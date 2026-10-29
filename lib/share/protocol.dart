/// LocalSend protocol v2 (https://github.com/localsend/protocol, Apache-2.0):
/// message formats and constants. Our own Dart implementation, compatible
/// with the official LocalSend apps.
library;

const lsPort = 53317;
const lsMulticastGroup = '224.0.0.167';
const lsVersion = '2.1';
const lsApi = '/api/localsend/v2';

enum LsDeviceType { mobile, desktop, web, headless, server }

/// A LocalSend device as it announces itself.
class LsInfo {
  LsInfo({
    required this.alias,
    required this.fingerprint,
    this.version = lsVersion,
    this.deviceModel,
    this.deviceType = LsDeviceType.mobile,
    this.port = lsPort,
    this.protocol = 'http',
    this.download = false,
  });

  final String alias;
  final String version;
  final String? deviceModel;
  final LsDeviceType deviceType;
  final String fingerprint;
  final int port;

  /// `http` or `https`.
  final String protocol;

  /// Whether it serves files for browsers ("download" / reverse mode).
  final bool download;

  factory LsInfo.fromJson(Map<String, dynamic> j) => LsInfo(
        alias: j['alias'] as String? ?? 'Unknown',
        version: j['version'] as String? ?? '2.0',
        deviceModel: j['deviceModel'] as String?,
        deviceType: LsDeviceType.values.firstWhere(
          (t) => t.name == j['deviceType'],
          // Unknown types count as desktop, like the official app.
          orElse: () => LsDeviceType.desktop,
        ),
        fingerprint: j['fingerprint'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? lsPort,
        protocol: j['protocol'] as String? ?? 'https',
        download: j['download'] as bool? ?? false,
      );

  Map<String, dynamic> toJson({bool? announce}) => {
        'alias': alias,
        'version': version,
        'deviceModel': deviceModel,
        'deviceType': deviceType.name,
        'fingerprint': fingerprint,
        'port': port,
        'protocol': protocol,
        'download': download,
        'announce': ?announce,
      };
}

/// A device found on the network, with where to reach it.
class LsDevice {
  LsDevice({required this.info, required this.ip, required this.lastSeen});

  final LsInfo info;
  final String ip;
  DateTime lastSeen;

  String get fingerprint => info.fingerprint;
  String get alias => info.alias;
  Uri uri(String path, [Map<String, String>? query]) => Uri(
        scheme: info.protocol,
        host: ip,
        port: info.port,
        path: '$lsApi$path',
        queryParameters: query,
      );

  /// Recently heard from (discovery re-announces every few seconds).
  bool get isFresh => DateTime.now().difference(lastSeen) < const Duration(seconds: 45);
}

/// One file offered in `prepare-upload` / `prepare-download`.
class LsFile {
  LsFile({
    required this.id,
    required this.fileName,
    required this.size,
    required this.fileType,
    this.sha256,
    this.preview,
    this.modified,
  });

  final String id;
  final String fileName;
  final int size;
  final String fileType;
  final String? sha256;
  final String? preview;
  final DateTime? modified;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'size': size,
        'fileType': fileType,
        'sha256': sha256,
        'preview': preview,
        'metadata': modified == null ? null : {'modified': modified!.toUtc().toIso8601String()},
      };
}

/// MIME type from a file name, for the `fileType` field.
String mimeFor(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'heic' => 'image/heic',
    'heif' => 'image/heif',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'dng' => 'image/x-adobe-dng',
    'zip' => 'application/zip',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'mkv' => 'video/x-matroska',
    'webm' => 'video/webm',
    '3gp' => 'video/3gpp',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'wav' => 'audio/wav',
    'ogg' => 'audio/ogg',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'html' || 'htm' => 'text/html',
    'json' => 'application/json',
    'csv' => 'text/csv',
    'doc' => 'application/msword',
    'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'apk' => 'application/vnd.android.package-archive',
    '7z' => 'application/x-7z-compressed',
    'rar' => 'application/vnd.rar',
    _ => 'application/octet-stream',
  };
}
