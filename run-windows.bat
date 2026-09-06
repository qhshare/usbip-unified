@echo off
cd /d "%~dp0"
where flutter >nul 2>nul
if errorlevel 1 (
  echo 错误：未找到 Flutter SDK，请先安装 Flutter 并加入 PATH。
  exit /b 1
)
if not exist windows (
  call tool\bootstrap.bat
  if errorlevel 1 exit /b 1
)
flutter run -d windows %*
