import '../models/im_dynamic_command.dart';
import '../models/im_dynamic_models.dart';

/// Converts application/editor commands into the existing dynamic_update
/// protocol. The runtime remains unaware of transport and server concerns.
class ImDynamicCommandWireAdapter {
  const ImDynamicCommandWireAdapter();

  ImDynamicPatchSet toPatchSet(ImDynamicCommand command) {
    switch (command.operation) {
      case ImDynamicCommandOperation.update:
        final update = command.update;
        if (update == null) {
          throw const FormatException('Dynamic update command has no patches');
        }
        return update;
      case ImDynamicCommandOperation.replace:
        final content = command.content;
        if (content == null) {
          throw const FormatException('Dynamic replace command has no content');
        }
        return ImDynamicPatchSet(
          messageId: command.messageId,
          contentId: command.contentId,
          patches: [
            ImDynamicPatch(
              operation: ImDynamicPatchOperation.replace,
              nodeId: content.tree.id,
              node: content.tree,
            ),
          ],
        );
      case ImDynamicCommandOperation.create:
        throw UnsupportedError(
          'Create commands create a new message and are not dynamic_update patches.',
        );
      case ImDynamicCommandOperation.remove:
        throw UnsupportedError(
          'Removing a complete content requires a message-level protocol operation.',
        );
    }
  }
}
