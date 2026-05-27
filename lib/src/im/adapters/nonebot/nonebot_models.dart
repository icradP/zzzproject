/// Re-exports OneBot protocol types from the standalone SDK package.
///
/// All protocol definitions now live in `package:onebot_flutter/onebot_flutter.dart`.
///
/// Prefer importing from `package:onebot_flutter/onebot_flutter.dart` directly.
library;

export 'package:onebot_flutter/onebot_flutter.dart'
    show
        OneBotConfig,
        OneBotConnectionStatus,
        OneBotSender,
        OneBotMessageSegment,
        OneBotPrivateMessageEvent,
        OneBotGroupMessageEvent,
        OneBotNoticeEvent,
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
        oneBotPlainText,
        oneBotChainToJson,
        oneBotChainFromJson;

