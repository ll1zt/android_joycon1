# Troubleshooting — every pitfall hit on the way, with root causes

[中文版](TROUBLESHOOTING.zh-CN.md)

Each entry: symptom → red herring → root cause → fix. All of these were hit for
real on Pixel 6 / Android 16 / GKI 6.1 / KernelSU Next 3.3.

## 1. KernelSU Next ≥ 3.3 does not magic-mount modules

- **Symptom**: module installs fine, `service.sh` runs, but nothing under the
  module's `system/` appears in `/system` or `/vendor`; log shows
  `ksud::cli: Module { command: Metamodule } → Error: Unsupported`.
- **Red herring**: suspected a broken module layout or `skip_mount` flag.
- **Root cause**: KernelSU Next moved mounting into an optional **metamodule**
  component. Without it installed, modules are extracted and executed (scripts)
  but never mounted.
- **Fix**: do not rely on magic mount. `service.sh` performs the file placement
  itself:
  - daemon binary → copied to `/dev` tmpfs (see pitfall 2) and executed from there;
  - keylayout/idc → copied into a tmpfs staging dir together with the stock files,
    then `mount --bind` over `/system/usr/keylayout` and `/system/usr/idc`
    (idempotent: checks `/proc/mounts` first).

## 2. The daemon cannot be exec'd from `/data`

- **Symptom**: `exec ./joycond: No such file or directory` (ENOENT, not EACCES!)
  when running the same binary that works fine from `/dev`.
- **Root cause**: the misleading ENOENT comes from the kernel's exec path on this
  device's f2fs `/data` mount; `/dev` (tmpfs) executes the identical binary fine.
- **Fix**: stage the binary into `/dev/.joycond-bin/` at service start and exec
  from there. It is re-staged on every boot, so tmpfs volatility doesn't matter.

## 3. SELinux silently kills all keylayout/idc loading

- **Symptom**: combined device exists, evdev events flow (`getevent` shows
  everything), but `dumpsys input` shows `Sources` without `GAMEPAD`,
  axes named `GENERIC_1..8` instead of `AXIS_X/Y/...`, games see no controller.
- **Red herring**: suspected the BUS_VIRTUAL (0x06) uinput bus or a keylayout
  naming mismatch; also, earlier `dmesg` denials all said `permissive=1`, which
  suggested SELinux was globally permissive.
- **Root cause**: the overlay files inherited label `u:object_r:device:s0` from
  `/dev` tmpfs, and `system_server` — which runs **enforcing** (the `permissive=1`
  denials seen earlier belonged to a custom domain) — is not allowed to read
  `device:s0`. `EventHub` failed to probe **every** candidate file, including the
  `Generic.kl` fallback, so no axis labels were applied at all:
  `Couldn't find a system-provided input device configuration file ... error 13`.
- **Fix**: `chcon u:object_r:system_file:s0` on the staged files before mounting.
- **Lesson**: `dumpsys input` + `logcat | grep -i eventhub` is the fastest way to
  see which configuration files the framework actually loaded.

## 4. GKI ships `CONFIG_HID_NINTENDO=y` but `# CONFIG_NINTENDO_FF is not set`

- **Symptom**: `EVIOCSFF` on the combined device succeeds, joycond forwards the
  effect to both pads, `write(EV_FF)` succeeds — but the controllers never vibrate.
- **Root cause**: the FF interface is exposed by the driver regardless, but every
  code path that actually transmits rumble (`joycon_parse_report` →
  `rumble_worker`) is compiled out by `IS_ENABLED(CONFIG_NINTENDO_FF)`. Rebuilding
  the GKI kernel would be heavy; instead the rumble is driven **directly through
  hidraw**.
- **Fix**: the joycond patch in this repo intercepts FF upload/play on the
  combined uinput device and writes BT OUTPUT `0x10` reports to both pads'
  hidraw nodes: `[0x10][pkt_num 0x0-0xF][left 4B][right 4B]`, where each 4-byte
  band is `[HF freq][HF amp][LF freq][LF amp]`. LF amplitude is clamped to the
  protocol's safe maximum `0x72`. FF_RUMBLE's `strong_magnitude` maps to the LF
  band, `weak_magnitude` to the HF band. 60Hz streaming with per-band
  amplitude/frequency control works (see `hd-test`), which is full HD-Rumble
  capability — beyond what the kernel FF path (simple two-motor rumble) could do.

## 5. Joy-Con sleep/reconnect churns all node numbers

- **Symptom**: mid-test the controllers go silent; after waking them, evdev
  nodes shifted (`event4→event5...`), hidraw nodes disappear, HID instance
  numbers increment (`.0001→.0003`).
- **Root cause**: Joy-Cons sleep after ~5 min idle; on reconnect the HID device
  is re-probed and re-registered.
- **Fix**: nothing to fix — upstream joycond tracks controllers by MAC address
  (`/sys/.../uniq`) and re-attaches cleanly. But any hard-coded node numbers in
  scripts/tests will break; always re-resolve nodes via `getevent -p` or by
  device name.

## 6. Wireless adb dropouts during long operations

- **Symptom**: `adb: error: connect failed: closed` / `cannot stat` mid-session.
- **Fix**: `adb connect 192.168.x.x:5555` again; for long pushes prefer USB.

## Pre-flight checklist (all verified green on the reference device)

See [precheck/RESULTS.md](../precheck/RESULTS.md) for the full 10-point check:
kernel config (`CONFIG_HID_NINTENDO=y`), root domain, `/dev/uinput` + hidraw,
driver binding, calibration, button/stick events, IMU streaming, battery node,
InputReader consumption, and the absence of `CONFIG_NINTENDO_FF`.
