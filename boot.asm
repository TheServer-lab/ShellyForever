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
KERNEL_SECTORS    equ 40          ; how many 512B sectors to load (20KB, plenty of room)

; ---- on-screen checkpoint markers ----
; Each stage of the real->protected->long mode transition writes one
; character to a fixed row near the top of the screen, in column order.
; If boot hangs on real hardware, whichever checkpoint is the last one
; visible tells us exactly which stage failed, instead of guessing blind.
; Row 24 (bottom row) is used so it never collides with the boot messages.
; Implemented as one shared subroutine (not a macro) so the 5 call sites
; below don't each pay for their own copy of the setup code - every byte
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
    ; Some real BIOSes hand off to the boot sector in a different video mode
    ; (vendor splash screens, etc). If we don't set this explicitly, our raw
    ; writes to 0xB8000 below can land somewhere that doesn't render as
    ; legible on-screen text - which would explain checkpoint markers
    ; appearing in the wrong place / as a smear instead of a clean digit.
    mov ax, 0x0003
    int 0x10

    mov [boot_drive], dl        ; BIOS passes boot drive number in dl - save
                                 ; it before any checkpoint call clobbers dl

    DBG16 0, '1'                   ; checkpoint 1: boot sector is executing

    ; ---- load kernel from disk ----
    ; Real BIOSes (especially booting off USB) very often don't support, or
    ; mis-translate, legacy CHS INT 13h reads (AH=02h) for arbitrary sector
    ; numbers - that's why this hung on real hardware while working fine in
    ; QEMU. Fix: check for INT 13h extensions (AH=41h) and use the LBA-based
    ; extended read (AH=42h) when present; fall back to the old CHS read
    ; only if extensions genuinely aren't there (some older/flakier BIOSes).
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc chs_read                 ; extensions not supported -> fall back
    cmp bx, 0xAA55
    jne chs_read

    mov si, dap
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc disk_error
    jmp read_done

chs_read:
    mov ax, KERNEL_LOAD_SEG
    mov es, ax
    mov bx, KERNEL_LOAD_OFF
    mov ah, 0x02                ; BIOS read sectors
    mov al, KERNEL_SECTORS      ; number of sectors
    mov ch, 0                   ; cylinder 0
    mov cl, 2                   ; start at sector 2 (sector 1 = boot sector)
    mov dh, 0                   ; head 0
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

read_done:
    DBG16 1, '2'                   ; checkpoint 2: kernel sectors read OK

    cli

    ; ---- enable A20 line: try both the fast-A20 gate (port 0x92) and the
    ; keyboard-controller method. Not every chipset honors 0x92, so this
    ; does both unconditionally - harmless if a line is already enabled.
    call enable_a20

    DBG16 2, '3'                   ; checkpoint 3: A20 enabling done

    ; ---- load GDT for protected mode ----
    lgdt [gdt32_descriptor]

    DBG16 3, '4'                   ; checkpoint 4: GDT loaded

    DBG16 4, '5'                   ; checkpoint 5: about to set PE and far-jump
                                    ; (must fire BEFORE PE is set: once CR0.PE=1,
                                    ; 'mov es,ax' is a protected-mode selector load,
                                    ; not a real-mode segment load, and dbg16's
                                    ; mov es,0xB800 would fault - 0xB800 is way
                                    ; outside our GDT's bounds)

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE32_SEL:pm_entry     ; far jump flushes prefetch, loads CS

disk_error:
    DBG16 1, 'E'                   ; distinct from checkpoint 2's spot: a real
                                    ; disk error (BIOS returned, carry set),
                                    ; not a silent hang inside the INT 13h call
    cli
    hlt
.hang: jmp .hang

; -------- enable A20 via port 0x92 (fast A20) and the 8042 keyboard
; controller (older/more universal method). Some real chipsets only
; honor one or the other. --------
enable_a20:
    ; method 1: fast A20 gate
    in al, 0x92
    or al, 2
    and al, 0xFE                ; leave bit0 (fast reset) alone/clear
    out 0x92, al

    ; method 2: 8042 keyboard controller
    call kbd_wait_input
    mov al, 0xAD                ; disable keyboard
    out 0x64, al

    call kbd_wait_input
    mov al, 0xD0                ; read output port
    out 0x64, al

    call kbd_wait_output
    in al, 0x60
    push ax                     ; save current output port value

    call kbd_wait_input
    mov al, 0xD1                ; write output port
    out 0x64, al

    call kbd_wait_input
    pop ax
    or al, 2                    ; set A20 bit
    out 0x60, al

    call kbd_wait_input
    mov al, 0xAE                ; re-enable keyboard
    out 0x64, al

    call kbd_wait_input
    ret

; al is scratch in both helpers below - every call site reloads al itself
; right after (or doesn't need it again), so it's safe to leave clobbered.
kbd_wait_input:
.wait:
    in al, 0x64
    test al, 2
    jnz .wait
    ret

kbd_wait_output:
.wait:
    in al, 0x64
    test al, 1
    jz .wait
    ret

boot_drive: db 0

; ---- Disk Address Packet for INT 13h AH=42h (LBA extended read) ----
; Kernel starts right after the boot sector: MBR is LBA 0, so the kernel's
; first sector is LBA 1 (equivalent to the old CHS "cylinder 0, head 0,
; sector 2").
ALIGN 4
dap:
    db 0x10                      ; packet size (16 bytes)
    db 0                         ; reserved
    dw KERNEL_SECTORS            ; number of sectors to transfer
    dw KERNEL_LOAD_OFF           ; transfer buffer offset
    dw KERNEL_LOAD_SEG           ; transfer buffer segment
    dq 1                         ; starting LBA (sector right after MBR)

; ============================================================
; 32-bit protected mode
; ============================================================
%macro DBG32 2                     ; %1 = column, %2 = char
    mov edi, 0xB8000 + (0*80 + %1) * 2
    mov byte [edi], %2
    mov byte [edi+1], 0x1F         ; white on blue
%endmacro

BITS 32
pm_entry:
    mov ax, DATA32_SEL
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x9F000

    DBG32 5, '6'                   ; checkpoint 6: in protected mode, segments reloaded

    ; ---- build minimal 4-level page tables for long mode ----
    ; layout: PML4 @0x1000, PDPT @0x2000, PD @0x3000
    ; PD uses a single 2MB page entry that identity-maps 0-2MB
    ; (enough to cover boot sector, kernel, and stack area).

    mov edi, 0x1000
    mov ecx, 0x3000 / 4          ; clear 0x1000..0x4000
    xor eax, eax
    rep stosd

    mov dword [0x1000], 0x2000 | 0x3   ; PML4[0] -> PDPT (present+rw)
    mov dword [0x1000 + 4], 0

    mov dword [0x2000], 0x3000 | 0x3   ; PDPT[0] -> PD (present+rw)
    mov dword [0x2000 + 4], 0

    mov dword [0x3000], 0x0 | 0x83     ; PD[0] -> 2MB page @0, present+rw+PS(2MB)
    mov dword [0x3000 + 4], 0

    ; ---- load CR3 ----
    mov eax, 0x1000
    mov cr3, eax

    ; ---- enable PAE (CR4 bit 5) ----
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    ; ---- set LME (long mode enable) in EFER MSR (0xC0000080) ----
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    DBG32 6, '7'                   ; checkpoint 7: page tables + PAE + LME set, about to enable paging

    ; ---- enable paging (CR0 bit 31) => activates long mode ----
    mov eax, cr0
    or eax, 1 << 31
    mov cr0, eax

    ; ---- jump into 64-bit code segment ----
    jmp CODE64_SEL:lm_entry

; ============================================================
; 64-bit long mode
; ============================================================
%macro DBG64 2                     ; %1 = column, %2 = char
    mov rdi, 0xB8000 + (0*80 + %1) * 2
    mov byte [rdi], %2
    mov byte [rdi+1], 0x2F         ; white on green
%endmacro

BITS 64
lm_entry:
    mov ax, DATA32_SEL
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov rsp, 0x9F000

    DBG64 7, '8'                   ; checkpoint 8: in long mode, segments reloaded

    mov rax, KERNEL_LOAD_OFF     ; kernel is loaded flat at 0x8000
    jmp rax

; ============================================================
; GDT
; ============================================================
ALIGN 8
gdt32_start:
    dq 0x0000000000000000                     ; null descriptor
CODE32_DESC:
    dw 0xFFFF, 0x0000
    db 0x00, 10011010b, 11001111b, 0x00        ; 32-bit code, base0 limit4G
DATA32_DESC:
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b, 11001111b, 0x00        ; 32-bit data
CODE64_DESC:
    dw 0x0000, 0x0000
    db 0x00, 10011010b, 00100000b, 0x00        ; 64-bit code (L bit set)
gdt32_end:

gdt32_descriptor:
    dw gdt32_end - gdt32_start - 1
    dd gdt32_start

CODE32_SEL equ CODE32_DESC - gdt32_start
DATA32_SEL equ DATA32_DESC - gdt32_start
CODE64_SEL equ CODE64_DESC - gdt32_start

; ============================================================
; pad boot sector to 512 bytes, boot signature
; ============================================================
TIMES 510 - ($ - $$) db 0
DW 0xAA55