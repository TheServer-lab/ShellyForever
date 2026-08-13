; ============================================================
;  INSTALL.ASM  --  Shelly Installer (.sin packages / .inst scripts)
; ============================================================
; Implements the "ShellyForever Programs & Installer System" spec
; (v0.1) and its "whattodo.inst" instruction language on top of the
; ZIP-container primitives already in zip.asm: a .sin file IS a
; stored-mode .zip (see zip.asm's own scope note - method 0 only),
; so cmd_install reuses zip_find_eocd/zip_unpack_validate verbatim
; and only adds package-specific logic: finding whattodo.inst inside
; the archive, running its instructions, and the program registry.
;
; Commands added (kernel.asm wires these into dispatch + help text,
; same as pack/unpack):
;   install <file.sin>   run a .sin package's installer
;   uninstall <id>        remove a program by its registered id
;
; Also wires a dispatch FALLBACK: typing a bare registered program
; id (e.g. "calc"), with or without a "-back" flag, launches it the
; same way a bare "<n>.run" already does - see reg_lookup_path and
; its call site in kernel.asm's dispatch, right before "unknown
; command". This is what makes spec section 8 ("Program Execution")
; work without a separate "run <id>" command on top of the existing
; "run <path>" one.
;
; Registry format (spec section 5), stored at /sys/programs.sly
; (root's "sys" folder - "/home" is just root's display alias, see
; fs_resolve_path's own alias handling, so the real on-disk path is
; "sys/programs.sly"):
;
;     program = <id>
;     path = <absolute path>
;
; blank-line separated, one entry per program. Only this module ever
; writes the file, so the reader trusts the exact "program = " /
; "path = " prefixes (10 / 7 bytes, space included) rather than
; doing general whitespace-tolerant parsing.
;
; Known gaps / deferred (mirrors zip.asm's own such section):
;   - No transactional rollback: if an instruction mid-script fails,
;     whatever mkdir/copy/program calls already ran stay applied.
;     Spec section 16 only says installation SHOULD stop on error,
;     not that it must undo prior steps - this does the former.
;   - `uninstall` only removes the ONE file recorded as a program's
;     "path" (its entry point) plus the registry entry - not every
;     file a `copy` instruction wrote during install, since v0.1's
;     registry keeps no manifest of those. Matches spec section 9's
;     "SHOULD" (not MUST) and its "preserve unrelated files" rule -
;     deleting files we have no record of would risk exactly that.
;   - `delete` in whattodo.inst refuses to delete folders (every
;     spec example only ever targets a file) and is a non-fatal
;     no-op if the target is already missing (idempotent).
;   - Registry updates are append-at-end: updating an id removes
;     its old two-line entry and appends a fresh one at the bottom,
;     rather than editing in place, so entry order can drift across
;     updates. The content is equivalent either way.
;   - Package/registry size caps mirror zip.asm's own EDIT_MAX-based
;     philosophy: a whole .sin is capped like any other file
;     (EDIT_MAX), whattodo.inst itself at INST_MAX, and the whole
;     programs.sly registry at REG_MAX - all clean errors, not
;     silent truncation.
;   - Not tested in a real boot/QEMU environment - only nasm
;     syntax-checked alongside the rest of the kernel image.
; ============================================================

INST_MAX equ 4096              ; max bytes for one whattodo.inst script
REG_MAX  equ 8192              ; max bytes for the whole programs.sly registry

; ------------------------------------------------------------
; cmd_install: `install <file.sin>`
; ------------------------------------------------------------
cmd_install:
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
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .not_found
    cmp byte [node_type + rax], 2
    je .is_file
    mov rsi, msg_install_not_file
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.is_file:
    mov r12, rax                     ; .sin file node
    call fs_file_len
    cmp rax, ZIP_EOCD_SIZE
    jb .bad_sin
    cmp rax, EDIT_MAX
    ja .too_big
    mov [zip_unpack_len], eax
    mov rax, r12
    mov rdi, zip_buf
    call fs_read_binary_file

    call zip_find_eocd
    cmp al, 1
    je .bad_sin

    call zip_unpack_validate          ; stored-only check (message printed on failure)
    cmp al, 1
    je .ret

    mov rsi, str_whattodo
    call inst_find_entry
    cmp al, 1
    jne .no_inst

    mov eax, [inst_tmp_size]
    cmp eax, INST_MAX-1
    jae .inst_too_big

    ; copy whattodo.inst's bytes out of zip_buf into a private, NUL-
    ; terminated buffer - parsing runs against this copy, not the
    ; archive in place
    mov eax, [inst_tmp_dataoff]
    lea rsi, [zip_buf + rax]
    mov rdi, inst_script_buf
    mov ecx, [inst_tmp_size]
    cld
    rep movsb
    mov byte [rdi], 0

    mov rsi, msg_install_running
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string

    mov rax, inst_script_buf
    mov [inst_content_ptr], rax
    mov byte [kill_flag], 0

.inst_loop:
    call kbd_poll
    cmp byte [kill_flag], 0
    jne .killed

    mov r12, [inst_content_ptr]
    cmp byte [r12], 0
    je .inst_done

    mov rdi, line_buf
    xor r14, r14
.copy_loop:
    mov al, [r12]
    cmp al, 0
    je .line_end
    cmp al, 0x0A
    je .line_end
    cmp r14, LINE_MAX-1
    jae .line_end
    mov [rdi], al
    inc rdi
    inc r14
    inc r12
    jmp .copy_loop
.line_end:
    mov [inst_content_ptr], r12
    cmp byte [r12], 0x0A
    jne .no_nl
    inc r12
    mov [inst_content_ptr], r12
.no_nl:
    mov byte [rdi], 0

    call inst_exec_line
    cmp al, 1
    je .aborted
    cmp al, 2
    je .inst_done                    ; "finish" reached
    jmp .inst_loop

.inst_done:
    mov rsi, msg_install_ok
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    call maybe_auto_sync
.ret:
    ret
.killed:
    mov rsi, msg_install_killed
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.aborted:
    mov rsi, msg_install_aborted
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.no_inst:
    mov rsi, msg_install_no_inst
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.inst_too_big:
    mov rsi, msg_install_inst_too_big
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
.bad_sin:
    mov rsi, msg_install_bad
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.too_big:
    mov rsi, msg_unpack_too_big
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; inst_exec_line: line_buf holds one already-extracted whattodo.inst
; line (may still be blank or a "#" comment - this filters those
; too). Returns al=0 to keep going, al=1 on error (message already
; printed - caller aborts the install), al=2 if this line was
; "finish".
inst_exec_line:
    push rbx
    push rcx
    push rdx
    push r13

    mov r13, line_buf
.skip_sp:
    cmp byte [r13], ' '
    jne .after_sp
    inc r13
    jmp .skip_sp
.after_sp:
    cmp byte [r13], 0
    je .skip_line
    cmp byte [r13], '#'
    je .skip_line

    mov rsi, r13
    mov rdi, inst_cmd_buf
    call next_token
    mov r13, rsi                     ; cursor now past the keyword

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_finish
    call str_eq
    cmp al, 1
    je .k_finish

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_name
    call str_eq
    cmp al, 1
    je .k_name

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_version
    call str_eq
    cmp al, 1
    je .k_version

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_mkdir
    call str_eq
    cmp al, 1
    je .k_mkdir

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_copy
    call str_eq
    cmp al, 1
    je .k_copy

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_delete
    call str_eq
    cmp al, 1
    je .k_delete

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_program
    call str_eq
    cmp al, 1
    je .k_program

    ; unknown instruction word - spec section 15: MUST cause an
    ; installation error, and MUST NOT be handed off to Rush
    mov rsi, msg_install_bad_instr
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, inst_cmd_buf
    call print_string
    mov rsi, newline_str
    call print_string
    mov al, 1
    jmp .out

.k_finish:
    mov al, 2
    jmp .out

.k_name:
    mov rsi, r13
    mov rdi, inst_arg1_buf
    call next_token
    mov r13, rsi
    mov rsi, msg_install_pkg_name
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, inst_arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    xor al, al
    jmp .out

.k_version:
    mov rsi, r13
    mov rdi, inst_arg1_buf
    call next_token
    mov r13, rsi
    xor al, al
    jmp .out

.k_mkdir:
    mov rsi, r13
    mov rdi, inst_arg1_buf
    call next_token
    mov r13, rsi
    cmp byte [inst_arg1_buf], 0
    je .err_need_arg
    call inst_do_mkdir
    jmp .out

.k_copy:
    mov rsi, r13
    mov rdi, inst_arg1_buf
    call next_token
    mov r13, rsi
    mov rsi, r13
    mov rdi, inst_arg2_buf
    call next_token
    mov r13, rsi
    cmp byte [inst_arg1_buf], 0
    je .err_need_arg
    cmp byte [inst_arg2_buf], 0
    je .err_need_arg
    call inst_do_copy
    jmp .out

.k_delete:
    mov rsi, r13
    mov rdi, inst_arg1_buf
    call next_token
    mov r13, rsi
    cmp byte [inst_arg1_buf], 0
    je .err_need_arg
    call inst_do_delete
    jmp .out

.k_program:
    mov rsi, r13
    mov rdi, inst_arg1_buf
    call next_token
    mov r13, rsi
    mov rsi, r13
    mov rdi, inst_arg2_buf
    call next_token
    mov r13, rsi
    cmp byte [inst_arg1_buf], 0
    je .err_need_arg
    cmp byte [inst_arg2_buf], 0
    je .err_need_arg
    call inst_do_program
    jmp .out

.err_need_arg:
    mov rsi, msg_install_bad_instr_arg
    mov al, ATTR_ERROR
    call print_string_attr
    mov al, 1
    jmp .out

.skip_line:
    xor al, al
.out:
    pop r13
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; inst_resolve_create: rsi = absolute destination path (must start
; with '/'). Creates any missing folder components, collapsing a
; leading "home" component exactly the way fs_resolve_path treats
; it (root itself IS "/home" - see that routine's own alias check).
; Returns rax = the resulting parent folder's node index, or -1 on
; a name collision or a full filesystem (message NOT printed here -
; the caller knows which instruction/argument this was for). Copies
; the final path component into inst_leaf_buf.
; ------------------------------------------------------------
inst_resolve_create:
    push rbx
    push rcx
    push rdx
    push rdi
    push r10
    push r12
    mov r12, rsi                     ; path cursor
    cmp byte [r12], '/'
    jne .fail
    inc r12
    xor rbx, rbx                     ; current dir = root
.next_comp:
    mov rdi, inst_comp_buf
.copy_loop:
    mov al, [r12]
    cmp al, 0
    je .comp_done
    cmp al, '/'
    je .comp_done
    mov [rdi], al
    inc r12
    inc rdi
    jmp .copy_loop
.comp_done:
    mov byte [rdi], 0
    cmp byte [r12], '/'
    jne .is_leaf
    inc r12
    cmp rbx, 0
    jne .lookup_or_create
    mov rsi, inst_comp_buf
    mov rdi, str_home_name
    call str_eq
    cmp al, 1
    je .next_comp
.lookup_or_create:
    mov rax, rbx
    mov rsi, inst_comp_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .create_folder
    cmp byte [node_type + rax], 1
    je .have_folder
    jmp .fail                        ; a file is where a folder needs to go
.create_folder:
    mov rax, rbx
    mov rsi, inst_comp_buf
    mov r10, 1
    call fs_create_node
    cmp rax, -1
    je .fail
.have_folder:
    mov rbx, rax
    jmp .next_comp
.is_leaf:
    mov rsi, inst_comp_buf
    mov rdi, inst_leaf_buf
    call str_copy
    mov rax, rbx
    jmp .out
.fail:
    mov rax, -1
.out:
    pop r12
    pop r10
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; inst_do_mkdir: inst_arg1_buf = absolute path. al=0/1.
; ------------------------------------------------------------
inst_do_mkdir:
    mov rsi, inst_arg1_buf
    call inst_resolve_create
    cmp rax, -1
    je .fail
    mov r11, rax
    mov rax, r11
    mov rsi, inst_leaf_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .maybe_exists
    mov rax, r11
    mov rsi, inst_leaf_buf
    mov r10, 1
    call fs_create_node
    cmp rax, -1
    je .fail
    jmp .ok
.maybe_exists:
    cmp byte [node_type + rax], 1
    je .ok                           ; already a folder - mkdir is idempotent
    jmp .fail
.ok:
    xor al, al
    ret
.fail:
    mov rsi, msg_install_mkdir_failed
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, inst_arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    mov al, 1
    ret

; ------------------------------------------------------------
; inst_do_copy: inst_arg1_buf = package-relative file (no "files/"
; prefix - that's added here), inst_arg2_buf = absolute dest path.
; al=0/1.
; ------------------------------------------------------------
inst_do_copy:
    mov rsi, str_files_prefix
    mov rdi, inst_entryname_buf
    call str_copy
    mov rdi, inst_entryname_buf
    mov rsi, inst_arg1_buf
    call str_append

    mov rsi, inst_entryname_buf
    call inst_find_entry
    cmp al, 1
    jne .missing_pkg_file

    mov rsi, inst_arg2_buf
    call inst_resolve_create
    cmp rax, -1
    je .dest_failed
    mov r11, rax                     ; parent dir

    mov rax, r11
    mov rsi, inst_leaf_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .maybe_reuse
    mov rax, r11
    mov rsi, inst_leaf_buf
    mov r10, 2
    call fs_create_node
    cmp rax, -1
    je .dest_failed
    jmp .have_node
.maybe_reuse:
    cmp byte [node_type + rax], 2
    jne .dest_failed                 ; a same-named folder is in the way
.have_node:
    mov r11, rax                     ; destination file node
    mov eax, [inst_tmp_dataoff]
    lea rsi, [zip_buf + rax]
    mov ecx, [inst_tmp_size]
    mov rax, r11
    call fs_write_binary_file
    xor al, al
    ret
.missing_pkg_file:
    mov rsi, msg_install_copy_missing
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, inst_arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    mov al, 1
    ret
.dest_failed:
    mov rsi, msg_install_copy_dest_failed
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, inst_arg2_buf
    call print_string
    mov rsi, newline_str
    call print_string
    mov al, 1
    ret

; ------------------------------------------------------------
; inst_do_delete: inst_arg1_buf = absolute path. Non-fatal (al=0)
; if the target doesn't exist; al=1 if it's a folder.
; ------------------------------------------------------------
inst_do_delete:
    mov rax, 0
    mov rsi, inst_arg1_buf
    mov rdi, inst_leaf_buf
    call fs_resolve_path
    cmp rax, -1
    je .missing
    mov rsi, inst_leaf_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .missing
    cmp byte [node_type + rax], 1
    je .is_folder
    call fs_delete_tree
    xor al, al
    ret
.is_folder:
    mov rsi, msg_install_delete_folder
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, inst_arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    mov al, 1
    ret
.missing:
    xor al, al
    ret

; ------------------------------------------------------------
; inst_do_program: inst_arg1_buf = id, inst_arg2_buf = path. al=0/1.
; ------------------------------------------------------------
inst_do_program:
    mov rsi, inst_arg1_buf
    mov rdi, inst_arg2_buf
    call reg_update
    cmp al, 1
    je .fail
    xor al, al
    ret
.fail:
    mov rsi, msg_install_reg_failed
    mov al, ATTR_ERROR
    call print_string_attr
    mov al, 1
    ret

; ------------------------------------------------------------
; inst_find_entry: rsi = target entry name (C-string, e.g.
; "whattodo.inst" or "files/foo.run"). Scans the archive's already-
; validated central directory (zip_unpack_cdoff/zip_unpack_total,
; set by zip_find_eocd + zip_unpack_validate). On a match, sets
; inst_tmp_dataoff/inst_tmp_size (data offset computed via the
; entry's own LOCAL header, same as zip_unpack_extract does) and
; returns al=1; al=0 if no entry has that exact name.
; ------------------------------------------------------------
inst_find_entry:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    mov r14, rsi                     ; target name ptr
    call str_len                     ; rax = target length, preserves rsi
    mov r11, rax
    mov r12d, [zip_unpack_cdoff]
    mov r13d, [zip_unpack_total]
    xor rbx, rbx
.loop:
    cmp rbx, r13
    jae .notfound
    lea rsi, [zip_buf + r12]
    movzx r8, word [rsi+28]          ; filename length
    movzx r9, word [rsi+30]          ; extra length
    movzx r10, word [rsi+32]         ; comment length
    cmp r8, r11
    jne .no_match
    lea rdi, [rsi+46]
    xor rcx, rcx
.cmpname:
    cmp rcx, r8
    jae .name_matched
    mov al, [rdi+rcx]
    mov dl, [r14+rcx]
    cmp al, dl
    jne .no_match
    inc rcx
    jmp .cmpname
.name_matched:
    mov eax, [rsi+24]                ; uncompressed size (== stored size)
    mov [inst_tmp_size], eax
    mov eax, [rsi+42]                ; local header offset
    lea rdx, [zip_buf + rax]
    movzx rbx, word [rdx+26]         ; local filename length
    movzx rcx, word [rdx+28]         ; local extra length
    add rax, 30
    add rax, rbx
    add rax, rcx
    mov [inst_tmp_dataoff], eax
    mov al, 1
    jmp .out
.no_match:
    mov eax, 46
    add eax, r8d
    add eax, r9d
    add eax, r10d
    add r12d, eax
    inc rbx
    jmp .loop
.notfound:
    xor al, al
.out:
    pop r14
    pop r13
    pop r12
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

; ============================================================
;  Program registry ( /sys/programs.sly )
; ============================================================

; reg_ensure_sys_dir: returns rax = the "sys" folder's node index
; under root, creating it if missing. rax=-1 if a same-named FILE
; is in the way.
reg_ensure_sys_dir:
    push rsi
    push r10
    mov rax, 0
    mov rsi, str_sys_name
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .check_type
    mov rax, 0
    mov rsi, str_sys_name
    mov r10, 1
    call fs_create_node
    jmp .out
.check_type:
    cmp byte [node_type + rax], 1
    je .out
    mov rax, -1
.out:
    pop r10
    pop rsi
    ret

; reg_update: rsi = id (C-string), rdi = path (C-string). Removes
; any existing entry for that id and appends a fresh one. al=0 ok,
; al=1 fail (message NOT printed here - inst_do_program handles it).
reg_update:
    mov [reg_target_id], rsi
    mov [reg_target_path], rdi
    call reg_ensure_sys_dir
    cmp rax, -1
    je .fail
    mov r15, rax                     ; sys dir idx

    mov rax, r15
    mov rsi, str_programs_sly
    mov r10, 2
    call fs_find_child
    mov r14, rax                     ; existing registry file idx, or -1

    cmp r14, -1
    je .no_existing
    mov rax, r14
    call fs_file_len
    cmp rax, REG_MAX-1
    ja .fail
    mov rax, r14
    mov rdi, fs_io_buf
    call fs_read_binary_file         ; rax = bytes copied
    mov byte [fs_io_buf + rax], 0
    jmp .have_content
.no_existing:
    mov byte [fs_io_buf], 0
.have_content:
    call reg_filter_out              ; rebuilds reg_out_buf without [reg_target_id]'s old entry
    call reg_append_entry            ; appends the fresh entry at the end

    cmp r14, -1
    jne .have_node
    mov rax, r15
    mov rsi, str_programs_sly
    mov r10, 2
    call fs_create_node
    cmp rax, -1
    je .fail
    mov r14, rax
.have_node:
    mov rax, r14
    mov rsi, reg_out_buf
    mov ecx, [reg_out_len]
    call fs_write_binary_file
    jc .fail
    xor al, al
    ret
.fail:
    mov al, 1
    ret

; reg_filter_out: reads NUL-terminated content from fs_io_buf, and
; copies every line into reg_out_buf EXCEPT the "program = <id>" /
; "path = <value>" pair matching [reg_target_id] (plus one blank
; separator line after it, if present). Sets reg_out_len, sets
; reg_found_flag to 1 if a match was removed, and copies that
; entry's path value into reg_matched_path_buf (used by uninstall;
; empty string if nothing matched).
reg_filter_out:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    push r13
    mov dword [reg_out_len], 0
    mov byte [reg_found_flag], 0
    mov byte [reg_matched_path_buf], 0
    mov rsi, fs_io_buf
.loop:
    cmp byte [rsi], 0
    je .done
    mov r12, rsi                     ; line start
.find_eol:
    cmp byte [rsi], 0
    je .eol
    cmp byte [rsi], 0x0A
    je .eol
    inc rsi
    jmp .find_eol
.eol:
    mov r13, rsi                     ; line end (exclusive)
    mov rdi, r13
    mov rsi, r12
    call reg_line_is_program_match
    cmp al, 1
    je .skip_entry
    mov rsi, r12
    mov rcx, r13
    sub rcx, r12
    call reg_out_append_bytes
    cmp byte [r13], 0x0A
    jne .after_copy
    mov al, 0x0A
    call reg_out_append_byte
.after_copy:
    mov rsi, r13
    cmp byte [rsi], 0x0A
    jne .loop
    inc rsi
    jmp .loop
.skip_entry:
    mov byte [reg_found_flag], 1
    mov rsi, r13
    cmp byte [rsi], 0x0A
    jne .no_path_line
    inc rsi
    mov r8, rsi                      ; path line start
.find_eol2:
    cmp byte [rsi], 0
    je .eol2
    cmp byte [rsi], 0x0A
    je .eol2
    inc rsi
    jmp .find_eol2
.eol2:
    mov r9, rsi                      ; path line end
    mov rcx, r9
    sub rcx, r8
    cmp rcx, 7
    jb .skip_past_pathline
    push rcx
    xor rdx, rdx
.pfxcmp:
    cmp rdx, 7
    jae .pfxok
    mov al, [r8+rdx]
    mov bl, [str_path_prefix+rdx]
    cmp al, bl
    jne .pfxfail
    inc rdx
    jmp .pfxcmp
.pfxok:
    lea rsi, [r8+7]
    mov rdi, reg_matched_path_buf
    mov rcx, r9
    sub rcx, rsi
.cpy:
    cmp rcx, 0
    je .cpy_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .cpy
.cpy_done:
    mov byte [rdi], 0
.pfxfail:
    pop rcx
.skip_past_pathline:
    mov rsi, r9
.no_path_line:
    cmp byte [rsi], 0x0A
    jne .maybe_blank2
    inc rsi
.maybe_blank2:
    cmp byte [rsi], 0x0A
    jne .after_skip2
    inc rsi
.after_skip2:
    jmp .loop
.done:
    pop r13
    pop r12
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; reg_append_entry: appends "program = <id>\npath = <path>\n" (using
; [reg_target_id]/[reg_target_path]) to reg_out_buf, preceded by a
; blank-line separator if reg_out_buf isn't currently empty.
reg_append_entry:
    cmp dword [reg_out_len], 0
    je .no_sep
    mov al, 0x0A
    call reg_out_append_byte
.no_sep:
    mov rsi, str_program_prefix
    call reg_out_append_str
    mov rsi, [reg_target_id]
    call reg_out_append_str
    mov al, 0x0A
    call reg_out_append_byte
    mov rsi, str_path_prefix
    call reg_out_append_str
    mov rsi, [reg_target_path]
    call reg_out_append_str
    mov al, 0x0A
    call reg_out_append_byte
    ret

; reg_out_append_bytes: rsi = ptr, rcx = length. Appends to
; reg_out_buf at reg_out_len (silently stops at REG_MAX-1 - a
; registry big enough to hit that cap is a clean, if unlikely, edge
; case rather than memory corruption).
reg_out_append_bytes:
    push rax
    push rdi
    push rdx
.loop:
    cmp rcx, 0
    je .done
    mov edx, [reg_out_len]
    cmp edx, REG_MAX-1
    jae .done
    lea rdi, [reg_out_buf + rdx]
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc dword [reg_out_len]
    dec rcx
    jmp .loop
.done:
    pop rdx
    pop rdi
    pop rax
    ret

; reg_out_append_byte: al = byte to append.
reg_out_append_byte:
    push rdi
    push rdx
    mov edx, [reg_out_len]
    cmp edx, REG_MAX-1
    jae .done
    lea rdi, [reg_out_buf + rdx]
    mov [rdi], al
    inc dword [reg_out_len]
.done:
    pop rdx
    pop rdi
    ret

; reg_out_append_str: rsi = NUL-terminated string.
reg_out_append_str:
    push rax
    push rcx
    push rsi
    call str_len
    mov rcx, rax
    call reg_out_append_bytes
    pop rsi
    pop rcx
    pop rax
    ret

; reg_line_is_program_match: rsi = line start, rdi = line end
; (exclusive - neither is NUL-terminated at that boundary, so this
; can't just call str_eq). al=1 if the line reads exactly
; "program = " + the C-string at [reg_target_id].
reg_line_is_program_match:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    mov rcx, rdi
    sub rcx, rsi
    cmp rcx, 10
    jb .no
    xor r10, r10
.pfx:
    cmp r10, 10
    jae .pfxok
    mov al, [rsi+r10]
    mov r8b, [str_program_prefix+r10]
    cmp al, r8b
    jne .no
    inc r10
    jmp .pfx
.pfxok:
    lea r8, [rsi+10]                 ; start of id-in-line
    mov r9, rdi                      ; end of id-in-line
    sub rcx, 10                      ; id-in-line length
    push rsi
    mov rsi, [reg_target_id]
    call str_len                     ; rax = target id length, preserves rsi
    pop rsi
    cmp rax, rcx
    jne .no
    xor r10, r10
    mov rdx, [reg_target_id]
.idcmp:
    cmp r10, rcx
    jae .yes
    mov al, [r8+r10]
    mov bl, [rdx+r10]
    cmp al, bl
    jne .no
    inc r10
    jmp .idcmp
.yes:
    mov al, 1
    jmp .out
.no:
    xor al, al
.out:
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; reg_lookup_path: rsi = id (C-string), rdi = destination buffer.
; al=1 and dest filled if a registered program has that id; al=0
; otherwise (dest left as an empty string). Used by kernel.asm's
; dispatch fallback so a bare identifier launches its program.
reg_lookup_path:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r13
    mov [reg_target_id], rsi
    mov r13, rdi
    mov byte [r13], 0

    mov rax, 0
    mov rsi, str_sys_name
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .notfound
    cmp byte [node_type + rax], 1
    jne .notfound
    mov rsi, str_programs_sly
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .notfound
    mov r9, rax                      ; registry file node idx
    call fs_file_len
    cmp rax, REG_MAX-1
    ja .notfound
    mov rax, r9
    mov rdi, fs_io_buf
    call fs_read_binary_file
    mov byte [fs_io_buf + rax], 0

    mov rsi, fs_io_buf
.loop:
    cmp byte [rsi], 0
    je .notfound
    mov r8, rsi                      ; line start
.find_eol:
    cmp byte [rsi], 0
    je .eol
    cmp byte [rsi], 0x0A
    je .eol
    inc rsi
    jmp .find_eol
.eol:
    mov rdi, rsi                     ; line end
    push rsi
    mov rsi, r8
    call reg_line_is_program_match
    pop rsi
    cmp al, 1
    je .found_program_line
    cmp byte [rsi], 0x0A
    jne .loop
    inc rsi
    jmp .loop
.found_program_line:
    cmp byte [rsi], 0x0A
    jne .notfound                    ; malformed - no path line follows
    inc rsi
    mov r8, rsi                      ; path line start
.find_eol2:
    cmp byte [rsi], 0
    je .eol2
    cmp byte [rsi], 0x0A
    je .eol2
    inc rsi
    jmp .find_eol2
.eol2:
    mov r9, rsi                      ; path line end
    mov rcx, r9
    sub rcx, r8
    cmp rcx, 7
    jb .notfound
    xor rdx, rdx
.pfx2:
    cmp rdx, 7
    jae .pfx2ok
    mov al, [r8+rdx]
    mov bl, [str_path_prefix+rdx]
    cmp al, bl
    jne .notfound
    inc rdx
    jmp .pfx2
.pfx2ok:
    lea rsi, [r8+7]
    mov rdi, r13
    mov rcx, r9
    sub rcx, rsi
.cpy2:
    cmp rcx, 0
    je .cpy2done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .cpy2
.cpy2done:
    mov byte [rdi], 0
    mov al, 1
    jmp .out
.notfound:
    xor al, al
.out:
    pop r13
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; cmd_uninstall: `uninstall <id>`
; ------------------------------------------------------------
cmd_uninstall:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    mov rax, 0
    mov rsi, str_sys_name
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .not_installed
    cmp byte [node_type + rax], 1
    jne .not_installed
    mov r15, rax

    mov rax, r15
    mov rsi, str_programs_sly
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .not_installed
    mov r14, rax                     ; registry file node idx

    mov rax, r14
    call fs_file_len
    cmp rax, REG_MAX-1
    ja .too_big
    mov rax, r14
    mov rdi, fs_io_buf
    call fs_read_binary_file
    mov byte [fs_io_buf + rax], 0

    mov rsi, arg1_buf
    mov [reg_target_id], rsi
    call reg_filter_out
    cmp byte [reg_found_flag], 0
    je .not_installed

    cmp byte [reg_matched_path_buf], 0
    je .skip_file_delete
    mov rax, 0
    mov rsi, reg_matched_path_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .skip_file_delete
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .skip_file_delete
    call fs_delete_tree
.skip_file_delete:

    mov rax, r14
    mov rsi, reg_out_buf
    mov ecx, [reg_out_len]
    call fs_write_binary_file

    mov rsi, msg_uninstall_ok
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    call maybe_auto_sync
    ret
.not_installed:
    mov rsi, msg_uninstall_not_found
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret
.too_big:
    mov rsi, msg_uninstall_too_big
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
; data
; ------------------------------------------------------------
str_install:   db "install", 0
str_uninstall: db "uninstall", 0
str_mksin:     db "mksin", 0
str_whattodo:  db "whattodo.inst", 0
str_files_prefix: db "files/", 0
str_programs_sly:  db "programs.sly", 0
str_program_prefix: db "program = ", 0
str_path_prefix:     db "path = ", 0

str_inst_name:    db "name", 0
str_inst_version: db "version", 0
str_inst_mkdir:   db "mkdir", 0
str_inst_copy:    db "copy", 0
str_inst_delete:  db "delete", 0
str_inst_program: db "program", 0
str_inst_finish:  db "finish", 0

msg_install_not_file:     db "install: not a file: ", 0
msg_install_bad:           db "install: not a valid .sin package (or truncated)", 10, 0
msg_install_no_inst:       db "install: not a valid .sin package (missing whattodo.inst)", 10, 0
msg_install_inst_too_big:  db "install: whattodo.inst exceeds the internal size cap", 10, 0
msg_install_running:       db "install: installing ", 0
msg_install_ok:             db "install: installed ", 0
msg_install_killed:        db "install: cancelled", 10, 0
msg_install_aborted:       db "install: installation stopped after an error", 10, 0
msg_install_bad_instr:     db "install: unknown instruction: ", 0
msg_install_bad_instr_arg: db "install: a whattodo.inst instruction is missing an argument", 10, 0
msg_install_mkdir_failed:  db "install: mkdir failed: ", 0
msg_install_copy_missing:  db "install: package is missing files/", 0
msg_install_copy_dest_failed: db "install: could not create destination: ", 0
msg_install_delete_folder: db "install: whattodo.inst delete refuses to remove a folder: ", 0
msg_install_reg_failed:    db "install: could not update the program registry", 10, 0
msg_install_pkg_name:      db "install: package: ", 0

msg_uninstall_ok:          db "uninstall: removed ", 0
msg_uninstall_not_found:   db "uninstall: no such program: ", 0
msg_uninstall_too_big:     db "uninstall: program registry exceeds the internal size cap", 10, 0

; --- packaging/instruction staging ---
inst_script_buf:    times INST_MAX db 0
inst_content_ptr:   dq 0
inst_cmd_buf:       times 32 db 0
inst_arg1_buf:      times ZIP_NAME_MAX db 0
inst_arg2_buf:      times 160 db 0
inst_comp_buf:      times 64 db 0
inst_leaf_buf:       times NAME_LEN+1 db 0
inst_entryname_buf: times ZIP_NAME_MAX db 0
inst_tmp_dataoff:    dd 0
inst_tmp_size:        dd 0

; --- registry staging ---
reg_target_id:          dq 0
reg_target_path:        dq 0
reg_found_flag:          db 0
ALIGN 8
reg_out_len:              dd 0
reg_matched_path_buf: times 160 db 0
reg_out_buf: times REG_MAX db 0

; ============================================================
;  mksin: build a .sin package from a prepared folder
; ============================================================
; `mksin <folder>` packages an already-prepared folder (one
; containing "whattodo.inst" as a file and "files" as a folder,
; exactly the layout spec section 10/11 requires inside a .sin)
; into "<folder>.sin", ready for `install`.
;
; This does NOT reimplement zip writing: it validates the folder's
; structure and whattodo.inst script first (catching an unknown
; instruction, a missing argument, or a "copy" source that doesn't
; actually exist under files/ - all *before* anything is written),
; then hands off to the existing `pack` command (see zip.asm) to do
; the real stored-mode zipping into "<folder>.zip", and finally
; renames that node to "<folder>.sin" in place - the same in-place
; node_name edit cmd_rname already uses, so no new archive-writing
; code is needed at all.
;
; Known gaps:
;   - Validation only checks the shape of whattodo.inst (known
;     instructions, required args, absolute-looking destinations,
;     and that "copy" sources exist under files/). It can't catch
;     everything `install` might still reject (e.g. a destination
;     that collides with a same-named FOLDER on the *target*
;     machine) since that depends on where it's eventually
;     installed, not on anything visible here.
;   - Leans on `pack`'s own limits (EDIT_MAX total size, 64 files)
;     and its own "refuses if <folder>.zip already exists" rule -
;     mksin checks for a colliding <folder>.zip up front so that
;     failure is reported as an mksin error instead of a raw pack
;     one, but the actual cap enforcement still happens inside pack.
; ------------------------------------------------------------
cmd_mksin:
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
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .not_found
    cmp byte [node_type + rax], 1
    je .is_folder
    mov rsi, msg_mksin_not_folder
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.is_folder:
    mov r15, rax                     ; source folder node

    mov rax, r15
    mov rsi, str_whattodo
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .missing_inst
    mov r14, rax                     ; whattodo.inst node

    mov rax, r15
    mov rsi, str_files_prefix_name
    mov r10, 1
    call fs_find_child
    cmp rax, -1
    je .missing_files
    mov [mksin_files_node], rax

    mov rax, r14
    call fs_file_len
    cmp rax, INST_MAX-1
    jae .inst_too_big
    mov rax, r14
    mov rdi, inst_script_buf
    call fs_read_binary_file
    mov byte [inst_script_buf + rax], 0

    mov rax, inst_script_buf
    mov [inst_content_ptr], rax
    mov qword [mksin_line_no], 0

.val_loop:
    mov r9, [inst_content_ptr]
    cmp byte [r9], 0
    je .val_done
    inc qword [mksin_line_no]
    mov rdi, line_buf
    xor r8, r8
.val_copy:
    mov al, [r9]
    cmp al, 0
    je .val_line_end
    cmp al, 0x0A
    je .val_line_end
    cmp r8, LINE_MAX-1
    jae .val_line_end
    mov [rdi], al
    inc rdi
    inc r8
    inc r9
    jmp .val_copy
.val_line_end:
    mov [inst_content_ptr], r9
    cmp byte [r9], 0x0A
    jne .val_no_nl
    inc r9
    mov [inst_content_ptr], r9
.val_no_nl:
    mov byte [rdi], 0
    call inst_validate_line
    cmp al, 1
    je .invalid                      ; message already printed, with line #
    cmp al, 2
    je .val_done                     ; "finish" reached
    jmp .val_loop
.val_done:

    mov rsi, arg1_buf
    mov rdi, mksin_zip_name
    call str_copy
    mov rdi, mksin_zip_name
    mov rsi, mksin_dot_zip_str
    call str_append

    mov rsi, arg1_buf
    mov rdi, mksin_sin_name
    call str_copy
    mov rdi, mksin_sin_name
    mov rsi, mksin_dot_sin_str
    call str_append

    mov rsi, mksin_sin_name
    call str_len
    cmp rax, NAME_LEN
    jae .name_too_long

    mov rax, [cur_dir]
    mov rsi, mksin_sin_name
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .sin_exists

    mov rax, [cur_dir]
    mov rsi, mksin_zip_name
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .zip_in_way

    ; hand off to the existing `pack` command - arg1_buf is already
    ; the folder name, exactly what "pack <folder>" expects
    call cmd_pack

    mov rax, [cur_dir]
    mov rsi, mksin_zip_name
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .ret                          ; pack already printed its own error

    mov rdi, rax
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    mov rsi, mksin_sin_name
    call str_copy

    call maybe_auto_sync
    mov rsi, msg_mksin_ok
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, mksin_sin_name
    call print_string
    mov rsi, newline_str
    call print_string
.ret:
    ret

.invalid:
    ret
.missing_inst:
    mov rsi, msg_mksin_missing_inst
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.missing_files:
    mov rsi, msg_mksin_missing_files
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.inst_too_big:
    mov rsi, msg_install_inst_too_big
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.sin_exists:
    mov rsi, msg_mksin_sin_exists
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.zip_in_way:
    mov rsi, msg_mksin_zip_in_way
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.name_too_long:
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

; inst_validate_line: line_buf holds one already-extracted
; whattodo.inst line from the SOURCE FOLDER (not a zip). Same
; keyword set as inst_exec_line, but never performs mkdir/copy/
; delete/program - only checks that the instruction is known, that
; its required arguments are present, that mkdir/copy/delete/program
; destination-style paths look absolute, and (for copy) that the
; named source file actually exists under [mksin_files_node].
; Returns al=0 keep going, al=1 error (message printed, includes
; the 1-based line number from [mksin_line_no]), al=2 on "finish".
inst_validate_line:
    push rbx
    push rcx
    push rdx
    push r13

    mov r13, line_buf
.skip_sp:
    cmp byte [r13], ' '
    jne .after_sp
    inc r13
    jmp .skip_sp
.after_sp:
    cmp byte [r13], 0
    je .skip_line
    cmp byte [r13], '#'
    je .skip_line

    mov rsi, r13
    mov rdi, inst_cmd_buf
    call next_token
    mov r13, rsi

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_finish
    call str_eq
    cmp al, 1
    je .k_finish

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_name
    call str_eq
    cmp al, 1
    je .k_take1

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_version
    call str_eq
    cmp al, 1
    je .k_take1

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_mkdir
    call str_eq
    cmp al, 1
    je .k_mkdir

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_copy
    call str_eq
    cmp al, 1
    je .k_copy

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_delete
    call str_eq
    cmp al, 1
    je .k_delete

    mov rsi, inst_cmd_buf
    mov rdi, str_inst_program
    call str_eq
    cmp al, 1
    je .k_program

    mov rsi, msg_mksin_bad_instr
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, inst_cmd_buf
    mov al, ATTR_ERROR
    call print_string_attr
    call .print_line_suffix
    mov al, 1
    jmp .out

.k_finish:
    mov al, 2
    jmp .out

.k_take1:
    mov rsi, r13
    mov rdi, inst_arg1_buf
    call next_token
    mov r13, rsi
    xor al, al
    jmp .out

.k_mkdir:
    mov rsi, r13
    mov rdi, inst_arg1_buf
    call next_token
    mov r13, rsi
    cmp byte [inst_arg1_buf], 0
    je .err_need_arg
    cmp byte [inst_arg1_buf], '/'
    jne .err_not_absolute
    xor al, al
    jmp .out

.k_copy:
    mov rsi, r13
    mov rdi, inst_arg1_buf
    call next_token
    mov r13, rsi
    mov rsi, r13
    mov rdi, inst_arg2_buf
    call next_token
    mov r13, rsi
    cmp byte [inst_arg1_buf], 0
    je .err_need_arg
    cmp byte [inst_arg2_buf], 0
    je .err_need_arg
    cmp byte [inst_arg2_buf], '/'
    jne .err_not_absolute
    mov rax, [mksin_files_node]
    mov rsi, inst_arg1_buf
    call mksin_verify_source
    cmp al, 1
    jne .err_copy_missing
    xor al, al
    jmp .out

.k_delete:
    mov rsi, r13
    mov rdi, inst_arg1_buf
    call next_token
    mov r13, rsi
    cmp byte [inst_arg1_buf], 0
    je .err_need_arg
    cmp byte [inst_arg1_buf], '/'
    jne .err_not_absolute
    xor al, al
    jmp .out

.k_program:
    mov rsi, r13
    mov rdi, inst_arg1_buf
    call next_token
    mov r13, rsi
    mov rsi, r13
    mov rdi, inst_arg2_buf
    call next_token
    mov r13, rsi
    cmp byte [inst_arg1_buf], 0
    je .err_need_arg
    cmp byte [inst_arg2_buf], 0
    je .err_need_arg
    cmp byte [inst_arg2_buf], '/'
    jne .err_not_absolute
    xor al, al
    jmp .out

.err_need_arg:
    mov rsi, msg_mksin_bad_instr_arg
    mov al, ATTR_ERROR
    call print_string_attr
    call .print_line_suffix
    mov al, 1
    jmp .out
.err_not_absolute:
    mov rsi, msg_mksin_not_absolute
    mov al, ATTR_ERROR
    call print_string_attr
    call .print_line_suffix
    mov al, 1
    jmp .out
.err_copy_missing:
    mov rsi, msg_mksin_copy_missing
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, inst_arg1_buf
    mov al, ATTR_ERROR
    call print_string_attr
    call .print_line_suffix
    mov al, 1
    jmp .out

.print_line_suffix:
    push rax
    push rsi
    push rdi
    mov rsi, msg_mksin_line
    mov al, ATTR_ERROR
    call print_string_attr
    mov rax, [mksin_line_no]
    mov rdi, mksin_num_buf
    call int_to_str
    mov rsi, mksin_num_buf
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, msg_mksin_line2
    mov al, ATTR_ERROR
    call print_string_attr
    pop rdi
    pop rsi
    pop rax
    ret

.skip_line:
    xor al, al
.out:
    pop r13
    pop rdx
    pop rcx
    pop rbx
    ret

; mksin_verify_source: rax = starting folder node (files/), rsi =
; package-relative path (may contain '/' for subfolders, no leading
; slash). al=1 if it resolves to an existing FILE under that
; folder, al=0 otherwise.
mksin_verify_source:
    push rbx
    push rdi
    push r10
    push r12
    mov r12, rsi
    mov rbx, rax
.next_comp:
    mov rdi, inst_comp_buf
.copy_loop:
    mov al, [r12]
    cmp al, 0
    je .comp_done
    cmp al, '/'
    je .comp_done
    mov [rdi], al
    inc r12
    inc rdi
    jmp .copy_loop
.comp_done:
    mov byte [rdi], 0
    cmp byte [r12], '/'
    jne .is_leaf
    inc r12
    mov rax, rbx
    mov rsi, inst_comp_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .fail
    cmp byte [node_type + rax], 1
    jne .fail
    mov rbx, rax
    jmp .next_comp
.is_leaf:
    mov rax, rbx
    mov rsi, inst_comp_buf
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .fail
    mov al, 1
    jmp .out
.fail:
    xor al, al
.out:
    pop r12
    pop r10
    pop rdi
    pop rbx
    ret

str_files_prefix_name: db "files", 0
mksin_dot_zip_str: db ".zip", 0
mksin_dot_sin_str: db ".sin", 0

msg_mksin_not_folder:      db "mksin: not a folder: ", 0
msg_mksin_missing_inst:    db "mksin: folder is missing whattodo.inst", 10, 0
msg_mksin_missing_files:   db "mksin: folder is missing a files/ folder", 10, 0
msg_mksin_sin_exists:      db "mksin: that .sin already exists here (del it first)", 10, 0
msg_mksin_zip_in_way:      db "mksin: a colliding .zip already exists here (del it first)", 10, 0
msg_mksin_ok:               db "mksin: built ", 0
msg_mksin_bad_instr:       db "mksin: unknown instruction: ", 0
msg_mksin_bad_instr_arg:   db "mksin: a whattodo.inst instruction is missing an argument", 0
msg_mksin_not_absolute:    db "mksin: destination path must be absolute (start with /)", 0
msg_mksin_copy_missing:    db "mksin: copy source not found under files/: ", 0
msg_mksin_line:            db " (line ", 0
msg_mksin_line2:           db ")", 10, 0

mksin_files_node: dq 0
mksin_line_no:      dq 0
mksin_zip_name: times NAME_LEN+8 db 0
mksin_sin_name:  times NAME_LEN+8 db 0
mksin_num_buf:  times 24 db 0
