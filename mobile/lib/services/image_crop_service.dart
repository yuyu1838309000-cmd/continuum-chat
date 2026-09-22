import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';

class ImageCropService {
  ImageCropService._();

  static Future<Uint8List?> cropSquareBytes(
    Uint8List bytes, {
    String title = '裁剪头像',
    int maxSize = 1024,
  }) {
    return cropBytes(
      bytes,
      title: title,
      maxSize: maxSize,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
    );
  }

  static Future<Uint8List?> cropBytes(
    Uint8List bytes, {
    CropAspectRatio? aspectRatio,
    String title = '裁剪图片',
    int maxSize = 1600,
  }) async {
    final dir = await getTemporaryDirectory();
    final source = File(
      '${dir.path}/continuum_crop_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await source.writeAsBytes(bytes, flush: true);
    final cropped = await ImageCropper().cropImage(
      sourcePath: source.path,
      maxWidth: maxSize,
      maxHeight: maxSize,
      aspectRatio: aspectRatio,
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 92,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: title,
          toolbarColor: Colors.black,
          toolbarWidgetColor: Colors.white,
          hideBottomControls: false,
          lockAspectRatio: aspectRatio != null,
        ),
        IOSUiSettings(
          title: title,
          doneButtonTitle: '完成',
          cancelButtonTitle: '取消',
          aspectRatioLockEnabled: aspectRatio != null,
        ),
      ],
    );
    try {
      await source.delete();
    } catch (_) {}
    if (cropped == null) return null;
    return File(cropped.path).readAsBytes();
  }
}
