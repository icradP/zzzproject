import 'package:flutter/material.dart';

import '../theme/zzz_colors.dart';

part 'components/zzz_footer_button.dart';
part 'components/zzz_form_controls.dart';
part 'components/zzz_identity_widgets.dart';
part 'components/zzz_panels.dart';
part 'components/zzz_segmented_control.dart';

const Duration _kZzzAnimFast = Duration(milliseconds: 120);
const Duration _kZzzAnimNormal = Duration(milliseconds: 220);
const Duration _kZzzAnimSegment = Duration(milliseconds: 280);
const Duration _kZzzAnimExpand = Duration(milliseconds: 320);
const Curve _kZzzCurve = Curves.easeOutCubic;
const Curve _kZzzBounce = Cubic(0.34, 1.56, 0.64, 1);

Duration _zzzDuration(bool animated, [Duration duration = _kZzzAnimNormal]) {
  return animated ? duration : Duration.zero;
}
