; ============================================================
;  ShellyForever  --  boot.asm
;  Stage-1 bootloader (fits in one 512-byte sector).
;  1) Loaded by BIOS at 0x7C00 in 16-bit real mode.
;  2) Loads stage2.bin (splash + relocator + mode-transition code - see
;     stage2.asm) from disk sectors STAGE2_LBA..STAGE2_LBA+STAGE2_SECTORS-1
;     into memory at 0x8000 using BIOS INT 13h.
;
;  *** CHANGED (relocating loader rewrite): this file used to load the
;  WHOLE kernel here, flat, capped at a hard ~1216-sector ceiling because
;  conventional memory tops out at 0x9FFFF just above this load address
;  (0xA0000 is the VGA framebuffer window, not RAM - BIOS INT 13h will
;  "read" sectors past that boundary but real hardware silently drops
;  them instead of storing them). That ceiling is gone: this file now
;  only loads stage2, which is tiny (splash + loader code, not the whole
;  OS), and stage2 itself loads and relocates the real kernel body above
;  1MB in chunks (see stage2.asm's relocate_kernel_body) where there is
;  no such ceiling. See layout.inc for the disk-layout constants shared
;  by all three stages so they can't drift out of sync again.
;
;  3) Far-jumps into stage2 at 0000:8000, STILL IN REAL MODE. Everything
;     past this point - A20, GDT, protected/long mode, page tables - now
;     lives in stage2.asm (moved there originally so the splash could run
;     first with BIOS still available; unchanged by this rewrite).
; ============================================================

%include "layout.inc"

BITS 16
ORG 0x7C00

; The CPU starts executing at the very first byte of this file (0x7C00).
; dbg16 is placed early so its 'call dbg16' sites below can reach it with a
; cheap near call, but that means we MUST jump over it here - otherwise
; the CPU would fall straight into the subroutine and hit its 'ret' with
; no return address on the stack yet, jumping to garbage.
jmp start

; ---- on-screen checkpoint markers ----
; Each stage of the boot process writes one character to a fixed row near
; the top of the screen, in column order. If boot hangs on real hardware,
; whichever checkpoint is the last one visible tells us exactly which
; stage failed, instead of guessing blind. Row 24 (bottom row) is used so
; it never collides with the boot messages. Implemented as one shared
; subroutine (not a macro) so the call sites don't each pay for their own
; copy of the setup code - every byte matters in a 512-byte sector.
; Registers are intentionally left clobbered (no push/pop): every call
; site reloads ax/bx/dx itself before relying on them again.
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

    ; ---- load stage2 from disk ----
    ; stage2 is small but still usually more than a floppy track (18
    ; sectors) and more than some BIOSes accept in one INT 13h call, so a
    ; single-shot read can fail with 'E' right after checkpoint '1' (the
    ; "1E" screen). Fix: check for INT 13h extensions (AH=41h) and use the
    ; LBA extended read when present; otherwise fall back to CHS. Either
    ; way, read in chunks and advance the buffer. One shared loop does
    ; both: the read_mode byte picks LBA vs CHS, and the CHS path starts
    ; at LBA 0 so the boot-sector copy lands harmlessly at 0x7E00 and
    ; stage2 still begins at 0x8000.
    xor di, di                  ; di = sectors read so far
    mov dword [read_lin], STAGE2_LOAD_OFF
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
    mov word [read_lin], 0x7E00 ; boot-sector copy lands here, stage2 at 0x8000
    mov ch, 0                   ; cylinder
    mov dh, 0                   ; head
    mov cl, 1                   ; start at sector 1 of track 0
.loop:
    mov ax, STAGE2_SECTORS
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
    add ax, STAGE2_LBA          ; lba = STAGE2_LBA + sectors_done so far
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
    mov bx, 2                   ; checkpoint 2: stage2 sectors read OK (col 1)
    mov dl, '2'
    call dbg16

    ; ---- hand off to stage2.bin, STILL IN REAL MODE ----
    ; dbg16 clobbers dl (it's the char being printed), so restore dl to the
    ; real boot drive number here - stage2 captures dl into its own
    ; boot_drive at the top of splash_stub and relies on it for every disk
    ; read it does later (relocate_kernel_body). Without this, stage2 would
    ; inherit dl = '2' (0x32) instead of the actual drive number.
    mov dl, [boot_drive]

    ; A far jump (not a near jump) so cs:ip is set explicitly to 0000:8000,
    ; matching STAGE2_LOAD_SEG:STAGE2_LOAD_OFF exactly.
    jmp STAGE2_LOAD_SEG:STAGE2_LOAD_OFF

disk_error:
    mov bx, 2                   ; 'E' at col 1 (same spot '2' would use): a real
    mov dl, 'E'                 ; disk error (carry set), not a hang in INT 13h
    call dbg16
    cli
    hlt
.hang: jmp .hang

boot_drive: db 0
read_mode: db 0                 ; 0x42 = LBA read, 0x02 = CHS read
read_lin: dd STAGE2_LOAD_OFF     ; linear address of the next free stage2 buffer byte

; ---- Disk Address Packet for INT 13h AH=42h (LBA extended read) ----
; stage2 starts right after the boot sector: MBR is LBA 0, so its first
; sector is LBA STAGE2_LBA (equivalent to the old CHS "cylinder 0, head 0,
; sector 2"). count/off/seg/lba are updated by the chunked reader.
ALIGN 4
dap:
    db 0x10                      ; packet size (16 bytes)
    db 0                         ; reserved
dap_count:
    dw STAGE2_SECTORS            ; number of sectors to transfer
dap_off:
    dw STAGE2_LOAD_OFF           ; transfer buffer offset
dap_seg:
    dw STAGE2_LOAD_SEG           ; transfer buffer segment
dap_lba:
    dq STAGE2_LBA                ; starting LBA (sector right after MBR)

; ---- turn the 32-bit linear buffer pointer (read_lin) into a 16-bit
; real-mode seg:off pair, since the stage2 buffer can in principle grow
; past the 64K segment boundary ----
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
