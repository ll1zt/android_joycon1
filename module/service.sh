#!/system/bin/sh
### joycond KernelSU 启动脚本(late_start,root/ksu 域)
### 二进制经 magic mount 位于 /vendor/bin/joycond(/data 分区 noexec,不能原地跑)
MODDIR=${0%/*}
LOG=/data/adb/joycond.log

# 等开机完成
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done
sleep 3

# 简易守护:崩溃后 5 秒重启;日志落盘便于 adb 排查
while true; do
  if [ -x /vendor/bin/joycond ]; then
    /vendor/bin/joycond >> "$LOG" 2>&1
    echo "[service.sh] joycond exited with $?" >> "$LOG"
  else
    echo "[service.sh] /vendor/bin/joycond not found (magic mount failed?)" >> "$LOG"
    sleep 30
    continue
  fi
  sleep 5
done
