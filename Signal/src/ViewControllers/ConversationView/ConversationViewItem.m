//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "ConversationViewItem.h"
#import "OWSContactOffersCell.h"
#import "OWSMessageCell.h"
#import "OWSMessageHeaderView.h"
#import "OWSSystemMessageCell.h"
#import "Session-Swift.h"
#import "AnyPromise.h"
#import <SignalMessaging/OWSUnreadIndicator.h>
#import <SessionServiceKit/NSData+Image.h>
#import <SessionServiceKit/NSString+SSK.h>
#import <SessionServiceKit/OWSContact.h>
#import <SessionServiceKit/TSInteraction.h>
#import <SessionServiceKit/SSKEnvironment.h>
#import <SessionServiceKit/SessionServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSString *NSStringForOWSMessageCellType(OWSMessageCellType cellType)
{
    switch (cellType) {
        case OWSMessageCellType_TextOnlyMessage:
            return @"OWSMessageCellType_TextOnlyMessage";
        case OWSMessageCellType_Audio:
            return @"OWSMessageCellType_Audio";
        case OWSMessageCellType_GenericAttachment:
            return @"OWSMessageCellType_GenericAttachment";
        case OWSMessageCellType_Unknown:
            return @"OWSMessageCellType_Unknown";
        case OWSMessageCellType_ContactShare:
            return @"OWSMessageCellType_ContactShare";
        case OWSMessageCellType_MediaMessage:
            return @"OWSMessageCellType_MediaMessage";
        case OWSMessageCellType_OversizeTextDownloading:
            return @"OWSMessageCellType_OversizeTextDownloading";
    }
}

#pragma mark -

@implementation ConversationMediaAlbumItem

- (instancetype)initWithAttachment:(TSAttachment *)attachment
                  attachmentStream:(nullable TSAttachmentStream *)attachmentStream
                           caption:(nullable NSString *)caption
                         mediaSize:(CGSize)mediaSize
{
    OWSAssertDebug(attachment);

    self = [super init];

    if (!self) {
        return self;
    }

    _attachment = attachment;
    _attachmentStream = attachmentStream;
    _caption = caption;
    _mediaSize = mediaSize;

    return self;
}

- (BOOL)isFailedDownload
{
    if (![self.attachment isKindOfClass:[TSAttachmentPointer class]]) {
        return NO;
    }
    TSAttachmentPointer *attachmentPointer = (TSAttachmentPointer *)self.attachment;
    return attachmentPointer.state == TSAttachmentPointerStateFailed;
}

@end

#pragma mark -

@interface ConversationInteractionViewItem ()

@property (nonatomic, nullable) NSValue *cachedCellSize;

#pragma mark - OWSAudioPlayerDelegate

@property (nonatomic) AudioPlaybackState audioPlaybackState;
@property (nonatomic) CGFloat audioProgressSeconds;
@property (nonatomic) CGFloat audioDurationSeconds;

#pragma mark - View State

@property (nonatomic) BOOL hasViewState;
@property (nonatomic) OWSMessageCellType messageCellType;
@property (nonatomic, nullable) DisplayableText *displayableBodyText;
@property (nonatomic, nullable) DisplayableText *displayableQuotedText;
@property (nonatomic, nullable) OWSQuotedReplyModel *quotedReply;
@property (nonatomic, nullable) TSAttachmentStream *attachmentStream;
@property (nonatomic, nullable) TSAttachmentPointer *attachmentPointer;
@property (nonatomic, nullable) ContactShareViewModel *contactShare;
@property (nonatomic, nullable) OWSLinkPreview *linkPreview;
@property (nonatomic, nullable) TSAttachment *linkPreviewAttachment;
@property (nonatomic, nullable) NSArray<ConversationMediaAlbumItem *> *mediaAlbumItems;
@property (nonatomic, nullable) NSString *systemMessageText;
@property (nonatomic, nullable) TSThread *incomingMessageAuthorThread;
@property (nonatomic, nullable) NSString *authorConversationColorName;
@property (nonatomic, nullable) ConversationStyle *conversationStyle;

@end

#pragma mark -

@implementation ConversationInteractionViewItem

@synthesize shouldShowDate = _shouldShowDate;
@synthesize shouldShowSenderAvatar = _shouldShowSenderAvatar;
@synthesize unreadIndicator = _unreadIndicator;
@synthesize didCellMediaFailToLoad = _didCellMediaFailToLoad;
@synthesize interaction = _interaction;
@synthesize isFirstInCluster = _isFirstInCluster;
@synthesize isGroupThread = _isGroupThread;
@synthesize isRSSFeed = _isRSSFeed;
@synthesize isLastInCluster = _isLastInCluster;
@synthesize lastAudioMessageView = _lastAudioMessageView;
@synthesize senderName = _senderName;
@synthesize shouldHideFooter = _shouldHideFooter;

- (instancetype)initWithInteraction:(TSInteraction *)interaction
                      isGroupThread:(BOOL)isGroupThread
                          isRSSFeed:(BOOL)isRSSFeed
                        transaction:(YapDatabaseReadTransaction *)transaction
                  conversationStyle:(ConversationStyle *)conversationStyle
{
    OWSAssertDebug(interaction);
    OWSAssertDebug(transaction);
    OWSAssertDebug(conversationStyle);

    self = [super init];

    if (!self) {
        return self;
    }

    _interaction = interaction;
    _isGroupThread = isGroupThread;
    _isRSSFeed = isRSSFeed;
    _conversationStyle = conversationStyle;

    [self updateAuthorConversationColorNameWithTransaction:transaction];

    [self ensureViewState:transaction];

    return self;
}

- (void)replaceInteraction:(TSInteraction *)interaction transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertDebug(interaction);

    _interaction = interaction;

    self.hasViewState = NO;
    self.messageCellType = OWSMessageCellType_Unknown;
    self.displayableBodyText = nil;
    self.attachmentStream = nil;
    self.attachmentPointer = nil;
    self.mediaAlbumItems = nil;
    self.displayableQuotedText = nil;
    self.quotedReply = nil;
    self.contactShare = nil;
    self.systemMessageText = nil;
    self.authorConversationColorName = nil;
    self.linkPreview = nil;
    self.linkPreviewAttachment = nil;

    [self updateAuthorConversationColorNameWithTransaction:transaction];

    [self clearCachedLayoutState];

    [self ensureViewState:transaction];
}

- (void)updateAuthorConversationColorNameWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertDebug(transaction);

    switch (self.interaction.interactionType) {
        case OWSInteractionType_TypingIndicator: {
            OWSTypingIndicatorInteraction *typingIndicator = (OWSTypingIndicatorInteraction *)self.interaction;
            _authorConversationColorName =
                [TSContactThread conversationColorNameForRecipientId:typingIndicator.recipientId
                                                         transaction:transaction];
            break;
        }
        case OWSInteractionType_IncomingMessage: {
            TSIncomingMessage *incomingMessage = (TSIncomingMessage *)self.interaction;
            _authorConversationColorName =
                [TSContactThread conversationColorNameForRecipientId:incomingMessage.authorId transaction:transaction];
            break;
        }
        default:
            _authorConversationColorName = nil;
            break;
    }
}

- (OWSPrimaryStorage *)primaryStorage
{
    return SSKEnvironment.shared.primaryStorage;
}

- (NSString *)itemId
{
    return self.interaction.uniqueId;
}

- (BOOL)hasBodyText
{
    return _displayableBodyText != nil;
}

- (BOOL)hasQuotedText
{
    return _displayableQuotedText != nil;
}

- (BOOL)hasQuotedAttachment
{
    return self.quotedAttachmentMimetype.length > 0;
}

- (BOOL)isQuotedReply
{
    return self.hasQuotedAttachment || self.hasQuotedText;
}

- (BOOL)isExpiringMessage
{
    if (self.interaction.interactionType != OWSInteractionType_OutgoingMessage
        && self.interaction.interactionType != OWSInteractionType_IncomingMessage) {
        return NO;
    }

    TSMessage *message = (TSMessage *)self.interaction;
    return message.isExpiringMessage;
}

- (BOOL)hasCellHeader
{
    return self.shouldShowDate || self.unreadIndicator;
}

- (void)setShouldShowDate:(BOOL)shouldShowDate
{
    if (_shouldShowDate == shouldShowDate) {
        return;
    }

    _shouldShowDate = shouldShowDate;

    [self clearCachedLayoutState];
}

- (void)setShouldShowSenderAvatar:(BOOL)shouldShowSenderAvatar
{
    if (_shouldShowSenderAvatar == shouldShowSenderAvatar) {
        return;
    }

    _shouldShowSenderAvatar = shouldShowSenderAvatar;

    [self clearCachedLayoutState];
}

- (void)setSenderName:(nullable NSAttributedString *)senderName
{
    if ([NSObject isNullableObject:senderName equalTo:_senderName]) {
        return;
    }

    _senderName = senderName;

    [self clearCachedLayoutState];
}

- (void)setShouldHideFooter:(BOOL)shouldHideFooter
{
    if (_shouldHideFooter == shouldHideFooter) {
        return;
    }

    _shouldHideFooter = shouldHideFooter;

    [self clearCachedLayoutState];
}

- (void)setIsFirstInCluster:(BOOL)isFirstInCluster
{
    if (_isFirstInCluster == isFirstInCluster) {
        return;
    }

    _isFirstInCluster = isFirstInCluster;

    // Although this doesn't affect layout size, the view model use
    // hasCachedLayoutState to detect which cells needs to be redrawn due to changes.
    [self clearCachedLayoutState];
}

- (void)setIsLastInCluster:(BOOL)isLastInCluster
{
    if (_isLastInCluster == isLastInCluster) {
        return;
    }

    _isLastInCluster = isLastInCluster;

    // Although this doesn't affect layout size, the view model use
    // hasCachedLayoutState to detect which cells needs to be redrawn due to changes.
    [self clearCachedLayoutState];
}

- (void)setUnreadIndicator:(nullable OWSUnreadIndicator *)unreadIndicator
{
    if ([NSObject isNullableObject:_unreadIndicator equalTo:unreadIndicator]) {
        return;
    }

    _unreadIndicator = unreadIndicator;

    [self clearCachedLayoutState];
}

- (void)clearCachedLayoutState
{
    self.cachedCellSize = nil;
}

- (BOOL)hasCachedLayoutState {
    return self.cachedCellSize != nil;
}

- (CGSize)cellSize
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(self.conversationStyle);

    if (!self.cachedCellSize) {
        ConversationViewCell *_Nullable measurementCell = [self measurementCell];
        measurementCell.viewItem = self;
        measurementCell.conversationStyle = self.conversationStyle;
        CGSize cellSize = [measurementCell cellSize];
        self.cachedCellSize = [NSValue valueWithCGSize:cellSize];
        [measurementCell prepareForReuse];
    }
    return [self.cachedCellSize CGSizeValue];
}

- (nullable ConversationViewCell *)measurementCell
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(self.interaction);

    // For performance reasons, we cache one instance of each kind of
    // cell and uses these cells for measurement.
    static NSMutableDictionary<NSNumber *, ConversationViewCell *> *measurementCellCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        measurementCellCache = [NSMutableDictionary new];
    });

    NSNumber *cellCacheKey = @(self.interaction.interactionType);
    ConversationViewCell *_Nullable measurementCell = measurementCellCache[cellCacheKey];
    if (!measurementCell) {
        switch (self.interaction.interactionType) {
            case OWSInteractionType_Unknown:
                OWSFailDebug(@"Unknown interaction type.");
                return nil;
            case OWSInteractionType_IncomingMessage:
            case OWSInteractionType_OutgoingMessage:
                measurementCell = [OWSMessageCell new];
                break;
            case OWSInteractionType_Error:
            case OWSInteractionType_Info:
            case OWSInteractionType_Call:
                measurementCell = [OWSSystemMessageCell new];
                break;
            case OWSInteractionType_Offer:
                measurementCell = [OWSContactOffersCell new];
                break;
            case OWSInteractionType_TypingIndicator:
                measurementCell = [OWSTypingIndicatorCell new];
                break;
        }

        OWSAssertDebug(measurementCell);
        measurementCellCache[cellCacheKey] = measurementCell;
    }

    return measurementCell;
}

- (CGFloat)vSpacingWithPreviousLayoutItem:(id<ConversationViewItem>)previousLayoutItem
{
    OWSAssertDebug(previousLayoutItem);

    if (self.hasCellHeader) {
        return OWSMessageHeaderViewDateHeaderVMargin;
    }

    // "Bubble Collapse".  Adjacent messages with the same author should be close together.
    if (self.interaction.interactionType == OWSInteractionType_IncomingMessage
        && previousLayoutItem.interaction.interactionType == OWSInteractionType_IncomingMessage) {
        TSIncomingMessage *incomingMessage = (TSIncomingMessage *)self.interaction;
        TSIncomingMessage *previousIncomingMessage = (TSIncomingMessage *)previousLayoutItem.interaction;
        if ([incomingMessage.authorId isEqualToString:previousIncomingMessage.authorId]) {
            return 2.f;
        }
    } else if (self.interaction.interactionType == OWSInteractionType_OutgoingMessage
        && previousLayoutItem.interaction.interactionType == OWSInteractionType_OutgoingMessage) {
        return 2.f;
    }

    return 12.f;
}

- (ConversationViewCell *)dequeueCellForCollectionView:(UICollectionView *)collectionView
                                             indexPath:(NSIndexPath *)indexPath
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(collectionView);
    OWSAssertDebug(indexPath);
    OWSAssertDebug(self.interaction);

    switch (self.interaction.interactionType) {
        case OWSInteractionType_Unknown:
            OWSFailDebug(@"Unknown interaction type.");
            return nil;
        case OWSInteractionType_IncomingMessage:
        case OWSInteractionType_OutgoingMessage:
            return [collectionView dequeueReusableCellWithReuseIdentifier:[OWSMessageCell cellReuseIdentifier]
                                                             forIndexPath:indexPath];
        case OWSInteractionType_Error:
        case OWSInteractionType_Info:
        case OWSInteractionType_Call:
            return [collectionView dequeueReusableCellWithReuseIdentifier:[OWSSystemMessageCell cellReuseIdentifier]
                                                             forIndexPath:indexPath];
        case OWSInteractionType_Offer:
            return [collectionView dequeueReusableCellWithReuseIdentifier:[OWSContactOffersCell cellReuseIdentifier]
                                                             forIndexPath:indexPath];

        case OWSInteractionType_TypingIndicator:
            return [collectionView dequeueReusableCellWithReuseIdentifier:[OWSTypingIndicatorCell cellReuseIdentifier]
                                                             forIndexPath:indexPath];
    }
}

- (nullable TSAttachmentStream *)firstValidAlbumAttachment
{
    OWSAssertDebug(self.mediaAlbumItems.count > 0);

    // For now, use first valid attachment.
    TSAttachmentStream *_Nullable attachmentStream = nil;
    for (ConversationMediaAlbumItem *mediaAlbumItem in self.mediaAlbumItems) {
        if (mediaAlbumItem.attachmentStream && mediaAlbumItem.attachmentStream.isValidVisualMedia) {
            attachmentStream = mediaAlbumItem.attachmentStream;
            break;
        }
    }
    return attachmentStream;
}

#pragma mark - OWSAudioPlayerDelegate

- (void)setAudioPlaybackState:(AudioPlaybackState)audioPlaybackState
{
    _audioPlaybackState = audioPlaybackState;

    BOOL isPlaying = (audioPlaybackState == AudioPlaybackState_Playing);
    [self.lastAudioMessageView setIsPlaying:isPlaying];
}

- (void)setAudioProgress:(CGFloat)progress duration:(CGFloat)duration
{
    OWSAssertIsOnMainThread();

    self.audioProgressSeconds = progress;

    [self.lastAudioMessageView setProgress:progress / duration];
}

#pragma mark - Displayable Text

// TODO: Now that we're caching the displayable text on the view items,
//       I don't think we need this cache any more.
- (NSCache *)displayableTextCache
{
    static NSCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        // Cache the results for up to 1,000 messages.
        cache.countLimit = 1000;
    });
    return cache;
}

- (DisplayableText *)displayableBodyTextForText:(NSString *)text interactionId:(NSString *)interactionId
{
    OWSAssertDebug(text);
    OWSAssertDebug(interactionId.length > 0);

    NSString *displayableTextCacheKey = [@"body-" stringByAppendingString:interactionId];

    return [self displayableTextForCacheKey:displayableTextCacheKey
                                  textBlock:^{
                                      return text;
                                  }];
}

- (DisplayableText *)displayableBodyTextForOversizeTextAttachment:(TSAttachmentStream *)attachmentStream
                                                    interactionId:(NSString *)interactionId
{
    OWSAssertDebug(attachmentStream);
    OWSAssertDebug(interactionId.length > 0);

    NSString *displayableTextCacheKey = [@"oversize-body-" stringByAppendingString:interactionId];

    return [self displayableTextForCacheKey:displayableTextCacheKey
                                  textBlock:^{
                                      NSData *textData =
                                          [NSData dataWithContentsOfURL:attachmentStream.originalMediaURL];
                                      NSString *text =
                                          [[NSString alloc] initWithData:textData encoding:NSUTF8StringEncoding];
                                      return text;
                                  }];
}

- (DisplayableText *)displayableQuotedTextForText:(NSString *)text interactionId:(NSString *)interactionId
{
    OWSAssertDebug(text);
    OWSAssertDebug(interactionId.length > 0);

    NSString *displayableTextCacheKey = [@"quoted-" stringByAppendingString:interactionId];

    return [self displayableTextForCacheKey:displayableTextCacheKey
                                  textBlock:^{
                                      return text;
                                  }];
}

- (DisplayableText *)displayableCaptionForText:(NSString *)text attachmentId:(NSString *)attachmentId
{
    OWSAssertDebug(text);
    OWSAssertDebug(attachmentId.length > 0);

    NSString *displayableTextCacheKey = [@"attachment-caption-" stringByAppendingString:attachmentId];

    return [self displayableTextForCacheKey:displayableTextCacheKey
                                  textBlock:^{
                                      return text;
                                  }];
}

- (DisplayableText *)displayableTextForCacheKey:(NSString *)displayableTextCacheKey
                                      textBlock:(NSString * (^_Nonnull)(void))textBlock
{
    OWSAssertDebug(displayableTextCacheKey.length > 0);

    DisplayableText *_Nullable displayableText = [[self displayableTextCache] objectForKey:displayableTextCacheKey];
    if (!displayableText) {
        NSString *text = textBlock();
        displayableText = [DisplayableText displayableText:text];
        [[self displayableTextCache] setObject:displayableText forKey:displayableTextCacheKey];
    }
    return displayableText;
}

#pragma mark - View State

- (void)ensureViewState:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(transaction);
    OWSAssertDebug(!self.hasViewState);

    switch (self.interaction.interactionType) {
        case OWSInteractionType_Unknown:
        case OWSInteractionType_Offer:
        case OWSInteractionType_TypingIndicator:
            return;
        case OWSInteractionType_Error:
        case OWSInteractionType_Info:
        case OWSInteractionType_Call:
            self.systemMessageText = [self systemMessageTextWithTransaction:transaction];
            OWSAssertDebug(self.systemMessageText.length > 0);
            return;
        case OWSInteractionType_IncomingMessage:
        case OWSInteractionType_OutgoingMessage:
            break;
        default:
            OWSFailDebug(@"Unknown interaction type.");
            return;
    }

    OWSAssertDebug([self.interaction isKindOfClass:[TSOutgoingMessage class]] ||
        [self.interaction isKindOfClass:[TSIncomingMessage class]]);

    self.hasViewState = YES;

    TSMessage *message = (TSMessage *)self.interaction;
    if (message.contactShare) {
        self.contactShare =
            [[ContactShareViewModel alloc] initWithContactShareRecord:message.contactShare transaction:transaction];
        self.messageCellType = OWSMessageCellType_ContactShare;
        return;
    }

    // Check for quoted replies _before_ media album handling,
    // since that logic may exit early.
    if (message.quotedMessage) {
        self.quotedReply =
            [OWSQuotedReplyModel quotedReplyWithQuotedMessage:message.quotedMessage threadId:message.uniqueThreadId transaction:transaction];

        if (self.quotedReply.body.length > 0) {
            self.displayableQuotedText =
                [self displayableQuotedTextForText:self.quotedReply.body interactionId:message.uniqueId];
        }
    }

    TSAttachment *_Nullable oversizeTextAttachment = [message oversizeTextAttachmentWithTransaction:transaction];
    if ([oversizeTextAttachment isKindOfClass:[TSAttachmentStream class]]) {
        TSAttachmentStream *oversizeTextAttachmentStream = (TSAttachmentStream *)oversizeTextAttachment;
        self.displayableBodyText = [self displayableBodyTextForOversizeTextAttachment:oversizeTextAttachmentStream
                                                                        interactionId:message.uniqueId];
    } else if ([oversizeTextAttachment isKindOfClass:[TSAttachmentPointer class]]) {
        TSAttachmentPointer *oversizeTextAttachmentPointer = (TSAttachmentPointer *)oversizeTextAttachment;
        // TODO: Handle backup restore.
        self.messageCellType = OWSMessageCellType_OversizeTextDownloading;
        self.attachmentPointer = (TSAttachmentPointer *)oversizeTextAttachmentPointer;
        return;
    } else {
        NSString *_Nullable bodyText = [message bodyTextWithTransaction:transaction];
        if (bodyText) {
            self.displayableBodyText = [self displayableBodyTextForText:bodyText interactionId:message.uniqueId];
        }
    }

    NSArray<TSAttachment *> *mediaAttachments = [message mediaAttachmentsWithTransaction:transaction];
    NSArray<ConversationMediaAlbumItem *> *mediaAlbumItems = [self albumItemsForMediaAttachments:mediaAttachments];
    if (mediaAlbumItems.count > 0) {
        if (mediaAlbumItems.count == 1) {
            ConversationMediaAlbumItem *mediaAlbumItem = mediaAlbumItems.firstObject;
            if (mediaAlbumItem.attachmentStream && !mediaAlbumItem.attachmentStream.isValidVisualMedia) {
                OWSLogWarn(@"Treating invalid media as generic attachment.");
                self.messageCellType = OWSMessageCellType_GenericAttachment;
                return;
            }
        }

        self.mediaAlbumItems = mediaAlbumItems;
        self.messageCellType = OWSMessageCellType_MediaMessage;
        return;
    }

    // Only media galleries should have more than one attachment.
    OWSAssertDebug(mediaAttachments.count <= 1);

    TSAttachment *_Nullable mediaAttachment = mediaAttachments.firstObject;
    if (mediaAttachment) {
        if ([mediaAttachment isKindOfClass:[TSAttachmentStream class]]) {
            self.attachmentStream = (TSAttachmentStream *)mediaAttachment;
            if ([self.attachmentStream isAudio]) {
                CGFloat audioDurationSeconds = [self.attachmentStream audioDurationSeconds];
                if (audioDurationSeconds > 0) {
                    self.audioDurationSeconds = audioDurationSeconds;
                    self.messageCellType = OWSMessageCellType_Audio;
                } else {
                    self.messageCellType = OWSMessageCellType_GenericAttachment;
                }
            } else if (self.messageCellType == OWSMessageCellType_Unknown) {
                self.messageCellType = OWSMessageCellType_GenericAttachment;
            }
        } else if ([mediaAttachment isKindOfClass:[TSAttachmentPointer class]]) {
            if ([mediaAttachment isAudio]) {
                self.audioDurationSeconds = 0;
                self.messageCellType = OWSMessageCellType_Audio;
            } else {
                self.messageCellType = OWSMessageCellType_GenericAttachment;
            }
            self.attachmentPointer = (TSAttachmentPointer *)mediaAttachment;
        } else {
            OWSFailDebug(@"Unknown attachment type");
        }
    }

    if (self.hasBodyText) {
        if (self.messageCellType == OWSMessageCellType_Unknown) {
//            OWSAssertDebug(message.attachmentIds.count == 0
//                || (message.attachmentIds.count == 1 &&
//                       [message oversizeTextAttachmentWithTransaction:transaction] != nil));
            self.messageCellType = OWSMessageCellType_TextOnlyMessage;
        }
        OWSAssertDebug(self.displayableBodyText);
    }

    if (self.hasBodyText && message.linkPreview) {
        self.linkPreview = message.linkPreview;
        if (message.linkPreview.imageAttachmentId && message.linkPreview.imageAttachmentId.length > 0) {
            TSAttachment *_Nullable linkPreviewAttachment =
                [TSAttachment fetchObjectWithUniqueID:message.linkPreview.imageAttachmentId transaction:transaction];
            if (!linkPreviewAttachment) {
                OWSFailDebug(@"Could not load link preview image attachment.");
            } else if (!linkPreviewAttachment.isImage) {
                OWSFailDebug(@"Link preview attachment isn't an image.");
            } else if ([linkPreviewAttachment isKindOfClass:[TSAttachmentStream class]]) {
                TSAttachmentStream *attachmentStream = (TSAttachmentStream *)linkPreviewAttachment;
                if (!attachmentStream.isValidImage) {
                    OWSFailDebug(@"Link preview image attachment isn't valid.");
                } else {
                    self.linkPreviewAttachment = linkPreviewAttachment;
                }
            } else {
                self.linkPreviewAttachment = linkPreviewAttachment;
            }
        }
    }

    if (self.messageCellType == OWSMessageCellType_Unknown) {
        // Messages of unknown type (including messages with missing attachments)
        // are rendered like empty text messages, but without any interactivity.
        OWSLogWarn(@"Treating unknown message as empty text message: %@ %llu", message.class, message.timestamp);
        self.messageCellType = OWSMessageCellType_TextOnlyMessage;
        self.displayableBodyText = [[DisplayableText alloc] initWithFullText:@"" displayText:@"" isTextTruncated:NO];
    }
}

- (NSArray<ConversationMediaAlbumItem *> *)albumItemsForMediaAttachments:(NSArray<TSAttachment *> *)attachments
{
    OWSAssertIsOnMainThread();

    NSMutableArray<ConversationMediaAlbumItem *> *mediaAlbumItems = [NSMutableArray new];
    for (TSAttachment *attachment in attachments) {
        if (!attachment.isVisualMedia) {
            // Well behaving clients should not send a mix of visual media (like JPG) and non-visual media (like PDF's)
            // Since we're not coped to handle a mix of media, return @[]
            OWSAssertDebug(mediaAlbumItems.count == 0);
            return @[];
        }

        NSString *_Nullable caption = (attachment.caption
                ? [self displayableCaptionForText:attachment.caption attachmentId:attachment.uniqueId].displayText
                : nil);

        if (![attachment isKindOfClass:[TSAttachmentStream class]]) {
            TSAttachmentPointer *attachmentPointer = (TSAttachmentPointer *)attachment;
            CGSize mediaSize = CGSizeZero;
            if (attachmentPointer.mediaSize.width > 0 && attachmentPointer.mediaSize.height > 0) {
                mediaSize = attachmentPointer.mediaSize;
            }
            [mediaAlbumItems addObject:[[ConversationMediaAlbumItem alloc] initWithAttachment:attachment
                                                                             attachmentStream:nil
                                                                                      caption:caption
                                                                                    mediaSize:mediaSize]];
            continue;
        }
        TSAttachmentStream *attachmentStream = (TSAttachmentStream *)attachment;
        if (![attachmentStream isValidVisualMedia]) {
            OWSLogWarn(@"Filtering invalid media.");
            [mediaAlbumItems addObject:[[ConversationMediaAlbumItem alloc] initWithAttachment:attachment
                                                                             attachmentStream:nil
                                                                                      caption:caption
                                                                                    mediaSize:CGSizeZero]];
            continue;
        }
        CGSize mediaSize = [attachmentStream imageSize];
        if (mediaSize.width <= 0 || mediaSize.height <= 0) {
            OWSLogWarn(@"Filtering media with invalid size.");
            [mediaAlbumItems addObject:[[ConversationMediaAlbumItem alloc] initWithAttachment:attachment
                                                                             attachmentStream:nil
                                                                                      caption:caption
                                                                                    mediaSize:CGSizeZero]];
            continue;
        }

        ConversationMediaAlbumItem *mediaAlbumItem =
            [[ConversationMediaAlbumItem alloc] initWithAttachment:attachment
                                                  attachmentStream:attachmentStream
                                                           caption:caption
                                                         mediaSize:mediaSize];
        [mediaAlbumItems addObject:mediaAlbumItem];
    }
    return mediaAlbumItems;
}

- (NSString *)systemMessageTextWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertDebug(transaction);

    switch (self.interaction.interactionType) {
        case OWSInteractionType_Error: {
            TSErrorMessage *errorMessage = (TSErrorMessage *)self.interaction;
            return [errorMessage previewTextWithTransaction:transaction];
        }
        case OWSInteractionType_Info: {
            TSInfoMessage *infoMessage = (TSInfoMessage *)self.interaction;
            if ([infoMessage isKindOfClass:[OWSVerificationStateChangeMessage class]]) {
                OWSVerificationStateChangeMessage *verificationMessage
                    = (OWSVerificationStateChangeMessage *)infoMessage;
                BOOL isVerified = verificationMessage.verificationState == OWSVerificationStateVerified;
                NSString *displayName =
                    [Environment.shared.contactsManager displayNameForPhoneIdentifier:verificationMessage.recipientId];
                NSString *titleFormat = (isVerified
                        ? (verificationMessage.isLocalChange
                                  ? NSLocalizedString(@"VERIFICATION_STATE_CHANGE_FORMAT_VERIFIED_LOCAL",
                                        @"Format for info message indicating that the verification state was verified "
                                        @"on "
                                        @"this device. Embeds {{user's name or phone number}}.")
                                  : NSLocalizedString(@"VERIFICATION_STATE_CHANGE_FORMAT_VERIFIED_OTHER_DEVICE",
                                        @"Format for info message indicating that the verification state was verified "
                                        @"on "
                                        @"another device. Embeds {{user's name or phone number}}."))
                        : (verificationMessage.isLocalChange
                                  ? NSLocalizedString(@"VERIFICATION_STATE_CHANGE_FORMAT_NOT_VERIFIED_LOCAL",
                                        @"Format for info message indicating that the verification state was "
                                        @"unverified on "
                                        @"this device. Embeds {{user's name or phone number}}.")
                                  : NSLocalizedString(@"VERIFICATION_STATE_CHANGE_FORMAT_NOT_VERIFIED_OTHER_DEVICE",
                                        @"Format for info message indicating that the verification state was "
                                        @"unverified on "
                                        @"another device. Embeds {{user's name or phone number}}.")));
                return [NSString stringWithFormat:titleFormat, displayName];
            } else {
                return [infoMessage previewTextWithTransaction:transaction];
            }
        }
        case OWSInteractionType_Call: {
            TSCall *call = (TSCall *)self.interaction;
            return [call previewTextWithTransaction:transaction];
        }
        default:
            OWSFailDebug(@"not a system message.");
            return nil;
    }
}

- (nullable NSString *)quotedAttachmentMimetype
{
    return self.quotedReply.contentType;
}

- (nullable NSString *)quotedRecipientId
{
    return self.quotedReply.authorId;
}

- (OWSMessageCellType)messageCellType
{
    OWSAssertIsOnMainThread();

    return _messageCellType;
}

- (nullable DisplayableText *)displayableBodyText
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(self.hasViewState);

    OWSAssertDebug(_displayableBodyText);
    OWSAssertDebug(_displayableBodyText.displayText);
    OWSAssertDebug(_displayableBodyText.fullText);

    return _displayableBodyText;
}

- (nullable TSAttachmentStream *)attachmentStream
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(self.hasViewState);

    return _attachmentStream;
}

- (nullable TSAttachmentPointer *)attachmentPointer
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(self.hasViewState);

    return _attachmentPointer;
}

- (nullable DisplayableText *)displayableQuotedText
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(self.hasViewState);

    OWSAssertDebug(_displayableQuotedText);
    OWSAssertDebug(_displayableQuotedText.displayText);
    OWSAssertDebug(_displayableQuotedText.fullText);

    return _displayableQuotedText;
}

- (void)copyTextAction
{
    if (self.attachmentPointer != nil) {
        OWSFailDebug(@"Can't copy not-yet-downloaded attachment");
        return;
    }

    switch (self.messageCellType) {
        case OWSMessageCellType_TextOnlyMessage:
        case OWSMessageCellType_Audio:
        case OWSMessageCellType_MediaMessage:
        case OWSMessageCellType_GenericAttachment: {
            OWSAssertDebug(self.displayableBodyText);
            [UIPasteboard.generalPasteboard setString:self.displayableBodyText.fullText];
            break;
        }
        case OWSMessageCellType_Unknown: {
            OWSFailDebug(@"No text to copy");
            break;
        }
        case OWSMessageCellType_ContactShare: {
            // TODO: Implement copy contact.
            OWSFailDebug(@"Not implemented yet");
            break;
        }
        case OWSMessageCellType_OversizeTextDownloading:
            OWSFailDebug(@"Can't copy not-yet-downloaded attachment");
            return;
    }
}

- (void)copyMediaAction
{
    if (self.attachmentPointer != nil) {
        OWSFailDebug(@"Can't copy not-yet-downloaded attachment");
        return;
    }

    switch (self.messageCellType) {
        case OWSMessageCellType_Unknown:
        case OWSMessageCellType_TextOnlyMessage:
        case OWSMessageCellType_ContactShare: {
            OWSFailDebug(@"No media to copy");
            break;
        }
        case OWSMessageCellType_Audio:
        case OWSMessageCellType_GenericAttachment: {
            [self copyAttachmentToPasteboard:self.attachmentStream];
            break;
        }
        case OWSMessageCellType_MediaMessage: {
            if (self.mediaAlbumItems.count == 1) {
                ConversationMediaAlbumItem *mediaAlbumItem = self.mediaAlbumItems.firstObject;
                if (mediaAlbumItem.attachmentStream && mediaAlbumItem.attachmentStream.isValidVisualMedia) {
                    [self copyAttachmentToPasteboard:mediaAlbumItem.attachmentStream];
                    return;
                }
            }

            OWSFailDebug(@"Can't copy media album");
            break;
        }
        case OWSMessageCellType_OversizeTextDownloading:
            OWSFailDebug(@"Can't copy not-yet-downloaded attachment");
            return;
    }
}

- (void)copyAttachmentToPasteboard:(TSAttachmentStream *)attachment
{
    OWSAssertDebug(attachment);

    NSString *utiType = [MIMETypeUtil utiTypeForMIMEType:attachment.contentType];
    if (!utiType) {
        OWSFailDebug(@"Unknown MIME type: %@", attachment.contentType);
        utiType = (NSString *)kUTTypeGIF;
    }
    NSData *data = [NSData dataWithContentsOfURL:[attachment originalMediaURL]];
    if (!data) {
        OWSFailDebug(@"Could not load attachment data");
        return;
    }
    [UIPasteboard.generalPasteboard setData:data forPasteboardType:utiType];
}

- (void)shareMediaAction
{
    if (self.attachmentPointer != nil) {
        OWSFailDebug(@"Can't share not-yet-downloaded attachment");
        return;
    }

    switch (self.messageCellType) {
        case OWSMessageCellType_Unknown:
        case OWSMessageCellType_TextOnlyMessage:
        case OWSMessageCellType_ContactShare:
            OWSFailDebug(@"No media to share.");
            break;
        case OWSMessageCellType_Audio:
        case OWSMessageCellType_GenericAttachment:
            [AttachmentSharing showShareUIForAttachment:self.attachmentStream];
            break;
        case OWSMessageCellType_MediaMessage: {
            // TODO: We need a "canShareMediaAction" method.
            OWSAssertDebug(self.mediaAlbumItems);
            NSMutableArray<TSAttachmentStream *> *attachmentStreams = [NSMutableArray new];
            for (ConversationMediaAlbumItem *mediaAlbumItem in self.mediaAlbumItems) {
                if (mediaAlbumItem.attachmentStream && mediaAlbumItem.attachmentStream.isValidVisualMedia) {
                    [attachmentStreams addObject:mediaAlbumItem.attachmentStream];
                }
            }
            if (attachmentStreams.count < 1) {
                OWSFailDebug(@"Can't share media album; no valid items.");
                return;
            }
            [AttachmentSharing showShareUIForAttachments:attachmentStreams completion:nil];
            break;
        }
        case OWSMessageCellType_OversizeTextDownloading:
            OWSFailDebug(@"Can't share not-yet-downloaded attachment");
            return;
    }
}

- (BOOL)canCopyMedia
{
    if (self.attachmentPointer != nil) {
        // The attachment is still downloading.
        return NO;
    }

    switch (self.messageCellType) {
        case OWSMessageCellType_Unknown:
        case OWSMessageCellType_TextOnlyMessage:
        case OWSMessageCellType_ContactShare:
            return NO;
        case OWSMessageCellType_Audio:
            return NO;
        case OWSMessageCellType_GenericAttachment:
        case OWSMessageCellType_MediaMessage: {
            if (self.mediaAlbumItems.count == 1) {
                ConversationMediaAlbumItem *mediaAlbumItem = self.mediaAlbumItems.firstObject;
                if (mediaAlbumItem.attachmentStream && mediaAlbumItem.attachmentStream.isValidVisualMedia) {
                    return YES;
                }
            }
            return NO;
        }
        case OWSMessageCellType_OversizeTextDownloading:
            return NO;
    }
}

- (BOOL)canSaveMedia
{
    if (self.attachmentPointer != nil) {
        // The attachment is still downloading.
        return NO;
    }

    switch (self.messageCellType) {
        case OWSMessageCellType_Unknown:
        case OWSMessageCellType_TextOnlyMessage:
        case OWSMessageCellType_ContactShare:
            return NO;
        case OWSMessageCellType_Audio:
            return NO;
        case OWSMessageCellType_GenericAttachment:
            return NO;
        case OWSMessageCellType_MediaMessage: {
            for (ConversationMediaAlbumItem *mediaAlbumItem in self.mediaAlbumItems) {
                if (!mediaAlbumItem.attachmentStream) {
                    continue;
                }
                if (!mediaAlbumItem.attachmentStream.isValidVisualMedia) {
                    continue;
                }
                if (mediaAlbumItem.attachmentStream.isImage || mediaAlbumItem.attachmentStream.isAnimated) {
                    return YES;
                }
                if (mediaAlbumItem.attachmentStream.isVideo) {
                    if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(
                            mediaAlbumItem.attachmentStream.originalFilePath)) {
                        return YES;
                    }
                }
            }
            return NO;
        }
        case OWSMessageCellType_OversizeTextDownloading:
            return NO;
    }
}

- (void)saveMediaAction
{
    if (self.attachmentPointer != nil) {
        OWSFailDebug(@"Can't save not-yet-downloaded attachment");
        return;
    }
    switch (self.messageCellType) {
        case OWSMessageCellType_Unknown:
        case OWSMessageCellType_TextOnlyMessage:
        case OWSMessageCellType_ContactShare:
            OWSFailDebug(@"Cannot save text data.");
            break;
        case OWSMessageCellType_Audio:
            OWSFailDebug(@"Cannot save media data.");
            break;
        case OWSMessageCellType_GenericAttachment:
            OWSFailDebug(@"Cannot save media data.");
            break;
        case OWSMessageCellType_MediaMessage: {
            [self saveMediaAlbumItems];
            break;
        }
        case OWSMessageCellType_OversizeTextDownloading:
            OWSFailDebug(@"Can't save not-yet-downloaded attachment");
            return;
    }
}

- (void)saveMediaAlbumItems
{
    // We need to do these writes serially to avoid "write busy" errors
    // from too many concurrent asset saves.
    [self saveMediaAlbumItems:[self.mediaAlbumItems mutableCopy]];
}

- (void)saveMediaAlbumItems:(NSMutableArray<ConversationMediaAlbumItem *> *)mediaAlbumItems
{
    if (mediaAlbumItems.count < 1) {
        return;
    }
    ConversationMediaAlbumItem *mediaAlbumItem = mediaAlbumItems.firstObject;
    [mediaAlbumItems removeObjectAtIndex:0];

    if (!mediaAlbumItem.attachmentStream || !mediaAlbumItem.attachmentStream.isValidVisualMedia) {
        // Skip this item.
    } else if (mediaAlbumItem.attachmentStream.isImage || mediaAlbumItem.attachmentStream.isAnimated) {
        [[PHPhotoLibrary sharedPhotoLibrary]
            performChanges:^{
                [PHAssetChangeRequest
                    creationRequestForAssetFromImageAtFileURL:mediaAlbumItem.attachmentStream.originalMediaURL];
            }
            completionHandler:^(BOOL success, NSError *error) {
                if (error || !success) {
                    OWSFailDebug(@"Image save failed: %@", error);
                }
                [self saveMediaAlbumItems:mediaAlbumItems];
            }];
        return;
    } else if (mediaAlbumItem.attachmentStream.isVideo) {
        [[PHPhotoLibrary sharedPhotoLibrary]
            performChanges:^{
                [PHAssetChangeRequest
                    creationRequestForAssetFromVideoAtFileURL:mediaAlbumItem.attachmentStream.originalMediaURL];
            }
            completionHandler:^(BOOL success, NSError *error) {
                if (error || !success) {
                    OWSFailDebug(@"Video save failed: %@", error);
                }
                [self saveMediaAlbumItems:mediaAlbumItems];
            }];
        return;
    }
    return [self saveMediaAlbumItems:mediaAlbumItems];
}

- (void)deleteAction
{
    [self.interaction remove];
    
    if (self.isGroupThread) {
        // Skip if the thread is an RSS feed
        TSGroupThread *groupThread = (TSGroupThread *)self.interaction.thread;
        if (groupThread.isRSSFeed) return;
        
        // Only allow deletion on incoming and outgoing messages
        OWSInteractionType interationType = self.interaction.interactionType;
        if (interationType != OWSInteractionType_IncomingMessage && interationType != OWSInteractionType_OutgoingMessage) return;
        
        // Make sure it's a public chat message
        TSMessage *message = (TSMessage *)self.interaction;
        if (!message.isOpenGroupMessage) return;
        
        __block LKPublicChat *publicChat;
        [self.primaryStorage.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            publicChat = [LKDatabaseUtilities getPublicChatForThreadID:groupThread.uniqueId transaction: transaction];
        }];
        if (publicChat == nil) return;
        
        // Delete the message
        BOOL isSentByUser = (interationType == OWSInteractionType_OutgoingMessage);
        [[LKPublicChatAPI deleteMessageWithID:message.openGroupServerMessageID forGroup:publicChat.channel onServer:publicChat.server isSentByUser:isSentByUser].catch(^(NSError *error) {
            // Roll back
            [self.interaction save];
        }) retainUntilComplete];
    }
}

- (BOOL)hasBodyTextActionContent
{
    return self.hasBodyText && self.displayableBodyText.fullText.length > 0;
}

- (BOOL)hasMediaActionContent
{
    if (self.attachmentPointer != nil) {
        // The attachment is still downloading.
        return NO;
    }

    switch (self.messageCellType) {
        case OWSMessageCellType_Unknown:
        case OWSMessageCellType_TextOnlyMessage:
        case OWSMessageCellType_ContactShare:
            return NO;
        case OWSMessageCellType_Audio:
        case OWSMessageCellType_GenericAttachment:
            return self.attachmentStream != nil;
        case OWSMessageCellType_MediaMessage:
            return self.firstValidAlbumAttachment != nil;
        case OWSMessageCellType_OversizeTextDownloading:
            return NO;
    }
}

- (BOOL)mediaAlbumHasFailedAttachment
{
    OWSAssertDebug(self.messageCellType == OWSMessageCellType_MediaMessage);
    OWSAssertDebug(self.mediaAlbumItems.count > 0);

    for (ConversationMediaAlbumItem *mediaAlbumItem in self.mediaAlbumItems) {
        if (mediaAlbumItem.isFailedDownload) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)userHexEncodedPublicKey {
    return OWSIdentityManager.sharedManager.identityKeyPair.hexEncodedPublicKey;
}

- (BOOL)userCanDeleteGroupMessage
{
    if (!self.isGroupThread) return false;
    
    // Ensure the thread is a public chat and not an RSS feed
    TSGroupThread *groupThread = (TSGroupThread *)self.interaction.thread;
    if (groupThread.isRSSFeed) return false;
    
    // Only allow deletion on incoming and outgoing messages
    OWSInteractionType interationType = self.interaction.interactionType;
    if (interationType != OWSInteractionType_OutgoingMessage && interationType != OWSInteractionType_IncomingMessage) return false;
    
    // Make sure it's a public chat message
    TSMessage *message = (TSMessage *)self.interaction;
    if (!message.isOpenGroupMessage) return true;
    
    // Ensure we have the details needed to contact the server
    __block LKPublicChat *publicChat;
    [self.primaryStorage.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        publicChat = [LKDatabaseUtilities getPublicChatForThreadID:groupThread.uniqueId transaction: transaction];
    }];
    if (publicChat == nil) return true;
    
    if (interationType == OWSInteractionType_IncomingMessage) {
        // Only allow deletion on incoming messages if the user has moderation permission
        return [LKPublicChatAPI isUserModerator:self.userHexEncodedPublicKey forChannel:publicChat.channel onServer:publicChat.server];
    } else {
        // Only allow deletion on outgoing messages if the user was the sender (i.e. it was not sent from another linked device)
        return [self.interaction.actualSenderHexEncodedPublicKey isEqual:self.userHexEncodedPublicKey];
    }
}

@end

NS_ASSUME_NONNULL_END
