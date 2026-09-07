import 'package:flutter/foundation.dart';

import '../models/im_dynamic_models.dart';
import 'im_dynamic_patch.dart';

/// Owns mutable runtime state while keeping the schema immutable and
/// serializable. A view can listen to this object without owning business data.
class ImDynamicRuntime extends ChangeNotifier {
  ImDynamicRuntime({
    required ImDynamicContent content,
    ImDynamicState state = const ImDynamicState(),
    ImDynamicPatchApplier patchApplier = const ImDynamicPatchApplier(),
  }) : _content = content,
       _state = state,
       _patchApplier = patchApplier;

  ImDynamicContent _content;
  ImDynamicState _state;
  final ImDynamicPatchApplier _patchApplier;

  ImDynamicContent get content => _content;
  ImDynamicState get state => _state;

  void setState(ImDynamicState state) {
    _state = state;
    notifyListeners();
  }

  void updateState({
    ImDynamicLifecycle? lifecycle,
    Map<String, dynamic>? values,
  }) {
    _state = _state.copyWith(
      lifecycle: lifecycle,
      values: values == null ? null : {..._state.values, ...values},
    );
    notifyListeners();
  }

  void apply(ImDynamicPatchSet update) {
    _content = _patchApplier.apply(_content, update);
    notifyListeners();
  }
}
