import 'dart:io';

import 'package:flutter/widgets.dart';

ImageProvider createFileImageProvider(String path) => FileImage(File(path));
