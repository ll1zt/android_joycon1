#!/system/bin/sh
### joycond KernelSU 启动脚本(late_start,root/ksu 域)
### 用法:
###   service.sh           开机入口:放置文件 + 守护循环
###   service.sh remount   WebUI 调用:按 config.json 重选 kl 并重新放置(不动守护)
###                        (历史名:语义已变为重拷文件,不涉及任何 mount)
###
### keylayout/idc 的安放方式:直接写入 /data/system/devices/{keylayout,idc} ——
### AOSP EventHub 搜索链的末位(odm -> vendor -> system -> data)。相比 bind mount:
###   - 不依赖 magic mount / metamodule(KernelSU Next >= 3.3 两者都没有)
###   - SELinux 标签自动继承 system_data_file,enforcing 下 system_server 可读
###   - 失败语义安全:文件缺失 = EventHub 回退 Generic.kl,不存在"空 overlay
###     遮蔽系统全部 keylayout"的故障模式
### (2026-09-06 Pixel 6 / Android 16 两阶段对照实测:dumpsys 的 KeyLayoutFile /
###  ConfigurationFile 两个文件均确认从 /data 路径加载,见 HANDOFF.md)
### 平台坑只剩一个:/data 不可 exec,二进制先暂存 /dev tmpfs 再跑。

MODDIR=${0%/*}
LOG=/data/adb/joycond.log
BIN=/dev/.joycond-bin
CFG=/data/adb/modules/joycond/config.json
KLD=/data/system/devices/keylayout
IDCD=/data/system/devices/idc
MODE="${1:-boot}"

log() { echo "[service.sh] $(date '+%m-%d %H:%M:%S') $1" >> "$LOG"; }

trim_log() {  # 无界增长的日志会把历史残留混进验收判定,超 512K 截尾留 256K
  SIZE=$(wc -c < "$LOG" 2>/dev/null)
  case "$SIZE" in ''|*[!0-9]*) return;; esac
  if [ "$SIZE" -gt 524288 ]; then
    tail -c 262144 "$LOG" > "$LOG.tmp" \
      && echo "[service.sh] $(date '+%m-%d %H:%M:%S') log truncated ($SIZE -> 256K)" >> "$LOG.tmp" \
      && mv "$LOG.tmp" "$LOG"
  fi
}

json() {  # json <key> <default> — 极简 JSON 提取(toybox sed 兼容)
  v=$(sed -n "s/.*\"$1\" *: *\"\{0,1\}\([^,\"]*\)\"\{0,1\}.*/\1/p" "$CFG" 2>/dev/null | head -1)
  [ -n "$v" ] && echo "$v" || echo "$2"
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

# keylayout/idc 放进 EventHub 搜索链末位;宁缺毋滥——拷贝失败宁可让
# EventHub 回退 Generic.kl,也不能留下半套配置污染判定
place_cfg_files() {
  SCALE=$(json rumble_scale 1.0)
  ABXY=$(json abxy nintendo)
  ENVELOPE=$(json envelope 1)
  log "config: rumble_scale=$SCALE abxy=$ABXY envelope=$ENVELOPE"
  # 文件名固定为主名(InputReader 只匹配 Vendor_VVVV_Product_PPPP.kl)
  KL_SRC="$MODDIR/kl/Vendor_057e_Product_2008.kl"
  [ "$ABXY" = "xbox" ] && KL_SRC="$MODDIR/kl/Vendor_057e_Product_2008_swap.kl"
  mkdir -p "$KLD" "$IDCD" 2>>"$LOG" || { log "mkdir $KLD/$IDCD failed"; return 1; }
  chmod 755 "$KLD" "$IDCD" 2>>"$LOG"
  cp -f "$KL_SRC" "$KLD/Vendor_057e_Product_2008.kl" 2>>"$LOG" || { log "copy keylayout failed"; return 1; }
  for f in 2006 2007 2008; do
    cp -f "$MODDIR/idc/Vendor_057e_Product_$f.idc" "$IDCD/" 2>>"$LOG" || { log "copy idc $f failed"; return 1; }
  done
  # 只碰自有文件:目录可能被其他组件共享,整目录 chmod/chcon 会误伤,
  # 且 chmod 644 落在子目录上会剥掉 x 位
  for f in "$KLD/Vendor_057e_Product_2008.kl" \
           "$IDCD/Vendor_057e_Product_2006.idc" \
           "$IDCD/Vendor_057e_Product_2007.idc" \
           "$IDCD/Vendor_057e_Product_2008.idc"; do
    chmod 644 "$f" 2>>"$LOG"
    chcon u:object_r:system_data_file:s0 "$f" 2>>"$LOG"
  done
  log "keylayout/idc placed in $KLD $IDCD"
}

if [ "$MODE" = "remount" ]; then
  wait_boot
  place_cfg_files
  exit 0
fi

# ---- boot 模式 ----
wait_boot
trim_log
log "=== service.sh start (moddir=$MODDIR) ==="
place_bins
place_cfg_files

# ---- 守护循环(崩溃重启+退避;模块被禁用/移除即退出,不做孤儿) ----
N=0
while true; do
  # KernelSU 禁用/移除模块时在模块目录置标记文件,此刻循环必须停止,
  # 否则 joycond 被无限重生
  if [ -e "$MODDIR/disable" ] || [ -e "$MODDIR/remove" ]; then
    log "module disabled/removed; supervisor exit"
    break
  fi
  if [ -x "$BIN/joycond" ]; then
    SCALE=$(json rumble_scale 1.0)
    ENVELOPE=$(json envelope 1)
    START=$(date +%s)
    "$BIN/joycond" --rumble-scale "$SCALE" --envelope "$ENVELOPE" >> "$LOG" 2>&1
    RC=$?
    # 单次运行超过 60s 视为干净退出(手柄全断开/WebUI pkill),退避只针对崩溃循环。
    # 注意:清零分支不能落到下面的取模检查——N=0 时 N%%10==0 恒真,每次干净退出
    # 都会误触发 60s backoff(v1.1.1 引入,2026-09-06 真机抓到)
    if [ $(( $(date +%s) - START )) -ge 60 ]; then
        N=0
        log "joycond exited rc=$RC (clean run >= 60s; counter reset)"
    else
        N=$((N+1))
        log "joycond exited rc=$RC (restart #$N)"
        [ $((N % 10)) -eq 0 ] && { log "backoff 60s"; sleep 60; }
    fi
  else
    log "binary missing, waiting"; sleep 30; continue
  fi
  sleep 5
done
