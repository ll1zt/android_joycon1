#!/system/bin/sh
### joycond KernelSU 启动脚本(late_start,root/ksu 域)
### 自给自足模式:不依赖 KSU metamodule(magic mount),自己完成文件放置与 bind mount
MODDIR=${0%/*}
LOG=/data/adb/joycond.log
BIN=/dev/.joycond-bin
KLOVER=/dev/.joycond-kl
IDCOVER=/dev/.joycond-idc

log() { echo "[service.sh] $(date '+%m-%d %H:%M:%S') $1" >> "$LOG"; }

# 等开机完成
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done
sleep 2

log "=== service.sh start (moddir=$MODDIR) ==="

# ---- 1. 二进制 → /dev tmpfs(已验证 /data 分区 exec 该文件失败,/dev 可行) ----
mkdir -p "$BIN"
if ! cp "$MODDIR/bin/joycond" "$BIN/joycond" 2>>"$LOG"; then
  log "FATAL: cannot copy binary"; exit 1
fi
chmod 755 "$BIN/joycond"
log "binary staged at $BIN/joycond"

# ---- 2. keylayout/idc 覆盖(bind mount,tmpfs 目录 → /system/usr/...) ----
# 做法:magic mount 简化版——原目录内容 + 新文件复制到 tmpfs,再 bind 覆盖
do_overlay() {
  SRC_DIR="$1"    # 模块内新文件目录
  TGT_DIR="$2"    # 系统 keylayout/idc 目录
  OVL="$3"        # tmpfs 暂存目录
  mkdir -p "$OVL"
  # 复制系统现有内容(若有)
  if [ -d "$TGT_DIR" ]; then
    cp "$TGT_DIR"/* "$OVL/" 2>>"$LOG"
  fi
  # 放入我们的文件
  cp "$SRC_DIR"/* "$OVL/" 2>>"$LOG" || { log "overlay copy failed for $TGT_DIR"; return 1; }
  chmod 644 "$OVL"/*
  # 关键:overlay 里的文件必须打 system_file label,否则 system_server 读取被
  # SELinux enforcing 拒绝(avc denied { read } tcontext=u:object_r:device:s0)
  chcon u:object_r:system_file:s0 "$OVL"/* 2>>"$LOG"
  # 幂等:已挂载则跳过(mount 点的 stat 与 tmpfs 不同)
  if ! grep -q " $TGT_DIR " /proc/mounts; then
    mount --bind "$OVL" "$TGT_DIR" 2>>"$LOG" || { log "bind mount $TGT_DIR failed"; return 1; }
    log "bind-mounted $OVL -> $TGT_DIR"
  else
    log "$TGT_DIR already mounted, skip"
  fi
}
mkdir -p /system/usr/keylayout /system/usr/idc 2>>"$LOG"
do_overlay "$MODDIR/kl"  /system/usr/keylayout "$KLOVER"
do_overlay "$MODDIR/idc" /system/usr/idc       "$IDCOVER"

# ---- 3. 守护循环 ----
RESTART_COUNT=0
while true; do
  if [ -x "$BIN/joycond" ]; then
    "$BIN/joycond" >> "$LOG" 2>&1
    RC=$?
    RESTART_COUNT=$((RESTART_COUNT + 1))
    log "joycond exited rc=$RC (restart #$RESTART_COUNT)"
    # 连续崩溃超过 10 次退避 60s
    if [ $((RESTART_COUNT % 10)) -eq 0 ]; then log "backoff 60s"; sleep 60; fi
  else
    log "binary missing, waiting"
    sleep 30
    continue
  fi
  sleep 5
done
