# Contributing

感谢参与 USBIP Unified Manager。项目仍处于早期阶段，提交前请先阅读
`README.md`、`ARCHITECTURE.md` 和 `SECURITY.md`，了解平台边界、离线资源和
USB/IP 的安全风险。

从源码构建、平台工具链、免安装打包和 GitHub Release 流程见
[BUILDING.md](BUILDING.md)。

## 开发环境

- Flutter stable
- Dart SDK 由 Flutter 提供
- Linux 开发需要 GTK 3、CMake、Ninja 和 USB/IP 命令行工具
- Windows 开发需要 Visual Studio 的 Desktop development with C++ 工作负载
- 真机 USB/IP 联调需要两台可互通的主机、对应的内核模块或 Windows 驱动

初始化工程：

```bash
./tool/bootstrap.sh
flutter pub get
```

Windows 使用：

```bat
tool\bootstrap.bat
flutter pub get
```

## 提交前检查

在项目根目录执行：

```bash
dart format lib test
dart analyze lib test
flutter test
./tool/check-repository.sh
```

如果修改了 Linux runner 或离线资源，还应执行：

```bash
flutter build linux --release
cd offline && sha256sum -c SHA256SUMS
```

Windows 构建必须在 Windows 主机上执行：

```bat
flutter build windows --release
```

## 代码约定

- UI 逻辑集中在 `lib/main.dart`，命令构造、权限、解析和状态模型集中在
  `lib/services/usbip_service.dart`。
- 新增平台或工具后，同时添加命令输出 fixture 和单元测试。
- 不要在 widget 中散落平台命令判断；将适配逻辑放入 service 层。
- 不要把密码、令牌、真实公网地址、真实设备信息或安装日志提交到仓库。
- 不要把 `build/`、`dist/`、`.dart_tool/`、`.tmp/`、Wine 环境或 IDE 配置提交到仓库。
- 不要修改 `third_party/` 中上游项目的历史文件来实现本项目功能。

## 离线资源与第三方源码

`offline/` 是有意提交的发布资源，新增或替换文件后必须更新：

```bash
cd offline
find . -type f ! -name SHA256SUMS -printf '%P\0' \
  | sort -z \
  | xargs -0 sha256sum > SHA256SUMS
```

提交前请确认资源来自可信发布页，并在 `offline/README.md` 记录版本、架构、
适用平台和已知限制。

`third_party/` 中的源码仅用于研究和适配参考。更新上游时使用：

```bash
./tool/update-upstream.sh
```

然后将新的提交号记录到 `third_party/SOURCES.lock`。上游源码保留各自许可证，
不能把 GPL-3.0 代码复制到 MIT 许可的主程序中而不进行许可证审查。

## Pull Request

Pull Request 请说明：

1. 修改的用户场景和受影响的平台。
2. 是否改变命令参数、权限行为、驱动安装或网络监听行为。
3. 执行过的测试和未能执行的真机验证。
4. 是否新增、替换或重新分发了第三方二进制文件。

涉及 USB/IP 绑定、连接、驱动、UAC、root 或防火墙的改动，应附上失败场景
和完整日志，而不是只提供成功截图。
