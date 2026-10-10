# Changelog

## 0.1.0+20261010.17 - 2026-10-10

- 修复 Windows 便携版未嵌入管理员清单的问题，使 `usbipd bind/unbind`
  等操作能够触发 UAC 提权。
- 将 Windows 自动安装流程的实际来源（winget、包内 MSI 回退、官方客户端安装器）
  明确写入日志，并递增便携包构建号，避免误测旧 Release。
- 整理 GitHub 发布目录、支持矩阵和离线资源说明。
- 增加仓库校验、贡献指南和安全策略。
- 明确 Flutter 主程序与系统 USB/IP 工具、驱动和第三方参考源码的边界。
- 分离 Windows 共享端和客户端的工具路径、探测逻辑及设置保存。
- 将 Windows x64 官方 `USBip-0.9.8.0-x64.exe` USBip-win2 安装器和 VC++
  Runtime 随 Flutter asset 打包，支持离线安装客户端及其虚拟 USB 驱动。
- Windows x64 客户端安装改由官方安装器统一负责文件、DLL、驱动服务和虚拟
  USB 设备注册；项目不再手工复制客户端文件，也不再直接调用 `pnputil`。
- Windows 离线安装后验证共享端服务、客户端工具和可执行路径，并向 GUI 返回
  已确认的路径，避免安装后继续使用旧 PATH 或旧配置。
- GUI 增加构建号、运行环境、Flutter asset 和内置安装脚本诊断；便携包构建脚本
  会校验打包后的 PowerShell 安装脚本。

## 0.1.0

- 提供 Flutter Linux/Windows 统一管理界面。
- 支持服务端绑定/解绑和客户端连接/断开。
- 支持 Linux 在线/离线底层组件安装，以及 Windows x64/ARM64 离线安装资源。
- 增加命令日志、远程地址、端口配置和环境检查。

## 0.1.0+20260910.5

- Windows 在线安装固定安装共享端和客户端，不再允许旧版入口只传入 `-Server`。
- Windows 客户端安装结果继续校验 `usbipw.exe`、驱动服务和虚拟 USB 设备节点。
- 便携包版本号与应用启动日志同步，便于确认没有误启动旧 Release。
