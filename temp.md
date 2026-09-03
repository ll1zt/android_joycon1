# 全文总结：安卓上使用 Joy-Con 1 的完整图景（仅 root 方案）

## 一、现实的问题

### 1. 协议层：问题早已解决，但常被误判

- Joy-Con 的蓝牙 HID 描述符只暴露瘦按键集，完整数据（摇杆校准、IMU、震动、LED）依赖私有 subcommand 切到 `0x30` 全报告模式——这套协议 Linux 侧已有开源实现，**不需要从零移植**
- 内核 `hid-nintendo` 驱动自 Linux 5.16 进主线，Android Common Kernel 已收录；现代 GKI（如 android15-6.6）直接 `CONFIG_HID_NINTENDO=y` 编进本体，Pixel 及多数 GKI 机型免编内核
- 真正需要自编内核的只有：非 GKI 老内核（4.9/4.14/4.19/5.4 厂商树）和被裁剪的定制内核
- 没有 hid-nintendo 而 fallback 到 hid-generic 时：蓝牙能连、按键能用，但**摇杆残缺/未校准**——这是"连得上但玩不了"的错觉来源

### 2. 用户态层：比想象中成熟

- 双手柄合成靠 joycond 守护进程，生成 `Nintendo Switch Combined Joy-Cons` 虚拟设备（PID 0x2008）
- 原文"主要障碍是 libudev"的判断**已过时**：上游已有 `ctlr_detector_android.cpp`，用 netlink uevent 而非 udev，编译时定义 `__ANDROID__` 即启用 [github](https://github.com/DanielOgorchock/joycond/blob/master/CMakeLists.txt)
- Android 构建的特例：因玩家灯无 UI 反馈，Joy-Con 永远处于 Waiting 状态，**两只一连上自动合成**，无需按 L+R；副作用是单只横持模式被禁用（改几十行可恢复）
- LineageOS 有 AIDL HAL 级参考实现（Switchroot 在用），但手机版 LineageOS 默认不带 [github](https://github.com/LineageOS/android_hardware_nintendo_joycond)

### 3. Android 框架层：标准手柄契约太窄

- 合成设备 0x2008 缺 keylayout，不补则游戏键位全乱；左 Joy-Con 方向键不返回标准 `KEYCODE_DPAD_*` 
- SELinux 限制 `/dev/uinput` 访问，是比 libudev 更真实的拦路虎
- 安卓游戏认的手柄模型只有：按键 + 摇杆轴 + 可选震动 + 可选 sensor——Joy-Con 多出的能力没有地方放

### 4. 功能断点：三类"不支持"

| 类型 | 含义 | 涉及功能 |
|---|---|---|
| A. 契约里没有 | OS 抽象表达不了，改 joycond 救不了 | NFC/Amiibo、红外摄像头、HD Rumble 质感 |
| B. 下层有、路径扔了 | 内核有数据，合成/框架丢弃，加代码可补 | IMU 体感、单只横持、充电握把/N64 白名单 |
| C. 送到了、没人用 | 节点存在但游戏/系统不读 | 普通震动（部分游戏）、玩家灯、电量 |

- **IMU**：内核拆成独立 evdev 节点，joycond 合成时故意丢弃；Eden 安卓版读外接手柄陀螺仪至今是 open 的功能请求 
- **HD Rumble**：四层断链——协议完好（双频带 HF 81.75–1252.57Hz / LF 40.87–626.28Hz，60Hz 流式下发） ，内核频率表也在 ，但驱动只注册 `FF_RUMBLE`（强弱两档），Android `VibrationEffect` 无频率维度，游戏内容本身就按"时长+振幅"创作。**本质是抽象模型错配：系统是"两个马达震多大力"，HD Rumble 是"一个喇叭播放波形"** [github](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering/blob/master/bluetooth_hid_notes.md)
- **模拟扳机**：硬件上就不存在（ZL/ZR 是数字微动）

### 5. Eden 模拟器特有的现实

- 桌面端走 SDL3（输入满血），安卓端走 InputDevice 层，只能拿到 InputFlinger 加工后的数据
- 左 Joy-Con 方向键问题已由 Eden 的 scancode 回退修复 
- 体感只能用手机陀螺仪；Amiibo 反而变优势——Eden 直接从 .bin 文件加载，不需要 NFC 硬件
- Eden 模拟 HID 服务时经手游戏下发的原始震动数据，但当前降级翻译成普通震动 ——这是 HD Rumble 方案的切入点 [reddit](https://www.reddit.com/r/yuzu/comments/swjf9q/does_yuzu_supports_hd_rumble_with_the_dualsense/)

## 二、我的需求

1. **核心需求**：让所有原生安卓游戏把两只 Joy-Con 认成"一只完整手柄"（系统级合成，不依赖单个 App 的支持）
2. **模拟器需求**：在 Eden 上正常使用 Joy-Con 玩 Switch 游戏
3. **进阶需求**：理解并尽可能实现 HD Rumble 的质感
4. **前提与约束**：设备已具备 Magisk root 权限；工程量要可控；不重复造轮子（不写协议、不写 udev 适配）

## 三、实现的方案

### 方案 1：GKI + root + joycond 系统级路径（核心需求）

五步落地，工程量约半天到一天，sepolicy 调试是大头：

1. **验证内核**：`zcat /proc/config.gz | grep HID_NINTENDO` 应为 `=y`；配对后 `dmesg` 应见 `nintendo 0005:057E:...` 而非 hid-generic——否则此路终止，回去编内核
2. **交叉编译**：NDK 静态编 libevdev + 直接编译 joycond 源码（排除 udev 检测器，保留 android 检测器），产物只依赖 bionic
3. **投放 keylayout**：Magisk 模块 magic mount `Vendor_057e_Product_2008.kl`（按键码 + 双摇杆轴 + HAT），注意任天堂/Xbox 的 ABXY 布局差异可选交换 
4. **SELinux + 服务**：`service.sh` 等待开机完成后启动守护进程；先跑起来抓 `avc: denied`，再按实际日志写 `sepolicy.rule`（uinput/input_device 的 chr_file 权限），不要直接 permissive 
5. **验证排错**：`getevent -pl` 见合成设备 → 手柄测试 App 逐键确认 → 进游戏；常见问题对照（键位乱=kl 没读到、震动断连=蓝牙 rumble 老毛病需限速、不合体=确认走了 Android 分支）

### 方案 2：HD Rumble 质感（进阶需求，按可行性排序）

1. **改进翻译**：fork hid-nintendo 把强弱震映射到 LRA 谐振甜区 + 包络整形——成本最低，天花板是"更好的普通震动"
2. **hidraw 直通守护进程**：root 下直接写 `0x10` 纯震动报告，任意双频带波形，绕开 FF 子系统（复用方案 1 的 Magisk/sepolicy 工程） [github](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering/blob/master/bluetooth_hid_notes.md)
3. **模拟器直通（杀手锏）**：Switch 游戏**本来就产出 HD 级震动数据**，只是被 Eden 降级翻译 。给 Eden 打补丁把原始 VibrationValue 经本地 socket 导出 → hidraw 守护进程直写 Joy-Con——内容源和播放端都可控，保真度可接近实机，**今天就可行，不用等上游** [reddit](https://www.reddit.com/r/yuzu/comments/swjf9q/does_yuzu_supports_hd_rumble_with_the_dualsense/)
4. **音频合成**：给原生游戏抓音频提取低频包络实时合成波形——真实但属锦上添花

约束：蓝牙带宽与 60Hz 输入报告抢链路需限速；LF 幅度安全上限 `0x72` 要自己守（防 LRA 损伤） ；不推荐改内核扩展 evdev API（GKI KMI 限制下很痛苦，hidraw 完全覆盖）。 [github](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering/blob/master/bluetooth_hid_notes.md)

### 明确不要做的事

- 不要从零移植协议（hid-nintendo 已是完整实现）
- 不要写 udev 适配层（上游 Android 检测器已存在）
- 不要指望原生安卓游戏出现 HD 内容（内容生态缺失，只能靠合成）
- Joy-Con 2 是另一代协议（私有 BLE GATT），走 joycon2android 的 Shizuku+UHID 路线，与本文所有方案无关

**一句话总览：在 root 前提下，系统级合成只需"编一个 joycond + 三个文件（二进制、keylayout、sepolicy）"，半天到一天可落地；体感、NFC、红外属结构性无解；HD Rumble 唯一值得做的场景是模拟器直通，且今天就能做。**
