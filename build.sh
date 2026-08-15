#!/bin/bash
# ShellyForever build script - assembles the three-stage boot image and
# concatenates them at the LBA offsets defined in layout.inc.
#
# Disk layout (must match layout.inc exactly - this script derives its
# numbers from the same file so they can't drift):
#   LBA 0                              : boot.bin (MBR, 512 bytes)
#   LBA STAGE2_LBA .. +STAGE2_SECTORS-1        : stage2.bin (padded)
#   LBA KERNEL_BODY_LBA .. +KERNEL_BODY_SECTORS-1 : kernel_body.bin (padded)
#   LBA FS_LBA_START ..                : filesystem region (left as zeros
#                                         here; fs_load/fs_init handle a
#                                         blank region on first real boot)
set -euo pipefail
cd "$(dirname "$0")"

# ---- pull the layout constants out of layout.inc so this script can't
# disagree with the assembly sources ----
val() { grep -E "^$1\s+equ" layout.inc | head -1 | sed -E "s/^$1\s+equ\s+([0-9]+).*/\1/"; }
STAGE2_LBA=$(val STAGE2_LBA)
STAGE2_SECTORS=$(val STAGE2_SECTORS)
KERNEL_BODY_SECTORS=$(val KERNEL_BODY_SECTORS)
KERNEL_BODY_LBA=$((STAGE2_LBA + STAGE2_SECTORS))
FS_LBA_START=$((KERNEL_BODY_LBA + KERNEL_BODY_SECTORS + 64))

echo "STAGE2_LBA=$STAGE2_LBA STAGE2_SECTORS=$STAGE2_SECTORS"
echo "KERNEL_BODY_LBA=$KERNEL_BODY_LBA KERNEL_BODY_SECTORS=$KERNEL_BODY_SECTORS"
echo "FS_LBA_START=$FS_LBA_START"

nasm -f bin boot.asm -o boot.bin
nasm -f bin stage2.asm -o stage2.bin
nasm -f bin kernel.asm -o kernel_body.bin

check_fits() {
    local file=$1 max_sectors=$2 label=$3
    local size sectors
    size=$(stat -c%s "$file")
    sectors=$(( (size + 511) / 512 ))
    echo "$label: $size bytes = $sectors sectors (budget: $max_sectors)"
    if [ "$sectors" -gt "$max_sectors" ]; then
        echo "ERROR: $label ($sectors sectors) exceeds its layout.inc budget ($max_sectors sectors)." >&2
        echo "Bump the matching *_SECTORS constant in layout.inc and rebuild." >&2
        exit 1
    fi
}
check_fits boot.bin 1 "boot.bin"
check_fits stage2.bin "$STAGE2_SECTORS" "stage2.bin"
check_fits kernel_body.bin "$KERNEL_BODY_SECTORS" "kernel_body.bin"

# ---- assemble the disk image ----
IMAGE_SIZE=$((256 * 1024 * 1024))   # fixed 256MB image, like a standard floppy/USB image

if [ $((FS_LBA_START * 512)) -gt "$IMAGE_SIZE" ]; then
    echo "ERROR: FS_LBA_START (byte offset $((FS_LBA_START * 512))) exceeds the 256MB image size." >&2
    exit 1
fi

rm -f shellyforever.img
truncate -s "$IMAGE_SIZE" shellyforever.img   # zero-filled, fixed 256MB

dd if=boot.bin of=shellyforever.img bs=512 seek=0 conv=notrunc status=none
dd if=stage2.bin of=shellyforever.img bs=512 seek=$STAGE2_LBA conv=notrunc status=none
dd if=kernel_body.bin of=shellyforever.img bs=512 seek=$KERNEL_BODY_LBA conv=notrunc status=none

echo "shellyforever.img built: $(stat -c%s shellyforever.img) bytes"
echo "OK"
