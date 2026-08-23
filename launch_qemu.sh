#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)
ARTIFACTS_DIR=${ARTIFACTS_DIR:-$SCRIPT_DIR/artifacts}

case "$(uname -s)" in
  Darwin)
    SDK_ROOT_DEFAULT="$HOME/Library/Android/sdk"
    ;;
  Linux)
    SDK_ROOT_DEFAULT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
    if [ ! -f "$SDK_ROOT_DEFAULT/system-images/android-33/default/arm64-v8a/kernel-ranchu" ] &&
       [ -f /mnt/d/YuKongA/AndroidSDK/system-images/android-33/default/arm64-v8a/kernel-ranchu ]; then
      SDK_ROOT_DEFAULT="/mnt/d/YuKongA/AndroidSDK"
    fi
    ;;
  *)
    SDK_ROOT_DEFAULT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
    ;;
esac
SDK_DEFAULT="$SDK_ROOT_DEFAULT/system-images/android-33/default/arm64-v8a"
SDK_DIR=${SDK_DIR:-$SDK_DEFAULT}
KERNEL=${KERNEL:-$SDK_DIR/kernel-ranchu}
LOG=${LOG:-$ARTIFACTS_DIR/qemu_boot.log}

# Keep the host window, virtio-gpu scanout and Linux DRM mode in sync.  The
# virtio-gpu device defaults vary between QEMU builds, so do not rely on them.
WIDTH=${WIDTH:-1080}
HEIGHT=${HEIGHT:-1920}
REFRESH=${REFRESH:-60}

HOST_ARCH=$(uname -m)
HOST_OS=$(uname -s)
CPU_MODEL=${CPU_MODEL:-}
QEMU_ACCEL=${QEMU_ACCEL:-}
DISPLAY_BACKEND=${DISPLAY_BACKEND:-}

if [ -z "$DISPLAY_BACKEND" ]; then
  if [ "$HOST_OS" = "Darwin" ]; then
    DISPLAY_BACKEND=cocoa
  else
    DISPLAY_BACKEND=gtk
  fi
fi

if [ "$DISPLAY_BACKEND" = "gtk" ]; then
  DISPLAY_OPTIONS="gtk,full-screen=off,show-menubar=off,show-cursor=off,zoom-to-fit=on"
else
  DISPLAY_OPTIONS="$DISPLAY_BACKEND,show-cursor=off"
fi

if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
  echo "qemu-system-aarch64 不在 PATH 中" >&2
  exit 1
fi

if [ -z "$QEMU_ACCEL" ]; then
  if [ "$HOST_ARCH" = "arm64" ] && qemu-system-aarch64 -accel help 2>/dev/null | grep -qx 'hvf'; then
    QEMU_ACCEL=hvf
  else
    QEMU_ACCEL=tcg
  fi
fi

if [ -z "$CPU_MODEL" ]; then
  if [ "$QEMU_ACCEL" = "hvf" ]; then
    CPU_MODEL=host
  else
    CPU_MODEL=max
  fi
fi

mkdir -p "$ARTIFACTS_DIR"

if [ "$#" -gt 0 ] && [ "$1" != "twrp" ]; then
  echo "当前脚本仅支持启动 TWRP recovery。" >&2
  echo "用法: $0 [twrp]" >&2
  exit 1
fi

if [ -n "${RAMDISK:-}" ]; then
  :
else
  RAMDISK="$ARTIFACTS_DIR/ramdisk-recovery.cpio"
  if [ -f "$RAMDISK" ]; then
    echo "使用 ramdisk: $RAMDISK"
  else
    echo "ramdisk-recovery.cpio 不存在: $RAMDISK" >&2
    echo "请将 ramdisk-recovery.cpio 放到 $ARTIFACTS_DIR" >&2
    exit 1
  fi
fi

EXTRA_APPEND="skip_initramfs video=Virtual-1:${WIDTH}x${HEIGHT}@${REFRESH}"
EXTRA_DRIVES=()
echo "=== 启动 TWRP recovery ==="

if [ ! -f "$KERNEL" ]; then
  echo "kernel-ranchu 不存在: $KERNEL" >&2
  exit 1
fi

if [ ! -f "$RAMDISK" ]; then
  echo "ramdisk 不存在: $RAMDISK" >&2
  echo "可将 ramdisk-recovery.cpio 放到当前目录或 $ARTIFACTS_DIR" >&2
  exit 1
fi

: > "$LOG"

nohup qemu-system-aarch64 \
  -machine virt \
  -accel "$QEMU_ACCEL" \
  -cpu "$CPU_MODEL" \
  -smp 2 \
  -m 3072 \
  -kernel "$KERNEL" \
  -initrd "$RAMDISK" \
  -append "console=ttyAMA0 androidboot.hardware=ranchu androidboot.selinux=permissive androidboot.serialno=QEMU0001 $EXTRA_APPEND" \
  -device "virtio-gpu-pci,edid=on,xres=${WIDTH},yres=${HEIGHT}" \
  -display "$DISPLAY_OPTIONS" \
  -device usb-ehci \
  -device usb-mouse \
  -device virtio-net-pci,netdev=net0 \
  -netdev "user,id=net0,hostfwd=tcp::5557-:5555" \
  -serial "file:$LOG" \
  -no-reboot &
echo "QEMU 启动中，日志输出到 $LOG"
echo "可以通过以下命令查看日志："
echo "  tail -f $LOG"
sleep 5
adb connect 127.0.0.1:5557
