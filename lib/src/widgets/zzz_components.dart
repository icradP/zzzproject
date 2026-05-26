import 'package:flutter/material.dart';

import '../theme/zzz_colors.dart';

class ZzzPanel extends StatelessWidget {
  const ZzzPanel({
    required this.child,
    this.background,
    this.padding = const EdgeInsets.all(16),
    this.radius = 18,
    super.key,
  });

  final Widget child;
  final DecorationImage? background;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: ZzzColors.panel,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white12),
        image: background,
      ),
      child: child,
    );
  }
}

class ZzzSectionLabel extends StatelessWidget {
  const ZzzSectionLabel({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Colors.white24)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(label, style: const TextStyle(color: Colors.white54)),
          ),
          const Expanded(child: Divider(color: Colors.white24)),
        ],
      ),
    );
  }
}

class ZzzSegmentItem<T> {
  const ZzzSegmentItem({
    required this.value,
    required this.tooltip,
    this.icon,
    this.iconAsset,
    this.enabled = true,
  }) : assert(icon != null || iconAsset != null);

  final T value;
  final String tooltip;
  final IconData? icon;
  final String? iconAsset;
  final bool enabled;
}

class ZzzSegmentedControl<T> extends StatelessWidget {
  const ZzzSegmentedControl({
    required this.items,
    required this.value,
    required this.onChanged,
    this.animated = true,
    super.key,
  });

  final List<ZzzSegmentItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: _ZzzSegmentButton<T>(
                item: item,
                selected: item.value == value,
                animated: animated,
                onTap: item.enabled ? () => onChanged(item.value) : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _ZzzSegmentButton<T> extends StatelessWidget {
  const _ZzzSegmentButton({
    required this.item,
    required this.selected,
    required this.animated,
    required this.onTap,
  });

  final ZzzSegmentItem<T> item;
  final bool selected;
  final bool animated;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final foreground =
        item.enabled
            ? selected
                ? Colors.black
                : Colors.white
            : Colors.white24;

    return Tooltip(
      message: item.tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          height: 42,
          decoration: BoxDecoration(
            color: selected ? ZzzColors.yellow : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
            boxShadow:
                selected && animated
                    ? [
                      BoxShadow(
                        color: ZzzColors.yellow.withValues(alpha: 0.35),
                        blurRadius: 12,
                      ),
                    ]
                    : null,
          ),
          child: Center(
            child:
                item.iconAsset == null
                    ? Icon(item.icon, color: foreground)
                    : Image.asset(
                      item.iconAsset!,
                      height: 28,
                      color: foreground,
                    ),
          ),
        ),
      ),
    );
  }
}

class ZzzAvatar extends StatelessWidget {
  const ZzzAvatar({
    required this.image,
    required this.size,
    this.backgroundColor = Colors.white,
    super.key,
  });

  final ImageProvider image;
  final double size;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: backgroundColor,
      backgroundImage: image,
    );
  }
}

class ZzzPillButton extends StatelessWidget {
  const ZzzPillButton({
    required this.title,
    required this.onPressed,
    this.subtitle,
    this.leading,
    this.animated = true,
    this.backgroundColor = ZzzColors.yellow,
    this.foregroundColor = Colors.black,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final VoidCallback onPressed;
  final bool animated;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        padding: const EdgeInsets.all(8),
        minimumSize: const Size.fromHeight(66),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(36)),
        shadowColor: animated ? backgroundColor : Colors.transparent,
      ),
      onPressed: onPressed,
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foregroundColor.withValues(alpha: 0.48),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ZzzTextAction extends StatelessWidget {
  const ZzzTextAction({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white38,
        minimumSize: const Size.fromHeight(40),
      ),
    );
  }
}

class ZzzSelectableAvatar extends StatelessWidget {
  const ZzzSelectableAvatar({
    required this.image,
    required this.label,
    required this.selected,
    required this.onSelect,
    this.onRemove,
    this.size = 58,
    super.key,
  });

  final ImageProvider image;
  final String label;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback? onRemove;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 16,
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              InkWell(
                onTap: onSelect,
                customBorder: const CircleBorder(),
                child: Container(
                  padding: EdgeInsets.all(selected ? 4 : 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? ZzzColors.yellow : Colors.white24,
                  ),
                  child: ZzzAvatar(image: image, size: size),
                ),
              ),
              if (onRemove != null)
                Positioned(
                  top: -8,
                  right: -8,
                  child: IconButton.filled(
                    tooltip: 'Remove',
                    onPressed: onRemove,
                    style: IconButton.styleFrom(
                      backgroundColor: ZzzColors.red,
                      minimumSize: const Size(28, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.close_rounded, size: 16),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class ZzzTextInput extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      autofocus: autofocus,
      textInputAction: textInputAction,
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: prefixIcon,
        filled: true,
        fillColor: fillColor,
        hintStyle: TextStyle(color: foregroundColor.withValues(alpha: 0.45)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
      ),
      style: style ?? TextStyle(color: foregroundColor),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}

class ZzzSelectItem<T> {
  const ZzzSelectItem({required this.value, required this.label, this.leading});

  final T value;
  final String label;
  final Widget? leading;
}

class ZzzSelect<T> extends StatelessWidget {
  const ZzzSelect({
    required this.value,
    required this.items,
    required this.onChanged,
    this.labelText,
    super.key,
  });

  final T value;
  final List<ZzzSelectItem<T>> items;
  final ValueChanged<T> onChanged;
  final String? labelText;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      value: value,
      dropdownColor: ZzzColors.grayPanel,
      decoration: InputDecoration(
        isDense: true,
        labelText: labelText,
        border: const OutlineInputBorder(),
      ),
      items:
          items
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
        if (value != null) onChanged(value);
      },
    );
  }
}

class ZzzSwitchTile extends StatelessWidget {
  const ZzzSwitchTile({
    required this.value,
    required this.title,
    required this.onChanged,
    this.subtitle,
    super.key,
  });

  final bool value;
  final String title;
  final String? subtitle;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        value: value,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        activeColor: Colors.black,
        activeTrackColor: ZzzColors.yellow,
        onChanged: onChanged,
      ),
    );
  }
}

class ZzzFooterButton extends StatelessWidget {
  const ZzzFooterButton({required this.icon, super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      width: 46,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white24),
      ),
      child: Icon(icon),
    );
  }
}
