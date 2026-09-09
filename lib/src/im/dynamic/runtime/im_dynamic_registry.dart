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
    return Text(
      node.props['text']?.toString() ?? node.props['content']?.toString() ?? '',
    );
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
    return SelectableText(
      node.props['content']?.toString() ?? node.props['text']?.toString() ?? '',
    );
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
    final label =
        node.props['text']?.toString() ??
        node.props['label']?.toString() ??
        'Action';
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
    final label = node.props['text']?.toString();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: value),
        if (label != null && label.isNotEmpty) ...[
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
    final text =
        node.props['text']?.toString() ?? node.props['label']?.toString() ?? '';
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
    return Chip(
      label: Text(
        node.props['text']?.toString() ?? node.props['label']?.toString() ?? '',
      ),
    );
  }
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
    context.state['lifecycle'] == ImDynamicLifecycle.closed.name;

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
