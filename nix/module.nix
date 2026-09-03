{
  lib,
  runCommand,
  zip,
  joycond,
  ff-test,
  hd-test,
  moduleSrc,
}:
runCommand "joycond-kernelsu-module"
  {
    meta.description = "KernelSU 模块:joycond 守护进程 + keylayout/idc 自挂载(service.sh)";
  }
  ''
    mkdir -p work/bin work/kl work/idc
    mkdir -p work/webroot

    # 守护进程:service.sh 启动时拷到 /dev tmpfs 执行
    # (不依赖 KSU metamodule 的 magic mount;实测该机型 /data exec 失败而 /dev 可行)
    install -m755 ${joycond}/bin/joycond work/bin/joycond
    # WebUI(Plugin config) + ff-test/hd-test 测试工具
    install -m644 ${moduleSrc}/webroot/index.html work/webroot/index.html
    install -m644 ${moduleSrc}/config.json work/config.json
    install -m755 ${ff-test}/bin/ff-test work/bin/ff-test
    install -m755 ${hd-test}/bin/hd-test work/bin/hd-test

    # 模块元数据与启动脚本
    install -m644 ${moduleSrc}/module.prop   work/module.prop
    install -m755 ${moduleSrc}/service.sh    work/service.sh
    install -m644 ${moduleSrc}/sepolicy.rule work/sepolicy.rule

    # 键位映射(0x2008 合成设备)+ 设备配置
    # (单只 2006/2007 用 device.disabled 从框架禁用,游戏只见合成设备)
    install -m644 ${moduleSrc}/keylayout/Vendor_057e_Product_2008.kl work/kl/
    install -m644 ${moduleSrc}/keylayout/Vendor_057e_Product_2008_swap.kl work/kl/
    install -m644 ${moduleSrc}/idc/Vendor_057e_Product_2006.idc work/idc/
    install -m644 ${moduleSrc}/idc/Vendor_057e_Product_2007.idc work/idc/
    install -m644 ${moduleSrc}/idc/Vendor_057e_Product_2008.idc work/idc/

    cd work
    # $out 已被预创建为目录,先打包再 mv 覆盖
    ${zip}/bin/zip -qrX module.zip .
    mv module.zip $out
  ''
