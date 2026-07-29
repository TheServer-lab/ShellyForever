; ============================================================
;  Shelly OS — Kernel
;
;  Loaded by boot.asm at physical address 0x10000, still in
;  16-bit real mode. This file:
;
;    1. (16-bit) enables A20, loads a 32-bit GDT, enters
;       protected mode
;    2. (32-bit) builds identity-mapped page tables, enables
;       PAE + long mode + paging, loads a 64-bit GDT, enters
;       long mode
;    3. (64-bit) runs kernel_main: prints a banner and starts
;       the "rush" shell, which supports one command:
;
;           show "some text"   ->   prints: some text
; ============================================================

[BITS 16]
[ORG 0x10000]

start16:
    cli
    mov ax, 0x1000
    mov ds, ax
    mov es, ax
    xor ax, ax
    mov ss, ax
    mov sp, 0x7C00          ; boot sector's memory is free now, use it as stack

    call enable_a20

    lgdt [gdt32_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp dword CODE_SEG32:protected_mode_init

enable_a20:
    in al, 0x92
    or al, 2
    out 0x92, al
    ret

; ------------------------------------------------------------
[BITS 32]
protected_mode_init:
    mov ax, DATA_SEG32
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    call setup_paging

    ; Enable PAE (CR4 bit 5)
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    ; Load PML4 physical address into CR3
    mov eax, pml4_table
    mov cr3, eax

    ; Enable long mode (EFER.LME, MSR 0xC0000080 bit 8)
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    ; Enable paging (CR0 bit 31) -- this activates long mode
    mov eax, cr0
    or eax, 1 << 31
    mov cr0, eax

    lgdt [gdt64_descriptor]
    jmp CODE_SEG64:long_mode_init

; ------------------------------------------------------------
; Build a minimal page table set that identity-maps the first
; 16MB of physical memory using 2MB pages:
;   PML4[0] -> PDPT
;   PDPT[0] -> PD
;   PD[0..7] -> eight 2MB pages covering 0..16MB
; ------------------------------------------------------------
setup_paging:
    ; zero out the three tables (3 * 4096 bytes = 3072 dwords)
    mov edi, pml4_table
    mov ecx, 3072
    xor eax, eax
    rep stosd

    mov eax, pdpt_table
    or eax, 0x03            ; present + writable
    mov [pml4_table], eax

    mov eax, pd_table
    or eax, 0x03
    mov [pdpt_table], eax

    xor ecx, ecx
.map_entry:
    mov eax, 0x200000       ; 2MB
    mul ecx                 ; eax = 2MB * ecx
    or eax, 0x83            ; present + writable + page-size(2MB)
    mov [pd_table + ecx*8], eax
    inc ecx
    cmp ecx, 8              ; 8 entries * 2MB = 16MB mapped
    jl .map_entry
    ret

; ------------------------------------------------------------
[BITS 64]
long_mode_init:
    mov ax, DATA_SEG64
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov rsp, 0x90000

    jmp kernel_main

; ============================================================
;  Descriptor tables
; ============================================================
align 8
gdt32_start:
    dq 0x0000000000000000                  ; null descriptor
gdt32_code:
    dw 0xFFFF, 0x0000
    db 0x00, 10011010b, 11001111b, 0x00    ; 32-bit code, base 0, limit 4GB
gdt32_data:
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b, 11001111b, 0x00    ; 32-bit data, base 0, limit 4GB
gdt32_end:

gdt32_descriptor:
    dw gdt32_end - gdt32_start - 1
    dd gdt32_start

CODE_SEG32 equ gdt32_code - gdt32_start
DATA_SEG32 equ gdt32_data - gdt32_start

align 8
gdt64_start:
    dq 0x0000000000000000
gdt64_code:
    dq 0x00209A0000000000                  ; 64-bit code segment
gdt64_data:
    dq 0x0000920000000000                  ; 64-bit data segment
gdt64_end:

gdt64_descriptor:
    dw gdt64_end - gdt64_start - 1
    dq gdt64_start

CODE_SEG64 equ gdt64_code - gdt64_start
DATA_SEG64 equ gdt64_data - gdt64_start

; ============================================================
;  Page tables (must be page-aligned)
; ============================================================
align 4096
pml4_table: times 4096 db 0
pdpt_table: times 4096 db 0
pd_table:   times 4096 db 0


; ============================================================
;  ============  64-BIT KERNEL STARTS HERE  =================
; ============================================================

VGA_MEMORY   equ 0xB8000
VGA_COLS     equ 80
VGA_ROWS     equ 25
WHITE_ON_BLACK equ 0x0F
RED_ON_BLACK   equ 0x04

LINE_BUF_LEN equ 256

kernel_main:
    call clear_screen

    lea rsi, [rel banner1]
    call print_string
    lea rsi, [rel banner2]
    call print_string
    lea rsi, [rel banner3]
    call print_string
    lea rsi, [rel banner4]
    call print_string

    call init_real_mode
    call fs_load
    call user_load
    call init_keyboard

shell_loop:
    call build_path
    lea rsi, [rel prompt_prefix]
    call print_string
    lea rsi, [rel path_buf]
    call print_string
    lea rsi, [rel prompt_suffix]
    call print_string

    lea rdi, [rel line_buffer]
    call read_line

    lea rsi, [rel line_buffer]
    call exec_line

    jmp shell_loop

; ============================================================
;  run_command(rdi = pointer to null-terminated input line)
;
;  Supported syntax:
;      show "text"
;
;  Anything else -> "rush: command not found"
; ============================================================
run_command:
    push rbx
    push rsi
    push rdi

    ; skip leading spaces
    call skip_spaces

    ; empty line -> do nothing
    mov al, [rdi]
    cmp al, 0
    je .done

    ; compare against "reg"
    mov rsi, rdi
    lea rbx, [rel cmd_reg]
    call str_starts_with
    cmp al, 1
    je .do_reg

    ; compare against "login"
    mov rsi, rdi
    lea rbx, [rel cmd_login]
    call str_starts_with
    cmp al, 1
    je .do_login

    ; compare against "help"
    mov rsi, rdi
    lea rbx, [rel cmd_help]
    call str_starts_with
    cmp al, 1
    je .do_help

    ; compare against "me"
    mov rsi, rdi
    lea rbx, [rel cmd_me]
    call str_starts_with
    cmp al, 1
    je .do_me

    ; compare against "auth"
    mov rsi, rdi
    lea rbx, [rel cmd_auth]
    call str_starts_with
    cmp al, 1
    je .do_auth

    ; compare against "show"
    mov rsi, rdi
    lea rbx, [rel cmd_show]
    call str_starts_with
    cmp al, 1
    je .do_show

    ; compare against "calc"
    mov rsi, rdi
    lea rbx, [rel cmd_calc]
    call str_starts_with
    cmp al, 1
    je .do_calc

    ; compare against "mkf"
    mov rsi, rdi
    lea rbx, [rel cmd_mkf]
    call str_starts_with
    cmp al, 1
    je .do_mkf

    ; compare against "cf"
    mov rsi, rdi
    lea rbx, [rel cmd_cf]
    call str_starts_with
    cmp al, 1
    je .do_cf

    ; compare against "list"
    mov rsi, rdi
    lea rbx, [rel cmd_list]
    call str_starts_with
    cmp al, 1
    je .do_ls

    ; compare against "mkfl"
    mov rsi, rdi
    lea rbx, [rel cmd_mkfl]
    call str_starts_with
    cmp al, 1
    je .do_mkfl

    ; compare against "logout"
    mov rsi, rdi
    lea rbx, [rel cmd_logout]
    call str_starts_with
    cmp al, 1
    je .do_logout

    ; compare against "wipe"
    mov rsi, rdi
    lea rbx, [rel cmd_wipe]
    call str_starts_with
    cmp al, 1
    je .do_wipe

    ; compare against "edit"
    mov rsi, rdi
    lea rbx, [rel cmd_edit]
    call str_starts_with
    cmp al, 1
    je .do_edit

    ; compare against "open"
    mov rsi, rdi
    lea rbx, [rel cmd_open]
    call str_starts_with
    cmp al, 1
    je .do_open

    ; compare against "task"
    mov rsi, rdi
    lea rbx, [rel cmd_task]
    call str_starts_with
    cmp al, 1
    je .do_task

    ; check for variable assignment (name = value)
    call try_var_set
    cmp al, 1
    je .done

    ; unknown command
    lea rsi, [rel err_unknown]
    call print_string
    jmp .done

.do_reg:
    add rdi, 3                   ; skip "reg"
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .reg_syntax
    call user_register
    jmp .done

.reg_syntax:
    lea rsi, [rel err_reg_syntax]
    call print_string
    jmp .done

.do_login:
    add rdi, 5                   ; skip "login"
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .login_syntax
    call user_login
    jmp .done

.login_syntax:
    lea rsi, [rel err_login_syntax]
    call print_string
    jmp .done

.do_help:
    lea rsi, [rel help_text]
    call print_string
    jmp .done

.do_me:
    call user_whoami
    jmp .done

.do_auth:
    add rdi, 4                   ; skip "auth"
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .auth_syntax
    call user_auth
    jmp .done

.auth_syntax:
    lea rsi, [rel err_auth_syntax]
    call print_string
    jmp .done

.do_show:
    add rdi, 4
    call skip_spaces

    mov al, [rdi]
    cmp al, '"'
    je .show_quoted

    ; no quote — show variable value
    lea rsi, [rel token_buf]
    push rdi
    call copy_token
    pop rdi
    lea rsi, [rel token_buf]
    call var_get
    cmp rsi, 0
    je .show_var_nf
    call print_string
    call newline
    jmp .done

.show_var_nf:
    lea rsi, [rel err_var_nf]
    call print_string
    jmp .done

.show_quoted:
    inc rdi                      ; skip opening quote
    mov rsi, rdi
.print_loop:
    mov al, [rsi]
    cmp al, 0
    je .missing_quote
    cmp al, '"'
    je .close_found
    cmp al, '{'
    je .interpolate
    call putchar
    inc rsi
    jmp .print_loop

.interpolate:
    inc rsi                      ; skip {
    lea rdi, [rel token_buf]
    xor rcx, rcx
.copy_var:
    mov al, [rsi]
    cmp al, 0
    je .close_found
    cmp al, '}'
    je .end_var
    cmp rcx, 15
    jge .skip_var
    mov [rdi+rcx], al
    inc rcx
    inc rsi
    jmp .copy_var
.end_var:
    mov byte [rdi+rcx], 0
    inc rsi                      ; skip }
    push rsi
    lea rsi, [rel token_buf]
    call var_get
    cmp rsi, 0
    je .print_loop
    call print_string
    pop rsi
    jmp .print_loop

.skip_var:
    inc rsi
    mov al, [rsi]
    cmp al, '}'
    jne .skip_var
    inc rsi
    jmp .print_loop

.close_found:
    call newline
    jmp .done

.missing_quote:
    lea rsi, [rel err_syntax]
    call print_string
    jmp .done

.do_calc:
    add rdi, 4
    call skip_spaces
    call calc_expr                 ; rax = result, rdi advanced

    call skip_spaces
    mov al, [rdi]
    cmp al, '~'
    jne .calc_print

    inc rdi
    call skip_spaces
    lea rsi, [rel token_buf]
    call copy_token

    push rax
    lea rdi, [rel num_buf]
    add rdi, 63
    mov byte [rdi], 0
    pop rax
    mov rbx, rax
    cmp rbx, 0
    jne .calc_convert
    dec rdi
    mov byte [rdi], '0'
    jmp .calc_store
.calc_convert:
    mov rcx, 10
    mov rax, rbx
.calc_digits:
    xor rdx, rdx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    cmp rax, 0
    jne .calc_digits
.calc_store:
    push rdi
    lea rsi, [rel token_buf]
    pop rdi
    call var_set
    jmp .done

.calc_print:
    call print_int
    call newline
    jmp .done

.do_mkf:
    add rdi, 3                   ; skip "mkf"
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .mkf_syntax_error
    call fs_make_folder
    jmp .done

.mkf_syntax_error:
    lea rsi, [rel err_mkf_syntax]
    call print_string
    jmp .done

.do_cf:
    add rdi, 2                   ; skip "cf"
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .cf_syntax_error
    call fs_change_dir
    jmp .done

.cf_syntax_error:
    lea rsi, [rel err_cf_syntax]
    call print_string
    jmp .done

.do_ls:
    call fs_list_dir
    jmp .done

.do_mkfl:
    add rdi, 4                   ; skip "mkfl"
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .mkfl_syntax_error
    call fs_make_file
    jmp .done

.mkfl_syntax_error:
    lea rsi, [rel err_mkfl_syntax]
    call print_string
    jmp .done

.do_logout:
    mov byte [rel logged_in], 0
    lea rsi, [rel msg_logout_ok]
    call print_string
    jmp .done

.do_wipe:
    call clear_screen
    jmp .done

.do_edit:
    add rdi, 4
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .edit_syntax
    call edit_file
    jmp .done

.edit_syntax:
    lea rsi, [rel err_edit_syntax]
    call print_string
    jmp .done

.do_open:
    add rdi, 4
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .open_syntax
    call open_file
    jmp .done

.open_syntax:
    lea rsi, [rel err_open_syntax]
    call print_string
    jmp .done

.do_task:
    add rdi, 4
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .task_syntax
    call exec_script
    jmp .done

.task_syntax:
    lea rsi, [rel err_task_syntax]
    call print_string
    jmp .done

.done:
    pop rdi
    pop rsi
    pop rbx
    ret

; ------------------------------------------------------------
; exec_line(rsi = pointer to null-terminated line)
; Splits on ; and runs each command segment in sequence.
; ------------------------------------------------------------
exec_line:
    push rsi
    push rdi
    push rcx

.outer_loop:
    mov al, [rsi]
    cmp al, ' '
    jne .start_seg
    inc rsi
    jmp .outer_loop

.start_seg:
    mov al, [rsi]
    cmp al, 0
    je .done

    lea rdi, [rel cmd_buf]
.copy_loop:
    mov al, [rsi]
    cmp al, 0
    je .copy_done
    cmp al, ';'
    je .copy_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .copy_loop

.copy_done:
    mov byte [rdi], 0

    cmp byte [rsi], ';'
    jne .run_it
    inc rsi

.run_it:
    lea rdi, [rel cmd_buf]
    push rsi
    call run_command
    pop rsi
    jmp .outer_loop

.done:
    pop rcx
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------
;  Variable system
; ------------------------------------------------------------

VAR_MAX equ 16
VAR_NAME_LEN equ 16
VAR_VALUE_LEN equ 64
VAR_ENTRY_SIZE equ 80   ; name[16] + value[64]

; var_find(rsi = name) -> rax = index or -1
var_find:
    push rbx
    push rcx
    push rdi
    push rsi

    xor rcx, rcx
.loop:
    cmp rcx, VAR_MAX
    jge .notfound

    lea rdi, [rel var_table]
    mov rax, rcx
    imul rax, VAR_ENTRY_SIZE
    add rdi, rax

    cmp byte [rdi], 0
    je .next

    mov rbx, rdi
    call str_equal
    cmp al, 1
    je .found

.next:
    inc rcx
    jmp .loop

.found:
    mov rax, rcx
    jmp .out
.notfound:
    mov rax, -1
.out:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; var_set(rsi = name, rdi = value) — create or update variable
var_set:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; check if variable exists
    push rsi
    push rdi
    call var_find
    pop rdi
    pop rsi
    cmp rax, -1
    jne .update

    ; find free slot
    xor rcx, rcx
.find_free:
    cmp rcx, VAR_MAX
    jge .full
    lea rdx, [rel var_table]
    mov rax, rcx
    imul rax, VAR_ENTRY_SIZE
    add rdx, rax
    cmp byte [rdx], 0
    je .slot_found
    inc rcx
    jmp .find_free

.slot_found:
    ; rdx = entry, rsi = name, rdi = value
    push rcx
    push rdi
    mov rdi, rdx
    call copy_str_no_nul
    mov byte [rdi], 0
    pop rdi
    pop rcx
    ; now write value at entry + VAR_NAME_LEN
    lea rdx, [rel var_table]
    mov rax, rcx
    imul rax, VAR_ENTRY_SIZE
    add rdx, rax
    add rdx, VAR_NAME_LEN
    push rcx
    push rsi
    mov rsi, rdi           ; value source
    mov rdi, rdx           ; value dest
    call copy_str_no_nul
    mov byte [rdi], 0
    pop rsi
    pop rcx
    jmp .done

.update:
    ; rax = existing index, rsi = name, rdi = new value
    push rdi
    lea rdx, [rel var_table]
    mov rcx, rax
    imul rcx, VAR_ENTRY_SIZE
    add rdx, rcx
    add rdx, VAR_NAME_LEN
    mov rsi, rdi
    mov rdi, rdx
    call copy_str_no_nul
    mov byte [rdi], 0
    pop rdi
    jmp .done

.full:
    ; just ignore silently if full
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; var_get(rsi = name) -> rsi = pointer to value, or 0 if not found
var_get:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi

    xor rcx, rcx
.loop:
    cmp rcx, VAR_MAX
    jge .notfound

    lea rdi, [rel var_table]
    mov rax, rcx
    imul rax, VAR_ENTRY_SIZE
    add rdi, rax

    cmp byte [rdi], 0
    je .next

    push rcx
    push rsi
    mov rbx, rdi
    call str_equal
    pop rsi
    pop rcx
    cmp al, 1
    je .found

.next:
    inc rcx
    jmp .loop

.found:
    lea rax, [rel var_table]
    imul rcx, VAR_ENTRY_SIZE
    add rax, rcx
    add rax, VAR_NAME_LEN
    mov rsi, rax
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

.notfound:
    xor rsi, rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; try_var_set(rdi = input line) -> al = 1 if assignment was made
; Detects "name = value" pattern and sets the variable.
try_var_set:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rsi, rdi
    lea rdi, [rel token_buf]
    xor rcx, rcx
.copy_name:
    mov al, [rsi]
    cmp al, 0
    je .not_assign
    cmp al, ' '
    je .name_done
    cmp al, '='
    je .not_assign
    cmp rcx, 15
    jge .not_assign
    mov [rdi+rcx], al
    inc rcx
    inc rsi
    jmp .copy_name
.name_done:
    mov byte [rdi+rcx], 0
    cmp rcx, 0
    je .not_assign
.skip_sp:
    mov al, [rsi]
    cmp al, ' '
    jne .check_eq
    inc rsi
    jmp .skip_sp
.check_eq:
    cmp al, '='
    jne .not_assign
    inc rsi
.skip_sp2:
    mov al, [rsi]
    cmp al, ' '
    jne .got_val
    inc rsi
    jmp .skip_sp2
.got_val:
    ; rsi points to value portion of original input (null-terminated)
    lea rdi, [rel token_buf]
    ; rsi = value, but we need rsi=name, rdi=value for var_set
    ; save both
    push rsi
    lea rsi, [rel token_buf]   ; name
    pop rdi                    ; value (from rsi above)
    call var_set
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    mov al, 1
    ret

.not_assign:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    xor al, al
    ret

str_starts_with:
    push rsi
    push rbx
    push rcx
.cmp_loop:
    mov cl, [rbx]
    cmp cl, 0
    je .prefix_done
    mov al, [rsi]
    cmp al, cl
    jne .no_match
    inc rsi
    inc rbx
    jmp .cmp_loop
.prefix_done:
    ; next char in input must be space or NUL (so "showX" doesn't match "show")
    mov al, [rsi]
    cmp al, ' '
    je .match
    cmp al, 0
    je .match
    jmp .no_match
.match:
    pop rcx
    pop rbx
    pop rsi
    mov al, 1
    ret
.no_match:
    pop rcx
    pop rbx
    pop rsi
    mov al, 0
    ret

; ------------------------------------------------------------
; skip_spaces(rdi = string pointer) -> advances rdi past spaces
; ------------------------------------------------------------
skip_spaces:
    push rax
.loop:
    mov al, [rdi]
    cmp al, ' '
    jne .done
    inc rdi
    jmp .loop
.done:
    pop rax
    ret

; ------------------------------------------------------------
; parse_int(rdi = string pointer)
; Parses an optional '-' followed by decimal digits.
; Returns: rax = parsed signed integer, rdi advanced past the
; number (stops at the first non-digit character).
; If no digits are present, returns rax = 0 and rdi unchanged
; (aside from skipping a lone leading '-', if any).
; ------------------------------------------------------------
parse_int:
    push rbx
    push rcx
    push rdx

    xor rcx, rcx                ; rcx = 1 if negative, else 0
    mov al, [rdi]
    cmp al, '-'
    jne .no_sign
    mov rcx, 1
    inc rdi
.no_sign:
    xor rax, rax
.digit_loop:
    mov dl, [rdi]
    cmp dl, '0'
    jl .done
    cmp dl, '9'
    jg .done
    sub dl, '0'
    imul rax, rax, 10
    movzx rbx, dl
    add rax, rbx
    inc rdi
    jmp .digit_loop
.done:
    cmp rcx, 1
    jne .out
    neg rax
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; print_int(rax = signed 64-bit integer to print as decimal)
; ------------------------------------------------------------
print_int:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    mov rbx, rax
    cmp rbx, 0
    jge .not_negative
    mov al, '-'
    call putchar
    neg rbx
.not_negative:
    cmp rbx, 0
    jne .convert
    mov al, '0'
    call putchar
    jmp .finish

.convert:
    lea rdi, [rel int_buf]
    add rdi, 31
    mov byte [rdi], 0
    mov rax, rbx
    mov rcx, 10
.digit_loop:
    xor rdx, rdx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    cmp rax, 0
    jne .digit_loop

    mov rsi, rdi
    call print_string

.finish:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

int_buf: times 32 db 0

; puthex8(al = byte) — prints as 2 hex digits
puthex8:
    push rax
    push rcx
    push rdx
    push rdi
    mov rcx, 2
    ror al, 4
.loop:
    push rcx
    mov cl, al
    and cl, 0x0F
    cmp cl, 10
    jl .digit
    add cl, 'A' - 10
    jmp .out
.digit:
    add cl, '0'
.out:
    mov al, cl
    call putchar
    pop rcx
    rol al, 4
    loop .loop
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; ============================================================
;  Screen / VGA text-mode routines
; ============================================================

cursor_row: dq 0
cursor_col: dq 0

clear_screen:
    push rax
    push rcx
    push rdi
    mov rdi, VGA_MEMORY
    mov rcx, VGA_COLS * VGA_ROWS
    mov ah, WHITE_ON_BLACK
    mov al, ' '
.loop:
    mov [rdi], ax
    add rdi, 2
    loop .loop
    mov qword [rel cursor_row], 0
    mov qword [rel cursor_col], 0
    call update_cursor
    pop rdi
    pop rcx
    pop rax
    ret

; print_string(rsi = pointer to null-terminated string)
print_string:
    push rax
    push rsi
.loop:
    mov al, [rsi]
    cmp al, 0
    je .done
    call putchar
    inc rsi
    jmp .loop
.done:
    pop rsi
    pop rax
    ret

newline:
    push rax
    mov rax, [rel cursor_row]
    inc rax
    mov [rel cursor_row], rax
    mov qword [rel cursor_col], 0
    call scroll_if_needed
    pop rax
    ret

; putchar(al = character)
putchar:
    push rax
    push rbx
    push rdx
    push rdi

    cmp al, 10               ; '\n'
    je .do_newline
    cmp al, 8                ; backspace
    je .do_backspace

    ; compute offset = (row*80 + col) * 2
    mov rbx, [rel cursor_row]
    imul rbx, VGA_COLS
    add rbx, [rel cursor_col]
    shl rbx, 1
    mov rdi, VGA_MEMORY
    add rdi, rbx
    mov ah, WHITE_ON_BLACK
    mov [rdi], ax

    mov rax, [rel cursor_col]
    inc rax
    mov [rel cursor_col], rax
    cmp rax, VGA_COLS
    jl .end
    ; wrap to next line
    mov qword [rel cursor_col], 0
    mov rax, [rel cursor_row]
    inc rax
    mov [rel cursor_row], rax
    call scroll_if_needed
    jmp .end

.do_newline:
    mov rax, [rel cursor_row]
    inc rax
    mov [rel cursor_row], rax
    mov qword [rel cursor_col], 0
    call scroll_if_needed
    jmp .end

.do_backspace:
    mov rax, [rel cursor_col]
    cmp rax, 0
    je .end                  ; nothing to backspace at column 0
    dec rax
    mov [rel cursor_col], rax
    mov rbx, [rel cursor_row]
    imul rbx, VGA_COLS
    add rbx, [rel cursor_col]
    shl rbx, 1
    mov rdi, VGA_MEMORY
    add rdi, rbx
    mov ax, (WHITE_ON_BLACK << 8) | ' '
    mov [rdi], ax

.end:
    call update_cursor
    pop rdi
    pop rdx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
; update_cursor: tells the VGA hardware where to draw the
; blinking text cursor, based on cursor_row/cursor_col.
;
; The CRT Controller has an index port (0x3D4) and a data port
; (0x3D5). Register 0x0E = cursor position high byte,
; register 0x0F = cursor position low byte. The position is a
; single number: row * 80 + col.
; ------------------------------------------------------------
update_cursor:
    push rax
    push rbx
    push rdx

    mov rbx, [rel cursor_row]
    imul rbx, VGA_COLS
    add rbx, [rel cursor_col]     ; rbx = linear cursor position

    mov dx, 0x3D4
    mov al, 0x0E                  ; select "cursor location high" register
    out dx, al
    mov dx, 0x3D5
    mov al, bh                    ; high byte of position
    out dx, al

    mov dx, 0x3D4
    mov al, 0x0F                  ; select "cursor location low" register
    out dx, al
    mov dx, 0x3D5
    mov al, bl                    ; low byte of position
    out dx, al

    pop rdx
    pop rbx
    pop rax
    ret

scroll_if_needed:
    push rax
    push rcx
    push rsi
    push rdi
    mov rax, [rel cursor_row]
    cmp rax, VGA_ROWS
    jl .done

    ; scroll everything up by one line
    mov rsi, VGA_MEMORY + (VGA_COLS * 2)
    mov rdi, VGA_MEMORY
    mov rcx, VGA_COLS * (VGA_ROWS - 1)
.copy_loop:
    mov ax, [rsi]
    mov [rdi], ax
    add rsi, 2
    add rdi, 2
    loop .copy_loop

    ; clear last line
    mov rdi, VGA_MEMORY + (VGA_COLS * (VGA_ROWS - 1) * 2)
    mov rcx, VGA_COLS
    mov ax, (WHITE_ON_BLACK << 8) | ' '
.clear_loop:
    mov [rdi], ax
    add rdi, 2
    loop .clear_loop

    mov qword [rel cursor_row], VGA_ROWS - 1
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ============================================================
;  Keyboard driver
;
;  Uses BIOS int 0x16 via real-mode trampoline to read keys.
;  The BIOS handles all keyboard state (shift, caps, etc.)
;  and returns fully-processed ASCII characters.
; ============================================================

; ------------------------------------------------------------------
; read_line(rdi = buffer) — line editor with echo, backspace, Enter
; ------------------------------------------------------------------
read_line:
    push rax
    push rbx
    push rdi
    mov rbx, rdi
    xor ecx, ecx

.key_loop:
    call read_scancode

    cmp al, 0
    je .key_loop

    cmp al, 13
    je .enter
    cmp al, 8
    je .bs

    cmp al, ' '
    jb .key_loop

    cmp rcx, LINE_BUF_LEN - 1
    jge .key_loop

    mov [rbx], al
    inc rbx
    inc rcx
    call putchar
    jmp .key_loop

.bs:
    test rcx, rcx
    jz .key_loop
    dec rbx
    dec rcx
    mov al, 8
    call putchar
    jmp .key_loop

.enter:
    mov byte [rbx], 0
    mov al, 10
    call putchar
    pop rdi
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------
; read_scancode — read a key via BIOS int 0x16
; Returns AL = ASCII character, AH = scancode
; ------------------------------------------------------------------
read_scancode:
    call bios_get_key
    ret

; ------------------------------------------------------------------
; drain_kbd — no-op (no PS/2 buffer when using BIOS)
; ------------------------------------------------------------------
drain_kbd:
    ret

; ------------------------------------------------------------------
; init_keyboard — called once at boot; no setup needed
; ------------------------------------------------------------------
init_keyboard:
    ret

; ------------------------------------------------------------------
; init_real_mode — copy trampoline to 0x7000 and fill jump pointers
; ------------------------------------------------------------------
init_real_mode:
    push rax
    push rcx
    push rsi
    push rdi

    lea rsi, [rel trampoline_start]
    mov rdi, 0x7000
    mov rcx, trampoline_end - trampoline_start
    cld
    rep movsb

    ; Point rsi to offset table (last 24 bytes of trampoline)
    lea rsi, [rel trampoline_end]
    sub rsi, 24

    ; pm32_off at 0x705C: dd (pmode32_entry + 0x7000)
    mov eax, [rsi+4]
    add eax, 0x7000
    mov [0x705C], eax

    ; pm16_jmp at 0x0048: dd offset, dw CODE16_SEL
    mov eax, [rsi+8]
    add eax, 0x7000
    mov [0x7048], eax
    mov word [0x704C], 0x18

    ; rm16_jmp at 0x004E: dw offset, dw 0
    mov eax, [rsi+12]
    add eax, 0x7000
    mov [0x704E], ax
    mov word [0x7050], 0

    ; pm32ret_jmp at 0x0052: dw offset, dw CODE32_SEL
    mov eax, [rsi+16]
    add eax, 0x7000
    mov [0x7052], ax
    mov word [0x7054], 0x08

    ; lm64_jmp at 0x0056: dd offset, dw CODE64_SEL
    mov eax, [rsi+20]
    add eax, 0x7000
    mov [0x7056], eax
    mov word [0x705A], 0x28

    ; PML4 physical address at 0x7040
    lea rax, [rel pml4_table]
    mov [0x7040], rax

    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------
; bios_get_key — call trampoline at 0x7000 to read key via BIOS
; Returns AL = ASCII, AH = scancode (set 1)
; ------------------------------------------------------------------
bios_get_key:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    sgdt [saved_gdt]

    mov rax, 0x71E4
    call rax

    lgdt [saved_gdt]
    push CODE_SEG64
    lea rax, [rel .done]
    push rax
    retfq
.done:
    ; Load kernel data segment
    mov ax, DATA_SEG64
    mov ds, ax
    mov es, ax

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------
saved_gdt: times 10 db 0

; ============================================================
;  ATA (IDE) PIO disk driver — primary bus, master drive,
;  LBA28, polling. Works fine from 64-bit long mode since it's
;  plain port I/O (no BIOS calls needed once we're past boot).
; ============================================================

ATA_DATA    equ 0x1F0
ATA_SECCNT  equ 0x1F2
ATA_LBA_LO  equ 0x1F3
ATA_LBA_MID equ 0x1F4
ATA_LBA_HI  equ 0x1F5
ATA_DRVHEAD equ 0x1F6
ATA_CMD     equ 0x1F7
ATA_STATUS  equ 0x1F7

ATA_CMD_READ  equ 0x20
ATA_CMD_WRITE equ 0x30
ATA_CMD_FLUSH equ 0xE7

; ata_wait_bsy: poll status port until BSY (bit7) clears, with timeout
; Returns carry=0 on success, carry=1 on timeout
ata_wait_bsy:
    push rcx
    push rdx
    mov ecx, 0xFFFFFF
.wait:
    mov dx, ATA_STATUS
    in al, dx
    test al, 0x80
    jz .ready
    dec ecx
    jnz .wait
    stc
    pop rdx
    pop rcx
    ret
.ready:
    clc
    pop rdx
    pop rcx
    ret

; ata_wait_drq: poll status port until BSY clear and DRQ (bit3) set, with timeout
; Returns carry=0 on success, carry=1 on timeout
ata_wait_drq:
    push rcx
    push rdx
    mov ecx, 0xFFFFFF
.wait:
    mov dx, ATA_STATUS
    in al, dx
    test al, 0x80
    jnz .dec
    test al, 0x08
    jnz .ready
.dec:
    dec ecx
    jnz .wait
    stc
    pop rdx
    pop rcx
    ret
.ready:
    clc
    pop rdx
    pop rcx
    ret

; ata_read_sector(rax = LBA, rdi = 512-byte destination buffer)
; Returns carry=0 on success, carry=1 on timeout/error.
; Clobbers rax, rbx, rcx, rdx, rdi.
ata_read_sector:
    push rax
    push rbx
    push rcx
    push rdx

    call ata_wait_bsy
    jc .error

    mov rbx, rax
    mov dx, ATA_SECCNT
    mov al, 1
    out dx, al
    mov dx, ATA_LBA_LO
    mov al, bl
    out dx, al
    mov dx, ATA_LBA_MID
    mov al, bh
    out dx, al
    mov dx, ATA_LBA_HI
    mov eax, ebx
    shr eax, 16
    out dx, al
    mov dx, ATA_DRVHEAD
    mov eax, ebx
    shr eax, 24
    and al, 0x0F
    or al, 0xE0            ; LBA mode, master drive
    out dx, al

    mov dx, ATA_CMD
    mov al, ATA_CMD_READ
    out dx, al

    call ata_wait_drq
    jc .error

    cld
    mov dx, ATA_DATA
    mov rcx, 256            ; 256 words = 512 bytes
    rep insw

    clc
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

.error:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret

; ata_write_sector(rax = LBA, rdi = 512-byte source buffer)
; Returns carry=0 on success, carry=1 on timeout/error.
; Clobbers rax, rbx, rcx, rdx, rsi.
ata_write_sector:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi

    call ata_wait_bsy
    jc .error_ws

    mov rbx, rax
    mov dx, ATA_SECCNT
    mov al, 1
    out dx, al
    mov dx, ATA_LBA_LO
    mov al, bl
    out dx, al
    mov dx, ATA_LBA_MID
    mov al, bh
    out dx, al
    mov dx, ATA_LBA_HI
    mov eax, ebx
    shr eax, 16
    out dx, al
    mov dx, ATA_DRVHEAD
    mov eax, ebx
    shr eax, 24
    and al, 0x0F
    or al, 0xE0
    out dx, al

    mov dx, ATA_CMD
    mov al, ATA_CMD_WRITE
    out dx, al

    call ata_wait_drq
    jc .error_ws

    mov rsi, rdi
    cld
    mov dx, ATA_DATA
    mov rcx, 256
    rep outsw

    ; flush write cache so it survives a reset
    call ata_wait_bsy
    jc .error_ws
    mov dx, ATA_CMD
    mov al, ATA_CMD_FLUSH
    out dx, al
    call ata_wait_bsy
    jc .error_ws

    clc
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

.error_ws:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret

; ============================================================
;  /home filesystem — a flat table of directory entries kept
;  in memory and mirrored to disk so it survives a reboot.
;
;  Each entry is 64 bytes:
;    offset 0  : name, 32 bytes, NUL-terminated
;    offset 32 : used flag (1 byte: 1 = in use, 0 = free)
;    offset 33 : type (1 byte: 0 = folder, 1 = file)
;    offset 36 : parent_idx, signed dword (-1 for the root)
;    offset 40 : content_lba (4 bytes, LBA of content sector, 0 = none)
;    offset 44 : content_size (4 bytes)
;
;  Disk layout:
;    LBA 200        : magic sector ("SHFS")
;    LBA 201..208    : the 64-entry table (8 sectors = 4096B)
;
;  Entry 0 is always the root, named "home". Commands:
;    mkf <name>          create a folder in the current dir
;    cf <path>            change directory (absolute /home/.. ,
;                          relative name, "..", or nested a/b)
;    list                  list items in the current dir
;    mkfl <name>          create a file in the current dir
; ============================================================

FS_MAX_ENTRIES equ 64
FS_ENTRY_SIZE  equ 64
FS_MAGIC_LBA   equ 200
FS_TABLE_LBA   equ 201
FS_TABLE_SECTORS equ 8
FS_MAGIC_VALUE equ 0x53464853        ; "SHFS" little-endian
FS_TYPE_FOLDER   equ 0
FS_TYPE_FILE     equ 1
FS_CONTENT_LBA_OFF  equ 40
FS_CONTENT_SIZE_OFF equ 44

; str_equal(rsi, rbx = NUL-terminated strings) -> al = 1 if equal
str_equal:
    push rsi
    push rbx
    push rdx
.loop:
    mov al, [rsi]
    mov dl, [rbx]
    cmp al, dl
    jne .no
    cmp al, 0
    je .yes
    inc rsi
    inc rbx
    jmp .loop
.yes:
    pop rdx
    pop rbx
    pop rsi
    mov al, 1
    ret
.no:
    pop rdx
    pop rbx
    pop rsi
    mov al, 0
    ret

; str_prefix_match(rsi = string, rbx = NUL-terminated prefix) -> al = 1 if rsi begins with rbx
str_prefix_match:
    push rsi
    push rbx
    push rdx
.loop:
    mov dl, [rbx]
    cmp dl, 0
    je .match
    mov al, [rsi]
    cmp al, dl
    jne .no
    inc rsi
    inc rbx
    jmp .loop
.match:
    pop rdx
    pop rbx
    pop rsi
    mov al, 1
    ret
.no:
    pop rdx
    pop rbx
    pop rsi
    mov al, 0
    ret

; copy_str_no_nul(rsi = src NUL-terminated, rdi = dest) — copies
; bytes, advances both pointers, does NOT write a terminator.
copy_str_no_nul:
    push rax
.loop:
    mov al, [rsi]
    cmp al, 0
    je .done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .loop
.done:
    pop rax
    ret

; fs_find_child(r8 = parent index, rsi = name) -> rax = index or -1
fs_find_child:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    xor rcx, rcx
.loop:
    cmp rcx, FS_MAX_ENTRIES
    jge .notfound

    lea rdi, [rel fs_table]
    mov rax, rcx
    imul rax, FS_ENTRY_SIZE
    add rdi, rax

    cmp byte [rdi+32], 1
    jne .next

    movsx rax, dword [rdi+36]
    cmp rax, r8
    jne .next

    mov rbx, rdi
    call str_equal
    cmp al, 1
    je .found

.next:
    inc rcx
    jmp .loop

.found:
    mov rax, rcx
    jmp .out
.notfound:
    mov rax, -1
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; fs_load: reads the fs table from disk, or creates a fresh
; one (just the "home" root) if no valid filesystem is found.
; If the ATA drive times out (no disk), creates a memory-only fs.
fs_load:
    push rax
    push rcx
    push rdi

    mov rax, FS_MAGIC_LBA
    lea rdi, [rel sector_buf]
    call ata_read_sector
    jc .mem_only              ; ATA timeout → memory-only fs

    mov eax, [rel sector_buf]
    cmp eax, FS_MAGIC_VALUE
    jne .mem_only                  ; wrong magic → memory-only (don't overwrite disk)

    xor rcx, rcx
.load_loop:
    mov rax, FS_TABLE_LBA
    add rax, rcx
    lea rdi, [rel fs_table]
    push rax
    mov rax, rcx
    imul rax, 512
    add rdi, rax
    pop rax
    call ata_read_sector
    inc rcx
    cmp rcx, FS_TABLE_SECTORS
    jl .load_loop

    mov qword [rel fs_current_dir], 0
    jmp .done

.init_fresh:
    lea rdi, [rel fs_table]
    mov rcx, (FS_MAX_ENTRIES * FS_ENTRY_SIZE) / 8
    xor rax, rax
    rep stosq

    lea rdi, [rel fs_table]
    lea rsi, [rel str_home]
    call copy_str_no_nul
    mov byte [rdi], 0

    lea rdi, [rel fs_table]
    mov byte [rdi+32], 1
    mov byte [rdi+33], FS_TYPE_FOLDER
    mov dword [rdi+36], -1

    mov qword [rel fs_current_dir], 0
    call fs_save
    jmp .done

.mem_only:
    lea rdi, [rel fs_table]
    mov rcx, (FS_MAX_ENTRIES * FS_ENTRY_SIZE) / 8
    xor rax, rax
    rep stosq

    lea rdi, [rel fs_table]
    lea rsi, [rel str_home]
    call copy_str_no_nul
    mov byte [rdi], 0

    lea rdi, [rel fs_table]
    mov byte [rdi+32], 1
    mov byte [rdi+33], FS_TYPE_FOLDER
    mov dword [rdi+36], -1

    mov qword [rel fs_current_dir], 0
    mov byte [rel fs_readonly], 1

.done:
    pop rdi
    pop rcx
    pop rax
    ret

; fs_save: writes the magic sector + full table out to disk.
; Skips if fs_readonly is set (no ATA drive present).
fs_save:
    cmp byte [rel fs_readonly], 1
    je .skip
    push rax
    push rcx
    push rdi

    lea rdi, [rel sector_buf]
    xor rax, rax
    push rcx
    mov rcx, 512/8
    rep stosq
    pop rcx

    mov dword [rel sector_buf], FS_MAGIC_VALUE
    mov rax, FS_MAGIC_LBA
    lea rdi, [rel sector_buf]
    call ata_write_sector

    xor rcx, rcx
.save_loop:
    mov rax, FS_TABLE_LBA
    add rax, rcx
    lea rdi, [rel fs_table]
    push rax
    mov rax, rcx
    imul rax, 512
    add rdi, rax
    pop rax
    call ata_write_sector
    inc rcx
    cmp rcx, FS_TABLE_SECTORS
    jl .save_loop

    pop rdi
    pop rcx
    pop rax
.skip:
    ret

; fs_make_folder(rdi = name, terminated by space or NUL)
fs_make_folder:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    lea rbx, [rel fs_seg_buf]
    xor rcx, rcx
.copy:
    mov al, [rdi]
    cmp al, 0
    je .copy_done
    cmp al, ' '
    je .copy_done
    cmp rcx, 31
    jge .copy_done
    mov [rbx+rcx], al
    inc rcx
    inc rdi
    jmp .copy
.copy_done:
    mov byte [rbx+rcx], 0

    cmp rcx, 0
    je .syntax_err

    mov r8, [rel fs_current_dir]
    lea rsi, [rel fs_seg_buf]
    call fs_find_child
    cmp rax, -1
    jne .exists_err

    xor rcx, rcx
.find_free:
    cmp rcx, FS_MAX_ENTRIES
    jge .full_err
    lea rdi, [rel fs_table]
    mov rax, rcx
    imul rax, FS_ENTRY_SIZE
    add rdi, rax
    cmp byte [rdi+32], 0
    je .slot_found
    inc rcx
    jmp .find_free

.slot_found:
    lea rsi, [rel fs_seg_buf]
    call copy_str_no_nul
    mov byte [rdi], 0

    ; rdi walked past the name; recompute the entry base to set
    ; the fixed-offset fields safely
    lea rdi, [rel fs_table]
    mov rax, rcx
    imul rax, FS_ENTRY_SIZE
    add rdi, rax
    mov byte [rdi+32], 1
    mov byte [rdi+33], FS_TYPE_FOLDER
    mov eax, dword [rel fs_current_dir]
    mov [rdi+36], eax

    call fs_save

    lea rsi, [rel msg_mkf_ok]
    call print_string
    jmp .done

.syntax_err:
    lea rsi, [rel err_mkf_syntax]
    call print_string
    jmp .done
.exists_err:
    lea rsi, [rel err_mkf_exists]
    call print_string
    jmp .done
.full_err:
    lea rsi, [rel err_mkf_full]
    call print_string
    jmp .done

.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; fs_make_file(rdi = name, terminated by space or NUL)
fs_make_file:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    lea rbx, [rel fs_seg_buf]
    xor rcx, rcx
.copy:
    mov al, [rdi]
    cmp al, 0
    je .copy_done
    cmp al, ' '
    je .copy_done
    cmp rcx, 31
    jge .copy_done
    mov [rbx+rcx], al
    inc rcx
    inc rdi
    jmp .copy
.copy_done:
    mov byte [rbx+rcx], 0

    cmp rcx, 0
    je .syntax_err

    mov r8, [rel fs_current_dir]
    lea rsi, [rel fs_seg_buf]
    call fs_find_child
    cmp rax, -1
    jne .exists_err

    xor rcx, rcx
.find_free:
    cmp rcx, FS_MAX_ENTRIES
    jge .full_err
    lea rdi, [rel fs_table]
    mov rax, rcx
    imul rax, FS_ENTRY_SIZE
    add rdi, rax
    cmp byte [rdi+32], 0
    je .slot_found
    inc rcx
    jmp .find_free

.slot_found:
    lea rsi, [rel fs_seg_buf]
    call copy_str_no_nul
    mov byte [rdi], 0

    lea rdi, [rel fs_table]
    mov rax, rcx
    imul rax, FS_ENTRY_SIZE
    add rdi, rax
    mov byte [rdi+32], 1
    mov byte [rdi+33], FS_TYPE_FILE
    mov eax, dword [rel fs_current_dir]
    mov [rdi+36], eax
    mov dword [rdi+FS_CONTENT_LBA_OFF], 0
    mov dword [rdi+FS_CONTENT_SIZE_OFF], 0

    call fs_save

    lea rsi, [rel msg_mkfl_ok]
    call print_string
    jmp .done

.syntax_err:
    lea rsi, [rel err_mkfl_syntax]
    call print_string
    jmp .done
.exists_err:
    lea rsi, [rel err_mkfl_exists]
    call print_string
    jmp .done
.full_err:
    lea rsi, [rel err_mkfl_full]
    call print_string
    jmp .done

.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; fs_change_dir(rdi = path string, rest of the input line)
fs_change_dir:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9

    mov r9, rdi

    mov al, [r9]
    cmp al, '/'
    jne .relative

    lea rbx, [rel abs_home_prefix]
    mov rsi, r9
    call str_prefix_match
    cmp al, 1
    jne .notfound

    mov al, [r9+5]
    cmp al, '/'
    je .home_ok
    cmp al, 0
    je .home_ok
    jmp .notfound
.home_ok:
    add r9, 5
    mov r8, 0
    jmp .descend

.relative:
    mov r8, [rel fs_current_dir]

.descend:
    mov al, [r9]
    cmp al, '/'
    jne .check_end
    inc r9
    jmp .descend
.check_end:
    mov al, [r9]
    cmp al, 0
    je .success

    lea rdi, [rel fs_seg_buf]
    xor rcx, rcx
.seg_loop:
    mov al, [r9]
    cmp al, 0
    je .seg_done
    cmp al, '/'
    je .seg_done
    cmp rcx, 31
    jge .seg_done
    mov [rdi+rcx], al
    inc rcx
    inc r9
    jmp .seg_loop
.seg_done:
    mov byte [rdi+rcx], 0

    lea rsi, [rel fs_seg_buf]
    lea rbx, [rel str_dotdot]
    call str_equal
    cmp al, 1
    jne .not_dotdot

    lea rdi, [rel fs_table]
    mov rax, r8
    imul rax, FS_ENTRY_SIZE
    add rdi, rax
    movsx rax, dword [rdi+36]
    cmp rax, -1
    je .descend
    mov r8, rax
    jmp .descend

.not_dotdot:
    lea rsi, [rel fs_seg_buf]
    call fs_find_child
    cmp rax, -1
    je .notfound
    lea rdi, [rel fs_table]
    mov rdx, rax
    imul rdx, FS_ENTRY_SIZE
    add rdi, rdx
    cmp byte [rdi+33], FS_TYPE_FOLDER
    jne .notfound
    mov r8, rax
    jmp .descend

.success:
    mov [rel fs_current_dir], r8
    jmp .ret

.notfound:
    lea rsi, [rel err_cf_notfound]
    call print_string

.ret:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; fs_list_dir: prints the names of folders inside the current dir
fs_list_dir:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    mov r8, [rel fs_current_dir]
    xor rcx, rcx
    xor rbx, rbx
.loop:
    cmp rcx, FS_MAX_ENTRIES
    jge .check_empty

    lea rdi, [rel fs_table]
    mov rax, rcx
    imul rax, FS_ENTRY_SIZE
    add rdi, rax

    cmp byte [rdi+32], 1
    jne .next
    movsx rax, dword [rdi+36]
    cmp rax, r8
    jne .next

    mov rsi, rdi
    call print_string
    lea rsi, [rel newline_str]
    call print_string
    mov rbx, 1

.next:
    inc rcx
    jmp .loop

.check_empty:
    cmp rbx, 1
    je .done
    lea rsi, [rel msg_ls_empty]
    call print_string

.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; build_path: writes the current directory's full path (e.g.
; "/home/foo/bar") as a NUL-terminated string into path_buf.
build_path:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9

    mov r8, [rel fs_current_dir]
    xor rcx, rcx

.collect:
    lea rbx, [rel path_stack]
    mov [rbx + rcx*8], r8
    inc rcx

    lea rdi, [rel fs_table]
    mov rax, r8
    imul rax, FS_ENTRY_SIZE
    add rdi, rax
    movsx rax, dword [rdi+36]
    cmp rax, -1
    je .collect_done
    mov r8, rax
    cmp rcx, 16
    jge .collect_done
    jmp .collect

.collect_done:
    lea rdi, [rel path_buf]
    mov byte [rdi], '/'
    inc rdi

    mov rax, rcx
    dec rax
    lea rbx, [rel path_stack]
    mov r9, [rbx + rax*8]
    lea rsi, [rel fs_table]
    mov rax, r9
    imul rax, FS_ENTRY_SIZE
    add rsi, rax
    call copy_str_no_nul

    mov rax, rcx
    sub rax, 2
    cmp rax, 0
    jl .path_finish

.path_loop:
    cmp rax, 0
    jl .path_finish
    mov byte [rdi], '/'
    inc rdi
    push rax
    lea rbx, [rel path_stack]
    mov r9, [rbx + rax*8]
    lea rsi, [rel fs_table]
    mov rax, r9
    imul rax, FS_ENTRY_SIZE
    add rsi, rax
    call copy_str_no_nul
    pop rax
    dec rax
    jmp .path_loop

.path_finish:
    mov byte [rdi], 0

    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
;  User management — 3 roles: admin, member, guest
;
;  Stored on disk at LBA 220..221 (2 sectors = 1024 bytes).
;  16 entries, each 64 bytes:
;    offset 0  : username[16], NUL-terminated
;    offset 16 : password[16], NUL-terminated (plain text)
;    offset 32 : role (1 byte: 0=guest, 1=member, 2=admin)
;    offset 33-63 : padding
;
;  First registered user → admin, rest → member.
;  auth <password> promo <user> <role>   — promote (admin only)
;  auth <password> demo <user>           — demote (admin only)
; ============================================================

USER_MAX_ENTRIES equ 16
USER_ENTRY_SIZE  equ 64
USER_TABLE_LBA   equ 220
USER_TABLE_SECTORS equ 2
USER_MAGIC_VALUE equ 0x52455553        ; "USER" little-endian

ROLE_GUEST  equ 0
ROLE_MEMBER equ 1
ROLE_ADMIN  equ 2

; user_load: load user table from disk, or init fresh
user_load:
    cmp byte [rel fs_readonly], 1
    je .user_no_disk
    push rax
    push rcx
    push rdi

    mov rax, USER_TABLE_LBA
    lea rdi, [rel sector_buf]
    call ata_read_sector
    jc .init_fresh               ; ATA timeout

    mov eax, [rel sector_buf]
    cmp eax, USER_MAGIC_VALUE
    jne .mem_only_users

    xor rcx, rcx
.load_loop:
    mov rax, USER_TABLE_LBA
    inc rax
    add rax, rcx
    lea rdi, [rel user_table]
    push rax
    mov rax, rcx
    imul rax, 512
    add rdi, rax
    pop rax
    call ata_read_sector
    inc rcx
    cmp rcx, USER_TABLE_SECTORS
    jl .load_loop
    jmp .done

.user_no_disk:
    lea rdi, [rel user_table]
    mov rcx, (USER_MAX_ENTRIES * USER_ENTRY_SIZE) / 8
    xor rax, rax
    rep stosq
    mov byte [rel logged_in], 0
    ret

.init_fresh:
    lea rdi, [rel user_table]
    mov rcx, (USER_MAX_ENTRIES * USER_ENTRY_SIZE) / 8
    xor rax, rax
    rep stosq
    cmp byte [rel fs_readonly], 0
    je .save_users
    mov byte [rel logged_in], 0
    jmp .done

.mem_only_users:
    lea rdi, [rel user_table]
    mov rcx, (USER_MAX_ENTRIES * USER_ENTRY_SIZE) / 8
    xor rax, rax
    rep stosq
    mov byte [rel logged_in], 0
    jmp .done

.save_users:
    call user_save
    mov byte [rel logged_in], 0

.done:
    pop rdi
    pop rcx
    pop rax
    ret

; user_save: write magic sector + user table to disk
; Skips if fs_readonly is set (no ATA drive present).
user_save:
    cmp byte [rel fs_readonly], 1
    je .skip
    push rax
    push rcx
    push rdi

    lea rdi, [rel sector_buf]
    xor rax, rax
    push rcx
    mov rcx, 512/8
    rep stosq
    pop rcx

    mov dword [rel sector_buf], USER_MAGIC_VALUE
    mov rax, USER_TABLE_LBA
    lea rdi, [rel sector_buf]
    call ata_write_sector

    xor rcx, rcx
.save_loop:
    mov rax, USER_TABLE_LBA
    inc rax
    add rax, rcx
    lea rdi, [rel user_table]
    push rax
    mov rax, rcx
    imul rax, 512
    add rdi, rax
    pop rax
    call ata_write_sector
    inc rcx
    cmp rcx, USER_TABLE_SECTORS
    jl .save_loop

    pop rdi
    pop rcx
    pop rax
.skip:
    ret

; user_find(rsi = NUL-terminated username) -> rax = index or -1
user_find:
    push rbx
    push rcx
    push rdi
    push rsi

    xor rcx, rcx
.loop:
    cmp rcx, USER_MAX_ENTRIES
    jge .notfound

    lea rdi, [rel user_table]
    mov rax, rcx
    imul rax, USER_ENTRY_SIZE
    add rdi, rax

    cmp byte [rdi], 0
    je .next

    push rcx
    push rsi
    push rdi
    mov rbx, rdi
    call str_equal
    pop rdi
    pop rsi
    pop rcx
    cmp al, 1
    je .found

.next:
    inc rcx
    jmp .loop

.found:
    mov rax, rcx
    jmp .out
.notfound:
    mov rax, -1
.out:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; user_check_password(rcx = index, rsi = password) -> al = 1 if match
user_check_password:
    push rdi
    push rsi

    lea rdi, [rel user_table]
    mov rax, rcx
    imul rax, USER_ENTRY_SIZE
    add rdi, rax
    add rdi, 16

    call str_equal

    pop rsi
    pop rdi
    ret

; user_get_role(rcx = index) -> al = role byte
user_get_role:
    lea rdi, [rel user_table]
    mov rax, rcx
    imul rax, USER_ENTRY_SIZE
    add rdi, rax
    mov al, [rdi + 32]
    ret

; user_set_role(rcx = index, al = new_role)
user_set_role:
    lea rdi, [rel user_table]
    mov rax, rcx
    imul rax, USER_ENTRY_SIZE
    add rdi, rax
    mov [rdi + 32], al
    push rax
    call user_save
    pop rax
    ret

; parse_role(rsi = string) -> al = role or -1 if invalid
parse_role:
    push rbx
    push rsi
    lea rbx, [rel str_role_guest]
    call str_equal
    cmp al, 1
    je .guest
    lea rbx, [rel str_role_member]
    call str_equal
    cmp al, 1
    je .member
    lea rbx, [rel str_role_admin]
    call str_equal
    cmp al, 1
    je .admin
    pop rsi
    pop rbx
    mov al, -1
    ret
.guest:
    pop rsi
    pop rbx
    mov al, ROLE_GUEST
    ret
.member:
    pop rsi
    pop rbx
    mov al, ROLE_MEMBER
    ret
.admin:
    pop rsi
    pop rbx
    mov al, ROLE_ADMIN
    ret

; role_to_string(al = role) -> rsi = string
role_to_string:
    cmp al, ROLE_GUEST
    je .g
    cmp al, ROLE_MEMBER
    je .m
    lea rsi, [rel str_role_admin]
    ret
.g:
    lea rsi, [rel str_role_guest]
    ret
.m:
    lea rsi, [rel str_role_member]
    ret

; copy_token(rdi = input, rsi = dest_buf, max = 15) — copies
; the next token (spaces or NUL terminated) to dest, returns
; rdi advanced past the token (to space or NUL).
copy_token:
    push rcx
    xor rcx, rcx
.loop:
    mov al, [rdi]
    cmp al, 0
    je .done
    cmp al, ' '
    je .done
    cmp rcx, 15
    jge .done
    mov [rsi + rcx], al
    inc rcx
    inc rdi
    jmp .loop
.done:
    mov byte [rsi + rcx], 0
    pop rcx
    ret

; copy_token_advance(rdi = input, rsi = dest_buf, max = 15) —
; same as copy_token but also advances rdi past trailing space.
; Returns rdi at start of next token (or NUL).
copy_token_advance:
    call copy_token
    cmp byte [rdi], ' '
    jne .no_skip
    inc rdi
.no_skip:
    ret

; user_register(rdi = input after "reg "): reg <username> <password>
user_register:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    lea rsi, [rel token_buf]
    call copy_token_advance
    mov al, [rel token_buf]
    cmp al, 0
    je .syntax

    ; check username doesn't already exist
    lea rsi, [rel token_buf]
    call user_find
    cmp rax, -1
    jne .exists

    ; find free slot
    xor rcx, rcx
.find_free:
    cmp rcx, USER_MAX_ENTRIES
    jge .full
    lea rdi, [rel user_table]
    mov rax, rcx
    imul rax, USER_ENTRY_SIZE
    add rdi, rax
    cmp byte [rdi], 0
    je .slot_found
    inc rcx
    jmp .find_free

.slot_found:
    push rcx
    ; copy username
    lea rsi, [rel token_buf]
    lea rdi, [rel user_table]
    mov rax, rcx
    imul rax, USER_ENTRY_SIZE
    add rdi, rax
    push rdi
    call copy_str_no_nul
    mov byte [rdi], 0
    pop rdi

    ; copy password (next token)
    push rdi
    add rdi, 16
    push rdi
    lea rsi, [rel token_buf2]
    mov rdi, rsi
    call copy_token_advance
    pop rdi
    lea rsi, [rel token_buf2]
    call copy_str_no_nul
    mov byte [rdi], 0
    pop rdi

    ; determine role: first user = admin, rest = member
    push rcx
    call user_count
    cmp rax, 1
    jg .member_role
    mov byte [rdi + 32], ROLE_ADMIN
    jmp .role_set
.member_role:
    mov byte [rdi + 32], ROLE_MEMBER
.role_set:
    pop rcx

    pop rcx
    call user_save

    ; auto-login
    mov [rel current_user_idx], rcx
    mov byte [rel logged_in], 1

    ; print success message
    lea rsi, [rel msg_reg_ok]
    call print_string
    lea rsi, [rel token_buf]
    call print_string
    lea rsi, [rel msg_reg_as]
    call print_string
    lea rdi, [rel user_table]
    mov rax, rcx
    imul rax, USER_ENTRY_SIZE
    add rdi, rax
    mov al, [rdi + 32]
    call role_to_string
    call print_string
    call newline
    jmp .done

.syntax:
    lea rsi, [rel err_reg_syntax]
    call print_string
    jmp .done
.exists:
    lea rsi, [rel err_reg_exists]
    call print_string
    jmp .done
.full:
    lea rsi, [rel err_reg_full]
    call print_string

.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; user_count -> rax = number of registered users
user_count:
    push rcx
    push rdi
    xor rax, rax
    xor rcx, rcx
.loop:
    cmp rcx, USER_MAX_ENTRIES
    jge .done
    lea rdi, [rel user_table]
    mov rdx, rcx
    imul rdx, USER_ENTRY_SIZE
    add rdi, rdx
    cmp byte [rdi], 0
    je .next
    inc rax
.next:
    inc rcx
    jmp .loop
.done:
    pop rdi
    pop rcx
    ret

; user_login(rdi = input after "login "): login <username> <password>
user_login:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    lea rsi, [rel token_buf]
    call copy_token_advance
    mov al, [rel token_buf]
    cmp al, 0
    je .syntax

    lea rsi, [rel token_buf]
    call user_find
    cmp rax, -1
    je .bad_user
    mov rcx, rax

    ; save the password token
    push rcx
    lea rsi, [rel token_buf2]
    mov rdi, rsi
    call copy_token_advance
    pop rcx

    lea rsi, [rel token_buf2]
    call user_check_password
    cmp al, 1
    jne .bad_pass

    mov [rel current_user_idx], rcx
    mov byte [rel logged_in], 1

    lea rsi, [rel msg_login_ok]
    call print_string
    lea rsi, [rel token_buf]
    call print_string
    call newline
    jmp .done

.bad_user:
    lea rsi, [rel err_login_bad_user]
    call print_string
    jmp .done
.bad_pass:
    lea rsi, [rel err_login_bad_pass]
    call print_string
    jmp .done
.syntax:
    lea rsi, [rel err_login_syntax]
    call print_string

.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; user_whoami: prints current user info
user_whoami:
    push rax
    push rcx
    push rdi
    push rsi

    cmp byte [rel logged_in], 1
    jne .not_logged

    mov rcx, [rel current_user_idx]
    lea rdi, [rel user_table]
    mov rax, rcx
    imul rax, USER_ENTRY_SIZE
    add rdi, rax

    lea rsi, [rel msg_whoami_line1]
    call print_string
    mov rsi, rdi
    call print_string
    call newline

    lea rsi, [rel msg_whoami_line2]
    call print_string
    mov al, [rdi + 32]
    call role_to_string
    call print_string
    call newline
    jmp .done

.not_logged:
    lea rsi, [rel msg_whoami_nobody]
    call print_string

.done:
    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret

; user_auth(rdi = input after "auth "): auth <password> [promo/demo ...]
user_auth:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    cmp byte [rel logged_in], 1
    jne .need_login

    ; copy the password token
    lea rsi, [rel token_buf]
    call copy_token_advance

    mov al, [rel token_buf]
    cmp al, 0
    je .syntax

    ; verify password against current user
    mov rcx, [rel current_user_idx]
    lea rsi, [rel token_buf]
    call user_check_password
    cmp al, 1
    jne .bad_pass

    ; check what sub-command follows
    mov al, [rdi]
    cmp al, 0
    je .syntax

    ; check for "promo"
    push rdi
    lea rbx, [rel cmd_promo]
    call str_starts_with
    cmp al, 1
    je .do_promo
    pop rdi

    ; check for "demo"
    push rdi
    lea rbx, [rel cmd_demo]
    call str_starts_with
    cmp al, 1
    je .do_demo
    pop rdi

    ; unknown auth sub-command
    lea rsi, [rel err_auth_sub]
    call print_string
    jmp .done

.do_promo:
    pop rdi
    add rdi, 5                  ; skip "promo"
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .promo_syntax

    ; check current user is admin
    mov rcx, [rel current_user_idx]
    call user_get_role
    cmp al, ROLE_ADMIN
    jne .need_admin

    ; get target username
    lea rsi, [rel token_buf]
    call copy_token_advance
    mov al, [rel token_buf]
    cmp al, 0
    je .promo_syntax

    ; find target user
    lea rsi, [rel token_buf]
    call user_find
    cmp rax, -1
    je .promo_bad_user
    mov r9, rax                    ; r9 = target index

    ; get target role from remaining input
    lea rsi, [rel token_buf2]
    mov rdi, rsi
    call copy_token_advance

    ; parse role
    lea rsi, [rel token_buf2]
    call parse_role
    cmp al, -1
    je .promo_syntax
    mov r8b, al                    ; r8b = new role

    ; set the role
    mov rcx, r9
    mov al, r8b
    call user_set_role

    lea rsi, [rel msg_promo_ok]
    call print_string
    lea rsi, [rel token_buf]
    call print_string
    lea rsi, [rel msg_promo_to]
    call print_string
    mov al, r8b
    call role_to_string
    call print_string
    call newline
    jmp .done

.promo_syntax:
    lea rsi, [rel err_promo_syntax]
    call print_string
    jmp .done
.promo_bad_user:
    lea rsi, [rel err_promo_bad_user]
    call print_string
    jmp .done

.do_demo:
    pop rdi
    add rdi, 4                  ; skip "demo"
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .demo_syntax

    ; check current user is admin
    mov rcx, [rel current_user_idx]
    call user_get_role
    cmp al, ROLE_ADMIN
    jne .need_admin

    ; get target username
    lea rsi, [rel token_buf]
    call copy_token_advance
    mov al, [rel token_buf]
    cmp al, 0
    je .demo_syntax

    ; find target user
    lea rsi, [rel token_buf]
    call user_find
    cmp rax, -1
    je .demo_bad_user
    mov r9, rax

    ; check target is not admin
    mov rcx, r9
    call user_get_role
    cmp al, ROLE_ADMIN
    je .demo_cant

    ; demote to member
    mov rcx, r9
    mov al, ROLE_MEMBER
    call user_set_role

    lea rsi, [rel msg_demo_ok]
    call print_string
    lea rsi, [rel token_buf]
    call print_string
    call newline
    jmp .done

.demo_syntax:
    lea rsi, [rel err_demo_syntax]
    call print_string
    jmp .done
.demo_bad_user:
    lea rsi, [rel err_demo_bad_user]
    call print_string
    jmp .done
.demo_cant:
    lea rsi, [rel err_demo_cant]
    call print_string
    jmp .done

.need_login:
    lea rsi, [rel err_auth_nologin]
    call print_string
    jmp .done
.bad_pass:
    lea rsi, [rel err_auth_bad_pass]
    call print_string
    jmp .done
.need_admin:
    lea rsi, [rel err_auth_need_admin]
    call print_string
    jmp .done
.syntax:
    lea rsi, [rel err_auth_syntax]
    call print_string

.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
;  calc_expr — precedence-aware expression parser
;
;  rdi = input string (e.g. "10 - 6 * 3 + 14")
;  returns rax = computed result, rdi advanced past expression
;
;  Uses shunting-yard with fixed-size stacks.
; ============================================================

CALC_STACK_MAX equ 16

; calc_push_val(rax)
calc_push_val:
    push rcx
    mov rcx, [rel calc_val_sp]
    cmp rcx, CALC_STACK_MAX
    jge .full
    lea rdx, [rel calc_val_stack]
    mov [rdx + rcx*8], rax
    inc qword [rel calc_val_sp]
.full:
    pop rcx
    ret

; calc_pop_val -> rax
calc_pop_val:
    push rcx
    mov rcx, [rel calc_val_sp]
    cmp rcx, 0
    je .empty
    dec rcx
    mov [rel calc_val_sp], rcx
    lea rdx, [rel calc_val_stack]
    mov rax, [rdx + rcx*8]
    pop rcx
    ret
.empty:
    xor rax, rax
    pop rcx
    ret

; calc_push_op(al)
calc_push_op:
    push rcx
    mov rcx, [rel calc_op_sp]
    cmp rcx, CALC_STACK_MAX
    jge .full
    lea rdx, [rel calc_op_stack]
    mov [rdx + rcx], al
    inc qword [rel calc_op_sp]
.full:
    pop rcx
    ret

; calc_pop_op -> al
calc_pop_op:
    push rcx
    mov rcx, [rel calc_op_sp]
    cmp rcx, 0
    je .empty
    dec rcx
    mov [rel calc_op_sp], rcx
    lea rdx, [rel calc_op_stack]
    mov al, [rdx + rcx]
    pop rcx
    ret
.empty:
    xor al, al
    pop rcx
    ret

; calc_peek_op -> al
calc_peek_op:
    push rcx
    mov rcx, [rel calc_op_sp]
    cmp rcx, 0
    je .empty
    dec rcx
    lea rdx, [rel calc_op_stack]
    mov al, [rdx + rcx]
    pop rcx
    ret
.empty:
    xor al, al
    pop rcx
    ret

; calc_precedence(al = op) -> al = 2 for */, 1 for +-
calc_precedence:
    cmp al, '+'
    je .low
    cmp al, '-'
    je .low
    cmp al, '*'
    je .high
    cmp al, '/'
    je .high
    xor al, al
    ret
.low:
    mov al, 1
    ret
.high:
    mov al, 2
    ret

; calc_apply(lhs in r8, op in r9b, rhs in r10) -> rax
calc_apply:
    cmp r9b, '+'
    je .add
    cmp r9b, '-'
    je .sub
    cmp r9b, '*'
    je .mul
    cmp r9b, '/'
    je .div
    xor rax, rax
    ret
.add:
    mov rax, r8
    add rax, r10
    ret
.sub:
    mov rax, r8
    sub rax, r10
    ret
.mul:
    mov rax, r8
    imul rax, r10
    ret
.div:
    cmp r10, 0
    je .divz
    mov rax, r8
    cqo
    idiv r10
    ret
.divz:
    xor rax, rax
    ret

; reduce_top: pop two values and one operator, apply, push result
calc_reduce_top:
    push r8
    push r9
    push r10
    call calc_pop_op
    mov r9b, al
    call calc_pop_val
    mov r10, rax
    call calc_pop_val
    mov r8, rax
    call calc_apply
    call calc_push_val
    pop r10
    pop r9
    pop r8
    ret

; calc_expr(rdi) -> rax
calc_expr:
    push r8
    push r9
    push r10
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov qword [rel calc_val_sp], 0
    mov qword [rel calc_op_sp], 0

    ; parse first number
    call parse_int
    call calc_push_val

.next_token:
    call skip_spaces
    mov al, [rdi]
    cmp al, 0
    je .finish

    ; read operator
    mov r9b, al
    inc rdi

    call skip_spaces
    call parse_int
    mov r10, rax

    ; while precedence(new op) <= precedence(top op): reduce
.reduce_loop:
    call calc_peek_op
    cmp al, 0
    je .push_op
    push rax
    mov al, r9b
    call calc_precedence
    mov bl, al
    pop rax
    call calc_precedence
    cmp bl, al
    jg .push_op
    ; reduce top
    call calc_reduce_top
    jmp .reduce_loop

.push_op:
    mov al, r9b
    call calc_push_op
    call calc_push_val
    jmp .next_token

.finish:
    ; reduce all remaining operators
.reduce_all:
    call calc_peek_op
    cmp al, 0
    je .done_expr
    call calc_reduce_top
    jmp .reduce_all

.done_expr:
    call calc_pop_val
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop r10
    pop r9
    pop r8
    ret

; ============================================================
;  File content storage — content blocks at LBA 209+
;
;  Entry field additions:
;    offset 40: content_lba (4 bytes, 0 = no content)
;    offset 44: content_size (4 bytes)
;
;  Magic sector (LBA 200):
;    offset 0: "SHFS" (4 bytes)
;    offset 4: next_free_lba (4 bytes)
; ============================================================

FS_CONTENT_START equ 209

; fs_alloc_block -> rax = LBA of newly allocated block (or 0 on fail)
fs_alloc_block:
    cmp byte [rel fs_readonly], 1
    je .no_disk
    push rcx
    push rdx
    push rdi

    ; read magic sector to get next_free_lba
    mov rax, FS_MAGIC_LBA
    lea rdi, [rel sector_buf]
    call ata_read_sector

    mov eax, [rel sector_buf + 4]
    cmp eax, 0
    jne .have_lba
    mov eax, FS_CONTENT_START
.have_lba:
    push rax

    ; write zeros to the new block
    mov rcx, rax
    lea rdi, [rel sector_buf]
    push rcx
    xor rax, rax
    push rdi
    mov rcx, 512/8
    rep stosq
    pop rdi
    pop rcx
    mov rax, rcx
    call ata_write_sector

    ; increment next_free_lba and save
    pop rax
    push rax
    inc rax
    mov [rel sector_buf + 4], eax
    mov dword [rel sector_buf], FS_MAGIC_VALUE
    mov rax, FS_MAGIC_LBA
    lea rdi, [rel sector_buf]
    call ata_write_sector

    pop rax
    pop rdi
    pop rdx
    pop rcx
    ret

.no_disk:
    xor rax, rax
    ret

; ------------------------------------------------------------
; fs_read_file_content(rcx = entry_index, rdi = buffer) -> rax = size
fs_read_file_content:
    cmp byte [rel fs_readonly], 1
    je .empty
    push rcx
    push rdx
    push rdi
    push rsi

    ; get entry
    lea rsi, [rel fs_table]
    mov rax, rcx
    imul rax, FS_ENTRY_SIZE
    add rsi, rax

    mov eax, [rsi + 40]        ; content_lba
    cmp eax, 0
    je .empty

    push rdi
    mov rdi, rdi               ; dest buffer
    xor rdx, rdx
    push rax
    mov rax, rax               ; LBA
    pop rax
    call ata_read_sector
    pop rdi

    mov eax, [rsi + 44]        ; content_size
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

.empty:
    xor rax, rax
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

; fs_write_file_content(rcx = entry_index, rsi = buffer, rdx = size)
; Returns carry=0 on success, carry=1 on failure (including readonly).
fs_write_file_content:
    cmp byte [rel fs_readonly], 1
    je .fail_write
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    mov r8, rcx                  ; save entry index

    lea rdi, [rel fs_table]
    mov rax, rcx
    imul rax, FS_ENTRY_SIZE
    add rdi, rax

    mov eax, [rdi + FS_CONTENT_LBA_OFF]
    cmp eax, 0
    jne .have_lba

    push rdx
    push rsi
    push rdi
    call fs_alloc_block
    pop rdi
    pop rsi
    pop rdx
    cmp rax, 0
    je .fail
    mov [rdi + FS_CONTENT_LBA_OFF], eax

.have_lba:
    mov eax, [rdi + FS_CONTENT_LBA_OFF]
    mov [rdi + FS_CONTENT_SIZE_OFF], edx

    ; copy data to sector_buf
    push rsi
    push rdx
    lea rdi, [rel sector_buf]
    xor rax, rax
    mov rcx, 512/8
    rep stosq
    pop rdx
    pop rsi

    lea rdi, [rel sector_buf]
    mov rcx, rdx
    cmp rcx, 512
    jle .copy_ok
    mov rcx, 512
.copy_ok:
    rep movsb

    ; save entry
    call fs_save

    ; write content sector
    lea rdi, [rel fs_table]
    mov rax, r8
    imul rax, FS_ENTRY_SIZE
    add rdi, rax
    mov eax, [rdi + FS_CONTENT_LBA_OFF]
    cmp eax, 0
    je .fail
    lea rdi, [rel sector_buf]
    call ata_write_sector

.fail_write:
    stc
    ret

.fail:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ============================================================
;  edit_file — simple line-based file editor
;
;  rdi = filename (null-terminated)
;  Shows current content, then reads lines.
;  Empty line (just Enter) saves and exits.
; ============================================================

edit_file:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    ; find file in current directory
    lea rsi, [rel token_buf]
    push rdi
    push rsi
    mov rsi, rdi
    lea rdi, [rel token_buf]
    call copy_str_no_nul
    mov byte [rdi], 0
    pop rsi
    pop rdi

    mov r8, [rel fs_current_dir]
    lea rsi, [rel token_buf]
    call fs_find_child
    cmp rax, -1
    je .create_file

    ; file exists — read its content
    mov rcx, rax
    lea rdi, [rel file_buf]
    call fs_read_file_content

    ; show current content
    cmp rax, 0
    je .editor_loop
    lea rsi, [rel msg_edit_content]
    call print_string
    lea rsi, [rel file_buf]
    call print_string
    call newline
    jmp .editor_loop

.create_file:
    ; create the file via fs_make_file (caller's rdi still has args)
    ; We already consumed it above, so just prompt user to use mkfl first
    lea rsi, [rel err_edit_notfound]
    call print_string
    jmp .done_edit

.editor_loop:
    lea rsi, [rel msg_edit_prompt]
    call print_string

    lea rdi, [rel line_buffer]
    call read_line

    lea rsi, [rel line_buffer]
    mov al, [rsi]
    cmp al, 0
    je .save_exit

    ; append to file_buf
    lea rdi, [rel file_buf]
    ; find end of file_buf
.find_end:
    cmp byte [rdi], 0
    je .append
    inc rdi
    jmp .find_end
.append:
    mov al, [rsi]
    cmp al, 0
    je .append_done
    cmp rdi, file_buf + 510
    jae .full
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .append
.append_done:
    mov byte [rdi], 10       ; newline
    inc rdi
    mov byte [rdi], 0
    jmp .editor_loop

.save_exit:
    ; save file content
    ; find the file again (it was just created or already existed)
    mov r8, [rel fs_current_dir]
    lea rsi, [rel token_buf]
    call fs_find_child
    cmp rax, -1
    je .done_edit

    mov rcx, rax
    lea rsi, [rel file_buf]
    ; calculate size
    lea rdi, [rel file_buf]
    xor rdx, rdx
.sizeloop:
    cmp byte [rdi], 0
    je .save_it
    inc rdx
    inc rdi
    cmp rdx, 512
    jae .save_it
    jmp .sizeloop
.save_it:
    call fs_write_file_content
    lea rsi, [rel msg_edit_saved]
    call print_string
    jmp .done_edit

.full:
    lea rsi, [rel err_edit_full]
    call print_string

.done_edit:
    ; clear file_buf for next use
    lea rdi, [rel file_buf]
    xor rax, rax
    mov rcx, 512/8
    rep stosq

    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
;  exec_script — run a .rsh script file
;
;  rdi = filename. Reads content, executes each line.
; ============================================================

exec_script:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    ; save filename
    lea rsi, [rel token_buf]
    push rdi
    push rsi
    mov rsi, rdi
    lea rdi, [rel token_buf]
    call copy_str_no_nul
    mov byte [rdi], 0
    pop rsi
    pop rdi

    ; find file
    mov r8, [rel fs_current_dir]
    lea rsi, [rel token_buf]
    call fs_find_child
    cmp rax, -1
    je .not_found

    ; read content
    mov rcx, rax
    lea rdi, [rel file_buf]
    call fs_read_file_content
    cmp rax, 0
    je .done_script

    ; execute each line
    lea rsi, [rel file_buf]
.line_loop:
    ; skip leading spaces/newlines
.skip_blank:
    mov al, [rsi]
    cmp al, ' '
    je .skip_c
    cmp al, 10
    je .skip_c
    cmp al, 13
    je .skip_c
    jmp .copy_line
.skip_c:
    inc rsi
    jmp .skip_blank

.copy_line:
    mov al, [rsi]
    cmp al, 0
    je .done_script
    cmp al, 10
    je .run_it
    cmp al, 13
    je .run_it

    lea rdi, [rel cmd_buf]
.copy_loop:
    mov al, [rsi]
    cmp al, 0
    je .copy_done
    cmp al, 10
    je .copy_done
    cmp al, 13
    je .copy_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .copy_loop

.copy_done:
    mov byte [rdi], 0

    push rsi
    lea rdi, [rel cmd_buf]
    call run_command
    pop rsi

    ; skip past newline(s)
    mov al, [rsi]
    cmp al, 10
    jne .line_loop
    inc rsi
    mov al, [rsi]
    cmp al, 13
    jne .line_loop
    inc rsi
    jmp .line_loop

.run_it:
    ; empty line — skip it
    inc rsi
    jmp .line_loop

.not_found:
    lea rsi, [rel err_task_notfound]
    call print_string

.done_script:
    ; clear file_buf
    lea rdi, [rel file_buf]
    xor rax, rax
    mov rcx, 512/8
    rep stosq

    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
;  open_file — display a file's contents
;
;  rdi = filename. Reads and prints the file content.
; ============================================================

open_file:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    lea rsi, [rel token_buf]
    push rdi
    push rsi
    mov rsi, rdi
    lea rdi, [rel token_buf]
    call copy_str_no_nul
    mov byte [rdi], 0
    pop rsi
    pop rdi

    mov r8, [rel fs_current_dir]
    lea rsi, [rel token_buf]
    call fs_find_child
    cmp rax, -1
    je .not_found

    mov rcx, rax
    lea rdi, [rel file_buf]
    call fs_read_file_content
    cmp rax, 0
    je .empty

    lea rsi, [rel file_buf]
    call print_string
    cmp byte [rsi + rax - 1], 10
    je .done_open
    call newline
    jmp .done_open

.empty:
    lea rsi, [rel msg_file_empty]
    call print_string
    jmp .done_open

.not_found:
    lea rsi, [rel err_open_notfound]
    call print_string

.done_open:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ============================================================
;  Data
; ============================================================

banner1 db "Shelly OS  --  64-bit bare metal", 10, 0
banner2 db "rush shell -- try: show ", 34, "some text", 34, "  or  calc 1 + 1", 10, 0
banner3 db "mkf <name>   cf <path>   list   mkfl <name>   -- items persist across reboots", 10, 0
banner4 db "----------------------------------------", 10, 0
prompt_prefix db "rush:", 0
prompt_suffix db "> ", 0
cmd_show    db "show", 0
cmd_calc    db "calc", 0
cmd_mkf     db "mkf", 0
cmd_cf      db "cf", 0
cmd_list    db "list", 0
cmd_mkfl    db "mkfl", 0
cmd_reg     db "reg", 0
cmd_login   db "login", 0
cmd_me      db "me", 0
cmd_help    db "help", 0
cmd_logout  db "logout", 0
cmd_wipe    db "wipe", 0
cmd_edit    db "edit", 0
cmd_task    db "task", 0
cmd_open    db "open", 0
cmd_auth    db "auth", 0
cmd_promo   db "promo", 0
cmd_demo    db "demo", 0
err_unknown db "rush: command not found", 10, 0
err_syntax  db "rush: syntax error (expected: show ", 34, "text", 34, ")", 10, 0
err_divzero db "rush: division by zero", 10, 0
err_mkf_syntax db "rush: syntax error (expected: mkf <name>)", 10, 0
err_mkf_exists db "rush: mkf: a folder with that name already exists here", 10, 0
err_mkf_full   db "rush: mkf: filesystem is full", 10, 0
err_cf_syntax  db "rush: syntax error (expected: cf <path>)", 10, 0
err_cf_notfound db "rush: cf: no such directory", 10, 0
err_mkfl_syntax db "rush: syntax error (expected: mkfl <name>)", 10, 0
err_mkfl_exists db "rush: mkfl: a file with that name already exists here", 10, 0
err_mkfl_full   db "rush: mkfl: filesystem is full", 10, 0
msg_mkf_ok db "folder created", 10, 0
msg_mkfl_ok db "file created", 10, 0
msg_ls_empty db "(empty)", 10, 0
newline_str db 10, 0
str_home db "home", 0
str_dotdot db "..", 0
abs_home_prefix db "/home", 0

err_reg_syntax    db "rush: syntax error (expected: reg <username> <password>)", 10, 0
err_reg_exists    db "rush: reg: username already taken", 10, 0
err_reg_full      db "rush: reg: user table is full", 10, 0
msg_reg_ok        db "registered: ", 0
msg_reg_as        db " as ", 0
err_login_syntax    db "rush: syntax error (expected: login <username> <password>)", 10, 0
err_login_bad_user  db "rush: login: unknown user", 10, 0
err_login_bad_pass  db "rush: login: wrong password", 10, 0
msg_login_ok        db "logged in as ", 0
msg_whoami_nobody db "not logged in", 10, 0
msg_whoami_line1  db "user: ", 0
msg_whoami_line2  db "role: ", 0
err_auth_syntax     db "rush: syntax error (expected: auth <password> <subcommand>)", 10, 0
err_auth_nologin    db "rush: auth: you must be logged in", 10, 0
err_auth_bad_pass   db "rush: auth: wrong password", 10, 0
err_auth_need_admin db "rush: auth: admin privileges required", 10, 0
err_auth_sub        db "rush: auth: unknown sub-command (try promo or demo)", 10, 0
err_promo_syntax    db "rush: syntax error (expected: auth <pass> promo <user> <role>)", 10, 0
err_promo_bad_user  db "rush: promo: unknown user", 10, 0
msg_promo_ok        db "promoted ", 0
msg_promo_to        db " to ", 0
err_demo_syntax     db "rush: syntax error (expected: auth <pass> demo <user>)", 10, 0
err_demo_bad_user   db "rush: demo: unknown user", 10, 0
err_demo_cant       db "rush: demo: cannot demote another admin", 10, 0
msg_demo_ok         db "demoted ", 0
str_role_guest  db "guest", 0
str_role_member db "member", 0
str_role_admin  db "admin", 0
err_var_nf db "rush: variable not found", 10, 0
err_edit_syntax db "rush: syntax error (expected: edit <filename>)", 10, 0
err_edit_notfound db "rush: edit: file not found", 10, 0
err_edit_full db "rush: edit: file too large", 10, 0
err_task_syntax db "rush: syntax error (expected: task <filename>)", 10, 0
err_task_notfound db "rush: task: file not found", 10, 0
msg_logout_ok db "logged out", 10, 0
msg_edit_content db "--- file content ---", 10, 0
msg_edit_prompt db "[edit] ", 0
msg_edit_saved db "file saved", 10, 0
err_open_syntax db "rush: syntax error (expected: open <filename>)", 10, 0
err_open_notfound db "rush: open: file not found", 10, 0
msg_file_empty db "(file is empty)", 10, 0

help_text db "Available commands:", 10, 0
db "  reg <user> <pass>    - register", 10, 0
db "  login <user> <pass>  - log in", 10, 0
db "  me                   - show current user", 10, 0
db "  logout               - log out", 10, 0
db "  wipe                 - clear screen", 10, 0
db "  auth <pass> <sub>    - elevated command", 10, 0
db "  show <var>           - show variable", 10, 0
db '  show "t {v}"         - interpolated print', 10, 0
db "  calc <expr>          - arithmetic", 10, 0
db "  calc <expr> ~ <var>  - pipe result to var", 10, 0
db "  mkf <name>           - create folder", 10, 0
db "  cf <path>            - change directory", 10, 0
db "  list                 - list directory", 10, 0
db "  mkfl <name>          - create file", 10, 0
db "  edit <name>          - edit file", 10, 0
db "  open <name>          - show file contents", 10, 0
db "  task <name.rsh>      - run script", 10, 0
db "  help                 - this help", 10, 0
db "  <v> = <val>          - set variable", 10, 0
db "  ;                    - command separator", 10, 0

sector_buf: times 512 db 0
fs_seg_buf: times 32 db 0
path_buf: times 256 db 0
path_stack: times 16 dq 0
fs_current_dir: dq 0
fs_readonly: db 0
fs_table: times (FS_MAX_ENTRIES * FS_ENTRY_SIZE) db 0

token_buf: times 16 db 0
token_buf2: times 16 db 0
current_user_idx: dq 0
logged_in: db 0
user_table: times (USER_MAX_ENTRIES * USER_ENTRY_SIZE) db 0

cmd_buf: times LINE_BUF_LEN db 0
var_table: times (VAR_MAX * VAR_ENTRY_SIZE) db 0
num_buf: times 64 db 0
calc_val_stack: times 16 dq 0
calc_op_stack: times 16 db 0
calc_val_sp: dq 0
calc_op_sp: dq 0
file_buf: times 512 db 0

line_buffer: times LINE_BUF_LEN db 0

; -----------------------------------------------------------
; Real-mode keyboard trampoline (assembled separately)
; -----------------------------------------------------------
trampoline_start:
incbin "trampoline.bin"
trampoline_end:

align 4096, db 0
