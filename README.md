# AppMixer

[![Build](https://github.com/Monem-Benjeddou/AppMixer/actions/workflows/build.yml/badge.svg)](https://github.com/Monem-Benjeddou/AppMixer/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/Monem-Benjeddou/AppMixer)](https://github.com/Monem-Benjeddou/AppMixer/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14.2+](https://img.shields.io/badge/macOS-14.2%2B-lightgrey)

Per-app volume control for macOS. Turn individual apps up or down, mute them, or send them to different speakers. For example, Spotify quieter, Discord louder, and the game through your headphones.

![AppMixer's mixer window, with Chrome and QuickTime playing and each app's volume, mute, and output controls](docs/screenshots/mixer.jpg)

| Devices | |
|---|---|
| ![Output devices with their volume and the system default](docs/screenshots/devices.jpg) | Every output device with its volume. Make any of them the system default in one click. Apps you've sent to a device are listed with it. |

## Features

- **Per-app volume from 0–200%.** Lower one app or boost a quiet one above its normal level.
- **Per-app mute.** Silence one app without touching the others.
- **Per-app output routing.** Send any app to any output device. If that device disconnects, the app falls back to the system output, then switches back when the device returns.
- **Devices page.** See every output device, change its volume, and make it the default.
- **Menu bar panel.** Quick controls for whatever is playing, plus a full window with search.
- **Remembers settings per app.** Choices are reapplied automatically every time the app plays.
- **No driver to install.** AppMixer uses Core Audio process taps (macOS 14.2+), not a kernel extension or virtual audio device.

## Install

1. Download `AppMixer-mac.zip` from the [latest release](https://github.com/Monem-Benjeddou/AppMixer/releases/latest) and unzip it.
2. Move `AppMixer.app` to `/Applications`.
3. The app isn't notarized, so open it the first time by right-clicking it and choosing **Open**. Alternatively, run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/AppMixer.app
   ```
4. The first time you change an app's volume, macOS asks to let AppMixer record system audio. Allow it. You can change this later in **System Settings › Privacy & Security › Screen & System Audio Recording**.

## How it works

AppMixer leaves each app alone until you change one of its settings. At that point AppMixer:

1. creates a private **process tap** for the app's audio processes. Helper processes are included: Chrome's renderer helpers and Safari's WebKit processes are grouped under the app that owns them. The tap silences the app's normal output.
2. creates a private **aggregate device** that contains the chosen output device and the tap.
3. copies the tapped audio to that output in a real-time callback, applying your volume with a short ramp so changes don't click.

Both the tap and the aggregate device are private to AppMixer's process. **If AppMixer quits or crashes, macOS removes them and every app goes back to playing normally.** No system state is left behind.

## Reliability

- **The UI never waits on the audio system.** Audio-system calls can stall for seconds, for example while a Bluetooth device wakes up. All of them run on a dedicated background queue, never the main thread.
- **Permission is asked for once.** AppMixer checks the permission status before creating any tap and asks at most once per launch. If you denied it, the app shows a banner with a shortcut to the right System Settings page instead of prompting again.
- **No retry loops.** When an app's capture can't be set up, AppMixer remembers it and doesn't retry until something changes: the app, the device, a setting, or you click **Try Again**. Meanwhile the app keeps playing normally.
- **Recovery.**
  - If the audio system (`coreaudiod`) restarts, AppMixer rebuilds all its taps.
  - After the Mac wakes from sleep, it scans devices again.
  - Plugging in or removing an output device is handled automatically.
- **Watchdog.** If the audio system stops responding, a banner says so instead of the app looking frozen.
- **Format checking.** AppMixer only processes 32-bit float audio and refuses anything else rather than playing noise.
- **Saved settings are protected.** If the saved settings can't be read, they're kept aside for diagnosis instead of being overwritten.
- **Logging.** Errors are logged to the unified log:
  ```sh
  log stream --predicate 'subsystem == "dev.appmixer.AppMixer"'
  ```

## Build from source

You need the Swift 5.10+ toolchain (Xcode or the Command Line Tools).

```sh
git clone https://github.com/Monem-Benjeddou/AppMixer.git
cd AppMixer
./build.sh            # → build/AppMixer.app (universal: arm64 + x86_64)
./build.sh 1.2.0      # same, with the version number set
```

`build.sh` signs with `$SIGN_IDENTITY` if set. Otherwise it uses a local certificate named "… Local Signing" from your keychain, or falls back to ad-hoc signing. A stable certificate keeps macOS permissions after a rebuild, because an ad-hoc signature changes with every build.

### Project layout

| File | Purpose |
|------|---------|
| `AudioEngine.swift` | Owns all taps on a serial queue; scanning and reconciling |
| `AppTap.swift` | One process tap and aggregate device, plus the real-time render callback |
| `AudioDiscovery.swift` | Lists output devices and audio-producing apps, grouping helpers under their app |
| `AudioCapturePermission.swift` | Checks and requests the audio recording permission without repeated prompts |
| `MixerModel.swift` | Main-thread UI state and saved per-app settings |
| `MixerView.swift` | Main window, menu bar panel, and Settings |

## Releasing

[`build.yml`](.github/workflows/build.yml) builds and verifies the universal app on every push and pull request. When you push a version tag, it also publishes a GitHub Release with `AppMixer-mac.zip` and its SHA-256 checksum:

```sh
git tag v1.1 && git push origin v1.1
```

To sign releases with your own certificate (for example, a Developer ID), add these repository secrets:

- `MAC_CERT_P12`: the base64-encoded `.p12`
- `MAC_CERT_PASSWORD`: its password

Without them, the build is signed ad hoc and the workflow shows a warning.

## License

[MIT](LICENSE) © Monem Benjeddou
