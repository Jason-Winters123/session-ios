//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import PromiseKit
import SessionServiceKit

@objc(OWSSyncPushTokensJob)
class SyncPushTokensJob: NSObject {

    @objc public static let PushTokensDidChange = Notification.Name("PushTokensDidChange")

    // MARK: Dependencies
    let accountManager: AccountManager
    let preferences: OWSPreferences
    var pushRegistrationManager: PushRegistrationManager {
        return PushRegistrationManager.shared
    }

    @objc var uploadOnlyIfStale = true

    @objc
    required init(accountManager: AccountManager, preferences: OWSPreferences) {
        self.accountManager = accountManager
        self.preferences = preferences
    }

    class func run(accountManager: AccountManager, preferences: OWSPreferences) -> Promise<Void> {
        let job = self.init(accountManager: accountManager, preferences: preferences)
        return job.run()
    }

    func run() -> Promise<Void> {

        let runPromise = firstly {
            return self.pushRegistrationManager.requestPushTokens()
        }.then { (pushToken: String, voipToken: String) -> Promise<Void> in
            var shouldUploadTokens = false

            if self.preferences.getPushToken() != pushToken || self.preferences.getVoipToken() != voipToken {
                shouldUploadTokens = true
            } else if !self.uploadOnlyIfStale {
                shouldUploadTokens = true
            }

            if AppVersion.sharedInstance().lastAppVersion != AppVersion.sharedInstance().currentAppVersion {
                shouldUploadTokens = true
            }

            guard shouldUploadTokens else {
                return Promise.value(())
            }

            return firstly {
                self.accountManager.updatePushTokens(pushToken: pushToken, voipToken: voipToken, isForcedUpdate: shouldUploadTokens)
            }.done { _ in
                self.recordPushTokensLocally(pushToken: pushToken, voipToken: voipToken)
            }
        }

        runPromise.retainUntilComplete()

        return runPromise
    }

    // MARK: - objc wrappers, since objc can't use swift parameterized types

    @objc
    class func run(accountManager: AccountManager, preferences: OWSPreferences) -> AnyPromise {
        let promise: Promise<Void> = self.run(accountManager: accountManager, preferences: preferences)
        return AnyPromise(promise)
    }

    @objc
    func run() -> AnyPromise {
        let promise: Promise<Void> = self.run()
        return AnyPromise(promise)
    }

    // MARK: 

    private func recordPushTokensLocally(pushToken: String, voipToken: String) {
        Logger.warn("Recording push tokens locally. pushToken: \(redact(pushToken)), voipToken: \(redact(voipToken))")

        var didTokensChange = false

        if (pushToken != self.preferences.getPushToken()) {
            Logger.info("Recording new plain push token")
            self.preferences.setPushToken(pushToken)
            didTokensChange = true
        }

        if (voipToken != self.preferences.getVoipToken()) {
            Logger.info("Recording new voip token")
            self.preferences.setVoipToken(voipToken)
            didTokensChange = true
        }

        if (didTokensChange) {
            NotificationCenter.default.postNotificationNameAsync(SyncPushTokensJob.PushTokensDidChange, object: nil)
        }
    }
}

private func redact(_ string: String) -> String {
    return OWSIsDebugBuild() ? string : "[ READACTED \(string.prefix(2))...\(string.suffix(2)) ]"
}
