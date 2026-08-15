; ============================================================
;  ShellyForever  --  stage2.asm  (formerly splash.asm)
;  Loaded flat by boot.asm at physical 0x8000, in 16-bit real mode, and is
;  now its own top-level assembly (built to stage2.bin), not %include'd
;  into kernel.asm anymore.
;
;  *** RENAMED + EXPANDED (relocating loader rewrite) ***
;  This used to be just the splash screen + the real->protected->long-mode
;  transition, %include'd directly into kernel.asm so the whole thing
;  (splash + transition + OS) was one flat binary loaded below 1MB - which
;  is exactly what capped the kernel at ~1216 sectors (see boot.asm's old
;  comments). Now this file does three jobs instead of two:
;    1) show the splash (unchanged)
;    2) relocate_kernel_body: while still in real mode, read the actual
;       OS (kernel_body.bin, built separately from kernel.asm - see that
;       file's header) off disk in chunks and use BIOS INT 15h/AH=87h
;       ("move block") to copy each chunk up above 1MB to KERNEL_HIGH_BASE,
;       which has no conventional-memory ceiling
;    3) the A20/GDT/protected-mode/long-mode transition (unchanged in
;       spirit, but ends with a jump to KERNEL_HIGH_BASE instead of a
;       same-binary label, since the kernel body is a separate build now)
;
;  boot.asm hands off here WHILE STILL IN REAL MODE so BIOS video/keyboard/
;  disk calls are still available for the splash and for the relocation
;  reads.
; ============================================================

%include "layout.inc"

BITS 16
ORG STAGE2_LOAD_OFF           ; 0x8000 - this is a top-level build now (used
                               ; to inherit ORG 0x8000 from kernel.asm via
                               ; %include; now it needs its own)
SPLASH_TICKS equ 55          ; ~3 seconds at the BIOS timer's ~18.2 ticks/sec
splash_stub:
    xor ax, ax
    mov ds, ax
    mov es, ax

    ; boot.asm reloads dl = boot_drive right before its far jump here, so
    ; capture it immediately - before any BIOS video call gets a chance to
    ; clobber it - into our OWN copy (this is a separate binary from
    ; boot.asm; there is no shared symbol to reach across that boundary,
    ; same reasoning as dbg_local below vs boot.asm's dbg16).
    mov [boot_drive], dl

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

    mov bx, (24*80 + 2) * 2      ; checkpoint 3: splash done, enabling A20
    mov dl, '3'                  ; before anything above 1MB gets touched
    call dbg_local

    ; ---- A20 must be on before relocate_kernel_body below touches
    ; anything above 1MB (INT 15h/AH=87h needs it exactly like paging
    ; would), so this now happens BEFORE the relocation step instead of
    ; right before the GDT load like it used to. ----
    cli
    call enable_a20
    jne .a20_ok
    ; A20 could not be enabled by either method - stop here with a distinct
    ; marker rather than pressing on into a >1MB copy with a gated A20
    ; line, which would silently corrupt memory instead of failing loudly.
    mov bx, (24*80 + 3) * 2
    mov dl, '!'
    call dbg_local
    cli
    hlt
    jmp $
.a20_ok:
    mov bx, (24*80 + 3) * 2      ; checkpoint 4: A20 confirmed on (not just
    mov dl, '4'                  ; "we wrote to port 0x92 and hoped") - see
    call dbg_local                ; enable_a20/test_a20 below

    ; ---- load the real kernel (kernel_body.bin) off disk and relocate it
    ; above 1MB, still in real mode - see relocate_kernel_body below ----
    call relocate_kernel_body

    mov bx, (24*80 + 4) * 2      ; checkpoint 5: kernel body loaded and
    mov dl, '5'                  ; relocated above 1MB
    call dbg_local

    lgdt [gdt32_descriptor]

    mov bx, (24*80 + 5) * 2      ; checkpoint 6: GDT loaded, about to flip
    mov dl, '6'                   ; CR0.PE and far-jump into 32-bit mode
    call dbg_local

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE32_SEL:splash_pm32   ; far jump flushes prefetch, loads CS

; in: bx = byte offset into VGA memory, dl = char to show. Same idea as
; boot.asm's dbg16, but boot.asm and stage2.bin are separate nasm builds
; (boot.asm is ORG 0x7C00, this file is ORG 0x8000) so there is no shared
; symbol to call across that boundary - this is stage2.bin's own copy,
; used only while still in real mode.
dbg_local:
    push ax
    push es
    mov ax, 0xB800
    mov es, ax
    mov [es:bx], dl
    mov byte [es:bx+1], 0x4F
    pop es
    pop ax
    ret

boot_drive: db 0                 ; stage2's own copy - see splash_stub's top

; ============================================================
; relocate_kernel_body: reads kernel_body.bin (LBA KERNEL_BODY_LBA ..
; KERNEL_BODY_LBA+KERNEL_BODY_SECTORS-1) off disk in BIOS-sized sub-chunks
; into the fixed low staging buffer STAGE_BUF, and after each sub-chunk
; read, uses INT 15h/AH=87h ("move block") to copy it from STAGE_BUF up to
; its final position starting at KERNEL_HIGH_BASE. This is the actual fix
; for the reboot loop: the OS no longer has to fit below the 0xA0000 VGA
; hole at all, because it is never resident down there - each chunk is
; only in low memory transiently, between being read off disk and being
; moved up.
;
; INT 15h/AH=87h moves a block of memory using a temporary, BIOS-managed
; switch to protected mode for the duration of a single call, entirely
; from real mode - no permanent mode change, no IDT needed. It takes
; ES:SI -> a 6-descriptor (48-byte) GDT-shaped structure: descriptors 0,
; 1, 4, 5 must be zeroed by the caller (the BIOS uses/fills them
; internally); descriptor 2 describes the source block, descriptor 3 the
; destination block (each: word limit, word base<0:15>, byte base<16:23>,
; byte access=0x93 [present, ring0, r/w data], word reserved=0 - the base
; field is only 24 bits, so this call can only reach up to 16MB, which is
; not a real constraint here since KERNEL_HIGH_BASE=2MB and the kernel is
; well under a few MB). CX = word count, max 8000h (32K words = 64KB) -
; each sub-chunk below is well under that ceiling.
;
; This has been a standard AT-class BIOS service since 1984 (it predates
; XMS, which is built on top of it) - SeaBIOS (QEMU/Bochs) and every real
; BIOS since support it, so no fallback path is provided for it the way
; there is for missing INT 13h extensions.
; ============================================================
relocate_kernel_body:
    ; ---- detect INT 13h extensions once, same check boot.asm makes ----
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc .chs_mode
    cmp bx, 0xAA55
    jne .chs_mode
    mov byte [reloc_read_mode], 0x42
    jmp .init
.chs_mode:
    mov byte [reloc_read_mode], 0x02
.init:
    mov word [reloc_lba], KERNEL_BODY_LBA
    mov word [reloc_lba+2], 0
    mov word [reloc_remaining], KERNEL_BODY_SECTORS
    mov dword [reloc_dest], KERNEL_HIGH_BASE

.loop:
    cmp word [reloc_remaining], 0
    je .done

    cmp byte [reloc_read_mode], 0x02
    je .chs_read

    ; ---- LBA extended read: up to 63 sectors per BIOS call (picky-BIOS
    ; friendly cap, same as boot.asm), into STAGE_BUF:0000 ----
    mov ax, [reloc_remaining]
    cmp ax, 63
    jbe .lba_have_size
    mov ax, 63
.lba_have_size:
    mov [reloc_sub_count], ax
    mov word [dap_count], ax
    mov word [dap_off], 0
    mov word [dap_seg], STAGE_BUF_SEG
    mov ax, [reloc_lba]
    mov [dap_lba], ax
    mov ax, [reloc_lba+2]
    mov [dap_lba+2], ax
    mov word [dap_lba+4], 0
    mov word [dap_lba+6], 0
    mov si, dap
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc .disk_fail
    jmp .have_chunk

.chs_read:
    ; ---- CHS fallback: compute cyl/head/sector from the running LBA
    ; (2 heads, 18 sectors/track - same legacy floppy-style geometry
    ; boot.asm's old CHS path assumed), and cap this call so it never
    ; crosses a track boundary. Recomputed fresh every call instead of
    ; incrementally stepped, since relocate_kernel_body (unlike boot.asm's
    ; old CHS path) doesn't start at LBA 0. ----
    mov ax, [reloc_lba]           ; sectors run this high (<65536) for any
                                   ; realistic kernel size, so the 16-bit
                                   ; halves of reloc_lba are enough here
    xor dx, dx
    mov bx, 18
    div bx                        ; ax = track = cyl*2+head, dx = sector-1
    mov [chs_sector0], dl         ; 0-based sector-in-track, used for capping
    inc dx
    mov [chs_sector], dl          ; 1-based sector number (BIOS convention)
    xor dx, dx
    mov bx, 2
    div bx                        ; ax = cylinder, dx = head
    mov [chs_cyl], ax
    mov [chs_head], dl

    mov ax, 18
    sub al, [chs_sector0]         ; sectors left in this track
    cmp ax, [reloc_remaining]
    jbe .chs_have_size
    mov ax, [reloc_remaining]
.chs_have_size:
    mov [reloc_sub_count], ax

    mov ax, STAGE_BUF_SEG
    mov es, ax
    xor bx, bx
    mov al, [reloc_sub_count]
    mov ah, 0x02
    mov ch, [chs_cyl]
    mov cl, [chs_sector]
    mov dh, [chs_head]
    mov dl, [boot_drive]
    int 0x13
    jc .disk_fail

.have_chunk:
    ; ---- move this sub-chunk from STAGE_BUF up to [reloc_dest] ----
    movzx ecx, word [reloc_sub_count]
    shl ecx, 8                    ; sectors * 512 / 2 = sectors * 256 = word count
    call reloc_move
    jc .move_fail

    ; ---- advance LBA, remaining count, and destination pointer ----
    movzx eax, word [reloc_sub_count]
    add [reloc_lba], eax
    adc word [reloc_lba+2], 0
    sub [reloc_remaining], ax
    shl eax, 9                    ; sectors * 512 bytes
    add [reloc_dest], eax
    jmp .loop

.done:
    ret

.disk_fail:
    ; same column checkpoint 5 (relocation done) would have used on
    ; success - mutually exclusive with it, same pattern as A20's '4'/'!'
    mov bx, (24*80 + 4) * 2
    mov dl, 'R'                   ; distinct from boot.asm's 'E': this is a
    call dbg_local                ; kernel-body read failure, not stage2's own
    cli
    hlt
    jmp $

.move_fail:
    mov bx, (24*80 + 4) * 2
    mov dl, 'M'                   ; INT 15h/AH=87h reported an error - see
    call dbg_local                ; its AH return code convention above
    cli
    hlt
    jmp $

reloc_read_mode: db 0             ; 0x42 = LBA read, 0x02 = CHS read
reloc_lba:       dd 0             ; current source LBA (low32; kernel images
                                   ; realistically never reach the high dword)
reloc_remaining: dw 0             ; sectors left to move
reloc_sub_count: dw 0             ; sectors in the sub-chunk just read
reloc_dest:      dd 0             ; current destination physical address
chs_cyl:         dw 0
chs_head:        db 0
chs_sector:      db 0
chs_sector0:     db 0

STAGE_BUF_SEG equ (STAGE_BUF >> 4)

; ---- Disk Address Packet for INT 13h AH=42h (LBA extended read), used by
; relocate_kernel_body's LBA path. Separate from boot.asm's own dap - two
; different binaries, no shared symbol across that boundary (same reason
; as dbg_local/boot_drive above). ----
ALIGN 4
dap:
    db 0x10
    db 0
dap_count: dw 0
dap_off:   dw 0
dap_seg:   dw 0
dap_lba:   dq 0

; ============================================================
; reloc_move: move ecx words from STAGE_BUF to [reloc_dest] via BIOS
; INT 15h/AH=87h. See relocate_kernel_body's header comment for the GDT
; shape this call requires.
; in: ecx = word count (<= 0x1FC0 here - 63 sectors' worth - well under
;     the 8000h/32K-word ceiling)
; out: CF set on failure (distinct 'M' checkpoint + hang by the caller)
; ============================================================
reloc_move:
    push ax
    push cx
    push si

    ; patch the destination descriptor's base address from reloc_dest
    mov eax, [reloc_dest]
    mov [reloc_gdt_dst + 2], ax
    shr eax, 16
    mov [reloc_gdt_dst + 4], al

    ; cx already holds the word count the caller computed in ecx (caller
    ; guarantees it fits in 16 bits - max 63 sectors' worth per call)
    xor ax, ax
    mov es, ax
    mov si, reloc_gdt
    mov ah, 0x87
    int 0x15                      ; CF/AH set per relocate_kernel_body's header

    pop si
    pop cx
    pop ax
    ret

; ---- the 6-descriptor (48-byte) structure INT 15h/AH=87h requires - see
; relocate_kernel_body's header comment for the exact field meanings and
; why descriptors 0/1/4/5 are left zeroed. ----
ALIGN 8
reloc_gdt:
    times 8 db 0                            ; [0] dummy - caller zeroes
    times 8 db 0                            ; [1] GDT self-desc - caller zeroes, BIOS fills
reloc_gdt_src:
    dw 0xFFFF                               ; limit (generous; only needs to
                                             ; cover the largest single move)
    dw (STAGE_BUF & 0xFFFF)                 ; base bits 0-15
    db ((STAGE_BUF >> 16) & 0xFF)            ; base bits 16-23
    db 0x93                                 ; present, ring0, data, r/w
    dw 0
reloc_gdt_dst:
    dw 0xFFFF                               ; limit
    dw 0                                    ; base bits 0-15  - patched per call
    db 0                                    ; base bits 16-23 - patched per call
    db 0x93
    dw 0
    times 8 db 0                            ; [4] protected-mode CS - caller zeroes, BIOS fills
    times 8 db 0                            ; [5] protected-mode SS - caller zeroes, BIOS fills

; ---- A20 gate: enable, then VERIFY, instead of writing to port 0x92 and
; just hoping. Fast-A20 (port 0x92) is widely supported but not universal -
; some real chipsets ignore it, need a brief settle delay, or need the
; legacy PS/2 keyboard-controller method instead. QEMU/Bochs accept the
; fast-A20 write unconditionally and immediately, which is exactly the kind
; of gap that boots fine in an emulator and hangs/corrupts on real hardware:
; with A20 still gated, every physical address above 1MB silently aliases
; back down to (addr - 1MB), which does not break anything while splash_stub
; itself is only touching addresses below 1MB, but would corrupt memory the
; moment relocate_kernel_body starts moving data above 1MB (or, previously,
; the moment the identity-mapped kernel started using extended RAM).
; out: ZF=1 if A20 could not be enabled by either method (caller hangs)
enable_a20:
    call test_a20
    jne .done                     ; already on - some BIOSes enable it for you
    mov al, 0x02
    out 0x92, al                  ; fast-A20 gate
    call test_a20
    jne .done
    call a20_kbc                  ; fall back to the PS/2 keyboard controller
    call test_a20
.done:
    ret

; classic A20 test: 0000:0500 and FFFF:0510 address the same byte
; (physical 0x100500) when A20 is disabled, and different bytes when it's
; enabled. Returns ZF=1 (equal => A20 OFF) or ZF=0 (different => A20 ON).
test_a20:
    push ax
    push es
    push ds
    xor ax, ax
    mov ds, ax
    mov byte [0x0500], 0x00
    mov ax, 0xFFFF
    mov es, ax
    mov byte [es:0x0510], 0xFF
    mov al, [0x0500]
    cmp al, 0xFF
    pop ds
    pop es
    pop ax
    ret

; legacy PS/2 keyboard-controller A20 enable (the pre-Fast-A20 method every
; real PS/2-compatible chipset supports): disable keyboard, read the
; controller's output port, set bit 1 (A20), write it back, re-enable.
a20_kbc:
    call kbc_wait_input
    mov al, 0xAD                  ; disable keyboard
    out 0x64, al
    call kbc_wait_input
    mov al, 0xD0                  ; command: read output port
    out 0x64, al
    call kbc_wait_output
    in al, 0x60
    push ax
    call kbc_wait_input
    mov al, 0xD1                  ; command: write output port
    out 0x64, al
    call kbc_wait_input
    pop ax
    or al, 2                      ; set A20 bit
    out 0x60, al
    call kbc_wait_input
    mov al, 0xAE                  ; re-enable keyboard
    out 0x64, al
    call kbc_wait_input
    ret

kbc_wait_input:                   ; wait until it's safe to write a command/data
    in al, 0x64
    test al, 2
    jnz kbc_wait_input
    ret

kbc_wait_output:                  ; wait until a byte is ready to read
    in al, 0x64
    test al, 1
    jz kbc_wait_output
    ret

BITS 32
splash_pm32:
    mov ax, DATA32_SEL
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x9F000

    ; checkpoint 7: landed in 32-bit protected mode. Flat linear write, no
    ; segment juggling needed now that DATA32_SEL is a 4GB flat descriptor.
    mov byte [0xB8000 + (24*80 + 6) * 2], '7'
    mov byte [0xB8000 + (24*80 + 6) * 2 + 1], 0x4F

    ; ---- build minimal 4-level page tables for long mode (PML4 @0x1000,
    ; PDPT @0x2000, PD @0x3000, identity-mapping the first 64MB with 2MB
    ; pages - unchanged by this rewrite). This already covers
    ; KERNEL_HIGH_BASE (2MB), so the far jump below to KERNEL_HIGH_BASE
    ; works correctly even before kernel_entry's expand_identity_map
    ; extends this to a full 4GB map. ----
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

    ; no extra checkpoint here on purpose - kernel_entry's checkpoint 'A'
    ; (col 6) is the very next thing that runs after splash_lm64's jump, so
    ; it already confirms this far jump into 64-bit mode landed correctly.
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
    ; kernel_entry now lives in the separately-built kernel_body.bin,
    ; relocated above 1MB by relocate_kernel_body - jump to its known
    ; fixed load address instead of a same-binary label. kernel.asm's
    ; ORG KERNEL_HIGH_BASE plus kernel_entry being the first thing after
    ; that ORG (no code between them - only equ constants, which emit no
    ; bytes) means kernel_entry is always exactly at KERNEL_HIGH_BASE.
    jmp KERNEL_HIGH_BASE

; ---- GDT (unchanged by this rewrite) ----
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
; invoked on (stage2.asm, now - it used to be kernel.asm before this file
; became its own top-level build), so keep both .bin files alongside
; whichever file is invoked. ----
ALIGN 16
splash_palette_data: incbin "splash_palette.bin"   ; 256*3 bytes
splash_pixel_data:   incbin "splash_pixels.bin"    ; 320*200 bytes

; nasm's -f bin output won't apply >>/& directly to a label (non-scalar),
; so go through a $$-relative offset + the known ORG base to get a plain
; number first, matching boot.asm's old dap_set_buf technique for the same
; real-mode seg:off problem.
PALETTE_ADDR equ STAGE2_LOAD_OFF + (splash_palette_data - $$)
PIXELS_ADDR  equ STAGE2_LOAD_OFF + (splash_pixel_data - $$)
PALETTE_SEG equ (PALETTE_ADDR >> 4)
PALETTE_OFF equ (PALETTE_ADDR & 0xF)
PIXELS_SEG  equ (PIXELS_ADDR >> 4)
PIXELS_OFF  equ (PIXELS_ADDR & 0xF)
