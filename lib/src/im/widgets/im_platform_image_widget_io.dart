import 'dart:io';

import 'package:flutter/widgets.dart';

Widget platformImageWidget(
  String path, {
  double? width,
  BoxFit? fit,
  ImageErrorWidgetBuilder? errorBuilder,
}) {
  final uri = Uri.tryParse(path);
  final isNetwork = uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
  if (isNetwork) {
    return Image.network(
      path,
      width: width,
      fit: fit,
      errorBuilder: errorBuilder,
    );
  }
  return Image.file(
    File(path),
    width: width,
    fit: fit,
    errorBuilder: errorBuilder,
  );
}
