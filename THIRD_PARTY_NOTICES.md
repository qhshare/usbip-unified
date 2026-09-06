# Third-Party Notices

USBIP Unified Manager is a new Flutter application. Its main application code
is available under the MIT License in `LICENSE`. The application invokes native
USB/IP tools and does not embed the user interfaces from the reference projects.

The source snapshots under `third_party/` are retained for research and
compatibility review. They are separate works and keep their original
licenses:

| Component | Source | License and notice |
| --- | --- | --- |
| Linux UI and command reference | [K-Francis-H/usbip-gui](https://github.com/K-Francis-H/usbip-gui) | GPL-3.0, `third_party/k-francis-usbip-gui/LICENSE` |
| Windows client reference | [Snakefoxu/SnakeUSBIP](https://github.com/Snakefoxu/SnakeUSBIP) | GPL-3.0, `third_party/snakeusbip/LICENSE` |
| Windows server reference | [Snakefoxu/SnakeUSBIP-Server](https://github.com/Snakefoxu/SnakeUSBIP-Server) | GPL-3.0, `third_party/snakeusbip-server/LICENSE` |
| Windows USB/IP server binary | [dorssel/usbipd-win](https://github.com/dorssel/usbipd-win) | See `offline/licenses/usbipd-win-GPL-3.0-only.txt` and the upstream release notices |
| Windows USB/IP client binary | [vadimgrn/usbip-win2](https://github.com/vadimgrn/usbip-win2) | See `offline/licenses/usbip-win2-LICENSE.txt` and the upstream release notices |

The exact revisions of the three reference snapshots are recorded in
`third_party/SOURCES.lock`. Offline binary resources are covered by
`offline/SHA256SUMS`. Before publishing a release, review the upstream release
terms, retain all required notices, and verify that the binary source or
corresponding-source obligations are met.

The reference projects are not runtime dependencies of the Flutter application.
Their source is not imported into `lib/`, and their original desktop UIs are not
launched by the product.
