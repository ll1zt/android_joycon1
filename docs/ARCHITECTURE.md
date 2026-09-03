# Architecture

[中文版](ARCHITECTURE.zh-CN.md)

This document explains the runtime architecture and the build architecture of
this project, and why each piece exists.

## Runtime: data flow

```
                Bluetooth HID (Android BT stack → /dev/uhid)
                                    │
                     kernel hid-nintendo (built into GKI)
                    calibration, IMU, battery, FF iface (dead)
                                    │
          ┌─────────────────────────┼───────────────────────────┐
          ▼                         ▼                           ▼
   evdev event4 (L)          evdev event6 (R)            /dev/hidraw0/1
   evdev event5 (L IMU)      evdev event7 (R IMU)        (raw BT reports)
          │                         │                           ▲
          │ EVIOCGRAB               │ EVIOCGRAB                 │ 0x10 rumble
          └───────────┬─────────────┘                           │ (direct write)
                      ▼                                          │
              ┌───────────────┐   uinput combined 0x2008   ┌────┴─────────┐
              │    joycond    │──────────────────────────► │ /dev/input/  │
              │  (patched)    │   KEYBOARD|GAMEPAD|JOYSTICK│  eventN      │
              └───────┬───────┘   AXIS_X/Y/Z/RZ/HAT_X/Y   └──────────────┘
                      │ FF upload/play intercepted                │
                      └───────────────────────────────────────────┘
```

### Why each piece exists

| Piece | Why |
|---|---|
| kernel `hid-nintendo` | The only component that speaks Joy-Con's private protocol (subcommands, 0x30 full reports, calibration, IMU). Built into GKI. |
| joycond | A single Joy-Con exposes half a gamepad. joycond grabs both, merges inputs and creates the `0x2008` combined uinput device that apps see. Its Android detector uses netlink uevents (no udev on Android). |
| uinput FF hook → hidraw | GKI builds the driver without `CONFIG_NINTENDO_FF`, so the kernel accepts effects but never transmits them. The patch intercepts effects in joycond (which must process them anyway via `UI_BEGIN_FF_UPLOAD`) and writes `0x10` rumble reports straight to the pads' hidraw nodes. |
| keylayout `Vendor_057e_Product_2008.kl` | Maps the combined device's evdev codes/axes to Android `KEYCODE_BUTTON_*` / `MotionEvent.AXIS_*`. Without it Android labels axes `GENERIC_*` and games ignore the device. |
| idc files | `2006/2007: device.disabled=1` hides the half-controllers from the framework; `2008: device.internal=0` marks the combined pad external. |
| service.sh | Boot-time staging: binary → `/dev` tmpfs (exec), config overlay → bind mount, then supervises the daemon with backoff and logs to `/data/adb/joycond.log`. |
| sepolicy.rule | Insurance: grants the `ksu` domain the permissions LineageOS grants its `joycond` domain (input/uhid/netlink/sysfs). KernelSU's `ksu` domain is permissive in practice, so the rules are belt-and-suspenders. |

### Rumble protocol details

BT OUTPUT report `0x10` (rumble-only), 64 bytes:

```
[0]      0x10
[1]      packet counter, wraps 0x0–0xF
[2..5]   left pad band:  HF freq, HF amp, LF freq, LF amp
[6..9]   right pad band: HF freq, HF amp, LF freq, LF amp
[10..63] zero
```

Amplitude encodings are asymmetric: LF amp `0x40 = 0.0f … 0x72 = 1.0f`
(safe maximum — exceeding it can damage the LRA), HF amp `0x01 = 0.0f …
0xC8 = 1.0f`. Frequencies cover LF 40.87–626.28 Hz and HF 81.75–1252.57 Hz.
Both bands of a pad's single LRA can be driven simultaneously, and frames can
be streamed at up to 60 Hz — that is exactly how Switch games produce "HD
rumble" textures (rolling marbles, rain, engine revs). `hd-test` demonstrates
this with five looped waveforms.

## Build architecture (Nix flakes)

```
flake.nix ─┬─ nix/joycond-android.nix ─┬─ fetchFromGitHub joycond @ 0df025a
           │                           ├─ nix/joycond-hidraw-rumble.patch
           │                           ├─ libevdev 1.13.2 (fetchurl, meson cross → NDK clang)
           │                           └─ ndk-bundle (androidenv, r29)
           ├─ nix/module.nix ──────────┴─ module/ (prop, service.sh, sepolicy, kl, idc)
           ├─ nix/ff-test.nix  → ff-test/ff-test.c
           └─ nix/hd-test.nix  → hd-test/hd-test.cpp
```

Notable decisions:

- **Cross toolchain**: `androidenv.androidPkgs.ndk-bundle` (NDK r29, prebuilt,
  pinned). nixpkgs' own `pkgsCross.aarch64-android` stdenv was broken at the
  time (compiler-rt bootstrap fails against bionic headers), so the official
  NDK is used instead. The NDK is unfree; it is instantiated through a
  **dedicated `allowUnfree = true` nixpkgs instance** so the main instance
  stays clean.
- **libevdev**: joycond's only real C dependency; built as a static lib via
  meson with a cross file pointing at the NDK clang wrapper. Three small
  patches: `librt` not found on bionic (functionality lives in libc →
  `required: false`), the `configure_file` python helper invoked via
  `find_program('python3')` (shebang robustness), and `-Ddocumentation=disabled`.
- **joycond**: compiled directly with the NDK clang++ driver (mirroring
  upstream `Android.mk`'s source list, replacing the udev detector with the
  android detector). `__ANDROID__` is defined by the clang android target
  automatically. API level 28 (bionic exposes `glob`/`globfree` from 28).
  `-static-libstdc++` so the binary only needs `libc/liblog/libdl/libm`.
- **Patches**: the hidraw rumble feature is maintained as a single git patch
  (`nix/joycond-hidraw-rumble.patch`) so it can be rebased onto upstream
  joycond versions; regenerating: copy upstream to a scratch dir, `git init`,
  apply changes, `git diff`.

## Known limitations

- IMU data reaches the kernel but joycond discards it when merging, and the
  Android framework has no external-gyroscope API — motion aiming is not
  possible without an emulator that reads IMU itself.
- NFC/Amiibo and the IR camera have no path into Android at all.
- Battery is exposed as `capacity_level` (4 bands), no percentage.
- The rumble passthrough writes to hidraw from joycond; if a future GKI
  enables `CONFIG_NINTENDO_FF`, both paths would fight — in that case remove
  the patch and let the kernel handle FF again.
