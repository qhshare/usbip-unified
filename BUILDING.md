# 构建指南

本文面向希望从源码构建 USBIP Unified Manager 的开发者和维护者。项目是
Flutter 桌面应用，Linux 和 Windows 的构建产物应在对应的平台构建机上生成。
目标用户不需要安装 Flutter SDK，但构建机需要。

## 1. 准备构建环境

### Linux

需要 Git、Flutter stable、Clang、CMake、Ninja、`pkg-config` 和 GTK 3 开发文件：

```bash
sudo apt update
sudo apt install -y git clang cmake ninja-build pkg-config libgtk-3-dev
flutter config --enable-linux-desktop
flutter doctor -v
```

`flutter doctor -v` 中的 Linux desktop 工具链应为可用状态。运行 USB/IP
功能所需的 `usbip`、`usbipd` 和内核模块不是 Flutter 编译依赖，请按
[README.md](README.md) 的平台说明另行安装。

### Windows

需要 Git for Windows、Flutter stable、Visual Studio 2022（或兼容版本）、
**Desktop development with C++** 工作负载、Windows 10/11 SDK 和 PowerShell：

```powershell
flutter config --enable-windows-desktop
flutter doctor -v
```

MSVC、Windows SDK、CMake 工具和 C++ 工作负载都必须通过检查。Linux 交叉环境
或 Wine 不能替代 Windows 真机对 UAC、服务、驱动签名、防火墙和 USB/IP 的验证。

## 2. 获取源码和资源

```bash
git clone https://github.com/<用户名>/<仓库名>.git
cd <仓库名>
flutter pub get
```

仓库中的 `offline/` 是有意保留的版本化安装资源，正常克隆后不需要再次下载。
构建前建议验证：

```bash
cd offline
sha256sum -c SHA256SUMS
cd ..
```

Windows 没有 `sha256sum` 时，可以使用 `Get-FileHash` 检查单个资源：

```powershell
Get-ChildItem -Recurse offline -File |
  Where-Object { $_.Name -ne 'SHA256SUMS' } |
  ForEach-Object { Get-FileHash $_.FullName -Algorithm SHA256 }
```

如果 `linux/` 或 `windows/` 平台目录缺失，使用脚本生成 Flutter runner：

```bash
./tool/bootstrap.sh
```

```bat
tool\bootstrap.bat
```

初始化脚本会执行 `flutter create --platforms=linux,windows` 和
`flutter pub get`，可能重新生成平台模板。已有平台目录的正常克隆只需执行
`flutter pub get`；平台 runner 有本地修改时，先提交或备份再执行 bootstrap。

## 3. 开发运行

Linux：

```bash
./run.sh
```

等价于 `flutter run -d linux`。脚本参数会继续传给 Flutter，例如：

```bash
./run.sh --verbose
```

Windows：

```bat
run-windows.bat
```

等价于 `flutter run -d windows`。Flutter 热重载适合 Dart/UI 修改；修改
`pubspec.yaml`、asset 列表、C++ runner、安装器或平台构建文件后，应停止并
重新运行应用。

## 4. 测试和静态检查

提交前在项目根目录执行：

```bash
dart format --output=none --set-exit-if-changed lib test
dart analyze lib test
flutter test
./tool/check-repository.sh
```

本地需要格式化时执行 `dart format lib test`。仓库检查会验证离线资源清单、
嵌套 Git 元数据和常见私钥文件，但不会替代真实 Linux/Windows USB/IP 联调，
也不会安装内核模块或 Windows 驱动。

## 5. 构建 Release

### Linux

```bash
flutter build linux --release
```

产物目录是 `build/linux/x64/release/bundle/`。其中的 `usbip_unified` 必须和
同目录的 `data/`、`lib/` 一起使用，不能只复制可执行文件。

### Windows

必须在 Windows 构建机执行：

```bat
flutter build windows --release
```

x64 产物目录是 `build/windows/x64/runner/Release/`。ARM64 构建：

```bat
flutter build windows --release --target-platform windows-arm64
```

Windows 产物中的 `usbip_unified.exe` 必须和相邻的 `data/` 目录一起分发。
ARM64 必须使用匹配的 Flutter/Visual Studio 工具链和 ARM64 离线资源，不能用
x64 驱动替代。

## 6. 生成免安装包

打包脚本会先执行 Release 构建，再将完整 Flutter bundle 压缩到 `dist/`。

Linux：

```bash
./tool/package-portable.sh linux
```

输出：`dist/usbip-unified-linux-x64-portable.tar.gz`。

Windows：

```bat
tool\package-portable.bat x64
tool\package-portable.bat arm64
```

输出：

```text
dist/usbip-unified-windows-x64-portable.zip
dist/usbip-unified-windows-arm64-portable.zip
```

Windows 批处理使用 PowerShell `Compress-Archive`，不需要单独安装 zip。解压
后保留整个目录和 `data/`；Linux bundle 还需要保留 `lib/`。免安装只描述
Flutter 图形应用的分发方式，USB/IP 工具、服务、内核模块和 Windows 虚拟
USB 驱动仍需目标系统已有，或由应用安装器安装。

## 7. GitHub Release

`build/`、`dist/`、`.dart_tool/`、`.tmp/` 和 Wine 环境已被 `.gitignore`
排除。源码仓库与构建产物分开发布：

1. 提交源码、测试、脚本、文档和明确需要的 `offline/` 资源。
2. 在对应平台构建 `dist/` 压缩包。
3. 为 Release 产物生成校验值：

```bash
find dist -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\0' \
  | sort -z \
  | xargs -0 -r -I{} sha256sum "dist/{}" > dist/SHA256SUMS
```

Windows 可使用：

```powershell
Get-ChildItem dist -File |
  Where-Object { $_.Name -ne 'SHA256SUMS' } |
  ForEach-Object { Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 }
```

4. 在 GitHub 创建版本标签和 Release。
5. 上传 Linux/Windows 压缩包、校验值、`THIRD_PARTY_NOTICES.md` 和架构说明。

不要把 `dist/` 复制到 Git 暂存区。未来若离线资源超过 GitHub 单文件限制，
应改用 Git LFS 或 Release 附件，并同步更新 `offline/README.md` 和校验清单。

## 8. 常见问题

### 找不到 Flutter

执行 `flutter doctor -v`，并将 Flutter SDK 的 `bin/` 加入 `PATH` 后重新打开
终端。

### Linux 缺少 GTK、CMake 或 Ninja

Debian/Ubuntu/Kali 可执行：

```bash
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev
```

其他发行版请安装对应名称的开发包。

### 构建成功但程序无法启动

确认运行的是完整 bundle，而不是只复制可执行文件。Linux 检查 `data/` 和
`lib/`，Windows 检查 `data/`，并确认桌面会话可用。

### 应用启动但看不到 USB 设备

检查目标系统是否安装 `usbip`/`usbipd` 或 `usbipd-win`，当前用户是否具备
root/管理员权限，以及 Linux 内核模块或 Windows 虚拟 USB 驱动是否工作。优先
查看应用日志和原生命令输出，这不一定是 Flutter 构建失败。

### 离线安装为什么使用 `/tmp`

这是正常流程。Flutter asset 只读，安装器先把资源提取到临时目录，再调用
`dpkg`、MSI 或 Windows 安装程序，完成后清理临时目录。真正的安装位置不是
`/tmp`，而是由系统安装器决定。

### 为什么没有 Windows 32 位版本

当前 Windows USB/IP 服务端和虚拟 USB 客户端没有完整可支持的 x86 驱动组合。
能生成普通 x86 Flutter 程序，不代表 USB/IP 驱动链路可用，因此项目暂不发布
Windows x86 版本。

## 9. 相关文档

- [README.md](README.md)：功能、安装和使用
- [README.en.md](README.en.md)：English user guide
- [ARCHITECTURE.md](ARCHITECTURE.md)：模块边界和数据流
- [CONTRIBUTING.md](CONTRIBUTING.md)：代码贡献和提交检查
- [offline/README.md](offline/README.md)：离线资源矩阵和安装器
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)：第三方许可证和二进制声明
