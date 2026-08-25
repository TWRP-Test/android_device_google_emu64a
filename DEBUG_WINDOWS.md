# 在 Windows + WSL2 上调试 emu64a TWRP

Aurora 上游的 [`README.md`](README.md) / [`DEVELOP.md`](DEVELOP.md) 是 macOS + 裸 QEMU
路线。Windows 主机也能跑通同一条链路（虚拟化加速 hvf 没有，回退 TCG，慢但够调
UI）。这份文档总结实测的 Windows 工程化路径。

## 0. 前提

| 角色 | Windows 端 | WSL2 端 |
|---|---|---|
| 编译 |  | Ubuntu 24.04，本仓库放 `device/google/emu64a` |
| QEMU | `qemu-system-aarch64` | |
| Android 33 arm64 SDK image | 含 `kernel-ranchu` + `ramdisk.img` | |
| ADB | `platform-tools` | |
| ramdisk 重打 | | `prebuilts/build-tools/path/linux-x86/cpio`（AOSP 自带） |

只有 QEMU、Android SDK、ADB 必须在 Windows 端；WSL2 不直接跑 GUI（WSLg 也行
但绕弯）。

## 1. 装 QEMU（无管理员）

`winget install SoftwareFreedomConservancy.QEMU` 走 NSIS 安装，UAC 经常被取消。
绕过法：直接下安装包用 7-Zip 解压抽出二进制。

```powershell
mkdir D:\YuKongA\qemu
curl -L -o D:\YuKongA\qemu\qemu-installer.exe `
    https://qemu.weilnetz.de/w64/2026/qemu-w64-setup-20260422.exe
7z x D:\YuKongA\qemu\qemu-installer.exe -oD:\YuKongA\qemu\qemu-w64
D:\YuKongA\qemu\qemu-w64\qemu-system-aarch64.exe --version
```

预期看到 `QEMU emulator version 11.0.0` 之类。

## 2. 装 Android 33 ARM64 system image

```powershell
sdkmanager --install "system-images;android-33;default;arm64-v8a"
```

装完路径默认在 `%LOCALAPPDATA%\Android\Sdk\system-images\android-33\default\arm64-v8a\`，
也可能在 `D:\YuKongA\AndroidSDK\system-images\android-33\default\arm64-v8a\`，里面要有
`kernel-ranchu` 和 `ramdisk.img`。

> **必须 android-33。**`android-35` / `android-36` 不再附带 `virtio-gpu.ko` 和它
> 的依赖链，TWRP DRM 后端开不起来。详见 Aurora `DEVELOP.md` 5.1。

## 3. WSL2 编 recovery

```bash
# 在 WSL 里
cd ~/twrp-16.0
source build/envsetup.sh
lunch twrp_emu64a
m recoveryimage
```

产物：`out/target/product/emu64a/ramdisk-recovery.cpio`。

## 4. 把 ramdisk 拷到 Windows

```powershell
cp \\wsl.localhost\Ubuntu-24.04\home\$env:USERNAME\twrp-16.0\out\target\product\emu64a\ramdisk-recovery.cpio `
   D:\GitHub\android_device_google_emu64a\artifacts\ramdisk-recovery.cpio
```

## 5. Windows launcher（cmd 版避免 PowerShell quoting 坑）

`D:\GitHub\android_device_google_emu64a\launch_qemu.cmd`：

```bat
@echo off
setlocal
set QEMU_DIR=D:\YuKongA\qemu\qemu-w64
set QEMU=%QEMU_DIR%\qemu-system-aarch64.exe
set SDK_ARM64=D:\YuKongA\AndroidSDK\system-images\android-33\default\arm64-v8a
set KERNEL=%SDK_ARM64%\kernel-ranchu
set RAMDISK=D:\GitHub\android_device_google_emu64a\artifacts\ramdisk-recovery.cpio
set ARTIFACTS=D:\GitHub\android_device_google_emu64a\artifacts
set LOG=%ARTIFACTS%\qemu_boot.log
set DATA_IMG=%ARTIFACTS%\qemu_userdata.img

if not exist "%ARTIFACTS%" mkdir "%ARTIFACTS%"
if not exist "%DATA_IMG%" "%QEMU_DIR%\qemu-img.exe" create -f raw "%DATA_IMG%" 512M

"%QEMU%" ^
    -machine virt ^
    -accel tcg ^
    -cpu cortex-a57 ^
    -smp 2 ^
    -m 3072 ^
    -kernel "%KERNEL%" ^
    -initrd "%RAMDISK%" ^
    -drive file="%DATA_IMG%",if=none,format=raw,id=userdata ^
    -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.serialno=QEMU0001 skip_initramfs video=Virtual-1:1080x1920@60" ^
    -device virtio-gpu-pci,edid=on,xres=1080,yres=1920 ^
    -device usb-ehci ^
    -device usb-storage,drive=userdata ^
    -device usb-mouse ^
    -device virtio-net-pci,netdev=net0 ^
    -netdev user,id=net0,hostfwd=tcp::5557-:5555 ^
    -display gtk,full-screen=off,show-menubar=off,show-cursor=off,zoom-to-fit=on ^
    -serial file:"%LOG%" ^
    -no-reboot
```

`xres/yres` 设置的是 virtio-gpu 的初始 scanout；Windows 一键脚本默认使用
竖屏 `1080x1920@60`。

需要改成其他尺寸时，修改 `launch_qemu.cmd` 中的 `WIDTH`、`HEIGHT`、`REFRESH`
三行，并保持 `-append` 与 `-device virtio-gpu-pci` 使用这些变量。`zoom-to-fit=on`
会在窗口尺寸受宿主屏幕限制时缩放显示画面；guest 内部的 DRM 分辨率仍然是
`1080x1920`，不会改变 TWRP 的布局和触摸坐标。若窗口仍显示的是旧尺寸，请先关闭
旧的 QEMU 实例，再重新运行脚本。

Windows 启动脚本会同时运行 `fit_qemu_window.ps1`，按当前显示器工作区自动调整外层
窗口大小并保持竖屏比例，因此不会出现横向铺满、两侧大黑边的窗口。该脚本位于
`D:\GitHub\android_device_google_emu64a`，需要与 `launch_qemu.cmd` 放在同一目录。

启动：

```powershell
Start-Process cmd.exe -ArgumentList '/c','D:\GitHub\android_device_google_emu64a\launch_qemu.cmd' `
    -WorkingDirectory 'C:\Windows\Temp' -WindowStyle Hidden
```

> 用 `cmd.exe` 包一层是因为 PowerShell 的 `Start-Process -ArgumentList` 会把
> `-append` 后面带空格的字符串拆成多个 arg；cmd 的 `^` 续行 + 双引号能正确传递。
>
> `-WorkingDirectory C:\Windows\Temp` 是为了避免 cwd 是 `\\wsl.localhost\...` 时
> cmd 抱怨 UNC 不支持。
>
> Windows 的 `-display`：用 `gtk` 而不是 `sdl,gl=off`。后者在 QEMU 11 win64 build
> 上结合 virtio-gpu 触发 0xC0000005 access violation。

约 20 秒后 GTK 窗口出现，TWRP UI（或 Phase 1 demo）显示。

## 6. ADB 连接

QEMU `hostfwd` 把 guest 5555 转到 host 5557。Windows 端：

```powershell
& 'D:\YuKongA\AndroidSDK\platform-tools\adb.exe' connect 127.0.0.1:5557
& 'D:\YuKongA\AndroidSDK\platform-tools\adb.exe' devices
# 应见 127.0.0.1:5557  recovery
```

guest 内的 `init.recovery.ranchu.rc` 在 `on property:sys.usb.config=adb` 时
强配 `eth0=10.0.2.15`，TCP-ADB 才走得通。

## 7. 串口调试

`launch_qemu.cmd` 里 `-serial file:%LOG%` 把 guest 串口写到
`D:\GitHub\android_device_google_emu64a\artifacts\qemu_boot.log`。Windows 用 `Get-Content -Wait` 当
`tail -f`：

```powershell
Get-Content D:\GitHub\android_device_google_emu64a\artifacts\qemu_boot.log -Wait -Tail 30
```

要交互式 console，把 `-serial file:...` 换成
`-serial tcp:127.0.0.1:5556,server,nowait`，然后用 `nc` / `ncat` / PuTTY 接 5556。
不过 Aurora 那一头还有个 ADB 端口也叫 5556，用别的端口避免冲突。

## 8. /tmp/recovery.log

TWRP 自己往 `/tmp/recovery.log` 写日志。Aurora 的 `init.recovery.ranchu.rc`
在 `init.svc.recovery=stopped` 时把它转储到 `/dev/kmsg`，所以 recovery 退出后
自动进串口 log。运行中也可以：

```powershell
& adb -s 127.0.0.1:5557 shell 'cat /tmp/recovery.log' | Tee-Object recovery.log
```

排查 minui DRM、libguitwrp_v2 的关键字：

```text
falling back to drmModeSetCrtc   # virtio-gpu atomic 失败 -> legacy modeset
BoardConfig pinned mode          # TW_DRM_PREFERRED_MODE_W/_H 命中
modeset succeeded                # legacy modeset 成功
clamping number_of_lms           # SDE 拓扑超过实际 plane 数（virtio-gpu 1 plane）
```

## 9. 一次完整改 minui → 看效果的循环

```bash
# WSL
cd ~/twrp-16.0
$EDITOR bootable/recovery/minuitwrp/graphics_drm.cpp
m libminuitwrp recoveryimage   # ~2 min
bash /tmp/repack.sh             # ~3 sec
```

```powershell
# Windows
Stop-Process -Name qemu-system-aarch64 -Force -ErrorAction SilentlyContinue
cp \\wsl.localhost\Ubuntu-24.04\home\$env:USERNAME\twrp-16.0\out\target\product\emu64a\ramdisk-recovery.cpio `
   D:\GitHub\android_device_google_emu64a\artifacts\ramdisk-recovery.cpio
Start-Process cmd.exe -ArgumentList '/c','D:\GitHub\android_device_google_emu64a\launch_qemu.cmd' `
    -WorkingDirectory 'C:\Windows\Temp' -WindowStyle Hidden
```

GTK 窗口里看新结果。整圈约 3 分钟（TCG 编译 + 启动 + UI hover），日常迭代可
接受。
