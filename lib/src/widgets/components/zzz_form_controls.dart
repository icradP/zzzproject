part of '../zzz_components.dart';

class ZzzTextInput extends StatefulWidget {
  const ZzzTextInput({
    this.controller,
    this.hintText,
    this.prefixIcon,
    this.minLines = 1,
    this.maxLines = 1,
    this.autofocus = false,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.style,
    this.fillColor = Colors.white,
    this.foregroundColor = Colors.black,
    super.key,
  });

  final TextEditingController? controller;
  final String? hintText;
  final Widget? prefixIcon;
  final int minLines;
  final int maxLines;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextStyle? style;
  final Color fillColor;
  final Color foregroundColor;

  @override
  State<ZzzTextInput> createState() => _ZzzTextInputState();
}

class _ZzzTextInputState extends State<ZzzTextInput> {
  late final FocusNode _focusNode;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus != _focused) {
        setState(() => _focused = _focusNode.hasFocus);
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: _kZzzAnimNormal,
      curve: _kZzzCurve,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow:
            _focused
                ? [
                  BoxShadow(
                    color: ZzzColors.yellow.withValues(alpha: 0.35),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
                : null,
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        autofocus: widget.autofocus,
        textInputAction: widget.textInputAction,
        decoration: InputDecoration(
          hintText: widget.hintText,
          prefixIcon: widget.prefixIcon,
          filled: true,
          fillColor: widget.fillColor,
          hintStyle: TextStyle(
            color: widget.foregroundColor.withValues(alpha: 0.45),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
        ),
        style: widget.style ?? TextStyle(color: widget.foregroundColor),
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
      ),
    );
  }
}

class ZzzSelectItem<T> {
  const ZzzSelectItem({required this.value, required this.label, this.leading});

  final T value;
  final String label;
  final Widget? leading;
}

class ZzzSelect<T> extends StatefulWidget {
  const ZzzSelect({
    required this.value,
    required this.items,
    required this.onChanged,
    this.labelText,
    this.animated = true,
    super.key,
  });

  final T value;
  final List<ZzzSelectItem<T>> items;
  final ValueChanged<T> onChanged;
  final String? labelText;
  final bool animated;

  @override
  State<ZzzSelect<T>> createState() => _ZzzSelectState<T>();
}

class _ZzzSelectState<T> extends State<ZzzSelect<T>> {
  late final FocusNode _focusNode;
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus != _focused) {
        setState(() => _focused = _focusNode.hasFocus);
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final highlighted = _focused || _hovered;
    final duration = _zzzDuration(widget.animated);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        duration: _kZzzAnimFast,
        curve: _kZzzCurve,
        scale: highlighted && widget.animated ? 1.01 : 1,
        child: AnimatedContainer(
          duration: duration,
          curve: _kZzzCurve,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            boxShadow:
                highlighted
                    ? [
                      BoxShadow(
                        color: ZzzColors.yellow.withValues(alpha: 0.18),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ]
                    : null,
          ),
          child: DropdownButtonFormField<T>(
            value: widget.value,
            focusNode: _focusNode,
            isExpanded: true,
            dropdownColor: ZzzColors.grayPanel,
            icon: AnimatedRotation(
              duration: duration,
              curve: _kZzzCurve,
              turns: _focused ? 0.5 : 0,
              child: const Icon(Icons.expand_more_rounded),
            ),
            decoration: InputDecoration(
              isDense: true,
              labelText: widget.labelText,
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(
                  color:
                      _hovered
                          ? ZzzColors.yellow.withValues(alpha: 0.38)
                          : Colors.white24,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(
                  color: ZzzColors.yellow.withValues(alpha: 0.75),
                  width: 2,
                ),
              ),
              border: const OutlineInputBorder(),
            ),
            items:
                widget.items
                    .map(
                      (item) => DropdownMenuItem<T>(
                        value: item.value,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (item.leading != null) ...[
                              item.leading!,
                              const SizedBox(width: 8),
                            ],
                            Flexible(child: Text(item.label)),
                          ],
                        ),
                      ),
                    )
                    .toList(),
            onChanged: (value) {
              if (value != null) widget.onChanged(value);
            },
          ),
        ),
      ),
    );
  }
}

class ZzzSwitchTile extends StatefulWidget {
  const ZzzSwitchTile({
    required this.value,
    required this.title,
    required this.onChanged,
    this.subtitle,
    this.animated = true,
    super.key,
  });

  final bool value;
  final String title;
  final String? subtitle;
  final ValueChanged<bool> onChanged;
  final bool animated;

  @override
  State<ZzzSwitchTile> createState() => _ZzzSwitchTileState();
}

class _ZzzSwitchTileState extends State<ZzzSwitchTile> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final duration = _zzzDuration(widget.animated);
    final highlighted = widget.value || _hovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedScale(
          duration: _kZzzAnimFast,
          curve: _kZzzCurve,
          scale: widget.animated && _pressed ? 0.985 : 1,
          child: AnimatedContainer(
            duration: duration,
            curve: _kZzzCurve,
            margin: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color:
                  widget.value
                      ? ZzzColors.yellow.withValues(alpha: 0.14)
                      : Colors.white.withValues(alpha: _hovered ? 0.1 : 0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color:
                    highlighted
                        ? ZzzColors.yellow.withValues(alpha: 0.35)
                        : Colors.white10,
              ),
              boxShadow:
                  widget.value && widget.animated
                      ? [
                        BoxShadow(
                          color: ZzzColors.yellow.withValues(alpha: 0.12),
                          blurRadius: 12,
                        ),
                      ]
                      : null,
            ),
            child: SwitchListTile(
              value: widget.value,
              title: Text(widget.title),
              subtitle: widget.subtitle == null ? null : Text(widget.subtitle!),
              activeColor: Colors.black,
              activeTrackColor: ZzzColors.yellow,
              onChanged: widget.onChanged,
            ),
          ),
        ),
      ),
    );
  }
}
