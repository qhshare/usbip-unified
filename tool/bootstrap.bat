@echo off
cd /d "%~dp0.."
where flutter >nul 2>nul
if errorlevel 1 (
  echo 错误：未找到 Flutter SDK，请先安装 Flutter stable。
  exit /b 1
)
flutter create --platforms=windows,linux --project-name usbip_unified .
if errorlevel 1 exit /b 1
flutter pub get
