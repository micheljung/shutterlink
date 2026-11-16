import 'package:flutter/material.dart';

class ShutterlinkWordmark extends StatelessWidget {
  const ShutterlinkWordmark({super.key, this.size = defaultSize});

  static const text = 'shutterlink';
  static const defaultSize = 40.0;
  static const _tracking = -0.035;
  static const _lineHeight = 1.05;

  final double size;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    style: TextStyle(
      fontSize: size,
      fontWeight: FontWeight.w800,
      letterSpacing: size * _tracking,
      height: _lineHeight,
      color: Theme.of(context).colorScheme.onSurface,
    ),
  );
}
