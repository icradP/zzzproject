import 'dart:io';

import 'package:flutter/widgets.dart';

Widget platformImageWidget(
  String path, {
  double? width,
  BoxFit? fit,
  ImageErrorWidgetBuilder? errorBuilder,
}) =>
    Image.file(
      File(path),
      width: width,
      fit: fit,
      errorBuilder: errorBuilder,
    );
