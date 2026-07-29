; ============================================================
; Real-mode keyboard trampoline
; Assembled with ORG 0x7000, copied there by init_real_mode.
; ============================================================

[ORG 0x7000]

CODE32_SEL  equ 0x08
DATA32_SEL  equ 0x10
CODE16_SEL  equ 0x18
DATA16_SEL  equ 0x20
CODE64_SEL  equ 0x28

; =====================================================
; DATA SECTION
; =====================================================

; --- GDT (0x0000, 48 bytes) ---
dq 0                          ; NULL
dq 0x00CF9A000000FFFF         ; CODE32
dq 0x00CF92000000FFFF         ; DATA32
dq 0x00009A000000FFFF         ; CODE16
dq 0x000092000000FFFF         ; DATA16
dq 0x00209A0000000000         ; CODE64

; --- GDTR (0x0030, 6 bytes) ---
gdt_desc: dw 47
          dd 0x7000

; --- ret_addr (0x0036, 8 bytes) ---
ret_addr: dq 0

; --- ret_val (0x003E, 2 bytes) ---
ret_val: dw 0

; --- pml4_addr (0x0040, 8 bytes) ---
pml4_addr: dq 0

; --- Far jump targets (offsets relative to 0x7000) ---

; pm16_jmp at 0x0048: dd offset32, dw sel16  (used in BITS 32)
pm16_jmp: dd 0, 0

; rm16_jmp at 0x004E: dw offset16, dw seg16  (used in BITS 16)
rm16_jmp: dw 0, 0

; pm32ret_jmp at 0x0052: dw offset16, dw sel16  (used in BITS 16)
pm32ret_jmp: dw 0, 0

; lm64_jmp at 0x0056: dd offset32, dw sel16  (used in BITS 32)
lm64_jmp: dd 0, 0

; pm32_off at 0x005C: dd offset32  (for push+retfq from BITS 64)
pm32_off: dd 0

; --- Saved GP registers (0x0060-0x00DF, 128 bytes) ---
saved_regs:
r_save_rax: dq 0
r_save_rcx: dq 0
r_save_rdx: dq 0
r_save_rbx: dq 0
r_save_rsp: dq 0
r_save_rbp: dq 0
r_save_rsi: dq 0
r_save_rdi: dq 0
r_save_r8:  dq 0
r_save_r9:  dq 0
r_save_r10: dq 0
r_save_r11: dq 0
r_save_r12: dq 0
r_save_r13: dq 0
r_save_r14: dq 0
r_save_r15: dq 0

; --- Stack space (0x00E0, 256 bytes) ---
stack_bot: times 256 db 0
stack_top:

; =====================================================
; CODE SECTION — starts at file offset 0x01E0
; =====================================================

; =============================================
[BITS 64]
entry64:

    pop qword [ret_addr]

    mov [r_save_rax], rax
    mov [r_save_rcx], rcx
    mov [r_save_rdx], rdx
    mov [r_save_rbx], rbx
    mov [r_save_rsp], rsp
    mov [r_save_rbp], rbp
    mov [r_save_rsi], rsi
    mov [r_save_rdi], rdi
    mov [r_save_r8],  r8
    mov [r_save_r9],  r9
    mov [r_save_r10], r10
    mov [r_save_r11], r11
    mov [r_save_r12], r12
    mov [r_save_r13], r13
    mov [r_save_r14], r14
    mov [r_save_r15], r15

    lea rsp, [stack_top]

    lgdt [gdt_desc]
    cli

    mov eax, [pm32_off]
    push CODE32_SEL
    push rax
    retfq

; =============================================
[BITS 32]
pmode32_entry:

    mov eax, cr0
    and eax, 0x7FFFFFFF
    mov cr0, eax

    mov ecx, 0xC0000080
    rdmsr
    and eax, ~(1 << 8)
    wrmsr

    jmp far [pm16_jmp]

; =============================================
[BITS 16]
pmode16_entry:

    mov eax, cr0
    and eax, 0xFFFFFFFE
    mov cr0, eax

    jmp far [rm16_jmp]

realmode_entry:

    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x71E0

    sti
    mov ah, 0x00
    int 0x16
    cli

    mov [ret_val], ax

    mov eax, cr0
    or al, 1
    mov cr0, eax

    jmp far [pm32ret_jmp]

; =============================================
[BITS 32]
pmode32_ret:

    mov ax, DATA32_SEL
    mov ds, ax
    mov es, ax
    mov ss, ax

    mov eax, cr4
    or eax, (1 << 5)
    mov cr4, eax

    mov eax, [pml4_addr]
    mov cr3, eax

    mov ecx, 0xC0000080
    rdmsr
    or eax, (1 << 8)
    wrmsr

    mov eax, cr0
    or eax, (1 << 31)
    mov cr0, eax

    jmp far [lm64_jmp]

; =============================================
[BITS 64]
longmode_ret:

    mov rax, [r_save_rsp]
    mov rsp, rax

    mov rax, [r_save_rax]
    mov rcx, [r_save_rcx]
    mov rdx, [r_save_rdx]
    mov rbx, [r_save_rbx]
    mov rbp, [r_save_rbp]
    mov rsi, [r_save_rsi]
    mov rdi, [r_save_rdi]
    mov r8,  [r_save_r8]
    mov r9,  [r_save_r9]
    mov r10, [r_save_r10]
    mov r11, [r_save_r11]
    mov r12, [r_save_r12]
    mov r13, [r_save_r13]
    mov r14, [r_save_r14]
    mov r15, [r_save_r15]

    mov ax, [ret_val]

    push qword [ret_addr]
    ret

; =====================================================
; Offset table — read by init_real_mode
; =====================================================
offset_table:
dd entry64 - 0x7000
dd pmode32_entry - 0x7000
dd pmode16_entry - 0x7000
dd realmode_entry - 0x7000
dd pmode32_ret - 0x7000
dd longmode_ret - 0x7000

trampoline_end: