import '../models/im_dynamic_models.dart';

enum ImDynamicEditorTemplate {
  progressControls,
  survey,
  readReceipt,
  confirmation,
  blank,
}

extension ImDynamicEditorTemplateLabel on ImDynamicEditorTemplate {
  String get label => switch (this) {
    ImDynamicEditorTemplate.progressControls => 'Progress controls',
    ImDynamicEditorTemplate.survey => 'Survey / vote',
    ImDynamicEditorTemplate.readReceipt => 'Notice + read receipt',
    ImDynamicEditorTemplate.confirmation => 'Confirm / reject',
    ImDynamicEditorTemplate.blank => 'Blank layout',
  };

  String get description => switch (this) {
    ImDynamicEditorTemplate.progressControls =>
      'Buttons increase and decrease a shared progress value.',
    ImDynamicEditorTemplate.survey =>
      'Each member chooses an option and the result is recorded.',
    ImDynamicEditorTemplate.readReceipt =>
      'Members acknowledge a notice and completion is tracked.',
    ImDynamicEditorTemplate.confirmation =>
      'Collect a confirm or reject decision with a visible status.',
    ImDynamicEditorTemplate.blank =>
      'Start with an empty column and add your own components.',
  };
}

class ImDynamicEditorTemplates {
  const ImDynamicEditorTemplates._();

  static ImDynamicContent build({
    required ImDynamicEditorTemplate template,
    required String contentId,
  }) {
    final content = switch (template) {
      ImDynamicEditorTemplate.progressControls => _progressControls(contentId),
      ImDynamicEditorTemplate.survey => _survey(contentId),
      ImDynamicEditorTemplate.readReceipt => _readReceipt(contentId),
      ImDynamicEditorTemplate.confirmation => _confirmation(contentId),
      ImDynamicEditorTemplate.blank => _blank(contentId),
    };
    return content;
  }

  static ImDynamicContent _progressControls(String id) => ImDynamicContent(
    id: id,
    version: '1.0',
    source: ImDynamicContentSource.user,
    tree: const ImDynamicNode(
      id: 'root',
      type: 'column',
      props: {'spacing': 10.0},
      children: [
        ImDynamicNode(
          id: 'title',
          type: 'text',
          props: {'text': 'Adjust progress'},
        ),
        ImDynamicNode(
          id: 'progress',
          type: 'progress',
          props: {'value': 0.5, 'text': '50%'},
        ),
        ImDynamicNode(
          id: 'controls',
          type: 'row',
          props: {'spacing': 8.0, 'wrap': true},
          children: [
            ImDynamicNode(
              id: 'decrease',
              type: 'button',
              props: {'text': '-10%'},
              events: {
                'click': {
                  'action': 'adjust_progress',
                  'projection': {
                    'progress_delta': -0.1,
                    'progress_node_id': 'progress',
                  },
                },
              },
            ),
            ImDynamicNode(
              id: 'increase',
              type: 'button',
              props: {'text': '+10%'},
              events: {
                'click': {
                  'action': 'adjust_progress',
                  'projection': {
                    'progress_delta': 0.1,
                    'progress_node_id': 'progress',
                  },
                },
              },
            ),
          ],
        ),
      ],
    ),
    fallback: const ImDynamicFallback(type: 'text', content: 'Adjust progress'),
    metadata: const {
      'created_by': 'dynamic_creator_panel',
      'template': 'progress_controls',
      'interaction': {
        'reducer': 'none',
        'policy': {
          'response': 'many',
          'visibility': 'public_detail',
          'allow_change': true,
        },
        'routing': {'fairy': 'each_event'},
        'projection': {'progress_node_id': 'progress'},
      },
    },
  );

  static ImDynamicContent _survey(String id) => ImDynamicContent(
    id: id,
    version: '1.0',
    source: ImDynamicContentSource.user,
    tree: const ImDynamicNode(
      id: 'root',
      type: 'column',
      props: {'spacing': 10.0},
      children: [
        ImDynamicNode(
          id: 'question',
          type: 'text',
          props: {'text': 'Which option do you prefer?'},
        ),
        ImDynamicNode(
          id: 'choices',
          type: 'row',
          props: {'spacing': 8.0, 'wrap': true},
          children: [
            ImDynamicNode(
              id: 'option-a',
              type: 'button',
              props: {'text': 'Option A'},
              events: {
                'click': {
                  'action': 'option_a',
                  'projection': {
                    'progress_node_id': 'participation',
                    'total': 1,
                  },
                },
              },
            ),
            ImDynamicNode(
              id: 'option-b',
              type: 'button',
              props: {'text': 'Option B'},
              events: {
                'click': {
                  'action': 'option_b',
                  'projection': {
                    'progress_node_id': 'participation',
                    'total': 1,
                  },
                },
              },
            ),
          ],
        ),
        ImDynamicNode(
          id: 'participation',
          type: 'progress',
          props: {'value': 0.0, 'text': 'No responses yet'},
        ),
      ],
    ),
    fallback: const ImDynamicFallback(type: 'text', content: 'Survey'),
    metadata: const {
      'created_by': 'dynamic_creator_panel',
      'template': 'survey',
      'interaction': {
        'reducer': 'set_by_actor',
        'policy': {
          'response': 'once',
          'visibility': 'public_aggregate',
          'allow_change': true,
        },
        'routing': {'fairy': 'each_event'},
        'projection': {
          'progress_node_id': 'participation',
          'progress_text': '%d / %d responded',
        },
      },
    },
  );

  static ImDynamicContent _readReceipt(String id) => ImDynamicContent(
    id: id,
    version: '1.0',
    source: ImDynamicContentSource.user,
    tree: const ImDynamicNode(
      id: 'root',
      type: 'column',
      props: {'spacing': 10.0},
      children: [
        ImDynamicNode(
          id: 'notice',
          type: 'markdown',
          props: {'content': '**Team notice**\n\nPlease read this update.'},
        ),
        ImDynamicNode(
          id: 'read-progress',
          type: 'progress',
          props: {'value': 0.0, 'text': '0 read'},
        ),
        ImDynamicNode(
          id: 'mark-read',
          type: 'button',
          props: {'text': 'Mark as read'},
          events: {
            'click': {
              'action': 'acknowledge',
              'projection': {'progress_node_id': 'read-progress', 'total': 1},
            },
          },
        ),
      ],
    ),
    fallback: const ImDynamicFallback(type: 'text', content: 'Team notice'),
    metadata: const {
      'created_by': 'dynamic_creator_panel',
      'template': 'read_receipt',
      'interaction': {
        'reducer': 'set_by_actor',
        'policy': {
          'response': 'once',
          'visibility': 'public_aggregate',
          'allow_change': false,
        },
        'routing': {'fairy': 'each_event'},
        'projection': {
          'progress_node_id': 'read-progress',
          'progress_text': '%d / %d read',
        },
      },
    },
  );

  static ImDynamicContent _confirmation(String id) => ImDynamicContent(
    id: id,
    version: '1.0',
    source: ImDynamicContentSource.user,
    tree: const ImDynamicNode(
      id: 'root',
      type: 'column',
      props: {'spacing': 10.0},
      children: [
        ImDynamicNode(
          id: 'request',
          type: 'markdown',
          props: {
            'content': '**Confirmation required**\n\nReview the request.',
          },
        ),
        ImDynamicNode(
          id: 'decision-status',
          type: 'status',
          props: {'text': 'Pending'},
        ),
        ImDynamicNode(
          id: 'decision-progress',
          type: 'progress',
          props: {'value': 0.0, 'text': 'Waiting for responses'},
        ),
        ImDynamicNode(
          id: 'decisions',
          type: 'row',
          props: {'spacing': 8.0, 'wrap': true},
          children: [
            ImDynamicNode(
              id: 'confirm',
              type: 'button',
              props: {'text': 'Confirm'},
              events: {
                'click': {'action': 'confirm'},
              },
            ),
            ImDynamicNode(
              id: 'reject',
              type: 'button',
              props: {'text': 'Reject'},
              events: {
                'click': {'action': 'reject'},
              },
            ),
          ],
        ),
      ],
    ),
    fallback: const ImDynamicFallback(
      type: 'text',
      content: 'Confirmation required',
    ),
    metadata: const {
      'created_by': 'dynamic_creator_panel',
      'template': 'confirmation',
      'interaction': {
        'reducer': 'approval_quorum',
        'policy': {
          'response': 'once',
          'visibility': 'admin_detail',
          'allow_change': true,
          'veto': true,
        },
        'routing': {'fairy': 'each_event'},
        'projection': {
          'progress_node_id': 'decision-progress',
          'status_node_id': 'decision-status',
          'progress_text': '%d / %d responded',
        },
      },
    },
  );

  static ImDynamicContent _blank(String id) => ImDynamicContent(
    id: id,
    version: '1.0',
    source: ImDynamicContentSource.user,
    tree: const ImDynamicNode(
      id: 'root',
      type: 'column',
      props: {'spacing': 8.0},
      children: [
        ImDynamicNode(
          id: 'title',
          type: 'text',
          props: {'text': 'New interactive message'},
        ),
      ],
    ),
    fallback: const ImDynamicFallback(
      type: 'text',
      content: 'Interactive message',
    ),
    metadata: const {
      'created_by': 'dynamic_creator_panel',
      'template': 'blank',
    },
  );
}
