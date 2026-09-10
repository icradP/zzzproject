import 'package:flutter/material.dart';

import '../models/im_dynamic_models.dart';

typedef ImDynamicNodeBuilder =
    Widget Function(
      BuildContext context,
      ImDynamicNode node,
      ImDynamicRenderContext renderContext,
    );

typedef ImDynamicActionHandler =
    void Function(
      ImDynamicNode source,
      String event,
      Map<String, dynamic> definition,
      Map<String, dynamic> payload,
    );

int _dynamicEventSequence = 0;

String _newDynamicEventId() {
  final timestamp = DateTime.now().microsecondsSinceEpoch;
  final sequence = _dynamicEventSequence++;
  return 'dynamic-event-$timestamp-$sequence';
}

abstract class ImDynamicComponentRenderer {
  const ImDynamicComponentRenderer();

  String get type;

  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  );
}

class ImDynamicRenderContext {
  const ImDynamicRenderContext({
    required this.messageId,
    required this.contentId,
    required this.renderNode,
    this.onEvent,
    this.onAction,
    this.state = const <String, dynamic>{},
  });

  final String messageId;
  final String contentId;
  final Widget Function(BuildContext context, ImDynamicNode node) renderNode;
  final ValueChanged<ImDynamicEvent>? onEvent;
  final ImDynamicActionHandler? onAction;
  final Map<String, dynamic> state;

  void emit(
    ImDynamicNode node,
    String event, {
    Map<String, dynamic> payload = const <String, dynamic>{},
  }) {
    final definition = node.events[event];
    final action = definition?['action']?.toString();
    if (definition != null) {
      onAction?.call(node, event, definition, payload);
    }
    if (onEvent == null) return;
    onEvent!(
      ImDynamicEvent(
        messageId: messageId,
        contentId: contentId,
        nodeId: node.id,
        event: event,
        action: action,
        eventId: _newDynamicEventId(),
        payload: payload,
      ),
    );
  }
}

class ImDynamicComponentRegistry {
  ImDynamicComponentRegistry({
    Iterable<ImDynamicComponentRenderer> renderers = const [],
  }) {
    for (final renderer in renderers) {
      register(renderer);
    }
  }

  final Map<String, ImDynamicComponentRenderer> _renderers = {};

  void register(ImDynamicComponentRenderer renderer) {
    final key = renderer.type.trim();
    if (key.isEmpty) throw ArgumentError.value(renderer.type, 'type');
    _renderers[key] = renderer;
  }

  ImDynamicComponentRenderer? find(String type) => _renderers[type];

  Set<String> get types => Set.unmodifiable(_renderers.keys);

  factory ImDynamicComponentRegistry.standard() {
    return ImDynamicComponentRegistry(
      renderers: const [
        _TextRenderer(),
        _MarkdownRenderer(),
        _IconRenderer(),
        _ImageRenderer(),
        _RowRenderer(),
        _ColumnRenderer(),
        _CardRenderer(),
        _ContainerRenderer(),
        _DividerRenderer(),
        _ButtonRenderer(),
        _InputRenderer(),
        _CheckboxRenderer(),
        _SelectRenderer(),
        _ProgressRenderer(),
        _StatusRenderer(),
        _BadgeRenderer(),
      ],
    );
  }
}

class _TextRenderer extends ImDynamicComponentRenderer {
  const _TextRenderer();
  @override
  String get type => 'text';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    return Text(_dynamicText(node, 'text', 'content'));
  }
}

class _MarkdownRenderer extends ImDynamicComponentRenderer {
  const _MarkdownRenderer();
  @override
  String get type => 'markdown';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    final content = _dynamicText(node, 'content', 'text');
    if (node.props['collapsible'] == true) {
      return _ExpandableMarkdown(
        title: node.props['title']?.toString() ?? 'Details',
        content: content,
        initiallyExpanded: node.props['expanded'] == true,
      );
    }
    return _MarkdownDocument(content: content);
  }
}

class _IconRenderer extends ImDynamicComponentRenderer {
  const _IconRenderer();
  @override
  String get type => 'icon';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    final name = node.props['name']?.toString() ?? 'circle';
    return Icon(
      _icons[name] ?? Icons.circle_outlined,
      size: _number(node.props['size'], 18),
    );
  }
}

class _ImageRenderer extends ImDynamicComponentRenderer {
  const _ImageRenderer();
  @override
  String get type => 'image';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    final uri = Uri.tryParse(node.props['url']?.toString() ?? '');
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return const _UnsupportedNode(label: 'Invalid image URL');
    }
    return Image.network(
      uri.toString(),
      width: _optionalNumber(node.props['width']),
      height: _optionalNumber(node.props['height']),
      fit: BoxFit.cover,
      errorBuilder:
          (_, __, ___) => const _UnsupportedNode(label: 'Image unavailable'),
    );
  }
}

class _RowRenderer extends ImDynamicComponentRenderer {
  const _RowRenderer();
  @override
  String get type => 'row';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    final children =
        node.children
            .map((child) => renderContext.renderNode(context, child))
            .toList();
    final alignment = _mainAxisAlignment(node.props['mainAxisAlignment']);
    final crossAxisAlignment = _crossAxisAlignment(
      node.props['crossAxisAlignment'],
    );
    if (node.props['wrap'] == true) {
      return Wrap(
        spacing: _number(node.props['spacing'], 8),
        runSpacing: _number(node.props['runSpacing'], 8),
        alignment: _wrapAlignment(node.props['mainAxisAlignment']),
        crossAxisAlignment: _wrapCrossAlignment(
          node.props['crossAxisAlignment'],
        ),
        children: children,
      );
    }
    return Row(
      mainAxisSize: _mainAxisSize(node.props['mainAxisSize']),
      mainAxisAlignment: alignment,
      crossAxisAlignment: crossAxisAlignment,
      children: _withSpacing(context, node, renderContext, Axis.horizontal),
    );
  }
}

class _ColumnRenderer extends ImDynamicComponentRenderer {
  const _ColumnRenderer();
  @override
  String get type => 'column';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    return Column(
      mainAxisSize: _mainAxisSize(node.props['mainAxisSize']),
      mainAxisAlignment: _mainAxisAlignment(node.props['mainAxisAlignment']),
      crossAxisAlignment: _crossAxisAlignment(node.props['crossAxisAlignment']),
      children: _withSpacing(context, node, renderContext, Axis.vertical),
    );
  }
}

class _CardRenderer extends ImDynamicComponentRenderer {
  const _CardRenderer();
  @override
  String get type => 'card';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    return Container(
      padding: EdgeInsets.all(_number(node.props['padding'], 10)),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: _mainAxisSize(node.props['mainAxisSize']),
        mainAxisAlignment: _mainAxisAlignment(node.props['mainAxisAlignment']),
        crossAxisAlignment: _crossAxisAlignment(
          node.props['crossAxisAlignment'],
        ),
        children: _withSpacing(context, node, renderContext, Axis.vertical),
      ),
    );
  }
}

class _ContainerRenderer extends ImDynamicComponentRenderer {
  const _ContainerRenderer();
  @override
  String get type => 'container';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    return Container(
      padding: _padding(node.props['padding']),
      child: Column(
        mainAxisSize: _mainAxisSize(node.props['mainAxisSize']),
        mainAxisAlignment: _mainAxisAlignment(node.props['mainAxisAlignment']),
        crossAxisAlignment: _crossAxisAlignment(
          node.props['crossAxisAlignment'],
        ),
        children: _withSpacing(context, node, renderContext, Axis.vertical),
      ),
    );
  }
}

class _DividerRenderer extends ImDynamicComponentRenderer {
  const _DividerRenderer();
  @override
  String get type => 'divider';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) => const Divider(height: 16);
}

class _ButtonRenderer extends ImDynamicComponentRenderer {
  const _ButtonRenderer();
  @override
  String get type => 'button';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    final label = _dynamicText(node, 'text', 'label', 'Action');
    return FilledButton(
      onPressed:
          _isClosed(renderContext)
              ? null
              : node.events.containsKey('click') ||
                  node.events.containsKey('tap')
              ? () => renderContext.emit(
                node,
                node.events.containsKey('click') ? 'click' : 'tap',
              )
              : null,
      child: Text(label),
    );
  }
}

class _InputRenderer extends ImDynamicComponentRenderer {
  const _InputRenderer();
  @override
  String get type => 'input';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    return _DynamicInput(node: node, renderContext: renderContext);
  }
}

class _CheckboxRenderer extends ImDynamicComponentRenderer {
  const _CheckboxRenderer();
  @override
  String get type => 'checkbox';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    return _DynamicCheckbox(node: node, renderContext: renderContext);
  }
}

class _SelectRenderer extends ImDynamicComponentRenderer {
  const _SelectRenderer();
  @override
  String get type => 'select';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    final options = (node.props['options'] as List? ?? const [])
        .map((value) => value.toString())
        .toList(growable: false);
    if (options.isEmpty) return const SizedBox.shrink();
    final initial = node.props['value']?.toString();
    return _DynamicSelect(
      node: node,
      options: options,
      initialValue: options.contains(initial) ? initial! : options.first,
      renderContext: renderContext,
    );
  }
}

class _ProgressRenderer extends ImDynamicComponentRenderer {
  const _ProgressRenderer();
  @override
  String get type => 'progress';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    final value = _number(node.props['value'], 0).clamp(0.0, 1.0);
    final label = _dynamicText(node, 'text');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: value),
        if (label.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _StatusRenderer extends ImDynamicComponentRenderer {
  const _StatusRenderer();
  @override
  String get type => 'status';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    final text = _dynamicText(node, 'text', 'label');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.circle, size: 8),
        const SizedBox(width: 6),
        Text(text),
      ],
    );
  }
}

class _BadgeRenderer extends ImDynamicComponentRenderer {
  const _BadgeRenderer();
  @override
  String get type => 'badge';
  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    return Chip(label: Text(_dynamicText(node, 'text', 'label')));
  }
}

String _dynamicText(
  ImDynamicNode node,
  String primary, [
  String? secondary,
  String fallback = '',
]) {
  final raw =
      node.props[primary] ??
      (secondary == null ? null : node.props[secondary]) ??
      fallback;
  final text = raw.toString();
  return text.replaceAllMapped(RegExp(r'\{\{([A-Za-z0-9_.-]+)\}\}'), (match) {
    final value = node.props[match.group(1)];
    return value == null ? match.group(0)! : value.toString();
  });
}

class _ExpandableMarkdown extends StatelessWidget {
  const _ExpandableMarkdown({
    required this.title,
    required this.content,
    required this.initiallyExpanded,
  });

  final String title;
  final String content;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: ExpansionTile(
      title: Text(title),
      initiallyExpanded: initiallyExpanded,
      tilePadding: const EdgeInsets.symmetric(horizontal: 10),
      childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      children: [_MarkdownDocument(content: content)],
    ),
  );
}

class _MarkdownDocument extends StatelessWidget {
  const _MarkdownDocument({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final blocks = _markdownBlocks(content);
    if (blocks.length == 1 && blocks.single.kind == _MarkdownBlockKind.text) {
      return SelectableText(blocks.single.value);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < blocks.length; index++) ...[
          if (index > 0) const SizedBox(height: 8),
          _MarkdownBlockView(block: blocks[index]),
        ],
      ],
    );
  }
}

enum _MarkdownBlockKind { text, code, table }

class _MarkdownBlock {
  const _MarkdownBlock(this.kind, this.value);

  final _MarkdownBlockKind kind;
  final String value;
}

class _MarkdownBlockView extends StatelessWidget {
  const _MarkdownBlockView({required this.block});

  final _MarkdownBlock block;

  @override
  Widget build(BuildContext context) {
    switch (block.kind) {
      case _MarkdownBlockKind.text:
        return SelectableText(block.value);
      case _MarkdownBlockKind.code:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              block.value,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        );
      case _MarkdownBlockKind.table:
        final rows = _parseMarkdownTable(block.value);
        if (rows.isEmpty) return const SizedBox.shrink();
        final columnCount = rows.fold<int>(
          0,
          (count, row) => row.length > count ? row.length : count,
        );
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: Theme.of(context).dividerColor),
            children: [
              for (final row in rows)
                TableRow(
                  children: [
                    for (var index = 0; index < columnCount; index++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: SelectableText(
                          index < row.length ? row[index] : '',
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
    }
  }
}

List<_MarkdownBlock> _markdownBlocks(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final blocks = <_MarkdownBlock>[];
  final text = <String>[];
  void flushText() {
    final value = text.join('\n').trim();
    if (value.isNotEmpty) {
      blocks.add(_MarkdownBlock(_MarkdownBlockKind.text, value));
    }
    text.clear();
  }
  var inCode = false;
  final code = <String>[];
  final table = <String>[];
  void flushTable() {
    if (table.isNotEmpty) {
      blocks.add(_MarkdownBlock(_MarkdownBlockKind.table, table.join('\n')));
      table.clear();
    }
  }

  for (final line in lines) {
    if (line.trimLeft().startsWith('```')) {
      if (inCode) {
        blocks.add(_MarkdownBlock(_MarkdownBlockKind.code, code.join('\n')));
        code.clear();
      } else {
        flushText();
        flushTable();
      }
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      code.add(line);
      continue;
    }
    if (line.contains('|')) {
      flushText();
      table.add(line);
    } else {
      flushTable();
      text.add(line);
    }
  }
  if (inCode && code.isNotEmpty) {
    blocks.add(_MarkdownBlock(_MarkdownBlockKind.code, code.join('\n')));
  }
  flushTable();
  flushText();
  return blocks.isEmpty
      ? const [_MarkdownBlock(_MarkdownBlockKind.text, '')]
      : blocks;
}

List<List<String>> _parseMarkdownTable(String source) {
  final rows = <List<String>>[];
  for (final line in source.split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.contains('|') ||
        RegExp(
          r'^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$',
        ).hasMatch(trimmed)) {
      continue;
    }
    final value = trimmed.startsWith('|') ? trimmed.substring(1) : trimmed;
    final withoutTrailing =
        value.endsWith('|') ? value.substring(0, value.length - 1) : value;
    rows.add(
      withoutTrailing
          .split('|')
          .map((cell) => cell.trim())
          .toList(growable: false),
    );
  }
  return rows;
}

class _DynamicInput extends StatefulWidget {
  const _DynamicInput({required this.node, required this.renderContext});
  final ImDynamicNode node;
  final ImDynamicRenderContext renderContext;
  @override
  State<_DynamicInput> createState() => _DynamicInputState();
}

class _DynamicInputState extends State<_DynamicInput> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.node.props['value']?.toString() ?? '',
  );

  @override
  void didUpdateWidget(covariant _DynamicInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldValue = oldWidget.node.props['value']?.toString() ?? '';
    final nextValue = widget.node.props['value']?.toString() ?? '';
    if (oldValue != nextValue && _controller.text != nextValue) {
      _controller.value = TextEditingValue(
        text: nextValue,
        selection: TextSelection.collapsed(offset: nextValue.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      enabled: !_isClosed(widget.renderContext),
      obscureText: widget.node.props['obscure'] == true,
      maxLines: widget.node.props['multiline'] == true ? 4 : 1,
      decoration: InputDecoration(
        labelText: widget.node.props['label']?.toString(),
        hintText: widget.node.props['placeholder']?.toString(),
        isDense: true,
      ),
      onSubmitted:
          widget.node.events.containsKey('submit')
              ? (_) => widget.renderContext.emit(
                widget.node,
                'submit',
                payload: {'value': _controller.text},
              )
              : null,
    );
  }
}

class _DynamicCheckbox extends StatefulWidget {
  const _DynamicCheckbox({required this.node, required this.renderContext});
  final ImDynamicNode node;
  final ImDynamicRenderContext renderContext;
  @override
  State<_DynamicCheckbox> createState() => _DynamicCheckboxState();
}

class _DynamicCheckboxState extends State<_DynamicCheckbox> {
  late bool _value = widget.node.props['value'] == true;

  @override
  void didUpdateWidget(covariant _DynamicCheckbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.props['value'] != widget.node.props['value'] &&
        widget.node.props['value'] is bool) {
      _value = widget.node.props['value'] as bool;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: _value,
      title: Text(widget.node.props['text']?.toString() ?? ''),
      onChanged:
          _isClosed(widget.renderContext) ||
                  !widget.node.events.containsKey('change')
              ? null
              : (value) {
                setState(() => _value = value ?? false);
                widget.renderContext.emit(
                  widget.node,
                  'change',
                  payload: {'value': _value},
                );
              },
    );
  }
}

class _DynamicSelect extends StatefulWidget {
  const _DynamicSelect({
    required this.node,
    required this.options,
    required this.initialValue,
    required this.renderContext,
  });
  final ImDynamicNode node;
  final List<String> options;
  final String initialValue;
  final ImDynamicRenderContext renderContext;
  @override
  State<_DynamicSelect> createState() => _DynamicSelectState();
}

class _DynamicSelectState extends State<_DynamicSelect> {
  late String _value = widget.initialValue;

  @override
  void didUpdateWidget(covariant _DynamicSelect oldWidget) {
    super.didUpdateWidget(oldWidget);
    final optionsChanged =
        oldWidget.options.length != widget.options.length ||
        oldWidget.options.asMap().entries.any(
          (entry) => entry.value != widget.options[entry.key],
        );
    if (optionsChanged || !widget.options.contains(_value)) {
      _value = widget.initialValue;
    } else if (oldWidget.initialValue != widget.initialValue &&
        widget.options.contains(widget.initialValue)) {
      _value = widget.initialValue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: _value,
      isDense: true,
      decoration: InputDecoration(
        labelText: widget.node.props['label']?.toString(),
      ),
      items:
          widget.options
              .map(
                (option) =>
                    DropdownMenuItem(value: option, child: Text(option)),
              )
              .toList(),
      onChanged:
          _isClosed(widget.renderContext) ||
                  !widget.node.events.containsKey('change')
              ? null
              : (value) {
                if (value == null) return;
                setState(() => _value = value);
                widget.renderContext.emit(
                  widget.node,
                  'change',
                  payload: {'value': value},
                );
              },
    );
  }
}

class _UnsupportedNode extends StatelessWidget {
  const _UnsupportedNode({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) =>
      Text(label, style: Theme.of(context).textTheme.bodySmall);
}

List<Widget> _withSpacing(
  BuildContext context,
  ImDynamicNode node,
  ImDynamicRenderContext renderContext,
  Axis axis,
) {
  final spacing = _number(node.props['spacing'], 6);
  final result = <Widget>[];
  for (var i = 0; i < node.children.length; i++) {
    if (i > 0 && spacing > 0) {
      result.add(
        axis == Axis.horizontal
            ? SizedBox(width: spacing)
            : SizedBox(height: spacing),
      );
    }
    result.add(renderContext.renderNode(context, node.children[i]));
  }
  return result;
}

EdgeInsets _padding(Object? value) {
  if (value is num) return EdgeInsets.all(_number(value, 0));
  if (value is Map) {
    return EdgeInsets.only(
      left: _number(value['left'], 0),
      top: _number(value['top'], 0),
      right: _number(value['right'], 0),
      bottom: _number(value['bottom'], 0),
    );
  }
  return EdgeInsets.zero;
}

MainAxisSize _mainAxisSize(Object? value) =>
    value?.toString() == 'max' ? MainAxisSize.max : MainAxisSize.min;

MainAxisAlignment _mainAxisAlignment(Object? value) => switch (value
    ?.toString()) {
  'center' => MainAxisAlignment.center,
  'end' => MainAxisAlignment.end,
  'spaceBetween' => MainAxisAlignment.spaceBetween,
  'spaceAround' => MainAxisAlignment.spaceAround,
  'spaceEvenly' => MainAxisAlignment.spaceEvenly,
  _ => MainAxisAlignment.start,
};

CrossAxisAlignment _crossAxisAlignment(Object? value) => switch (value
    ?.toString()) {
  'center' => CrossAxisAlignment.center,
  'end' => CrossAxisAlignment.end,
  'stretch' => CrossAxisAlignment.stretch,
  // Baseline alignment requires a TextBaseline on Row/Column and is not
  // exposed by the schema editor. Keep unknown legacy values safe.
  'baseline' => CrossAxisAlignment.start,
  _ => CrossAxisAlignment.start,
};

WrapAlignment _wrapAlignment(Object? value) => switch (value?.toString()) {
  'center' => WrapAlignment.center,
  'end' => WrapAlignment.end,
  'spaceBetween' => WrapAlignment.spaceBetween,
  'spaceAround' => WrapAlignment.spaceAround,
  'spaceEvenly' => WrapAlignment.spaceEvenly,
  _ => WrapAlignment.start,
};

WrapCrossAlignment _wrapCrossAlignment(Object? value) =>
    value?.toString() == 'end'
        ? WrapCrossAlignment.end
        : value?.toString() == 'start'
        ? WrapCrossAlignment.start
        : WrapCrossAlignment.center;

double _number(Object? value, double fallback) =>
    value is num ? value.toDouble().clamp(0, 1000) : fallback;
double? _optionalNumber(Object? value) =>
    value is num ? value.toDouble().clamp(0, 2000) : null;

bool _isClosed(ImDynamicRenderContext context) =>
    context.state['lifecycle'] == ImDynamicLifecycle.closed.name ||
    context.state['interaction_closed'] == true;

const _icons = <String, IconData>{
  'check': Icons.check,
  'close': Icons.close,
  'error': Icons.error_outline,
  'info': Icons.info_outline,
  'warning': Icons.warning_amber_outlined,
  'play': Icons.play_arrow,
  'refresh': Icons.refresh,
  'circle': Icons.circle_outlined,
};
