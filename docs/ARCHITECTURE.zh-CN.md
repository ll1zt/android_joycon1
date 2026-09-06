# 架构文档

[English](ARCHITECTURE.md)

本文解释项目的运行时架构与构建架构,以及每个部件为什么存在。

## 运行时:数据流

```
                蓝牙 HID(Android BT 协议栈 → /dev/uhid)
                                    │
                     内核 hid-nintendo(GKI 内置)
                    校准/IMU/电池(FF 接口未注册)
                                    │
          ┌─────────────────────────┼───────────────────────────┐
          ▼                         ▼                           ▼
   evdev event4 (L)          evdev event6 (R)            /dev/hidraw0/1
   evdev event5 (L IMU)      evdev event7 (R IMU)        (原始 BT 报告)
          │                         │                           ▲
          │ EVIOCGRAB               │ EVIOCGRAB                 │ 0x10 震动
          └───────────┬─────────────┘                           │ (直通写入)
                      ▼                                          │
              ┌───────────────┐   uinput 合成 0x2008       ┌────┴─────────┐
              │    joycond    │──────────────────────────► │ /dev/input/  │
              │  (打过补丁)   │   KEYBOARD|GAMEPAD|JOYSTICK│  eventN      │
              └───────┬───────┘   AXIS_X/Y/Z/RZ/HAT_X/Y   └──────────────┘
                      │ 截获 FF upload/play                       │
                      └───────────────────────────────────────────┘
```

### 每个部件存在的理由

| 部件 | 理由 |
|---|---|
| 内核 `hid-nintendo` | 唯一说 Joy-Con 私有协议的组件(subcommand、0x30 全量报告、校准、IMU),GKI 内置。 |
| joycond | 单只 Joy-Con 只有半副手柄。joycond 独占两只、合并输入,创建 App 看到的 `0x2008` 合成设备;它的 Android 检测器走 netlink uevent(Android 没有 udev)。 |
| uinput FF 钩子 → hidraw | GKI 编译驱动时没开 `CONFIG_NINTENDO_FF`,物理手柄上 FF 接口根本没被注册(连 `EV_FF` capability 都没有),内核路径永远发不出震动。补丁在 joycond 内截获效果(它本来就要经 `UI_BEGIN_FF_UPLOAD` 处理),直接写 `0x10` 震动报告到手柄 hidraw。 |
| keylayout `Vendor_057e_Product_2008.kl` | 把合成设备的 evdev 键码/轴映射为 Android `KEYCODE_BUTTON_*` / `MotionEvent.AXIS_*`。没有它轴会被标成 `GENERIC_*`,游戏直接无视设备。 |
| idc 文件 | `2006/2007: device.disabled=1` 让框架不为半截手柄生成 Mapper(Android 16 实测:设备仍留在 InputReader 列表并占用 ControllerNumber,不可用但未真正移除);`2008: device.internal=0` 标记合成设备为外接手柄。 |
| service.sh | 开机放置:二进制 → `/dev` tmpfs(可 exec),keylayout/idc → `/data/system/devices/{keylayout,idc}`(EventHub 搜索链末位,无挂载;失败即回退 Generic.kl,无遮蔽风险),然后以退避策略守护进程并把日志落到 `/data/adb/joycond.log`。 |
| sepolicy.rule | 保险:把 LineageOS 给其 `joycond` 域的权限授予 `ksu` 域(input/uhid/netlink/sysfs)。实践中 KernelSU 的 `ksu` 域是 permissive,规则属于双保险。 |

### 震动协议细节

BT OUTPUT 报告 `0x10`(纯震动),64 字节:

```
[0]      0x10
[1]      包计数器,0x0–0xF 循环
[2..5]   左手柄频段:HF 频率、HF 幅度、LF 频率、LF 幅度
[6..9]   右手柄频段:同上
[10..63] 零
```

幅度编码不对称:LF 幅度 `0x40 = 0.0f … 0x72 = 1.0f`(安全上限——超限可能损坏
LRA),HF 幅度 `0x01 = 0.0f … 0xC8 = 1.0f`。频率覆盖 LF 40.87–626.28Hz、
HF 81.75–1252.57Hz。单只手柄的单个 LRA 可以同时驱动两个频段,帧可以按最高
60Hz 流式下发——Switch 游戏的"HD 震动"质感(滚珠、雨滴、引擎轰鸣)正是这样
产生的。`hd-test` 用 4 段循环波形演示了这套能力。

## 构建架构(Nix flakes)

```
flake.nix ─┬─ nix/joycond-android.nix ─┬─ fetchFromGitHub joycond @ 0df025a
           │                           ├─ nix/joycond-hidraw-rumble.patch
           │                           ├─ libevdev 1.13.2(fetchurl,meson cross → NDK clang)
           │                           └─ ndk-bundle(androidenv,r29)
           ├─ nix/module.nix ──────────┴─ module/(prop、service.sh、uninstall.sh、sepolicy、kl、idc)
           ├─ nix/ff-test.nix  → ff-test/ff-test.c
           └─ nix/hd-test.nix  → hd-test/hd-test.cpp
```

关键决策:

- **交叉工具链**:`androidenv.androidPkgs.ndk-bundle`(NDK r29,预编译,已锁定)。
  nixpkgs 自带的 `pkgsCross.aarch64-android` stdenv 当前是坏的(compiler-rt
  bootstrap 对着 bionic 头文件失败),所以改用官方 NDK。NDK 是 unfree 许可,
  通过**专用的 `allowUnfree = true` nixpkgs 实例**实例化,主实例保持干净。
- **libevdev**:joycond 唯一真正的 C 依赖;用 meson 交叉文件指向 NDK clang
  wrapper 构建静态库。三个小补丁:bionic 无 `librt`(功能在 libc 里 →
  `required: false`);`configure_file` 的 python 脚本改为
  `find_program('python3')` 显式调用(shebang 稳健性);`-Ddocumentation=disabled`。
- **joycond**:直接用 NDK clang++ driver 编译(源列表镜像上游 `Android.mk`,
  用 android 检测器替代 udev 检测器)。`__ANDROID__` 由 clang 的 android
  target 自动定义。API 级别 28(bionic 从 28 起才导出 `glob`/`globfree`)。
  `-static-libstdc++` 使二进制只依赖 `libc/liblog/libdl/libm`。
- **补丁**:hidraw 震动特性以单个 git patch 维护
  (`nix/joycond-hidraw-rumble.patch`),便于跟着上游 joycond 版本 rebase;
  再生成方法:把上游拷到临时目录、`git init`、改代码、`git diff`。

## 已知限制

- IMU 数据能到内核,但 joycond 合成时丢弃,且 Android 框架没有外接陀螺仪
  API——不做模拟器改造就无法体感瞄准。
- NFC/Amiibo 与红外摄像头完全没有进入 Android 的通路。
- 电池只有 `capacity_level`(4 档),没有百分比。
- keylayout/idc 从 `/data/system/devices` 加载(搜索链**末位**):若 ROM 自带
  同名 `.kl`(例如集成 joycond 的 LineageOS),system 路径会优先——但那种 ROM
  本身已内置支持,不构成实际影响。
- 单只 Joy-Con 并未从框架移除(Android 16 实测),只是没有 Mapper;它们仍占用
  ControllerNumber,合成设备的编号因此取决于物理手柄占用情况。
- 震动直通从 joycond 写 hidraw;如果未来 GKI 打开了 `CONFIG_NINTENDO_FF`,
  两条路径会打架——届时移除补丁、把 FF 还给内核即可。
