; ============================================================
;  ShellyForever  --  kernel.asm
;  Loaded flat at physical address 0x8000 by boot.asm, already
;  running in 64-bit long mode with the first 2MB identity
;  mapped. No IDT/interrupts are set up - keyboard is polled.
; ============================================================

BITS 64
ORG 0x8000

; ---------------- constants ----------------
VGA_BASE        equ 0xB8000
VGA_COLS        equ 80
VGA_ROWS        equ 25
ATTR_NORMAL     equ 0x0A          ; bright green on black
ATTR_PROMPT     equ 0x0E          ; yellow
ATTR_ERROR      equ 0x0C          ; red

MAX_NODES       equ 64
NAME_LEN        equ 32
CONTENT_LEN     equ 160
LINE_MAX        equ 220

MAX_VARS        equ 16
VAR_NAME_LEN    equ 32
MAX_CALC_TOKENS equ 32

; disk region (LBA sectors) where the filesystem is persisted.
; kernel occupies LBA 1..64 (see boot.asm KERNEL_SECTORS), so LBA 100
; leaves plenty of headroom for the kernel to grow.
FS_LBA_START    equ 100

; ============================================================
kernel_entry:
    cli
    mov rsp, 0x9F000

    ; checkpoint 9: kernel code is executing (proves boot.asm's jump into
    ; 0x8000 landed correctly). Matches the DBG16/32/64 checkpoints in
    ; boot.asm - if you see 1..8 but not this, the kernel wasn't loaded/
    ; jumped to correctly; if the OS otherwise looks fine you can ignore it.
    mov rdi, 0xB8000 + (24*80 + 8) * 2
    mov byte [rdi], 'K'
    mov byte [rdi+1], 0x0F

    call clear_screen
    call fs_load                ; loads persisted fs from disk, or fs_init's a fresh one

    mov rsi, banner
    mov al, ATTR_NORMAL
    call print_string_attr

    cmp byte [fs_disk_available], 0
    je .say_no_disk
    cmp byte [fs_loaded_from_disk], 1
    je .say_loaded
    mov rsi, msg_fresh_fs
    mov al, ATTR_NORMAL
    call print_string_attr
    jmp .banner_done
.say_loaded:
    mov rsi, msg_loaded_fs
    mov al, ATTR_NORMAL
    call print_string_attr
    jmp .banner_done
.say_no_disk:
    mov rsi, msg_no_disk
    mov al, ATTR_ERROR
    call print_string_attr
.banner_done:

.shell_loop:
    call print_prompt

    mov rdi, line_buf
    mov rcx, LINE_MAX-1
    call read_line

    ; --- tokenize: cmd, arg1, arg2 ---
    mov rsi, line_buf
    mov rdi, cmd_buf
    call next_token
    mov rdi, arg1_buf
    call next_token
    mov rdi, arg2_buf
    call next_token

    ; empty line -> loop again
    cmp byte [cmd_buf], 0
    je .shell_loop

    call dispatch
    jmp .shell_loop

; ============================================================
; dispatch: compares cmd_buf against known commands
; ============================================================
dispatch:
    ; --- variable assignment:  name = value ---
    mov rsi, arg1_buf
    mov rdi, str_eq_sign
    call str_eq
    cmp al, 1
    je cmd_assign

    mov rsi, cmd_buf
    mov rdi, str_calc
    call str_eq
    cmp al, 1
    je cmd_calc

    mov rsi, cmd_buf
    mov rdi, str_edit
    call str_eq
    cmp al, 1
    je cmd_edit

    mov rsi, cmd_buf
    mov rdi, str_cf
    call str_eq
    cmp al, 1
    je cmd_cf

    mov rsi, cmd_buf
    mov rdi, str_mkf
    call str_eq
    cmp al, 1
    je cmd_mkf

    mov rsi, cmd_buf
    mov rdi, str_mkfl
    call str_eq
    cmp al, 1
    je cmd_mkfl

    mov rsi, cmd_buf
    mov rdi, str_show
    call str_eq
    cmp al, 1
    je cmd_show

    mov rsi, cmd_buf
    mov rdi, str_ls
    call str_eq
    cmp al, 1
    je cmd_ls

    mov rsi, cmd_buf
    mov rdi, str_cat
    call str_eq
    cmp al, 1
    je cmd_cat

    mov rsi, cmd_buf
    mov rdi, str_pwd
    call str_eq
    cmp al, 1
    je cmd_pwd

    mov rsi, cmd_buf
    mov rdi, str_clear
    call str_eq
    cmp al, 1
    je cmd_clear

    mov rsi, cmd_buf
    mov rdi, str_help
    call str_eq
    cmp al, 1
    je cmd_help

    mov rsi, cmd_buf
    mov rdi, str_reboot
    call str_eq
    cmp al, 1
    je cmd_reboot

    mov rsi, cmd_buf
    mov rdi, str_sync
    call str_eq
    cmp al, 1
    je cmd_sync

    mov rsi, cmd_buf
    mov rdi, str_del
    call str_eq
    cmp al, 1
    je cmd_del

    mov rsi, cmd_buf
    mov rdi, str_rmv
    call str_eq
    cmp al, 1
    je cmd_rmv

    mov rsi, cmd_buf
    mov rdi, str_sdown
    call str_eq
    cmp al, 1
    je cmd_sdown

    mov rsi, cmd_buf
    mov rdi, str_rname
    call str_eq
    cmp al, 1
    je cmd_rname

    mov rsi, cmd_buf
    mov rdi, str_cpy
    call str_eq
    cmp al, 1
    je cmd_cpy

    mov rsi, cmd_buf
    mov rdi, str_mov
    call str_eq
    cmp al, 1
    je cmd_mov

    ; unknown command
    mov rsi, msg_unknown1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, cmd_buf
    call print_string
    mov rsi, msg_unknown2
    call print_string
    ret

; ------------------------------------------------------------
cmd_cf:
    cmp byte [arg1_buf], 0
    jne .have_arg
    ret
.have_arg:
    ; fs_resolve_path handles "/", "/home", "..", ".", multi-segment
    ; paths, and plain single names all through one code path now.
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    xor rdi, rdi               ; whole-path mode: resolve every component
    call fs_resolve_path
    cmp rax, -1
    je .not_found
    mov [cur_dir], rax
    ret
.not_found:
    mov rsi, msg_no_folder
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
cmd_mkf:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .bad_path
    mov r11, rax                ; parent dir the new folder goes in
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, -1                ; any type counts as "exists"
    call fs_find_child
    cmp rax, -1
    jne .exists
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 1                 ; type folder
    call fs_create_node
    cmp rax, -1
    je .full
    ret
.exists:
    mov rsi, msg_exists
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.full:
    cmp byte [fs_name_too_long], 1
    je .toolong
    mov rsi, msg_full
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.bad_path:
    mov rsi, msg_bad_path
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
cmd_mkfl:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .bad_path
    mov r11, rax                 ; parent dir the new file goes in
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .exists
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2                  ; type file
    call fs_create_node
    cmp rax, -1
    je .full
    ; rax = new node index, copy arg2 into its content
    mov rbx, rax
    mov rdi, rbx
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    mov rsi, arg2_buf
    call str_copy
    ret
.exists:
    mov rsi, msg_exists
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.full:
    cmp byte [fs_name_too_long], 1
    je .toolong
    mov rsi, msg_full
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.bad_path:
    mov rsi, msg_bad_path
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
cmd_show:
    mov rsi, arg1_buf
    call var_get
    cmp cl, 1
    je .show_var
    mov rsi, arg1_buf
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, newline_str
    call print_string
    ret
.show_var:
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_assign: reached when arg1_buf == "=" ; cmd_buf is the variable
; name, arg2_buf is either a decimal literal or another variable's name.
cmd_assign:
    mov rsi, arg2_buf
    call parse_int
    cmp cl, 1
    je .ca_haveval
    mov rsi, arg2_buf
    call var_get
    cmp cl, 1
    je .ca_haveval
    mov rsi, msg_bad_value
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.ca_haveval:
    mov rbx, rax
    mov rsi, cmd_buf
    call var_set
    ret

; ------------------------------------------------------------
; cmd_calc: re-scans the raw line_buf (untouched by tokenizing) to get
; the full expression after the leading "calc" word, so expressions of
; any length/operator-count are supported (not just 2 args).
cmd_calc:
    mov rsi, line_buf
.cc_skipcmd:
    mov al, [rsi]
    cmp al, 0
    je .cc_noexpr
    cmp al, ' '
    je .cc_skipspaces
    inc rsi
    jmp .cc_skipcmd
.cc_skipspaces:
    mov al, [rsi]
    cmp al, ' '
    jne .cc_haveexpr
    inc rsi
    jmp .cc_skipspaces
.cc_haveexpr:
    cmp byte [rsi], 0
    je .cc_noexpr
    call eval_expr
    cmp cl, 1
    jne .cc_bad
    lea rdi, [calc_out_buf]
    call int_to_str
    mov rsi, calc_out_buf
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, newline_str
    call print_string
    ret
.cc_bad:
    mov rsi, msg_calc_err
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.cc_noexpr:
    mov rsi, msg_calc_need_expr
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
; cmd_edit: opens the built-in editor on an existing file. Types over
; a copy of the file's content (backspace erases, Enter adds a newline),
; ESC ends editing and asks whether to save (y) or discard (n).
cmd_edit:
    cmp byte [arg1_buf], 0
    jne .ce_have_arg
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.ce_have_arg:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .ce_not_found
    push r15
    mov r15, rax

    mov rdi, rax
    imul rdi, CONTENT_LEN
    lea rsi, [node_content + rdi]
    lea rdi, [edit_buf]
    call str_copy

    call clear_screen
    mov rsi, msg_edit_header1
    mov al, ATTR_PROMPT
    call print_string_attr
    mov rsi, arg1_buf
    mov al, ATTR_PROMPT
    call print_string_attr
    mov rsi, msg_edit_header2
    mov al, ATTR_PROMPT
    call print_string_attr

    lea rsi, [edit_buf]
    mov al, ATTR_NORMAL
    call print_string_attr

    lea rsi, [edit_buf]
    call str_len
    push r14
    mov r14, rax
.ce_loop:
    call get_char
    cmp al, 27
    je .ce_finish
    cmp al, 0x0D
    je .ce_newline
    cmp al, 8
    je .ce_bksp
    cmp r14, CONTENT_LEN-1
    jae .ce_loop
    lea rdi, [edit_buf]
    mov [rdi + r14], al
    inc r14
    mov byte [rdi + r14], 0
    push rbx
    mov bl, ATTR_NORMAL
    call putchar
    pop rbx
    jmp .ce_loop
.ce_newline:
    cmp r14, CONTENT_LEN-1
    jae .ce_loop
    lea rdi, [edit_buf]
    mov byte [rdi + r14], 10
    inc r14
    mov byte [rdi + r14], 0
    mov al, 0x0A
    push rbx
    xor bl, bl
    call putchar
    pop rbx
    jmp .ce_loop
.ce_bksp:
    cmp r14, 0
    je .ce_loop
    dec r14
    lea rdi, [edit_buf]
    mov byte [rdi + r14], 0
    call do_backspace
    jmp .ce_loop
.ce_finish:
    mov rsi, msg_save_prompt
    mov al, ATTR_PROMPT
    call print_string_attr
.ce_wait_key:
    call get_char
    cmp al, 'y'
    je .ce_save
    cmp al, 'Y'
    je .ce_save
    cmp al, 'n'
    je .ce_discard
    cmp al, 'N'
    je .ce_discard
    jmp .ce_wait_key
.ce_save:
    mov rdi, r15
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    lea rsi, [edit_buf]
    call str_copy
    call clear_screen
    mov rsi, msg_saved
    mov al, ATTR_NORMAL
    call print_string_attr
    pop r14
    pop r15
    ret
.ce_discard:
    call clear_screen
    mov rsi, msg_discarded
    mov al, ATTR_NORMAL
    call print_string_attr
    pop r14
    pop r15
    ret
.ce_not_found:
    mov rsi, msg_no_file
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
cmd_pwd:
    call print_path
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
cmd_ls:
    xor r9, r9                  ; index
    xor r12, r12                ; found-any flag
.loop:
    cmp r9, MAX_NODES
    jae .done
    cmp byte [node_type + r9], 0
    je .next
    movzx rax, word [node_parent + r9*2]
    cmp rax, [cur_dir]
    jne .next
    mov r12, 1
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rsi, [node_name + rdi]
    mov al, ATTR_NORMAL
    call print_string_attr
    cmp byte [node_type + r9], 1
    jne .isfile
    mov rsi, tag_folder
    jmp .printtag
.isfile:
    mov rsi, tag_file
.printtag:
    call print_string
.next:
    inc r9
    jmp .loop
.done:
    cmp r12, 0
    jne .ret
    mov rsi, msg_empty
    call print_string
.ret:
    ret

; ------------------------------------------------------------
cmd_cat:
    cmp byte [arg1_buf], 0
    jne .have_arg
    ret
.have_arg:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .not_found
    mov r11, rax
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .not_found
    mov rdi, rax
    imul rdi, CONTENT_LEN
    lea rsi, [node_content + rdi]
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, newline_str
    call print_string
    ret
.not_found:
    mov rsi, msg_no_file
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
cmd_clear:
    call clear_screen
    ret

; ------------------------------------------------------------
cmd_help:
    mov rsi, help_text
    mov al, ATTR_NORMAL
    call print_string_attr
    ret

; ------------------------------------------------------------
cmd_sync:
    call fs_save
    jc .fail
    mov rsi, msg_synced
    mov al, ATTR_NORMAL
    call print_string_attr
    ret
.fail:
    mov rsi, msg_sync_failed
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
cmd_reboot:
    call fs_save                ; persist filesystem before restarting (best effort)
.wait_kbd:
    in al, 0x64
    test al, 2
    jnz .wait_kbd
    mov al, 0xFE
    out 0x64, al
.hang:
    hlt
    jmp .hang

; ------------------------------------------------------------
; cmd_del: delete a file in the current folder (folders are untouched -
; use 'rmv' for variables and there is no bulk folder-delete command).
cmd_del:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .not_found
    mov r11, rax
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2                  ; type = file
    call fs_find_child
    cmp rax, -1
    je .not_found
    call fs_delete_node
    ret
.not_found:
    mov rsi, msg_no_entry
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_rmv: remove a variable by name
cmd_rmv:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    mov rsi, arg1_buf
    call var_find
    cmp rax, -1
    je .not_found
    mov r9, rax
    mov byte [var_used + r9], 0
    mov qword [var_value + r9*8], 0
    mov rdi, r9
    imul rdi, VAR_NAME_LEN
    lea rdi, [var_name + rdi]
    mov rcx, VAR_NAME_LEN
    xor al, al
    rep stosb
    ret
.not_found:
    mov rsi, msg_no_var
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_sdown: save the filesystem, then try the legacy shutdown ports
; used by QEMU/Bochs/VirtualBox. No ACPI tables are parsed by this
; kernel, so on real hardware (or an emulator/port combo not listed
; below) none of these will fire and the machine just halts safely.
cmd_sdown:
    call fs_save
    mov rsi, msg_shutting_down
    mov al, ATTR_NORMAL
    call print_string_attr
    mov dx, 0x604                ; QEMU (older versions) ACPI PM control
    mov ax, 0x2000
    out dx, ax
    mov dx, 0xB004                ; Bochs / very old QEMU
    mov ax, 0x2000
    out dx, ax
    mov dx, 0x4004                ; VirtualBox
    mov ax, 0x3400
    out dx, ax
.hang:
    cli
    hlt
    jmp .hang

; ------------------------------------------------------------
; cmd_rname: rename a file or folder in the current folder
cmd_rname:
    cmp byte [arg1_buf], 0
    jne .check2
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.check2:
    cmp byte [arg2_buf], 0
    jne .have_args
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_args:
    mov rsi, arg2_buf
    call str_len
    cmp rax, NAME_LEN
    jae .toolong
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .not_found
    mov r13, rax                ; folder the source lives in
    mov rax, r13
    mov rsi, leaf1_buf
    mov r10, -1                 ; any type
    call fs_find_child
    cmp rax, -1
    je .not_found
    mov r9, rax                 ; node to rename
    mov rax, r13                ; new name is checked/applied in the same folder
    mov rsi, arg2_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .exists
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    mov rsi, arg2_buf
    call str_copy
    ret
.exists:
    mov rsi, msg_exists
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.not_found:
    mov rsi, msg_no_entry
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_cpy: copy a file or folder (recursively) within the current folder
; under a new name
cmd_cpy:
    cmp byte [arg1_buf], 0
    jne .check2
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.check2:
    cmp byte [arg2_buf], 0
    jne .have_args
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_args:
    ; resolve the source path -> (folder, leaf) and find the node
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .not_found
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .not_found
    mov r14, rax                ; src node index

    ; resolve the destination path -> (folder, leaf name to copy as)
    mov rax, [cur_dir]
    mov rsi, arg2_buf
    mov rdi, leaf2_buf
    call fs_resolve_path
    cmp rax, -1
    je .bad_dest
    mov r10, rax                 ; dest parent folder
    mov rax, r14
    mov rsi, leaf2_buf
    call fs_copy_node
    cmp rax, -1
    jne .ret_ok
    cmp byte [fs_name_too_long], 1
    je .toolong
    mov rsi, msg_copy_failed
    mov al, ATTR_ERROR
    call print_string_attr
.ret_ok:
    ret
.toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.bad_dest:
    mov rsi, msg_bad_path
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg2_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret
.not_found:
    mov rsi, msg_no_entry
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_mov: move/rename a file or folder (recursively) within the current
; folder - implemented as copy-then-delete-original.
cmd_mov:
    cmp byte [arg1_buf], 0
    jne .check2
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.check2:
    cmp byte [arg2_buf], 0
    jne .have_args
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_args:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .not_found
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .not_found
    mov r14, rax                 ; remember src idx to delete after copy

    mov rax, [cur_dir]
    mov rsi, arg2_buf
    mov rdi, leaf2_buf
    call fs_resolve_path
    cmp rax, -1
    je .bad_dest
    mov r10, rax                  ; dest parent folder
    mov rax, r14
    mov rsi, leaf2_buf
    call fs_copy_node
    cmp rax, -1
    je .failed
    mov rax, r14
    call fs_delete_tree
    ret
.failed:
    cmp byte [fs_name_too_long], 1
    je .toolong
    mov rsi, msg_copy_failed
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.bad_dest:
    mov rsi, msg_bad_path
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg2_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret
.not_found:
    mov rsi, msg_no_entry
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ============================================================
;  FILESYSTEM
; ============================================================
fs_init:
    mov rdi, node_type
    mov rcx, MAX_NODES
    xor al, al
    rep stosb
    mov byte [node_type], 1          ; root: folder
    mov word [node_parent], 0xFFFF
    lea rdi, [node_name]
    mov rsi, str_home_name
    call str_copy
    mov qword [cur_dir], 0
    ret

; fs_find_child: rax=parent_idx, rsi=name, r10=type filter (-1 = any)
; returns rax = index or -1
fs_find_child:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push rsi
    mov r8, rax                 ; parent to match
    xor r9, r9                  ; loop index
.loop:
    cmp r9, MAX_NODES
    jae .notfound
    cmp byte [node_type + r9], 0
    je .next
    cmp r10, -1
    je .typeok
    movzx rax, byte [node_type + r9]
    cmp rax, r10
    jne .next
.typeok:
    movzx rax, word [node_parent + r9*2]
    cmp rax, r8
    jne .next
    ; compare name
    pop rsi
    push rsi
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    xchg rsi, rdi
    call str_eq
    cmp al, 1
    je .found
.next:
    inc r9
    jmp .loop
.found:
    mov rax, r9
    jmp .out
.notfound:
    mov rax, -1
.out:
    pop rsi
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; fs_create_node: rax=parent_idx, rsi=name, r10=type
; returns rax = new index or -1 if full
fs_create_node:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push rsi
    mov byte [fs_name_too_long], 0
    mov r8, rax                 ; save parent idx before str_len clobbers rax
    ; reject names that won't fit in the fixed NAME_LEN slot (leaving room
    ; for the null terminator) instead of silently overflowing into the
    ; next node's name/type/parent fields
    call str_len
    cmp rax, NAME_LEN
    jae .name_too_long
    xor r9, r9
.loop:
    cmp r9, MAX_NODES
    jae .full
    cmp byte [node_type + r9], 0
    je .free
    inc r9
    jmp .loop
.free:
    mov byte [node_type + r9], r10b
    mov [node_parent + r9*2], r8w
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    pop rsi
    push rsi
    call str_copy
    mov rax, r9
    jmp .out
.name_too_long:
    mov byte [fs_name_too_long], 1
    mov rax, -1
    jmp .out
.full:
    mov rax, -1
.out:
    pop rsi
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; fs_delete_node: rax = node index. Frees just that one node (does not
; touch children - use fs_delete_tree if the node might be a folder with
; contents).
fs_delete_node:
    push rax
    push rdi
    push rcx
    push r9
    mov r9, rax
    mov byte [node_type + r9], 0
    mov word [node_parent + r9*2], 0
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    mov rcx, NAME_LEN
    xor al, al
    rep stosb
    mov rdi, r9
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    mov rcx, CONTENT_LEN
    xor al, al
    rep stosb
    pop r9
    pop rcx
    pop rdi
    pop rax
    ret

; fs_delete_tree: rax = node index. Recursively frees the node and, if
; it's a folder, everything inside it too.
fs_delete_tree:
    push rax
    push r8
    push r13
    mov r8, rax
    cmp byte [node_type + r8], 1
    jne .leaf
    xor r13, r13
.loop:
    cmp r13, MAX_NODES
    jae .leaf
    cmp byte [node_type + r13], 0
    je .next
    movzx rax, word [node_parent + r13*2]
    cmp rax, r8
    jne .next
    mov rax, r13
    call fs_delete_tree
.next:
    inc r13
    jmp .loop
.leaf:
    mov rax, r8
    call fs_delete_node
    pop r13
    pop r8
    pop rax
    ret

; fs_copy_node: rax=src node idx, r10=dest parent idx, rsi=dest name.
; Recursively copies a file, or a folder and everything inside it, to a
; new parent under a new name. Returns rax = new node idx, or -1 if that
; name is already taken at dest or the filesystem is full.
fs_copy_node:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r11
    push r12
    push r13
    mov r8, rax                  ; src idx
    mov r9, r10                  ; dest parent idx

    mov rax, r9
    mov r10, -1
    call fs_find_child            ; rsi (dest name) preserved by callee
    cmp rax, -1
    jne .taken

    movzx r11, byte [node_type + r8]
    mov rax, r9
    mov r10, r11
    call fs_create_node            ; rsi preserved
    cmp rax, -1
    je .full
    mov r12, rax

    cmp r11, 2
    jne .isfolder
    mov rdi, r12
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    mov rax, r8
    imul rax, CONTENT_LEN
    lea rsi, [node_content + rax]
    call str_copy
    jmp .done
.isfolder:
    xor r13, r13
.childloop:
    cmp r13, MAX_NODES
    jae .done
    cmp byte [node_type + r13], 0
    je .childnext
    movzx rax, word [node_parent + r13*2]
    cmp rax, r8
    jne .childnext
    mov rax, r13
    mov r10, r12
    mov rdi, r13
    imul rdi, NAME_LEN
    lea rsi, [node_name + rdi]
    call fs_copy_node
.childnext:
    inc r13
    jmp .childloop
.done:
    mov rax, r12
    jmp .out
.taken:
    mov rax, -1
    jmp .out
.full:
    mov rax, -1
.out:
    pop r13
    pop r12
    pop r11
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; fs_resolve_path: walks a '/'-separated path, one folder at a time,
; using the same node_parent/fs_find_child machinery every other command
; already relies on. Understands "/" (root), "." and ".." (like cf always
; has), collapses repeated or trailing slashes, and treats a leading
; "/home" as an alias for root (same alias cf used to special-case).
;
; in:  rax = starting dir index (normally [cur_dir])
;      rsi = path string, e.g. "docs/notes.txt", "..", "/home/docs", "notes.txt"
;      rdi = 0            -> whole-path mode: every component (including
;                             the last) is resolved as a folder. Used by cf.
;            leaf_buf ptr -> split mode: all components except the last
;                             are resolved as folders; the last component
;                             is copied verbatim into [leaf_buf] instead of
;                             being looked up. Used by anything that names
;                             a file/folder to act on (view, del, rname,
;                             cpy, mov, mkf, mkfl).
; out: rax = resolved dir index, or -1 if a folder component along the way
;            doesn't exist (leaf_buf, if any, is left untouched on failure)
; ============================================================
fs_resolve_path:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r12
    push r13
    push r14
    mov r12, rdi                ; leaf buf ptr, or 0 for whole-path mode
    mov r13, rax                ; running "current dir" as we walk
    mov r14, rsi                ; path cursor

    cmp byte [r14], '/'
    jne .parse_loop
    mov r13, 0                  ; absolute path -> start from root

.parse_loop:
.skip_seps:
    cmp byte [r14], '/'
    jne .extract_check
    inc r14
    jmp .skip_seps
.extract_check:
    cmp byte [r14], 0
    je .success                 ; nothing left to parse - done
    mov rdi, path_comp_buf
.copy_loop:
    mov al, [r14]
    cmp al, 0
    je .comp_done
    cmp al, '/'
    je .comp_done
    mov [rdi], al
    inc rdi
    inc r14
    jmp .copy_loop
.comp_done:
    mov byte [rdi], 0
    ; peek past any trailing slashes to see whether anything real remains
.skip_seps2:
    cmp byte [r14], '/'
    jne .check_last
    inc r14
    jmp .skip_seps2
.check_last:
    cmp byte [r14], 0
    jne .resolve_component      ; more path remains -> this is a folder step
    cmp r12, 0
    je .resolve_component        ; whole-path mode: resolve last comp too
    ; split mode, and this was the last component -> it's the leaf name
    push rsi
    mov rsi, path_comp_buf
    mov rdi, r12
    call str_copy
    pop rsi
    jmp .success
.resolve_component:
    mov rsi, path_comp_buf
    mov rdi, str_updir
    call str_eq
    cmp al, 1
    je .do_updir
    mov rsi, path_comp_buf
    mov rdi, str_dot
    call str_eq
    cmp al, 1
    je .after_resolve            ; "." is a no-op
    ; "/home" alias: while sitting at root, a literal "home" component
    ; is a no-op too (matches the old single-token "/home" special case)
    cmp r13, 0
    jne .lookup_child
    mov rsi, path_comp_buf
    mov rdi, str_home_name
    call str_eq
    cmp al, 1
    je .after_resolve
.lookup_child:
    mov rax, r13
    mov rsi, path_comp_buf
    mov r10, 1                   ; must be a folder to descend into
    call fs_find_child
    cmp rax, -1
    je .notfound
    mov r13, rax
    jmp .after_resolve
.do_updir:
    cmp r13, 0
    je .after_resolve            ; already at root, no-op
    movzx rbx, word [node_parent + r13*2]
    cmp bx, 0xFFFF
    je .after_resolve
    mov r13, rbx
.after_resolve:
    cmp byte [r14], 0
    je .success
    jmp .parse_loop
.notfound:
    mov rax, -1
    jmp .out
.success:
    mov rax, r13
.out:
    pop r14
    pop r13
    pop r12
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
;  DISK PERSISTENCE  (ATA PIO driver, primary bus, LBA28, polling)
; ============================================================
; Ports (primary ATA channel):
;   0x1F0 data, 0x1F1 features/error, 0x1F2 sector count,
;   0x1F3/4/5 LBA low/mid/high, 0x1F6 drive/head, 0x1F7 status/command.
; No IRQs are used anywhere in this kernel, so these routines just
; poll BSY/DRQ in the status register, matching the polled keyboard
; driver's style.

; ata_wait_bsy: block until BSY (bit 7) clears, or give up after a timeout.
; returns CF=0 on success, CF=1 on timeout (no device responding at all,
; e.g. real hardware with no legacy IDE controller / booting off USB).
ATA_TIMEOUT equ 0x400000
ata_wait_bsy:
    push rax
    push rdx
    push rcx
    mov rcx, ATA_TIMEOUT
    mov dx, 0x1F7
.wait:
    in al, dx
    test al, 0x80
    jz .ok
    loop .wait
    pop rcx
    pop rdx
    pop rax
    stc
    ret
.ok:
    pop rcx
    pop rdx
    pop rax
    clc
    ret

; ata_wait_drq: block until DRQ (bit 3) sets, or time out (see ata_wait_bsy)
ata_wait_drq:
    push rax
    push rdx
    push rcx
    mov rcx, ATA_TIMEOUT
    mov dx, 0x1F7
.wait:
    in al, dx
    test al, 0x08
    jnz .ok
    loop .wait
    pop rcx
    pop rdx
    pop rax
    stc
    ret
.ok:
    pop rcx
    pop rdx
    pop rax
    clc
    ret

; ata_read_sector: rax = LBA (28-bit), rdi = 512-byte destination buffer
; returns CF=0 on success, CF=1 on failure/timeout (buffer left untouched
; or partially written - caller should not trust it on failure).
ata_read_sector:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    mov rbx, rax                 ; keep LBA
    call ata_wait_bsy
    jc .fail
    mov dx, 0x1F6
    mov rax, rbx
    shr rax, 24
    and al, 0x0F
    or al, 0xE0                  ; LBA mode, master drive
    out dx, al
    mov dx, 0x1F2
    mov al, 1                    ; sector count = 1
    out dx, al
    mov dx, 0x1F3
    mov al, bl
    out dx, al                   ; LBA[0:7]
    mov dx, 0x1F4
    mov rax, rbx
    shr rax, 8
    out dx, al                   ; LBA[8:15]
    mov dx, 0x1F5
    mov rax, rbx
    shr rax, 16
    out dx, al                   ; LBA[16:23]
    mov dx, 0x1F7
    mov al, 0x20                 ; READ SECTORS (with retry)
    out dx, al
    call ata_wait_bsy
    jc .fail
    call ata_wait_drq
    jc .fail
    mov dx, 0x1F0
    mov rcx, 256                 ; 256 words = 512 bytes
.readloop:
    in ax, dx
    mov [rdi], ax
    add rdi, 2
    loop .readloop
    clc
    jmp .done
.fail:
    stc
.done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ata_write_sector: rax = LBA (28-bit), rsi = 512-byte source buffer
; returns CF=0 on success, CF=1 on failure/timeout.
ata_write_sector:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov rbx, rax
    call ata_wait_bsy
    jc .fail
    mov dx, 0x1F6
    mov rax, rbx
    shr rax, 24
    and al, 0x0F
    or al, 0xE0
    out dx, al
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    mov dx, 0x1F3
    mov al, bl
    out dx, al
    mov dx, 0x1F4
    mov rax, rbx
    shr rax, 8
    out dx, al
    mov dx, 0x1F5
    mov rax, rbx
    shr rax, 16
    out dx, al
    mov dx, 0x1F7
    mov al, 0x30                 ; WRITE SECTORS (with retry)
    out dx, al
    call ata_wait_bsy
    jc .fail
    call ata_wait_drq
    jc .fail
    mov dx, 0x1F0
    mov rcx, 256
.writeloop:
    mov ax, [rsi]
    out dx, ax
    add rsi, 2
    loop .writeloop
    call ata_wait_bsy
    jc .fail
    mov dx, 0x1F7
    mov al, 0xE7                 ; CACHE FLUSH so it actually hits the image
    out dx, al
    call ata_wait_bsy
    jc .fail
    clc
    jmp .done
.fail:
    stc
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; fs_save: serialize node_type/node_parent/node_name/node_content (plus a
; small magic/version header) out to FS_LBA_START.. on disk.
; returns CF=0 on success, CF=1 if the disk isn't there/isn't responding.
fs_save:
    push rax
    push rsi
    push rcx
    cmp byte [fs_disk_available], 0
    je .fail                     ; already known-absent this session, don't retry
    mov byte [fs_disk_header+0], 'S'
    mov byte [fs_disk_header+1], 'F'
    mov byte [fs_disk_header+2], 'F'
    mov byte [fs_disk_header+3], 'S'
    mov byte [fs_disk_header+4], 1     ; format version
    mov byte [fs_disk_header+5], 0
    mov byte [fs_disk_header+6], 0
    mov byte [fs_disk_header+7], 0
    mov rax, FS_LBA_START
    lea rsi, [fs_disk_header]
    mov rcx, FS_SECTORS
.loop:
    push rax
    push rcx
    call ata_write_sector
    pop rcx
    pop rax
    jc .disk_gone
    add rsi, 512
    inc rax
    loop .loop
    pop rcx
    pop rsi
    pop rax
    clc
    ret
.disk_gone:
    mov byte [fs_disk_available], 0
.fail:
    pop rcx
    pop rsi
    pop rax
    stc
    ret

; fs_load: read the persisted region straight into the live fs structures;
; if the magic/version don't check out (blank disk, older format, etc.) or
; there's simply no disk responding at the legacy ATA ports (common on
; real hardware without a PATA/IDE controller, or booting off USB), fall
; back to fs_init for a fresh in-memory-only filesystem instead.
; sets fs_loaded_from_disk and fs_disk_available accordingly.
fs_load:
    push rax
    push rdi
    push rcx
    mov rax, FS_LBA_START
    lea rdi, [fs_disk_header]
    mov rcx, FS_SECTORS
.loop:
    push rax
    push rcx
    call ata_read_sector
    pop rcx
    pop rax
    jc .no_disk
    add rdi, 512
    inc rax
    loop .loop

    cmp byte [fs_disk_header+0], 'S'
    jne .invalid
    cmp byte [fs_disk_header+1], 'F'
    jne .invalid
    cmp byte [fs_disk_header+2], 'F'
    jne .invalid
    cmp byte [fs_disk_header+3], 'S'
    jne .invalid
    cmp byte [fs_disk_header+4], 1
    jne .invalid

    mov qword [cur_dir], 0
    mov byte [fs_loaded_from_disk], 1
    jmp .done
.invalid:
    call fs_init
    mov byte [fs_loaded_from_disk], 0
    jmp .done
.no_disk:
    mov byte [fs_disk_available], 0
    call fs_init
    mov byte [fs_loaded_from_disk], 0
.done:
    pop rcx
    pop rdi
    pop rax
    ret

; ============================================================
;  VARIABLES  (simple name -> int64 table used by assignment/show/calc)
; ============================================================

; str_len: rsi=string -> rax=length (not including null terminator)
str_len:
    push rsi
    xor rax, rax
.sl_loop:
    cmp byte [rsi], 0
    je .sl_done
    inc rax
    inc rsi
    jmp .sl_loop
.sl_done:
    pop rsi
    ret

; var_find: rsi=name -> rax=index or -1. Preserves rsi.
var_find:
    push rsi
    push rdi
    push rcx
    xor rcx, rcx
.vf_loop:
    cmp rcx, MAX_VARS
    jae .vf_notfound
    cmp byte [var_used+rcx], 0
    je .vf_next
    mov rdi, rcx
    imul rdi, VAR_NAME_LEN
    lea rdi, [var_name+rdi]
    push rsi
    push rcx
    call str_eq
    pop rcx
    pop rsi
    cmp al, 1
    je .vf_found
.vf_next:
    inc rcx
    jmp .vf_loop
.vf_found:
    mov rax, rcx
    jmp .vf_out
.vf_notfound:
    mov rax, -1
.vf_out:
    pop rcx
    pop rdi
    pop rsi
    ret

; var_get: rsi=name -> rax=value, cl=1 if found else cl=0 and rax=0
var_get:
    push rsi
    call var_find
    pop rsi
    cmp rax, -1
    je .vg_notfound
    mov r9, rax
    mov rax, [var_value + r9*8]
    mov cl, 1
    ret
.vg_notfound:
    xor rax, rax
    mov cl, 0
    ret

; var_set: rsi=name, rbx=value(int64). Creates the variable if it
; doesn't exist yet, otherwise updates it in place. Silently does
; nothing if the table is full (MAX_VARS reached).
var_set:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi
    push rbx
    call var_find
    pop rbx
    pop rsi
    cmp rax, -1
    jne .vs_have
    xor rcx, rcx
.vs_free:
    cmp rcx, MAX_VARS
    jae .vs_full
    cmp byte [var_used+rcx], 0
    je .vs_got
    inc rcx
    jmp .vs_free
.vs_got:
    mov byte [var_used+rcx], 1
    mov rdi, rcx
    imul rdi, VAR_NAME_LEN
    lea rdi, [var_name+rdi]
    call str_copy
    mov rax, rcx
    jmp .vs_setval
.vs_have:
.vs_setval:
    mov [var_value + rax*8], rbx
.vs_full:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; parse_int: rsi=null-terminated string -> rax=value(int64), cl=1 if the
; whole string was a valid (optionally negative) decimal integer, else
; cl=0. Does not preserve rcx (used to return the flag in cl).
parse_int:
    push rbx
    push rdx
    push r8
    push r9
    xor rax, rax
    xor rdx, rdx
    xor r8, r8
    mov bl, [rsi]
    cmp bl, '-'
    jne .pi_loop
    mov rdx, 1
    inc rsi
.pi_loop:
    mov bl, [rsi]
    cmp bl, 0
    je .pi_end
    cmp bl, '0'
    jb .pi_bad
    cmp bl, '9'
    ja .pi_bad
    imul rax, rax, 10
    movzx r9, bl
    sub r9, '0'
    add rax, r9
    inc r8
    inc rsi
    jmp .pi_loop
.pi_end:
    cmp r8, 0
    je .pi_bad
    cmp rdx, 1
    jne .pi_ok
    neg rax
.pi_ok:
    mov cl, 1
    jmp .pi_out
.pi_bad:
    xor rax, rax
    mov cl, 0
.pi_out:
    pop r9
    pop r8
    pop rdx
    pop rbx
    ret

; int_to_str: rax=value(signed) -> ascii decimal (with leading '-' if
; negative) written null-terminated to buffer rdi.
int_to_str:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    cmp rax, 0
    jge .its_pos
    mov byte [rdi], '-'
    inc rdi
    neg rax
.its_pos:
    cmp rax, 0
    jne .its_digits
    mov byte [rdi], '0'
    inc rdi
    mov byte [rdi], 0
    jmp .its_done
.its_digits:
    mov rsi, rdi
    xor rcx, rcx
.its_loop:
    cmp rax, 0
    je .its_reverse
    mov rbx, 10
    xor rdx, rdx
    div rbx
    add dl, '0'
    push rdx
    inc rcx
    jmp .its_loop
.its_reverse:
    xor rbx, rbx
.its_pop:
    cmp rbx, rcx
    je .its_termin
    pop rdx
    mov [rsi], dl
    inc rsi
    inc rbx
    jmp .its_pop
.its_termin:
    mov byte [rsi], 0
.its_done:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; parse_uint_run: reads a run of decimal digits starting at [rsi],
; advances rsi past them, returns rax=value. Caller must have already
; verified [rsi] is a digit before calling.
parse_uint_run:
    push rbx
    push r9
    xor rax, rax
.pur_loop:
    mov bl, [rsi]
    cmp bl, '0'
    jb .pur_done
    cmp bl, '9'
    ja .pur_done
    imul rax, rax, 10
    movzx r9, bl
    sub r9, '0'
    add rax, r9
    inc rsi
    jmp .pur_loop
.pur_done:
    pop r9
    pop rbx
    ret

; parse_ident_run: reads [a-zA-Z0-9]* starting at [rsi] (caller has
; verified the first char is a letter), advances rsi past it, looks it
; up as a variable. Returns rax=value, cl=1 if found else 0.
parse_ident_run:
    push rdi
    push rbx
    lea rdi, [ident_buf]
.pir_loop:
    mov al, [rsi]
    cmp al, 0
    je .pir_end
    cmp al, 'a'
    jb .pir_check_upper
    cmp al, 'z'
    jbe .pir_take
.pir_check_upper:
    cmp al, 'A'
    jb .pir_check_digit
    cmp al, 'Z'
    jbe .pir_take
.pir_check_digit:
    cmp al, '0'
    jb .pir_end
    cmp al, '9'
    ja .pir_end
.pir_take:
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .pir_loop
.pir_end:
    mov byte [rdi], 0
    mov rbx, rsi
    lea rsi, [ident_buf]
    push r9
    call var_get
    pop r9
    mov rsi, rbx
    pop rbx
    pop rdi
    ret

; ============================================================
;  CALC EXPRESSION EVALUATOR
;  Supports +, -, *, / with standard precedence (* / before + -),
;  unary minus, decimal literals, and variable names as operands.
;  eval_expr: rsi = expression text (null-terminated) -> rax=result,
;  cl=1 if valid else cl=0. Does not preserve rcx (return flag).
; ============================================================
eval_expr:
    push rbx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    xor r8, r8            ; count of parsed values so far
    mov r9, 1             ; expect_operand flag
    xor r10, r10          ; pending unary-negate flag

.ee_loop:
    mov al, [rsi]
    cmp al, 0
    je .ee_endloop
    cmp al, ' '
    je .ee_skip_space
    cmp r9, 1
    je .ee_operand
    jmp .ee_operator
.ee_skip_space:
    inc rsi
    jmp .ee_loop

.ee_operand:
    cmp al, '-'
    jne .ee_o_notminus
    xor r10, 1
    inc rsi
    jmp .ee_loop
.ee_o_notminus:
    cmp al, '+'
    jne .ee_o_notplus
    inc rsi
    jmp .ee_loop
.ee_o_notplus:
    cmp al, '0'
    jb .ee_o_ident
    cmp al, '9'
    ja .ee_o_ident
    call parse_uint_run
    jmp .ee_have_val
.ee_o_ident:
    cmp al, 'a'
    jb .ee_o_upper
    cmp al, 'z'
    jbe .ee_o_doident
.ee_o_upper:
    cmp al, 'A'
    jb .ee_bad
    cmp al, 'Z'
    ja .ee_bad
.ee_o_doident:
    call parse_ident_run
    cmp cl, 1
    jne .ee_bad
.ee_have_val:
    cmp r10, 1
    jne .ee_store
    neg rax
    xor r10, r10
.ee_store:
    cmp r8, MAX_CALC_TOKENS
    jae .ee_bad
    mov [calc_vals + r8*8], rax
    inc r8
    mov r9, 0
    jmp .ee_loop

.ee_operator:
    cmp al, '+'
    je .ee_op_ok
    cmp al, '-'
    je .ee_op_ok
    cmp al, '*'
    je .ee_op_ok
    cmp al, '/'
    je .ee_op_ok
    jmp .ee_bad
.ee_op_ok:
    mov r11, r8
    dec r11
    mov [calc_ops + r11], al
    inc rsi
    mov r9, 1
    jmp .ee_loop

.ee_endloop:
    cmp r9, 1
    je .ee_bad
    cmp r8, 0
    je .ee_bad

    ; ---- pass 1: fold * and / left-to-right ----
    mov rax, [calc_vals]
    mov [calc_vals2], rax
    mov r12, 1
    xor r13, r13
.ee_md_loop:
    mov rax, r8
    dec rax
    cmp r13, rax
    jae .ee_md_done
    movzx rcx, byte [calc_ops + r13]
    mov rdx, r12
    dec rdx
    cmp cl, '*'
    je .ee_domul
    cmp cl, '/'
    je .ee_dodiv
    mov rbx, r13
    inc rbx
    mov rax, [calc_vals + rbx*8]
    mov [calc_vals2 + r12*8], rax
    mov [calc_ops2 + r12 - 1], cl
    inc r12
    jmp .ee_md_next
.ee_domul:
    mov rax, [calc_vals2 + rdx*8]
    mov rbx, r13
    inc rbx
    imul rax, [calc_vals + rbx*8]
    mov [calc_vals2 + rdx*8], rax
    jmp .ee_md_next
.ee_dodiv:
    mov rax, [calc_vals2 + rdx*8]
    mov rbx, r13
    inc rbx
    mov rbx, [calc_vals + rbx*8]
    cmp rbx, 0
    je .ee_bad
    cqo
    idiv rbx
    mov [calc_vals2 + rdx*8], rax
.ee_md_next:
    inc r13
    jmp .ee_md_loop
.ee_md_done:

    ; ---- pass 2: fold + and - left-to-right ----
    mov rax, [calc_vals2]
    xor r14, r14
.ee_as_loop:
    mov rcx, r12
    dec rcx
    cmp r14, rcx
    jae .ee_as_done
    movzx rbx, byte [calc_ops2 + r14]
    mov rdx, r14
    inc rdx
    mov rcx, [calc_vals2 + rdx*8]
    cmp bl, '+'
    je .ee_doadd
    sub rax, rcx
    jmp .ee_as_next
.ee_doadd:
    add rax, rcx
.ee_as_next:
    inc r14
    jmp .ee_as_loop
.ee_as_done:
    mov cl, 1
    jmp .ee_out
.ee_bad:
    xor rax, rax
    mov cl, 0
.ee_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rbx
    ret

; ============================================================
;  SHELL / STRING HELPERS
; ============================================================

; print_prompt: prints "rush>" + current path + ": "
print_prompt:
    mov rsi, prompt_head
    mov al, ATTR_PROMPT
    call print_string_attr
    call print_path
    mov rsi, prompt_tail
    call print_string
    ret

; print_path: walks parent chain of cur_dir, prints /home/.../name
print_path:
    push rax
    push rbx
    push rcx
    push rsi
    xor rcx, rcx                    ; depth counter
    mov rax, [cur_dir]
.collect:
    mov [path_stack + rcx*2], ax
    inc rcx
    movzx rbx, word [node_parent + rax*2]
    cmp bx, 0xFFFF
    je .print
    mov rax, rbx
    jmp .collect
.print:
    mov al, '/'
    mov bl, ATTR_PROMPT
    call putchar
.printloop:
    dec rcx
    movzx rax, word [path_stack + rcx*2]
    imul rax, NAME_LEN
    lea rsi, [node_name + rax]
    mov al, ATTR_PROMPT
    push rcx
    call print_string_attr
    pop rcx
    cmp rcx, 0
    je .done
    mov al, '/'
    mov bl, ATTR_PROMPT
    call putchar
    jmp .printloop
.done:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; next_token: rsi = pointer into source line, rdi = dest buffer
; advances rsi; writes null-terminated token (may be empty) to rdi
; supports "quoted strings with spaces"
next_token:
    push rax
.skip:
    mov al, [rsi]
    cmp al, 0
    je .empty
    cmp al, ' '
    jne .check_quote
    inc rsi
    jmp .skip
.check_quote:
    cmp al, '"'
    jne .plain
    inc rsi
.qloop:
    mov al, [rsi]
    cmp al, 0
    je .term
    cmp al, '"'
    je .qend
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .qloop
.qend:
    inc rsi
    jmp .term
.plain:
.ploop:
    mov al, [rsi]
    cmp al, 0
    je .term
    cmp al, ' '
    je .term
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .ploop
.term:
    mov byte [rdi], 0
    pop rax
    ret
.empty:
    mov byte [rdi], 0
    pop rax
    ret

; str_copy: null-terminated string rsi -> rdi
str_copy:
    push rax
.loop:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    cmp al, 0
    jne .loop
    pop rax
    ret

; str_eq: rsi, rdi null-terminated strings. returns al=1 if equal else 0
str_eq:
    push rsi
    push rdi
.loop:
    mov al, [rsi]
    mov ah, [rdi]
    cmp al, ah
    jne .neq
    cmp al, 0
    je .eq
    inc rsi
    inc rdi
    jmp .loop
.eq:
    pop rdi
    pop rsi
    mov al, 1
    ret
.neq:
    pop rdi
    pop rsi
    mov al, 0
    ret

; ============================================================
;  VGA TEXT OUTPUT
; ============================================================
clear_screen:
    push rax
    push rcx
    push rdi
    mov rdi, VGA_BASE
    mov rcx, VGA_COLS*VGA_ROWS
    mov ax, 0x0720           ; space, light grey
.loop:
    mov [rdi], ax
    add rdi, 2
    loop .loop
    mov byte [cursor_row], 0
    mov byte [cursor_col], 0
    call update_cursor
    pop rdi
    pop rcx
    pop rax
    ret

; update_cursor: programs the VGA CRTC hardware cursor (the blinking block)
; to match cursor_row/cursor_col, via the index/data port pair 0x3D4/0x3D5.
; Without this the blinking cursor never moves from wherever the BIOS left
; it, even though text is being printed elsewhere.
update_cursor:
    push rax
    push rcx
    push rdx
    movzx rcx, byte [cursor_row]
    imul rcx, VGA_COLS
    movzx rdx, byte [cursor_col]
    add rcx, rdx                 ; rcx = linear cursor position

    mov dx, 0x3D4
    mov al, 0x0F                 ; cursor location low byte
    out dx, al
    mov dx, 0x3D5
    mov al, cl
    out dx, al

    mov dx, 0x3D4
    mov al, 0x0E                 ; cursor location high byte
    out dx, al
    mov dx, 0x3D5
    mov al, ch
    out dx, al

    pop rdx
    pop rcx
    pop rax
    ret

; print_string: rsi = null terminated string, default attribute
print_string:
    push rax
    mov al, ATTR_NORMAL
    call print_string_attr
    pop rax
    ret

; print_string_attr: rsi=string, al=attribute byte
print_string_attr:
    push rax
    push rbx
    push rsi
    mov bl, al
.loop:
    mov al, [rsi]
    cmp al, 0
    je .done
    push rbx
    call putchar
    pop rbx
    inc rsi
    jmp .loop
.done:
    pop rsi
    pop rbx
    pop rax
    ret

; putchar: al = char to print, uses attribute in bl if caller set it via
; print_string_attr; falls back to ATTR_NORMAL when called directly.
putchar:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi

    cmp al, 0x0A
    je .newline
    cmp al, 0x0D
    je .newline

    ; compute video offset = (row*80+col)*2
    movzx rcx, byte [cursor_row]
    imul rcx, VGA_COLS
    movzx rdx, byte [cursor_col]
    add rcx, rdx
    imul rcx, 2
    lea rdi, [VGA_BASE]
    add rdi, rcx
    mov [rdi], al
    cmp bl, 0
    jne .useattr
    mov byte [rdi+1], ATTR_NORMAL
    jmp .advance
.useattr:
    mov [rdi+1], bl
.advance:
    inc byte [cursor_col]
    cmp byte [cursor_col], VGA_COLS
    jne .maybe_scroll
    mov byte [cursor_col], 0
    inc byte [cursor_row]
.maybe_scroll:
    cmp byte [cursor_row], VGA_ROWS
    jne .out
    call scroll_screen
    mov byte [cursor_row], VGA_ROWS-1
    jmp .out
.newline:
    mov byte [cursor_col], 0
    inc byte [cursor_row]
    cmp byte [cursor_row], VGA_ROWS
    jne .out
    call scroll_screen
    mov byte [cursor_row], VGA_ROWS-1
.out:
    call update_cursor
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

scroll_screen:
    push rax
    push rcx
    push rsi
    push rdi
    mov rsi, VGA_BASE + (VGA_COLS*2)
    mov rdi, VGA_BASE
    mov rcx, (VGA_ROWS-1)*VGA_COLS
    rep movsw
    mov rdi, VGA_BASE + ((VGA_ROWS-1)*VGA_COLS*2)
    mov rcx, VGA_COLS
    mov ax, 0x0720
.clr:
    mov [rdi], ax
    add rdi, 2
    loop .clr
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ============================================================
;  PS/2 KEYBOARD
; ============================================================

; get_char: blocks until a key is pressed, returns ascii in al
get_char:
    push rbx
.wait:
    in al, 0x64
    test al, 1
    jz .wait
    in al, 0x60
    mov bl, al
    test bl, 0x80
    jnz .breakcode
    cmp bl, 0x2A
    je .setshift
    cmp bl, 0x36
    je .setshift
    movzx rbx, bl
    cmp byte [shift_state], 0
    jne .shifted
    mov al, [kbd_unshift + rbx]
    jmp .have
.shifted:
    mov al, [kbd_shift + rbx]
.have:
    cmp al, 0
    je .wait
    pop rbx
    ret
.setshift:
    mov byte [shift_state], 1
    jmp .wait
.breakcode:
    and bl, 0x7F
    cmp bl, 0x2A
    je .clrshift
    cmp bl, 0x36
    je .clrshift
    jmp .wait
.clrshift:
    mov byte [shift_state], 0
    jmp .wait

; read_line: rdi=buffer, rcx=max chars. Echoes to screen, handles
; backspace, terminates on Enter. Buffer is null terminated.
read_line:
    push rax
    push rbx
    push rdi
    push rcx
    xor r8, r8
    mov r9, rdi
    mov r10, rcx
.loop:
    call get_char
    cmp al, 0x0D
    je .enter
    cmp al, 0x08
    je .bksp
    cmp r8, r10
    jae .loop
    mov [r9 + r8], al
    inc r8
    mov bl, ATTR_NORMAL
    call putchar
    jmp .loop
.bksp:
    cmp r8, 0
    je .loop
    dec r8
    call do_backspace
    jmp .loop
.enter:
    mov byte [r9 + r8], 0
    mov al, 0x0A
    call putchar
    pop rcx
    pop rdi
    pop rbx
    pop rax
    ret

; erase one character visually (move cursor back, blank it)
do_backspace:
    push rax
    cmp byte [cursor_col], 0
    je .maybeup
    dec byte [cursor_col]
    jmp .blank
.maybeup:
    cmp byte [cursor_row], 0
    je .out
    dec byte [cursor_row]
    mov byte [cursor_col], VGA_COLS-1
.blank:
    push rbx
    push rcx
    push rdx
    push rdi
    movzx rcx, byte [cursor_row]
    imul rcx, VGA_COLS
    movzx rdx, byte [cursor_col]
    add rcx, rdx
    imul rcx, 2
    lea rdi, [VGA_BASE]
    add rdi, rcx
    mov byte [rdi], ' '
    mov byte [rdi+1], 0x07
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    call update_cursor
.out:
    pop rax
    ret

; ============================================================
;  DATA
; ============================================================
ALIGN 8
cursor_row:   db 0
cursor_col:   db 0
shift_state:  db 0
cur_dir:      dq 0

banner:
    db "ShellyForever v0.1 -- 'help' for commands", 10, 0

prompt_head: db "rush>", 0
prompt_tail: db ": ", 0
newline_str: db 10, 0

str_slash:  db "/", 0
str_home:   db "/home", 0
str_updir:  db "..", 0
str_dot:    db ".", 0
str_cf:     db "cf", 0
str_mkf:    db "mkf", 0
str_mkfl:   db "mkfl", 0
str_show:   db "show", 0
str_ls:     db "list", 0
str_cat:    db "view", 0
str_pwd:    db "current", 0
str_clear:  db "wipe", 0
str_help:   db "help", 0
str_reboot: db "rboot", 0
str_sync:   db "sync", 0
str_calc:   db "calc", 0
str_edit:   db "edit", 0
str_del:    db "del", 0
str_rmv:    db "rmv", 0
str_sdown:  db "sdown", 0
str_rname:  db "rname", 0
str_cpy:    db "cpy", 0
str_mov:    db "mov", 0
str_eq_sign: db "=", 0
str_home_name: db "home", 0

tag_folder: db "/", 10, 0
tag_file:   db "", 10, 0

msg_unknown1: db "rush: unknown command: ", 0
msg_unknown2: db " (type 'help')", 10, 0
msg_no_folder: db "cf: no such folder: ", 0
msg_bad_path:  db "error: no such folder in path: ", 0
msg_no_file:   db "view: no such file: ", 0
msg_no_entry:  db "no such file or folder: ", 0
msg_no_var:    db "rmv: no such variable: ", 0
msg_need_name: db "error: a name is required", 10, 0
msg_exists:    db "error: that name already exists here", 10, 0
msg_full:      db "error: filesystem is full", 10, 0
msg_name_too_long: db "error: name too long (max 31 characters)", 10, 0
msg_copy_failed: db "error: name already exists at destination, or filesystem is full", 10, 0
msg_shutting_down: db "Shutting down...", 10, 0
msg_empty:     db "(empty)", 10, 0
msg_synced:     db "Filesystem synced to disk.", 10, 0
msg_loaded_fs:  db "Loaded filesystem from disk.", 10, 10, 0
msg_fresh_fs:   db "No saved filesystem found - starting fresh.", 10, 10, 0
msg_no_disk:    db "No disk detected - filesystem will not persist.", 10, 10, 0
msg_sync_failed: db "error: sync failed - disk not available.", 10, 0
msg_bad_value:   db "error: invalid value", 10, 0
msg_calc_err:      db "calc: invalid expression", 10, 0
msg_calc_need_expr: db "calc: need an expression, e.g. calc 1 + 2 * 3", 10, 0
msg_edit_header1: db "-- editing ", 0
msg_edit_header2: db "  (ESC when done, then y/n to save) --", 10, 10, 0
msg_save_prompt:  db 10, "Save changes? (y/n): ", 0
msg_saved:        db 10, "Saved.", 10, 0
msg_discarded:    db 10, "Discarded.", 10, 0

help_text:
    db "Commands (name args accept paths: docs/notes.txt, ../x, /home/x):", 10
    db "  cf <path>          change folder ('cf ..' up, 'cf /home' root)", 10
    db "  mkf <path>         make a folder", 10
    db '  mkfl <path> "txt"  make a file with text content', 10
    db '  show "text"        print a message (or a variable to show its value)', 10
    db "  list               list contents of current folder", 10
    db "  view <path>        print a file's content", 10
    db "  edit <name>        open the built-in editor for a file", 10
    db "  del <path>         delete a file", 10
    db "  rname <path> <new> rename a file or folder (new name stays in same folder)", 10
    db "  cpy <src> <dest>   copy a file or folder (both can be paths)", 10
    db "  mov <src> <dest>   move/rename a file or folder (both can be paths)", 10
    db "  <name> = <value>   set a variable, e.g. a = 1", 10
    db "  rmv <name>         remove a variable", 10
    db "  calc <expr>        evaluate math, e.g. calc 1 + 2 * 3", 10
    db "  current            print current path", 10
    db "  wipe               clear the screen", 10
    db "  sync               save the filesystem to disk", 10
    db "  rboot              save to disk, then restart the machine", 10
    db "  sdown              shut down the machine", 10, 10, 0

; --- scancode set 1 -> ascii tables (index = scancode, 0..0x39) ---
ALIGN 8
kbd_unshift:
    db 0,27,'1','2','3','4','5','6','7','8'      ; 0x00-0x09
    db '9','0','-','=',8,9                        ; 0x0A-0x0F
    db 'q','w','e','r','t','y','u','i','o','p'    ; 0x10-0x19
    db '[',']',13,0                                ; 0x1A-0x1D
    db 'a','s','d','f','g','h','j','k','l',';'    ; 0x1E-0x27
    db 39,'`',0,'\'                                ; 0x28-0x2B
    db 'z','x','c','v','b','n','m',',','.','/'    ; 0x2C-0x35
    db 0,'*',0,' '                                 ; 0x36-0x39

kbd_shift:
    db 0,27,'!','@','#','$','%','^','&','*'       ; 0x00-0x09
    db '(',')','_','+',8,9                         ; 0x0A-0x0F
    db 'Q','W','E','R','T','Y','U','I','O','P'    ; 0x10-0x19
    db '{','}',13,0                                ; 0x1A-0x1D
    db 'A','S','D','F','G','H','J','K','L',':'    ; 0x1E-0x27
    db 34,'~',0,'|'                                ; 0x28-0x2B
    db 'Z','X','C','V','B','N','M','<','>','?'    ; 0x2C-0x35
    db 0,'*',0,' '                                 ; 0x36-0x39

; --- filesystem storage ---
; fs_disk_header..fs_image_end is exactly what fs_save/fs_load ship to/from
; disk as one blob. fs_pad rounds that blob up to a whole number of sectors
; so sector-sized disk I/O never spills into unrelated memory (path_stack
; etc.) that happens to sit right after it.
ALIGN 8
fs_disk_header:
    db 'SFFS'                    ; magic
    db 1                         ; format version
    db 0, 0, 0                   ; reserved
fs_image_start:
node_type:    times MAX_NODES db 0
node_parent:  times MAX_NODES dw 0
node_name:    times MAX_NODES*NAME_LEN db 0
node_content: times MAX_NODES*CONTENT_LEN db 0
fs_image_end:
FS_IMAGE_SIZE equ fs_image_end - fs_disk_header
FS_PAD_SIZE   equ (512 - (FS_IMAGE_SIZE % 512)) % 512
fs_pad:       times FS_PAD_SIZE db 0
fs_disk_block_end:
FS_SECTORS    equ (fs_disk_block_end - fs_disk_header) / 512

fs_loaded_from_disk: db 0
fs_disk_available:   db 1     ; optimistic default; cleared on first ATA failure
fs_name_too_long:    db 0     ; set by fs_create_node when a name won't fit

path_stack:   times 16 dw 0

; --- scratch for fs_resolve_path ---
path_comp_buf: times 64 db 0     ; one path component at a time
leaf1_buf:      times 64 db 0    ; resolved leaf name for arg1_buf paths
leaf2_buf:      times 64 db 0    ; resolved leaf name for arg2_buf paths

; --- line editing buffers ---
line_buf: times LINE_MAX db 0
cmd_buf:  times 32  db 0
arg1_buf: times 96  db 0
arg2_buf: times 160 db 0

; --- variables table (used by assignment, show, and calc) ---
ALIGN 8
var_name:  times MAX_VARS*VAR_NAME_LEN db 0
var_value: times MAX_VARS dq 0
var_used:  times MAX_VARS db 0

; --- calc evaluator scratch ---
ALIGN 8
calc_vals:  times MAX_CALC_TOKENS dq 0
calc_vals2: times MAX_CALC_TOKENS dq 0
calc_ops:   times MAX_CALC_TOKENS db 0
calc_ops2:  times MAX_CALC_TOKENS db 0
calc_out_buf: times 24 db 0
show_num_buf: times 24 db 0
ident_buf:  times 40 db 0

; --- built-in editor buffer (one file's worth of content) ---
edit_buf: times CONTENT_LEN db 0
