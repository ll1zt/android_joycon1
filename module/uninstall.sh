#!/system/bin/sh
# KernelSU 卸载钩子:停止守护进程并清除写入 /data/system/devices 的 keylayout/idc。
# bind mount 方案重启后挂载自然消失;/data 文件持久,必须显式清理。
#
# 先兜一发停震再杀 joycond:被 kill 的 joycond 发不出中性包,
# 正在震的手柄会一直震(TODO P1「joycond 被 kill 时震动残留」的卸载路径缓解)。
/dev/.joycond-bin/ff-test 10 0 0 2>/dev/null
pkill joycond 2>/dev/null
pkill -x hd-test 2>/dev/null
# 只删本模块的文件,目录里可能有其他内容;空目录才移除。
rm -f /data/system/devices/keylayout/Vendor_057e_Product_2008.kl
rm -f /data/system/devices/idc/Vendor_057e_Product_2006.idc \
      /data/system/devices/idc/Vendor_057e_Product_2007.idc \
      /data/system/devices/idc/Vendor_057e_Product_2008.idc
rmdir /data/system/devices/keylayout /data/system/devices/idc /data/system/devices 2>/dev/null
exit 0
