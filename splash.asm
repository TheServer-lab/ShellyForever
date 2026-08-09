; ============================================================
;  ShellyForever  --  splash.asm
;  %include'd by kernel.asm immediately after "BITS 64 / ORG 0x8000", as
;  the very first code in the kernel image (nothing but EQU constants,
;  which emit no bytes, may precede it - boot.asm far-jumps straight to
;  0x8000). Kept as its own file, like party.asm/tcp.asm/http.asm/
;  browse.asm/mouse.asm, because this block is unusually order- and
;  mode-sensitive (mixes 16/32/64-bit code, must be first, has real-mode
;  segment math) and is easiest to review/test/revert in isolation. nasm
;  inlines %include before assembling, so splitting it out here changes
;  nothing about the resulting kernel.bin.
;
;  boot.asm hands off here WHILE STILL IN REAL MODE (see boot.asm's
;  read_done) so BIOS video/keyboard calls are still available for a boot
;  splash. This code then does the A20/GDT/protected-mode/long-mode
;  transition itself (moved here from boot.asm - see boot.asm's
;  read_done for why) and falls into kernel_entry, which is where actual
;  64-bit long-mode execution used to begin directly.
; ============================================================
BITS 16
SPLASH_TICKS equ 55          ; ~3 seconds at the BIOS timer's ~18.2 ticks/sec
splash_stub:
    xor ax, ax
    mov ds, ax
    mov es, ax

    ; ---- VGA mode 13h: 320x200, 256 colors ----
    mov ax, 0x0013
    int 0x10

    ; ---- load the splash's 256-color palette (6-bit-per-channel VGA DAC
    ; values) via BIOS "set block of DAC registers" (AH=10h AL=12h;
    ; BX=start index, CX=count, ES:DX -> table of CX*3 bytes) ----
    mov ax, PALETTE_SEG
    mov es, ax
    mov dx, PALETTE_OFF
    xor bx, bx
    mov cx, 256
    mov ax, 0x1012
    int 0x10

    ; ---- blit the 320x200 indexed image straight into the mode-13h
    ; linear framebuffer at 0xA000:0000 ----
    mov ax, PIXELS_SEG
    mov ds, ax
    mov si, PIXELS_OFF
    mov ax, 0xA000
    mov es, ax
    xor di, di
    mov cx, 320*200
    cld
    rep movsb

    ; ---- hold the splash for ~SPLASH_TICKS ticks, then continue on its
    ; own - no keypress needed. Uses the BIOS timer tick counter (INT 1Ah
    ; AH=00h returns ticks-since-midnight in CX:DX, incrementing at
    ; ~18.2Hz) rather than INT 15h AH=86h's microsecond wait, which is a
    ; single blocking call but is known to be unreliable on some real
    ; BIOSes; polling the tick counter is about as universally supported
    ; as real-mode BIOS gets. Only DX (the low word) is used - at ~18.2
    ; ticks/sec that's good for waits well over an hour before DX itself
    ; wraps, far more than any splash needs. The one edge case is the
    ; midnight rollover, where the BIOS resets the counter to 0 instead of
    ; continuing to increment: the unsigned subtraction below can then
    ; read as a huge elapsed value and exit the wait immediately - i.e.
    ; the splash is cut short, never stuck, so it fails safe.
    mov ah, 0x00
    int 0x1A                     ; dx = current tick count (low word)
    mov si, dx                   ; si = start tick
.splash_wait:
    mov ah, 0x00
    int 0x1A
    sub dx, si                   ; dx = elapsed ticks since start
    cmp dx, SPLASH_TICKS
    jb .splash_wait

    ; ---- back to 80x25 text mode ----
    mov ax, 0x0003
    int 0x10

    xor ax, ax                  ; restore ds (clobbered above for the blit)
    mov ds, ax

    ; ---- same A20/GDT/protected-mode transition boot.asm's read_done used
    ; to do right after loading the kernel ----
    cli
    mov al, 0x02
    out 0x92, al                 ; fast-A20 gate (port 0x92)

    lgdt [gdt32_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE32_SEL:splash_pm32   ; far jump flushes prefetch, loads CS

BITS 32
splash_pm32:
    mov ax, DATA32_SEL
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x9F000

    ; ---- build minimal 4-level page tables for long mode (identical to
    ; boot.asm's old pm_entry - PML4 @0x1000, PDPT @0x2000, PD @0x3000,
    ; identity-mapping the first 64MB with 2MB pages). kernel_entry's
    ; expand_identity_map extends this to 4GB before anything that needs
    ; it (e.g. acpi_shutdown's ACPI table walk) runs. ----
    mov edi, 0x1000
    mov ecx, 0x3000 / 4
    xor eax, eax
    rep stosd

    mov dword [0x1000], 0x2000 | 0x3   ; PML4[0] -> PDPT
    mov dword [0x2000], 0x3000 | 0x3   ; PDPT[0] -> PD

    mov edi, 0x3000
    mov eax, 0x83                ; present+rw+PS(2MB), base 0
    mov cl, 32                   ; 32 * 2MB = 64MB
.fill_pd:
    mov [edi], eax
    add eax, 0x200000
    add edi, 8
    loop .fill_pd

    mov eax, 0x1000
    mov cr3, eax

    mov eax, cr4
    or eax, 1 << 5                ; PAE
    mov cr4, eax

    mov ecx, 0xC0000080            ; EFER
    rdmsr
    or eax, 1 << 8                ; LME
    wrmsr

    mov eax, cr0
    or eax, 1 << 31                ; PG - activates long mode
    mov cr0, eax

    jmp CODE64_SEL:splash_lm64

BITS 64
splash_lm64:
    mov ax, DATA32_SEL
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov rsp, 0x9F000
    jmp kernel_entry

; ---- GDT (moved here from boot.asm - see boot.asm's read_done) ----
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

; ---- splash image data: 320x200 8bpp indexed image + its 256-color
; palette (6-bit-per-channel VGA DAC values), generated from the logo
; artwork. Regenerate both with the conversion script if the logo changes.
; incbin paths are resolved relative to the top-level file nasm was
; invoked on (kernel.asm), not this file - keep both .bin files alongside
; kernel.asm, same as today. ----
ALIGN 16
splash_palette_data: incbin "splash_palette.bin"   ; 256*3 bytes
splash_pixel_data:   incbin "splash_pixels.bin"    ; 320*200 bytes

; nasm's -f bin output won't apply >>/& directly to a label (non-scalar),
; so go through a $$-relative offset + the known ORG base to get a plain
; number first, matching boot.asm's dap_set_buf technique for the same
; real-mode seg:off problem.
PALETTE_ADDR equ 0x8000 + (splash_palette_data - $$)
PIXELS_ADDR  equ 0x8000 + (splash_pixel_data - $$)
PALETTE_SEG equ (PALETTE_ADDR >> 4)
PALETTE_OFF equ (PALETTE_ADDR & 0xF)
PIXELS_SEG  equ (PIXELS_ADDR >> 4)
PIXELS_OFF  equ (PIXELS_ADDR & 0xF)
