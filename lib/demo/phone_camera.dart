import 'dart:io';

import 'package:image_picker/image_picker.dart';

/// The phone's own camera, which shoots for the demo camera.
class PhoneCamera {
  const PhoneCamera();

  /// Opens the system camera, which needs no camera permission. Null when
  /// the player backs out without a photo.
  Future<File?> takePhoto() async {
    final shot = await ImagePicker().pickImage(
      source: ImageSource.camera,
      requestFullMetadata: false,
    );
    return shot == null ? null : File(shot.path);
  }
}
