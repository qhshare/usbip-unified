import 'dart:io';

import 'usbip_service.dart';

/// Installs the native USB/IP tools from the operating system's online
/// package source. The package manager remains responsible for dependencies.
class OnlineInstaller {
  Future<CommandResult> install(
      {required bool server, required bool client}) async {
    if (!Platform.isLinux && !Platform.isWindows) {
      return const CommandResult(
          command: 'online installer',
          code: 2,
          output: '在线安装目前仅支持 Linux 和 Windows。');
    }
    if (Platform.isLinux) return _installLinux(server: server, client: client);
    return _installWindows(server: server, client: client);
  }

  Future<CommandResult> check({bool? server, bool? client}) async {
    final checkServer = server ?? true;
    final checkClient = client ?? true;
    final found = <String>[];
    final missing = <String>[];
    if (Platform.isWindows) {
      if (checkServer) {
        if (await _exists('usbipd')) {
          found.add('usbipd');
        } else {
          missing.add('usbipd');
        }
      }
      if (checkClient) {
        if (await _exists('usbipw.exe')) {
          found.add('usbipw.exe');
        } else if (await _exists('usbip.exe')) {
          found.add('usbip.exe (兼容模式)');
        } else {
          missing.add('usbipw.exe');
        }
      }
    } else if (Platform.isLinux) {
      if (await _exists('usbip')) {
        found.add('usbip');
      } else {
        missing.add('usbip');
      }
    }
    return CommandResult(
      command: 'environment check',
      code: missing.isEmpty ? 0 : 1,
      output: [
        if (found.isNotEmpty) '已检测到：${found.join(', ')}',
        if (missing.isNotEmpty) '未检测到：${missing.join(', ')}',
        if (Platform.isWindows && checkClient)
          'Windows 客户端还需要已安装并加载 usbip-win2 虚拟 USB 驱动；兼容旧版本时也会接受 usbip.exe。',
      ].join('\n'),
    );
  }

  Future<CommandResult> _installLinux(
      {required bool server, required bool client}) async {
    final manager = await _linuxManager();
    if (manager == null) {
      return const CommandResult(
        command: 'online installer',
        code: 2,
        output: '未识别 Linux 包管理器。支持 apt、dnf、pacman、apk；请手动安装 usbip。',
      );
    }
    // Linux distributions generally ship both roles in the same usbip tools.
    final command = manager.executable;
    final args = [...manager.prefix, ...manager.installArgs, 'usbip'];
    return _elevated(command, args, manager.needsElevation);
  }

  Future<CommandResult> _installWindows(
      {required bool server, required bool client}) async {
    if (!server) {
      return const CommandResult(
        command: 'online installer',
        code: 2,
        output: 'Windows 客户端 usbip-win2 没有统一的官方包管理器包。请使用设置中的离线资源安装，或手动安装对应版本。',
      );
    }
    if (!await _exists('winget')) {
      return const CommandResult(
          command: 'winget',
          code: 127,
          output: '未找到 winget。请安装 App Installer，或使用离线安装包。');
    }
    return _elevated(
        'winget',
        [
          'install',
          '--id',
          'dorssel.usbipd-win',
          '--exact',
          '--accept-source-agreements',
          '--accept-package-agreements',
        ],
        false);
  }

  Future<_LinuxManager?> _linuxManager() async {
    if (await _exists('apt-get')) {
      // Fail fast when another apt/dpkg operation owns the lock. Waiting for
      // an unknown amount of time makes the UI look frozen.
      return const _LinuxManager(
          'apt-get', ['-y', '-o', 'DPkg::Lock::Timeout=0'], ['install'], true);
    }
    if (await _exists('dnf')) {
      return const _LinuxManager('dnf', [], ['install', '-y'], true);
    }
    if (await _exists('pacman')) {
      return const _LinuxManager('pacman', [], ['-S', '--noconfirm'], true);
    }
    if (await _exists('apk')) {
      return const _LinuxManager('apk', [], ['add'], true);
    }
    return null;
  }

  Future<CommandResult> _elevated(
      String executable, List<String> args, bool needsElevation) async {
    if (!needsElevation || await _isRoot()) return _run(executable, args);
    if (await _exists('pkexec')) return _run('pkexec', [executable, ...args]);
    if (await _exists('sudo')) return _run('sudo', [executable, ...args]);
    return const CommandResult(
        command: 'privilege elevation',
        code: 127,
        output: '未找到 pkexec 或 sudo，请在管理员终端手动安装。');
  }

  Future<bool> _isRoot() async {
    if (!Platform.isLinux) return false;
    try {
      final result = await Process.run('id', ['-u']);
      return result.exitCode == 0 && result.stdout.toString().trim() == '0';
    } catch (_) {
      return false;
    }
  }

  Future<bool> _exists(String command) async {
    try {
      final result = await Process.run(Platform.isWindows ? 'where.exe' : 'sh',
          Platform.isWindows ? [command] : ['-c', 'command -v "$command"']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<CommandResult> _run(String executable, List<String> args) async {
    final command = ([executable, ...args]).join(' ');
    try {
      final process = await Process.start(executable, args);
      final stdout =
          process.stdout.transform(const SystemEncoding().decoder).join();
      final stderr =
          process.stderr.transform(const SystemEncoding().decoder).join();
      final code = await process.exitCode.timeout(const Duration(minutes: 15),
          onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        return 124;
      });
      return CommandResult(
          command: command,
          code: code,
          output: '${await stdout}${await stderr}'.trim());
    } on ProcessException catch (error) {
      return CommandResult(
          command: command, code: 127, output: '无法执行在线安装命令：${error.message}');
    } catch (error) {
      return CommandResult(command: command, code: 1, output: '在线安装失败：$error');
    }
  }
}

class _LinuxManager {
  const _LinuxManager(
      this.executable, this.prefix, this.installArgs, this.needsElevation);
  final String executable;
  final List<String> prefix;
  final List<String> installArgs;
  final bool needsElevation;
}
