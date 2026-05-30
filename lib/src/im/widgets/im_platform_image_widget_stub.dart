import 'package:flutter/widgets.dart';

/// On web, treat the path as a network URL or fall back.
Widget platformImageWidget(
  String path, {
  double? width,
  BoxFit? fit,
  ImageErrorWidgetBuilder? errorBuilder,
}) =>
    Image.network(
      path,
      width: width,
      fit: fit,
      errorBuilder: errorBuilder,
    );
