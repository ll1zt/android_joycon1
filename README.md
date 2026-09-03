# android_joycon1 — Joy-Con 安卓系统级合成(KernelSU)

目标:让所有原生安卓游戏把两只 Joy-Con 认成一只完整手柄。
路线:GKI 内核自带 `hid-nintendo`(实测 `=y`)+ joycond 守护进程 + KernelSU 模块。
Pre-check 全绿记录见 `precheck/RESULTS.md`,背景分析见 `temp.md`。

## 构建(声明式,全部 pin 在 flake.lock)

```bash
nix build              # → ./result 是 KernelSU 模块 zip
nix build .#joycond-android   # 只要二进制
```

组成:
- `nix/joycond-android.nix` — NDK r29 交叉编译 libevdev(静态)+ joycond,
  产物只依赖 bionic + liblog;`__ANDROID__` 由 clang android target 自动定义,
  启用上游 netlink 检测器(排除 udev,无需 libudev)
- `nix/module.nix` — 组装 KernelSU 模块 zip
- `module/` — module.prop / service.sh(守护+日志)/ sepolicy.rule(保险)/
  LineageOS 版 0x2008 keylayout + 上游 idc(单只 device.disabled,合成 device.internal=0)

## 安装

1. `result` 拷到手机:`adb push $(readlink -f result) /sdcard/Download/joycond.zip`
2. KernelSU App → 模块 → 从本地存储安装 → 选 zip → **重启**
3. 重启后两只 Joy-Con 各自配对连接(设置→蓝牙,按手柄侧边小圆钮)

## 验证

```bash
adb shell su -c 'ls -l /vendor/bin/joycond'          # magic mount 成功?
adb shell su -c 'tail /data/adb/joycond.log'          # 守护进程日志
adb shell su -c 'getevent -pl | grep -A2 Combined'    # 应见 Nintendo Switch Combined Joy-Cons
```

预期:合成设备 `Vendor 0x57e Product 0x2008` 出现,含双摇杆+HAT+ABXY+模拟扳机;
单只 2006/2007 被 idc 禁用,游戏不再看到半截手柄。

## 已知约束(pre-check 实测)

- 手柄 ~5 分钟休眠,重连后 event 节点号变化 — joycond 的 MAC 去重逻辑已处理
- 蓝牙带宽紧张(dmesg 有 dropped IMU reports),后续 HD Rumble 直通需限速
- kl 为任天堂原生布局(按名字映射);想要 Xbox 布局(A/B、X/Y 交换)改
  `module/keylayout/` 里对应行重新 build 即可
- 体感(IMU)与 NFC/红外仍不可用(框架结构性限制,见 temp.md)

## 开发

```bash
nix develop        # 含 nixfmt-rfc-style / adb / zip
nix fmt
```
