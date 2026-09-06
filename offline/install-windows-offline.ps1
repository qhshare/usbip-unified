param(
  [switch]$Server,
  [switch]$Client,
  [ValidateSet('auto', 'x64', 'arm64')]
  [string]$Architecture = 'auto',
  [string]$ResultFile = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Quote-ProcessArgument {
  param([Parameter(Mandatory = $true)][string]$Value)
  if ($Value -notmatch '[\s"]') { return $Value }
  $escaped = $Value -replace '(\\*)"', '$1$1\"'
  $escaped = $escaped -replace '(\\+)$', '$1$1'
  return '"' + $escaped + '"'
}

function Write-InstallMessage {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host $Message
  if (-not [string]::IsNullOrWhiteSpace($ResultFile)) {
    try {
      Add-Content -LiteralPath $ResultFile -Value $Message -Encoding UTF8
    } catch {
      # Keep console output working if the temporary result file is unavailable.
    }
  }
}

function Resolve-TargetArchitecture {
  # PROCESSOR_ARCHITEW6432 is set when a 32-bit process runs on 64-bit Windows.
  $raw = $env:PROCESSOR_ARCHITEW6432
  if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $env:PROCESSOR_ARCHITECTURE }
  switch -Wildcard ($raw.ToUpperInvariant()) {
    'ARM64' { return 'arm64' }
    'AMD64' { return 'x64' }
    'X86'   { return 'x86' }
    default { return $raw.ToLowerInvariant() }
  }
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  # The Flutter process is normally started by a standard user. Re-launch this
  # same script through UAC so the portable GUI does not need admin rights.
  $childArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  if ($Server) { $childArguments += '-Server' }
  if ($Client) { $childArguments += '-Client' }
  $childArguments += @('-Architecture', $Architecture)
  if (-not [string]::IsNullOrWhiteSpace($ResultFile)) {
    $childArguments += @('-ResultFile', $ResultFile)
  }
  $argumentLine = ($childArguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '

  try {
    $elevated = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru
    exit $elevated.ExitCode
  } catch {
    Write-InstallMessage ('无法通过 UAC 获取管理员权限，安装已取消：' + $_.Exception.Message)
    exit 1223
  }
}

try {
  if (-not [string]::IsNullOrWhiteSpace($ResultFile)) {
    Set-Content -LiteralPath $ResultFile -Value '' -Encoding UTF8
  }

  if (-not $Server -and -not $Client) {
    Write-InstallMessage '用法: .\install-windows-offline.ps1 -Server [-Client] [-Architecture auto|x64|arm64]'
    Write-InstallMessage '      .\install-windows-offline.ps1 -Client'
    exit 2
  }

  $target = if ($Architecture -eq 'auto') { Resolve-TargetArchitecture } else { $Architecture }
  if ($target -eq 'x86') {
    throw ('检测到 32 位 Windows（x86）。usbipd-win 与 usbip-win2 均未发布 32 位版本，' +
           'Windows 端 USB/IP 需要 x64 或 ARM64 内核驱动，无法在 32 位系统上安装。')
  }

  $Win = Join-Path $Root "windows\$target"
  if (-not (Test-Path $Win)) {
    $available = (Get-ChildItem -Path (Join-Path $Root 'windows') -Directory | Select-Object -ExpandProperty Name) -join '、'
    throw "离线包中没有匹配架构 $target 的资源。已内置架构：$available。"
  }

  $installers = @{
    'x64'   = @{ Server = 'usbipd-win_5.3.0_x64.msi';   Client = 'USBip-0.9.7.7-x64.exe' }
    'arm64' = @{ Server = 'usbipd-win_5.3.0_arm64.msi'; Client = 'USBip-0.9.7.5-arm64-release.exe' }
  }
  if (-not $installers.ContainsKey($target)) {
    throw "不支持的架构: $target"
  }

  Write-InstallMessage "目标架构: $target"
  $restartRequired = $false
  if ($Server) {
    $msi = Join-Path $Win $installers[$target].Server
    if (-not (Test-Path $msi)) { throw "缺少离线安装包: $msi" }
    Write-InstallMessage "安装服务端: $msi"
    $msiArguments = '/i ' + (Quote-ProcessArgument $msi) + ' /qn /norestart'
    $msiProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArguments -Wait -PassThru
    if ($msiProcess.ExitCode -notin @(0, 1641, 3010)) {
      throw "服务端 MSI 安装失败，退出码: $($msiProcess.ExitCode)"
    }
    if ($msiProcess.ExitCode -in @(1641, 3010)) { $restartRequired = $true }
  }
  if ($Client) {
    $client = Join-Path $Win $installers[$target].Client
    if (-not (Test-Path $client)) { throw "缺少离线安装包: $client" }
    Write-InstallMessage "安装客户端: $client"
    $clientProcess = Start-Process -FilePath $client -Wait -PassThru
    if ($clientProcess.ExitCode -notin @(0, 1641, 3010)) {
      throw "客户端安装失败，退出码: $($clientProcess.ExitCode)"
    }
    if ($clientProcess.ExitCode -in @(1641, 3010)) { $restartRequired = $true }
  }

  if ($restartRequired) {
    Write-InstallMessage "Windows USB/IP 离线组件安装完成（$target）。安装程序要求重启 Windows 后才会生效。"
  } else {
    Write-InstallMessage "Windows USB/IP 离线组件安装完成（$target）。请返回应用检查环境。"
  }
} catch {
  Write-InstallMessage ('Windows USB/IP 离线安装失败：' + $_.Exception.Message)
  exit 1
}
