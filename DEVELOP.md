# TWRP 在模拟器 / QEMU 上运行的排障记录

## 背景

目标原本是：让 TWRP Recovery 在 Android AVD（ranchu 模拟器）里正常显示 UI。

在排查过程中，目标逐步收敛为两条线：

1. 解释为什么 ranchu / emulator 这条线很难直接显示 TWRP
2. 把可运行、可显示、可 ADB 的主线稳定在裸 QEMU 上

当前主线已经不是“继续硬啃 emulator 出图”，而是：

```text
qemu-system-aarch64
    + android-33 kernel-ranchu
    + android-33 对应模块
    + virtio-gpu-pci
    + TWRP recovery ramdisk
```

---

## 环境

| 项目 | 内容 |
| --- | --- |
| TWRP 源码（Mac） | `/Volumes/android_source/twrp_a16_compile/bootable/recovery/` |
| TWRP 源码（Linux） | `laurie@192.168.31.206:~/twrp/bootable/recovery/` |
| 编译目标 | `emu64a`（Google AVD 64-bit ARM） |
| magiskboot | `/Volumes/android_source/rom/magiskboot` |
| ramdisk（工作版） | `/Volumes/android_source/ramdisk-recovery.cpio` |
| ramdisk（备份） | `/Volumes/android_source/ramdisk-recovery-orig.cpio` |
| ramdisk（emulator 用） | `/Volumes/android_source/ramdisk-recovery.img` |
| android-33 SDK ramdisk（原始） | `~/Library/Android/sdk/system-images/android-33/default/arm64-v8a/ramdisk.img` |
| android-33 解包目录 | `/Volumes/android_source/work/sdk_a33/` |
| android-35 解包目录 | `/Volumes/android_source/work/sdk_a35/` |
| android-36 解包目录 | `/Volumes/android_source/work/sdk_a36/` |
| 模拟器配置 | Medium_Phone_6（android-33, Linux 5.15.41） |

---

## 问题 01：怎样拿到 recovery 的有效日志？

### 现象

最早阶段里，TWRP 崩溃，但几乎没有可用输出，无法知道卡在哪一步。

### 尝试过的方法

1. 让 recovery 的标准输出尽量进内核日志
2. 用 `-show-kernel` 观察启动阶段输出
3. 直接把 `TMP_LOG_FILE` 指到 `/dev/kmsg`

### 结果

把 `TMP_LOG_FILE` 直接改成 `/dev/kmsg` 最终失败。

原因不是权限，而是：

```text
freopen("/dev/kmsg", "a", stdout)
```

对字符设备不成立，`stdout/stderr` 会变坏，后续日志反而丢失。

### 最终可用方案

保留：

```text
TMP_LOG_FILE = /tmp/recovery.log
```

再通过辅助服务把日志从 `/tmp/recovery.log` 逐行转储到 `/dev/kmsg`。

### 结论

这个问题的结论是：

1. 直接把 recovery 日志文件指向 `/dev/kmsg` 不可靠
2. 最稳妥的办法是先写普通文件，再转储到内核日志

---

## 问题 02：为什么 TWRP 启动后会立刻 SIGSEGV？

### 现象

TWRP 启动后立刻崩溃。

### 直接原因

`gr_draw == NULL`，随后触发 SIGSEGV。

### 对应代码路径

`gr_init()` 依次尝试三个后端：

```cpp
gr_backend = open_overlay();
gr_backend = open_drm();
gr_backend = open_fbdev();
```

三条路径都失败时，最终就会落到空指针。

### 关键观察

最早阶段在 recovery / emulator 组合里能看到：

```text
open_drm() 枚举 /dev/dri/card0..63 全部 ENOENT
open_fbdev() 打开 /dev/graphics/fb0 失败
```

### 结论

这里不要把“崩溃”单独当作主问题，它只是显示初始化失败后的结果。

真正需要继续拆开的子问题是：

1. 为什么没有可用的 DRM 设备
2. 为什么 framebuffer 也不存在
3. 即便出现 `/dev/dri/card0`，为什么 emulator 里仍然可能黑屏

---

## 问题 03：ranchu / emulator 能否靠 virtio-gpu 直接让 TWRP 出图？

### 最初假设

如果在 recovery 里加载 `virtio-gpu.ko`，让 `/dev/dri/card0` 出现，那么 TWRP 的 DRM 后端就应该可以工作。

### 做过的验证

#### 3.1 尝试在 emulator 路线直接加载 virtio-gpu

做法：

1. 把 `virtio-gpu.ko` 注入 ramdisk
2. 在 `init.recovery.ranchu.rc` 的 `on early-init` 中手动 `insmod`

遇到过的直接问题：

| 问题 | 原因 | 处理 |
|---|---|---|
| `virtio_dma_buf` 符号未解析 | 缺少依赖模块 | 增加 `virtio_dma_buf.ko` |
| 模块能加载但没有 `/dev/dri/card0` | emulator 没有目标 PCI 设备 | 无法靠补模块解决 |
| `insmod` 太晚 | coldboot 已结束 | 改到 `early-init` |

#### 3.2 尝试 `-qemu -vga virtio`

结果是 ranchu 自带的 QEMU 不支持这个 VGA 选项，路线走不通。

#### 3.3 扫描不同 Android 版本镜像

结论很重要：

1. android-33 还能提供完整的 `virtio-gpu` 依赖链
2. android-35 / 36 已经没有 `virtio-gpu.ko`

这说明即使继续折腾，能用的内核/模块基础也只能落在 android-33 上。

#### 3.4 回到 stock emulator 看显示链到底是什么

在正常系统里虽然能看到 `/dev/dri/card0`，但它实际对应的是：

```text
MODALIAS=platform:vkms
```

也就是 `vkms`，它只是虚拟 DRM 设备，不直接把帧送到 emulator 窗口。

进一步核实后，stock emulator 的可见画面实际走的是：

```text
app / SurfaceFlinger
    -> gralloc + hwcomposer
    -> goldfish_pipe / goldfish_address_space / goldfish_sync
    -> host emulator window
```

而 TWRP 走的是：

```text
minui
    -> overlay / drm / fbdev
```

### 关键结论

emulator 这条线的主要问题不是“缺一个模块”这么简单，而是显示链不匹配：

1. `vkms` 只会提供虚拟 DRM 设备，不会把帧显示到 emulator 窗口
2. ranchu 新版内核已经没有 `goldfish_fb`
3. TWRP 本身又不走 goldfish 的 userspace 图形栈

### 进一步对照验证

后续又做过两类对照：

1. 对比 `-gpu swiftshader_indirect` / `-gpu host` / `-gpu guest`
2. 移除 `goldfish_address_space` / `goldfish_pipe` / `goldfish_sync`

结果都没有改变 emulator 侧的核心失败特征：

```text
Atomic commit failed ret=-22
Legacy drmModeSetCrtc failed ret=-22
```

### 本问题最终结论

如果问题是“在 ranchu / emulator 窗口里直接显示 TWRP UI 是否值得继续作为主线”，当前结论是否定的。

不是完全理论不可能，而是工程投入产出比很差。要继续走，基本只剩两条代价高的路：

1. 给 TWRP 新增 goldfish 显示后端
2. 在 recovery 里额外拉起完整的图形 userspace 栈

---

## 问题 04：为什么最终切到裸 QEMU？

### 决策前提

emulator 线路已经证明：

1. 显示链不匹配
2. 继续投入需要改大量专用逻辑
3. 同时 android-35 / 36 还缺失关键 virtio-gpu 模块

### 裸 QEMU 的优势

在裸 QEMU 的 `virt` 机器上：

1. 有真实 PCI 总线
2. 有 `virtio-gpu-pci`
3. android-33 的 `virtio-gpu.ko` 能正常绑定
4. TWRP 现有 DRM 路径可以直接复用

### 结论

最终主线切到：

```text
qemu-system-aarch64 + virtio-gpu-pci
```

这是当前唯一已经验证“能真正出画面”的路线。

---

## 问题 05：裸 QEMU 的显示链是怎么一步步打通的？

### 5.1 第一层：补齐 virtio-gpu 依赖链

最开始只加载 `virtio-gpu.ko`，会依次缺少：

1. `virtio_dma_buf.ko`
2. `virtio_pci_modern_dev.ko`
3. `virtio_pci.ko`

最终可用顺序是：

```text
virtio_dma_buf.ko
virtio_pci_modern_dev.ko
virtio_pci.ko
virtio-gpu.ko
```

### 5.2 第二层：让 connector 变成 connected

即使 `/dev/dri/card0` 出现，QEMU 默认也可能没有有效 connector。

修正方式是给 QEMU 增加：

```text
-device virtio-gpu-pci,edid=on,xres=1080,yres=1920
```

这一步解决的是 `connector disconnected`。

### 5.3 第三层：修正 plane 数检查

virtio-gpu 只有 1 个 plane，但原代码按 `DEFAULT_NUM_LMS=2` 检查，会过早返回 NULL。

因此改动了两点：

1. `count_planes == 0` 才算失败
2. `number_of_lms` 不能超过实际 plane 数

### 5.4 第四层：给 atomic commit 加 legacy fallback

virtio-gpu 上 atomic commit 会返回 `-22`，原逻辑没有回退。

补上 `drmModeSetCrtc` fallback 后，QEMU 路线才真正出画面。

### 5.5 第五层：颜色问题

出现过红蓝互换，最后确认是像素格式不对。

修正为：

```text
TARGET_RECOVERY_PIXEL_FORMAT := BGRA_8888
```

### 本问题结论

QEMU 出图并不是“加一个模块就好了”，而是至少同时满足：

1. 内核和模块版本匹配
2. `virtio-gpu` 依赖链完整
3. QEMU connector 可用
4. TWRP DRM 代码能接受单 plane 设备
5. atomic 失败后能回退到 legacy modeset

---

## 问题 06：QEMU 下输入为什么异常，后来怎么修？

### 问题 06-1：鼠标悬停会触发幽灵点击

#### 现象

鼠标只是在窗口里移动，不按键，TWRP 也会收到触摸按下。

#### 原因

`usb-tablet` 走的是 `EV_ABS`，而旧逻辑没有正确跟踪 `BTN_LEFT` 状态，导致悬停坐标也被当成 touch-down。

#### 修复

在事件处理逻辑里：

1. 显式跟踪 `BTN_LEFT` 按下/释放状态
2. 非多点设备且 `BTN_LEFT` 未按下时，丢弃悬停事件

### 问题 06-2：鼠标不移动时点击无效

#### 现象

不移动鼠标，直接点，TWRP 没反应。

#### 原因

之前一次 `SYN_REPORT` 后同步位已经清零；如果 QEMU 没再发 ABS 坐标，下一次点击时没有有效坐标被重新激活。

#### 修复

在 `BTN_LEFT` 按下时重新 arm 缓存坐标：

```cpp
e->p.synced = 0x03;
```

### 问题 06-3：Cocoa 窗口吞鼠标

这不是 TWRP 输入逻辑问题，而是 macOS Cocoa 显示后端行为。

处理方式：

1. 临时按 `Ctrl+Alt+G` 释放鼠标
2. macOS 使用 `-display cocoa,show-cursor=on`；Linux 使用
   `-display gtk,full-screen=off,show-menubar=off,show-cursor=on,zoom-to-fit=on`

### 本问题结论

QEMU 下输入问题已经基本收敛，关键是：

1. 使用 `usb-tablet`
2. 事件层正确处理 `EV_ABS + BTN_LEFT`
3. Cocoa 显示后端开启 `show-cursor=on`

---

## 问题 07：health HAL 的 VINTF 报错是怎么回事？

### 现象

recovery 日志反复出现：

```text
Could not find android.hardware.health.IHealth/default in the VINTF manifest.
No alternative instances declared in VINTF.
```

### 已核实事实

当前设备树最终没有继续依赖 health HAL 这条链来读电池信息，而是改成了 TWRP 的 legacy battery 路线。

### 原因

TWRP 在这里其实有两条电池读取路径：

1. 默认路径：调用 `GetBatteryInfo()`，走 AIDL/HIDL health 服务
2. legacy 路径：直接读 sysfs 下的 `capacity` 和 `status`

其中 recovery 代码里：

1. 定义 `TW_CUSTOM_BATTERY_PATH` 后，会强制打开 `TW_USE_LEGACY_BATTERY_SERVICES`
2. 启动后不再走 `GetBatteryInfo()`
3. 而是直接读取：

```text
/sys/class/power_supply/battery/capacity
/sys/class/power_supply/battery/status
```

之前看到的 VINTF 报错，来自默认 health 路径中的这段探测逻辑：

1. 先查 AIDL health
2. 找不到再回退到 HIDL health 2.1

这就导致每次都会先打一轮没意义的 VINTF 报错。

### 实际修复

真正落地的修法不是去改 health HAL 探测顺序，而是在设备树里定义：

```makefile
TW_CUSTOM_BATTERY_PATH := /sys/class/power_supply/battery
```

同时配合：

```makefile
TW_USE_LEGACY_BATTERY_SERVICES := true
```

这样 TWRP 就会直接走 legacy battery 逻辑，从 sysfs 读取电量和充电状态，不再依赖 health HAL。

也就是说，真正把这个问题绕开的链路是：

```text
定义 TW_CUSTOM_BATTERY_PATH
    -> 自动启用 legacy battery services
    -> 直接读取 /sys/class/power_supply/battery/*
    -> 不再把 health HAL 当作电池信息来源
```

### 为什么这样能解决

因为当前这个 QEMU 目标并不需要一条完整、干净的 health HAL 电池链路；只要 recovery 能从 sysfs 拿到：

1. `capacity`
2. `status`

UI 上的电量显示和充电状态就足够工作。

### 实际结论

这个问题后来真正采用的修法，是在设备树里定义 `TW_CUSTOM_BATTERY_PATH`，把电池读取切到 legacy sysfs 路径，而不是继续在 health HAL 探测顺序上做文章。

### 结论

这个问题不是 emulator 专有故障，但对当前 emu64a / QEMU 目标来说，最直接有效的解法就是绕开 health HAL，改用 `TW_CUSTOM_BATTERY_PATH` 指向 sysfs 电池节点。

---

## 问题 08：QEMU 下 ADB 为什么一度是 offline？

### 现象

宿主机可以连到 QEMU 转发端口，但 ADB 仍然表现为：

```text
failed to connect
device offline
```

### 一开始排查过的怀疑点

1. `adbd` 没启动
2. `service.adb.tcp.port=5555` 没生效
3. recovery 缺少 system/vendor 挂载
4. QEMU 不支持 recovery 里的 TCP ADB

这些后来都被逐一排除了。

### 最关键的验证结果

#### 8.1 `adbd` 其实已经启动并监听 `tcp:5555`

通过包装日志可以确认：

```text
adbd listening on tcp:5555
adbd started
```

#### 8.2 真正异常的是 guest 网络没配起来

当时 guest 里：

1. `eth0` 存在
2. 但没有 `10.0.2.15`
3. 默认路由也不存在

### 根因

`hostfwd=tcp::5556-:5555` 依赖的是 guest 网络栈里的目标地址，不是直接把数据塞给某个进程。

所以需要同时满足：

1. guest `eth0` 已配置
2. guest 地址是 `10.0.2.15/24`
3. 默认路由指向 `10.0.2.2`
4. guest 里 `adbd` 正在监听 `5555`

当时只满足了第 4 条，所以宿主机表现为 `offline`。

### 修复

在启动 adbd 前先配置网络：

```sh
ifconfig lo 127.0.0.1 up
ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up
toybox route add default gw 10.0.2.2 dev eth0
```

### 修复后结果

最终验证：

```text
adb connect 127.0.0.1:5556  -> connected
adb get-state                -> recovery
```

### 8.3 重新编译后出现过一次回归

后面切回重新编译产物后，QEMU ADB 又重新出现过一轮异常。

这次不是最早那种单纯的“eth0 没配置”一个问题，而是两个条件同时退化：

1. `sys.usb.config` 实际落到了 `mtp,adb`
2. `eth0` 虽然存在，但没有拿到 `10.0.2.15`

通过串口控制台直接检查到：

```text
getprop service.adb.tcp.port -> 5555
getprop sys.usb.config       -> mtp,adb
getprop init.svc.adbd        -> stopped / restarting
ifconfig eth0                -> 有 virtio_net，但没有 inet addr
```

继续做最小化验证后可以确认：

1. 手动 `setprop sys.usb.config adb` 后，`init` 会重新创建 `/dev/socket/adbd`，`adbd` 能进入 `running`
2. 当前 recovery 里没有可用的 `toybox route` / `ip route`
3. 用 shell 身份手动 `ifconfig eth0 10.0.2.15 ...` 会报 `Operation not permitted`

这说明重编译后的回归链条是：

```text
sys.usb.config 被切到 mtp,adb
    -> adbd 没稳定进入 TCP ADB 所需状态

eth0 地址配置没有真正成功
    -> hostfwd 仍然没有可达目标
```

### 8.4 `sys.usb.config` 为什么会变成 `mtp,adb`

这不是当前设备树 rc 主动写进去的，而是 TWRP 自己的 MTP 启动逻辑在 recovery 启动阶段改的。

已经确认的链路是：

1. 编译时启用了 `TW_HAS_MTP`
2. TWRP 启动时把 `tw_mtp_enabled` 默认值设成 `1`
3. recovery 主流程启动后，如果检测到 MTP 默认开启，就会调用 `Enable_MTP()`
4. `Enable_MTP()` 会主动执行：

```text
property_set("sys.usb.config", "none")
property_set("sys.usb.config", "mtp,adb")
```

因此，这次 `sys.usb.config` 退化成 `mtp,adb` 的真正原因不是 init 规则顺序问题，而是：

```text
TWRP 启动后自动启用了 MTP，随后把 USB 功能切到了 mtp,adb。
```

对于当前这个 QEMU 目标，这条默认行为会和 TCP ADB 的稳定启动链打架，所以设备树里需要把它强制拉回纯 `adb`。

### 8.5 回归修复

最终修复没有再依赖临时 wrapper 脚本，而是直接收敛回设备树 rc：

1. 在 `on fs` 中先设置 `sys.usb.config adb`
2. 增加 `on property:sys.usb.config=mtp,adb`，强制拉回 `adb`
3. 在 `on property:sys.usb.config=adb` 中，用

```text
exec u:r:su:s0 root root -- /system/bin/sh -c "ifconfig lo ...; ifconfig eth0 10.0.2.15 ..."
```

由 `init` 以 root 身份完成网卡配置

### 8.6 回归修复后的结果

修复后再次验证：

```text
adb connect 127.0.0.1:5556 -> connected
adb -s 127.0.0.1:5556 get-state -> recovery
```

### 本问题结论

QEMU 下 ADB offline 的根因并不只有一种，但当前已经确认过两类关键失败模式：

1. guest `eth0` 没按 QEMU user-net 预期完成配置
2. 重编译产物里 `sys.usb.config` 退化到 `mtp,adb`，导致 adbd 状态异常

最终稳定方案是：

1. 强制 recovery 保持 `sys.usb.config=adb`
2. 在 `sys.usb.config=adb` 触发时，由 `init` 以 root 身份配置 `eth0=10.0.2.15`

---

## 问题 10：可交互串口怎么用？

### 现象

当 ADB 自己就挂掉、`offline`、或者 TCP 端口还没真正可用时，单靠宿主机上的 `adb connect` 很难知道 guest 里到底发生了什么。

### 方法

把 QEMU 串口直接映射成宿主机上的一个 TCP 端口，例如：

```text
-serial tcp:127.0.0.1:5557,server,nowait
```

这样以后就可以把这个端口当成 guest 控制台来用。

### 怎么连

最直接的方式是用 `nc` 连过去：

```bash
nc 127.0.0.1 5557
```

连上以后，如果 QEMU 已经启动到 recovery 控制台，你会看到类似：

```text
console:/ $
```

这时候就和串口 shell 一样，直接输入命令再回车即可，例如：

```text
getprop sys.usb.config
getprop init.svc.adbd
ifconfig eth0
ls /dev/socket
cat /tmp/recovery.log
```

如果当前终端想退出，通常直接按 `Ctrl+C` 即可。

### 怎么一次性发命令

如果不想手工进交互式 shell，也可以一次性把几条命令通过标准输入发给串口：

```bash
{
    printf '\r\ngetprop sys.usb.config\r\n'
    printf 'getprop init.svc.adbd\r\n'
    printf 'ifconfig eth0\r\n'
    sleep 2
} | nc 127.0.0.1 5557
```

这里的关键点有两个：

1. 命令之间用 `\r\n` 分隔，模拟回车
2. 末尾保留一个很短的 `sleep`，给 guest 一点时间把输出回传出来

这种方式适合做快速状态采样，不适合长时间交互。

### 能做什么

连上这个串口后，可以直接在 recovery 里执行：

```text
getprop
ifconfig eth0
ls /dev/socket
cat /tmp/recovery.log
```

这条通道不依赖 ADB，所以特别适合排查：

1. adbd 根本没起来
2. adbd 在重启循环
3. 网卡存在但没有地址
4. 某个属性在运行时被别的组件改掉

### 这次排查里它解决了什么

这次就是通过可交互串口，直接确认了：

1. `getprop sys.usb.config -> mtp,adb`
2. `getprop init.svc.adbd -> stopped / restarting`
3. `ifconfig eth0` 有设备，但没有 `inet addr`
4. 手动 `setprop sys.usb.config adb` 后，`adbd` 能重新进入 `running`

如果没有这条串口通道，只看宿主机上的 `adb connect`，只能看到 `failed to connect` 或 `offline`，看不到 guest 内部到底是哪一环出问题。

### 结论

对当前这条 QEMU recovery 路线来说，可交互串口不是可选项，而是 ADB 故障时最可靠的兜底调试手段。

---

## 问题 11：当前有哪些关键修改和运行前提？

### 11.1 当前路线依赖的版本前提

| 项目 | 结论 |
|---|---|
| 可用内核/模块版本 | 仅 android-33 |
| android-35 / 36 | 已确认无 `virtio-gpu.ko` |
| QEMU 显示主线 | `virtio-gpu-pci` |
| 主运行目标 | 裸 QEMU，不再以 emulator 出图为主线 |

### 11.2 关键代码修改汇总

#### `graphics_drm.cpp`

| 位置 | 修改 | 原因 |
|---|---|---|
| `drm_blank()` | atomic 失败后回退 `drmModeSetCrtc` | virtio-gpu 不支持 atomic |
| `update_plane_fb()` | 同上 | 同上 |
| `drm_init()` 枚举 DRM 设备 | 加调试输出 | 便于确认枚举过程 |
| plane 数检查 | 只在 `count_planes == 0` 时失败 | virtio-gpu 只有 1 plane |
| topology 后 LMS 限幅 | `number_of_lms <= count_planes` | 避免默认值过大 |

#### `events.cpp`

| 位置 | 修改 | 原因 |
|---|---|---|
| `BTN_LEFT` 处理 | 跟踪按键状态 | 修复悬停误触 |
| `SYN_REPORT` 处理 | 未按下时丢弃 hover | 修复幽灵点击 |
| `BTN_LEFT` 按下 | `e->p.synced = 0x03` | 修复静止点击无效 |

#### `init.rc`

| service | 修改 |
|---|---|
| recovery | 增加 `stdio_to_kmsg`、`user root` |
| adbd | 增加 `user root` |
| charger | 增加 `user root` |

### 11.3 模块与 ramdisk 相关前提

历史上这里是靠手工注入维持的，当前目标是尽量把这些内容收敛进设备树。

需要特别记住两点：

1. `.ko` 必须和 `kernel-ranchu` 版本严格匹配
2. `recovery/root/...` 是 ramdisk 根目录 overlay，不是普通附属目录

也就是说：

```text
recovery/root/lib/modules/*.ko
```

会进入最终 ramdisk 的：

```text
/lib/modules/*.ko
```

### 11.4 当前状态

| 项目 | 状态 |
| --- | --- |
| virtio-gpu 模块加载 | 已验证 |
| `/dev/dri/card0` 出现 | 已验证 |
| QEMU 下 TWRP UI | 已验证 |
| 颜色问题 | 依赖重新编译后的像素格式修正 |
| 输入问题 | 已修复 |
| ADB 连接 | 已修复 |
