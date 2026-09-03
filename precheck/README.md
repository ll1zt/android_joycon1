# Pre-check / 诊断脚本

一组无时间压力的手工诊断脚本,用于验证内核→evdev→hidraw 链路。
首次部署排查和换机重检时使用。

> 前提:adb 可见设备、手柄已配对;手柄 5 分钟无操作会休眠,先按任意键唤醒。

## 节点解析(每次先做!)

重连/休眠唤醒后 evdev 与 hidraw 编号**会漂移**,先动态确认:

```bash
adb shell su -c "getevent -p | grep -E 'add device|name'" | grep -B1 -i joy
adb shell su -c "grep HID_NAME /sys/class/hidraw/*/device/uevent"
```

## 脚本

| 脚本 | 用途 |
|---|---|
| `jc_watch.sh <eventN>` | 实时监听 evdev 节点事件(Ctrl+C 退出),验证按键/摇杆数据是否到达内核 |
| `jc_bytes.sh <hidraw> [秒]` | 抓 hidraw 原始报告并分析哪些字节在操作时变化(定位数据丢失层) |
| `jc_force_full.sh <hidraw>` | 发 subcommand 强制 0x30 全报告模式(排查报告模式异常) |

典型排查顺序:`jc_watch`(evdev 有数据?)→ `jc_bytes`(hidraw 原始数据里按键字节是否变化?)
→ 结合 README 的架构说明与 dmesg/dumpsys/logcat 输出定位。
