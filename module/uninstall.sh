#!/system/bin/sh
# KernelSU 卸载钩子:清除写入 /data/system/devices 的 keylayout/idc。
# bind mount 方案重启后挂载自然消失;/data 文件持久,必须显式清理。
# 只删本模块的文件,目录里可能有其他内容;空目录才移除。
rm -f /data/system/devices/keylayout/Vendor_057e_Product_2008.kl
rm -f /data/system/devices/idc/Vendor_057e_Product_2006.idc \
      /data/system/devices/idc/Vendor_057e_Product_2007.idc \
      /data/system/devices/idc/Vendor_057e_Product_2008.idc
rmdir /data/system/devices/keylayout /data/system/devices/idc /data/system/devices 2>/dev/null
exit 0
