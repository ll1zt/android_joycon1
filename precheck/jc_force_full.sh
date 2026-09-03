#!/usr/bin/env bash
# 测试C: 通过 hidraw 直接发 subcommand 0x0a, 强制手柄切回 0x30 全报告模式
# (正常情况下内核驱动 probe 时已发过;若按键数据丢失且本命令后恢复,说明模式被改掉了)
# 用法: ./jc_force_full.sh [/dev/hidraw0]
DEV=${1:-/dev/hidraw0}
echo ">>> 向 $DEV 发送: output_report 0x01 | counter=0x05 | subcmd=0x0a | param=0x30 (全报告模式)"
{ printf '\x01\x05\x0a\x30'; head -c 60 /dev/zero; } | adb exec-out su -c "cat > $DEV" \
  && echo "已发送。立刻重跑 ./jc_watch.sh 验证按键是否恢复"
