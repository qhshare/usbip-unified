# Architecture

## Product boundary

USBIP Unified Manager is a new Flutter desktop application. The old Tkinter and
WPF interfaces from the reference projects are not embedded, launched, or
modified as the product UI.

```text
Flutter widgets (lib/main.dart)
        |
        +-- role and form state
        +-- device list, actions and logs
        |
UsbIpService (lib/services/usbip_service.dart)
        |
        +-- command construction and privilege boundary
        +-- output parsing and UsbDevice model
        +-- server/client state validation
        |
native process and driver boundary
        |-- Linux: usbip, usbipd, usbip-core, usbip-host, vhci-hcd
        |-- Windows server: usbipd-win / usbipd.exe
        `-- Windows client: usbip-win2 / usbipw.exe / virtual USB driver
```

Flutter does not implement the USB/IP protocol or a virtual USB controller. The
operating system kernel and native USB/IP project provide those components. The
application orchestrates native commands and presents their state.

## Modules

### UI: `lib/main.dart`

The UI owns role selection, address and port fields, device selection, action
availability, installation controls, and the visible command log. It calls the
service layer instead of constructing platform commands directly.

The two directions are intentionally separate:

- Server roles list local devices and expose bind/unbind actions.
- Client roles list remote devices and expose attach/detach actions.

This prevents a local server port from being confused with a client's local
USB/IP port. Client detach uses the local port discovered from `usbip port`.

### Command adapter: `UsbIpService`

`UsbIpService` is the platform-neutral contract used by the UI. It handles:

- Linux `usbip list -l`, `bind -b`, `unbind -b`, `attach`, `port` and `detach`.
- Linux `usbipd` startup and TCP listening checks.
- Windows `usbipd list`, `bind --busid` and `unbind --busid`.
- Windows `usbipw.exe` with the compatibility fallback `usbip.exe`.
- root/pkexec/sudo invocation on Linux.
- role mismatch, invalid port and duplicate binding validation.
- Linux, Windows server and client output parsing.

The service returns `CommandResult` rather than throwing for expected process
failures. This lets the UI show the exit code and native output in the log.

### Installers

`lib/services/online_installer.dart` delegates to the host package manager or
Windows `winget`. `lib/services/offline_installer.dart` extracts the selected
Flutter assets into a temporary directory and executes a platform installer.

The installer boundary is deliberately separate from runtime device operations:

- Offline Linux installation invokes `dpkg` for a specific Kali or Debian set,
  then attempts to load modules from the running kernel.
- Offline Windows installation invokes architecture-specific MSI/EXE installers
  through UAC.
- No installer replaces `libc6`, copies arbitrary kernel `.ko` files, or claims
  that a package for one distribution is universal.

## Roles and data flow

### Linux server

```text
local USB device
  -> usbip list -l
  -> usbip bind -b BUSID
  -> usbipd --tcp-port PORT -D
  -> trusted client connects to HOST:PORT
```

`usbip bind` attaches `usbip-host` to a device. The daemon is a separate process;
the service checks or starts it after binding. The UI displays all detected local
IPv4 addresses because the host can have more than one reachable interface.

### Linux client

```text
remote HOST:PORT
  -> usbip --tcp-port PORT list -r HOST
  -> usbip --tcp-port PORT attach -r HOST -b REMOTE_BUSID
  -> usbip port
  -> usbip detach -p LOCAL_PORT
```

The remote BUSID and local USB/IP port are different identifiers. The parser maps
the remote BUSID to the local port so the disconnect action cannot detach the
wrong connection.

### Windows server

```text
local USB device
  -> usbipd list
  -> usbipd bind --busid BUSID
  -> usbipd-win service on TCP 3240
  -> trusted client connects to HOST:3240
```

`usbipd-win` owns the service lifecycle and fixed listening port. The app does
not start a second daemon or pretend that Windows supports a per-device port.

### Windows client

```text
remote HOST:PORT
  -> usbipw.exe list -r HOST
  -> usbipw.exe attach -r HOST -b REMOTE_BUSID
  -> usbipw.exe port
  -> usbipw.exe detach -p LOCAL_PORT
```

The usbip-win2 virtual USB driver must already be installed and working. A GUI
cannot provide that kernel driver by itself.

## Platform matrix

| Platform role | Server | Client | Required native component |
| --- | ---: | ---: | --- |
| Linux | Yes | Yes | `usbip` plus `usbipd`, `usbip-host`, or `vhci-hcd` |
| Windows | Yes | Yes | `usbipd-win` or `usbip-win2` and its driver |
| macOS | No | No | No maintained backend in this project |

The current offline target matrix is narrower than the runtime role matrix. See
`offline/README.md` for the exact resources.

## Why the original projects are not modified

Modifying the reference interfaces would create separate UI forks and would not
make the original applications cross-platform. This repository instead keeps a
small, auditable adapter around native command contracts. The source checkouts
and exact revisions remain available under `third_party/` for comparison and
license review.

## Extension rules

To add a platform or native backend:

1. Add an explicit role to `UsbIpRole`.
2. Add command mapping and parsing in `UsbIpService`.
3. Keep platform checks out of individual widgets.
4. Add representative native output fixtures and action tests.
5. Update the support matrix, installer documentation, and release notes.
6. Verify privilege escalation, disconnect behavior, firewall requirements and
   failure output on the target platform.

Do not solve a missing kernel driver by copying a `.ko` or Windows `.sys` from a
different kernel or architecture. Add a supported target resource only after
testing it on the intended system family.
