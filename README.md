# joycond-android — Nintendo Joy-Con as a single gamepad on Android, with HD Rumble

[中文文档 (Chinese README)](README.zh-CN.md)

> **TL;DR** — Rooted Android (KernelSU/Magisk) on a GKI kernel (Android 12+,
> e.g. Pixel): `nix build`, flash the resulting zip, reboot, pair two Joy-Cons,
> done — one controller with rumble in every game. Tested on Pixel 6 / Android 16.
> Other devices: expect to adapt; see [precheck](precheck/) first.

Root-only solution that makes **all native Android games and emulators** see a pair of
Nintendo Joy-Cons as **one complete controller** (`Nintendo Switch Combined Joy-Cons`,
vendor `0x057e` product `0x2008`), plus **rumble / HD-Rumble-style vibration** on
kernels where the kernel FF path is unavailable.

Developed and verified on **Pixel 6 (oriole), Android 16, GKI kernel
6.1.145-android14**, root via **KernelSU Next**. Everything is built declaratively with
Nix flakes; `nix build` produces an installable KernelSU module zip.

## How it works

```
BT HID (uhid)                    /dev/input                /dev/hidraw
┌──────────────┐   kernel hid-nintendo (=y in GKI)   ┌─────────────────────┐
│ Joy-Con (L)  ├───────────────────────────────────► │ evdev event4 (L)    │──┐
│ Joy-Con (R)  ├───────────────────────────────────► │ evdev event6 (R)    │  │
└──────────────┘      calibration, IMU, battery       └─────────────────────┘  │
                                                               ▲  ▼             │
                                        EVIOCGRAB + FF hook    │  │             │
                                                       ┌───────┴──┴─────────┐   │
                                                       │      joycond       │   │
                                                       │ (patched, see      │   │
                                                       │  rumble_hidraw)    │   │
                                                       └───────┬────────────┘   │
                                     uinput: combined 0x2008   │                │
                                     with standard gamepad     ▼                │
                                     axes (X/Y/Z/RZ/HAT…)  /system/usr/{keylayout,idc}
                                     ◄─── magic self-mount │ (bind mount by     │
                                                           │  service.sh)       │
                          FF upload/play ──────────────────┤                    │
                                                           ▼                    │
                                               rumble_hidraw: BT OUTPUT 0x10 ───┘
                                               (60Hz capable, HF+LF bands,
                                                bypasses CONFIG_NINTENDO_FF=n)
```

Three layers had to cooperate (each with real pitfalls):

1. **Kernel**: modern GKI kernels ship `CONFIG_HID_NINTENDO=y` (built-in), so Joy-Cons
   bind to the `nintendo` HID driver with factory/user calibration. No kernel rebuild
   needed. However `CONFIG_NINTENDO_FF` (the force-feedback sub-option) is **not** set
   in GKI — the kernel exposes the FF interface but never sends rumble to the pads.
2. **Userspace**: upstream [joycond](https://github.com/DanielOgorchock/joycond) grabs
   both physical devices, merges them and creates the combined uinput device. It
   already has an Android detector (netlink uevent, no udev). This project patches it
   to also **drive rumble directly via hidraw** (`0x10` reports, HF+LF bands,
   60Hz streaming — full HD-Rumble capability), bypassing the dead kernel FF path.
3. **Framework**: a keylayout (`Vendor_057e_Product_2008.kl`, LineageOS version with
   HAT axes + analog triggers) and idc files are bind-mounted into
   `/system/usr/{keylayout,idc}` by the module's `service.sh` (KernelSU Next ≥ 3.3
   has no magic mount without the optional metamodule; `/data` is not executable, so
   the daemon is staged into `/dev` tmpfs instead; SELinux labels are fixed with
   `chcon u:object_r:system_file:s0`).

## What works / what doesn't

| Capability | Status |
|---|---|
| Combined single gamepad for **all** apps (system-wide) | ✅ |
| Sticks (full range, calibrated), ABXY, D-pad→HAT, L/R, ZL/ZR→analog triggers, SL/SR, +/-, Home, Capture | ✅ |
| Individual Joy-Cons hidden from apps (`device.disabled=1` idc) | ✅ |
| Rumble (classic dual-motor semantics: strong→LF band, weak→HF band) | ✅ via hidraw |
| **HD-Rumble-style streaming waveforms** (60Hz, per-band amplitude/frequency control) | ✅ via hidraw (`hd-test`) |
| Sleep / auto-reconnect (~5 min idle), MAC-based rebinding | ✅ handled by joycond |
| Battery level | ✅ kernel (`capacity_level`), no framework UI |
| IMU (motion) | ❌ kernel data exists; joycond drops it; Android framework has no path |
| NFC / Amiibo, IR camera | ❌ structurally impossible on stock Android |

## Build

Requirements: Nix with flakes enabled. Everything else (NDK r29, libevdev, cross
toolchain) is pinned by `flake.lock`.

```bash
nix build                    # KernelSU module zip → ./result
nix build .#joycond-android  # just the daemon binary
nix build .#ff-test-android  # evdev FF test tool
nix build .#hd-test-android  # HD rumble waveform demo player
```

Artifacts of the Android build depend only on `libc.so`, `liblog.so`, `libdl.so`,
`libm.so` (static libc++; API 28).

## Install

```bash
adb push -a "$(readlink -f result)" /sdcard/Download/joycond.zip
```

Then: **KernelSU app → Modules → Install from storage → joycond.zip → reboot**.
Pair both Joy-Cons in Android Bluetooth settings (hold the sync button on the rail).
When both are connected they are combined automatically (no L+R needed — the Android
build of joycond puts single controllers in `Waiting` state and merges on arrival).

## Verify

```bash
adb shell su -c 'tail /data/adb/joycond.log'                      # daemon log
adb shell su -c 'getevent -il | grep -A2 Combined'                # combined device
adb shell 'dumpsys input | grep -A8 Combined'                     # framework view
```

The framework should report `Sources: KEYBOARD | GAMEPAD | JOYSTICK`, `ControllerNum: 1`
and standard axes (`AXIS_X/Y/Z/RZ/HAT_X/HAT_Y`). Any game with controller support —
or a gamepad tester app — should now work.


HD rumble demo (both pads vibrate in sync; 4 looping waveform sketches:
marble roll, heartbeat, raindrops, frequency sweep):

```bash
adb push hd-test → /data/local/tmp/   # see nix/hd-test.nix
adb shell su -c '/data/local/tmp/hd-test /dev/hidraw0 /dev/hidraw1'
```

## Repository layout

```
├── flake.nix               # entry point; dedicated allowUnfree instance for the NDK
├── nix/
│   ├── joycond-android.nix # NDK r29 cross build; libevdev static; bionic compat patches
│   ├── joycond-hidraw-rumble.patch  # hidraw rumble passthrough for joycond
│   ├── module.nix          # KernelSU module assembly (zip)
│   ├── ff-test.nix         # evdev FF tester (aarch64-android)
│   └── hd-test.nix         # HD rumble waveform player
├── module/                 # module.prop, service.sh (self-mounting), sepolicy.rule,
│   ├── keylayout/          #   Vendor_057e_Product_2008.kl (LineageOS 2025)
│   └── idc/                #   2006/2007 disabled, 2008 external
├── ff-test/, hd-test/      # test tool sources (ff-test: legacy kernel-FF path; hd-test: HD rumble demo)
├── refs/                   # upstream clones (gitignored): joycond, LineageOS HAL, dekuNukem docs
├── precheck/               # pre-flight check scripts
```

## License

- joycond: GPLv3 (upstream), this repository's build system and patches: GPLv3-or-later
- joycond LineageOS keylayout file: Apache-2.0 (LineageOS)

## Acknowledgements

- [DanielOgorchock/joycond](https://github.com/DanielOgorchock/joycond) — the daemon
- [LineageOS android_hardware_nintendo_joycond](https://github.com/LineageOS/android_hardware_nintendo_joycond) — keylayout, sepolicy reference
- [dekuNukem/Nintendo_Switch_Reverse_Engineering](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering) — Joy-Con protocol & rumble data format documentation
