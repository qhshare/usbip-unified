# USBIP Unified Manager

[English](README.en.md) | 中文

一个使用 Flutter 开发的 Linux/Windows USB/IP 图形管理器。它用统一界面
管理本机 USB 设备共享、远程 USB 设备连接、绑定、解绑、断开、端口和底层
组件安装。

> 项目状态：早期版本（`0.1.0`）。Linux 流程已在开发环境验证；Windows 的
> 驱动、UAC、防火墙和真实 USB/IP 连接必须在 Windows x64/ARM64 真机继续验证。

## 目录

- [功能](#功能)
- [工作原理](#工作原理)
- [支持矩阵](#支持矩阵)
- [30 秒运行](#30-秒运行)
- [从源码构建](#从源码构建)
- [Linux](#linux)
- [Windows](#windows)
- [使用流程](#使用流程)
- [离线安装](#离线安装)
- [免安装发布包](#免安装发布包)
- [开发与测试](#开发与测试)
- [上传 GitHub](#上传-github)
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
| Windows x64 | 支持 | 支持 | MSI + EXE | 内置 `usbipd-win` 和 `usbip-win2` |
| Windows ARM64 | 支持 | 支持 | MSI + EXE | 使用 ARM64 对应驱动和工具 |
| Windows x86（32 位） | 不支持 | 不支持 | 不提供 | 当前上游没有可用的完整 32 位驱动组合 |
| macOS | 不支持 | 不支持 | 不提供 | 当前项目没有维护 macOS USB/IP 后端 |

“支持”表示代码和命令适配，不等于每种硬件、内核、驱动版本都已经真机
验证。Linux 离线 `.deb` 不是通用 Linux 安装包；Windows 离线资源也必须与
系统架构匹配。

## 30 秒运行

### Linux 开发运行

先安装 Flutter stable 和 Linux desktop 依赖，然后：

```bash
cd USBIP-整合
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

设置页的“在线安装”调用当前系统包管理器。也可以手动安装：

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
是 x64 `0.9.7.7`，ARM64 `0.9.7.5`；这是当前资源选择，不代表所有新版本都
适合生产使用。

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

- Windows x64/ARM64：`usbipd-win` MSI 和 `usbip-win2` 客户端安装程序。
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

## 免安装发布包

Flutter 桌面应用本身是解压即用目录，不需要 MSI、deb、注册表或 Flutter SDK。
底层 USB/IP 工具和驱动仍需由目标系统已有环境或应用内安装器提供。

Linux 在 Linux 主机上构建：

```bash
./tool/bootstrap.sh
./tool/package-portable.sh linux
```

输出：

```text
dist/usbip-unified-linux-x64-portable.tar.gz
```

Windows 必须在 Windows 构建机上构建：

```bat
tool\bootstrap.bat
tool\package-portable.bat x64
tool\package-portable.bat arm64
```

输出：

```text
dist\usbip-unified-windows-x64-portable.zip
dist\usbip-unified-windows-arm64-portable.zip
```

解压后运行 `usbip_unified` 或 `usbip_unified.exe`。不要删除同目录的 `data/`
目录；`offline/` 资源位于 Flutter asset 中。`dist/`、`build/` 和本地开发
环境默认被 `.gitignore` 排除，正式发布包应上传到 GitHub Releases，而不是
提交到源码仓库。

## 开发与测试

初始化或重新生成桌面 runner：

```bash
./tool/bootstrap.sh
flutter pub get
```

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

## 上传 GitHub

项目根目录已经适合初始化为独立 Git 仓库。当前目录中的 `.git/` 只包含本地
仓库元数据，不会被再次提交；不要把上级目录的 Git 仓库当作本项目仓库使用。
首次创建 GitHub 空仓库后，在项目根目录执行：

```bash
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git add -A
git status --short
git commit -m "Initial USBIP Unified Manager release"
git push -u origin main
```

确认 `git status --short` 中没有 `.dart_tool/`、`build/`、`dist/`、`.tmp/`、
`.wine*/`、IDE 配置或第三方嵌套 `.git`。离线安装资源会随源码提交；单个当前
资源文件低于 GitHub 的 100 MB 单文件限制。后续如果新增大型安装包，应改用
Git LFS 或 GitHub Releases，不要把构建产物长期堆在源码历史中。

推送源码后，再将 `dist/` 中的 Linux/Windows 免安装压缩包作为 GitHub Release
附件发布。Release 页面应同时附上 `THIRD_PARTY_NOTICES.md`、校验值和目标架构
说明；不要把 `dist/` 目录直接提交到源码仓库。

## 目录结构

```text
lib/                         Flutter UI 和 Dart 服务层
test/                        单元测试和 widget 测试
linux/                       Flutter Linux runner
windows/                     Flutter Windows runner
offline/                     有意提交的离线安装资源、脚本和校验清单
third_party/                 上游参考源码、许可证和来源锁定文件
tool/                        初始化、打包、更新和仓库检查脚本
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
- Windows 真机上的驱动签名、UAC、防火墙、睡眠恢复和多种 USB 设备组合仍需
  在对应 Windows 版本上验证。

## 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md)
- [offline/README.md](offline/README.md)
- [third_party/README.md](third_party/README.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [SECURITY.md](SECURITY.md)
- [CHANGELOG.md](CHANGELOG.md)
- [BUILDING.md](BUILDING.md)
