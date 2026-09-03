#!/system/bin/sh
### joycond KernelSU 启动脚本(late_start,root/ksu 域)
### 用法:
###   service.sh          开机入口:放置文件+挂载+守护循环
###   service.sh remount  WebUI 调用:按 config.json 重新选择 kl 并重挂载(不动守护)
MODDIR=${0%/*}
LOG=/data/adb/joycond.log
BIN=/dev/.joycond-bin
CFG=/data/adb/modules/joycond/config.json
MODE="${1:-boot}"

log() { echo "[service.sh] $(date '+%m-%d %H:%M:%S') $1" >> "$LOG"; }
json() {  # json <key> <default> — 极简 JSON 提取(toybox sed 兼容)
  sed -n "s/.*\"$1\" *: *\"\{0,1\}\([^,\"]*\)\"\{0,1\}.*/\1/p" "$CFG" 2>/dev/null | head -1 || echo "$2"
}

wait_boot() {
  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
  sleep 2
}

place_bins() {
  mkdir -p "$BIN"
  for f in joycond ff-test hd-test; do
    cp "$MODDIR/bin/$f" "$BIN/" 2>>"$LOG" && chmod 755 "$BIN/$f"
  done
  log "binaries staged at $BIN"
}

# 整目录 overlay:一个目标目录 = 一个 staging = 一次 bind mount
# (多次 bind 同一挂载点会互相覆盖,只有最后一次可见——不要那样做)
do_overlay_dir() {  # <目标目录> <暂存目录> <本地新增文件目录...>
  TGT_DIR="$1"; OVL="$2"; shift 2
  mkdir -p "$OVL"
  # 1) 系统现有文件先入 staging(仅首次,防重复回拷)
  if [ ! -f "$OVL/.seeded" ] && [ -d "$TGT_DIR" ]; then
    cp "$TGT_DIR"/* "$OVL/" 2>>"$LOG"
  fi
  # 2) 放入我们的文件(可多个来源目录,后者同名覆盖前者)
  for d in "$@"; do
    cp -f "$d"/* "$OVL/" 2>>"$LOG"
  done
  touch "$OVL/.seeded"
  # SELinux:tmpfs 文件须为 system_file 标签,否则 system_server 读取被拒
  chcon -R u:object_r:system_file:s0 "$OVL" 2>>"$LOG"
  if ! grep -q " $TGT_DIR " /proc/mounts; then
    mount --bind "$OVL" "$TGT_DIR" 2>>"$LOG" || { log "bind mount $TGT_DIR failed"; return 1; }
    log "bind-mounted $OVL -> $TGT_DIR"
  else
    log "$TGT_DIR already mounted; staged content refreshed (device re-plug to re-read)"
  fi
}

do_mounts() {
  SCALE=$(json rumble_scale 1.0)
  ABXY=$(json abxy nintendo)
  log "config: rumble_scale=$SCALE abxy=$ABXY"
  # 按 config 选内容;文件名固定为主名(InputReader 只匹配 Vendor_VVVV_Product_PPPP.kl)
  KL_SRC="$MODDIR/kl/Vendor_057e_Product_2008.kl"
  [ "$ABXY" = "xbox" ] && KL_SRC="$MODDIR/kl/Vendor_057e_Product_2008_swap.kl"
  mkdir -p /system/usr/keylayout /system/usr/idc "$MODDIR/kl_all" 2>>"$LOG"
  cp -f "$KL_SRC" "$MODDIR/kl_all/Vendor_057e_Product_2008.kl"
  do_overlay_dir /system/usr/keylayout /dev/.joycond-kl "$MODDIR/kl_all"
  do_overlay_dir /system/usr/idc       /dev/.joycond-idc "$MODDIR/idc"
}

if [ "$MODE" = "remount" ]; then
  wait_boot
  do_mounts
  exit 0
fi

# ---- boot 模式 ----
wait_boot
log "=== service.sh start (moddir=$MODDIR) ==="
place_bins
do_mounts

# ---- 守护循环(崩溃重启+退避;pkill 后自动按新配置拉起) ----
N=0
while true; do
  if [ -x "$BIN/joycond" ]; then
    SCALE=$(json rumble_scale 1.0)
    "$BIN/joycond" --rumble-scale "$SCALE" >> "$LOG" 2>&1
    RC=$?
    N=$((N+1))
    log "joycond exited rc=$RC (restart #$N)"
    [ $((N % 10)) -eq 0 ] && { log "backoff 60s"; sleep 60; }
  else
    log "binary missing, waiting"; sleep 30; continue
  fi
  sleep 5
done
