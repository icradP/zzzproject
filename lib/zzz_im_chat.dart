library;

// Expose the segment type used by ImMessage.segments to embedding clients.
export 'package:onebot_flutter/onebot_flutter.dart' show OneBotMessageSegment;

// Public surface for embedding the production ZZZ IM conversation component
// in sibling applications such as ZZZ Term.
export 'src/im/data/im_interaction_handler.dart';
export 'src/im/data/im_nsfw_checker.dart';
export 'src/im/data/im_nsfw_checker_stub.dart';
export 'src/im/data/im_push_manager.dart';
export 'src/im/data/mock_im_repository.dart';
export 'src/im/adapters/im_message_source.dart';
export 'src/im/adapters/source_repository.dart';
export 'src/im/adapters/zzz_server/zzz_server_source.dart';
export 'src/im/im_scope.dart';
export 'src/im/models/im_models.dart';
export 'src/im/content/im_content.dart';
export 'src/im/dynamic/im_dynamic.dart';
export 'src/im/data/im_dynamic_runtime_preferences.dart';
export 'src/im/widgets/im_chat_widgets.dart';
export 'src/im/widgets/im_chat_room_view.dart';
