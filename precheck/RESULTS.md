# Pre-check 最终报告（2026-09-03）

## 结论：✅ 方案 1（GKI + root + joycond）完全可行，无需编内核，进入实现阶段

## 检查清单

| # | 项目 | 结果 | 证据 |
|---|---|---|---|
| 1 | 设备/内核 | Pixel 6 (oriole) / Android 16 / **GKI 6.1.145-android14-11** | `uname -r` |
| 2 | hid-nintendo | **`CONFIG_HID_NINTENDO=y` 编进内核本体** | `/proc/config.gz` + kallsyms 11 符号 |
| 3 | root | ✅ **KernelSU**（注意：非 Magisk） | `su -c id` → `u:r:ksu:s0`，`/data/adb/ksu` |
| 4 | uinput/hidraw | ✅ 都在（uinput 标签 `uhid_device`） | `ls -lZ /dev/uinput /dev/hidraw*` |
| 5 | 驱动绑定 | ✅ 两只一连上即绑 `nintendo`（非 hid-generic），经 uhid 总线（Android BT 栈正常路径） | `/sys/bus/hid/drivers/nintendo/` |
| 6 | 校准 | ✅ factory/user cal 加载成功 | dmesg |
| 7 | 按键/摇杆 | ✅ 全按键 DOWN/UP 正常，摇杆全量程 ±32767 平滑 | `jc_watch.sh` 实测（见 precheck/README.md） |
| 8 | IMU | ✅ 内核层 200Hz 流式（加速度+陀螺+时间戳） | event5/7 抓取 |
| 9 | 电量 | ✅ `capacity_level` 上报（仅档位无百分比） | power_supply 节点 |
| 10 | 框架消费 | ✅ InputReader 打开 event4/event6；游戏能"看见"两只半截手柄 | `/proc/<system_server>/fd` |

## 实测发现的工程约束（比文档多出来的信息）

1. **KernelSU 而非 Magisk**：模块用 KSU 格式部署（兼容 magic mount / service.sh / sepolicy.rule），安装入口是 KernelSU App
2. **手柄 ~5 分钟休眠**：唤醒后 HID 实例重绑（`.0001→.0003`），**event 节点号会变**——joycond 用 netlink uevent 监听没问题，但任何按节点号写死的东西都会踩坑
3. **蓝牙带宽紧张实锤**：活跃操作时 dmesg 持续刷 `compensating for N dropped IMU reports`——印证文档"HD Rumble 60Hz 下发需限速"的约束，震动数据要节流
4. **B 类断点确认**：IMU 节点存在但 InputReader 直接忽略（`INPUT_PROP_ACCELEROMETER`）；电量节点存在但无 UI/框架读取（C 类）
5. **休眠期间 hidraw 节点会消失**（hidraw1 曾整个不见）——HD Rumble 守护进程必须处理节点热插拔

## 踩坑记录（避免误判）

- "按键零事件"是**测试时间窗太短 + 手柄休眠**造成的假异常；无时间压力的 `jc_watch.sh` 实测一切正常。教训：交互测试必须给用户留足操作窗口
- Joy-Con 的 BT HID 走 `/dev/uhid` 注入（Android BT 栈行为，与桌面 BlueZ 相同），看到 `virtual/misc/uhid` 路径不是异常
- 49 字节紧凑 0x30 报告中 buttons 字段为**高有效**（全松开=00 00 00），与私有 321 字节报告的低位有效不同，读原始字节时别搞反

## 下一步（实现阶段路线）

1. NDK 交叉编译 joycond（`__ANDROID__` netlink 检测器分支）
2. KernelSU 模块四件套：joycond 二进制 + `Vendor_057e_Product_2008.kl` + `service.sh` + `sepolicy.rule`（先跑抓 avc denied）
3. 验证：`getevent -pl` 见 `Nintendo Switch Combined Joy-Cons` (0x2008) → 手柄测试 App → 实游戏
4. （进阶）Eden HD Rumble 直通：hidraw 守护进程 + Eden 补丁导出 VibrationValue
