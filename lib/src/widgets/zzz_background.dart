import 'package:flutter/material.dart';

class ZzzBackground extends StatelessWidget {
  const ZzzBackground({
    required this.controller,
    required this.animated,
    super.key,
  });

  final Animation<double> controller;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/BG_background_ZZZChat_with_pattern.png',
          fit: BoxFit.cover,
          color: Colors.black.withValues(alpha: 0.34),
          colorBlendMode: BlendMode.darken,
        ),
        if (animated)
          AnimatedBuilder(
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
        Container(color: Colors.black.withValues(alpha: 0.62)),
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
        color: Colors.white.withValues(alpha: 0.06),
        fontSize: 96,
        fontWeight: FontWeight.w900,
        height: 1,
      ),
    );
  }
}
