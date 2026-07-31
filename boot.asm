; ============================================================
;  ShellyForever  --  boot.asm
;  Stage-1 bootloader (must fit in one 512-byte sector - hard limit).
;  1) Loaded by BIOS at 0x7C00 in 16-bit real mode.
;  2) Loads stage2.bin (a few sectors) from disk into memory at 0x0600.
;  3) Jumps into stage2, which isn't sector-size-constrained and does
;     everything else: the actual (large, chunked) kernel load, A20,
;     GDT, protected mode, paging, and long mode entry.
;
;  Why two stages: the kernel now needs up to KERNEL_SECTORS sectors
;  (see stage2.asm), and loading that in a single INT 13h AH=42h call
;  is NOT safe - real-mode transfers are still bounded by 64KB segment
;  windows in practice (confirmed: a single-shot read of 400 sectors
;  reliably failed under QEMU/SeaBIOS, while chunking in 32KB pieces
;  and advancing the segment each chunk works). That chunking loop
;  doesn't fit in this 512-byte sector alongside boot mechanics, so it
;  lives in stage2 instead, which has room to spare.
; ============================================================

BITS 16
ORG 0x7C00

jmp start

STAGE2_LOAD_SEG equ 0x0000
STAGE2_LOAD_OFF equ 0x0600
; Stage2's own compiled size is only a couple KB, but this is padded out
; to a fixed sector count by build.sh regardless, so the kernel always
; starts at a known, fixed LBA on disk. 32 sectors (16KB) is generous
; headroom for stage2 to grow into later.
STAGE2_SECTORS  equ 32
; Fixed low-memory scratch address (below stage2's own 0x0600 load
; address, so nothing overwrites it) used to hand the BIOS-reported boot
; drive number from stage1 to stage2.
BOOT_DRIVE_ADDR equ 0x0500

; ---- on-screen checkpoint markers (see stage2.asm for the rest) ----
; in: bx = byte offset into VGA memory (row*80+col)*2, dl = char to show
dbg16:
    mov ax, 0xB800
    mov es, ax
    mov [es:bx], dl
    mov byte [es:bx+1], 0x4F       ; white on red - stands out
    ret
%macro DBG16 2                     ; %1 = column, %2 = char
    mov bx, (0*80 + %1) * 2
    mov dl, %2
    call dbg16
%endmacro

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    ; ---- force standard 80x25 16-color text mode ----
    mov ax, 0x0003
    int 0x10

    mov [BOOT_DRIVE_ADDR], dl   ; hand off to stage2
    mov [boot_drive], dl

    DBG16 0, '1'                   ; checkpoint 1: boot sector is executing

    ; ---- load stage2 from disk ----
    ; Same extensions-check-then-fallback approach as before, but now
    ; only for a small, single-64KB-window-safe transfer (32 sectors),
    ; so a single AH=42h call (or the CHS fallback) is fine here.
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc chs_read
    cmp bx, 0xAA55
    jne chs_read

    mov si, dap
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc disk_error
    jmp read_done

chs_read:
    mov ax, STAGE2_LOAD_SEG
    mov es, ax
    mov bx, STAGE2_LOAD_OFF
    mov ah, 0x02                ; BIOS read sectors
    mov al, STAGE2_SECTORS      ; fits in a byte easily at this size
    mov ch, 0                   ; cylinder 0
    mov cl, 2                   ; start at sector 2 (sector 1 = boot sector)
    mov dh, 0                   ; head 0
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

read_done:
    DBG16 1, '2'                   ; checkpoint 2: stage2 loaded OK
    jmp 0x0000:STAGE2_LOAD_OFF     ; hand off; stage2 takes it from here

disk_error:
    DBG16 1, 'E'
    cli
    hlt
.hang: jmp .hang

boot_drive: db 0

; ---- Disk Address Packet for INT 13h AH=42h (LBA extended read) ----
; Stage2 starts right after the boot sector: MBR is LBA 0, so stage2's
; first sector is LBA 1.
ALIGN 4
dap:
    db 0x10                      ; packet size (16 bytes)
    db 0                         ; reserved
    dw STAGE2_SECTORS            ; number of sectors to transfer
    dw STAGE2_LOAD_OFF           ; transfer buffer offset
    dw STAGE2_LOAD_SEG           ; transfer buffer segment
    dq 1                         ; starting LBA (sector right after MBR)

; ============================================================
; pad boot sector to 512 bytes, boot signature
; ============================================================
TIMES 510 - ($ - $$) db 0
DW 0xAA55
