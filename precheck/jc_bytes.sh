#!/usr/bin/env bash
# 测试B: 抓取 hidraw 原始报告,分析哪些字节位置在你操作期间发生过变化
# 用法: ./jc_bytes.sh [/dev/hidraw0] [秒数,默认20]
# 报告为 49 字节紧凑 0x30 布局:
#   byte0=ID  byte1=timer  byte2=电量/连接  byte3-5=按键  byte6-8=左摇杆
#   byte9-11=右摇杆  byte12=震动回执  byte13-48=IMU(3x12)
DEV=${1:-/dev/hidraw0}
SEC=${2:-20}
RS=49
OUT=$(mktemp /tmp/jc_bytes.XXXXXX.bin)
trap 'rm -f "$OUT"' EXIT

echo ">>> 3 秒后开始抓 $DEV 共 ${SEC}s。期间请:逐个按遍按键 + 摇杆画圈 + 保持按住几个键不放"
sleep 3
adb exec-out su -c "timeout $SEC dd if=$DEV bs=$RS count=3000 2>/dev/null" > "$OUT"

SIZE=$(wc -c < "$OUT")
N=$((SIZE / RS))
echo "== 抓到 $N 个报告 ($SIZE 字节) =="
if [ "$N" -lt 10 ]; then
  echo "!! 报告太少。可能:手柄在睡(先按键唤醒)/ 节点不对。重试或换 hidraw 节点"
  exit 1
fi

od -An -tu1 -v "$OUT" | tr -s ' \t' '\n' | grep -v '^$' | awk -v rs=$RS -v n=$N '
{
  pos=(NR-1)%rs; val=$1
  key=pos "_" val
  if (!(key in seen)) { seen[key]=1; nval[pos]++ }
  if (!(pos in have)) { have[pos]=1; min[pos]=val; max[pos]=val }
  if (val<min[pos]) min[pos]=val
  if (val>max[pos]) max[pos]=val
}
END {
  printf "%-6s %-8s %-8s %-8s %s\n","byte","变化值数","min","max","字段含义"
  for (p=0;p<rs;p++) {
    note = (p==0?"报告ID": p==1?"timer": p==2?"电量/连接": (p>=3&&p<=5)?"★按键★":
           (p>=6&&p<=8)?"★左摇杆★": (p>=9&&p<=11)?"★右摇杆★": p==12?"震动回执":"IMU")
    if (nval[p]>1) printf "%-6d %-10d 0x%02x   0x%02x   %s\n", p, nval[p], min[p], max[p], note
    else if (p<=12) printf "%-6d %-10d 0x%02x   0x%02x   %s  (恒定)\n", p, nval[p], min[p], max[p], note
  }
  print ""
  print "判读: 按键时 byte3-5 应变化; 摇杆画圈时 byte6-11 应变化。"
  print "      若只有 IMU(13+) 和 timer(1) 在变 → 按键/摇杆数据确实没进内核。"
}'
