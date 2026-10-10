import 'dart:convert';
import 'dart:io';

/// Small JSON-backed settings store for a portable build.
///
/// The application must not write beside the executable: a portable package
/// is often extracted into a read-only directory. Tool paths are also machine
/// specific, so store them in the per-user configuration directory instead.
class AppSettings {
  const AppSettings({
    this.serverToolPath = '',
    this.clientToolPath = '',
    this.remoteHost = '',
    this.serverPort = '3240',
    this.clientPort = '3240',
  });

  final String serverToolPath;
  final String clientToolPath;
  final String remoteHost;
  final String serverPort;
  final String clientPort;

  Map<String, String> toJson() => {
        'serverToolPath': serverToolPath,
        'clientToolPath': clientToolPath,
        'remoteHost': remoteHost,
        'serverPort': serverPort,
        'clientPort': clientPort,
      };

  static AppSettings fromJson(Object? value) {
    if (value is! Map) return const AppSettings();
    String read(String key, String fallback) {
      final item = value[key];
      return item is String ? item : fallback;
    }

    return AppSettings(
      serverToolPath: read('serverToolPath', ''),
      clientToolPath: read('clientToolPath', ''),
      remoteHost: read('remoteHost', ''),
      serverPort: read('serverPort', '3240'),
      clientPort: read('clientPort', '3240'),
    );
  }
}

class AppSettingsStore {
  static const _directoryName = 'usbip-unified';
  static const _fileName = 'settings.json';

  Future<File> _file() async {
    final directory = _configDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}$_fileName');
  }

  Future<AppSettings> load() async {
    try {
      final file =
          File('${_configDirectory().path}${Platform.pathSeparator}$_fileName');
      if (!await file.exists()) return const AppSettings();
      return AppSettings.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      // A damaged or inaccessible settings file must not prevent the GUI from
      // starting; the user can still configure paths for this session.
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    final file = await _file();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
  }

  Directory _configDirectory() {
    final environment = Platform.environment;
    if (Platform.isWindows) {
      final root = environment['APPDATA'] ??
          environment['LOCALAPPDATA'] ??
          environment['USERPROFILE'] ??
          Directory.current.path;
      return Directory('$root${Platform.pathSeparator}$_directoryName');
    }
    final root = environment['XDG_CONFIG_HOME'];
    if (root != null && root.trim().isNotEmpty) {
      return Directory('$root${Platform.pathSeparator}$_directoryName');
    }
    final home = environment['HOME'] ?? Directory.current.path;
    return Directory(
        '$home${Platform.pathSeparator}.config${Platform.pathSeparator}$_directoryName');
  }
}
