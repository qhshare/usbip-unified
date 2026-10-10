# USBIP Unified Manager

[English](README.en.md) | 中文

一个使用 Flutter 开发的 Linux/Windows USB/IP 图形管理器。它用统一界面
管理本机 USB 设备共享、远程 USB 设备连接、绑定、解绑、断开、端口和底层
组件安装。

> 项目状态：早期版本（`0.1.0`）。已在 Windows x64 与 Linux amd64 真机上
> 完成 CH340 串口的双向 USB/IP 穿透验证；其他 USB 设备类型、多设备并发、
> 热插拔、重连、高带宽和长时间稳定性仍需继续验证。

## 目录

- [功能](#功能)
- [工作原理](#工作原理)
- [支持矩阵](#支持矩阵)
- [真机验证记录](#真机验证记录)
- [30 秒运行](#30-秒运行)
- [从源码构建](#从源码构建)
- [Linux](#linux)
- [Windows](#windows)
- [使用流程](#使用流程)
- [离线安装](#离线安装)
- [免安装发布包](#免安装发布包)
- [开发与测试](#开发与测试)
- [发布流程](#发布流程)
- [目录结构](#目录结构)
- [构建指南](BUILDING.md)
- [第三方源码与许可证](#第三方源码与许可证)
- [第三方声明](#第三方声明)
- [安全注意事项](#安全注意事项)
- [已知限制](#已知限制)

## 功能

- Material 3 Flutter 桌面界面，Linux 和 Windows 使用同一套产品界面。
- 明确区分共享端和客户端：共享端查看本机 USB 并绑定/共享、解绑；客户端
  查看远程 USB 并连接、断开。
- Linux 使用发行版提供的 `usbip`、`usbipd` 和内核模块。
- Windows 共享端使用 `usbipd-win`；Windows 客户端使用 `usbip-win2`。
- 显示本机网卡地址、共享端口、远程主机和远程端口。
- Linux 共享端支持自定义 `usbipd` TCP 端口；Windows `usbipd-win` 使用固定
  TCP `3240`。
- 操作日志记录实际命令、退出码、标准输出和关键步骤，便于排查权限、驱动、
  端口和设备状态问题。
- 设置页提供环境检查、在线安装、内置离线安装和手动安装指引。
- 离线资源随 Flutter asset 打入发布目录，安装器按发行版和 CPU 架构选择资源。

## 工作原理

本项目是从零开发的 Flutter 应用，不是三个旧项目的界面拼接，也不把旧的
Tkinter/WPF 界面嵌入应用：

```text
Flutter UI
    |
UsbIpService
    |
原生进程边界
    |-- Linux:   usbip / usbipd / usbip-host / vhci-hcd
    |-- Windows: usbipd-win / usbipd.exe
    `-- Windows: usbip-win2 / usbipw.exe / 虚拟 USB 驱动
```

Flutter 负责界面、角色状态、参数校验、命令调用、输出解析和日志。USB/IP
协议、Linux 内核模块、Windows 虚拟 USB 驱动和服务注册仍由操作系统及其原生
组件负责，不能仅靠复制 Flutter 目录替代。

参考项目源码保存在 `third_party/`，只用于研究命令、驱动和平台行为。主程序
没有运行这些项目的旧 UI。边界和扩展方式见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 支持矩阵

| 平台/架构 | 共享端 | 客户端 | 内置离线资源 | 当前说明 |
| --- | ---: | ---: | --- | --- |
| Linux Kali amd64 | 支持 | 支持 | `.deb` | 已提供 Kali amd64 资源 |
| Linux Kali i386 | 支持 | 支持 | `.deb` | 仅适用于 32 位 Kali 用户态和兼容内核 |
| Linux Kali arm64 | 支持 | 支持 | `.deb` | 目标设备需要匹配的 ARM64 内核 |
| Linux Kali armhf | 支持 | 支持 | `.deb` | 目标设备需要匹配的 ARM hard-float 内核 |
| Debian 12 amd64 | 支持 | 支持 | `.deb` | 单独使用 Debian 12 资源 |
| Ubuntu/Fedora/Arch/Alpine | 取决于系统工具 | 取决于系统工具 | 不提供 | 使用在线安装或发行版手动安装 |
| Windows x64 | 支持 | 支持 | MSI + VC++ Runtime + 客户端文件 + 驱动 | 内置 `usbipd-win`、`usbipw.exe` 和虚拟 USB 驱动 |
| Windows ARM64 | 支持 | 支持 | MSI + EXE | 使用 ARM64 对应驱动和工具 |
| Windows x86（32 位） | 不支持 | 不支持 | 不提供 | 当前上游没有可用的完整 32 位驱动组合 |
| macOS | 不支持 | 不支持 | 不提供 | 当前项目没有维护 macOS USB/IP 后端 |

“支持”表示代码和命令适配，不等于每种硬件、内核、驱动版本都已经真机
验证。Linux 离线 `.deb` 不是通用 Linux 安装包；Windows 离线资源也必须与
系统架构匹配。

## 真机验证记录

2026-10-10 已完成 Windows x64 与 Linux amd64 之间的 CH340 USB 转串口
双向穿透验证。测试设备为 `1a86:7523` CH340，TX/RX 已短接形成回环，用于
确认远程串口的双向数据收发。

| 方向 | 共享端 | 客户端 | 验证结果 |
| --- | --- | --- | --- |
| Windows -> Linux | Windows 10 x64，`usbipd-win 5.3.0` | Kali amd64，`usbip` + `vhci_hcd` | Linux 识别为 `/dev/ttyUSB0`，加载 `ch341-uart`；以 `9600 8N1` 原始模式发送 `55 AA 01 02 03 0D 0A`，收到完全相同的数据 |
| Linux -> Windows | Kali amd64，`usbip` 共享端 | Windows 10 x64，`USBip-win2 0.9.8.0` | Windows 成功连接并识别为 COM 串口，双向收发测试通过 |

以上结果验证了当前版本的 Windows 共享端、Linux 客户端、Linux 共享端和
Windows 客户端基础流程，以及 CH340 串口穿透的双向数据链路。该结论不代表
所有 USB 设备类型、多设备并发、热插拔、睡眠恢复、高带宽或长时间运行场景
都已经完成验证。

## 30 秒运行

### Linux 开发运行

先安装 Flutter stable 和 Linux desktop 依赖，然后：

```bash
git clone https://github.com/qhshare/usbip-unified.git
cd usbip-unified
flutter pub get
./run.sh
```

`run.sh` 会切换到项目目录，检查 Flutter；如果 `linux/` 不存在，会调用
`tool/bootstrap.sh` 生成 Flutter runner，然后执行 `flutter run -d linux`。

完整的构建机依赖、源码初始化、测试、Release 构建、免安装打包和发布流程见
[BUILDING.md](BUILDING.md)。

### Windows 开发运行

在 Windows 上安装 Flutter stable、Visual Studio 的 Desktop development with
C++ 工作负载，然后在项目目录执行：

```bat
flutter pub get
run-windows.bat
```

首次没有 `windows/` 目录时，脚本会调用 `tool\bootstrap.bat`。Linux 不能替代
Windows 真机完成 Windows 驱动和 USB/IP 行为验证。

## 从源码构建

构建者需要在 Linux 或 Windows 对应的桌面构建机上安装 Flutter stable 和平台
工具链。最小 Linux 流程如下：

```bash
flutter pub get
dart analyze lib test
flutter test
flutter build linux --release
```

Windows 构建必须在 Windows 主机上执行：

```bat
flutter pub get
dart analyze lib test
flutter test
flutter build windows --release
```

生成免安装 Release 包：

```bash
./tool/package-portable.sh linux
```

```bat
tool\package-portable.bat x64
tool\package-portable.bat arm64
```

构建依赖、`flutter doctor` 检查、ARM64 构建、校验、常见错误和 GitHub Release
发布步骤请阅读 [BUILDING.md](BUILDING.md)。

## Linux

### 在线安装

设置页的“自动安装组件”会调用当前系统包管理器。Windows 的服务端先尝试
`winget`，如果源损坏、证书异常或网络不可用，会自动改用便携包内的签名
`usbipd-win` MSI；Windows 客户端直接使用便携包内的官方 `USBip-win2` 安装器。
因此日志中看到 `winget` 失败并不代表本次安装失败，必须继续查看后面的“本地
MSI 回退”和“安装后环境检查”结果。也可以手动安装：

```bash
# Debian / Ubuntu / Kali
sudo apt update
sudo apt install usbip

# Fedora
sudo dnf install usbip

# Arch Linux
sudo pacman -S usbip
```

然后检查命令和内核模块：

```bash
command -v usbip
modinfo usbip-core
modinfo usbip-host
modinfo vhci-hcd
```

共享端通常需要：

```bash
sudo modprobe usbip-core
sudo modprobe usbip-host
```

客户端通常需要：

```bash
sudo modprobe usbip-core
sudo modprobe vhci-hcd
```

应用会在需要时通过 `pkexec` 或 `sudo` 请求权限。Linux 安装、绑定、解绑、
连接和断开都可能需要 root 权限。

### Linux 离线资源

当前仓库内置 Kali 多架构资源和 Debian 12 amd64 资源。进入应用设置页后，
“当前目标”会显示操作系统、发行版和架构；只有匹配的资源集才会启用离线
安装按钮。

安装器会把 asset 临时提取到类似 `/tmp/usbip-unified-offline-XXXXXX/` 的目录，
调用 `dpkg` 安装明确列出的包，完成后清理临时目录。这是为了让 Flutter 的
只读 asset 能被管理员脚本使用，不是把离线包永久安装到 `/tmp`。如果系统的
`apt/dpkg` 正在运行，安装器会停止并提示等待，不会删除锁文件。

离线 `.deb` 只提供用户态工具和依赖，不包含 `libc6`、当前内核的 `.ko` 模块
或通用 Linux 内核。`usbip-host` 和 `vhci-hcd` 必须来自目标系统当前内核。
不要把 Kali 的包强行安装到 Ubuntu、Fedora 或 Arch。

## Windows

### 共享端

Windows 共享端依赖 [usbipd-win](https://github.com/dorssel/usbipd-win)：

```powershell
winget install --id dorssel.usbipd-win --exact
usbipd list
Get-Service usbipd
```

共享端使用 `usbipd bind --busid <BUSID>` 和 `usbipd unbind --busid <BUSID>`。
`usbipd-win` 的 USB/IP 服务端监听 TCP `3240`，应用不会伪造可修改的 Windows
服务端端口。需要外部端口时，应在 FRP、VPN 或路由器层做映射。

### 客户端

Windows 客户端依赖带虚拟 USB 驱动的 [usbip-win2](https://github.com/vadimgrn/usbip-win2)：

```powershell
usbipw.exe list -r <服务端地址>
```

客户端安装会涉及内核驱动和 UAC。请使用与 Windows 架构匹配的安装包，安装前
阅读对应 Release 说明并创建系统还原点。当前仓库内置的 Windows 客户端版本
是 x64 `0.9.8.0`，ARM64 `0.9.7.5`。x64 使用官方 USBip-win2 安装器，由安装器
一次性处理客户端文件、DLL、签名驱动、驱动服务和虚拟 USB 设备节点；应用不再
手工复制 DLL，也不直接调用 `pnputil`。x64 还会先安装随包提供的 Microsoft
Visual C++ Runtime。以上是当前资源选择，不代表所有新版本都适合生产使用。

Windows 客户端的远程端口必须与对端服务端实际监听端口或 FRP 映射端口一致。
Windows 客户端端口输入限制为 `1024-65535`，Linux 客户端允许 `1-65535`。

## 使用流程

### 作为共享端

1. 在顶部或设置页选择“Linux 共享端”或“Windows 共享端”。
2. 点击“刷新设备”，确认能看到本机 USB 设备和 BUSID。
3. 检查主页显示的本机 IP 和 TCP 端口。服务端可能有多个网卡，使用客户端
   能够访问的那个地址。
4. 选择设备，点击绑定/共享。Linux 会检查或启动 `usbipd`；Windows 由
   `usbipd-win` 服务负责监听。
5. 将主页的 `IP:端口` 提供给可信客户端。客户端连接期间不要拔出设备或解绑。
6. 客户端断开后，再点击解绑。已共享或已有连接的设备按钮会被禁用，避免重复
   绑定和误解绑。

### 作为客户端

1. 选择“Linux 客户端”或“Windows 客户端”。
2. 在设置中填写远程服务端 IP/主机名和端口。
3. 点击“应用并刷新”或“刷新设备”，查看远程导出的设备。
4. 选择设备点击连接。连接状态来自本机 `usbip port`；如果查询失败，连接和
   断开按钮会禁用，避免把未知状态当成未连接。
5. 使用断开按钮释放本机虚拟 USB 端口。断开使用的是本机端口号，不是远程 BUSID。

### 命令行对照

Linux 共享端：

```bash
usbip list -l
sudo usbip bind -b 1-2
sudo usbip unbind -b 1-2
```

Linux 客户端：

```bash
usbip --tcp-port 3240 list -r 192.168.1.20
sudo usbip --tcp-port 3240 attach -r 192.168.1.20 -b 1-2
usbip port
sudo usbip detach -p 00
```

Windows 共享端：

```powershell
usbipd list
usbipd bind --busid 4-3
usbipd unbind --busid 4-3
```

Windows 客户端：

```powershell
usbipw.exe list -r 192.168.1.20
usbipw.exe attach -r 192.168.1.20 -b 1-2
usbipw.exe port
usbipw.exe detach -p 00
```

## 离线安装

离线安装资源位于 `offline/`，并作为 Flutter asset 打包到桌面发布目录。完整
资源包括：

- Windows x64：共享端 `usbipd-win_5.3.0_x64.msi`、官方
  `VC_redist.x64.exe` 和官方 `USBip-0.9.8.0-x64.exe` 安装器。x64 安装器由
  USBip-win2 官方程序负责部署客户端、DLL、签名驱动、驱动服务和虚拟 USB
  设备节点；应用不会手工复制 `client/` 文件，也不会直接调用 `pnputil`。
- Windows ARM64：`usbipd-win` MSI 和包含对应客户端、驱动的 ARM64 安装程序。
- Kali amd64/i386/arm64/armhf：对应架构的 `.deb`。
- Debian 12 amd64：单独的 Debian 12 `.deb` 组合。
- `offline/licenses/`：随二进制资源分发的许可证文本。
- `offline/SHA256SUMS`：资源校验清单。

校验资源：

```bash
cd offline
sha256sum -c SHA256SUMS
```

如果目标系统没有匹配资源，应用会禁用离线安装并提供在线安装/手动安装指引。
新增发行版时，不能只复制另一发行版的 `.deb`：需要为目标发行版、架构、
依赖版本和安装脚本增加资源，并在 `lib/services/offline_installer.dart`、
`offline/install-linux-offline.sh`、`offline/README.md`、`pubspec.yaml` 和
`SHA256SUMS` 中同步登记。

Windows 离线安装脚本支持分别安装角色：`-Server` 只安装共享端，`-Client`
只安装客户端和虚拟 USB 驱动，`-Server -Client` 同时安装两者。Windows x64 的
`-Client` 会先安装官方 Microsoft Visual C++ x64 Runtime，再启动官方
`USBip-0.9.8.0-x64.exe` 安装器，由它注册客户端文件、驱动和虚拟 USB 设备节点。
脚本成功后会检查 `usbipd.exe`、`usbipd` 服务、`usbipd list`，以及客户端的
`usbipw.exe`、USB/IP 驱动服务和虚拟设备节点。驱动服务已注册但设备节点尚未出现
时，会标记为需要重启，而不是报告完整成功。GUI 也会执行安装后环境检查。若 MSI 显示成功但旧应用仍
提示“未检测到 USB/IP 工具”，通常是 Windows 更新了系统 `PATH`，而已经运行
的旧 Flutter 进程没有获得新环境变量。必须关闭旧 GUI，并使用重新构建的完整
Windows 便携包；不能只替换临时目录中的 PowerShell 脚本。新版 GUI 还会直接
检查 `C:\Program Files\usbipd-win\usbipd.exe` 和服务配置，不依赖旧 `PATH`。
新版构建号会同时显示在系统窗口标题、页面副标题和启动日志中，例如
`0.1.0+20261010.17`。如果这些位置没有显示该构建号，说明运行的仍是旧版
`usbip_unified.exe`；只把脚本复制到临时目录不会更新 GUI 的工具探测代码。

可以在 PowerShell 中独立确认服务端安装结果：

```powershell
Test-Path 'C:\Program Files\usbipd-win\usbipd.exe'
Get-Service usbipd
& 'C:\Program Files\usbipd-win\usbipd.exe' list
Test-Path 'C:\Program Files\USBip\usbipw.exe'
Test-Path 'C:\Program Files\USBip\libusbip.dll'
Test-Path 'C:\Program Files\USBip\resources.dll'
& 'C:\Program Files\USBip\usbipw.exe' port
Test-Path "$env:WINDIR\System32\msvcp140.dll"
Test-Path "$env:WINDIR\System32\vcruntime140.dll"
Test-Path "$env:WINDIR\System32\vcruntime140_1.dll"
```

服务端文件、服务状态、VC++ Runtime 和客户端文件都应检查通过，`usbipw.exe port` 应能启动并输出
本机客户端端口状态。若服务端文件存在但旧 GUI 仍报错，通常是旧包问题；关闭旧 GUI，使用重新构建
的 `dist\usbip-unified-windows-x64-portable-20261010.17.zip` 或对应 ARM64
包。若文件不存在，
则应查看离线安装日志、UAC 和 Windows 事件查看器。

如果在设置中填写“工具路径”，可以填写 `usbipd.exe` 或 `usbip-win2` 安装目录；
新版会自动在目录中寻找对应 exe。安装成功后脚本会把服务不存在、服务未运行或
`usbipd list` 失败视为安装失败，不再显示“安装成功但应用不可用”。

## 免安装发布包

Flutter 桌面应用本身是解压即用目录，不需要 MSI、deb、注册表或 Flutter SDK。
启动应用不会自动安装任何系统组件；“检查环境”也只读检查，不会修改系统。
但是完整的 Windows USB/IP 功能不能只靠这个 EXE：服务端需要注册 `usbipd`
Windows 服务，客户端需要注册 `usbip2_ude`、`usbip2_filter` 内核驱动和虚拟
USB 设备节点。这些组件必须由目标系统预先安装，或由应用内安装器以管理员权限
安装。也就是说，应用可以免安装运行，但 Windows USB/IP 底层组件不能在未注册
驱动和服务的情况下做到完全绿色运行。

如果目标系统已经安装并通过“检查环境”验证了这些组件，可以只携带并运行便携
应用，不会重复安装；必要时可在“工具路径”中填写实际的 `usbipd.exe` 或
`usbip.exe` 路径。

Linux 在 Linux 主机上构建：

```bash
./tool/package-portable.sh linux
```

如果构建机当前无法访问 `pub.dev`，但项目已经成功执行过一次
`flutter pub get`，可以复用现有的 `.dart_tool/package_config.json`：

```bash
./tool/package-portable.sh linux --no-pub
```

`--no-pub` 会跳过依赖解析和 `flutter clean` 命令，但仍会清理 `build/` 和
`.dart_tool/flutter_build`，因此适合离线重复打包；如果
`.dart_tool/package_config.json` 不存在，必须先在可联网环境执行
`flutter pub get`。依赖或 `pubspec.yaml` 发生变化后，应重新执行正常的
`flutter pub get`，不要继续复用旧依赖。

输出：

```text
dist/usbip-unified-linux-x64-portable-20261010.17.tar.gz
```

Windows 必须在 Windows 构建机上构建：

```bat
tool\package-portable.bat x64
tool\package-portable.bat arm64
```

如果 Windows 构建机已经有可用的 `.dart_tool\package_config.json`，但当前
无法访问 `pub.dev`，可以跳过依赖解析：

```bat
tool\package-portable.bat x64 --no-pub
tool\package-portable.bat arm64 --no-pub
```

默认打包脚本会执行 `flutter clean` 和 `flutter pub get`，再重新构建 Windows
Release；`--no-pub` 模式会复用现有依赖，不执行这两个命令，但仍会删除
`build/` 和 `.dart_tool/flutter_build`。两种模式都会校验包内
`data\flutter_assets\offline\install-windows-offline.ps1` 与源码完全一致。
源码或离线脚本更新后，不要继续复制旧的 `build/windows` 或旧的 ZIP；必须重新
执行上面的命令。Windows PowerShell 5.1 对无 BOM 的 UTF-8 脚本兼容性较差，当前
离线安装脚本特意保持 ASCII 编码，以避免中文乱码导致脚本解析失败。
启动新包后，请先确认窗口标题或页面副标题中出现当前构建号，再点击“检查环境”
和“刷新设备”。不要在旧解压目录中直接覆盖单个 exe 或临时安装脚本；应删除旧
目录后解压完整的
`dist\usbip-unified-windows-x64-portable-20261010.17.zip`（或对应 ARM64
包）。

输出：

```text
dist\usbip-unified-windows-x64-portable-20261010.17.zip
dist\usbip-unified-windows-arm64-portable-20261010.17.zip
```

解压后运行 `usbip_unified` 或 `usbip_unified.exe`。不要删除同目录的 `data/`
目录；`offline/` 资源位于 Flutter asset 中。`dist/`、`build/` 和本地开发
环境默认被 `.gitignore` 排除，正式发布包应上传到 GitHub Releases，而不是
提交到源码仓库。

## 开发与测试

安装依赖：

```bash
flutter pub get
```

只有 `linux/` 或 `windows/` runner 目录缺失时，才运行
`./tool/bootstrap.sh` 或 `tool\bootstrap.bat` 重新生成。bootstrap 可能覆盖
平台 runner 的本地修改，执行前应先提交或备份。

提交前建议执行：

```bash
dart format lib test
dart analyze lib test
flutter test
./tool/check-repository.sh
```

Linux 构建：

```bash
flutter build linux --release
```

Windows 构建必须在 Windows 上执行：

```bat
flutter build windows --release
```

更新参考源码：

```bash
./tool/update-upstream.sh
```

更新后把各仓库新的提交号记录到 `third_party/SOURCES.lock`。如果把参考源码
作为普通文件提交到 GitHub，不要把它们内部的 `.git/` 历史目录一起嵌入；保留
源码、许可证和 `SOURCES.lock` 即可。发布前执行 `./tool/check-repository.sh`，
确认没有意外的嵌套仓库或本地凭据。

## 发布流程

项目仓库为 `https://github.com/qhshare/usbip-unified`，默认分支为 `main`。
发布新版本时按以下顺序执行：

1. 更新 `pubspec.yaml` 的版本号和 `CHANGELOG.md`，确认源码、离线资源与文档
   属于同一版本。
2. 运行 `dart format --output=none --set-exit-if-changed lib test`、
   `dart analyze`、`flutter test`、
   `./tool/check-repository.sh` 和离线资源校验；Linux 与 Windows 分别在对应
   构建机完成平台验证。
3. 在 Linux 构建机运行 `./tool/package-portable.sh linux`；在 Windows 构建机
   运行 `tool\package-portable.bat x64`，需要时再运行 `arm64`。产物名称带有
   `pubspec.yaml` 中 `+` 后的构建号，例如当前版本为
   `usbip-unified-linux-x64-portable-20261010.17.tar.gz` 和
   `usbip-unified-windows-x64-portable-20261010.17.zip`。
4. 只对当前构建号的压缩包生成校验文件：

```bash
build="$(sed -n 's/^version: //p' pubspec.yaml)"
build="${build#*+}"
(
  cd dist
  find . -maxdepth 1 -type f \
    \( -name "usbip-unified-*-portable-${build}.tar.gz" \
       -o -name "usbip-unified-*-portable-${build}.zip" \) \
    -printf '%f\0' | sort -z | xargs -0 -r sha256sum > "SHA256SUMS-${build}.txt"
  test -s "SHA256SUMS-${build}.txt" || {
    rm -f "SHA256SUMS-${build}.txt"
    echo "未找到构建号 ${build} 对应的便携包。" >&2
    exit 1
  }
)
```

当前版本会生成 `dist/SHA256SUMS-20261010.17.txt`。

5. 提交源码、测试、脚本、文档和必要的 `offline/` 资源；确认 `dist/`、
   `build/`、`.dart_tool/`、`.tmp/`、Wine 环境和第三方嵌套 `.git/` 没有进入
   暂存区。离线安装资源会随源码提交；单个当前资源文件低于 GitHub 的 100 MB
   单文件限制。后续如果新增大型安装包，应改用 Git LFS 或 GitHub Release。
6. 推送 `main`，创建版本标签和 GitHub Release。当前版本对应标签
   `v0.1.0-20261010.17`；将 Linux/Windows 压缩包和
   `SHA256SUMS-<build>.txt` 上传为 Release 附件。第三方通知、离线许可证和
   Release 说明继续保留在源码仓库；如未包含在便携包中，应在 Release 页面
   单独上传或链接。

不要把 `dist/` 目录或 Release 附件提交到源码历史。GitHub Actions 的
`.github/workflows/ci.yml` 会运行格式检查、静态分析、测试、仓库检查、离线
资源校验和 Linux release 构建；当前不会构建 Windows 便携包，也不会上传
构建产物或自动创建 Release。

## 目录结构

```text
.github/workflows/ci.yml     GitHub Actions 检查与 Linux release 构建
lib/                         Flutter UI 和 Dart 服务层
test/                        单元测试和 widget 测试
linux/                       Flutter Linux runner
windows/                     Flutter Windows runner
offline/                     有意提交的离线安装资源、脚本和校验清单
third_party/                 上游参考源码、许可证和来源锁定文件
tool/                        初始化、打包、更新和仓库检查脚本
run.sh                       Linux 开发运行脚本
run-windows.bat              Windows 开发运行脚本
tool/package-portable.sh     Linux 便携包脚本
tool/package-portable.bat    Windows 便携包脚本
BUILDING.md                 从源码构建、测试、打包和 Release 指南
ARCHITECTURE.md              模块边界、数据流和扩展方式
CONTRIBUTING.md              开发、测试和 Pull Request 规范
SECURITY.md                  安全边界和漏洞报告方式
CHANGELOG.md                 版本变更记录
THIRD_PARTY_NOTICES.md       第三方源码、工具和二进制声明
```

以下内容不应提交到 GitHub：`.dart_tool/`、`build/`、`dist/`、`.tmp/`、
`.wine*/`、IDE 私有配置、日志以及本地凭据。`pubspec.lock` 应提交，它能锁定
Flutter/Dart 依赖解析结果。

## 第三方源码与许可证

主程序使用 MIT License，见 [LICENSE](LICENSE)。参考项目和底层工具仍受各自
许可证约束：

- [K-Francis-H/usbip-gui](https://github.com/K-Francis-H/usbip-gui)
- [Snakefoxu/SnakeUSBIP](https://github.com/Snakefoxu/SnakeUSBIP)
- [Snakefoxu/SnakeUSBIP-Server](https://github.com/Snakefoxu/SnakeUSBIP-Server)

这三个参考项目在当前来源锁定中均为 GPL-3.0。它们的源码、许可证和提交号见
`third_party/`；不能把 GPL-3.0 实现直接复制进 MIT 主程序而不进行许可证审查。
Windows `usbipd-win`、`usbip-win2` 和 Linux `usbip` 也分别遵循各自项目的
许可证。重新分发二进制资源前，请保留相应许可证并核对上游发布条款。

完整的组件、来源、许可证和二进制再分发提醒见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。上传前请执行
`./tool/check-repository.sh`；如果检查到第三方目录中的嵌套 `.git`，应先将其
移出发布树，避免 GitHub 将源码目录记录成不完整的嵌套仓库。

## 安全注意事项

USB/IP 默认使用 TCP `3240`，协议本身没有端到端加密和身份认证。不要把端口
直接暴露到不可信公网。跨网络使用时，优先使用 WireGuard、Tailscale、ZeroTier
等受控 VPN，再限制防火墙只允许可信网段；使用 FRP 时也要设置访问控制和认证。

绑定、共享和客户端连接会把 USB 设备交给远程主机使用，一个设备通常只能被一
个客户端独占。驱动安装、UAC、root、`pkexec`、`sudo` 和系统包管理器操作都
可能改变系统状态，执行前应确认命令、资源来源和目标设备。

## 已知限制

- 当前没有账号系统、多节点发现、设备调度或权限管理服务。
- USB/IP 不会为设备数据提供应用层加密。
- Windows x86（32 位）没有内置完整工具链，当前不支持。
- Linux 离线包只覆盖文档列出的发行版和架构；其他发行版请使用在线安装或
  手动安装匹配包。
- Linux 内核模块和 Windows 虚拟 USB 驱动不能由 Flutter 运行时跨版本通用打包。
- 当前真机联调只覆盖 Windows x64 与 Linux amd64 之间的 CH340 串口；其他
  USB 设备类型、多设备并发、热插拔、睡眠恢复、高带宽和长时间稳定性仍需
  分别验证。

## 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md)
- [offline/README.md](offline/README.md)
- [third_party/README.md](third_party/README.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [SECURITY.md](SECURITY.md)
- [CHANGELOG.md](CHANGELOG.md)
- [BUILDING.md](BUILDING.md)
