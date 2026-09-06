#!/usr/bin/env bash
# 测试C: 通过 hidraw 直接发 subcommand 0x03, 强制手柄切回 0x30 全报告模式
# (正常情况下内核驱动 probe 时已发过;若按键数据丢失且本命令后恢复,说明模式被改掉了)
# 用法: ./jc_force_full.sh [/dev/hidraw0]
#
# 0x01 输出报告布局（权威出处：内核 drivers/hid/hid-nintendo.c 的
# struct joycon_subcmd_request，__packed）：
#   byte 0     output_id   = 0x01  (subcommand 报告；0x10 是纯震动报告)
#   byte 1     packet_num  = 0x0-0xF 滚动
#   byte 2-9   rumble_data = 8 字节，必须填当前震动值/中性值，
#              否则会把正在进行的震动打断（内核注释原话）
#   byte 10    subcmd_id   = 0x03  (JC_SUBCMD_SET_REPORT_MODE)
#   byte 11+   subcmd args = 0x30  (Standard full mode, 60Hz)
#
# 历史 bug：旧版写成 \x01\x05\x0a\x30，子命令落在 byte 2（被当成震动数据），
# byte 10 是 0x00 → 子命令根本没送达；而且 0x0a 是未定义子命令
# （dekuNukem 文档里归在 "All unused subcommands"），正确的应是 0x03。
DEV=${1:-/dev/hidraw0}
echo ">>> 向 $DEV 发送: report=0x01 | pkt=0x05 | rumble[8]=neutral | subcmd=0x03 | arg=0x30 (全报告模式)"
{ printf '\x01\x05\x00\x01\x40\x40\x00\x01\x40\x40\x03\x30'; head -c 52 /dev/zero; } \
  | adb exec-out su -c "cat > $DEV" \
  && echo "已发送。立刻重跑 ./jc_watch.sh 验证按键是否恢复"
