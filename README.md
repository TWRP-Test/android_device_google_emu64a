# twrp_device_google_emu64a

这个设备树目录同时包含两部分信息：

1. `emu64a` 目标的设备树内容
2. 在 macOS 上用裸 QEMU 启动 TWRP recovery 的最小方法

当前主线已经不是 AVD / emulator 出图，而是裸 QEMU：

```text
qemu-system-aarch64
  + android-33 kernel-ranchu
  + ramdisk-recovery.cpio
  + virtio-gpu-pci
  + 当前设备树里的 recovery root overlay
```

## 为什么编写这个设备树？

在编写新的 REC 的过程中，我的设备长期处于 rec 模式，无法接收消息，也无法正常使用

所以需要一个不依赖物理设备的调试环境

而 [android_device_emulator_twrp](https://github.com/TeamWin/android_device_emulator_twrp) 的最后一次更新是在十年前

## Supported targets

当前设备树对应的是 Google `emu64a`，产品名是：

```text
twrp_emu64a
```

构建后的运行目标不是实体手机，而是基于 `goldfish/ranchu` 的 arm64 模拟环境。

## 编译流程

这套设备树更适合放进标准的 TWRP / AOSP 源码树里构建。典型目录应是：

```text
device/google/emu64a
```

如果你是本地在 macOS 改设备树、远端 Linux 编译，当前目录自带的 `sync.sh` 可以把它同步到远端源码树。这个脚本只是个人工作流辅助，不是启动 QEMU 的必要条件。

当前脚本默认同步到：

```text
/home/laurie/twrp/device/google/emu64a/
```

### 1. 准备源码树

下面是一个最小化的初始化流程，重点是把当前设备树放到 `device/google/emu64a`：

```bash
mkdir twrp-work && cd twrp-work
repo init --depth=1 -u https://github.com/TWRP-Test/platform_manifest_twrp_aosp.git -b twrp-16.0
repo sync
mkdir -p device/google
```

然后把这个设备树放进去：

```text
device/google/emu64a
```

如果你已经有自己的源码树路径，直接把本目录内容拷过去即可，不需要照搬这里的远端路径。

### 2. 开始编译

进入源码树后执行：

```bash
source build/envsetup.sh
lunch twrp_emu64a
m recoveryimage
```

### 3. 取回产物

编译完成后，常用产物在：

```text
out/target/product/emu64a/recovery.img
out/target/product/emu64a/ramdisk-recovery.cpio
```

对当前这条 QEMU 启动链来说，真正会被 `launch_qemu.sh` 直接使用的是：

```text
out/target/product/emu64a/ramdisk-recovery.cpio
```

推荐做法是把它放到下面两个位置之一：

```text
device_tree/twrp_device_google_emu64a/ramdisk-recovery.cpio
device_tree/twrp_device_google_emu64a/artifacts/ramdisk-recovery.cpio
```

## 前提

需要准备：

1. macOS
2. `qemu-system-aarch64`
3. Android SDK 的 android-33 arm64 system image
4. 已经构建或拉回来的 `ramdisk-recovery.cpio`

### 安装 QEMU

```bash
brew install qemu
```

### Android SDK 路径

macOS 默认使用：

```text
$HOME/Library/Android/sdk/system-images/android-33/default/arm64-v8a
```

Linux 默认使用 `$HOME/Android/Sdk`；WSL 检测不到该目录时会回退到
`/mnt/d/YuKongA/AndroidSDK`。也可以用 `SDK_DIR` 覆盖路径。

其中必须存在：

```text
kernel-ranchu
ramdisk.img
```

## 目录内运行约定

当前启动脚本默认使用这个目录下的本地产物：

```text
./artifacts/ramdisk-recovery.cpio
```

运行时文件也默认放到：

```text
./artifacts/qemu_userdata.img
./artifacts/qemu_boot.log
```

也就是说，最小可运行集合是：

1. 当前设备树目录
2. Android SDK 的 `kernel-ranchu` 和 `ramdisk.img`
3. 当前目录或 `artifacts` 目录里的 `ramdisk-recovery.cpio`

## 启动方法

进入设备树目录后，直接运行：

```bash
cd device_tree/twrp_device_google_emu64a
bash launch_qemu.sh twrp
```

这会启动：

1. `kernel-ranchu`
2. 当前目录或 `artifacts` 目录下的 `ramdisk-recovery.cpio`
3. 当前目录下 `artifacts` 里的 `qemu_userdata.img`

如果 `qemu_userdata.img` 不存在，脚本会自动创建一个 8G 的 raw 数据盘。

在 Apple Silicon macOS 上，当前脚本会优先使用 `hvf` 硬件加速；只有不可用时才回退到 `tcg`。如果落到 `tcg`，TWRP 的整体响应会明显变慢。

## 启动正常系统

如果只是验证 QEMU + 内核 + 显示链，不启动 TWRP，可以运行：

```bash
cd device_tree/twrp_device_google_emu64a
bash launch_qemu.sh
```

这时会使用 SDK 自带的 `ramdisk.img`。

## 当前脚本默认参数

当前脚本固定使用：

1. `-machine virt`
2. macOS 优先 `-accel hvf`，Linux 回退 `tcg`
3. `-device virtio-gpu-pci,edid=on,xres=1080,yres=1920`
4. `-device virtio-net-pci`
5. `hostfwd=tcp::5557-:5555`
6. macOS 使用 `-display cocoa,show-cursor=on`；Linux 使用 GTK 缩放窗口

也就是说，宿主机上 ADB 应连接：

```bash
adb connect 127.0.0.1:5557
adb -s 127.0.0.1:5557 get-state
```

## 串口调试

当前 `launch_qemu.sh` 默认把串口写到：

```text
artifacts/qemu_boot.log
```

如果需要可交互串口调试，可以临时把脚本里的串口参数改成：

```text
-serial tcp:127.0.0.1:5557,server,nowait
```

然后在宿主机上连接：

```bash
nc 127.0.0.1 5557
```

连上后会看到：

```text
console:/ $
```

这时可以直接执行：

```text
getprop sys.usb.config
getprop init.svc.adbd
ifconfig eth0
ls /dev/socket
cat /tmp/recovery.log
```

如果只想一次性发几条命令：

```bash
{
  printf '\r\ngetprop sys.usb.config\r\n'
  printf 'getprop init.svc.adbd\r\n'
  printf 'ifconfig eth0\r\n'
  sleep 2
} | nc 127.0.0.1 5557
```

## 当前稳定结论

当前设备树里已经收敛了这些关键修复：

1. recovery root overlay 直接放在设备树里
2. 所需 `.ko` 已直接放进 `recovery/root/lib/modules`
3. `init.recovery.ranchu.rc` 已收敛到 QEMU 路线可用版本
4. ADB 通过 `5556 -> guest 5555` 工作
5. `sys.usb.config` 会被强制收敛回 `adb`
6. `eth0` 会在 `sys.usb.config=adb` 时由 init 负责配置

## 环境变量覆盖

如果默认路径不符合本地环境，可以在启动前覆盖：

```bash
SDK_DIR=/your/sdk/path \
RAMDISK=/your/ramdisk-recovery.cpio \
DATA_IMG=/your/qemu_userdata.img \
LOG=/your/qemu_boot.log \
QEMU_ACCEL=tcg \
CPU_MODEL=max \
bash launch_qemu.sh twrp
```

## 还需要什么

如果别人只拿到这个目录，离“直接跑起来”还需要补齐的只有这些外部条件：

1. 本机安装 `qemu-system-aarch64`
2. 本机有 Android 33 arm64 的 SDK system image
3. 手里有编译出来的 `ramdisk-recovery.cpio`

除了这三项，当前启动脚本已经不再要求依赖仓库根目录下的运行文件。
