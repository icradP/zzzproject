import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import 'im_logger.dart';
import 'im_nsfw_checker.dart';
import 'im_nsfw_config.dart';

/// NSFW checker powered by **NudeNet** (320n ONNX model).
///
/// NudeNet is a YOLOv8-based 18-class nudity detector:
/// https://github.com/notAI-tech/NudeNet
///
/// ## Setup
///
/// Download the ONNX model into `assets/models/`:
///
/// ```sh
/// curl -L -o assets/models/320n.onnx \
///   https://github.com/notAI-tech/NudeNet/releases/download/v3.4-weights/320n.onnx
/// ```
///
/// Then run `flutter pub get` and the model will be bundled with the app.
///
/// Call [initialize] once (e.g. in `ZzzApp._initRepository`).  If the model
/// fails to load the checker stays unavailable and [check] returns `null`.
class OnnxNsfwChecker implements ImNsfwChecker {
  OnnxNsfwChecker({
    this.modelAssetPath = 'assets/models/320n.onnx',
    this.inputSize = 320,
    this.confidenceThreshold = 0.35,
  });

  /// Flutter asset path to the ONNX model file.
  final String modelAssetPath;

  /// Model input resolution (320 for 320n, 640 for 640m).
  final int inputSize;

  /// Minimum confidence to treat a detection as NSFW.
  final double confidenceThreshold;

  OnnxRuntime? _ort;
  OrtSession? _session;
  String? _inputName;
  String? _outputName;

  // -----------------------------------------------------------------------
  // ImNsfwChecker
  // -----------------------------------------------------------------------

  @override
  bool get isAvailable => _session != null;

  @override
  Future<void> initialize() async {
    try {
      _ort = OnnxRuntime();
      _session = await _ort!.createSessionFromAsset(modelAssetPath);
      _inputName = _session!.inputNames.first;
      _outputName = _session!.outputNames.first;
    } catch (e) {
      ImLogger.nsfwInitFailed(e);
      _session?.close();
      _session = null;
    }
  }

  @override
  Future<bool?> check(String imagePath) async {
    final session = _session;
    if (session == null) {
      ImLogger.nsfwUnavailable('session null for $imagePath');
      return null;
    }

    final file = File(imagePath);
    if (!await file.exists()) {
      ImLogger.logRaw(ImLogger.nsfw, 'file missing: $imagePath');
      return null;
    }

    try {
      // 1. Preprocess: decode → resize → normalise → CHW float32 tensor
      final tensorData = await _preprocess(file, inputSize);
      if (tensorData == null) {
        ImLogger.logRaw(ImLogger.nsfw, 'decode/resize failed: $imagePath');
        return null;
      }

      // 2. Create OrtValue & run inference
      final inputTensor = await OrtValue.fromList(
        tensorData,
        [1, 3, inputSize, inputSize],
      );
      final outputs = await session.run({_inputName!: inputTensor});
      final outputTensor = outputs[_outputName!]!;

      // 3. Postprocess
      final result = await _postprocess(outputTensor, confidenceThreshold);
      return result;
    } catch (e) {
      ImLogger.logRaw(ImLogger.nsfw, 'inference error for $imagePath: $e');
      return null;
    }
  }

  @override
  void dispose() {
    _session?.close();
    _session = null;
    _ort = null;
  }

  // -----------------------------------------------------------------------
  // Preprocessing — YOLOv8
  // -----------------------------------------------------------------------

  /// Decodes [file], resizes to [size]×[size], normalises pixels to [0,1],
  /// and returns a [Float32List] in CHW layout.
  Future<Float32List?> _preprocess(File file, int size) async {
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    // Resize with linear interpolation (YOLOv8 uses letterbox, but simple
    // resize is close enough and faster for mobile).
    final resized = img.copyResize(
      decoded,
      width: size,
      height: size,
      interpolation: img.Interpolation.linear,
    );

    // CHW layout, normalised to [0, 1].
    final data = Float32List(3 * size * size);
    var idx = 0;
    for (var c = 0; c < 3; c++) {
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final pixel = resized.getPixel(x, y);
          final v =
              (c == 0 ? pixel.r : c == 1 ? pixel.g : pixel.b) / 255.0;
          data[idx++] = v;
        }
      }
    }
    return data;
  }

  // -----------------------------------------------------------------------
  // Postprocessing — YOLOv8 output
  // -----------------------------------------------------------------------

  /// NudeNet 18 class labels (0-indexed).
  /// See [ImNsfwConfig.labels] for the current list.
  ///
  /// Class indices 2,3,4,5,6,14 are the default NSFW candidates.
  static const _nsfwClassIndices = {2, 3, 4, 5, 6, 14};

  /// YOLOv8 output shape: [1, 4 + numClasses, numDetections].
  /// For NudeNet 320n: [1, 22, 8400].
  ///
  /// Uses [ImNsfwConfig.instance] for per-class thresholds and enabled set.
  Future<bool?> _postprocess(OrtValue output, double threshold) async {
    final config = ImNsfwConfig.instance;
    if (!config.enabled) {
      ImLogger.logRaw(ImLogger.nsfw, 'postprocess: NSFW disabled in config');
      return false;
    }

    final shape = output.shape;
    if (shape.length != 3) return null;

    final numClasses = shape[1]; // 22
    final numCells = shape[2]; // 8400
    if (numClasses < 5) return null;
    const boxLen = 4;
    final numCls = numClasses - boxLen; // 18

    final flat = await output.asFlattenedList();

    // Row-major: channel varies slowest, spatial varies fastest.
    // NudeNet ONNX output is already sigmoid-ed (scores in [0,1]).

    // 1. Collect ALL raw detections above per-class thresholds.
    final rawBoxes = <_RawBox>[];
    for (var ci = 0; ci < numCls; ci++) {
      final t = config.isClassEnabled(ci)
          ? config.thresholdFor(ci)
          : threshold;
      final scoreCh = boxLen + ci;
      for (var d = 0; d < numCells; d++) {
        final score = (flat[scoreCh * numCells + d] as num).toDouble();
        if (score < t) continue;

        final cx = (flat[0 * numCells + d] as num).toDouble();
        final cy = (flat[1 * numCells + d] as num).toDouble();
        final w = (flat[2 * numCells + d] as num).toDouble();
        final h = (flat[3 * numCells + d] as num).toDouble();

        rawBoxes.add(_RawBox(ci: ci, cx: cx, cy: cy, w: w, h: h, score: score));
      }
    }

    if (rawBoxes.isEmpty) {
      ImLogger.logRaw(ImLogger.nsfw, 'postprocess: 0 detections → safe');
      return false;
    }

    // 2. Sort by score desc, apply greedy NMS.
    rawBoxes.sort((a, b) => b.score.compareTo(a.score));
    const iouThreshold = 0.45;
    final suppressed = <int>{};

    double calcIou(_RawBox a, _RawBox b) {
      final ax1 = a.cx - a.w / 2, ay1 = a.cy - a.h / 2;
      final ax2 = a.cx + a.w / 2, ay2 = a.cy + a.h / 2;
      final bx1 = b.cx - b.w / 2, by1 = b.cy - b.h / 2;
      final bx2 = b.cx + b.w / 2, by2 = b.cy + b.h / 2;
      final iw = (ax1 > bx1 ? ax1 : bx1);
      final ih = (ay1 > by1 ? ay1 : by1);
      final iw2 = (ax2 < bx2 ? ax2 : bx2);
      final ih2 = (ay2 < by2 ? ay2 : by2);
      final iw3 = iw2 - iw;
      final ih3 = ih2 - ih;
      if (iw3 <= 0 || ih3 <= 0) return 0;
      final inter = iw3 * ih3;
      final union = a.w * a.h + b.w * b.h - inter;
      return union > 0 ? inter / union : 0;
    }

    for (var i = 0; i < rawBoxes.length; i++) {
      if (suppressed.contains(i)) continue;
      for (var j = i + 1; j < rawBoxes.length; j++) {
        if (suppressed.contains(j)) continue;
        if (calcIou(rawBoxes[i], rawBoxes[j]) > iouThreshold) suppressed.add(j);
      }
    }

    // 3. Log all surviving detections.
    final survived = <_RawBox>[];
    for (var i = 0; i < rawBoxes.length; i++) {
      if (!suppressed.contains(i)) survived.add(rawBoxes[i]);
    }

    ImLogger.logRaw(ImLogger.nsfw,
        'postprocess ${rawBoxes.length} raw → ${survived.length} NMS');
    for (final b in survived) {
      final labels = ImNsfwConfig.labels;
      final label = b.ci >= 0 && b.ci < labels.length ? labels[b.ci] : '?';
      final isNsfw = _nsfwClassIndices.contains(b.ci) ? ' *** NSFW ***' : '';
      ImLogger.logRaw(ImLogger.nsfw,
          '  $label score=${b.score.toStringAsFixed(3)} '
          'box=[${b.cx.toInt()},${b.cy.toInt()},${b.w.toInt()},${b.h.toInt()}]$isNsfw');
    }

    // 4. NSFW only if a survivor belongs to an enabled NSFW class.
    return survived.any(
        (b) => _nsfwClassIndices.contains(b.ci) && config.isClassEnabled(b.ci));
  }
}

class _RawBox {
  const _RawBox({
    required this.ci,
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
    required this.score,
  });
  final int ci;
  final double cx, cy, w, h, score;
}
