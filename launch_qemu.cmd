@echo off
setlocal EnableExtensions

rem Windows launcher for the TWRP emu64a recovery image.
set "SCRIPT_DIR=%~dp0"
set "QEMU_DIR=%SCRIPT_DIR%qemu-w64"
if not exist "%QEMU_DIR%\qemu-system-aarch64.exe" set "QEMU_DIR=D:\YuKongA\qemu\qemu-w64"
set "QEMU=%QEMU_DIR%\qemu-system-aarch64.exe"
set "SDK_ARM64=D:\YuKongA\AndroidSDK\system-images\android-33\default\arm64-v8a"
set "KERNEL=%SDK_ARM64%\kernel-ranchu"
set "RAMDISK=%SCRIPT_DIR%artifacts\ramdisk-recovery.cpio"
if not exist "%RAMDISK%" set "RAMDISK=D:\GitHub\android_device_google_emu64a\artifacts\ramdisk-recovery.cpio"
set "ARTIFACTS=%SCRIPT_DIR%artifacts"
set "LOG=%ARTIFACTS%\qemu_boot.log"
set "ADB=D:\YuKongA\AndroidSDK\platform-tools\adb.exe"
set "WIDTH=1080"
set "HEIGHT=1920"
set "REFRESH=60"

if not exist "%QEMU%" goto missing
if not exist "%KERNEL%" goto missing
if not exist "%RAMDISK%" goto missing
if not exist "%ARTIFACTS%" mkdir "%ARTIFACTS%"

echo Starting TWRP emu64a...
echo QEMU log: %LOG%
echo ADB command after boot: "%ADB%" connect 127.0.0.1:5557

if exist "%~dp0fit_qemu_window.ps1" (
    start "" /b powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0fit_qemu_window.ps1" -GuestWidth %WIDTH% -GuestHeight %HEIGHT%
)

"%QEMU%" ^
    -machine virt ^
    -accel tcg ^
    -cpu cortex-a57 ^
    -smp 2 ^
    -m 3072 ^
    -kernel "%KERNEL%" ^
    -initrd "%RAMDISK%" ^
    -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.serialno=QEMU0001 skip_initramfs video=Virtual-1:%WIDTH%x%HEIGHT%@%REFRESH%" ^
    -device virtio-gpu-pci,edid=on,xres=%WIDTH%,yres=%HEIGHT% ^
    -device usb-ehci ^
    -device usb-tablet ^
    -device virtio-net-pci,netdev=net0 ^
    -netdev user,id=net0,hostfwd=tcp::5557-:5555 ^
    -display gtk,full-screen=off,show-menubar=off,show-cursor=on,zoom-to-fit=on ^
    -serial file:"%LOG%" ^
    -no-reboot

set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
    echo QEMU exited with code %EXIT_CODE%.
    pause
)
exit /b %EXIT_CODE%

:missing
echo Missing required file.
echo QEMU:    %QEMU%
echo Kernel:  %KERNEL%
echo Ramdisk: %RAMDISK%
pause
exit /b 1
