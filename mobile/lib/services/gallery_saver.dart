import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class GallerySaver {
  GallerySaver._();

  static const MethodChannel _channel = MethodChannel('continuum/gallery');

  static Future<bool> saveNetworkImage(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw const FormatException('图片地址无效');
    }
    final resp = await http.get(uri).timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('图片下载失败');
    }
    final bytes = resp.bodyBytes;
    if (bytes.isEmpty) throw StateError('图片为空');
    return saveImageBytes(
      bytes,
      mimeType: _mimeType(resp.headers['content-type'], uri.path),
    );
  }

  static Future<bool> saveImageBytes(
    Uint8List bytes, {
    required String mimeType,
  }) async {
    final ok = await _channel.invokeMethod<bool>('saveImage', {
      'bytes': bytes,
      'mimeType': mimeType,
      'displayName': _displayName(mimeType),
    });
    return ok ?? false;
  }

  static String _mimeType(String? contentType, String path) {
    final type = (contentType ?? '').split(';').first.trim().toLowerCase();
    if (type == 'image/png' || type == 'image/jpeg' || type == 'image/gif') {
      return type;
    }
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  static String _displayName(String mimeType) {
    final ext = mimeType == 'image/png'
        ? 'png'
        : mimeType == 'image/gif'
        ? 'gif'
        : 'jpg';
    return 'continuum_${DateTime.now().millisecondsSinceEpoch}.$ext';
  }
}
