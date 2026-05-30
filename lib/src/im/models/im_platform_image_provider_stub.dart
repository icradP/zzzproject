import 'package:flutter/widgets.dart';

/// On web, local file paths aren't meaningful (no dart:io File).
/// avatarLocalPath will typically be null on web; this is a safety fallback.
ImageProvider createFileImageProvider(String path) => AssetImage(path);
