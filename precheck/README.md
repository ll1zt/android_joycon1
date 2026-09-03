# Joy-Con Pre-check 自测指南（无时间压力版）

> 前提：已在 `nix-shell -p android-tools` 里，`adb devices` 能看到手机；手柄已配对。
> 手柄若睡了（LED 全灭），先按一下任意键唤醒。

## 设备对照表（当前 Pixel 6 实测）

| 手柄 | evdev 主节点 | evdev IMU | hidraw |
|---|---|---|---|
| 左 Joy-Con (L) | `event4` | `event5` | `hidraw0` |
| 右 Joy-Con (R) | `event6` | `event7` | `hidraw1` |

> 重连/唤醒后编号可能变，用 `adb shell su -c "getevent -p | grep -B1 Joy-Con"` 复核。

## 测试 A：实时看按键事件（先跑这个，最直观）

```bash
./jc_watch.sh event4     # 左手柄；另开终端跑 event6 测右
```

- 一直按遍：方向键↑↓←→、SL/SR、L、ZL、L3(按摇杆)、-、Home，摇杆画圈
- **有任何输出 = 内核按键通路正常**（之前"零事件"可能只是没按上）
- 按 1 分钟毫无输出 = 异常坐实，继续测试 B

## 测试 B：原始报告字节分析（定位数据丢在哪一层）

```bash
./jc_bytes.sh /dev/hidraw0 20    # 左；右用 /dev/hidraw1
```

20 秒窗口内反复按键+画摇杆（可以按住不放几个键）。看结果表：

| 现象 | 结论 |
|---|---|
| byte3-5 随按键变化、byte6-11 随摇杆变化 | 数据进了内核报告流 → 问题在驱动解析层（再查） |
| 只有 byte1(timer) 和 byte13+(IMU) 变化，byte3-11 恒定 | **按键/摇杆数据没进内核** → 测试 C |

## 测试 C：强制切回 0x30 全报告模式

```bash
./jc_force_full.sh /dev/hidraw0
./jc_watch.sh event4        # 立刻复测按键
```

- **C 之后按键恢复** → 手柄报告模式被改（Android BT 栈/休眠唤醒导致），
  解法明确：joycond 守护进程启动时对每只手柄补发一次 0x0a=0x30 即可
- **C 之后仍无按键** → Android uhid 路径按"瘦描述符"重组报告、扔掉了私有字段，
  需要 dump `report_descriptor` 深挖，或走 hidraw 直通架构（顺带就是 HD Rumble 的路线）

## 判定汇总

- A 有事件 → pre-check 全绿，直接进入 joycond 落地阶段
- B 恒定 + C 恢复 → pre-check 通过（带一条工程要求：守护进程补发模式命令）
- B 恒定 + C 无效 → 停下，先解决框架层丢数据问题再谈 joycond
