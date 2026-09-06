# joycond-android — 在安卓上把两只 Joy-Con 变成一只手柄,还带 HD 震动

[English README](README.md)

> **一分钟速览** — 已 root 的 GKI 内核安卓机(Android 12+，如 Pixel，KernelSU/Magisk):
> `nix build` → 刷入 zip → 重启 → 配对两只 Joy-Con，全局合成一只手柄，游戏直接用，
> 还带震动。已在 Pixel 6 / Android 16 验证。其他机型需要自行适配，先看[预检脚本](precheck/)。

仅 root 方案:让**所有原生安卓游戏和模拟器**把一对任天堂 Joy-Con 识别成**一只完整手柄**
(`Nintendo Switch Combined Joy-Cons`,vendor `0x057e` / product `0x2008`),并附带
**普通震动与 HD Rumble 级别的波形震动**——即使内核 FF 路径被裁掉也能震。

开发与验证环境:**Pixel 6 (oriole) / Android 16 / GKI 内核 6.1.145-android14**,
root 方式为 **KernelSU Next**。全部构建用 Nix flake 声明式管理,`nix build` 直接产出
可安装的 KernelSU 模块 zip。

## 工作原理

```
BT HID (uhid)                内核 hid-nintendo(GKI 内置 =y)      /dev/input         /dev/hidraw
┌──────────────┐   校准/IMU/电池全量数据             ┌────────────────────┐
│ Joy-Con (L)  ├──────────────────────────────────► │ evdev event4 (L)   │─┐
│ Joy-Con (R)  ├──────────────────────────────────► │ evdev event6 (R)   │ │
└──────────────┘                                    └────────────────────┘ │
                                                            ▲  ▼            │
                                     EVIOCGRAB + FF 截获    │  │            │
                                                    ┌───────┴──┴────────┐   │
                                                    │      joycond      │   │
                                                    │(打过补丁,见下文)  │   │
                                                    └───────┬───────────┘   │
                                  uinput 合成设备 0x2008    │               │
                                  标准手柄轴(X/Y/Z/RZ/HAT…) ▼               │
                                  ◄─── service.sh 放置    /data/system/devices/
                                                          │  {keylayout,idc}│
                          FF upload/play ─────────────────┤               │
                                                          ▼               │
                                              rumble_hidraw: 0x10 报告 ───┘
                                              (最高 60Hz,HF+LF 双频带,
                                               绕过 CONFIG_NINTENDO_FF=n)
```

三层必须协同(每一层都踩过真实的坑):

1. **内核层**:新 GKI 内核自带 `CONFIG_HID_NINTENDO=y`(编进本体),Joy-Con 直接绑
   `nintendo` 驱动,工厂/用户校准齐全,**不用编内核**。但 GKI 没开
   `CONFIG_NINTENDO_FF`(力反馈子开关)——FF 能力位和 ff-core 注册都在这个 ifdef 里,
   物理手柄上**连 FF 接口都没被注册**,内核路径永远发不出震动。本项目的解法是
   **绕开**它,见第 2 层。
2. **用户态**:上游 [joycond](https://github.com/DanielOgorchock/joycond) 独占
   (grab)两只物理手柄、合成 uinput 设备;它自带 Android 检测器(netlink uevent,
   不需要 udev)。本项目给它打了补丁:截获游戏上传的 FF 效果,改经 **hidraw 直接写
   `0x10` 震动报告**(HF+LF 双频带,最高 60Hz 流式——HD Rumble 的全部能力),同时把
   LF 幅度钳制在安全上限 `0x72` 以内。
3. **框架层**:keylayout(`Vendor_057e_Product_2008.kl`,LineageOS 2025 版,含 HAT
   轴 + 模拟扳机)与 idc 文件由模块的 `service.sh` 直接写入
   `/data/system/devices/{keylayout,idc}`——AOSP EventHub 搜索链的**末位**
   (odm/vendor/system 之后),Pixel 6 / Android 16 实测加载成功。不依赖
   magic mount / metamodule,也没有 bind mount 的遮蔽风险:文件缺失只会回退
   `Generic.kl`。SELinux 标签由父目录自动继承(`system_data_file`),
   enforcing 下 system_server 可读。剩下的坑只有一个:`/data` 分区无法 exec
   (守护进程先拷到 `/dev` tmpfs 再跑)。

## 功能现状

| 能力 | 状态 |
|---|---|
| 全系统级合成:所有 App 只见一只完整手柄 | ✅ |
| 双摇杆(全量程+校准)、ABXY、十字键→HAT、L/R、ZL/ZR→模拟扳机、SL/SR、±、Home、Capture | ✅ |
| 单只手柄对框架不可用(idc `device.disabled=1` 不生成 Mapper) | ✅(Android 16 实测:设备仍留在 InputReader 列表并占用 ControllerNumber,不可用但并非真正移除) |
| 普通震动(strong→LF 低频带、weak→HF 高频带) | ✅ hidraw 直通(2026-09-06 GamePad Tester 游戏内 + ff-test 幅度四连测验证) |
| **HD Rumble 级流式波形**(60Hz、双频带独立幅度/频率控制) | ✅ `hd-test` |
| 休眠自动重连(~5 分钟息睡),按 MAC 重绑 | ✅ joycond 处理 |
| 电量 | ✅ 内核有(`capacity_level`),框架无 UI(经典 C 类断点) |
| 体感 IMU | ❌ 内核有数据,joycond 合成时丢弃,安卓框架无通路(结构性) |
| NFC/Amiibo、红外摄像头 | ❌ 结构性无解 |

## 构建

前置:Nix 且开启 flakes。其余(NDK r29、libevdev、交叉工具链)全部由
`flake.lock` 锁定。

```bash
nix build                    # KernelSU 模块 zip → ./result
nix build .#joycond-android  # 仅守护进程二进制
nix build .#ff-test-android  # evdev FF 测试工具
nix build .#hd-test-android  # HD 震动波形演示播放器
```

Android 侧产物仅依赖 `libc.so / liblog.so / libdl.so / libm.so`
(libc++ 静态链接,API 28)。

## 安装

```bash
adb push -a "$(readlink -f result)" /sdcard/Download/joycond.zip
```

然后:**KernelSU App → 模块 → 从本地存储安装 → 选 zip → 重启**。
卸载模块时会自动执行 `uninstall.sh`,清理写入 `/data/system/devices` 的持久文件
(挂载方案无需此步,/data 文件是持久的)。注意**「禁用」不等于「卸载」**:禁用状态下
模块脚本不会执行、`uninstall.sh` 也不会跑,`/data/system/devices` 的文件会残留
(单只 Joy-Con 仍被 idc 禁用)——要彻底还原请「卸载」。
在系统蓝牙设置里配对两只 Joy-Con(按住导轨上的小圆同步钮)。两只连上后
**自动合成**(无需按 L+R——Android 版 joycond 让单只处于 Waiting 状态,凑齐即合)。

## 验证

```bash
adb shell 'logcat -d -s joycond'                    # 守护进程日志:配对流程走 logtag joycond
                                                    #   (/data/adb/joycond.log 里只有错误与诊断)
adb shell su -c 'getevent -il | grep -A2 Combined'  # 合成设备
adb shell 'dumpsys input | grep -A12 Combined'      # 框架视角
```

框架应显示 `Sources: KEYBOARD | GAMEPAD | JOYSTICK` 与标准轴
`AXIS_X/Y/Z/RZ/HAT_X/HAT_Y`,`KeyLayoutFile` 应指向
`/data/system/devices/keylayout/Vendor_057e_Product_2008.kl`。ControllerNumber
取决于物理手柄占用情况(Pixel 6 实测为 3:单只 Joy-Con 虽不可用但仍占编号 1/2)。
任何支持手柄的游戏此时应直接可用。


HD 震动演示(双手柄同步,4 段循环波形:弹珠滚动/心跳/雨滴/滑音):

```bash
adb push $(nix build --no-link --print-out-paths .#hd-test-android)/bin/hd-test /data/local/tmp/
adb shell su -c '/data/local/tmp/hd-test /dev/hidraw0 /dev/hidraw1'
```

## 仓库结构

```
├── flake.nix               # 入口;NDK 用专用 allowUnfree 实例
├── nix/
│   ├── joycond-android.nix # NDK r29 交叉构建;libevdev 静态;bionic 兼容补丁
│   ├── joycond-hidraw-rumble.patch  # joycond 的 hidraw 震动直通补丁
│   ├── module.nix          # KernelSU 模块组装(zip)
│   ├── ff-test.nix         # evdev FF 测试工具(aarch64-android)
│   └── hd-test.nix         # HD 震动波形播放器
├── module/                 # module.prop、service.sh(放置 .kl/.idc)、uninstall.sh
│   ├── keylayout/          #   Vendor_057e_Product_2008.kl(LineageOS 2025 版)
│   └── idc/                #   2006/2007 禁用单只、2008 标记外接
├── ff-test/、hd-test/      # 测试工具源码(ff-test:已死的内核 FF 路径验证;hd-test:HD 震动演示)
├── refs/                   # 上游克隆(gitignore):joycond、LineageOS HAL、dekuNukem 文档
├── precheck/               # 预检脚本
```

## 许可

- joycond 上游:GPLv3;本仓库构建体系与补丁:GPLv3-or-later
- 模块 zip 分发的是修改过的 joycond 二进制(GPLv3),对应完整源码即本仓库
  (补丁 + 构建体系),全文见根目录 [`LICENSE`](LICENSE)
- keylayout 文件:Apache-2.0(LineageOS)

## 致谢

- [DanielOgorchock/joycond](https://github.com/DanielOgorchock/joycond) — 守护进程本体
- [LineageOS android_hardware_nintendo_joycond](https://github.com/LineageOS/android_hardware_nintendo_joycond) — keylayout、sepolicy 参考
- [dekuNukem/Nintendo_Switch_Reverse_Engineering](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering) — Joy-Con 协议与震动数据格式文档
