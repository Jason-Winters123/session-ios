import PromiseKit

// A few notes about making changes in this file:
//
// • Don't use a database transaction if you can avoid it.
// • If you do need to use a database transaction, use a read transaction if possible.
// • For write transactions, consider making it the caller's responsibility to manage the database transaction (this helps avoid unnecessary transactions).
// • Think carefully about adding a function; there might already be one for what you need.
// • Document the expected cases in which a function will be used.
// • Express those cases in tests.

/// See [the documentation](https://github.com/loki-project/session-protocol-docs/wiki/Medium-Size-Groups) for more information.
@objc(LKClosedGroupsProtocol)
public final class ClosedGroupsProtocol : NSObject {
    public static let isSharedSenderKeysEnabled = true
    public static let groupSizeLimit = 20
    public static let maxNameSize = 64

    public enum Error : LocalizedError {
        case noThread
        case noPrivateKey
        case invalidUpdate

        public var errorDescription: String? {
            switch self {
            case .noThread: return "Couldn't find a thread associated with the given group public key."
            case .noPrivateKey: return "Couldn't find a private key associated with the given group public key."
            case .invalidUpdate: return "Invalid group update."
            }
        }
    }

    // MARK: - Sending

    /// - Note: It's recommended to batch fetch the device links for the given set of members before invoking this, to avoid the message sending pipeline
    /// making a request for each member.
    public static func createClosedGroup(name: String, members: Set<String>, transaction: YapDatabaseReadWriteTransaction) -> Promise<TSGroupThread> {
        // Prepare
        var members = members
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        let userPublicKey = getUserHexEncodedPublicKey()
        // Generate a key pair for the group
        let groupKeyPair = Curve25519.generateKeyPair()
        let groupPublicKey = groupKeyPair.hexEncodedPublicKey // Includes the "05" prefix
        // Ensure the current user's master device is the one that's included in the member list
        members.remove(userPublicKey)
        members.insert(UserDefaults.standard[.masterHexEncodedPublicKey] ?? userPublicKey)
        let membersAsData = members.map { Data(hex: $0) }
        // Create ratchets for all members (and their linked devices)
        var membersAndLinkedDevices: Set<String> = members
        for member in members {
            let deviceLinks = OWSPrimaryStorage.shared().getDeviceLinks(for: member, in: transaction)
            membersAndLinkedDevices.formUnion(deviceLinks.flatMap { [ $0.master.publicKey, $0.slave.publicKey ] })
        }
        let senderKeys: [ClosedGroupSenderKey] = membersAndLinkedDevices.map { publicKey in
            let ratchet = SharedSenderKeysImplementation.shared.generateRatchet(for: groupPublicKey, senderPublicKey: publicKey, using: transaction)
            return ClosedGroupSenderKey(chainKey: Data(hex: ratchet.chainKey), keyIndex: ratchet.keyIndex, publicKey: Data(hex: publicKey))
        }
        // Create the group
        let admins = [ UserDefaults.standard[.masterHexEncodedPublicKey] ?? userPublicKey ]
        let adminsAsData = admins.map { Data(hex: $0) }
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        let group = TSGroupModel(title: name, memberIds: [String](members), image: nil, groupId: groupID, groupType: .closedGroup, adminIds: admins)
        let thread = TSGroupThread.getOrCreateThread(with: group, transaction: transaction)
        thread.usesSharedSenderKeys = true
        thread.save(with: transaction)
        SSKEnvironment.shared.profileManager.addThread(toProfileWhitelist: thread)
        // Establish sessions if needed
        establishSessionsIfNeeded(with: [String](members), using: transaction) // Not `membersAndLinkedDevices` as this internally takes care of multi device already
        // Send a closed group update message to all members (and their linked devices) using established channels
        var promises: [Promise<Void>] = []
        for member in members { // Not `membersAndLinkedDevices` as this internally takes care of multi device already
            guard member != userPublicKey else { continue }
            let thread = TSContactThread.getOrCreateThread(withContactId: member, transaction: transaction)
            thread.save(with: transaction)
            let closedGroupUpdateMessageKind = ClosedGroupUpdateMessage.Kind.new(groupPublicKey: Data(hex: groupPublicKey), name: name,
                groupPrivateKey: groupKeyPair.privateKey, senderKeys: senderKeys, members: membersAsData, admins: adminsAsData)
            let closedGroupUpdateMessage = ClosedGroupUpdateMessage(thread: thread, kind: closedGroupUpdateMessageKind)
            promises.append(SSKEnvironment.shared.messageSender.sendPromise(message: closedGroupUpdateMessage))
        }
        // Add the group to the user's set of public keys to poll for
        Storage.setClosedGroupPrivateKey(groupKeyPair.privateKey.toHexString(), for: groupPublicKey, using: transaction)
        // Notify the PN server
        promises.append(LokiPushNotificationManager.performOperation(.subscribe, for: groupPublicKey, publicKey: userPublicKey))
        // Notify the user
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .typeGroupUpdate)
        infoMessage.save(with: transaction)
        // Return
        return when(fulfilled: promises).map2 { thread }
    }

    /// - Note: The returned promise is only relevant for group leaving.
    public static func update(_ groupPublicKey: String, with members: Set<String>, name: String, transaction: YapDatabaseReadWriteTransaction) -> Promise<Void> {
        let (promise, seal) = Promise<Void>.pending()
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        let userPublicKey = getUserHexEncodedPublicKey()
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        guard let thread = TSGroupThread.fetch(uniqueId: TSGroupThread.threadId(fromGroupId: groupID), transaction: transaction) else {
            print("[Loki] Can't update nonexistent closed group.")
            return Promise(error: Error.noThread)
        }
        let group = thread.groupModel
        let oldMembers = Set(group.groupMemberIds)
        let newMembers = members.subtracting(oldMembers)
        let membersAsData = members.map { Data(hex: $0) }
        let admins = group.groupAdminIds
        let adminsAsData = admins.map { Data(hex: $0) }
        guard let groupPrivateKey = Storage.getClosedGroupPrivateKey(for: groupPublicKey) else {
            print("[Loki] Couldn't get private key for closed group.")
            return Promise(error: Error.noPrivateKey)
        }
        let wasAnyUserRemoved = Set(members).intersection(oldMembers) != oldMembers
        let removedMembers = oldMembers.subtracting(members)
        let isUserLeaving = removedMembers.contains(userPublicKey)
        var newSenderKeys: [ClosedGroupSenderKey] = []
        if wasAnyUserRemoved {
            if isUserLeaving && removedMembers.count != 1 {
                print("[Loki] Can't remove self and others simultaneously.")
                return Promise(error: Error.invalidUpdate)
            }
            // Establish sessions if needed
            establishSessionsIfNeeded(with: [String](members), using: transaction)
            // Send the update to the existing members using established channels (don't include new ratchets as everyone should regenerate new ratchets individually)
            let promises: [Promise<Void>] = oldMembers.map { member in
                let thread = TSContactThread.getOrCreateThread(withContactId: member, transaction: transaction)
                thread.save(with: transaction)
                let closedGroupUpdateMessageKind = ClosedGroupUpdateMessage.Kind.info(groupPublicKey: Data(hex: groupPublicKey), name: name, senderKeys: [],
                    members: membersAsData, admins: adminsAsData)
                let closedGroupUpdateMessage = ClosedGroupUpdateMessage(thread: thread, kind: closedGroupUpdateMessageKind)
                return SSKEnvironment.shared.messageSender.sendPromise(message: closedGroupUpdateMessage)
            }
            when(resolved: promises).done2 { _ in seal.fulfill(()) }.catch2 { seal.reject($0) }
            promise.done {
                try! Storage.writeSync { transaction in
                    let allOldRatchets = Storage.getAllClosedGroupRatchets(for: groupPublicKey)
                    for (senderPublicKey, oldRatchet) in allOldRatchets {
                        let collection = Storage.ClosedGroupRatchetCollectionType.old
                        Storage.setClosedGroupRatchet(for: groupPublicKey, senderPublicKey: senderPublicKey, ratchet: oldRatchet, in: collection, using: transaction)
                    }
                    // Delete all ratchets (it's important that this happens * after * sending out the update)
                    Storage.removeAllClosedGroupRatchets(for: groupPublicKey, using: transaction)
                    // Remove the group from the user's set of public keys to poll for if the user is leaving. Otherwise generate a new ratchet and
                    // send it out to all members (minus the removed ones) using established channels.
                    if isUserLeaving {
                        Storage.removeClosedGroupPrivateKey(for: groupPublicKey, using: transaction)
                        // Notify the PN server
                        LokiPushNotificationManager.performOperation(.unsubscribe, for: groupPublicKey, publicKey: userPublicKey)
                    } else {
                        // Send closed group update messages to any new members using established channels
                        for member in newMembers {
                            let thread = TSContactThread.getOrCreateThread(withContactId: member, transaction: transaction)
                            thread.save(with: transaction)
                            let closedGroupUpdateMessageKind = ClosedGroupUpdateMessage.Kind.new(groupPublicKey: Data(hex: groupPublicKey), name: name,
                                groupPrivateKey: Data(hex: groupPrivateKey), senderKeys: [], members: membersAsData, admins: adminsAsData)
                            let closedGroupUpdateMessage = ClosedGroupUpdateMessage(thread: thread, kind: closedGroupUpdateMessageKind)
                            messageSenderJobQueue.add(message: closedGroupUpdateMessage, transaction: transaction)
                        }
                        // Send out the user's new ratchet to all members (minus the removed ones) using established channels
                        let userRatchet = SharedSenderKeysImplementation.shared.generateRatchet(for: groupPublicKey, senderPublicKey: userPublicKey, using: transaction)
                        let userSenderKey = ClosedGroupSenderKey(chainKey: Data(hex: userRatchet.chainKey), keyIndex: userRatchet.keyIndex, publicKey: Data(hex: userPublicKey))
                        for member in members {
                            guard member != userPublicKey else { continue }
                            let thread = TSContactThread.getOrCreateThread(withContactId: member, transaction: transaction)
                            thread.save(with: transaction)
                            let closedGroupUpdateMessageKind = ClosedGroupUpdateMessage.Kind.senderKey(groupPublicKey: Data(hex: groupPublicKey), senderKey: userSenderKey)
                            let closedGroupUpdateMessage = ClosedGroupUpdateMessage(thread: thread, kind: closedGroupUpdateMessageKind)
                            messageSenderJobQueue.add(message: closedGroupUpdateMessage, transaction: transaction)
                        }
                    }
                }
            }
        } else if !newMembers.isEmpty {
            seal.fulfill(())
            // Generate ratchets for any new members
            newSenderKeys = newMembers.map { publicKey in
                let ratchet = SharedSenderKeysImplementation.shared.generateRatchet(for: groupPublicKey, senderPublicKey: publicKey, using: transaction)
                return ClosedGroupSenderKey(chainKey: Data(hex: ratchet.chainKey), keyIndex: ratchet.keyIndex, publicKey: Data(hex: publicKey))
            }
            // Send a closed group update message to the existing members with the new members' ratchets (this message is aimed at the group)
            let closedGroupUpdateMessageKind = ClosedGroupUpdateMessage.Kind.info(groupPublicKey: Data(hex: groupPublicKey), name: name, senderKeys: newSenderKeys,
                members: membersAsData, admins: adminsAsData)
            let closedGroupUpdateMessage = ClosedGroupUpdateMessage(thread: thread, kind: closedGroupUpdateMessageKind)
            messageSenderJobQueue.add(message: closedGroupUpdateMessage, transaction: transaction)
            // Establish sessions if needed
            establishSessionsIfNeeded(with: [String](newMembers), using: transaction)
            // Send closed group update messages to the new members using established channels
            var allSenderKeys = Storage.getAllClosedGroupSenderKeys(for: groupPublicKey)
            allSenderKeys.formUnion(newSenderKeys)
            for member in newMembers {
                let thread = TSContactThread.getOrCreateThread(withContactId: member, transaction: transaction)
                thread.save(with: transaction)
                let closedGroupUpdateMessageKind = ClosedGroupUpdateMessage.Kind.new(groupPublicKey: Data(hex: groupPublicKey), name: name,
                    groupPrivateKey: Data(hex: groupPrivateKey), senderKeys: [ClosedGroupSenderKey](allSenderKeys), members: membersAsData, admins: adminsAsData)
                let closedGroupUpdateMessage = ClosedGroupUpdateMessage(thread: thread, kind: closedGroupUpdateMessageKind)
                messageSenderJobQueue.add(message: closedGroupUpdateMessage, transaction: transaction)
            }
        } else {
            seal.fulfill(())
            let allSenderKeys = Storage.getAllClosedGroupSenderKeys(for: groupPublicKey)
            let closedGroupUpdateMessageKind = ClosedGroupUpdateMessage.Kind.info(groupPublicKey: Data(hex: groupPublicKey), name: name,
                senderKeys: [ClosedGroupSenderKey](allSenderKeys), members: membersAsData, admins: adminsAsData)
            let closedGroupUpdateMessage = ClosedGroupUpdateMessage(thread: thread, kind: closedGroupUpdateMessageKind)
            messageSenderJobQueue.add(message: closedGroupUpdateMessage, transaction: transaction)
        }
        // Update the group
        let newGroupModel = TSGroupModel(title: name, memberIds: [String](members), image: nil, groupId: groupID, groupType: .closedGroup, adminIds: admins)
        thread.setGroupModel(newGroupModel, with: transaction)
        // Notify the user
        let updateInfo = group.getInfoStringAboutUpdate(to: newGroupModel, contactsManager: SSKEnvironment.shared.contactsManager)
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .typeGroupUpdate, customMessage: updateInfo)
        infoMessage.save(with: transaction)
        // Return
        return promise
    }

    /// The returned promise is fulfilled when the group update message has been sent. It doesn't wait for the user's new ratchet to be distributed.
    @objc(leaveGroupWithPublicKey:transaction:)
    public static func objc_leave(_ groupPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) -> AnyPromise {
        return AnyPromise.from(leave(groupPublicKey, using: transaction))
    }

    /// The returned promise is fulfilled when the group update message has been sent. It doesn't wait for the user's new ratchet to be distributed.
    public static func leave(_ groupPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) -> Promise<Void> {
        let userPublicKey = UserDefaults.standard[.masterHexEncodedPublicKey] ?? getUserHexEncodedPublicKey()
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        guard let thread = TSGroupThread.fetch(uniqueId: TSGroupThread.threadId(fromGroupId: groupID), transaction: transaction) else {
            print("[Loki] Can't leave nonexistent closed group.")
            return Promise(error: Error.noThread)
        }
        let group = thread.groupModel
        var newMembers = Set(group.groupMemberIds)
        newMembers.remove(userPublicKey)
        return update(groupPublicKey, with: newMembers, name: group.groupName!, transaction: transaction)
    }

    public static func requestSenderKey(for groupPublicKey: String, senderPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) {
        print("[Loki] Requesting sender key for group public key: \(groupPublicKey), sender public key: \(senderPublicKey).")
        // Establish session if needed
        SessionManagementProtocol.sendSessionRequestIfNeeded(to: senderPublicKey, using: transaction)
        // Send the request
        let thread = TSContactThread.getOrCreateThread(withContactId: senderPublicKey, transaction: transaction)
        thread.save(with: transaction)
        let closedGroupUpdateMessageKind = ClosedGroupUpdateMessage.Kind.senderKeyRequest(groupPublicKey: Data(hex: groupPublicKey))
        let closedGroupUpdateMessage = ClosedGroupUpdateMessage(thread: thread, kind: closedGroupUpdateMessageKind)
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        messageSenderJobQueue.add(message: closedGroupUpdateMessage, transaction: transaction)
    }

    // MARK: - Receiving

    @objc(handleSharedSenderKeysUpdateIfNeeded:from:transaction:)
    public static func handleSharedSenderKeysUpdateIfNeeded(_ dataMessage: SSKProtoDataMessage, from publicKey: String, using transaction: YapDatabaseReadWriteTransaction) {
        // Note that `publicKey` is either the public key of the group or the public key of the
        // sender, depending on how the message was sent
        guard let closedGroupUpdate = dataMessage.closedGroupUpdate, isValid(closedGroupUpdate) else { return }
        switch closedGroupUpdate.type {
        case .new: handleNewGroupMessage(closedGroupUpdate, using: transaction)
        case .info: handleInfoMessage(closedGroupUpdate, from: publicKey, using: transaction)
        case .senderKeyRequest: handleSenderKeyRequestMessage(closedGroupUpdate, from: publicKey, using: transaction)
        case .senderKey: handleSenderKeyMessage(closedGroupUpdate, from: publicKey, using: transaction)
        }
    }

    private static func isValid(_ closedGroupUpdate: SSKProtoDataMessageClosedGroupUpdate) -> Bool {
        guard !closedGroupUpdate.groupPublicKey.isEmpty else { return false }
        switch closedGroupUpdate.type {
        case .new: return !(closedGroupUpdate.name ?? "").isEmpty && !(closedGroupUpdate.groupPrivateKey ?? Data()).isEmpty && !closedGroupUpdate.members.isEmpty
            && !closedGroupUpdate.admins.isEmpty // senderKeys may be empty
        case .info: return !(closedGroupUpdate.name ?? "").isEmpty && !closedGroupUpdate.members.isEmpty && !closedGroupUpdate.admins.isEmpty // senderKeys may be empty
        case .senderKeyRequest: return true
        case .senderKey: return !closedGroupUpdate.senderKeys.isEmpty
        }
    }

    private static func handleNewGroupMessage(_ closedGroupUpdate: SSKProtoDataMessageClosedGroupUpdate, using transaction: YapDatabaseReadWriteTransaction) {
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        // Unwrap the message
        let groupPublicKey = closedGroupUpdate.groupPublicKey.toHexString()
        let name = closedGroupUpdate.name
        let groupPrivateKey = closedGroupUpdate.groupPrivateKey!
        let senderKeys = closedGroupUpdate.senderKeys
        let members = closedGroupUpdate.members.map { $0.toHexString() }
        let admins = closedGroupUpdate.admins.map { $0.toHexString() }
        // Persist the ratchets
        senderKeys.forEach { senderKey in
            guard members.contains(senderKey.publicKey.toHexString()) else { return } // TODO: This currently doesn't take into account multi device
            let ratchet = ClosedGroupRatchet(chainKey: senderKey.chainKey.toHexString(), keyIndex: UInt(senderKey.keyIndex), messageKeys: [])
            Storage.setClosedGroupRatchet(for: groupPublicKey, senderPublicKey: senderKey.publicKey.toHexString(), ratchet: ratchet, using: transaction)
        }
        // Sort out any discrepancies between the provided sender keys and what's required
        let missingSenderKeys = Set(members).subtracting(senderKeys.map { $0.publicKey.toHexString() })
        let userPublicKey = getUserHexEncodedPublicKey()
        if missingSenderKeys.contains(userPublicKey) {
            establishSessionsIfNeeded(with: [String](members), using: transaction)
            let userRatchet = SharedSenderKeysImplementation.shared.generateRatchet(for: groupPublicKey, senderPublicKey: userPublicKey, using: transaction)
            let userSenderKey = ClosedGroupSenderKey(chainKey: Data(hex: userRatchet.chainKey), keyIndex: userRatchet.keyIndex, publicKey: Data(hex: userPublicKey))
            for member in members {
                guard member != userPublicKey else { continue }
                let thread = TSContactThread.getOrCreateThread(withContactId: member, transaction: transaction)
                thread.save(with: transaction)
                let closedGroupUpdateMessageKind = ClosedGroupUpdateMessage.Kind.senderKey(groupPublicKey: Data(hex: groupPublicKey), senderKey: userSenderKey)
                let closedGroupUpdateMessage = ClosedGroupUpdateMessage(thread: thread, kind: closedGroupUpdateMessageKind)
                messageSenderJobQueue.add(message: closedGroupUpdateMessage, transaction: transaction)
            }
        }
        for publicKey in missingSenderKeys.subtracting([ userPublicKey ]) {
            requestSenderKey(for: groupPublicKey, senderPublicKey: publicKey, using: transaction)
        }
        // Create the group
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        let group = TSGroupModel(title: name, memberIds: members, image: nil, groupId: groupID, groupType: .closedGroup, adminIds: admins)
        let thread: TSGroupThread
        if let t = TSGroupThread.fetch(uniqueId: TSGroupThread.threadId(fromGroupId: groupID), transaction: transaction) {
            thread = t
            thread.setGroupModel(group, with: transaction)
        } else {
            thread = TSGroupThread.getOrCreateThread(with: group, transaction: transaction)
            thread.usesSharedSenderKeys = true
            thread.save(with: transaction)
        }
        SSKEnvironment.shared.profileManager.addThread(toProfileWhitelist: thread)
        // Add the group to the user's set of public keys to poll for
        Storage.setClosedGroupPrivateKey(groupPrivateKey.toHexString(), for: groupPublicKey, using: transaction)
        // Notify the PN server
        LokiPushNotificationManager.performOperation(.subscribe, for: groupPublicKey, publicKey: getUserHexEncodedPublicKey())
        // Notify the user
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .typeGroupUpdate)
        infoMessage.save(with: transaction)
        // Establish sessions if needed
        establishSessionsIfNeeded(with: members, using: transaction) // This internally takes care of multi device
    }

    /// Invoked upon receiving a group update. A group update is sent out when a group's name is changed, when new users are added, when users leave or are
    /// kicked, or if the group admins are changed.
    private static func handleInfoMessage(_ closedGroupUpdate: SSKProtoDataMessageClosedGroupUpdate, from senderPublicKey: String,
        using transaction: YapDatabaseReadWriteTransaction) {
        // Unwrap the message
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        let groupPublicKey = closedGroupUpdate.groupPublicKey.toHexString()
        let name = closedGroupUpdate.name
        let senderKeys = closedGroupUpdate.senderKeys
        let members = closedGroupUpdate.members.map { $0.toHexString() }
        let admins = closedGroupUpdate.admins.map { $0.toHexString() }
        // Get the group
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        guard let thread = TSGroupThread.fetch(uniqueId: TSGroupThread.threadId(fromGroupId: groupID), transaction: transaction) else {
            return print("[Loki] Ignoring closed group info message for nonexistent group.")
        }
        let group = thread.groupModel
        // Check that the sender is a member of the group (before the update)
        var membersAndLinkedDevices: Set<String> = Set(group.groupMemberIds)
        for member in group.groupMemberIds {
            let deviceLinks = OWSPrimaryStorage.shared().getDeviceLinks(for: member, in: transaction)
            membersAndLinkedDevices.formUnion(deviceLinks.flatMap { [ $0.master.publicKey, $0.slave.publicKey ] })
        }
        guard membersAndLinkedDevices.contains(senderPublicKey) else {
            return print("[Loki] Ignoring closed group info message from non-member.")
        }
        // Store the ratchets for any new members (it's important that this happens before the code below)
        senderKeys.forEach { senderKey in
            let ratchet = ClosedGroupRatchet(chainKey: senderKey.chainKey.toHexString(), keyIndex: UInt(senderKey.keyIndex), messageKeys: [])
            Storage.setClosedGroupRatchet(for: groupPublicKey, senderPublicKey: senderKey.publicKey.toHexString(), ratchet: ratchet, using: transaction)
        }
        // Delete all ratchets and either:
        // • Send out the user's new ratchet using established channels if other members of the group left or were removed
        // • Remove the group from the user's set of public keys to poll for if the current user was among the members that were removed
        let oldMembers = group.groupMemberIds
        let userPublicKey = UserDefaults.standard[.masterHexEncodedPublicKey] ?? getUserHexEncodedPublicKey()
        let wasUserRemoved = !members.contains(userPublicKey)
        if Set(members).intersection(oldMembers) != Set(oldMembers) {
            let allOldRatchets = Storage.getAllClosedGroupRatchets(for: groupPublicKey)
            for (senderPublicKey, oldRatchet) in allOldRatchets {
                let collection = Storage.ClosedGroupRatchetCollectionType.old
                Storage.setClosedGroupRatchet(for: groupPublicKey, senderPublicKey: senderPublicKey, ratchet: oldRatchet, in: collection, using: transaction)
            }
            Storage.removeAllClosedGroupRatchets(for: groupPublicKey, using: transaction)
            if wasUserRemoved {
                Storage.removeClosedGroupPrivateKey(for: groupPublicKey, using: transaction)
                // Notify the PN server
                LokiPushNotificationManager.performOperation(.unsubscribe, for: groupPublicKey, publicKey: userPublicKey)
            } else {
                establishSessionsIfNeeded(with: members, using: transaction) // This internally takes care of multi device
                let userRatchet = SharedSenderKeysImplementation.shared.generateRatchet(for: groupPublicKey, senderPublicKey: userPublicKey, using: transaction)
                let userSenderKey = ClosedGroupSenderKey(chainKey: Data(hex: userRatchet.chainKey), keyIndex: userRatchet.keyIndex, publicKey: Data(hex: userPublicKey))
                for member in members {
                    guard member != userPublicKey else { continue }
                    let thread = TSContactThread.getOrCreateThread(withContactId: member, transaction: transaction)
                    thread.save(with: transaction)
                    let closedGroupUpdateMessageKind = ClosedGroupUpdateMessage.Kind.senderKey(groupPublicKey: Data(hex: groupPublicKey), senderKey: userSenderKey)
                    let closedGroupUpdateMessage = ClosedGroupUpdateMessage(thread: thread, kind: closedGroupUpdateMessageKind)
                    messageSenderJobQueue.add(message: closedGroupUpdateMessage, transaction: transaction) // This internally takes care of multi device
                }
            }
        }
        // Update the group
        let newGroupModel = TSGroupModel(title: name, memberIds: members, image: nil, groupId: groupID, groupType: .closedGroup, adminIds: admins)
        thread.setGroupModel(newGroupModel, with: transaction)
        // Notify the user if needed (don't notify them if the message just contained linked device sender keys)
        if Set(members) != Set(oldMembers) || Set(admins) != Set(group.groupAdminIds) || name != group.groupName {
            let infoMessageType: TSInfoMessageType = wasUserRemoved ? .typeGroupQuit : .typeGroupUpdate
            let updateInfo = group.getInfoStringAboutUpdate(to: newGroupModel, contactsManager: SSKEnvironment.shared.contactsManager)
            let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: infoMessageType, customMessage: updateInfo)
            infoMessage.save(with: transaction)
        }
    }

    private static func handleSenderKeyRequestMessage(_ closedGroupUpdate: SSKProtoDataMessageClosedGroupUpdate, from senderPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) {
        // Prepare
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        let userPublicKey = getUserHexEncodedPublicKey()
        let groupPublicKey = closedGroupUpdate.groupPublicKey.toHexString()
        let groupID = LKGroupUtilities.getEncodedClosedGroupIDAsData(groupPublicKey)
        guard let groupThread = TSGroupThread.fetch(uniqueId: TSGroupThread.threadId(fromGroupId: groupID), transaction: transaction) else {
            return print("[Loki] Ignoring closed group sender key request for nonexistent group.")
        }
        let group = groupThread.groupModel
        // Check that the requesting user is a member of the group
        var membersAndLinkedDevices: Set<String> = Set(group.groupMemberIds)
        for member in group.groupMemberIds {
            let deviceLinks = OWSPrimaryStorage.shared().getDeviceLinks(for: member, in: transaction)
            membersAndLinkedDevices.formUnion(deviceLinks.flatMap { [ $0.master.publicKey, $0.slave.publicKey ] })
        }
        guard membersAndLinkedDevices.contains(senderPublicKey) else {
            return print("[Loki] Ignoring closed group sender key request from non-member.")
        }
        // Respond to the request
        print("[Loki] Responding to sender key request from: \(senderPublicKey).")
        SessionManagementProtocol.sendSessionRequestIfNeeded(to: senderPublicKey, using: transaction) // This internally takes care of multi device
        let userRatchet = Storage.getClosedGroupRatchet(for: groupPublicKey, senderPublicKey: userPublicKey)
            ?? SharedSenderKeysImplementation.shared.generateRatchet(for: groupPublicKey, senderPublicKey: userPublicKey, using: transaction)
        let userSenderKey = ClosedGroupSenderKey(chainKey: Data(hex: userRatchet.chainKey), keyIndex: userRatchet.keyIndex, publicKey: Data(hex: userPublicKey))
        let thread = TSContactThread.getOrCreateThread(withContactId: senderPublicKey, transaction: transaction)
        thread.save(with: transaction)
        let closedGroupUpdateMessageKind = ClosedGroupUpdateMessage.Kind.senderKey(groupPublicKey: Data(hex: groupPublicKey), senderKey: userSenderKey)
        let closedGroupUpdateMessage = ClosedGroupUpdateMessage(thread: thread, kind: closedGroupUpdateMessageKind)
        messageSenderJobQueue.add(message: closedGroupUpdateMessage, transaction: transaction) // This internally takes care of multi device
    }

    /// Invoked upon receiving a sender key from another user.
    private static func handleSenderKeyMessage(_ closedGroupUpdate: SSKProtoDataMessageClosedGroupUpdate, from senderPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) {
        // Prepare
        let groupPublicKey = closedGroupUpdate.groupPublicKey.toHexString()
        guard let senderKey = closedGroupUpdate.senderKeys.first else {
            return print("[Loki] Ignoring invalid closed group sender key.")
        }
        guard senderKey.publicKey.toHexString() == senderPublicKey else {
            return print("[Loki] Ignoring invalid closed group sender key.")
        }
        // Store the sender key
        print("[Loki] Received a sender key from: \(senderPublicKey).")
        let ratchet = ClosedGroupRatchet(chainKey: senderKey.chainKey.toHexString(), keyIndex: UInt(senderKey.keyIndex), messageKeys: [])
        Storage.setClosedGroupRatchet(for: groupPublicKey, senderPublicKey: senderPublicKey, ratchet: ratchet, using: transaction)
    }

    // MARK: - General

    @objc(establishSessionsIfNeededWithClosedGroupMembers:transaction:)
    public static func establishSessionsIfNeeded(with closedGroupMembers: [String], using transaction: YapDatabaseReadWriteTransaction) {
        closedGroupMembers.forEach { publicKey in
            SessionManagementProtocol.sendSessionRequestIfNeeded(to: publicKey, using: transaction)
        }
    }

    @objc(shouldIgnoreClosedGroupMessage:inThread:wrappedIn:)
    public static func shouldIgnoreClosedGroupMessage(_ dataMessage: SSKProtoDataMessage, in thread: TSGroupThread, wrappedIn envelope: SSKProtoEnvelope) -> Bool {
        guard thread.groupModel.groupType == .closedGroup else { return true }
        let publicKey = envelope.source! // Set during UD decryption
        var result = false
        Storage.read { transaction in
            result = !thread.isUserMember(inGroup: publicKey, transaction: transaction)
        }
        return result
    }

    /// - Note: Deprecated.
    @objc(shouldIgnoreClosedGroupUpdateMessage:inThread:wrappedIn:)
    public static func shouldIgnoreClosedGroupUpdateMessage(_ dataMessage: SSKProtoDataMessage, in thread: TSGroupThread, wrappedIn envelope: SSKProtoEnvelope) -> Bool {
        guard thread.groupModel.groupType == .closedGroup else { return true }
        let publicKey = envelope.source! // Set during UD decryption
        var result = false
        Storage.read { transaction in
            result = !thread.isUserAdmin(inGroup: publicKey, transaction: transaction)
        }
        return result
    }
}
