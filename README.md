<div align="center">
  <img src="docs/assets/branding/dukex-logo.png" alt="DukeX" width="360">
  <p>
    <strong>Original Xbox emulation for iOS and macOS, built from xemu with a native Swift interface.</strong>
  </p>
  <p>
    <img src="https://img.shields.io/badge/status-update%20v1.0.2-8f95c4?style=flat-square" alt="Status: update v1.0.2">
    <img src="https://img.shields.io/badge/platform-iOS%2016%2B%20arm64%20%7C%20macOS-111827?style=flat-square" alt="Platform: iOS 16+ arm64 and macOS">
    <img src="https://img.shields.io/badge/iOS%20renderer-MoltenVK%20%2B%20Metal-1f6feb?style=flat-square" alt="iOS renderer: MoltenVK and Metal">
    <img src="https://img.shields.io/badge/JIT-version%20aware-2f855a?style=flat-square" alt="JIT: version aware">
  </p>
</div>

DukeX is an experimental iOS and macOS frontend for [xemu](https://xemu.app).
The iOS build embeds the xemu core in a native Swift shell and presents the
Vulkan renderer through MoltenVK and native Metal presentation. The macOS build
packages a nested desktop Xemu fork inside a Mac Catalyst DukeX experience.

> DukeX does not include Xbox system files, game images, or signing
> certificates. Users and testers are required to provide their own legally
> obtained files. DukeX is intended solely for legitimate emulation and
> preservation purposes, and is not designed for use with pirated materials.

## At a Glance

- Latest release: `v1.0.2`.
- Device target: iPhoneOS arm64, install target iOS 17.4 or later; a native
  macOS DMG is also available through GitHub Releases.
- Runtime: TCG with version-aware JIT setup; iOS 26 or later uses the
  StikJIT Universal.js flow.
- Graphics: iOS uses the xemu Vulkan renderer through MoltenVK with a native
  Metal presenter and AirPlay display support; macOS uses the bundled desktop
  Xemu presentation path inside the DukeX shell.
- Interface: native SwiftUI library, profile, settings, Activity Feed, and
  controller-focused landscape experiences.
- Networking: Insignia-oriented NAT defaults plus XB.Live profile, Rich
  Presence, messaging, social, community, and cloud-sync features.
- Known work: rendering correctness, touch-control behavior after rotation,
  Metal HUD visibility, and title-by-title tuning.

## Features

| Category | Details |
| --- | --- |
| Game library | Cover artwork, automatic cover art retrieval for supported titles, game launch, dashboard launch, favorites/title/live/recent sorting, portrait and landscape column options, controller landscape mode on iOS, long-press actions, native launch links, and Insignia live indicators for supported titles. |
| File management | User-accessible `BIOS`, `ROMs`, `Covers`, `GameConfigs`, and `ShaderCaches` folders through iOS file sharing. |
| JIT workflow | Optional in-app StikJIT enablement using an imported pairing file. |
| Display | iOS MoltenVK-backed Metal presenter with portrait and landscape-aware sizing, rendering stability work, expanded AirPlay support, and external-display handling; macOS presentation through the bundled desktop Xemu runtime. |
| Input | Controller support through iOS GameController APIs plus customizable touch controls through `.manicskin`, `.deltaskin`, and `.gammaskin` layouts. |
| Online setup | Insignia-focused NAT defaults, editable network settings, XB.Live profile integration, Rich Presence, playtime tracking, friends, messages, community event tracking, and supported cloud sync. |
| Profile | App-side profile tab with XB.Live identity, Activity Feed, achievement, friends, message, event, game-invite, and cloud-sync support. |
| Themes | Selectable interface themes and personalization options. |
| Per-game tuning | Custom config import and shader-cache clearing from each game menu. |
| Diagnostics | Built-in FPS/system statistics HUD and app-owned launch logs for device-side testing. |
| Advanced runtime | TCG translation block cache size controls for performance testing. |

## Availability

Current DukeX builds are published through GitHub Releases. iOS releases are
distributed for sideloading through StikStore and SideStore metadata under
[`altsource/source.json`](altsource/source.json), while the native macOS build
is distributed as a drag-to-Applications DMG.

Compatibility and performance vary by title, device, iOS version, JIT
availability, and touch-control orientation state. DukeX should be treated as
experimental software.

<p align="center">
  <img src="docs/assets/branding/stikstore-badge.png" alt="Available on StikStore" width="170">
  <img src="docs/assets/branding/sidestore-badge.png" alt="Available on SideStore" width="170">
</p>

## Dependencies

### Runtime

- Supported iPhone or iPad hardware for device testing. DukeX requires an
  Apple A14 Bionic or Apple M1 processor or newer.
- iOS 17.4 or later. iOS 17 through 18 use W^X reprotection after JIT has
  been enabled for the process. iOS 26 or later uses StikJIT's Universal.js
  flow.
- Legally obtained Xbox flash BIOS, MCPX ROM, and HDD image.
- Legally obtained XISO game images.
- Optional Insignia account and registered dashboard for online service testing.
- Optional XB.Live account for Rich Presence, playtime tracking, messaging,
  Activity Feed, social features, and supported cloud sync.

### Build

- macOS with Xcode 26 or newer and the iPhoneOS SDK.
- Xcode Mac Catalyst support for the desktop shell.
- MoltenVK iOS framework and headers for the iOS build, supplied locally and not committed.
- vcpkg `arm64-ios` dependency prefix used by the embedded xemu core.
- Meson, Ninja, Python, and the standard xemu/QEMU build toolchain.
- Apple signing assets only when creating signed device builds or sideload
  release packages.

## Documentation

- [Changelog](CHANGELOG.md)
- [iOS port overview](docs/ios-port/README.md)
- [iOS build instructions](docs/ios-port/BUILDING.md)
- [Renderer notes](docs/ios-port/RENDERER.md)

## Repository Layout

DukeX keeps the QEMU/xemu source tree at the repository root because the
upstream build system expects that layout. The main DukeX-specific areas are:

| Path | Purpose |
| --- | --- |
| `ios/` | Native Swift shell, assets, settings UI, and device build scripts. |
| `desktop/` | Mac Catalyst DukeX shell, bundled Xemu sidecar integration, and desktop build assets. |
| `altsource/` | AltStore/SideStore source metadata and store-facing image assets. |
| `docs/ios-port/` | DukeX iOS build and renderer notes. |
| `docs/assets/branding/` | README and release-facing DukeX image assets. |
| `hw/xbox/`, `target/i386/`, `tcg/`, `ui/`, `net/`, `block/` | Core emulator code used by the embedded iOS runtime. |
| `docs/upstream/` | Preserved upstream QEMU reference files for provenance and contributor context. |

## Upstream And Licensing

DukeX is based on xemu, which is itself based on QEMU. For upstream xemu
information, visit [xemu.app](https://xemu.app).

QEMU/xemu licensing information remains in `LICENSE`, `COPYING`, and source
file headers throughout the tree. DukeX is not affiliated with Microsoft, Xbox,
or the xemu project.
