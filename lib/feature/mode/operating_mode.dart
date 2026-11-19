import 'package:flutter/material.dart';

/// What happens to new or selected photos while a camera is connected.
enum OperatingMode {
  browse(
    'Browse & Download',
    'Look through the card and save photos to this phone.',
    Icons.photo_library_outlined,
  ),
  autoUpload(
    'Auto Upload',
    'Upload new shots to your destination while you shoot.',
    Icons.cloud_upload_outlined,
  ),
  qrSession(
    'Live Share',
    'Share new shots with guests through a QR code.',
    Icons.qr_code_2,
  );

  const OperatingMode(this.label, this.description, this.icon);

  final String label;
  final String description;
  final IconData icon;
}
