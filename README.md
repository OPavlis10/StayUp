<p align="center"><img src="docs/icon.png" width="128" alt="Stay Up icon"></p>

# Stay Up

A small macOS menu bar app that keeps a Mac awake while long-running work (AI agents, builds, downloads) is in progress, and shows what the machine is doing meanwhile.

Native Swift 6 + SwiftUI for macOS 26 and later. No dependencies, no telemetry, no network traffic. The interface is in Czech.

## What it does

**Keep awake**

- **Display sleeps, Mac runs** – blocks idle sleep with a power assertion; no admin rights needed.
- **Never sleep, even with the lid closed** – a privileged helper sets `pmset disablesleep`. Optional timer (1, 2, 4 hours).
- **Low power mode** – switched through the same helper, on battery and on the adapter.
- **Awake only while AI works** – watches chosen processes (`claude`, `node`, `ollama`, `codex` by default) and releases the Mac after they have been idle for a set time.

**System overview**

- CPU (total and per core), memory, disk, GPU and network rates with sparklines.
- Top three processes by energy, power draw in watts and battery time remaining.
- Network watch: a notification after a minute offline, optionally ending keep-awake.

**Safety**

- The helper records the original setting and restores it when the switch goes off, the app quits, crashes or hangs, the timer runs out, the battery gets low or the Mac overheats.
- It never overwrites a value that was set outside the app.

## Install

```sh
./build.sh install
```

This builds the app with the Command Line Tools, signs it ad hoc and copies it to `/Applications/Stay Up.app`. With Xcode:

```sh
xcodebuild -project StayUp.xcodeproj -scheme StayUp -configuration Release -derivedDataPath build/DerivedData build
```

The switches that use the helper need a one-time approval: turn one on, then allow **Stay Up** in System Settings → General → Login Items & Extensions → Allow in the Background.

## Layout

| Path | Contents |
|---|---|
| `App/` | the menu bar app: metrics, power, activity watch, settings, UI |
| `Helper/` | the root helper that changes sleep and low power settings |
| `Shared/` | the XPC contract between the two |
| `project.yml` | XcodeGen spec for `StayUp.xcodeproj` |
| `build.sh` | build without Xcode |

More detail, in Czech: [docs/README.cs.md](docs/README.cs.md).
