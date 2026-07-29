; ============================================================
;  Shelly OS — Stage 1 Boot Sector (MBR)
;
;  Runs in 16-bit real mode. Loads kernel from disk to 0x10000
;  and jumps to it.
;
;  Uses ONLY int 0x13, ah=0x02 (CHS read).  All volatile
;  registers are saved/restored around each BIOS call because
;  real hardware may clobber them.
;
;  Tries HDD geometry (63 SPT) first; if that fails, reads
;  one sector at a time with geometry auto-detection.
;
;  Must be exactly 512 bytes with 0xAA55 boot signature.
; ============================================================

[BITS 16]
[ORG 0x7C00]

KERNEL_LOAD_SEG   equ 0x1000
KERNEL_LOAD_OFF   equ 0x0000
KERNEL_SECTORS    equ 96       ; 48KB (kernel is ~36KB)

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [boot_drive], dl

    mov si, msg_loading
    call print_string

    ; ---- reset disk ----
    mov dl, [boot_drive]
    mov ah, 0x00
    int 0x13

    ; ---- Try HDD geometry (63 SPT) ----
    ; Read 62 sectors: sector 2-63, head 0, cylinder 0
    mov ax, KERNEL_LOAD_SEG
    mov es, ax
    xor bx, bx
    mov dl, [boot_drive]
    mov ah, 0x02
    mov al, 62
    mov ch, 0
    mov cl, 2
    mov dh, 0
    int 0x13
    jnc .hdd_cont

    ; HDD failed → floppy fallback
    jmp .floppy_start

.hdd_cont:
    ; Read remaining 34 sectors: sector 1-34, head 1, cylinder 0
    mov ax, KERNEL_LOAD_SEG
    mov es, ax
    mov bx, 62 * 512
    mov dl, [boot_drive]
    mov ah, 0x02
    mov al, 34
    mov ch, 0
    mov cl, 1
    mov dh, 1
    int 0x13
    jc disk_error
    jmp .done

; ---- Floppy fallback: detect geometry on the fly ----
; Read one sector at a time, preserving all regs around each
; BIOS call.  When a sector fails (end of track) we try head 1;
; if that also fails, wrap to next cylinder.
.floppy_start:
    mov ax, KERNEL_LOAD_SEG
    mov es, ax
    xor bx, bx
    mov ch, 0
    mov cl, 2
    xor dh, dh
    mov di, KERNEL_SECTORS

.floppy_loop:
    pusha
    pushf
    mov ax, KERNEL_LOAD_SEG
    mov es, ax
    mov dl, [boot_drive]
    mov ah, 0x02
    mov al, 1
    int 0x13
    popf                        ; restore flags (CF = read result)
    popa                        ; restore CH, CL, DH, BX, DI, etc.
    jnc .floppy_ok

    ; Sector failed → advance head or cylinder
    cmp dh, 1
    jae .next_cyl
    inc dh
    mov cl, 1
    jmp .floppy_loop

.next_cyl:
    xor dh, dh
    inc ch
    mov cl, 1
    jmp .floppy_loop

.floppy_ok:
    add bx, 512
    dec di
    jz .done
    inc cl
    jmp .floppy_loop

.done:
    mov si, msg_ok
    call print_string
    jmp KERNEL_LOAD_SEG:KERNEL_LOAD_OFF

disk_error:
    mov si, msg_err
    call print_string
    jmp $

; ------------------------------------------------------------
; print_string: BIOS teletype output
; ------------------------------------------------------------
print_string:
    pusha
.loop:
    lodsb
    or al, al
    jz .done
    mov ah, 0x0E
    mov bh, 0x00
    mov bl, 0x07
    int 0x10
    jmp .loop
.done:
    popa
    ret

; ------------------------------------------------------------
; data
; ------------------------------------------------------------
boot_drive  db 0
msg_loading db "Shelly: loading kernel...", 13, 10, 0
msg_ok      db "OK, jumping to kernel.", 13, 10, 0
msg_err     db "DISK READ ERROR", 13, 10, 0

; ------------------------------------------------------------
; pad to 510 bytes and add boot signature
; ------------------------------------------------------------
times 510 - ($ - $$) db 0
dw 0xAA55
