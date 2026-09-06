@echo off
setlocal
cd /d "%~dp0.."
set "ARCH=%~1"
if "%ARCH%"=="" set "ARCH=x64"
if /I not "%ARCH%"=="x64" if /I not "%ARCH%"=="arm64" (
  echo 用法：tool\package-portable.bat [x64^|arm64]
  exit /b 2
)
where flutter >nul 2>nul
if errorlevel 1 (
  echo 错误：未找到 Flutter SDK。
  exit /b 1
)
echo 正在构建 Windows %ARCH% 免安装版本...
flutter build windows --release --target-platform windows-%ARCH%
if errorlevel 1 exit /b 1
if not exist dist mkdir dist
powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path 'build\windows\%ARCH%\runner\Release\*' -DestinationPath 'dist\usbip-unified-windows-%ARCH%-portable.zip' -Force"
if errorlevel 1 exit /b 1
echo Windows 免安装包：dist\usbip-unified-windows-%ARCH%-portable.zip
endlocal
