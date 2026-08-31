# ShellyForever

**A complete x86_64 operating system written in pure assembly.**  
*No libc. No OpenSSL. No GRUB. Just raw silicon and stubbornness.*

---

## 🖥️ What is ShellyForever?

ShellyForever is a hobby operating system that boots on real hardware (and QEMU) from a custom BIOS bootloader. It includes a full networking stack with TLS 1.3 support, a text-mode web browser, a custom filesystem, a package manager, a programming language, and a PC speaker audio system — all written from scratch in x86_64 assembly.

**It fits in under 1.2 MB.**

---

## ✨ Features

### 🖥️ Core System

- Custom two-stage BIOS bootloader (512-byte MBR + stage2)
- 64-bit Long Mode with identity-mapped paging
- PS/2 keyboard polling (no interrupts yet)
- Custom SFFS filesystem (Shelly File System)

### 🌐 Networking

- RTL8168 PCIe NIC driver (polling-based)
- Full TCP/IP stack with retransmission
- DHCP client (automatic IP assignment)
- DNS resolver with multi-IP failover
- TLS 1.3 handshake (X25519 + ChaCha20-Poly1305 + SHA-256)
- HTTP/1.1 and HTTPS support (`stake` GET, `sgive` POST)
- Persistent TLS sessions for multiple requests

### 📦 Package Management

- `.sin` package format (stored ZIP, no compression)
- `whattodo.inst` installer scripts (`name`, `version`, `mkdir`, `copy`, `program`, `finish`)
- Registry (`/home/sys/programes.sly`) maps commands to binaries
- `sin install`, `sin uninstall`, and `sin get` commands
- `-keep` flag to preserve packages after installation

### 🎮 Programming Language (Party)

- Interpreted (`.pa`) and compiled (`.run`) modes
- Native compiler (runs on ShellyForever itself)
- Exposed intrinsics: `beep()`, `stake()`, `sgive()`, `fs_read()`, `print()`, etc.
- `pip`-like module manager for Party libraries

### 🔊 Audio

- PC speaker support (port `0x61` + PIT channel 2)
- `beep <hz> <ms>` command (raw frequency/duration)
- `.ss` (Shelly Sound) format (plain-text music notation)
- Startup chime (C Major arpeggio)

### 🔄 System Update

- `auth sys update` command
- Fetches new `boot.bin`, `stage2.bin`, and `kernel_body.bin` from the Shellybin repository
- Range-GET downloads in 16 KB chunks
- CRC32 verification on each component
- Pivot sector (LBA 1) for atomic boot switching
- **Warning: This will damage any other bootloaders (GRUB, etc.)**

### 🛡️ Security Model

- `auth admin` / `auth member` / `auth guest` privilege levels
- Password support (optional, SHA-256 hashed)
- `devmode on/off` bypasses passwords for development
- Scripts run with current user privileges (guest by default)
- `rr script.rsh` runs Rush scripts (read before running)

### 🖥️ Shell Commands (Rush)

| Command | Description |
|---|---|
| `list` | List files in a directory |
| `cpy` | Copy a file |
| `mov` | Move/rename a file |
| `auth del` | Delete a file (admin only) |
| `mkf` | Create a directory |
| `mkfl` | Create an empty file |
| `view` | Print a file to screen |
| `upper` | Print first N lines of a file |
| `lower` | Print last N lines of a file |
| `time` | Show system date/time |
| `me` | Show current user |
| `shelly` | Show OS version |
| `show` | Print a message |
| `bounce` | Ping a host |
| `monitor` | Continuous ping |
| `stake` | Download a file over HTTPS |
| `sgive` | Upload a file over HTTPS |
| `sin install` | Install a `.sin` package |
| `sin uninstall` | Uninstall a package |
| `sin get` | Fetch and install a package from a URL |
| `prs` | List running processes |
| `kill` | Kill a process |
| `prog.run` | Run a program (foreground) |
| `prog.run -back` | Run a program in the background |
| `front` | Bring a background job to the foreground |
| `cf` | Change directory |
| `current` | Show current directory |
| `help` | Show help for a command |
| `auth` | Run a command with privilege escalation |
| `auth sys reset` | Factory reset (not reboot!) |
| `auth sdown` | Shutdown the system |
| `devmode` | Enable/disable developer mode |
| `rr` | Run a Rush script |

---

## 🔧 System Requirements

- **CPU:** x86_64 (Intel or AMD)
- **RAM:** 64 MB minimum (tested on 2 GB)
- **Storage:** ATA/IDE hard disk or SSD (no USB yet)
- **Network:** RTL8168 PCIe NIC (common on older motherboards)
- **Audio:** PC speaker (requires a physical buzzer on the motherboard header)
- **BIOS:** Legacy BIOS (no UEFI support)

---

## ⚠️ Warnings

**This OS is not ready for daily use.** It is a hobby project written in pure assembly. Use it on real hardware at your own risk.

- **`auth sys update`** writes directly to disk sectors. It will **destroy any other bootloaders** (GRUB, Windows Boot Manager, etc.) on the device.
- **`auth sys reset`** is a **factory reset**, not a reboot. It will erase all user data.
- The network stack has a ~50–85% success rate on real hardware. Use `net reset` to retry.
- The `.ss` audio parser has a Heisenbug: it works only when a 1-byte diagnostic padding is present.

---

## 🚀 Getting Started

### Building from Source

1. Clone the repository:

   ```bash
   git clone https://github.com/TheServer-lab/ShellyForever.git
   cd ShellyForever
   ```

2. Assemble the kernel (requires NASM):

   ```bash
   make
   ```

3. Write the bootloader + kernel to a disk image:

   ```bash
   make image
   ```

4. Boot in QEMU:

   ```bash
   make qemu
   ```

5. Write to a USB stick (real hardware):

   ```bash
   dd if=shelly.img of=/dev/sdX bs=512 conv=fsync
   ```

### First Boot

- The OS boots directly into the Rush shell.
- Try `shelly` to see the version.
- Try `bounce google.com` to test networking.
- Try `stake https://raw.githubusercontent.com/TheServer-lab/shellybin/main/sys/version.sly version.sly` to download a file over HTTPS.
- Try `view version.sly` to read it.
- Try `beep 440 250` to test the PC speaker.

---

## 📂 Directory Structure

```text
/
├── boot.bin                 # MBR + bootloader
├── stage2.bin               # Stage 2 bootloader
├── kernel_body.bin          # Main kernel
├── home/
│   ├── sys/
│   │   ├── programes.sly    # Command registry
│   │   ├── sysconfig.sly    # System configuration
│   │   ├── password.sly     # Hashed admin password
│   │   └── version.sly      # Current OS version
│   └── user/                 # User home directories
├── bin/                      # System binaries
└── tmp/                      # Temporary files
```

---

## 🧪 Tested Hardware

- **Motherboard:** ASUS P8Z77-V (Intel H77 chipset)
- **NIC:** RTL8168/8111 (onboard)
- **CPU:** Intel Core i5-3570K
- **RAM:** 8 GB DDR3
- **Storage:** 120 GB SATA SSD

---

## 🐛 Known Issues

- **xHCI (USB 3.0):** Not supported. Use USB 2.0 (EHCI) or the network stack.
- **Intel HDA Audio:** Works in QEMU but not on real hardware.
- **Network Reliability:** ~50–85% success rate on real hardware. Use `net reset`.
- **`.ss` Parser Heisenbug:** Works with diagnostic padding, fails without it.

---

## 📜 License

This source code is **available for educational purposes only**.

You may read, study, and learn from it, but you may not copy, redistribute, or use it as the basis for your own project without explicit permission.

**ShellyForever is a work of art. Please respect the time and effort that went into it.**

---

## 💬 Acknowledgements

- The OSDev Wiki — for documentation on bootloaders, GDT, paging, etc.
- RFC 8446 — for TLS 1.3
- Local repair shop — for the free PC speaker buzzer

---

## 📞 Contact

- **Author:** TheServer-lab
- **Source:** https://github.com/TheServer-lab/ShellyForever
- **Discord:** [Join the ShellyForever community](https://discord.gg/vuUcJCY8bu)

---

> *"It requires two things: a good Ethernet cable and luck."*  
> — ShellyForever Developer
