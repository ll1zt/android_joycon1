# 踩坑全记录 —— 每个坑的现象、误判、根因与解法

[English](TROUBLESHOOTING.md)

每条按「现象 → 误判 → 根因 → 解法」组织。全部在 Pixel 6 / Android 16 / GKI 6.1 /
KernelSU Next 3.3 上真实踩过。

## 1. KernelSU Next ≥ 3.3 不再做模块 magic mount

- **现象**:模块安装成功、`service.sh` 正常运行,但模块 `system/` 下的内容没有
  出现在 `/system` 或 `/vendor`;ksud 日志有
  `Module { command: Metamodule } → Error: Unsupported`。
- **误判**:怀疑模块目录结构不对,或有 `skip_mount` 标记。
- **根因**:KernelSU Next 把挂载职责移到了可选的 **metamodule** 组件。没装它时,
  模块会被解压、脚本会被执行,但**永远不会被挂载**。
- **解法**:不依赖 magic mount,`service.sh` 自己完成文件放置:
  - 守护进程二进制 → 拷到 `/dev` tmpfs 执行(见坑 2);
  - keylayout/idc → 先把系统原有文件拷进 tmpfs 暂存目录、放入我们的文件,再
    `mount --bind` 覆盖 `/system/usr/keylayout` 与 `/system/usr/idc`
    (幂等:先查 `/proc/mounts`)。

## 2. 守护进程不能从 `/data` 直接执行

- **现象**:`exec ./joycond: No such file or directory`(ENOENT 而非 EACCES!),
  而同一个二进制从 `/dev` 执行完全正常。
- **根因**:这个误导性的 ENOENT 来自该设备 f2fs `/data` 挂载的 exec 路径;
  `/dev`(tmpfs)执行同一文件没问题。
- **解法**:service.sh 启动时把二进制拷到 `/dev/.joycond-bin/` 再执行。每次开机
  重新拷贝,tmpfs 的易失性无所谓。

## 3. SELinux 无声无息地干掉了全部 keylayout/idc 加载

- **现象**:合成设备在、evdev 事件流畅(`getevent` 一切正常),但 `dumpsys input`
  的 `Sources` 没有 `GAMEPAD`、轴叫 `GENERIC_1..8` 而不是 `AXIS_X/Y/...`,
  游戏完全看不到手柄。
- **误判**:先怀疑 uinput 的 BUS_VIRTUAL(0x06) 总线或 kl 文件命名不匹配;又因为
  之前 dmesg 里的 denied 全是 `permissive=1`,以为 SELinux 是全局 permissive。
- **根因**:overlay 文件从 `/dev` tmpfs 继承了 `u:object_r:device:s0` 标签,而
  `system_server` 是 **enforcing** 的(之前看到的 permissive=1 是某个自有域的),
  它无权读 `device:s0`。`EventHub` 探测**每一个**候选文件都失败——连
  `Generic.kl` 兜底都失败——所以轴标签完全没建立:
  `Couldn't find a system-provided input device configuration file ... error 13`。
- **解法**:挂载前 `chcon u:object_r:system_file:s0`。
- **教训**:`dumpsys input` + `logcat | grep -i eventhub` 是确认框架实际加载了
  哪些配置文件的最快手段。

## 4. GKI 只给了 `CONFIG_HID_NINTENDO=y`,`# CONFIG_NINTENDO_FF is not set`

- **现象**:合成设备上 `EVIOCSFF` 成功、joycond 把效果转发给两只手柄、
  `write(EV_FF)` 成功——手柄就是不震。
- **根因**:驱动对外暴露 FF 接口与配置无关,但所有真正发送震动的代码路径
  (`joycon_parse_report` → `rumble_worker`)被 `IS_ENABLED(CONFIG_NINTENDO_FF)`
  编译裁剪了。重编 GKI 内核代价太大;改为**直接经 hidraw 驱动震动**。
- **解法**:本仓库的 joycond 补丁在合成 uinput 设备上截获 FF upload/play,
  直接向两只手柄的 hidraw 写 BT OUTPUT `0x10` 报告:
  `[0x10][pkt_num 0x0-0xF][左 4 字节][右 4 字节]`,每 4 字节频段为
  `[HF 频率][HF 幅度][LF 频率][LF 幅度]`。LF 幅度钳制在协议安全上限 `0x72`;
  FF_RUMBLE 的 `strong_magnitude` 映射到 LF 频带、`weak_magnitude` 映射到 HF
  频带。60Hz 流式 + 双频带独立幅度/频率控制全部可用(见 `hd-test`)——能力上限
  反而超过了内核 FF 路径(普通双马达震动)。

## 5. Joy-Con 休眠/重连会打乱所有节点号

- **现象**:测试中途手柄息睡;唤醒后 evdev 节点漂移(`event4→event5...`),
  hidraw 节点消失,HID 实例号递增(`.0001→.0003`)。
- **根因**:Joy-Con 约 5 分钟无操作自动休眠;重连时 HID 设备被重新探测注册。
- **解法**:无需修复——上游 joycond 按 MAC(`/sys/.../uniq`)跟踪手柄,重连后
  能正确接管。但任何写死节点号的脚本/测试都会失效;始终用 `getevent -p` 或
  设备名重新解析节点。

## 6. 无线 adb 长会话掉线

- **现象**:中途 `adb: error: connect failed: closed` / `cannot stat`。
- **解法**:重新 `adb connect 192.168.x.x:5555`;大文件推送建议用 USB。

## 预检清单(参考机上 10 项全绿)

完整清单见 [precheck/RESULTS.md](../precheck/RESULTS.md):内核配置
(`CONFIG_HID_NINTENDO=y`)、root 域、`/dev/uinput` 与 hidraw、驱动绑定、校准、
按键/摇杆事件、IMU 流式、电池节点、InputReader 消费、以及
`CONFIG_NINTENDO_FF` 缺失的确认。
