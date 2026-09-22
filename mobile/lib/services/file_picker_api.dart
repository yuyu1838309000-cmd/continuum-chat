import 'package:flutter/services.dart';

/// 系统文件选择结果（Android 原生 ACTION_OPEN_DOCUMENT，走 MethodChannel）。
/// 原生侧已把所选文件拷到 App 缓存目录，返回可直接读取的本地路径。
class PickedLocalFile {
  final String path;
  final String name;
  final int size;

  const PickedLocalFile({
    required this.path,
    required this.name,
    required this.size,
  });

  /// 扩展名（小写，无点）。
  String get ext {
    final idx = name.lastIndexOf('.');
    return idx < 0 ? '' : name.substring(idx + 1).toLowerCase();
  }

  /// 类型：image / audio / doc（决定文件卡片图标与大小上限）。
  String get type {
    const audio = {'mp3', 'm4a', 'wav', 'flac'};
    const image = {'png', 'jpg', 'jpeg', 'gif'};
    if (audio.contains(ext)) return 'audio';
    if (image.contains(ext)) return 'image';
    return 'doc';
  }
}

/// 文件选择平台通道。原生实现见
/// android/.../MainActivity.kt（MethodChannel "continuum/file_picker"）。
/// file_picker 插件历史两轮编译失败，改走 Android 原生 Intent：
/// 零新插件依赖、零 Gradle 改动，版本兼容风险最低。
class FilePickerApi {
  FilePickerApi._();

  static const MethodChannel _channel = MethodChannel('continuum/file_picker');

  /// 类型白名单（与服务端 FILES_ALLOWED_EXTS 一致）。
  static const List<String> allowedExts = [
    'pdf',
    'doc',
    'docx',
    'txt',
    'md',
    'xlsx',
    'mp3',
    'm4a',
    'wav',
    'flac',
    'png',
    'jpg',
    'jpeg',
    'gif',
  ];

  /// 大小上限：文档/音频 50MB，图片 10MB（与服务端一致，客户端先拦一道）。
  static const int maxDocAudioBytes = 50 * 1024 * 1024;
  static const int maxImageBytes = 10 * 1024 * 1024;

  static int limitFor(String type) =>
      type == 'image' ? maxImageBytes : maxDocAudioBytes;

  /// 打开系统文件选择器。用户取消返回 null；
  /// 平台不支持/类型不合法/超大小抛异常（调用方 toast 兜底）。
  static Future<PickedLocalFile?> pick() async {
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('pickFile');
    if (res == null) return null;
    final path = res['path'] as String? ?? '';
    final name = res['name'] as String? ?? '';
    final size = (res['size'] as num?)?.toInt() ?? 0;
    if (path.isEmpty || name.isEmpty) return null;
    final file = PickedLocalFile(path: path, name: name, size: size);
    if (!allowedExts.contains(file.ext)) {
      throw PlatformException(
        code: 'bad_type',
        message: '不支持的文件类型 .${file.ext}',
      );
    }
    if (size > limitFor(file.type)) {
      throw PlatformException(code: 'too_large', message: '文件超过大小上限');
    }
    return file;
  }
}
