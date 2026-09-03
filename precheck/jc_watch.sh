#!/usr/bin/env bash
# 测试A: 实时监听某个 evdev 节点的事件流(无时间压力,随时按键,Ctrl+C 退出)
# 用法: ./jc_watch.sh [event4|event6]
NODE=${1:-event4}
echo ">>> 监听 /dev/input/$NODE — 现在随便按键/拨摇杆,有反应会实时打印,Ctrl+C 退出"
adb shell su -c "getevent -lt /dev/input/$NODE"
