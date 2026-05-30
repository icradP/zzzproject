/// Re-exports OneBot model types directly from `onebot_models.dart`.
///
/// The barrel file `package:onebot_flutter/onebot_flutter.dart` also exports
/// `onebot_client.dart` which imports `dart:io` — so on web we bypass the
/// barrel and import the model types directly.
///
/// This exports the **same symbols** as `nonebot_models.dart` minus
/// `OneBotConnectionStatus` (defined in `onebot_client.dart`, not needed
/// on web).
library;

export 'package:onebot_flutter/src/onebot_models.dart'
    show
        OneBotConfig,
        OneBotSender,
        OneBotMessageSegment,
        OneBotPrivateMessageEvent,
        OneBotGroupMessageEvent,
        OneBotNoticeEvent,
        OneBotGroupUploadNotice,
        OneBotGroupAdminNotice,
        OneBotGroupDecreaseNotice,
        OneBotGroupIncreaseNotice,
        OneBotGroupBanNotice,
        OneBotFriendAddNotice,
        OneBotGroupRecallNotice,
        OneBotFriendRecallNotice,
        OneBotPokeNotice,
        OneBotLuckyKingNotice,
        OneBotHonorNotice,
        OneBotEmojiLikeNotice,
        OneBotEmojiLikeEntry,
        OneBotRequestEvent,
        OneBotMetaEvent,
        OneBotEvent,
        OneBotMessageEvent,
        OneBotNoticeEventWrapper,
        OneBotRequestEventWrapper,
        OneBotMetaEventWrapper,
        OneBotApiResponse,
        OneBotWsMode,
        OneBotPostType,
        OneBotNoticeType,
        OneBotAnonymous,
        OneBotFileInfo,
        OneBotLoginInfo,
        OneBotStrangerInfo,
        OneBotFriendInfo,
        OneBotGroupInfo,
        OneBotGroupMemberInfo,
        OneBotGroupHonorInfo,
        OneBotHonorUser,
        OneBotCredentials,
        OneBotVersionInfo,
        OneBotStatusInfo,
        OneBotFileResult,
        OneBotMsgResult,
        OneBotGetMsgResult,
        OneBotForwardResult,
        OneBotCanSendResult,
        OneBotPrivateMessageQuickOp,
        OneBotGroupMessageQuickOp,
        OneBotFriendRequestQuickOp,
        OneBotGroupRequestQuickOp,
        oneBotPlainText,
        oneBotChainToJson,
        oneBotChainFromJson,
        parseCqCode,
        segmentsToCqCode;
