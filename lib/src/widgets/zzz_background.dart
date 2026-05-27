import 'package:flutter/material.dart';

import '../assets/app_assets.dart';

class ZzzBackground extends StatelessWidget {
  const ZzzBackground({required this.controller, required this.animated, super.key});

  final Animation<double> controller;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        Image.asset(
          AppAssets.bgChatWithPattern,
          fit: BoxFit.cover,
          color: Colors.black.withValues(alpha: 0.60),
          colorBlendMode: BlendMode.darken,
        ),
        if (animated)
          IgnorePointer(
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, child) {
                return Transform.rotate(
                  angle: -0.48,
                  child: FractionalTranslation(
                    translation: Offset(controller.value * 2 - 1, 0),
                    child: child,
                  ),
                );
              },
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _BackdropText('ZERO ZONE'),
                  _BackdropText('ZENLESS'),
                  _BackdropText('ZONE ZERO'),
                ],
              ),
            ),
          ),
        Container(color: Colors.black.withValues(alpha: 0.70)),
      ],
    );
  }
}

class _BackdropText extends StatelessWidget {
  const _BackdropText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.80),
        fontSize: 106,
        fontWeight: FontWeight.w900,
        height: 1,
      ),
    );
  }
}
