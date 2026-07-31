#!/bin/bash
# ShellyForever build script
# Requires: nasm (sudo apt install nasm)
set -e

STAGE2_SECTORS=32          # must match STAGE2_SECTORS in boot.asm
STAGE2_BYTES=$((STAGE2_SECTORS * 512))

nasm -f bin boot.asm    -o boot.bin
nasm -f bin stage2.asm  -o stage2.bin
nasm -f bin kernel.asm  -o kernel.bin

# stage2.bin's compiled size is smaller than its sector budget - pad it
# out to exactly STAGE2_BYTES so the kernel always starts at the fixed
# LBA (33) that both boot.asm and stage2.asm assume.
stage2_actual=$(wc -c < stage2.bin)
if [ "$stage2_actual" -gt "$STAGE2_BYTES" ]; then
    echo "ERROR: stage2.bin ($stage2_actual bytes) exceeds its $STAGE2_BYTES-byte budget." >&2
    echo "Bump STAGE2_SECTORS here and in boot.asm/stage2.asm together." >&2
    exit 1
fi
python3 - "$STAGE2_BYTES" <<'EOF'
import sys
target = int(sys.argv[1])
with open('stage2.bin','rb') as f:
    data = f.read()
with open('stage2.bin','ab') as f:
    f.write(b'\x00' * (target - len(data)))
EOF

cat boot.bin stage2.bin kernel.bin > shellyforever.img

# pad to 1.44MB so it behaves like a standard floppy/USB image
python3 - <<'EOF'
with open('shellyforever.img','rb') as f:
    data = f.read()
target = 1474560
with open('shellyforever.img','ab') as f:
    f.write(b'\x00' * (target - len(data)))
EOF

echo "Built shellyforever.img ($(wc -c < shellyforever.img) bytes)"
echo "  boot.bin:   $(wc -c < boot.bin) bytes (stage1, LBA 0)"
echo "  stage2.bin: $STAGE2_BYTES bytes padded, actual code $stage2_actual bytes (LBA 1)"
echo "  kernel.bin: $(wc -c < kernel.bin) bytes (LBA $((1 + STAGE2_SECTORS)))"
echo "Run it with:  qemu-system-x86_64 -drive format=raw,file=shellyforever.img"
