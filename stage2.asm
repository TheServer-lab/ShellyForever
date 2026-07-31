; ============================================================
;  ShellyForever  --  stage2.asm
;  Stage-2 bootloader: loaded by boot.asm at 0x0600 in 16-bit real mode.
;  Unlike stage1, this is NOT limited to 512 bytes (build.sh pads it to
;  STAGE2_SECTORS sectors, currently 32 = 16KB), so it can afford a real
;  chunked disk-read loop.
;  1) Chunk-reads the kernel from disk into memory at 0x8000, advancing
;     the destination segment every 64 sectors (32KB) so no single
;     transfer crosses a 64KB real-mode segment window - a single-shot
;     read of the full KERNEL_SECTORS was tested and reliably failed.
;  2) Enables A20, builds a temporary GDT, enters 32-bit protected mode.
;  3) Builds minimal page tables, enables PAE + long mode + paging.
;  4) Far-jumps into 64-bit long mode straight into the kernel entry
;     point at 0x8000.
; ============================================================

BITS 16
ORG 0x0600

; Landing here via boot.asm's far jump lands on the very first byte of
; this file - without this jump we'd fall straight into dbg16 below and
; hit its 'ret' with no return address on the stack, jumping to garbage
; (this is exactly the same hazard boot.asm's own "jmp start" guards
; against for its copy of dbg16).
jmp stage2_start

KERNEL_LOAD_SEG   equ 0x0000
KERNEL_LOAD_OFF   equ 0x8000
; Budget for the USB host-controller driver + exFAT reader being built
; out. Kernel end address (0x8000 + 800*512 = 0x6C000) is still well
; below the EBDA/video-memory region near 0x9FC00-0xA0000.
KERNEL_SECTORS    equ 800
; Must match STAGE2_SECTORS in boot.asm - stage2 occupies LBA 1..32, so
; the kernel starts right after at LBA 33. (Not computed from a shared
; equ since these are two separately-assembled files; build.sh's job is
; to keep stage2.bin padded to exactly this many sectors so the two
; files agree in practice.)
KERNEL_START_LBA  equ 33
BOOT_DRIVE_ADDR   equ 0x0500

; ---- on-screen checkpoint markers - continues stage1's column numbering ----
dbg16:
    mov ax, 0xB800
    mov es, ax
    mov [es:bx], dl
    mov byte [es:bx+1], 0x4F
    ret
%macro DBG16 2                     ; %1 = column, %2 = char
    mov bx, (0*80 + %1) * 2
    mov dl, %2
    call dbg16
%endmacro

stage2_start:
    mov al, [BOOT_DRIVE_ADDR]
    mov [boot_drive], al

    DBG16 2, 'S'                   ; checkpoint: stage2 running

    ; ---- chunked LBA read of the kernel ----
    ; Read in 64-sector (32KB) pieces, advancing the DAP's segment (not
    ; offset - offset always 0) by 32 paragraphs per sector transferred,
    ; so seg:off never comes near a 64KB boundary mid-transfer.
    mov word [sectors_left], KERNEL_SECTORS
    mov word [cur_seg], KERNEL_LOAD_OFF >> 4
    mov word [cur_lba_lo], KERNEL_START_LBA
.chunk_loop:
    mov ax, [sectors_left]
    cmp ax, 0
    je kernel_read_done
    cmp ax, 64
    jbe .have_chunk
    mov ax, 64
.have_chunk:
    mov [dap_count], ax
    mov cx, [cur_seg]
    mov [dap_seg], cx
    mov word [dap_off], 0
    mov cx, [cur_lba_lo]
    mov [dap_lba_lo], cx

    mov si, dap
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc disk_error

    mov cx, [dap_count]          ; sectors just transferred
    sub [sectors_left], cx
    add [cur_lba_lo], cx
    shl cx, 5                    ; paragraphs advanced = sectors * 32
    add [cur_seg], cx
    jmp .chunk_loop

kernel_read_done:
    DBG16 3, 'K'                   ; checkpoint: kernel loaded OK

    cli
    ; ---- enable A20: fast-A20 gate (port 0x92) + 8042 keyboard
    ; controller method, since not every chipset honors 0x92 alone ----
    call enable_a20
    DBG16 4, 'A'

    ; ---- load GDT for protected mode ----
    lgdt [gdt32_descriptor]
    DBG16 5, 'G'

    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp CODE32_SEL:pm_entry     ; far jump flushes prefetch, loads CS

disk_error:
    DBG16 3, 'E'
    cli
    hlt
.hang: jmp .hang

; -------- A20 helpers (unchanged from the original single-stage boot.asm) --------
enable_a20:
    in al, 0x92
    or al, 2
    and al, 0xFE
    out 0x92, al

    call kbd_wait_input
    mov al, 0xAD
    out 0x64, al

    call kbd_wait_input
    mov al, 0xD0
    out 0x64, al

    call kbd_wait_output
    in al, 0x60
    push ax

    call kbd_wait_input
    mov al, 0xD1
    out 0x64, al

    call kbd_wait_input
    pop ax
    or al, 2
    out 0x60, al

    call kbd_wait_input
    mov al, 0xAE
    out 0x64, al

    call kbd_wait_input
    ret

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

boot_drive:   db 0
sectors_left: dw 0
cur_seg:      dw 0
cur_lba_lo:   dw 0

ALIGN 4
dap:
    db 0x10
    db 0
dap_count:
    dw 64
dap_off:
    dw 0
dap_seg:
    dw 0
dap_lba_lo:
    dw 1
    dw 0
    dd 0

; ============================================================
; 32-bit protected mode
; ============================================================
%macro DBG32 2
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

    DBG32 6, 'P'                   ; checkpoint: in protected mode

    ; ---- build minimal 4-level page tables for long mode ----
    ; layout: PML4 @0x1000, PDPT @0x2000, PD @0x3000
    mov edi, 0x1000
    mov ecx, 0x3000 / 4
    xor eax, eax
    rep stosd

    mov dword [0x1000], 0x2000 | 0x3   ; PML4[0] -> PDPT
    mov dword [0x1000 + 4], 0
    mov dword [0x2000], 0x3000 | 0x3   ; PDPT[0] -> PD
    mov dword [0x2000 + 4], 0

    ; PD[0..31] -> 2MB pages, identity-mapping the first 64MB. kernel.asm
    ; extends this further before anything that needs more runs.
    mov edi, 0x3000
    mov eax, 0x83                ; present+rw+PS(2MB)
    mov cl, 32
.fill_pd:
    mov [edi], eax
    add eax, 0x200000
    add edi, 8
    loop .fill_pd

    mov eax, 0x1000
    mov cr3, eax

    mov eax, cr4
    or eax, 1 << 5              ; PAE
    mov cr4, eax

    mov ecx, 0xC0000080         ; EFER
    rdmsr
    or eax, 1 << 8              ; LME
    wrmsr

    DBG32 7, 'L'                   ; checkpoint: page tables + PAE + LME set

    mov eax, cr0
    or eax, 1 << 31              ; enable paging -> activates long mode
    mov cr0, eax

    jmp CODE64_SEL:lm_entry

; ============================================================
; 64-bit long mode
; ============================================================
%macro DBG64 2
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

    DBG64 8, 'X'                   ; checkpoint: in long mode, about to jump

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
