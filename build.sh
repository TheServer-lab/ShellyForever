#!/bin/bash
# ShellyForever build script
# Requires: nasm (sudo apt install nasm)
set -e

nasm -f bin boot.asm   -o boot.bin
nasm -f bin kernel.asm -o kernel.bin

cat boot.bin kernel.bin > shellyforever.img

# pad to 1.44MB so it behaves like a standard floppy/USB image
python3 - <<'EOF'
with open('shellyforever.img','rb') as f:
    data = f.read()
target = 1474560
with open('shellyforever.img','ab') as f:
    f.write(b'\x00' * (target - len(data)))
EOF

echo "Built shellyforever.img ($(wc -c < shellyforever.img) bytes)"
echo "Run it with:  qemu-system-x86_64 -drive format=raw,file=shellyforever.img"
