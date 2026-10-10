# Keep this installer ASCII-only.
# Windows PowerShell 5.1 treats a UTF-8 script without a BOM as an ANSI file.
# Non-ASCII text would then be corrupted and can make the script unparsable.
param(
  [switch]$Server,
  [switch]$Client,
  [ValidateSet('auto', 'x64', 'arm64')]
  [string]$Architecture = 'auto',
  [string]$ResultFile = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallerRevision = 'official-usbip-win2-0.9.8.0-v2'

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
      # ASCII output keeps this result file readable by Windows PowerShell 5.1
      # and by the Flutter process regardless of the active code page.
      Add-Content -LiteralPath $ResultFile -Value $Message -Encoding ASCII
    } catch {
      # Keep console output working if the temporary result file is unavailable.
    }
  }
}

function Write-InstallStatus {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Value
  )
  # Stable ASCII markers are consumed by the Flutter UI. Keep the descriptive
  # log messages above them because they remain useful when copied manually.
  Write-InstallMessage ($Name + '|' + $Value)
}

function Find-InstalledExecutable {
  param(
    [Parameter(Mandatory = $true)][string[]]$Names,
    [Parameter(Mandatory = $true)][string[]]$Directories
  )
  $roots = @(
    $env:ProgramW6432,
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:LOCALAPPDATA,
    $env:ProgramData,
    $env:APPDATA,
    $env:USERPROFILE
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  foreach ($root in $roots) {
    foreach ($directory in $Directories) {
      foreach ($name in $Names) {
        $candidate = Join-Path (Join-Path $root $directory) $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          return $candidate
        }
      }
    }
  }
  return $null
}

function Find-PathExecutable {
  param([Parameter(Mandatory = $true)][string[]]$Names)
  foreach ($name in $Names) {
    try {
      $command = Get-Command $name -ErrorAction SilentlyContinue
      if ($null -ne $command -and
          $command.CommandType -eq 'Application' -and
          (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        return $command.Source
      }
    } catch {
      # PATH lookup is only one fallback; continue with fixed and registered paths.
    }
  }
  return $null
}

function Get-ExecutableFromCommandLine {
  param([Parameter(Mandatory = $true)][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

  $quoted = [regex]::Match($Value, '(?i)"([^"]+\.exe)"')
  if ($quoted.Success) { return $quoted.Groups[1].Value }

  $unquoted = [regex]::Match($Value, '(?i)(?:[A-Za-z]:\\|\\\\)[^\r\n]*?\.exe')
  if ($unquoted.Success) { return $unquoted.Value.Trim() }
  return $null
}

function Get-RegistryInstallDirectories {
  $locations = @()
  $keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )

  foreach ($key in $keys) {
    try {
      $entries = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
      foreach ($entry in $entries) {
        $displayName = [string]$entry.DisplayName
        if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
        $normalizedName = ($displayName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($normalizedName -notmatch 'usbip') { continue }

        $installLocation = [string]$entry.InstallLocation
        if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
          $locations += $installLocation.Trim().Trim('"')
        }

        foreach ($field in @('DisplayIcon', 'UninstallString')) {
          $path = Get-ExecutableFromCommandLine ([string]$entry.$field)
          if ($null -ne $path) {
            $parent = Split-Path -Parent $path
            if (-not [string]::IsNullOrWhiteSpace($parent)) { $locations += $parent }
          }
        }
      }
    } catch {
      # A missing registry view or a restricted key must not stop installation.
    }
  }
  return $locations | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
}

function Find-ExecutableBelow {
  param(
    [Parameter(Mandatory = $true)][string[]]$Directories,
    [Parameter(Mandatory = $true)][string[]]$Names,
    [int]$MaxDepth = 3
  )
  $queue = New-Object System.Collections.Queue
  foreach ($directory in $Directories) {
    if (Test-Path -LiteralPath $directory -PathType Container) {
      $queue.Enqueue(@($directory, 0))
    }
  }

  while ($queue.Count -gt 0) {
    $item = $queue.Dequeue()
    $directory = [string]$item[0]
    $depth = [int]$item[1]
    foreach ($name in $Names) {
      $candidate = Join-Path $directory $name
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    if ($depth -ge $MaxDepth) { continue }

    try {
      $children = Get-ChildItem -LiteralPath $directory -Directory -ErrorAction SilentlyContinue
      foreach ($child in $children) {
        $queue.Enqueue(@($child.FullName, $depth + 1))
      }
    } catch {
      # Ignore inaccessible folders and continue with the other candidates.
    }
  }
  return $null
}

function Find-ClientExecutable {
  $names = @('usbipw.exe', 'usbip.exe', 'usbip-win2.exe')
  $directories = @(
    'USBip',
    'USBip\bin',
    'USBIP',
    'USBIP\bin',
    'usbip-win2',
    'usbip-win2\bin',
    'USBip-win2',
    'USBip-win2\bin',
    'Programs\USBip',
    'Programs\USBip\bin',
    'Programs\USBIP',
    'Programs\USBIP\bin',
    'Programs\usbip-win2',
    'Programs\usbip-win2\bin'
  )
  $standard = @()
  $roots = @(
    $env:ProgramW6432,
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:LOCALAPPDATA,
    $env:ProgramData,
    $env:APPDATA,
    $env:USERPROFILE
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
  foreach ($root in $roots) {
    foreach ($directory in $directories) {
      $standard += Join-Path (Join-Path $root $directory) ''
    }
  }

  $registry = @(Get-RegistryInstallDirectories)
  $allDirectories = @($standard + $registry) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
  return Find-ExecutableBelow -Directories $allDirectories -Names $names -MaxDepth 3
}

function Find-ServiceExecutable {
  $line = Get-ServiceCommandLine
  if ([string]::IsNullOrWhiteSpace($line)) { return $null }
  if ($line.StartsWith('"')) {
    $closingQuote = $line.IndexOf('"', 1)
    if ($closingQuote -gt 1) {
      $candidate = $line.Substring(1, $closingQuote - 1)
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
  }
  $match = [regex]::Match($line, '(?i)(?:\\\\\?\\)?[A-Za-z]:\\.*?\.exe')
  if ($match.Success -and (Test-Path -LiteralPath $match.Value -PathType Leaf)) {
    return $match.Value
  }
  return $null
}

function Get-ServiceCommandLine {
  try {
    $service = Get-CimInstance Win32_Service -Filter "Name='usbipd'" -ErrorAction Stop
    return [string]$service.PathName
  } catch {
    return $null
  }
}

function Wait-UsbipdServiceRunning {
  param([int]$TimeoutSeconds = 15)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastStatus = 'NotFound'
  $startRequested = $false
  while ((Get-Date) -lt $deadline) {
    $service = Get-Service -Name 'usbipd' -ErrorAction SilentlyContinue
    if ($null -eq $service) {
      Start-Sleep -Milliseconds 500
      continue
    }

    $lastStatus = [string]$service.Status
    if ($service.Status -eq 'Running') {
      return $service
    }

    # MSI normally starts usbipd itself. If the service is disabled or stopped,
    # request a start once and then let the Service Control Manager settle.
    if (-not $startRequested -and $service.Status -eq 'Stopped') {
      try {
        Start-Service -Name 'usbipd' -ErrorAction Stop
        $startRequested = $true
        Write-InstallMessage 'usbipd service start requested; waiting for Running state.'
      } catch {
        throw ('The usbipd service could not be started: ' + $_.Exception.Message)
      }
    }
    Start-Sleep -Milliseconds 500
  }

  $service = Get-Service -Name 'usbipd' -ErrorAction SilentlyContinue
  if ($null -ne $service -and $service.Status -eq 'Running') {
    return $service
  }
  throw "The usbipd service did not reach Running state within $TimeoutSeconds seconds. Current status: $lastStatus"
}

function Write-RegistryDiagnostics {
  $keys = @(
    'HKLM\SOFTWARE\usbipd-win',
    'HKLM\SOFTWARE\WOW6432Node\usbipd-win',
    'HKLM\SYSTEM\CurrentControlSet\Services\usbipd'
  )
  foreach ($key in $keys) {
    try {
      $raw = @(& reg.exe query $key 2>&1)
      $code = $LASTEXITCODE
      Write-InstallMessage "Registry key: $key (exit code: $code)"
      if ($raw.Count -eq 0) {
        Write-InstallMessage '  no output'
      } else {
        foreach ($line in $raw) {
          $text = [string]$line
          if (-not [string]::IsNullOrWhiteSpace($text)) {
            Write-InstallMessage ('  ' + $text.Trim())
          }
        }
      }
    } catch {
      Write-InstallMessage ('Registry query failed for ' + $key + ': ' + $_.Exception.Message)
    }
  }
}

function Write-ExecutableDiagnostics {
  param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][string[]]$Paths
  )
  $seen = @{}
  foreach ($path in $Paths) {
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $normalized = $path.Trim().ToLowerInvariant()
    if ($seen.ContainsKey($normalized)) { continue }
    $seen[$normalized] = $true
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    $version = 'unknown'
    if ($exists) {
      try {
        $version = [string](Get-Item -LiteralPath $path).VersionInfo.FileVersion
        if ([string]::IsNullOrWhiteSpace($version)) { $version = 'unknown' }
      } catch {
        $version = 'unavailable'
      }
    }
    Write-InstallMessage "$Label candidate: $path | exists: $exists | file version: $version"
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

function Install-VisualCRuntime {
  param([Parameter(Mandatory = $true)][string]$InstallerPath)

  if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "Missing Microsoft Visual C++ Redistributable: $InstallerPath"
  }

  Write-InstallMessage "Installing Microsoft Visual C++ Redistributable: $InstallerPath"
  $process = Start-Process -FilePath $InstallerPath `
    -ArgumentList @('/install', '/quiet', '/norestart') `
    -Wait `
    -PassThru
  Write-InstallMessage "Visual C++ Redistributable exit code: $($process.ExitCode)"

  # 0 = installed, 1638 = an equal/newer version is already present,
  # 1641/3010 = installed and Windows requested a restart.
  if ($process.ExitCode -notin @(0, 1638, 1641, 3010)) {
    throw "Microsoft Visual C++ Redistributable installation failed. Exit code: $($process.ExitCode)"
  }
  return ($process.ExitCode -in @(1641, 3010))
}

function Get-VisualCRuntimeStatus {
  $windowsRoot = $env:WINDIR
  if ([string]::IsNullOrWhiteSpace($windowsRoot)) { $windowsRoot = 'C:\Windows' }
  $system32 = Join-Path $windowsRoot 'System32'
  $required = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
  $missing = @($required | Where-Object {
      -not (Test-Path -LiteralPath (Join-Path $system32 $_) -PathType Leaf)
    })
  if ($missing.Count -eq 0) { return 'available' }
  Write-InstallMessage ('WARNING: Visual C++ runtime files are still missing from ' +
    $system32 + ': ' + ($missing -join ', '))
  return 'missing'
}

function Get-UsbipVirtualDevices {
  # usbip-win2 needs a root-enumerated UDE device in addition to the driver
  # service. The device instance is created by devnode.exe, not by pnputil
  # alone. Do not treat the legacy usbip_vhci device as a valid replacement.
  $devices = @()
  try {
    $devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
      Where-Object {
        $instanceId = [string]$_.PNPDeviceID
        $hardwareIds = @($_.HardwareID | ForEach-Object { [string]$_ })
        $instanceId -match '(?i)^ROOT\\USBIP_WIN2\\' -or
          $hardwareIds -contains 'ROOT\USBIP_WIN2\UDE'
      })
  } catch {
    Write-InstallMessage ('Unable to query USB/IP PnP devices with CIM: ' + $_.Exception.Message)
    try {
      $devices = @(Get-PnpDevice -PresentOnly:$false -ErrorAction Stop |
        Where-Object {
          $instanceId = [string]$_.InstanceId
          $instanceId -match '(?i)^ROOT\\USBIP_WIN2\\'
        })
    } catch {
      Write-InstallMessage ('Unable to query USB/IP PnP devices with Get-PnpDevice: ' + $_.Exception.Message)
    }
  }
  return $devices
}

function Get-BundledClientDriverServices {
  $names = @('usbip2_ude', 'usbip2_filter')
  $items = @()
  try {
    $items = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop |
      Where-Object { $names -contains $_.Name })
  } catch {
    Write-InstallMessage ('Unable to query registered USB/IP drivers with CIM: ' + $_.Exception.Message)
  }

  # CIM can return one driver while omitting another one. Query every missing
  # name with sc.exe instead of using the old all-or-nothing fallback; the
  # installer must distinguish a complete driver chain from a partial one.
  $detectedNames = @(
    $items |
      ForEach-Object { [string]$_.Name } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.ToLowerInvariant() } |
      Sort-Object -Unique
  )
  foreach ($name in $names) {
    if ($detectedNames -contains $name.ToLowerInvariant()) { continue }
    try {
      $output = @(& sc.exe query $name 2>&1)
      $code = $LASTEXITCODE
      if ($code -eq 0 -and ($output -join "`n") -match 'SERVICE_NAME') {
        $items += [pscustomobject]@{
          Name = $name
          State = 'unknown'
          Status = 'registered'
        }
      }
    } catch {
      # Continue with the remaining driver service names.
    }
  }
  return $items
}

function Write-BundledClientDriverDiagnostics {
  foreach ($name in @('usbip2_ude', 'usbip2_filter')) {
    try {
      $output = @(& sc.exe query $name 2>&1)
      $code = $LASTEXITCODE
      Write-InstallMessage "sc.exe query $name exit code: $code"
      if ($output.Count -eq 0) {
        Write-InstallMessage '  no output'
      } else {
        foreach ($line in $output) {
          $text = [string]$line
          if (-not [string]::IsNullOrWhiteSpace($text)) {
            Write-InstallMessage ('  ' + $text.Trim())
          }
        }
      }
    } catch {
      Write-InstallMessage ("sc.exe query $name failed: " + $_.Exception.Message)
    }
  }
}

function Write-WindowsEnvironmentDiagnostics {
  Write-InstallMessage ("PowerShell version: " + $PSVersionTable.PSVersion.ToString())
  Write-InstallMessage ("Process architecture: " + [Environment]::Is64BitProcess)
  Write-InstallMessage ("OS architecture: " + (Resolve-TargetArchitecture))
  try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Write-InstallMessage ("Windows version: " + $os.Caption + ' ' + $os.Version + ' build ' + $os.BuildNumber)
  } catch {
    Write-InstallMessage ('Windows version query failed: ' + $_.Exception.Message)
  }
  try {
    $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
    Write-InstallMessage ("Secure Boot enabled: " + $secureBoot)
  } catch {
    Write-InstallMessage 'Secure Boot status: unavailable (legacy BIOS, unsupported cmdlet, or access denied)'
  }
}

function Verify-BundledClientInstallation {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string]$ClientDirectory
  )

  $file = Get-Item -LiteralPath $Executable -ErrorAction Stop
  $version = [string]$file.VersionInfo.FileVersion
  if ([string]::IsNullOrWhiteSpace($version)) { $version = 'unknown' }
  Write-InstallMessage "Client executable version: $version"

  $probeOutput = @()
  $probeCode = 1
  $probeStarted = $true
  try {
    # `port` is read-only and exercises the Windows loader, bundled DLLs, and
    # the client executable without requiring a remote USB/IP server.
    $probeOutput = @(& $Executable port 2>&1)
    $probeCode = $LASTEXITCODE
  } catch {
    $probeStarted = $false
    Write-InstallMessage ('usbipw port probe raised an exception: ' + $_.Exception.Message)
  }
  Write-InstallMessage "usbipw port probe exit code: $probeCode"
  foreach ($line in $probeOutput) {
    $text = [string]$line
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      Write-InstallMessage ('  ' + $text.Trim())
    }
  }
  if (-not $probeStarted) {
    throw 'usbipw.exe could not be started. Check Visual C++ Redistributable, bundled DLLs, architecture, and client installation.'
  }
  if ($probeCode -ne 0) {
    Write-InstallMessage 'WARNING: usbipw.exe started, but the read-only port probe returned non-zero.'
    Write-InstallMessage 'This can be normal before a config file, virtual port, or remote connection exists.'
  }

  # Query both usbip-win2 kernel services after the executable probe. The
  # previous implementation referenced $services without assigning it,
  # which made a valid client installation look incomplete or produced an
  # empty diagnostic result in Windows PowerShell 5.1.
  $services = @(Get-BundledClientDriverServices)
  $requiredDriverNames = @('usbip2_ude', 'usbip2_filter')
  $detectedDriverNames = @(
    $services |
      ForEach-Object { [string]$_.Name } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.ToLowerInvariant() } |
      Sort-Object -Unique
  )
  $missingDriverNames = @(
    $requiredDriverNames |
      Where-Object { $detectedDriverNames -notcontains $_.ToLowerInvariant() }
  )
  $allDriverServicesAvailable = $missingDriverNames.Count -eq 0
  if (-not $allDriverServicesAvailable) {
    $driverStatus = 'missing'
    if ($services.Count -eq 0) {
      Write-InstallMessage 'WARNING: no USB/IP virtual bus driver service was registered.'
    } else {
      Write-InstallMessage ('WARNING: USB/IP virtual bus driver chain is incomplete. Missing: ' +
        ($missingDriverNames -join ', '))
    }
    Write-InstallMessage 'Re-run the installer as administrator and check driver signature or Windows security policy.'
  } else {
    $driverStatus = 'available'
  }
  if ($services.Count -gt 0) {
    foreach ($service in $services) {
      Write-InstallMessage "USB/IP client driver service: $($service.Name)|$($service.State)|$($service.Status)"
    }
  }

  $devices = @(Get-UsbipVirtualDevices)
  if ($devices.Count -eq 0) {
    $deviceStatus = if ($allDriverServicesAvailable) { 'pending_restart' } else { 'missing' }
    Write-InstallMessage 'WARNING: no USB/IP virtual USB device node is present.'
    if ($allDriverServicesAvailable) {
      Write-InstallMessage 'The complete driver service chain is registered; restart Windows or rescan PnP devices.'
    } else {
      Write-InstallMessage 'The driver service chain is incomplete; repair the client installation before restarting.'
    }
  } else {
    $deviceStatus = 'available'
  }
  Write-InstallMessage "USB/IP virtual device nodes: $($devices.Count)"

  Write-InstallMessage "Client install directory: $ClientDirectory"
  return [pscustomobject]@{
    DriverStatus = $driverStatus
    DeviceStatus = $deviceStatus
    RestartRequired = ($deviceStatus -eq 'pending_restart')
  }
}

function Install-OfficialUsbipWin2Client {
  param([Parameter(Mandatory = $true)][string]$InstallerPath)

  if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "Missing official usbip-win2 installer: $InstallerPath"
  }

  Write-InstallMessage "Installing official usbip-win2 client: $InstallerPath"
  Write-InstallMessage 'The official installer owns the client files, driver packages, and virtual USB device registration.'
  $installerArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
  Write-InstallMessage ('usbip-win2 command: "' + $InstallerPath + '" ' +
    ($installerArguments -join ' '))
  $process = Start-Process -FilePath $InstallerPath `
    -ArgumentList $installerArguments `
    -Wait `
    -PassThru
  Write-InstallMessage "usbip-win2 installer exit code: $($process.ExitCode)"
  if ($process.ExitCode -notin @(0, 1641, 3010)) {
    throw "Official usbip-win2 client installation failed. Exit code: $($process.ExitCode)"
  }

  $restartRequired = $process.ExitCode -in @(1641, 3010)
  Start-Sleep -Seconds 2
  $executable = Find-PathExecutable -Names @('usbipw.exe', 'usbip.exe', 'usbip-win2.exe')
  if ($null -eq $executable) {
    $executable = Find-ClientExecutable
  }
  if ($null -eq $executable) {
    throw 'The official usbip-win2 installer returned success, but no client executable was found.'
  }

  $clientDirectory = Split-Path -Parent $executable
  Write-InstallMessage "Client executable discovered: $executable"
  $verification = Verify-BundledClientInstallation `
    -Executable $executable `
    -ClientDirectory $clientDirectory
  Write-BundledClientDriverDiagnostics
  return [pscustomobject]@{
    Executable = $executable
    DriverStatus = [string]$verification.DriverStatus
    DeviceStatus = [string]$verification.DeviceStatus
    RestartRequired = ($restartRequired -or [bool]$verification.RestartRequired)
  }
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  # Re-launch this same script through UAC so the portable GUI does not need
  # to be started as administrator.
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
    Write-InstallMessage ('Unable to obtain administrator permission. Installation cancelled: ' + $_.Exception.Message)
    exit 1223
  }
}

try {
  if (-not [string]::IsNullOrWhiteSpace($ResultFile)) {
    Set-Content -LiteralPath $ResultFile -Value '' -Encoding ASCII
  }

  $installStatus = 'failed'
  $target = ''
  $serverStatus = if ($Server) { 'pending' } else { 'not_requested' }
  $clientStatus = if ($Client) { 'pending' } else { 'not_requested' }
  $clientDriverStatus = if ($Client) { 'pending' } else { 'not_requested' }
  $clientDeviceStatus = if ($Client) { 'pending' } else { 'not_requested' }
  $serverExecutable = $null
  $clientExecutable = $null
  $restartRequired = $false

  # Keep the complete revision marker literal in the bundled script. Flutter
  # performs a preflight fingerprint before launching the elevated installer,
  # so concatenating the value here would make a valid current bundle look
  # like an old legacy installer.
  Write-InstallMessage 'USBIP_UNIFIED_INSTALLER_REVISION|official-usbip-win2-0.9.8.0-v2'
  Write-InstallMessage '=== Windows USB/IP installer start ==='
  Write-InstallMessage ("Requested server role: " + $Server)
  Write-InstallMessage ("Requested client role: " + $Client)
  Write-WindowsEnvironmentDiagnostics

  if (-not $Server -and -not $Client) {
    Write-InstallMessage 'Usage: .\install-windows-offline.ps1 -Server [-Client] [-Architecture auto|x64|arm64]'
    Write-InstallMessage '       .\install-windows-offline.ps1 -Client'
    exit 2
  }

  $target = if ($Architecture -eq 'auto') { Resolve-TargetArchitecture } else { $Architecture }
  if ($target -eq 'x86') {
    throw '32-bit Windows (x86) is not supported. The bundled usbipd-win and usbip-win2 drivers require x64 or ARM64 Windows.'
  }

  $Win = Join-Path $Root "windows\$target"
  if (-not (Test-Path $Win)) {
    $available = (Get-ChildItem -Path (Join-Path $Root 'windows') -Directory | Select-Object -ExpandProperty Name) -join ', '
    throw "No offline resources found for architecture '$target'. Bundled architectures: $available."
  }

  $installers = @{
    # Keep the server and client installers independent. usbipd-win provides
    # the Windows sharing service; usbip-win2 provides the Windows client and
    # its virtual USB driver. The official usbip-win2 installer must install
    # the matching executable, DLLs, INF/SYS/CAT files, and device node as one
    # versioned set. Do not mix files from older releases.
    'x64'   = @{ Server = 'usbipd-win_5.3.0_x64.msi'; Client = 'USBip-0.9.8.0-x64.exe' }
    'arm64' = @{ Server = 'usbipd-win_5.3.0_arm64.msi'; Client = 'USBip-0.9.7.5-arm64-release.exe' }
  }
  if (-not $installers.ContainsKey($target)) {
    throw "Unsupported architecture: $target"
  }

  Write-InstallMessage "Target architecture: $target"
  $serverDiagnosticPaths = @()
  $clientDiagnosticPaths = @()
  if ($Server) {
    $msi = Join-Path $Win $installers[$target].Server
    if (-not (Test-Path $msi)) { throw "Missing server installer: $msi" }
    Write-InstallMessage "Installing server: $msi"
    $msiArguments = '/i ' + (Quote-ProcessArgument $msi) + ' /qn /norestart'
    $msiProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArguments -Wait -PassThru
    if ($msiProcess.ExitCode -notin @(0, 1641, 3010)) {
      throw "Server MSI installation failed. Exit code: $($msiProcess.ExitCode)"
    }
    if ($msiProcess.ExitCode -in @(1641, 3010)) { $restartRequired = $true }

    $serverExecutable = Find-InstalledExecutable `
      -Names @('usbipd.exe') `
      -Directories @('usbipd-win', 'usbipd-win\bin')
    if ($null -eq $serverExecutable) {
      $serverDirectories = @(Get-RegistryInstallDirectories)
      $serverExecutable = Find-ExecutableBelow `
        -Directories $serverDirectories `
        -Names @('usbipd.exe') `
        -MaxDepth 3
    }
    if ($null -eq $serverExecutable) {
      $serverExecutable = Find-ServiceExecutable
    }
    $serverDiagnosticPaths += $serverExecutable
    $serverDiagnosticPaths += @(Get-ServiceCommandLine | ForEach-Object { Get-ExecutableFromCommandLine $_ })
    if ($null -eq $serverExecutable) {
      Write-InstallMessage 'Server executable discovery failed. Collecting Windows installation diagnostics.'
      Write-RegistryDiagnostics
      Write-ExecutableDiagnostics -Label 'Server' -Paths $serverDiagnosticPaths
      throw 'The server installer returned success, but usbipd.exe was not found under Program Files.'
    }
    Write-InstallMessage "Server executable: $serverExecutable"
    $service = Get-Service -Name 'usbipd' -ErrorAction SilentlyContinue
    if ($null -eq $service) {
      throw 'The server installer returned success, but the usbipd Windows service was not found. Repair the usbipd-win installation.'
    } else {
      # Service installation/startup is asynchronous. Do not probe usbipd.exe
      # while SCM still reports StartPending, otherwise a valid installation
      # can be reported as failed immediately after MSI exits.
      $service = Wait-UsbipdServiceRunning -TimeoutSeconds 15
      Write-InstallMessage "usbipd service status: $($service.Status)"
    }
    $probeOutput = (& $serverExecutable list 2>&1 | Out-String).Trim()
    $probeCode = $LASTEXITCODE
    Write-InstallMessage "usbipd list probe exit code: $probeCode"
    if (-not [string]::IsNullOrWhiteSpace($probeOutput)) {
      Write-InstallMessage ('usbipd list probe output: ' + $probeOutput)
    }
    if ($probeCode -ne 0) {
      Write-RegistryDiagnostics
      Write-ExecutableDiagnostics -Label 'Server' -Paths $serverDiagnosticPaths
      throw 'usbipd.exe was found, but usbipd list failed. Check the service, administrator permission, and Windows Event Viewer.'
    }
    $serverStatus = 'installed'
  }
  if ($Client) {
    $clientExecutable = $null
    $clientVerification = $null
    $clientInstaller = Join-Path $Win $installers[$target].Client
    $programFiles64 = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($programFiles64)) {
      $programFiles64 = $env:ProgramFiles
    }
    $clientDiagnosticPaths += @(
      (Join-Path $programFiles64 'USBip\usbipw.exe'),
      (Join-Path $programFiles64 'USBip\devnode.exe'),
      (Join-Path $programFiles64 'USBip\libusbip.dll'),
      (Join-Path $programFiles64 'usbip-win2\usbipw.exe'),
      $clientInstaller
    )
    if ($target -eq 'x64') {
      if (-not (Test-Path -LiteralPath $clientInstaller -PathType Leaf)) {
        throw "Missing bundled official x64 client installer: $clientInstaller"
      }
      $runtime = Join-Path $Win 'VC_redist.x64.exe'
      if (Install-VisualCRuntime -InstallerPath $runtime) {
        $restartRequired = $true
      }
      $runtimeStatus = Get-VisualCRuntimeStatus
      if ($runtimeStatus -ne 'available') {
        throw 'Microsoft Visual C++ Redistributable is not available after installation.'
      }
      $clientVerification = Install-OfficialUsbipWin2Client -InstallerPath $clientInstaller
      $clientExecutable = [string]$clientVerification.Executable
    } else {
      if (-not (Test-Path $clientInstaller)) { throw "Missing client installer: $clientInstaller" }
      Write-InstallMessage "Installing client: $clientInstaller"
      # ARM64 currently uses its architecture-specific installer. Run it
      # silently so the Flutter process waits for the actual installation.
      $clientProcess = Start-Process `
        -FilePath $clientInstaller `
        -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
        -Wait `
        -PassThru
      Write-InstallMessage "Client installer exit code: $($clientProcess.ExitCode)"
      if ($clientProcess.ExitCode -notin @(0, 1641, 3010)) {
        throw "Client installation failed. Exit code: $($clientProcess.ExitCode)"
      }
      if ($clientProcess.ExitCode -in @(1641, 3010)) { $restartRequired = $true }

      # The installer can add its directory to PATH only for future
      # processes, so check PATH, fixed paths, and registered locations.
      $clientExecutable = Find-PathExecutable -Names @('usbipw.exe', 'usbip.exe', 'usbip-win2.exe')
      if ($null -eq $clientExecutable) {
        $clientExecutable = Find-ClientExecutable
      }
      $clientDiagnosticPaths += $clientExecutable
      if ($null -eq $clientExecutable) {
        Write-InstallMessage 'Client executable discovery failed. Collecting Windows installation diagnostics.'
        Write-RegistryDiagnostics
        Write-ExecutableDiagnostics -Label 'Client' -Paths $clientDiagnosticPaths
        throw 'The client installer returned success, but usbipw.exe, usbip.exe, or usbip-win2.exe was not found. Check the installer log and install the client manually from the bundled installer.'
      }
      Write-InstallMessage "Client executable: $clientExecutable"
      $clientDirectory = Split-Path -Parent $clientExecutable
      $clientVerification = Verify-BundledClientInstallation `
        -Executable $clientExecutable `
        -ClientDirectory $clientDirectory
    }
    $clientStatus = 'installed'
    if ($null -ne $clientVerification) {
      $clientDriverStatus = [string]$clientVerification.DriverStatus
      $clientDeviceStatus = [string]$clientVerification.DeviceStatus
      if ([bool]$clientVerification.RestartRequired) {
        $restartRequired = $true
      }
    }
  }

  $complete = $true
  if ($Server -and $serverStatus -ne 'installed') { $complete = $false }
  if ($Client -and ($clientStatus -ne 'installed' -or
      $clientDriverStatus -ne 'available' -or
      $clientDeviceStatus -ne 'available')) { $complete = $false }
  $installStatus = if ($complete) { 'success' } else { 'partial' }
  if ($restartRequired -or $clientDeviceStatus -eq 'pending_restart') {
    $restartRequired = $true
  }
  Write-InstallStatus 'TARGET_ARCHITECTURE' $target
  Write-InstallStatus 'SERVER_STATUS' $serverStatus
  if ($null -ne $serverExecutable) {
    Write-InstallStatus 'SERVER_PATH' $serverExecutable
  }
  Write-InstallStatus 'CLIENT_STATUS' $clientStatus
  if ($null -ne $clientExecutable) {
    Write-InstallStatus 'CLIENT_PATH' $clientExecutable
  }
  Write-InstallStatus 'CLIENT_DRIVER_STATUS' $clientDriverStatus
  Write-InstallStatus 'CLIENT_DEVICE_STATUS' $clientDeviceStatus
  Write-InstallStatus 'RESTART_REQUIRED' ([string]$restartRequired).ToLowerInvariant()
  Write-InstallStatus 'INSTALL_STATUS' $installStatus
  if ($restartRequired) {
    Write-InstallMessage "Windows USB/IP offline components installed for $target. Restart Windows before using the Flutter application."
  } elseif ($installStatus -eq 'partial') {
    Write-InstallMessage "Windows USB/IP files were installed for $target, but the selected components are not fully ready. Review the status markers and restart or repair the missing component."
  } else {
    Write-InstallMessage "Windows USB/IP offline components installed for $target. Return to the application and run environment check."
  }
} catch {
  if ($Server -and $null -ne $serverDiagnosticPaths) {
    Write-InstallMessage 'Final server diagnostics:'
    Write-RegistryDiagnostics
    Write-ExecutableDiagnostics -Label 'Server' -Paths $serverDiagnosticPaths
  }
  if ($Client -and $null -ne $clientDiagnosticPaths) {
    Write-InstallMessage 'Final client diagnostics:'
    Write-RegistryDiagnostics
    Write-ExecutableDiagnostics -Label 'Client' -Paths $clientDiagnosticPaths
  }
  if ([string]::IsNullOrWhiteSpace($target)) {
    $target = if ($Architecture -eq 'auto') { Resolve-TargetArchitecture } else { $Architecture }
  }
  if ($Server -and $serverStatus -eq 'pending') { $serverStatus = 'failed' }
  if ($Client -and $clientStatus -eq 'pending') { $clientStatus = 'failed' }
  if ($Client -and $clientDriverStatus -eq 'pending') { $clientDriverStatus = 'unknown' }
  if ($Client -and $clientDeviceStatus -eq 'pending') { $clientDeviceStatus = 'unknown' }
  Write-InstallStatus 'TARGET_ARCHITECTURE' $target
  Write-InstallStatus 'SERVER_STATUS' $serverStatus
  if ($null -ne $serverExecutable) {
    Write-InstallStatus 'SERVER_PATH' $serverExecutable
  }
  Write-InstallStatus 'CLIENT_STATUS' $clientStatus
  if ($null -ne $clientExecutable) {
    Write-InstallStatus 'CLIENT_PATH' $clientExecutable
  }
  Write-InstallStatus 'CLIENT_DRIVER_STATUS' $clientDriverStatus
  Write-InstallStatus 'CLIENT_DEVICE_STATUS' $clientDeviceStatus
  Write-InstallStatus 'RESTART_REQUIRED' ([string]$restartRequired).ToLowerInvariant()
  Write-InstallStatus 'INSTALL_STATUS' 'failed'
  Write-InstallMessage ('Windows USB/IP offline installation failed: ' + $_.Exception.Message)
  exit 1
}
