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
echo
echo "Run it with:"
echo "  qemu-system-x86_64 -drive format=raw,file=shellyforever.img \\"
echo "    -netdev user,id=n0 -device rtl8139,netdev=n0"
echo
echo "ShellyForever also has a native e1000 driver now, for real Intel"
echo "PRO/1000 hardware (82540/82541/82545/82546/8257x). To test that path"
echo "under QEMU instead, swap the device:"
echo "  qemu-system-x86_64 -drive format=raw,file=shellyforever.img \\"
echo "    -netdev user,id=n0 -device e1000,netdev=n0"
echo "nic_init tries RTL8139 first, then e1000 - whichever the machine"
echo "actually has, everything above the driver (ARP/IPv4/ICMP/DNS, and"
echo " netinfo/bounce/monitor/dns/net) is unaffected either way."
echo
echo "(netinfo/bounce/monitor/dns/net all need that -netdev/-device pair -"
echo " without it QEMU has no NIC at all, nic_present stays 0, and every"
echo " network command just prints 'network: no NIC detected.')"
echo
echo "Note: QEMU's slirp user-network defaults to 10.0.2.0/24, gw 10.0.2.2,"
echo "dns 10.0.2.3 - which is why ShellyForever's static IP config matches."