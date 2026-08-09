; ============================================================
;  ShellyForever  --  boot.asm
;  Stage-1 bootloader (fits in one 512-byte sector).
;  1) Loaded by BIOS at 0x7C00 in 16-bit real mode.
;  2) Loads the kernel (kernel.bin) from disk sectors 2..N into
;     memory at 0x8000 using BIOS INT 13h.
;  3) Enables A20, builds a temporary GDT, enters 32-bit
;     protected mode.
;  4) Builds minimal page tables (identity-maps first 2MB using
;     a single 2MB page), enables PAE + long mode + paging.
;  5) Far-jumps into 64-bit long mode straight into the kernel
;     entry point at 0x8000.
; ============================================================

BITS 16
ORG 0x7C00

; The CPU starts executing at the very first byte of this file (0x7C00).
; dbg16 is placed early so its 'call dbg16' sites below can reach it with a
; cheap near call, but that means we MUST jump over it here - otherwise
; the CPU would fall straight into the subroutine and hit its 'ret' with
; no return address on the stack yet, jumping to garbage.
jmp start

KERNEL_LOAD_SEG   equ 0x0000
KERNEL_LOAD_OFF   equ 0x8000
KERNEL_SECTORS    equ 1100        ; how many 512B sectors to load. Bumped from 900 - the
                                  ; splash screen's incbin'd image+palette data (see
                                  ; kernel.asm's splash_stub) adds ~65KB (~127 sectors) on
                                  ; top of the real kernel.bin's existing ~842 sectors
                                  ; (with party/tcp/http/browse/mouse folded in), landing
                                  ; around 970 - 1100 gives real headroom past that, not
                                  ; just enough for today's build. Previously bumped from
                                  ; 560 for the same reason (see git history): too little
                                  ; headroom here silently truncates the kernel's own tail
                                  ; data (ata_port_base/ata_drive_sel/fs_disk_available
                                  ; landed around sector 616 last time this bit), so the
                                  ; ATA driver ran with a zeroed port base and "No disk
                                  ; detected" even though the drive was fine.
                                  ; The CHS fallback reads at most 18
                                  ; sectors per BIOS call (not limited by al directly - see
                                  ; the .loop chunking below) and this total must stay clear
                                  ; of the SFFS region - see kernel.asm's FS_LBA_START (now
                                  ; 1150 to match), and leave real margin, not just enough
                                  ; for today's build - and <= 2880 (media). If
                                  ; KERNEL_SECTORS is ever bumped again, bump FS_LBA_START in
                                  ; kernel.asm to match - the two are not shared constants,
                                  ; so nothing else will catch a drift between them.

; ---- on-screen checkpoint markers ----
; Each stage of the real->protected->long mode transition writes one
; character to a fixed row near the top of the screen, in column order.
; If boot hangs on real hardware, whichever checkpoint is the last one
; visible tells us exactly which stage failed, instead of guessing blind.
; Row 24 (bottom row) is used so it never collides with the boot messages.
; Implemented as one shared subroutine (not a macro) so the call sites
; don't each pay for their own copy of the setup code - every byte
; matters in a 512-byte sector. Registers are intentionally left clobbered
; (no push/pop): every call site reloads ax/bx/dx itself before relying on
; them again.
; in: bx = byte offset into VGA memory (row*80+col)*2, dl = char to show
dbg16:
    mov ax, 0xB800
    mov es, ax
    mov [es:bx], dl
    mov byte [es:bx+1], 0x4F       ; white on red - stands out
    ret

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    ; (The video-mode reset was dropped to fit the chunked kernel reader;
    ; boot sectors always get an 80x25 text mode from the BIOS/emulator.)

    mov [boot_drive], dl        ; BIOS passes boot drive number in dl - save
                                 ; it before any checkpoint call clobbers dl

    mov bx, 0                   ; checkpoint 1: boot sector is executing (col 0)
    mov dl, '1'
    call dbg16

    ; ---- load kernel from disk ----
    ; The kernel is ~117 sectors (160 with headroom) - more than a floppy
    ; track (18) and more than some BIOSes accept in one INT 13h call, so a
    ; single-shot read fails with 'E' right after checkpoint '1' (that's the
    ; "1E" screen). Fix: check for INT 13h extensions (AH=41h) and use the
    ; LBA extended read when present; otherwise fall back to CHS. Either way
    ; read in chunks and advance the buffer. One shared loop does both: the
    ; read_mode byte picks LBA vs CHS, and the CHS path starts at LBA 0 so
    ; the boot-sector copy lands harmlessly at 0x7E00 and the kernel still
    ; begins at 0x8000.
    xor di, di                  ; di = sectors read so far
    mov dword [read_lin], 0x8000
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc .chs
    cmp bx, 0xAA55
    jne .chs
    mov byte [read_mode], 0x42  ; LBA extended read
    jmp .loop
.chs:
    mov byte [read_mode], 0x02  ; CHS read
    mov word [read_lin], 0x7E00 ; boot-sector copy lands here, kernel at 0x8000
    mov ch, 0                   ; cylinder
    mov dh, 0                   ; head
    mov cl, 1                   ; start at sector 1 of track 0
.loop:
    mov ax, KERNEL_SECTORS
    sub ax, di
    jz read_done                ; everything loaded
    cmp byte [read_mode], 0x02
    jne .ext_size
    cmp ax, 18                  ; CHS: one full track at a time
    jbe .have_size
    mov ax, 18
    jmp .have_size
.ext_size:
    cmp ax, 63                  ; LBA: keep calls small for picky BIOSes
    jbe .have_size
    mov ax, 63
.have_size:
    mov [dap_count], ax
    call dap_set_buf
    cmp byte [read_mode], 0x42
    je .ext_issue
    mov es, [dap_seg]
    mov bx, [dap_off]
    mov al, [dap_count]
    mov ah, 0x02                ; BIOS read sectors
    mov dl, [boot_drive]
    int 0x13
    jc disk_error
    jmp .advance
.ext_issue:
    mov ax, di
    inc ax                      ; lba = 1 + sectors_done (fits 16 bits)
    mov [dap_lba], ax
    mov si, dap
    mov dl, [boot_drive]
    mov ah, 0x42                ; BIOS extended read
    int 0x13
    jc disk_error
.advance:
    mov ax, [dap_count]
    add di, ax
    movzx eax, ax
    shl eax, 9                  ; sectors * 512
    add [read_lin], eax
    cmp byte [read_mode], 0x42
    je .loop
    inc dh                      ; CHS: next head, then next cylinder
    cmp dh, 2
    jb .loop
    xor dh, dh
    inc ch
    jmp .loop

read_done:
    mov bx, 2                   ; checkpoint 2: kernel sectors read OK (col 1)
    mov dl, '2'
    call dbg16

    ; ---- hand off to kernel.bin, STILL IN REAL MODE ----
    ; kernel.bin now opens with its own small 16-bit stub (see kernel.asm's
    ; splash_stub) that shows the boot splash (mode 13h) while BIOS INT 10h/
    ; INT 16h are still available, then does the A20/GDT/protected-mode/
    ; long-mode transition itself and finally jumps into kernel_entry. That
    ; transition code used to live here in boot.asm; it moved to kernel.asm
    ; so the splash can run before it, and so this sector - already tight -
    ; doesn't have to grow to fit "set mode 13h, load palette, blit image,
    ; wait for key, restore text mode" as well as the transition.
    ; A far jump (not a near jump) so cs:ip is set explicitly to 0000:8000,
    ; matching KERNEL_LOAD_SEG:KERNEL_LOAD_OFF exactly.
    jmp KERNEL_LOAD_SEG:KERNEL_LOAD_OFF

disk_error:
    mov bx, 2                   ; 'E' at col 1 (same spot '2' would use): a real
    mov dl, 'E'                 ; disk error (carry set), not a hang in INT 13h
    call dbg16
    cli
    hlt
.hang: jmp .hang

boot_drive: db 0
read_mode: db 0                 ; 0x42 = LBA read, 0x02 = CHS read
read_lin: dd 0x8000              ; linear address of the next free kernel buffer byte

; ---- Disk Address Packet for INT 13h AH=42h (LBA extended read) ----
; Kernel starts right after the boot sector: MBR is LBA 0, so the kernel's
; first sector is LBA 1 (equivalent to the old CHS "cylinder 0, head 0,
; sector 2"). count/off/seg/lba are updated by the chunked reader.
ALIGN 4
dap:
    db 0x10                      ; packet size (16 bytes)
    db 0                         ; reserved
dap_count:
    dw KERNEL_SECTORS            ; number of sectors to transfer
dap_off:
    dw KERNEL_LOAD_OFF           ; transfer buffer offset
dap_seg:
    dw KERNEL_LOAD_SEG           ; transfer buffer segment
dap_lba:
    dq 1                         ; starting LBA (sector right after MBR)

; ---- turn the 32-bit linear buffer pointer (read_lin) into a 16-bit
; real-mode seg:off pair, since the kernel buffer grows past the 64K
; segment boundary when reading 160 sectors ----
dap_set_buf:
    mov eax, [read_lin]
    mov edx, eax
    and eax, 0xF
    mov [dap_off], ax
    shr edx, 4
    mov [dap_seg], dx
    ret

; ============================================================
; pad boot sector to 512 bytes, boot signature
; ============================================================
TIMES 510 - ($ - $$) db 0
DW 0xAA55