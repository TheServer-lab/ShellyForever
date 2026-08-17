; ============================================================
;  PARTY (.pa) LANGUAGE — LEXER
; ============================================================
; Stage 1 of the Party interpreter: turns raw script text into a flat
; array of tokens. No parsing/execution here yet - that's the next
; module. cmd_party currently just reads the file, lexes it, and
; prints the token stream so the lexer can be verified on its own
; before anything is built on top of it.
;
; Design:
;   - Token = 8 bytes: {type:u8, reserved:u8, length:u16, start:u32}
;     start/length point INTO the source buffer (fs_io_buf) rather
;     than copying text out - cheap and matches how the rest of the
;     kernel already slices strings in place (see fs_resolve_path).
;   - Newlines are real tokens (TOK_NEWLINE), not whitespace, since
;     Party statements are newline-terminated - the parser needs to
;     see where a statement ends.
;   - "-45" is NOT a single token: '-' lexes as TOK_MINUS and 45 as
;     TOK_INT; unary minus is a parser concern, same approach as the
;     existing calc evaluator (eval_expr) uses.
;   - Keyword vs identifier is decided here (scan word, then compare
;     against the keyword list) via the existing str_eq helper.
; ============================================================

PARTY_MAX_TOKENS equ 512     ; token array capacity
PARTY_IDENT_MAX  equ 40      ; longest ident/keyword this lexer buffers

; ---- token types ----
TOK_EOF     equ 0
TOK_IDENT   equ 1
TOK_STR     equ 2
TOK_INT     equ 3
TOK_FLOAT   equ 4
TOK_TRUE    equ 5
TOK_FALSE   equ 6
TOK_VARS    equ 7
TOK_IF      equ 8
TOK_ELSE    equ 9
TOK_WHILE   equ 10
TOK_FUNC    equ 11
TOK_RETURN  equ 12
TOK_DISPLAY equ 13
TOK_NEWLINE equ 14
TOK_LBRACE  equ 15
TOK_RBRACE  equ 16
TOK_LPAREN  equ 17
TOK_RPAREN  equ 18
TOK_PLUS    equ 19
TOK_MINUS   equ 20
TOK_STAR    equ 21
TOK_SLASH   equ 22
TOK_EQ      equ 23
TOK_EQEQ    equ 24
TOK_NEQ     equ 25
TOK_LT      equ 26
TOK_LTE     equ 27
TOK_GT      equ 28
TOK_GTE     equ 29
TOK_COMMA   equ 30
TOK_PERCENT equ 31
TOK_READ    equ 32
TOK_RUSH    equ 33          ; `rush <expr>` - run a Rush/ShellyForever shell command line
TOK_COUNT_KNOWN equ 34       ; number of entries in party_tok_names
TOK_ERROR   equ 255

; ------------------------------------------------------------
; cmd_party: shell entry point. "party <file.pa>"
; ------------------------------------------------------------
cmd_party:
    cmp byte [arg1_buf], 0
    jne .check_compile
    mov rsi, msg_party_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.check_compile:
    mov rsi, arg1_buf
    mov rdi, str_compile_flag
    call str_eq
    cmp al, 1
    je .do_compile

    mov rsi, arg1_buf
    mov rdi, str_get_flag
    call str_eq
    cmp al, 1
    je .do_get

    ; Regular script execution: "party test.pa"
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

    lea rdi, [fs_io_buf]
    call fs_read_file

    call party_expand_modules
    cmp byte [party_preproc_ok], 1
    jne .preproc_failed

    lea rsi, [fs_io_buf]
    call party_lex

    cmp byte [party_lex_ok], 1
    jne .lex_failed

    mov rsi, arg2_buf
    mov rdi, str_tokens_flag
    call str_eq
    cmp al, 1
    je .want_tokens

    call party_exec
    cmp byte [party_exec_ok], 1
    jne .exec_failed
    ret

.do_compile:
    ; "party compile test.pa"
    cmp byte [arg2_buf], 0
    jne .have_compile_arg
    mov rsi, msg_party_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_compile_arg:
    mov rax, [cur_dir]
    mov rsi, arg2_buf
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

    lea rdi, [fs_io_buf]
    call fs_read_file

    call party_expand_modules
    cmp byte [party_preproc_ok], 1
    jne .preproc_failed

    lea rsi, [fs_io_buf]
    call party_lex

    cmp byte [party_lex_ok], 1
    jne .lex_failed

    call derive_run_filename
    call party_compile_to_run
    ret

; ---- "party get modulename [outfile.pa]" ----
; Fetches https://raw.githubusercontent.com/TheServer-lab/shellybin/
; refs/heads/main/party/modules/<modulename>.pa over TLS (reusing
; https.asm's cmd_stake machinery) and saves it locally as
; <modulename>.pa in cur_dir, or as the given outfile.pa if a third
; argument is given. Doesn't run or lex the fetched text - it's just
; staged on disk, ready for a `module "modulename.pa"` line or a
; `party modulename.pa` run, same as a hand-written file would be.
.do_get:
    cmp byte [arg2_buf], 0
    jne .pg_have_name
    mov rsi, msg_party_get_usage
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.pg_have_name:
    cmp byte [nic_present], 0
    je .pg_no_nic

    ; a module name is a bare name, not a path - reject '/' up front
    ; rather than let it silently reshape the request URL or the
    ; local destination path
    lea rsi, [arg2_buf]
.pg_scan_slash:
    mov al, [rsi]
    cmp al, 0
    je .pg_slash_ok
    cmp al, '/'
    je .pg_bad_name
    inc rsi
    jmp .pg_scan_slash
.pg_slash_ok:
    lea rsi, [arg2_buf]
    call str_len
    cmp rax, PARTY_GET_NAME_MAX
    ja .pg_too_long

    ; normalize: "party get foo" and "party get foo.pa" name the same
    ; module - strip a redundant trailing ".pa" up front so it isn't
    ; doubled onto the URL/destination below (the server layout and
    ; the local file both already end in ".pa" on their own).
    lea rdi, [party_get_name_buf]
    lea rsi, [arg2_buf]
    call str_copy
    lea rdi, [party_get_name_buf]
    call party_strip_pa_suffix

    ; build the request URL: fixed prefix + modulename + ".pa"
    ; NOTE: str_append expects rdi = start of the destination buffer
    ; (it walks to the end itself) - it must be reset before every
    ; call, not just left wherever str_copy last put it.
    lea rdi, [party_get_url_buf]
    lea rsi, [party_get_url_prefix]
    call str_copy
    lea rdi, [party_get_url_buf]
    lea rsi, [party_get_name_buf]
    call str_append
    lea rdi, [party_get_url_buf]
    lea rsi, [party_get_pa_suffix]
    call str_append

    lea rsi, [party_get_url_buf]
    call http_parse_url
    jc .pg_bad_url
    cmp byte [http_url_scheme], 1
    jne .pg_bad_url          ; shouldn't happen - the prefix is hardcoded https://

    call https_warn_once

    call http_build_get
    mov [tcp_tx_len], eax
    call https_bridge_tx

    mov rsi, msg_party_get_fetching
    call print_string
    lea rsi, [arg2_buf]
    call print_string
    mov rsi, msg_nl
    call print_string

    lea rsi, [http_host_buf]
    mov dx, [http_port]
    call tls_do_exchange
    jc .pg_done               ; tls_do_exchange already printed the error

    ; confirm the server actually said 200 before trusting the body -
    ; otherwise a 404 page (raw.githubusercontent.com returns a small
    ; error body with a non-200 status for a missing file) would get
    ; saved as if it were the module's own source
    lea rsi, [tls_app_rx_buf]
    mov ecx, [tls_app_rx_len]
    call party_check_http_200
    cmp al, 1
    jne .pg_not_found

    call https_find_body
    jc .pg_no_body

    mov rsi, rax
    mov dword [http_body_len], ecx
    test ecx, ecx
    jz .pg_write_file
    cmp ecx, (HTTP_RX_BUF_SIZE - 1)
    jbe .pg_body_fits
    mov ecx, (HTTP_RX_BUF_SIZE - 1)
.pg_body_fits:
    mov dword [http_body_len], ecx
    lea rdi, [http_rx_buf]
    rep movsb
    mov byte [rdi], 0

.pg_write_file:
    ; destination: arg3_buf if given, else "<modulename>.pa" in cur_dir
    cmp byte [arg3_buf], 0
    jne .pg_dest_given
    lea rdi, [party_get_dest_buf]
    lea rsi, [party_get_name_buf]
    call str_copy
    lea rdi, [party_get_dest_buf]
    lea rsi, [party_get_pa_suffix]
    call str_append
    jmp .pg_dest_ready
.pg_dest_given:
    lea rdi, [party_get_dest_buf]
    lea rsi, [arg3_buf]
    call str_copy
.pg_dest_ready:

    mov rax, [cur_dir]
    lea rsi, [party_get_dest_buf]
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .pg_bad_path
    mov r11, rax
    call check_target_sys_auth
    cmp rax, 1
    je .pg_done

    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .pg_overwrite

    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2
    call fs_create_node
    cmp rax, -1
    je .pg_create_fail
    mov r12, rax
    jmp .pg_do_write

.pg_create_fail:
    mov rsi, msg_party_get_createfail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .pg_done

.pg_overwrite:
    mov r12, rax

.pg_do_write:
    mov rax, r12
    lea rsi, [http_rx_buf]
    call fs_write_file
    call maybe_auto_sync

    mov rsi, msg_party_get_saved
    call print_string
    lea rsi, [party_get_dest_buf]
    call print_string
    mov rsi, msg_party_get_hint
    call print_string
    lea rsi, [party_get_dest_buf]
    call print_string
    mov rsi, msg_party_get_hint2
    call print_string
    jmp .pg_done

.pg_not_found:
    mov rsi, msg_party_get_notfound
    mov al, ATTR_ERROR
    call print_string_attr
    lea rsi, [arg2_buf]
    call print_string
    mov rsi, newline_str
    call print_string
    jmp .pg_done

.pg_no_body:
    mov rsi, msg_stake_nobody
    mov al, [cur_normal_attr]
    call print_string_attr
    mov eax, [tls_app_rx_len]
    call tcp_print_dec
    mov rsi, msg_stake_nobody2
    mov al, [cur_normal_attr]
    call print_string_attr
    jmp .pg_done

.pg_bad_url:
    mov rsi, msg_stake_badurl
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .pg_done

.pg_bad_path:
    mov rsi, msg_stake_badpath
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .pg_done

.pg_bad_name:
    mov rsi, msg_party_get_badname
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .pg_done

.pg_too_long:
    mov rsi, msg_party_get_toolong
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .pg_done

.pg_no_nic:
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .pg_done

.pg_done:
    ret

.want_tokens:
    call party_dump_tokens
    ret

.exec_failed:
    mov rsi, msg_party_exec_err
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, [party_err_msg_ptr]
    cmp rsi, 0
    je .exec_failed_line
    call print_string
.exec_failed_line:
    mov rsi, msg_party_err_near
    call print_string
    mov eax, [party_error_line]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

.lex_failed:
    mov rsi, msg_party_lex_err
    mov al, ATTR_ERROR
    call print_string_attr
    mov eax, [party_error_line]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
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

.preproc_failed:
    mov rsi, msg_party_mod_err
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, [party_preproc_err_ptr]
    call print_string
    mov rsi, [party_preproc_err_ptr]   ; re-read: print_string may not preserve rsi
    cmp rsi, msg_party_mod_not_found
    jne .preproc_failed_done
    mov rsi, party_preproc_bad_path
    call print_string
.preproc_failed_done:
    mov rsi, newline_str
    call print_string
    ret

; party_check_http_200: rsi = raw HTTP response buffer, ecx = its
; length. Both "HTTP/1.1" and "HTTP/1.0" are 8 bytes, so the status
; line's 3-digit code always starts at offset 9 regardless of minor
; version. Used by `party get` to make sure a fetched module is
; actually the file, not a server's 404 page (https.asm's
; take/stake now reject non-200 replies too (see http_status_code in
; http.asm) - this local check just stays a plain boolean, since
; `party get` only ever cares about 200-or-not, not the exact code).
; Out: al = 1 if the status code is 200, else 0. Clobbers al only.
party_check_http_200:
    cmp ecx, 12
    jb .pc2_no
    cmp byte [rsi+9], '2'
    jne .pc2_no
    cmp byte [rsi+10], '0'
    jne .pc2_no
    cmp byte [rsi+11], '0'
    jne .pc2_no
    mov al, 1
    ret
.pc2_no:
    xor al, al
    ret

; party_strip_pa_suffix: rdi = NUL-terminated buffer, modified in
; place. If it ends with the literal ".pa", that suffix is dropped;
; otherwise the buffer is left untouched. Used by `party get` (see
; cmd_party's .do_get) so "party get foo" and "party get foo.pa" are
; treated as the same module instead of the latter silently 404ing
; against a "foo.pa.pa" URL. Clobbers rax, rcx, rsi.
party_strip_pa_suffix:
    mov rsi, rdi
    call str_len              ; rax = length; str_len preserves rsi
    cmp rax, 3
    jb .pps_out
    mov rcx, rax
    sub rcx, 3                ; rcx = offset of a possible ".pa"
    lea rsi, [rdi+rcx]
    cmp byte [rsi], '.'
    jne .pps_out
    cmp byte [rsi+1], 'p'
    jne .pps_out
    cmp byte [rsi+2], 'a'
    jne .pps_out
    mov byte [rsi], 0
.pps_out:
    ret

; ============================================================
;  MODULES  (Phase 5)
; ============================================================
; A line of the form
;     module "otherfile.pa"
; splices that file's whole text in at that point, before lexing -
; a textual include, same idea as C's #include or Python's exec of
; another file's source. This is the simplest way to add
; multi-file scripts without teaching the rest of the interpreter
; (one token array over one source buffer - see party_lex's header
; comment) about which file a token or a function body came from:
; flatten everything into one buffer first, then lex/collect/run
; exactly as before. A module is typically just function
; definitions meant to be called from the including script, but
; nothing stops it from having top-level statements too - those run
; in place, in file order, same as if they'd been pasted in by hand.
;
; Include cycles and repeats are handled the boring way: each
; resolved path is only ever expanded once per party_expand_modules
; call (party_module_names), and nesting depth is capped
; (PARTY_MODULE_DEPTH_MAX) so a module that (perhaps indirectly)
; includes itself fails cleanly instead of recursing forever.
; ------------------------------------------------------------

PARTY_MODULE_MAX       equ 8    ; distinct module files one script may include
PARTY_MODULE_DEPTH_MAX equ 3    ; how deeply modules may include modules
PARTY_MOD_PATH_MAX     equ 200  ; NUL-terminated module-path staging size

; party_expand_modules: expands `module "..."` lines in fs_io_buf in
; place (fs_io_buf holds the just-read main script on entry).
; Out: party_preproc_ok = 1 on success, fs_io_buf now holds the fully
; expanded source. On failure, party_preproc_ok = 0,
; party_preproc_err_ptr names the problem (and, for a not-found
; module, party_preproc_bad_path holds the offending path) - fs_io_buf
; is left untouched. Clobbers rax-rdx, rsi, rdi, r8-r15.
party_expand_modules:
    push rbx
    mov byte [party_preproc_ok], 1
    mov qword [party_module_name_count], 0
    lea rax, [party_expand_buf]
    mov qword [party_expand_cursor], rax

    lea rsi, [fs_io_buf]
    xor r15, r15                   ; depth 0 = the top-level script itself
    call party_expand_scan
    cmp byte [party_preproc_ok], 1
    jne .pem_out

    mov rdi, [party_expand_cursor]
    mov byte [rdi], 0
    lea rax, [party_expand_buf]
    sub rdi, rax                   ; rdi = expanded length
    cmp rdi, EDIT_MAX-1
    jb .pem_fits
    lea rsi, [msg_party_mod_too_big]
    mov [party_preproc_err_ptr], rsi
    mov byte [party_preproc_ok], 0
    jmp .pem_out
.pem_fits:
    lea rsi, [party_expand_buf]
    lea rdi, [fs_io_buf]
    call str_copy
.pem_out:
    pop rbx
    ret

; party_expand_scan: rsi = null-terminated text to scan line-by-line,
; r15 = nesting depth of this text (0 for the top-level script).
; Copies ordinary lines straight to [party_expand_cursor]; for each
; `module "path"` line, calls party_expand_include instead. Stops
; (without erroring itself) as soon as party_preproc_ok drops to 0 -
; the routine that set it has already recorded why.
; Clobbers rax-rdx, rsi, rdi, r8-r15 (rbx/r12-r15 saved/restored so a
; recursive call - via party_expand_include - can't disturb the
; caller's line-scan position).
party_expand_scan:
    push rbx
    push r12
    push r13
    push r14
    push r15
.pes_line:
    cmp byte [party_preproc_ok], 0
    je .pes_ret
    cmp byte [rsi], 0
    je .pes_ret
    mov r12, rsi                   ; find end of this line ('\n' or NUL)
.pes_findeol:
    mov al, [r12]
    cmp al, 0
    je .pes_haveeol
    cmp al, 10
    je .pes_haveeol
    inc r12
    jmp .pes_findeol
.pes_haveeol:
    mov r13, rsi                   ; trim leading whitespace, looking for "module"
.pes_skip_ws1:
    cmp r13, r12
    jae .pes_not_module
    mov al, [r13]
    cmp al, ' '
    je .pes_ws1_adv
    cmp al, 9
    je .pes_ws1_adv
    jmp .pes_check_kw
.pes_ws1_adv:
    inc r13
    jmp .pes_skip_ws1
.pes_check_kw:
    lea rbx, [r13+6]
    cmp rbx, r12
    ja .pes_not_module
    cmp byte [r13], 'm'
    jne .pes_not_module
    cmp byte [r13+1], 'o'
    jne .pes_not_module
    cmp byte [r13+2], 'd'
    jne .pes_not_module
    cmp byte [r13+3], 'u'
    jne .pes_not_module
    cmp byte [r13+4], 'l'
    jne .pes_not_module
    cmp byte [r13+5], 'e'
    jne .pes_not_module
    mov al, [r13+6]
    cmp al, ' '
    je .pes_is_module
    cmp al, 9
    je .pes_is_module
    jmp .pes_not_module

.pes_is_module:
    add r13, 6
.pes_skip_ws2:
    cmp r13, r12
    jae .pes_bad_stmt
    mov al, [r13]
    cmp al, ' '
    je .pes_ws2_adv
    cmp al, 9
    je .pes_ws2_adv
    jmp .pes_check_quote
.pes_ws2_adv:
    inc r13
    jmp .pes_skip_ws2
.pes_check_quote:
    cmp byte [r13], '"'
    jne .pes_bad_stmt
    inc r13
    mov r14, r13                   ; r14 = path text start
.pes_find_close:
    cmp r13, r12
    jae .pes_bad_stmt              ; unterminated string on this line
    cmp byte [r13], '"'
    je .pes_found_close
    inc r13
    jmp .pes_find_close
.pes_found_close:
    mov rbx, r13
    sub rbx, r14                   ; rbx = path length
    cmp rbx, PARTY_MOD_PATH_MAX-1
    jb .pes_path_len_ok
    lea rsi, [msg_party_mod_path_long]
    mov [party_preproc_err_ptr], rsi
    mov byte [party_preproc_ok], 0
    jmp .pes_ret
.pes_path_len_ok:
    push rsi
    mov rsi, r14
    lea rdi, [party_mod_path_buf]
    mov rcx, rbx
    rep movsb
    mov byte [rdi], 0
    pop rsi
    inc r13                        ; step past the closing quote
.pes_trail_ws:
    cmp r13, r12
    jae .pes_trail_ok
    mov al, [r13]
    cmp al, ' '
    je .pes_trail_adv
    cmp al, 9
    je .pes_trail_adv
    cmp al, 13
    je .pes_trail_adv
    lea rsi, [msg_party_mod_bad_stmt]
    mov [party_preproc_err_ptr], rsi
    mov byte [party_preproc_ok], 0
    jmp .pes_ret
.pes_trail_adv:
    inc r13
    jmp .pes_trail_ws
.pes_trail_ok:
    call party_expand_include      ; party_mod_path_buf = path, r15 = our depth
    cmp byte [party_preproc_ok], 1
    jne .pes_ret
    jmp .pes_next_line

.pes_bad_stmt:
    lea rsi, [msg_party_mod_bad_stmt]
    mov [party_preproc_err_ptr], rsi
    mov byte [party_preproc_ok], 0
    jmp .pes_ret

.pes_not_module:
    mov rdi, [party_expand_cursor]
    mov rbx, rsi
.pes_copy_loop:
    cmp rbx, r12
    jae .pes_copy_done
    mov al, [rbx]
    mov [rdi], al
    inc rdi
    inc rbx
    jmp .pes_copy_loop
.pes_copy_done:
    mov byte [rdi], 10
    inc rdi
    mov [party_expand_cursor], rdi

.pes_next_line:
    cmp byte [r12], 0
    je .pes_ret
    mov rsi, r12
    inc rsi
    jmp .pes_line
.pes_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; party_expand_include: party_mod_path_buf = NUL-terminated module
; path (as written in the source, resolved relative to cur_dir same
; as the top-level script), r15 = depth of the scan that found this
; include. Resolves + reads the file, recurses into
; party_expand_scan for its own text (at depth r15+1, into a
; per-depth scratch buffer so an outer scan still in progress isn't
; disturbed), and appends its expansion to [party_expand_cursor].
; Silently does nothing if this exact path was already included
; earlier in the same party_expand_modules run.
; Clobbers rax-rdx, rsi, rdi, r8-r11 (rbx/r12-r15 saved/restored).
party_expand_include:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, r15
    inc r12                        ; r12 = new depth
    cmp r12, PARTY_MODULE_DEPTH_MAX
    jbe .pei_depth_ok
    lea rsi, [msg_party_mod_too_deep]
    mov [party_preproc_err_ptr], rsi
    mov byte [party_preproc_ok], 0
    jmp .pei_out
.pei_depth_ok:

    xor r13, r13
.pei_dedup_loop:
    cmp r13, [party_module_name_count]
    jae .pei_dedup_done
    mov rax, r13
    imul rax, PARTY_MOD_PATH_MAX
    lea rsi, [party_mod_path_buf]
    lea rdi, [party_module_names+rax]
    call str_eq
    cmp al, 1
    je .pei_out                    ; already included this run - nothing to do
    inc r13
    jmp .pei_dedup_loop
.pei_dedup_done:

    mov rax, [party_module_name_count]
    cmp rax, PARTY_MODULE_MAX
    jb .pei_count_ok
    lea rsi, [msg_party_mod_too_many]
    mov [party_preproc_err_ptr], rsi
    mov byte [party_preproc_ok], 0
    jmp .pei_out
.pei_count_ok:
    mov rbx, rax
    imul rbx, PARTY_MOD_PATH_MAX
    lea rdi, [party_module_names+rbx]
    lea rsi, [party_mod_path_buf]
    call str_copy
    inc qword [party_module_name_count]

    mov rax, [cur_dir]
    lea rsi, [party_mod_path_buf]
    lea rdi, [party_mod_leaf_buf]
    call fs_resolve_path
    cmp rax, -1
    je .pei_not_found
    mov r14, rax
    mov rax, r14
    lea rsi, [party_mod_leaf_buf]
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .pei_not_found

    mov r13, r12
    dec r13                        ; buffer index = new_depth - 1
    imul r13, EDIT_MAX
    lea rdi, [party_mod_read_buf+r13]
    call fs_read_file

    mov r15, r12                   ; depth parameter for the nested scan
    lea rsi, [party_mod_read_buf+r13]
    call party_expand_scan
    cmp byte [party_preproc_ok], 1
    jne .pei_out

    mov rdi, [party_expand_cursor]
    mov byte [rdi], 10             ; separating newline before whatever follows
    inc rdi
    mov [party_expand_cursor], rdi
    jmp .pei_out

.pei_not_found:
    lea rsi, [msg_party_mod_not_found]
    mov [party_preproc_err_ptr], rsi
    lea rdi, [party_preproc_bad_path]
    lea rsi, [party_mod_path_buf]
    call str_copy
    mov byte [party_preproc_ok], 0

.pei_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

party_preproc_ok:      db 1
ALIGN 8
party_preproc_err_ptr: dq 0
party_expand_cursor:   dq 0
party_module_name_count: dq 0
party_module_names:    times PARTY_MODULE_MAX*PARTY_MOD_PATH_MAX db 0
party_mod_path_buf:    times PARTY_MOD_PATH_MAX db 0
party_mod_leaf_buf:    times 64 db 0
party_preproc_bad_path: times PARTY_MOD_PATH_MAX db 0
party_mod_read_buf:    times PARTY_MODULE_DEPTH_MAX*EDIT_MAX db 0
PARTY_EXPAND_MAX equ EDIT_MAX*2
party_expand_buf:      times PARTY_EXPAND_MAX db 0

msg_party_mod_err:        db 'module: ', 0
msg_party_mod_too_deep:   db 'modules nested too deeply', 0
msg_party_mod_too_many:   db 'too many modules included', 0
msg_party_mod_bad_stmt:   db 'malformed module statement (expected: module "file.pa")', 0
msg_party_mod_path_long:  db 'module path too long', 0
msg_party_mod_not_found:  db 'module file not found: ', 0
msg_party_mod_too_big:    db 'expanded script too large', 0

; ------------------------------------------------------------
; party_lex: rsi = null-terminated source text (in fs_io_buf).
; Fills party_tokens / party_token_count. On success sets
; party_lex_ok=1; on error sets party_lex_ok=0 and party_error_line.
; Clobbers rax-rdx, rsi, rdi, r8-r11. Preserves nothing else it uses
; internally (all saved/restored) except the outputs above.
; ------------------------------------------------------------
party_lex:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rsi                  ; r12 = source base (offset 0)
    mov r13, rsi                  ; r13 = scan cursor
    mov qword [party_src_base], rsi
    mov word [party_token_count], 0
    mov dword [party_error_line], 1
    mov byte [party_lex_ok], 1

.pl_loop:
    mov al, [r13]
    cmp al, 0
    je .pl_eof

    cmp al, ' '
    je .pl_skip
    cmp al, 9                     ; tab
    je .pl_skip
    cmp al, 13                    ; CR - swallow, LF does the real work
    je .pl_skip

    cmp al, 10                    ; LF
    je .pl_newline

    cmp al, '/'
    je .pl_slash_or_comment

    cmp al, '"'
    je .pl_string

    cmp al, '0'
    jb .pl_sym_or_ident
    cmp al, '9'
    jbe .pl_number

.pl_sym_or_ident:
    cmp al, 'a'
    jb .pl_check_upper
    cmp al, 'z'
    jbe .pl_ident
.pl_check_upper:
    cmp al, 'A'
    jb .pl_check_underscore
    cmp al, 'Z'
    jbe .pl_ident
.pl_check_underscore:
    cmp al, '_'
    je .pl_ident

    cmp al, '{'
    je .pl_lbrace
    cmp al, '}'
    je .pl_rbrace
    cmp al, '('
    je .pl_lparen
    cmp al, ')'
    je .pl_rparen
    cmp al, '+'
    je .pl_plus
    cmp al, '-'
    je .pl_minus
    cmp al, '*'
    je .pl_star
    cmp al, '%'
    je .pl_percent
    cmp al, '='
    je .pl_eq
    cmp al, '!'
    je .pl_bang
    cmp al, '<'
    je .pl_lt
    cmp al, '>'
    je .pl_gt
    cmp al, ','
    je .pl_comma

    jmp .pl_bad_char

.pl_skip:
    inc r13
    jmp .pl_loop

.pl_newline:
    mov r14, r13
    sub r14, r12                  ; start offset
    mov r8, TOK_NEWLINE
    mov r9, r14
    mov r10, 1
    call party_emit
    cmp al, 0
    je .pl_overflow
    inc r13
    inc dword [party_error_line]
    jmp .pl_loop

.pl_slash_or_comment:
    mov al, [r13+1]
    cmp al, '/'
    jne .pl_slash_tok
    ; line comment: skip to newline or EOF (leave the newline for
    ; the main loop so it still gets a TOK_NEWLINE)
    add r13, 2
.pl_comment_loop:
    mov al, [r13]
    cmp al, 0
    je .pl_loop
    cmp al, 10
    je .pl_loop
    inc r13
    jmp .pl_comment_loop
.pl_slash_tok:
    mov r14, r13
    sub r14, r12
    mov r8, TOK_SLASH
    mov r9, r14
    mov r10, 1
    call party_emit
    cmp al, 0
    je .pl_overflow
    inc r13
    jmp .pl_loop

.pl_string:
    inc r13                       ; skip opening quote
    mov r14, r13
    sub r14, r12                  ; start offset = first char of content
    mov r15, r13                  ; scanning pointer
.pl_str_loop:
    mov al, [r15]
    cmp al, 0
    je .pl_str_unterminated
    cmp al, 10
    je .pl_str_unterminated
    cmp al, '"'
    je .pl_str_done
    inc r15
    jmp .pl_str_loop
.pl_str_done:
    mov r8, TOK_STR
    mov r9, r14
    mov r10, r15
    sub r10, r13                  ; length = content chars only
    call party_emit
    cmp al, 0
    je .pl_overflow
    mov r13, r15
    inc r13                       ; skip closing quote
    jmp .pl_loop
.pl_str_unterminated:
    mov byte [party_lex_ok], 0
    jmp .pl_out

.pl_number:
    mov r14, r13
    sub r14, r12                  ; start offset
    mov r8, TOK_INT                ; assume int until we see a '.'
.pl_num_intpart:
    mov al, [r13]
    cmp al, '0'
    jb .pl_num_check_dot
    cmp al, '9'
    ja .pl_num_check_dot
    inc r13
    jmp .pl_num_intpart
.pl_num_check_dot:
    cmp al, '.'
    jne .pl_num_done
    ; only treat as float if a digit follows the dot (so "foo.bar"
    ; elsewhere in the grammar isn't swallowed by number-lexing -
    ; Party doesn't have member access, but this keeps the rule
    ; explicit rather than accidental)
    mov dl, [r13+1]
    cmp dl, '0'
    jb .pl_num_done
    cmp dl, '9'
    ja .pl_num_done
    mov r8, TOK_FLOAT
    inc r13                       ; consume '.'
.pl_num_fracpart:
    mov al, [r13]
    cmp al, '0'
    jb .pl_num_done
    cmp al, '9'
    ja .pl_num_done
    inc r13
    jmp .pl_num_fracpart
.pl_num_done:
    mov r9, r14
    mov r10, r13
    sub r10, r12
    sub r10, r14                  ; length = end_offset - start_offset
    call party_emit
    cmp al, 0
    je .pl_overflow
    jmp .pl_loop

.pl_ident:
    mov r14, r13
    sub r14, r12                  ; start offset
    lea rdi, [party_ident_buf]
    xor rcx, rcx
.pl_ident_loop:
    mov al, [r13]
    cmp al, 'a'
    jb .pl_ident_check_upper
    cmp al, 'z'
    jbe .pl_ident_take
.pl_ident_check_upper:
    cmp al, 'A'
    jb .pl_ident_check_digit
    cmp al, 'Z'
    jbe .pl_ident_take
.pl_ident_check_digit:
    cmp al, '0'
    jb .pl_ident_check_us
    cmp al, '9'
    jbe .pl_ident_take
.pl_ident_check_us:
    cmp al, '_'
    jne .pl_ident_end
.pl_ident_take:
    cmp rcx, PARTY_IDENT_MAX-1
    jae .pl_ident_end             ; silently truncate the copy used for
                                   ; keyword matching only; the token's
                                   ; start/length still spans the full word
    mov [rdi], al
    inc rdi
    inc rcx
    inc r13
    jmp .pl_ident_loop
.pl_ident_end:
    mov byte [rdi], 0
    mov r9, r14
    mov r10, r13
    sub r10, r12
    sub r10, r14                  ; full length (not the truncated copy)

    ; check against keyword table
    lea rsi, [party_ident_buf]
    lea rdi, [kw_vars]
    call str_eq
    cmp al, 1
    je .pl_kw_vars
    lea rsi, [party_ident_buf]
    lea rdi, [kw_if]
    call str_eq
    cmp al, 1
    je .pl_kw_if
    lea rsi, [party_ident_buf]
    lea rdi, [kw_else]
    call str_eq
    cmp al, 1
    je .pl_kw_else
    lea rsi, [party_ident_buf]
    lea rdi, [kw_while]
    call str_eq
    cmp al, 1
    je .pl_kw_while
    lea rsi, [party_ident_buf]
    lea rdi, [kw_func]
    call str_eq
    cmp al, 1
    je .pl_kw_func
    lea rsi, [party_ident_buf]
    lea rdi, [kw_return]
    call str_eq
    cmp al, 1
    je .pl_kw_return
    lea rsi, [party_ident_buf]
    lea rdi, [kw_display]
    call str_eq
    cmp al, 1
    je .pl_kw_display
    lea rsi, [party_ident_buf]
    lea rdi, [kw_read]
    call str_eq
    cmp al, 1
    je .pl_kw_read
    lea rsi, [party_ident_buf]
    lea rdi, [kw_true]
    call str_eq
    cmp al, 1
    je .pl_kw_true
    lea rsi, [party_ident_buf]
    lea rdi, [kw_false]
    call str_eq
    cmp al, 1
    je .pl_kw_false
    lea rsi, [party_ident_buf]
    lea rdi, [kw_rush]
    call str_eq
    cmp al, 1
    je .pl_kw_rush
    mov r8, TOK_IDENT
    jmp .pl_ident_emit
.pl_kw_vars:
    mov r8, TOK_VARS
    jmp .pl_ident_emit
.pl_kw_if:
    mov r8, TOK_IF
    jmp .pl_ident_emit
.pl_kw_else:
    mov r8, TOK_ELSE
    jmp .pl_ident_emit
.pl_kw_while:
    mov r8, TOK_WHILE
    jmp .pl_ident_emit
.pl_kw_func:
    mov r8, TOK_FUNC
    jmp .pl_ident_emit
.pl_kw_return:
    mov r8, TOK_RETURN
    jmp .pl_ident_emit
.pl_kw_display:
    mov r8, TOK_DISPLAY
    jmp .pl_ident_emit
.pl_kw_read:
    mov r8, TOK_READ
    jmp .pl_ident_emit
.pl_kw_true:
    mov r8, TOK_TRUE
    jmp .pl_ident_emit
.pl_kw_false:
    mov r8, TOK_FALSE
    jmp .pl_ident_emit
.pl_kw_rush:
    mov r8, TOK_RUSH
.pl_ident_emit:
    call party_emit
    cmp al, 0
    je .pl_overflow
    jmp .pl_loop

.pl_lbrace:
    mov r8, TOK_LBRACE
    jmp .pl_sym1
.pl_rbrace:
    mov r8, TOK_RBRACE
    jmp .pl_sym1
.pl_lparen:
    mov r8, TOK_LPAREN
    jmp .pl_sym1
.pl_rparen:
    mov r8, TOK_RPAREN
    jmp .pl_sym1
.pl_plus:
    mov r8, TOK_PLUS
    jmp .pl_sym1
.pl_minus:
    mov r8, TOK_MINUS
    jmp .pl_sym1
.pl_star:
    mov r8, TOK_STAR
    jmp .pl_sym1
.pl_percent:
    mov r8, TOK_PERCENT
    jmp .pl_sym1
.pl_comma:
    mov r8, TOK_COMMA
    jmp .pl_sym1
.pl_sym1:
    mov r14, r13
    sub r14, r12
    mov r9, r14
    mov r10, 1
    call party_emit
    cmp al, 0
    je .pl_overflow
    inc r13
    jmp .pl_loop

.pl_eq:
    mov al, [r13+1]
    cmp al, '='
    jne .pl_eq_single
    mov r14, r13
    sub r14, r12
    mov r8, TOK_EQEQ
    mov r9, r14
    mov r10, 2
    call party_emit
    cmp al, 0
    je .pl_overflow
    add r13, 2
    jmp .pl_loop
.pl_eq_single:
    mov r14, r13
    sub r14, r12
    mov r8, TOK_EQ
    mov r9, r14
    mov r10, 1
    call party_emit
    cmp al, 0
    je .pl_overflow
    inc r13
    jmp .pl_loop

.pl_bang:
    mov al, [r13+1]
    cmp al, '='
    jne .pl_bad_char           ; bare '!' isn't a valid Party token
    mov r14, r13
    sub r14, r12
    mov r8, TOK_NEQ
    mov r9, r14
    mov r10, 2
    call party_emit
    cmp al, 0
    je .pl_overflow
    add r13, 2
    jmp .pl_loop

.pl_lt:
    mov al, [r13+1]
    cmp al, '='
    jne .pl_lt_single
    mov r14, r13
    sub r14, r12
    mov r8, TOK_LTE
    mov r9, r14
    mov r10, 2
    call party_emit
    cmp al, 0
    je .pl_overflow
    add r13, 2
    jmp .pl_loop
.pl_lt_single:
    mov r14, r13
    sub r14, r12
    mov r8, TOK_LT
    mov r9, r14
    mov r10, 1
    call party_emit
    cmp al, 0
    je .pl_overflow
    inc r13
    jmp .pl_loop

.pl_gt:
    mov al, [r13+1]
    cmp al, '='
    jne .pl_gt_single
    mov r14, r13
    sub r14, r12
    mov r8, TOK_GTE
    mov r9, r14
    mov r10, 2
    call party_emit
    cmp al, 0
    je .pl_overflow
    add r13, 2
    jmp .pl_loop
.pl_gt_single:
    mov r14, r13
    sub r14, r12
    mov r8, TOK_GT
    mov r9, r14
    mov r10, 1
    call party_emit
    cmp al, 0
    je .pl_overflow
    inc r13
    jmp .pl_loop

.pl_bad_char:
    mov byte [party_lex_ok], 0
    jmp .pl_out

.pl_overflow:
    mov byte [party_lex_ok], 0
    jmp .pl_out

.pl_eof:
    mov r14, r13
    sub r14, r12
    mov r8, TOK_EOF
    mov r9, r14
    mov r10, 0
    call party_emit
    ; overflow on the EOF token itself is irrelevant (nothing more
    ; to lex), just fall through to .pl_out either way

.pl_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
;  PARTY (.pa) LANGUAGE — TREE-WALKING INTERPRETER
; ============================================================
; The executor is a recursive-descent interpreter over the token
; stream produced by party_lex. It supports the full v0.1 spec:
; vars, assignment, if/else-if/else, while, func/return (with
; recursion), and full expressions over int/float/bool/string.
;
; Values are 32 bytes: { type:u8, resv:u8, [pad], data:qword,
; strptr:qword, strlen:qword }. data holds an int64 / double /
; bool flag; strptr/strlen describe a string that points into
; fs_io_buf (string literals are never copied out).
;
; The interpreter keeps its own state in a value stack
; (party_vstack), a global var table, a locals pool (one run per
; active call frame), a function table (collected in a first pass
; so mutual recursion works), and a fixed-size call-frame stack.
;
; Errors set party_exec_ok=0 + party_err_msg_ptr + party_error_line
; through party_set_err; every parser level is a no-op once the
; error flag is set, so a failure unwinds cleanly to party_exec.
; ------------------------------------------------------------

; ---- value types ----
PV_NONE  equ 0
PV_INT   equ 1
PV_FLOAT equ 2
PV_BOOL  equ 3
PV_STR   equ 4
PV_ARRAY equ 5      ; Phase 4: data field ([+8]) holds a handle - an index
                     ; into the party_arr_* table (party_arr_alloc/_check),
                     ; the same handle-into-a-fixed-table model PARTY_FH_*
                     ; already uses for file handles. No str fields used.

; ---- interpreter capacities ----
MAXVSTACK equ 64
MAXVARS   equ 32
MAXLOCALS equ 64
MAXFUNCS  equ 32
MAXCALLS  equ 32

; ------------------------------------------------------------
; party_exec: interpreter entry. Collects all func declarations,
; then runs top-level statements (skipping the func blocks, which
; are declarations). fninit resets the x87 FPU used for floats.
; Out: party_exec_ok = 1 success, 0 failure (+ party_error_line,
; party_err_msg_ptr). Preserves everything except the interpreter's
; own state (which is fully re-initialized on entry).
; ------------------------------------------------------------
party_exec:
    push rbx
    push r12
    push r13
    push r14
    push r15
    fninit                        ; reset x87 FPU (CW back to defaults)
    xor r13, r13
    mov byte [party_exec_ok], 1
    mov byte [party_killed], 0
    mov byte [party_returning], 0
    mov byte [kill_flag], 0
    mov qword [party_vsp], 0
    mov qword [party_call_depth], 0
    mov qword [party_loc_count], 0
    mov qword [party_func_count], 0
    mov qword [party_err_msg_ptr], 0

    lea rdi, [party_var_used]
    mov rcx, MAXVARS
    call party_memzero
    lea rdi, [party_loc_used]
    mov rcx, MAXLOCALS
    call party_memzero
    lea rdi, [party_frame_returned]
    mov rcx, MAXCALLS
    call party_memzero
    lea rdi, [party_arr_used]
    mov rcx, PARTY_ARR_MAX
    call party_memzero

    call party_collect_funcs
    cmp byte [party_exec_ok], 1
    jne .pe_out

    mov r14, TOK_EOF
    call party_exec_stmts

.pe_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; party_boot_compiled: KAPI_BOOT. A compiled .run binary's entry stub
; does LEA RSI, embedded-source ; CALL [KAPI_BOOT] ; RET - this is that
; bootstrap. rsi = the Party source embedded in the .run file (token
; text offsets are relative to it). Resets the runtime, lexes the
; embedded source, collects func declarations and runs the program
; with the tree-walking interpreter - the same path 'party foo.pa'
; uses, so a compiled program needs no separate runtime. On a lex
; error prints the failing line to the screen. Clobbers rax-r15 and
; the FPU; sets party_exec_ok / party_lex_ok / party_error_line.
; ------------------------------------------------------------
party_boot_compiled:
    mov [party_src_base], rsi
    call party_reset_runtime
    call party_lex
    cmp byte [party_lex_ok], 1
    jne .pbc_lex_fail
    xor r13, r13                   ; statement cursor, like party_exec does
    call party_collect_funcs
    cmp byte [party_exec_ok], 1
    jne .pbc_out
    mov r14, TOK_EOF
    call party_exec_stmts
.pbc_out:
    ret
.pbc_lex_fail:
    mov rsi, msg_party_lex_err
    mov al, ATTR_ERROR
    call print_string_attr
    mov eax, [party_error_line]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
;  BACKGROUND PROCESS CONTEXT SAVE / RESTORE
;  party_ctx_save(rdi = dst ctx base) parks the whole mutable
;  interpreter state (token stream, value stack, variable/locals/
;  function/call-frame tables, all scalars, the live statement cursor)
;  into a process's proc_bg_ctx area. party_ctx_restore(rsi = src ctx
;  base) brings it all back before a background step resumes. The
;  regions copied are listed in party_ctx_table (src-address/size
;  pairs, zero-terminated); r13 (statement cursor), r14 (stop token)
;  and r15 (branch flag) are parked after the data block. Used both by
;  cmd_run_back (parks the freshly lexed+collected state before the
;  first step) and party_bg_suspend (parks a mid-run state at a yield).
;  Both clobber rax, rbx, rcx, rsi, rdi, r8-r15.
; ------------------------------------------------------------
; PARTY_CTX_SIZE was 20226 through Phase 3. Phase 4 adds 32 bytes
; (party_scratch3, folded into the existing party_scratch region
; below) + 2084 bytes (the new party_arr_used/count/data regions:
; PARTY_ARR_MAX + PARTY_ARR_MAX*8 + PARTY_ARR_MAX*PARTY_ARR_CAP*32 =
; 4 + 32 + 2048), so 20226 + 32 + 2084 = 22342. This constant is NOT
; auto-derived from party_ctx_table below - if that table's per-entry
; sizes change again, update this by hand to match, the same way this
; session had to.
PARTY_CTX_REGS_OFFS equ 22342 - 24
PARTY_CTX_SIZE      equ 22342

party_ctx_table:
    dq party_lex_ok, 7             ; lex_ok, exec_ok, killed, error_line
    dq party_src_base, 8
    dq party_ident_buf, 184        ; ident_buf + call_name_buf + stmt_name_buf + text_buf
    dq party_token_count, 4098     ; token_count + the token array
    dq party_returning, 1
    dq party_err_msg_ptr, 40       ; err_msg_ptr, vsp, call_depth, loc_count, func_count
    dq party_while_cond_tok, 8
    dq party_scratch, 128          ; scratch, scratch1, scratch2, scratch3
    dq party_ftmp_i, 20            ; ftmp_i, tmp_i, fp_cw, fp_cw2
    dq party_num_buf, 32
    dq party_vstack, 2048
    dq party_var_used, 32
    dq party_var_val, 2304         ; var_val + var_name
    dq party_loc_used, 64
    dq party_loc_val, 4608         ; loc_val + loc_name
    dq party_func_name, 2592       ; func_name + nparams + paramtok + bodytok + bodyend
    dq party_frame_ret_r13, 1344   ; call frames incl. the retval block
    dq party_arr_used, 4           ; Phase 4: array-slot table (used flags)
    dq party_arr_count, 32         ; Phase 4: array-slot table (element counts)
    dq party_arr_data, 2048        ; Phase 4: array-slot table (element storage)
    dq 0, 0

party_ctx_save:                    ; rdi = dst ctx base
    push rbx
    push r8
    push r9
    mov r8, rdi                    ; ctx base
    lea rbx, [party_ctx_table]
    xor r9, r9                     ; ctx offset
.x_sv_loop:
    mov rax, [rbx]                 ; src global
    mov rcx, [rbx+8]               ; size
    cmp rcx, 0
    je .x_sv_done
    add rbx, 16
    push rbx
    push rdi
    mov rsi, rax
    lea rdi, [r8 + r9]
    add r9, rcx
    rep movsb
    pop rdi
    pop rbx
    jmp .x_sv_loop
.x_sv_done:
    mov [r8 + PARTY_CTX_REGS_OFFS], r13
    mov [r8 + PARTY_CTX_REGS_OFFS + 8], r14
    mov [r8 + PARTY_CTX_REGS_OFFS + 16], r15
    pop r9
    pop r8
    pop rbx
    ret

party_ctx_restore:                 ; rsi = src ctx base
    push rbx
    push r8
    push r9
    mov r8, rsi                    ; ctx base
    lea rbx, [party_ctx_table]
    xor r9, r9                     ; ctx offset
.x_rs_loop:
    mov rax, [rbx]                 ; dst global
    mov rcx, [rbx+8]               ; size
    cmp rcx, 0
    je .x_rs_done
    add rbx, 16
    push rbx
    push rdi
    mov rsi, r8
    add rsi, r9                    ; src = ctx + offset
    mov rdi, rax
    add r9, rcx
    rep movsb
    pop rdi
    pop rbx
    jmp .x_rs_loop
.x_rs_done:
    mov r13, [r8 + PARTY_CTX_REGS_OFFS]
    mov r14, [r8 + PARTY_CTX_REGS_OFFS + 8]
    mov r15, [r8 + PARTY_CTX_REGS_OFFS + 16]
    pop r9
    pop r8
    pop rbx
    ret

; party_bg_suspend: cooperative yield. Called from party_exec_stmts at a
; statement boundary when the background quantum is exhausted (see the
; party_bg_active / party_bg_quantum check at the top of the statement
; loop). Parks the interpreter state (globals + r13/r14/r15) into the
; current process's ctx area, saves the private-stack pointer (its top
; word is the resume address - the instruction right after this call) into
; proc_bg_rsp[slot], then switches back to the scheduler's stack and
; returns to bg_scheduler_tick. The next bg_step_proc restores the ctx,
; sets rsp back to proc_bg_rsp[slot] and RETs, so execution continues
; right after this call. Clobbers rax, rbx, rcx, rsi, rdi, r8-r15.
party_bg_suspend:
    movzx rax, byte [bg_cur_slot]
    lea rdi, [proc_bg_ctx]
    imul rcx, rax, PARTY_CTX_SIZE
    add rdi, rcx
    call party_ctx_save
    movzx rax, byte [bg_cur_slot]
    mov [proc_bg_rsp + rax*8], rsp
    mov rsp, [bg_shell_rsp]
    ret

; party_bg_bootstrap: the resume IP cmd_run_back parks on a background
; process's private stack. Runs the program with the interpreter from
; statement 0 - the tokens were already lexed and functions collected,
; then parked in the ctx by cmd_run_back, so all this does is execute.
; When the script reaches EOF/error/kill, party_exec_stmts returns:
; flag the slot free (bg_finish_notice) and go back to the scheduler.
; (A script that yields never returns here - it suspends on its own
; private stack and this path only runs when the script actually ends.)
party_bg_bootstrap:
    xor r13, r13
    mov r14, TOK_EOF
    xor r15, r15
    call party_exec_stmts
    call bg_finish_notice
    movzx rax, byte [bg_cur_slot]
    mov qword [proc_bg_rsp + rax*8], 0
    mov rsp, [bg_shell_rsp]
    ret

; ------------------------------------------------------------
; party_collect_funcs: first pass over the token stream. Every
; top-level `func name(params) { ... }` is recorded in the func
; table (name, param token indexes, body span) so a function can
; call another declared later in the file, or itself. Malformed
; declarations are hard errors. Clobbers rax-rbx, r8-r15.
; ------------------------------------------------------------
party_collect_funcs:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor r13, r13
.pcf_loop:
    movzx eax, word [party_token_count]
    cmp r13, rax
    jae .pcf_done
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_FUNC
    je .pcf_func
    inc r13
    jmp .pcf_loop

.pcf_func:
    mov rax, [party_func_count]
    cmp rax, MAXFUNCS
    jae .pcf_err_full
    mov r15, rax
    inc qword [party_func_count]

    inc r13                        ; past 'func'
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_IDENT
    jne .pcf_err_decl
    lea rdi, [party_func_name]
    imul rdx, r15, PARTY_IDENT_MAX
    add rdi, rdx
    call party_copy_tok_text_into_rdi

    inc r13                        ; past name
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LPAREN
    jne .pcf_err_decl
    inc r13

    mov byte [party_func_nparams+r15], 0
.pcf_param_loop:
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_RPAREN
    je .pcf_params_done
    cmp eax, TOK_IDENT
    jne .pcf_err_decl
    movzx r12, byte [party_func_nparams+r15]
    cmp r12, 8
    jae .pcf_err_decl
    lea rdx, [party_func_paramtok]
    imul rax, r15, 8
    add rdx, rax
    mov [rdx + r12*4], r13d
    inc byte [party_func_nparams+r15]
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_COMMA
    jne .pcf_param_loop
    inc r13
    jmp .pcf_param_loop

.pcf_params_done:
    inc r13                        ; past ')'
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LBRACE
    jne .pcf_err_decl
    inc r13
    mov [party_func_bodytok + r15*4], r13d

    mov r14d, 1                    ; brace depth
.pcf_brace_loop:
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_EOF
    je .pcf_err_decl
    cmp eax, TOK_LBRACE
    jne .pcf_brace_r
    inc r14d
    jmp .pcf_brace_next
.pcf_brace_r:
    cmp eax, TOK_RBRACE
    jne .pcf_brace_next
    dec r14d
    cmp r14d, 0
    je .pcf_brace_done
.pcf_brace_next:
    inc r13
    jmp .pcf_brace_loop
.pcf_brace_done:
    mov [party_func_bodyend + r15*4], r13d
    inc r13                        ; past '}'
    jmp .pcf_loop

.pcf_err_full:
    lea rsi, [msg_party_funcs_full]
    call party_set_err
    jmp .pcf_out
.pcf_err_decl:
    lea rsi, [msg_party_bad_func]
    call party_set_err
.pcf_done:
.pcf_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; party_exec_stmts: runs statements starting at token r13 until it
; reaches a token whose type equals r14 (TOK_EOF for the top level,
; TOK_RBRACE for a block body). Does NOT consume the stop token.
; Recurses into itself for if/while/else blocks. Exits early (with
; r13 wherever it stopped) when an error is set, the script is
; killed (Esc), or a `return` is unwinding (party_returning).
; In: r13 = starting token index, r14 = stop token type.
; Clobbers rax, rbx, r8-r11; preserves r13 (advances it), r14.
; ------------------------------------------------------------
party_exec_stmts:
    push rbx
    push r12
    push r15
.pes_stmt_loop:
    cmp byte [party_killed], 0
    jne .pes_out
    cmp byte [party_returning], 0
    jne .pes_out
    cmp byte [party_exec_ok], 0
    je .pes_out
    ; Esc-to-kill only applies to a foreground script (the shell is
    ; blocked while it runs, so there's nowhere else for keystrokes to
    ; go). A background process is stepped in short quanta between
    ; shell prompts and already has its own kill path ('prs kill
    ; <pid>'), so skip kbd_poll here - otherwise it would silently
    ; consume/discard keys the user is typing at the live shell prompt
    ; while this quantum runs.
    cmp byte [party_bg_active], 0
    jne .pes_not_killed
    call kbd_poll
    cmp byte [kill_flag], 0
    je .pes_not_killed
    mov byte [party_killed], 1
    mov rsi, msg_party_killed
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .pes_out
.pes_not_killed:
    ; Cooperative background yield: when this interpreter is running as a
    ; stepped background process, count the statement and hand control back
    ; to the scheduler once party_bg_quantum is exhausted. party_bg_active
    ; is 1 only while bg_step_proc is driving us - a foreground party/run
    ; never yields here. On resume the scheduler has reset party_bg_quantum
    ; and party_bg_suspend drops us back at this exact statement boundary.
    cmp byte [party_bg_active], 0
    je .pes_bg_done
    dec dword [party_bg_quantum]
    jns .pes_bg_done
    call party_bg_suspend
    jmp .pes_stmt_loop
.pes_bg_done:
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_NEWLINE
    jne .pes_check_stop
    inc r13
    jmp .pes_stmt_loop
.pes_check_stop:
    cmp eax, r14d
    je .pes_out                    ; found our stop token - leave it unconsumed
    cmp eax, TOK_EOF
    je .pes_err_eof                ; block ran off the end (unclosed '{')
    cmp eax, TOK_DISPLAY
    je .pes_display
    cmp eax, TOK_VARS
    je .pes_vars
    cmp eax, TOK_IF
    je .pes_if
    cmp eax, TOK_WHILE
    je .pes_while
    cmp eax, TOK_FUNC
    je .pes_skip_func
    cmp eax, TOK_RETURN
    je .pes_return
    cmp eax, TOK_READ
    je .pes_read
    cmp eax, TOK_RUSH
    je .pes_rush
    cmp eax, TOK_IDENT
    je .pes_ident
    jmp .pes_err_stmt

; ---- display <expr> ----
.pes_display:
    inc r13
    call party_parse_expr
    cmp byte [party_exec_ok], 1
    jne .pes_out
    lea rdi, [party_scratch]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .pes_out
    lea rbx, [party_scratch]
    call party_print_value
    mov rsi, newline_str
    call print_string
    jmp .pes_stmt_loop

; ---- read <ident> ----
; Reads one line from the keyboard into an already-declared variable
; as a string. The text lands in a single shared buffer
; (party_read_buf), so - like string literals sharing the source
; buffer - a later `read` overwrites what an earlier one produced.
.pes_read:
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_IDENT
    jne .pes_err_stmt
    call party_copy_tok_text_cur
    inc r13
    lea rsi, [party_ident_buf]
    lea rdi, [party_stmt_name_buf]
    call party_strcpy_save
    lea rdi, [party_read_buf]
    mov rcx, PARTY_READ_MAX - 1
    call read_line
    lea rsi, [party_read_buf]
    call str_len
    mov rcx, rax
    lea rsi, [party_stmt_name_buf]
    call party_var_get_ptr
    cmp al, 1
    jne .pes_read_undef
    mov rdi, rbx
    lea rsi, [party_read_buf]
    call party_val_set_str
    jmp .pes_stmt_loop
.pes_read_undef:
    lea rsi, [msg_party_undef_var]
    call party_set_err
    jmp .pes_out

; ---- rush <expr> ----
; Evaluates <expr> (must be a string) and feeds it to the Rush/
; ShellyForever shell exactly the way a typed prompt line would be:
; through process_chain, so ';' chaining, quoted args, aliases and
; every existing cmd_* handler (file creation/editing, http, net,
; the party compiler itself via "party compile x.pa", etc.) all just
; work with no separate reimplementation here. Party scripts still
; can't reach the shell any other way - this is the one deliberate
; door, and it only opens for a string the script itself built.
.pes_rush:
    inc r13
    call party_parse_expr
    cmp byte [party_exec_ok], 1
    jne .pes_out
    lea rdi, [party_scratch]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .pes_out
    cmp byte [party_scratch], PV_STR
    je .pes_rush_run
    lea rsi, [msg_party_rush_type]
    call party_set_err
    jmp .pes_out
.pes_rush_run:
    mov rsi, [party_scratch+16]    ; source text pointer (slice, not NUL-terminated)
    mov rcx, [party_scratch+24]    ; slice length
    cmp rcx, LINE_MAX-1
    jb .pes_rush_len_ok
    mov rcx, LINE_MAX-1            ; truncate rather than overrun line_buf
.pes_rush_len_ok:
    lea rdi, [line_buf]
    rep movsb
    mov byte [rdi], 0
    call process_chain
    jmp .pes_stmt_loop

; ---- vars <ident> = <expr> ----
.pes_vars:
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_IDENT
    jne .pes_err_stmt
    call party_copy_tok_text_cur
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_EQ
    jne .pes_err_stmt
    inc r13
    lea rsi, [party_ident_buf]
    lea rdi, [party_stmt_name_buf]
    call party_strcpy_save
    call party_parse_expr
    cmp byte [party_exec_ok], 1
    jne .pes_out
    lea rsi, [party_stmt_name_buf]
    call party_var_declare
    cmp byte [party_exec_ok], 1
    jne .pes_out
    jmp .pes_stmt_loop

; ---- <ident> = <expr>   or   <ident>(args) as a statement ----
.pes_ident:
    call party_copy_tok_text_cur
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_EQ
    je .pes_assign
    cmp eax, TOK_LPAREN
    je .pes_call_stmt
    jmp .pes_err_stmt
.pes_assign:
    inc r13
    lea rsi, [party_ident_buf]
    lea rdi, [party_stmt_name_buf]
    call party_strcpy_save
    call party_parse_expr
    cmp byte [party_exec_ok], 1
    jne .pes_out
    lea rsi, [party_stmt_name_buf]
    call party_var_assign
    cmp byte [party_exec_ok], 1
    jne .pes_out
    jmp .pes_stmt_loop
.pes_call_stmt:
    call party_parse_call
    cmp byte [party_exec_ok], 1
    jne .pes_out
    lea rdi, [party_scratch]
    call party_pop_val             ; discard the (possibly none) return value
    cmp byte [party_exec_ok], 1
    jne .pes_out
    jmp .pes_stmt_loop

; ---- if (expr) { } else if ... else { } ----
.pes_if:
    inc r13                        ; past 'if'
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LPAREN
    jne .pes_err_stmt
    inc r13
    call party_parse_expr
    cmp byte [party_exec_ok], 1
    jne .pes_out
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_RPAREN
    jne .pes_err_stmt
    inc r13
    lea rdi, [party_scratch]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .pes_out
    lea rbx, [party_scratch]
    call party_truthy
    mov r15b, al                   ; r15b = "a branch has been taken"
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LBRACE
    jne .pes_err_stmt
    inc r13
    cmp r15b, 1
    je .pes_if_run
    call party_skip_block
    jmp .pes_else_scan
.pes_if_run:
    push r14
    mov r14, TOK_RBRACE
    call party_exec_stmts
    pop r14
    cmp byte [party_exec_ok], 1
    jne .pes_out
    cmp byte [party_returning], 0
    jne .pes_out
    cmp byte [party_killed], 0
    jne .pes_out

.pes_else_scan:
    ; r13 = '}' of the block just finished; look for `else` after it
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_NEWLINE
    je .pes_else_scan
    cmp eax, TOK_ELSE
    je .pes_else_found
    jmp .pes_stmt_loop
.pes_else_found:
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_IF
    je .pes_else_if
    cmp eax, TOK_LBRACE
    je .pes_else_block
    jmp .pes_err_stmt

.pes_else_if:
    inc r13                        ; past 'if'
    cmp r15b, 1
    je .pes_eif_skip_all
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LPAREN
    jne .pes_err_stmt
    inc r13
    call party_parse_expr
    cmp byte [party_exec_ok], 1
    jne .pes_out
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_RPAREN
    jne .pes_err_stmt
    inc r13
    lea rdi, [party_scratch]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .pes_out
    lea rbx, [party_scratch]
    call party_truthy
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LBRACE
    jne .pes_err_stmt
    inc r13
    cmp al, 1
    je .pes_eif_run
    call party_skip_block
    jmp .pes_else_scan
.pes_eif_run:
    mov r15b, 1
    push r14
    mov r14, TOK_RBRACE
    call party_exec_stmts
    pop r14
    cmp byte [party_exec_ok], 1
    jne .pes_out
    cmp byte [party_returning], 0
    jne .pes_out
    cmp byte [party_killed], 0
    jne .pes_out
    jmp .pes_else_scan
.pes_eif_skip_all:
    ; a previous branch already ran: skip this whole else-if
    call party_skip_balanced_parens ; r13 = ')'
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LBRACE
    jne .pes_err_stmt
    inc r13
    call party_skip_block
    jmp .pes_else_scan

.pes_else_block:
    inc r13                        ; past '{'
    cmp r15b, 1
    je .pes_else_skip
    mov r15b, 1
    push r14
    mov r14, TOK_RBRACE
    call party_exec_stmts
    pop r14
    cmp byte [party_exec_ok], 1
    jne .pes_out
    cmp byte [party_returning], 0
    jne .pes_out
    cmp byte [party_killed], 0
    jne .pes_out
    jmp .pes_else_scan
.pes_else_skip:
    call party_skip_block
    jmp .pes_else_scan

; ---- while (expr) { ... } ----
.pes_while:
    inc r13                        ; past 'while'
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LPAREN
    jne .pes_err_stmt
    mov [party_while_cond_tok], r13d
    inc r13
    call party_parse_expr
    cmp byte [party_exec_ok], 1
    jne .pes_out
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_RPAREN
    jne .pes_err_stmt
    inc r13
    lea rdi, [party_scratch]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .pes_out
    lea rbx, [party_scratch]
    call party_truthy
    mov r15b, al
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LBRACE
    jne .pes_err_stmt
    inc r13
    mov [party_while_body_tok], r13d
    cmp r15b, 1
    je .pes_while_loop
    call party_skip_block
    inc r13
    jmp .pes_stmt_loop

.pes_while_loop:
    ; Same rule as the top-level statement loop: a background process
    ; must not consume keystrokes meant for the live shell prompt. Only
    ; poll for Esc-to-kill when running in the foreground.
    cmp byte [party_bg_active], 0
    jne .pes_while_nk
    call kbd_poll
    cmp byte [kill_flag], 0
    je .pes_while_nk
    mov byte [party_killed], 1
    mov rsi, msg_party_killed
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .pes_out
.pes_while_nk:
    mov r13d, [party_while_body_tok]
    push r14
    mov r14, TOK_RBRACE
    call party_exec_stmts
    pop r14
    cmp byte [party_exec_ok], 0
    je .pes_out
    cmp byte [party_killed], 0
    jne .pes_out
    cmp byte [party_returning], 0
    jne .pes_out
    ; re-evaluate the condition each iteration
    mov r13d, [party_while_cond_tok]
    inc r13
    call party_parse_expr
    cmp byte [party_exec_ok], 1
    jne .pes_out
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_RPAREN
    jne .pes_err_stmt
    inc r13
    lea rdi, [party_scratch]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .pes_out
    lea rbx, [party_scratch]
    call party_truthy
    cmp al, 1
    je .pes_while_loop
    mov r13d, [party_while_body_tok]
    call party_skip_block
    inc r13
    jmp .pes_stmt_loop

; ---- func declarations at execution time are no-ops (already collected) ----
.pes_skip_func:
    inc r13                        ; past 'func'
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_IDENT
    jne .pes_err_stmt
    inc r13
    call party_skip_balanced_parens ; param list
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LBRACE
    jne .pes_err_stmt
    inc r13
    call party_skip_block
    inc r13
    jmp .pes_stmt_loop

; ---- return [expr] ----
.pes_return:
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_NEWLINE
    je .pes_ret_none
    cmp eax, TOK_RBRACE
    je .pes_ret_none
    cmp eax, TOK_EOF
    je .pes_ret_none
    call party_parse_expr
    cmp byte [party_exec_ok], 1
    jne .pes_out
    mov rcx, [party_call_depth]
    cmp rcx, 0
    je .pes_ret_top               ; top-level return just ends the script
    dec rcx
    lea rdi, [party_frame_retval]
    imul rdx, rcx, 32
    add rdi, rdx
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .pes_out
    mov byte [party_frame_returned + rcx], 1
    mov byte [party_returning], 1
    jmp .pes_out
.pes_ret_none:
    mov rcx, [party_call_depth]
    cmp rcx, 0
    je .pes_ret_top
    dec rcx
    lea rdi, [party_frame_retval]
    imul rdx, rcx, 32
    add rdi, rdx
    call party_val_set_none
    mov byte [party_frame_returned + rcx], 1
    mov byte [party_returning], 1
    jmp .pes_out
.pes_ret_top:
    mov byte [party_returning], 1
    jmp .pes_out

.pes_err_stmt:
    lea rsi, [msg_party_bad_stmt]
    call party_set_err
    jmp .pes_out
.pes_err_eof:
    lea rsi, [msg_party_eof]
    call party_set_err
.pes_out:
    pop r15
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; party_set_err: records an interpreter error. rsi = message pointer.
; Sets party_exec_ok=0, party_err_msg_ptr=rsi, and party_error_line
; from the token at the current cursor r13. Clobbers rax, rbx, rsi,
; rcx.
; ------------------------------------------------------------
party_set_err:
    push rsi
    mov [party_err_msg_ptr], rsi
    call party_tok_ptr
    mov eax, [rbx+4]               ; token's start offset
    call party_line_at
    mov [party_error_line], eax
    mov byte [party_exec_ok], 0
    pop rsi
    ret

; ------------------------------------------------------------
; party_copy_tok_text_cur: copies the text of the token at cursor
; r13 into party_ident_buf (NUL-terminated, capped at
; PARTY_IDENT_MAX-1). Clobbers rax, rcx, rsi, rdi.
; ------------------------------------------------------------
party_copy_tok_text_cur:
    push rdi
    lea rdi, [party_ident_buf]
    call party_copy_tok_text_into_rdi
    pop rdi
    ret

; party_strcpy_save: rsi = src (NUL-terminated), rdi = dst; copies
; the string capped at PARTY_IDENT_MAX-1 bytes. Clobbers rax, rcx,
; rsi, rdi.
party_strcpy_save:
    push rsi
    push rdi
    push rcx
    push rax
    xor rcx, rcx
.pss_loop:
    mov al, [rsi]
    mov [rdi], al
    cmp al, 0
    je .pss_done
    inc rsi
    inc rdi
    inc rcx
    cmp rcx, PARTY_IDENT_MAX-1
    jae .pss_done
    jmp .pss_loop
.pss_done:
    pop rax
    pop rcx
    pop rdi
    pop rsi
    ret

; party_copy_tok_text_into_rdi: copies the token at cursor r13's
; text into the buffer at rdi, capped at PARTY_IDENT_MAX-1 bytes,
; NUL-terminated. Clobbers rax, rcx, rsi, rdi.
party_copy_tok_text_into_rdi:
    push rax
    push rcx
    push rsi
    push rdi
    call party_tok_ptr
    movzx rcx, word [rbx+2]
    mov eax, [rbx+4]
    mov rsi, [party_src_base]
    add rsi, rax
    cmp rcx, PARTY_IDENT_MAX-1
    jbe .ctt_ok
    mov rcx, PARTY_IDENT_MAX-1
.ctt_ok:
    mov rdi, [rsp]                 ; original dest (pushed last)
.ctt_copy:
    cmp rcx, 0
    je .ctt_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .ctt_copy
.ctt_done:
    mov byte [rdi], 0
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------
; party_skip_balanced_parens: r13 must point at '('; advances r13
; to the matching ')' (not consumed), handling nested parens.
; Clobbers rax, rbx, rcx.
; ------------------------------------------------------------
party_skip_balanced_parens:
    push rax
    push rbx
    push rcx
    xor ecx, ecx                   ; r13 points at '('; it opens depth 1
.sbp_loop:
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_EOF
    je .sbp_out
    cmp eax, TOK_LPAREN
    jne .sbp_check_r
    inc ecx
    jmp .sbp_next
.sbp_check_r:
    cmp eax, TOK_RPAREN
    jne .sbp_next
    dec ecx
    cmp ecx, 0
    je .sbp_out
.sbp_next:
    inc r13
    jmp .sbp_loop
.sbp_out:
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
; party_skip_block: r13 = first token inside a block (already past
; its opening '{'). Advances r13 past the block WITHOUT running any
; of it, stopping at the matching '}' (not consumed). Only tracks
; brace depth, so it doesn't validate anything inside the block.
; Clobbers rax, rbx, rcx.
; ------------------------------------------------------------
party_skip_block:
    mov ecx, 1
.psb_loop:
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_EOF
    je .psb_out                    ; unterminated block - caller's next
                                    ; token check (expects '}') will error
    cmp eax, TOK_LBRACE
    jne .psb_check_rbrace
    inc ecx
    inc r13
    jmp .psb_loop
.psb_check_rbrace:
    cmp eax, TOK_RBRACE
    jne .psb_next
    dec ecx
    cmp ecx, 0
    je .psb_out                    ; matching close brace - leave r13 on it
    inc r13
    jmp .psb_loop
.psb_next:
    inc r13
    jmp .psb_loop
.psb_out:
    ret

; ------------------------------------------------------------
; party_memzero: zeroes rcx bytes at rdi. Clobbers rax, rdi, rcx.
; ------------------------------------------------------------
party_memzero:
    push rax
    xor al, al
.pmz_loop:
    cmp rcx, 0
    je .pmz_done
    mov [rdi], al
    inc rdi
    dec rcx
    jmp .pmz_loop
.pmz_done:
    pop rax
    ret

; ============================================================
;  VALUE HELPERS
; ============================================================
; Each party_val_set_* takes the destination in rdi and fills the
; 32-byte value. party_val_copy copies a whole value (rsi -> rdi).

party_val_set_int:                 ; rax = int64
    mov byte [rdi], PV_INT
    mov qword [rdi+8], rax
    mov qword [rdi+16], 0
    mov qword [rdi+24], 0
    ret

party_val_set_bool_true:
    mov byte [rdi], PV_BOOL
    mov qword [rdi+8], 1
    mov qword [rdi+16], 0
    mov qword [rdi+24], 0
    ret

party_val_set_bool_false:
    mov byte [rdi], PV_BOOL
    mov qword [rdi+8], 0
    mov qword [rdi+16], 0
    mov qword [rdi+24], 0
    ret

party_val_set_none:
    mov byte [rdi], PV_NONE
    mov qword [rdi+8], 0
    mov qword [rdi+16], 0
    mov qword [rdi+24], 0
    ret

party_val_set_float:             ; rdi = dst, st0 = double
    fstp qword [rdi+8]
    mov byte [rdi], PV_FLOAT
    mov qword [rdi+16], 0
    mov qword [rdi+24], 0
    ret

party_val_set_str:                 ; rsi = ptr, rcx = length
    mov byte [rdi], PV_STR
    mov qword [rdi+8], 0
    mov qword [rdi+16], rsi
    mov qword [rdi+24], rcx
    ret

party_val_copy:                    ; rsi = src, rdi = dst
    push rcx
    mov rcx, 32
    rep movsb
    pop rcx
    ret

party_neg_top:                     ; negate the value on top of the value stack
    mov rax, [party_vsp]
    cmp rax, 0
    je .pnt_err
    lea rbx, [party_vstack]
    imul rdx, rax, 32
    sub rdx, 32
    add rbx, rdx
    movzx eax, byte [rbx]
    cmp eax, PV_INT
    je .pnt_int
    cmp eax, PV_FLOAT
    je .pnt_float
    jmp .pnt_err
.pnt_int:
    neg qword [rbx+8]
    mov al, 1
    ret
.pnt_float:
    fld qword [rbx+8]
    fchs
    fstp qword [rbx+8]
    mov al, 1
    ret
.pnt_err:
    lea rsi, [msg_party_bad_unary]
    call party_set_err
    xor al, al
    ret

; ------------------------------------------------------------
; party_reset_runtime: resets the shared global interpreter state
; (value stack, variable/locals/frame tables, flags, x87 FPU) to a
; fresh pre-run condition, exactly like party_exec initializes on
; entry. Used before lexing+collecting a compiled .run program so a
; previous party/run leaves no stale state behind. Clobbers rdi, rsi,
; rcx, rax and the FPU.
; ------------------------------------------------------------
party_reset_runtime:
    push rbx
    fninit                        ; reset x87 FPU (CW back to defaults)
    mov byte [party_exec_ok], 1
    mov byte [party_killed], 0
    mov byte [party_returning], 0
    mov byte [kill_flag], 0
    mov qword [party_vsp], 0
    mov qword [party_call_depth], 0
    mov qword [party_loc_count], 0
    mov qword [party_func_count], 0
    mov qword [party_err_msg_ptr], 0

    lea rdi, [party_var_used]
    mov rcx, MAXVARS
    call party_memzero
    lea rdi, [party_loc_used]
    mov rcx, MAXLOCALS
    call party_memzero
    lea rdi, [party_frame_returned]
    mov rcx, MAXCALLS
    call party_memzero
    lea rdi, [party_arr_used]
    mov rcx, PARTY_ARR_MAX
    call party_memzero

    pop rbx
    ret

; ============================================================
;  VALUE STACK
; ============================================================
; party_push_val: rsi = pointer to a 32-byte value; copies it onto
; the top of party_vstack. party_pop_val: rdi = destination for the
; top value; removes it. Both return al=1 on success, al=0 and a
; recorded error on overflow/underflow.

party_push_val:
    push rbx
    push rcx
    push rdx
    push rdi
    mov rax, [party_vsp]
    cmp rax, MAXVSTACK
    jae .pv_ovf
    lea rbx, [party_vstack]
    imul rdx, rax, 32
    add rbx, rdx
    mov rdi, rbx
    mov rcx, 32
    rep movsb
    inc qword [party_vsp]
    mov al, 1
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
.pv_ovf:
    lea rsi, [msg_party_vstack]
    call party_set_err
    xor al, al
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

party_pop_val:
    push rbx
    push rcx
    push rdx
    push rsi
    mov rax, [party_vsp]
    cmp rax, 0
    je .pv_und
    dec qword [party_vsp]
    lea rbx, [party_vstack]
    imul rdx, rax, 32
    sub rdx, 32
    add rbx, rdx
    mov rsi, rbx
    mov rcx, 32
    rep movsb
    mov al, 1
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.pv_und:
    lea rsi, [msg_party_vstack_und]
    call party_set_err
    xor al, al
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; party_truthy: rbx = value pointer -> al=1 if the value counts as
; "true" in an if/while condition. bool/int: nonzero. float: !=0.
; string: non-empty.
; ------------------------------------------------------------
party_truthy:
    movzx eax, byte [rbx]
    cmp eax, PV_BOOL
    je .pt_bool
    cmp eax, PV_INT
    je .pt_bool
    cmp eax, PV_FLOAT
    je .pt_float
    cmp qword [rbx+24], 0
    jne .pt_yes
    xor al, al
    ret
.pt_bool:
    cmp qword [rbx+8], 0
    jne .pt_yes
    xor al, al
    ret
.pt_float:
    fld qword [rbx+8]
    fldz
    fcomip st0, st1
    fstp st0
    jz .pt_no
.pt_yes:
    mov al, 1
    ret
.pt_no:
    xor al, al
    ret

; ------------------------------------------------------------
; party_print_value: rbx = value pointer -> prints the value's text
; (string/int/float/bool; PV_NONE prints nothing). Clobbers rax,
; rbx, rcx, rsi, rdi.
; ------------------------------------------------------------
party_print_value:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    movzx eax, byte [rbx]
    cmp eax, PV_STR
    je .pv_str
    cmp eax, PV_INT
    je .pv_int
    cmp eax, PV_FLOAT
    je .pv_float
    cmp eax, PV_BOOL
    je .pv_bool
    cmp eax, PV_ARRAY
    je .pv_array
    jmp .pv_done
.pv_array:
    ; [e0, e1, ...] - each element printed with a recursive call (the
    ; register save/restore at the top/bottom of this routine makes
    ; that safe; elements are never more than one array deep in
    ; practice, but nothing stops a nested array and this handles it
    ; correctly either way since each recursion level owns its rbx).
    push r12
    push r13
    mov rax, [rbx+8]                ; handle
    call party_arr_check
    cmp al, 1
    jne .pv_array_done              ; a stale/invalid handle just prints nothing
    mov r13, rcx                    ; slot index (rbx now = element-0 ptr)
    mov rsi, lbracket_str
    call print_string
    xor r12, r12                    ; element index
.pv_array_loop:
    cmp r12, [party_arr_count+r13*8]
    jae .pv_array_done_bracket
    cmp r12, 0
    je .pv_array_no_comma
    mov rsi, comma_sp_str
    call print_string
.pv_array_no_comma:
    call party_print_value
    add rbx, 32
    inc r12
    jmp .pv_array_loop
.pv_array_done_bracket:
    mov rsi, rbracket_str
    call print_string
.pv_array_done:
    pop r13
    pop r12
    jmp .pv_done
.pv_str:
    mov rsi, [rbx+16]
    mov rcx, [rbx+24]
    xor ebx, ebx                   ; default attribute for putchar
.pv_pb_loop:
    cmp rcx, 0
    je .pv_done
    mov al, [rsi]
    push rcx
    push rsi
    call putchar
    pop rsi
    pop rcx
    inc rsi
    dec rcx
    jmp .pv_pb_loop
.pv_int:
    mov rax, [rbx+8]
    lea rdi, [party_num_buf]
    call int_to_str
    mov rsi, party_num_buf
    call print_string
    jmp .pv_done
.pv_float:
    lea rsi, [party_num_buf]
    call party_float_to_str
    mov rsi, party_num_buf
    call print_string
    jmp .pv_done
.pv_bool:
    cmp qword [rbx+8], 0
    jne .pv_bool_t
    mov rsi, kw_false
    call print_string
    jmp .pv_done
.pv_bool_t:
    mov rsi, kw_true
    call print_string
.pv_done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
; party_float_to_str: rbx = PV_FLOAT value pointer, rsi = dest
; buffer. Writes a decimal string (up to 6 fractional digits,
; trailing zeros stripped, so 3.14 -> "3.14", 3.0 -> "3").
; Clobbers rax, rbx, rcx, rdx, rsi, rdi, and uses the x87 stack.
; ------------------------------------------------------------
party_float_to_str:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    fld qword [rbx+8]              ; st0 = v
    fldz
    fcomip st0, st1                ; 0 vs v
    jbe .pfs_nonneg
    mov byte [rsi], '-'
    inc rsi
    fchs                           ; st0 = |v|
.pfs_nonneg:
    ; integer part = trunc(|v|), fraction = |v| - intpart
    fstcw [party_fp_cw]
    mov ax, [party_fp_cw]
    or ax, 0x0C00                  ; RC = truncate toward zero
    mov [party_fp_cw2], ax
    fldcw [party_fp_cw2]
    fld st0
    fistp qword [party_tmp_i]
    fldcw [party_fp_cw]
    fild qword [party_tmp_i]       ; st0 = intpart, st1 = |v|
    fsubp st1, st0                 ; st0 = fraction
    mov rax, [party_tmp_i]
    mov rdi, rsi
    call int_to_str
    mov rdi, rsi
.pfs_len:
    cmp byte [rdi], 0
    je .pfs_len_done
    inc rdi
    jmp .pfs_len
.pfs_len_done:
    mov rsi, rdi
    fldz
    fcomip st0, st1                ; fraction == 0?
    je .pfs_no_frac
    mov byte [rsi], '.'
    inc rsi
    mov rcx, 6
.pfs_digit_loop:
    ; st0 = fraction
    fld dword [fp_1em7]
    fcomip st0, st1
    ja .pfs_stop                   ; fraction tiny - stop (kills noise digits)
    fmul dword [fp_10]             ; st0 = fraction*10
    fstcw [party_fp_cw]
    mov ax, [party_fp_cw]
    or ax, 0x0C00
    mov [party_fp_cw2], ax
    fldcw [party_fp_cw2]
    fld st0
    fistp qword [party_tmp_i]
    fldcw [party_fp_cw]
    mov rax, [party_tmp_i]
    cmp rax, 9
    jbe .pfs_digit_ok
    mov rax, 9
.pfs_digit_ok:
    add al, '0'
    mov [rsi], al
    inc rsi
    push rax
    fild qword [party_tmp_i]       ; st0 = digit, st1 = fraction*10
    fsubp st1, st0                 ; st0 = new fraction
    pop rax
    dec rcx
    jnz .pfs_digit_loop
.pfs_stop:
    mov byte [rsi], 0
    fstp st0
    jmp .pfs_done
.pfs_no_frac:
    mov byte [rsi], 0
    fstp st0
.pfs_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
; party_parse_float_text: parses a float literal's text into a
; double. In: rsi = text start, rcx = byte length, rdi = dest qword.
; Clobbers rax, rbx, rcx, rdx, rsi, rdi; uses the x87 stack.
; ------------------------------------------------------------
party_parse_float_text:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    xor rax, rax
.pft_int_loop:
    mov bl, [rsi]
    cmp bl, '0'
    jb .pft_int_done
    cmp bl, '9'
    ja .pft_int_done
    imul rax, rax, 10
    movzx rdx, bl
    sub rdx, '0'
    add rax, rdx
    inc rsi
    dec rcx
    jmp .pft_int_loop
.pft_int_done:
    mov [party_ftmp_i], rax
    fild qword [party_ftmp_i]      ; st0 = intpart
    cmp rcx, 0
    je .pft_store
    cmp byte [rsi], '.'
    jne .pft_store
    inc rsi
    dec rcx
    xor rbx, rbx                   ; frac_int
    xor rdx, rdx                   ; digit count
.pft_frac_loop:
    cmp rcx, 0
    je .pft_frac_done
    mov al, [rsi]
    cmp al, '0'
    jb .pft_frac_done
    cmp al, '9'
    ja .pft_frac_done
    imul rbx, rbx, 10
    movzx rax, al
    sub rax, '0'
    add rbx, rax
    inc rdx
    inc rsi
    dec rcx
    jmp .pft_frac_loop
.pft_frac_done:
    mov [party_ftmp_i], rbx
    fild qword [party_ftmp_i]      ; st0 = frac_int, st1 = intpart
    fld1
.pft_pow_loop:
    cmp rdx, 0
    je .pft_pow_done
    fmul dword [fp_10]
    dec rdx
    jmp .pft_pow_loop
.pft_pow_done:
    fdivp st1, st0                 ; st0 = frac, st1 = intpart
    faddp st1, st0                 ; st0 = intpart + frac
.pft_store:
    pop rdi
    fstp qword [rdi]
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
;  EXPRESSION PARSER  (recursive descent, left-associative)
; ============================================================
; Each party_parse_* evaluates its production and leaves exactly one
; value on the value stack, advancing r13 past everything it
; consumed. Every level is a no-op once party_exec_ok==0, so errors
; unwind naturally. The value stack is left balanced on success
; (each binary op pops two and pushes one).

party_parse_expr:
party_parse_eq:
    cmp byte [party_exec_ok], 0
    je .out
    call party_parse_rel
.pq_loop:
    cmp byte [party_exec_ok], 0
    je .out
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_EQEQ
    je .pq_op
    cmp eax, TOK_NEQ
    je .pq_op
    jmp .out
.pq_op:
    inc r13
    push rax
    call party_parse_rel
    cmp byte [party_exec_ok], 0
    jne .pq_have_rhs
    pop rax
    jmp .out
.pq_have_rhs:
    pop rax
    cmp al, TOK_EQEQ
    je .pq_eq
    call party_op_neq
    jmp .pq_loop
.pq_eq:
    call party_op_eq
    jmp .pq_loop
.out:
    ret

party_parse_rel:
    cmp byte [party_exec_ok], 0
    je .out
    call party_parse_add
.pr_loop:
    cmp byte [party_exec_ok], 0
    je .out
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LT
    je .pr_op
    cmp eax, TOK_LTE
    je .pr_op
    cmp eax, TOK_GT
    je .pr_op
    cmp eax, TOK_GTE
    je .pr_op
    jmp .out
.pr_op:
    inc r13
    push rax
    call party_parse_add
    cmp byte [party_exec_ok], 0
    jne .pr_have_rhs
    pop rax
    jmp .out
.pr_have_rhs:
    pop rax
    call party_op_rel
    jmp .pr_loop
.out:
    ret

party_parse_add:
    cmp byte [party_exec_ok], 0
    je .out
    call party_parse_mul
.pa_loop:
    cmp byte [party_exec_ok], 0
    je .out
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_PLUS
    je .pa_op
    cmp eax, TOK_MINUS
    je .pa_op
    jmp .out
.pa_op:
    inc r13
    push rax
    call party_parse_mul
    cmp byte [party_exec_ok], 0
    jne .pa_have_rhs
    pop rax
    jmp .out
.pa_have_rhs:
    pop rax
    call party_op_bin
    jmp .pa_loop
.out:
    ret

party_parse_mul:
    cmp byte [party_exec_ok], 0
    je .out
    call party_parse_unary
.pm_loop:
    cmp byte [party_exec_ok], 0
    je .out
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_STAR
    je .pm_op
    cmp eax, TOK_SLASH
    je .pm_op
    cmp eax, TOK_PERCENT
    je .pm_op
    jmp .out
.pm_op:
    inc r13
    push rax
    call party_parse_unary
    cmp byte [party_exec_ok], 0
    jne .pm_have_rhs
    pop rax
    jmp .out
.pm_have_rhs:
    pop rax
    call party_op_bin
    jmp .pm_loop
.out:
    ret

party_parse_unary:
    cmp byte [party_exec_ok], 0
    je .out
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_MINUS
    je .pu_neg
    jmp party_parse_primary
.pu_neg:
    inc r13
    call party_parse_unary
    cmp byte [party_exec_ok], 1
    jne .out
    mov rax, [party_vsp]
    cmp rax, 0
    je .pu_err
    lea rbx, [party_vstack]
    imul rdx, rax, 32
    sub rdx, 32
    add rbx, rdx
    movzx eax, byte [rbx]
    cmp eax, PV_INT
    je .pu_neg_int
    cmp eax, PV_FLOAT
    je .pu_neg_float
    jmp .pu_err
.pu_neg_int:
    neg qword [rbx+8]
    jmp .out
.pu_neg_float:
    fld qword [rbx+8]
    fchs
    fstp qword [rbx+8]
    jmp .out
.pu_err:
    lea rsi, [msg_party_bad_unary]
    call party_set_err
.out:
    ret

; ------------------------------------------------------------
; STRING INTERPOLATION (Phase 2)
;
; "hello {name}" embeds the string form of the variable `name`
; inline. Scope for this phase: `{identifier}` only - a bare,
; already-declared variable name, first char [a-zA-Z_], rest
; [a-zA-Z0-9_] (same rule as any other identifier). `{{` and `}}`
; escape to a literal brace. Full `{<expr>}` / `{ident(...)}` calls
; are deferred - see phases.txt Phase 2 notes - since re-entering
; party_parse_expr on text that was never tokenized is a bigger diff
; than this phase needs.
;
; Evaluated lazily, per the recommended approach in phases.txt: the
; lexer still emits one plain TOK_STR per literal (token count/shape
; unchanged); the scan for `{`/`}` and the actual substitution happen
; here, when the literal is turned into a runtime value.
; ------------------------------------------------------------

; party_val_to_string: rbx = value pointer. Formats the value as
; text. Out: rsi = ptr to text, rcx = length. PV_STR values pass
; their existing slice straight through (no copy). Numeric/bool text
; is written into the shared party_num_buf scratch buffer (the same
; one party_print_value uses) - copy it out (as party_pel_append
; below does) before formatting another value if it must survive
; that. PV_NONE yields length 0.
; Clobbers rax, rcx, rdx, rsi, rdi.
; ------------------------------------------------------------
party_val_to_string:
    movzx eax, byte [rbx]
    cmp eax, PV_STR
    je .vts_str
    cmp eax, PV_INT
    je .vts_int
    cmp eax, PV_FLOAT
    je .vts_float
    cmp eax, PV_BOOL
    je .vts_bool
    xor rsi, rsi
    xor rcx, rcx
    ret
.vts_str:
    mov rsi, [rbx+16]
    mov rcx, [rbx+24]
    ret
.vts_int:
    mov rax, [rbx+8]
    lea rdi, [party_num_buf]
    call int_to_str
    lea rsi, [party_num_buf]
    call str_len
    mov rcx, rax
    lea rsi, [party_num_buf]
    ret
.vts_float:
    lea rsi, [party_num_buf]
    call party_float_to_str
    lea rsi, [party_num_buf]
    call str_len
    mov rcx, rax
    lea rsi, [party_num_buf]
    ret
.vts_bool:
    cmp qword [rbx+8], 0
    jne .vts_bool_t
    mov rsi, kw_false
    call str_len
    mov rcx, rax
    mov rsi, kw_false
    ret
.vts_bool_t:
    mov rsi, kw_true
    call str_len
    mov rcx, rax
    mov rsi, kw_true
    ret

; party_str_has_lbrace: rsi = ptr, rcx = len -> al = 1 if the slice
; contains a '{' byte, else al = 0. Cheap pre-check so a plain
; literal (the overwhelming common case) skips interpolation
; entirely and keeps pointing straight into the source buffer,
; exactly as before this phase - only literals that opt in via '{'
; pay the party_eval_string_literal cost.
; Clobbers rax, rcx, rsi.
party_str_has_lbrace:
.phl_loop:
    cmp rcx, 0
    je .phl_no
    mov al, [rsi]
    cmp al, '{'
    je .phl_yes
    inc rsi
    dec rcx
    jmp .phl_loop
.phl_yes:
    mov al, 1
    ret
.phl_no:
    xor al, al
    ret

; party_pel_append: appends rcx bytes from rsi to the interpolation
; output cursor (r10 = write pointer, r11 = bytes of capacity left),
; advancing both in place. On overflow, sets party_exec_ok = 0 via
; party_set_err (msg_party_interp_overflow) - caller must check
; party_exec_ok after return either way.
; Clobbers rax, rcx, rsi.
party_pel_append:
.ppa_loop:
    cmp rcx, 0
    je .ppa_done
    cmp r11, 0
    je .ppa_overflow
    mov al, [rsi]
    mov [r10], al
    inc rsi
    inc r10
    dec r11
    dec rcx
    jmp .ppa_loop
.ppa_overflow:
    lea rsi, [msg_party_interp_overflow]
    call party_set_err
    ret
.ppa_done:
    ret

; party_eval_string_literal: rsi = ptr to string literal content
; (raw slice into party_src_base, same as a TOK_STR token's text),
; rcx = length. Expands {identifier} substitutions and {{ / }}
; brace escapes into party_interp_buf.
; Out: on success, party_exec_ok stays 1, rdi = party_interp_buf,
; rcx = result length. On error, sets party_exec_ok = 0 via
; party_set_err (caller's r13 must still point at the TOK_STR token
; so the reported line number is right) and rdi/rcx are undefined -
; caller must check party_exec_ok before using them.
; NOTE: party_interp_buf is a single shared scratch buffer, same
; aliasing caveat PARTY_SPEC.md already documents for `read` and for
; string literals sharing the source buffer - a later interpolated
; literal overwrites an earlier one's text, so a var holding an
; interpolated string needs to be consumed (displayed, rushed,
; compared, etc.) before the next interpolated literal is evaluated
; if the old text must still be around.
; Clobbers rax, rbx, rcx, rdx, rsi, rdi, r8, r9, r10, r11.
party_eval_string_literal:
    mov r8, rsi                    ; src cursor
    mov r9, rcx                    ; src bytes remaining
    lea r10, [party_interp_buf]    ; dst cursor
    mov r11, PARTY_INTERP_MAX-1    ; dst capacity (room left for NUL)
.pel_loop:
    cmp r9, 0
    je .pel_done
    mov al, [r8]
    cmp al, '{'
    je .pel_lbrace
    cmp al, '}'
    je .pel_rbrace
    mov [party_pel_char_scratch], al
    lea rsi, [party_pel_char_scratch]
    mov rcx, 1
    call party_pel_append
    cmp byte [party_exec_ok], 0
    je .pel_out
    inc r8
    dec r9
    jmp .pel_loop
.pel_rbrace:
    cmp r9, 1
    jbe .pel_rbrace_lit
    cmp byte [r8+1], '}'
    jne .pel_rbrace_lit
    mov byte [party_pel_char_scratch], '}'
    lea rsi, [party_pel_char_scratch]
    mov rcx, 1
    call party_pel_append
    cmp byte [party_exec_ok], 0
    je .pel_out
    add r8, 2
    sub r9, 2
    jmp .pel_loop
.pel_rbrace_lit:
    mov [party_pel_char_scratch], al
    lea rsi, [party_pel_char_scratch]
    mov rcx, 1
    call party_pel_append
    cmp byte [party_exec_ok], 0
    je .pel_out
    inc r8
    dec r9
    jmp .pel_loop
.pel_lbrace:
    cmp r9, 1
    jbe .pel_lbrace_open
    cmp byte [r8+1], '{'
    jne .pel_lbrace_open
    mov byte [party_pel_char_scratch], '{'
    lea rsi, [party_pel_char_scratch]
    mov rcx, 1
    call party_pel_append
    cmp byte [party_exec_ok], 0
    je .pel_out
    add r8, 2
    sub r9, 2
    jmp .pel_loop
.pel_lbrace_open:
    inc r8                          ; consume '{'
    dec r9
    mov rdx, r8                     ; identifier start
    xor rcx, rcx                    ; identifier length so far
.pel_ident_scan:
    cmp r9, 0
    je .pel_unterminated
    mov al, [r8]
    cmp al, '}'
    je .pel_ident_end
    cmp al, 'a'
    jb .pel_ic_upper
    cmp al, 'z'
    jbe .pel_ic_ok
    jmp .pel_ic_digit
.pel_ic_upper:
    cmp al, 'A'
    jb .pel_ic_us
    cmp al, 'Z'
    jbe .pel_ic_ok
    jmp .pel_ic_us
.pel_ic_digit:
    cmp al, '0'
    jb .pel_ic_us
    cmp al, '9'
    ja .pel_ic_us
    cmp rcx, 0                      ; digits can't start an identifier
    je .pel_badident
    jmp .pel_ic_ok
.pel_ic_us:
    cmp al, '_'
    jne .pel_badident
.pel_ic_ok:
    inc r8
    dec r9
    inc rcx
    jmp .pel_ident_scan
.pel_ident_end:
    cmp rcx, 0                      ; empty "{}"
    je .pel_badident
    cmp rcx, PARTY_IDENT_MAX-1
    jbe .pel_ident_len_ok
    mov rcx, PARTY_IDENT_MAX-1
.pel_ident_len_ok:
    mov rsi, rdx
    lea rdi, [party_interp_ident_buf]
.pel_copy_ident:
    cmp rcx, 0
    je .pel_copy_ident_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .pel_copy_ident
.pel_copy_ident_done:
    mov byte [rdi], 0
    lea rsi, [party_interp_ident_buf]
    call party_var_get_ptr
    cmp al, 1
    jne .pel_undef
    call party_val_to_string       ; rbx (from var_get_ptr) -> rsi, rcx
    call party_pel_append
    cmp byte [party_exec_ok], 0
    je .pel_out
    inc r8                         ; consume the closing '}'
    dec r9
    jmp .pel_loop
.pel_done:
    mov byte [r10], 0
    lea rax, [party_interp_buf]
    mov rcx, r10
    sub rcx, rax
    lea rdi, [party_interp_buf]
    ret
.pel_unterminated:
    lea rsi, [msg_party_interp_unterm]
    call party_set_err
    jmp .pel_out
.pel_badident:
    lea rsi, [msg_party_interp_badident]
    call party_set_err
    jmp .pel_out
.pel_undef:
    lea rsi, [msg_party_undef_var]
    call party_set_err
.pel_out:
    ret

party_parse_primary:
    cmp byte [party_exec_ok], 0
    je .out
    push r12
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_INT
    je .pp_int
    cmp eax, TOK_FLOAT
    je .pp_float
    cmp eax, TOK_STR
    je .pp_str
    cmp eax, TOK_TRUE
    je .pp_true
    cmp eax, TOK_FALSE
    je .pp_false
    cmp eax, TOK_LPAREN
    je .pp_paren
    cmp eax, TOK_IDENT
    je .pp_ident
    jmp .pp_err_expr
.pp_int:
    mov eax, [rbx+4]
    mov rsi, [party_src_base]
    add rsi, rax
    call parse_uint_run
    lea rdi, [party_scratch]
    call party_val_set_int
    lea rsi, [party_scratch]
    call party_push_val
    cmp byte [party_exec_ok], 1
    jne .pp_out
    inc r13
    jmp .pp_out
.pp_float:
    movzx rcx, word [rbx+2]
    mov eax, [rbx+4]
    mov rsi, [party_src_base]
    add rsi, rax
    lea rdi, [party_scratch+8]
    call party_parse_float_text
    mov byte [party_scratch], PV_FLOAT
    mov qword [party_scratch+16], 0
    mov qword [party_scratch+24], 0
    lea rsi, [party_scratch]
    call party_push_val
    cmp byte [party_exec_ok], 1
    jne .pp_out
    inc r13
    jmp .pp_out
.pp_str:
    movzx rcx, word [rbx+2]
    mov eax, [rbx+4]
    mov rsi, [party_src_base]
    add rsi, rax
    ; Plain literals (no '{') keep pointing straight into the source
    ; buffer, exactly as before Phase 2 - only literals that opt in
    ; via '{' pay the interpolation cost (and its shared-buffer
    ; aliasing caveat, see PARTY_SPEC.md section 1).
    push rsi
    push rcx
    call party_str_has_lbrace
    pop rcx
    pop rsi
    cmp al, 1
    je .pp_str_interp
    lea rdi, [party_scratch]
    call party_val_set_str
    jmp .pp_str_push
.pp_str_interp:
    call party_eval_string_literal
    cmp byte [party_exec_ok], 1
    jne .pp_out
    mov rsi, rdi
    lea rdi, [party_scratch]
    call party_val_set_str
.pp_str_push:
    lea rsi, [party_scratch]
    call party_push_val
    cmp byte [party_exec_ok], 1
    jne .pp_out
    inc r13
    jmp .pp_out
.pp_true:
    lea rdi, [party_scratch]
    call party_val_set_bool_true
    lea rsi, [party_scratch]
    call party_push_val
    inc r13
    jmp .pp_out
.pp_false:
    lea rdi, [party_scratch]
    call party_val_set_bool_false
    lea rsi, [party_scratch]
    call party_push_val
    inc r13
    jmp .pp_out
.pp_paren:
    inc r13
    call party_parse_expr
    cmp byte [party_exec_ok], 1
    jne .pp_out
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_RPAREN
    jne .pp_err_rparen
    inc r13
    jmp .pp_out
.pp_ident:
    call party_copy_tok_text_cur
    mov r12, r13
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LPAREN
    je .pp_call
    lea rsi, [party_ident_buf]
    call party_var_get_ptr
    cmp al, 1
    jne .pp_err_undef
    lea rdi, [party_scratch]
    mov rsi, rbx
    call party_val_copy
    lea rsi, [party_scratch]
    call party_push_val
    jmp .pp_out
.pp_call:
    ; r13 = '(' and party_ident_buf = function name
    call party_parse_call
    cmp byte [party_exec_ok], 1
    jne .pp_out
    mov rax, [party_vsp]
    cmp rax, 0
    je .pp_out
    lea rbx, [party_vstack]
    imul rdx, rax, 32
    sub rdx, 32
    add rbx, rdx
    cmp byte [rbx], PV_NONE
    jne .pp_out
    lea rsi, [msg_party_noretval]
    call party_set_err
    jmp .pp_out
.pp_err_expr:
    lea rsi, [msg_party_expr_expected]
    call party_set_err
    jmp .pp_out
.pp_err_rparen:
    lea rsi, [msg_party_rparen]
    call party_set_err
    jmp .pp_out
.pp_err_undef:
    lea rsi, [msg_party_undef_var]
    call party_set_err
.pp_out:
    pop r12
.out:
    ret

; ------------------------------------------------------------
; party_parse_call: parses a function call. In: r13 = '(' following
; the function-name token (name text already in party_ident_buf).
; Evaluates args (pushing each), checks arity, invokes the function,
; and leaves the result value on the value stack with r13 just past
; the closing ')'. Clobbers rax, rbx, r8-r14.
; ------------------------------------------------------------
party_parse_call:
    cmp byte [party_exec_ok], 0
    je .out
    push r12
    push r14
    push r15
    push rsi
    push rdi
    push rcx
    push rax
    lea rsi, [party_ident_buf]
    lea rdi, [party_call_name_buf]
    call party_strcpy_save
    pop rax
    pop rcx
    pop rdi
    pop rsi
    inc r13                        ; past '('
    xor r14, r14                   ; arg count
.ppc_arg_loop:
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_RPAREN
    je .ppc_args_done
    call party_parse_expr
    cmp byte [party_exec_ok], 1
    jne .ppc_out
    inc r14
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_COMMA
    jne .ppc_expect_rparen
    inc r13
    jmp .ppc_arg_loop
.ppc_expect_rparen:
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_RPAREN
    jne .ppc_err_rparen
.ppc_args_done:
    inc r13                        ; past ')'
    ; Builtins (fopen/fread/fwrite/fclose/fexists/fdelete - Phase 3)
    ; are checked before user-defined functions, so a script can't
    ; shadow them. party_call_builtin clobbers r8-r13 on a match (see
    ; its header comment), so r13 - the token cursor, which must
    ; survive past this call either way - is saved/restored around it.
    push r13
    call party_call_builtin
    pop r13
    cmp al, 1
    je .ppc_out                    ; builtin handled everything (result
                                    ; pushed, or exec_ok cleared on error)
    lea rsi, [party_call_name_buf]
    call party_func_find
    cmp r15, -1
    je .ppc_err_nofunc
    movzx eax, byte [party_func_nparams+r15]
    cmp eax, r14d
    jne .ppc_err_arity
    call party_invoke_func
    jmp .ppc_out
.ppc_err_rparen:
    lea rsi, [msg_party_rparen]
    call party_set_err
    jmp .ppc_out
.ppc_err_nofunc:
    lea rsi, [msg_party_undef_func]
    call party_set_err
    jmp .ppc_out
.ppc_err_arity:
    lea rsi, [msg_party_arg_count]
    call party_set_err
.ppc_out:
    pop r15
    pop r14
    pop r12
.out:
    ret

; ============================================================
;  IN-LANGUAGE FILE ACCESS API (Phase 3)
;
; fopen/fread/fwrite/fclose/fexists/fdelete: real file I/O without
; shelling out via `rush`. These are the first "builtin functions" -
; before this phase every call name went straight to party_func_find
; (user-defined functions only); party_call_builtin below is checked
; first and, on a name match, handles arg-count checking, argument
; popping, and pushing exactly one result value itself (matching
; party_invoke_func's contract), the same way a user function call
; leaves one value on the stack whether or not the caller uses it.
; A user script cannot redefine these names - the builtin check runs
; before party_func_find ever sees them.
;
; All routed straight to the fs_* primitives (kernel.asm ~8251+) -
; the same calls cmd_cat/cmd_mkfl/cmd_edit/cmd_rm already use, not
; reimplemented and not shelled out to `rush`.
; ============================================================

PARTY_FH_MAX equ 12          ; open-file-handle table capacity
PARTY_PATH_MAX equ 200       ; NUL-terminated path staging buffer size

; party_call_builtin: dispatches to a builtin function if
; party_call_name_buf names one. In: r14 = evaluated arg count (args
; already pushed onto party_vstack, first arg first - same
; convention party_invoke_func documents).
; Out: al = 1 if the name matched a builtin - whether it then
; succeeded or errored, check party_exec_ok either way, and exactly
; one value (a real result, or PV_NONE) has been pushed on success.
; al = 0 if the name isn't a builtin; args are left untouched on the
; stack for the normal user-function path.
; Clobbers rax, rbx, rcx, rdx, rsi, rdi, r8-r13 when al=1; untouched
; when al=0 (no builtin matched, nothing was done).
party_call_builtin:
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_fopen]
    call str_eq
    cmp al, 1
    je .pcb_fopen
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_fread]
    call str_eq
    cmp al, 1
    je .pcb_fread
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_fwrite]
    call str_eq
    cmp al, 1
    je .pcb_fwrite
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_fclose]
    call str_eq
    cmp al, 1
    je .pcb_fclose
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_fexists]
    call str_eq
    cmp al, 1
    je .pcb_fexists
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_fdelete]
    call str_eq
    cmp al, 1
    je .pcb_fdelete
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_arr_new]
    call str_eq
    cmp al, 1
    je .pcb_arr_new
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_arr_len]
    call str_eq
    cmp al, 1
    je .pcb_arr_len
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_arr_get]
    call str_eq
    cmp al, 1
    je .pcb_arr_get
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_arr_set]
    call str_eq
    cmp al, 1
    je .pcb_arr_set
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_arr_free]
    call str_eq
    cmp al, 1
    je .pcb_arr_free
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_rand]
    call str_eq
    cmp al, 1
    je .pcb_rand
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_randint]
    call str_eq
    cmp al, 1
    je .pcb_randint
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_randseed]
    call str_eq
    cmp al, 1
    je .pcb_randseed
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_time]
    call str_eq
    cmp al, 1
    je .pcb_time
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_datestr]
    call str_eq
    cmp al, 1
    je .pcb_datestr
    lea rsi, [party_call_name_buf]
    lea rdi, [str_fn_timestr]
    call str_eq
    cmp al, 1
    je .pcb_timestr
    xor al, al
    ret
.pcb_rand:
    call party_bi_rand
    mov al, 1
    ret
.pcb_randint:
    call party_bi_randint
    mov al, 1
    ret
.pcb_randseed:
    call party_bi_randseed
    mov al, 1
    ret
.pcb_time:
    call party_bi_time
    mov al, 1
    ret
.pcb_datestr:
    call party_bi_datestr
    mov al, 1
    ret
.pcb_timestr:
    call party_bi_timestr
    mov al, 1
    ret
.pcb_arr_new:
    call party_bi_arr_new
    mov al, 1
    ret
.pcb_arr_len:
    call party_bi_arr_len
    mov al, 1
    ret
.pcb_arr_get:
    call party_bi_arr_get
    mov al, 1
    ret
.pcb_arr_set:
    call party_bi_arr_set
    mov al, 1
    ret
.pcb_arr_free:
    call party_bi_arr_free
    mov al, 1
    ret
.pcb_fopen:
    call party_bi_fopen
    mov al, 1
    ret
.pcb_fread:
    call party_bi_fread
    mov al, 1
    ret
.pcb_fwrite:
    call party_bi_fwrite
    mov al, 1
    ret
.pcb_fclose:
    call party_bi_fclose
    mov al, 1
    ret
.pcb_fexists:
    call party_bi_fexists
    mov al, 1
    ret
.pcb_fdelete:
    call party_bi_fdelete
    mov al, 1
    ret

; party_fh_alloc: finds a free handle slot. Out: rax = slot index, or
; -1 if the table is full (msg_party_fh_full via party_set_err - the
; -1 is informational for the caller's own branch, exec_ok is already
; false). Clobbers rax, rcx.
party_fh_alloc:
    xor rcx, rcx
.pfa_loop:
    cmp rcx, PARTY_FH_MAX
    jae .pfa_full
    cmp byte [party_fh_used+rcx], 0
    je .pfa_found
    inc rcx
    jmp .pfa_loop
.pfa_found:
    mov byte [party_fh_used+rcx], 1
    mov rax, rcx
    ret
.pfa_full:
    lea rsi, [msg_party_fh_full]
    call party_set_err
    mov rax, -1
    ret

; party_fh_check: rax = handle value (int64). Validates it's in range
; and currently open.
; Out: on success, rbx = the file's node index, rcx = handle slot
; index, al = 1. On failure, sets party_exec_ok = 0 via party_set_err
; (msg_party_fh_invalid) and al = 0.
; Clobbers rax, rbx, rcx, rsi.
party_fh_check:
    cmp rax, 0
    jl .fhc_bad
    cmp rax, PARTY_FH_MAX
    jae .fhc_bad
    mov rcx, rax
    cmp byte [party_fh_used+rcx], 0
    je .fhc_bad
    mov ebx, [party_fh_node+rcx*4]
    mov al, 1
    ret
.fhc_bad:
    lea rsi, [msg_party_fh_invalid]
    call party_set_err
    xor al, al
    ret

; party_copy_str_to_cpath: rsi = ptr, rcx = len (a PV_STR's raw
; slice). Copies it into party_fh_path_buf, NUL-terminated, for
; passing to fs_resolve_path (which expects a C string).
; Out: al = 1 on success. al = 0 if it doesn't fit (sets
; party_exec_ok = 0 via party_set_err, msg_party_path_too_long).
; Clobbers rax, rcx, rsi, rdi.
party_copy_str_to_cpath:
    cmp rcx, PARTY_PATH_MAX-1
    jb .pctc_ok
    lea rsi, [msg_party_path_too_long]
    call party_set_err
    xor al, al
    ret
.pctc_ok:
    lea rdi, [party_fh_path_buf]
.pctc_loop:
    cmp rcx, 0
    je .pctc_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .pctc_loop
.pctc_done:
    mov byte [rdi], 0
    mov al, 1
    ret

; ---- fopen(path, mode) -> int handle ----
; mode is "r" (must already exist), "w" (create if missing, truncate
; if it exists), or "a" (create if missing, keep existing content).
; Errors (bad arg types/count, bad mode, path doesn't resolve, path
; names a folder not a file, handle table full, node table full) are
; all runtime errors - fopen never returns an invalid handle.
party_bi_fopen:
    cmp r14, 2
    je .bfo_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bfo_argc_ok:
    lea rdi, [party_scratch2]      ; mode (pushed last = on top)
    call party_pop_val
    lea rdi, [party_scratch1]      ; path
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .bfo_out
    cmp byte [party_scratch1], PV_STR
    jne .bfo_err_argtype
    cmp byte [party_scratch2], PV_STR
    jne .bfo_err_argtype
    ; mode must be exactly one of "r" / "w" / "a"
    cmp qword [party_scratch2+24], 1
    jne .bfo_err_mode
    mov rsi, [party_scratch2+16]
    mov al, [rsi]
    mov [party_fh_pending_mode], al
    cmp al, 'r'
    je .bfo_mode_ok
    cmp al, 'w'
    je .bfo_mode_ok
    cmp al, 'a'
    je .bfo_mode_ok
    jmp .bfo_err_mode
.bfo_mode_ok:
    mov rsi, [party_scratch1+16]
    mov rcx, [party_scratch1+24]
    call party_copy_str_to_cpath
    cmp al, 1
    jne .bfo_out
    mov rax, [cur_dir]
    lea rsi, [party_fh_path_buf]
    lea rdi, [leaf1_buf]
    call fs_resolve_path
    cmp rax, -1
    je .bfo_err_path
    mov r11, rax                   ; parent dir
    mov rax, r11
    lea rsi, [leaf1_buf]
    mov r10, -1                    ; any type - need to notice folder collisions
    call fs_find_child
    cmp rax, -1
    je .bfo_notfound
    ; something with this name already exists
    movzx rdx, byte [node_type + rax]
    cmp rdx, 2
    jne .bfo_err_isdir
    mov r12, rax                   ; existing file node
    cmp byte [party_fh_pending_mode], 'w'
    jne .bfo_have_node
    ; "w" on an existing file: truncate immediately
    mov rax, r12
    xor rsi, rsi
    xor rcx, rcx
    call fs_write_binary_file
    call maybe_auto_sync
    jmp .bfo_have_node
.bfo_notfound:
    cmp byte [party_fh_pending_mode], 'r'
    je .bfo_err_notfound
    mov rax, r11
    lea rsi, [leaf1_buf]
    mov r10, 2                     ; type file
    call fs_create_node
    cmp rax, -1
    je .bfo_err_full
    mov r12, rax
    call maybe_auto_sync
.bfo_have_node:
    call party_fh_alloc
    cmp rax, -1
    je .bfo_out                    ; party_fh_alloc already set the error
    mov rcx, rax                   ; slot index
    mov [party_fh_node+rcx*4], r12d
    mov al, [party_fh_pending_mode]
    mov [party_fh_mode+rcx], al
    lea rdi, [party_scratch]
    mov rax, rcx
    call party_val_set_int
    lea rsi, [party_scratch]
    call party_push_val
    jmp .bfo_out
.bfo_err_argtype:
    lea rsi, [msg_party_fopen_args]
    call party_set_err
    jmp .bfo_out
.bfo_err_mode:
    lea rsi, [msg_party_fopen_mode]
    call party_set_err
    jmp .bfo_out
.bfo_err_path:
    lea rsi, [msg_party_fopen_path]
    call party_set_err
    jmp .bfo_out
.bfo_err_notfound:
    lea rsi, [msg_party_fopen_notfound]
    call party_set_err
    jmp .bfo_out
.bfo_err_isdir:
    lea rsi, [msg_party_fopen_isdir]
    call party_set_err
    jmp .bfo_out
.bfo_err_full:
    lea rsi, [msg_party_fopen_full]
    call party_set_err
.bfo_out:
    ret

; ---- fread(h) -> whole file content as a string ----
party_bi_fread:
    cmp r14, 1
    je .bfr_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bfr_argc_ok:
    lea rdi, [party_scratch1]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .bfr_out
    cmp byte [party_scratch1], PV_INT
    jne .bfr_err_type
    mov rax, [party_scratch1+8]
    call party_fh_check
    cmp al, 1
    jne .bfr_out
    mov rax, rbx                   ; node index
    call fs_file_len
    cmp rax, EDIT_MAX
    jae .bfr_err_toobig
    mov r12, rax                   ; length
    mov rbx, rax
    mov rax, [party_scratch1+8]
    call party_fh_check             ; rbx clobbered above - re-fetch node idx
    mov rax, rbx
    lea rdi, [fs_io_buf]
    call fs_read_binary_file        ; rax = bytes actually copied
    lea rdi, [party_scratch]
    mov rsi, fs_io_buf
    mov rcx, rax
    call party_val_set_str
    lea rsi, [party_scratch]
    call party_push_val
    jmp .bfr_out
.bfr_err_type:
    lea rsi, [msg_party_fh_type]
    call party_set_err
    jmp .bfr_out
.bfr_err_toobig:
    lea rsi, [msg_party_fread_toobig]
    call party_set_err
.bfr_out:
    ret

; ---- fwrite(h, text) -> none ----
; Appends `text` to the file's current content (read-modify-write:
; there's no incremental-append primitive in the fs_* layer, so this
; reads the existing bytes, concatenates, and writes the whole run
; back via fs_write_binary_file, same as fs_write_file/
; fs_write_binary_file always replacing the full content).
party_bi_fwrite:
    cmp r14, 2
    je .bfw_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bfw_argc_ok:
    lea rdi, [party_scratch2]      ; text (on top)
    call party_pop_val
    lea rdi, [party_scratch1]      ; handle
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .bfw_out
    cmp byte [party_scratch1], PV_INT
    jne .bfw_err_htype
    cmp byte [party_scratch2], PV_STR
    jne .bfw_err_ttype
    mov rax, [party_scratch1+8]
    call party_fh_check
    cmp al, 1
    jne .bfw_out
    cmp byte [party_fh_mode+rcx], 'r'
    jne .bfw_mode_ok
    lea rsi, [msg_party_fh_readonly]
    call party_set_err
    jmp .bfw_out
.bfw_mode_ok:
    mov r12, rbx                    ; node index
    mov rax, r12
    call fs_file_len
    cmp rax, EDIT_MAX
    jae .bfw_err_toobig
    mov r13, rax                    ; current length
    mov rax, r12
    lea rdi, [fs_io_buf]
    call fs_read_binary_file        ; rax = bytes actually read back
    mov r13, rax
    mov rax, r13
    add rax, [party_scratch2+24]
    cmp rax, EDIT_MAX
    ja .bfw_err_toobig
    lea rdi, [fs_io_buf]
    add rdi, r13
    mov rsi, [party_scratch2+16]
    mov rcx, [party_scratch2+24]
    push rcx
.bfw_copy:
    cmp rcx, 0
    je .bfw_copy_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .bfw_copy
.bfw_copy_done:
    pop rcx
    mov rax, r13
    add rax, rcx                    ; total length
    mov r13, rax
    mov rax, r12
    mov rsi, fs_io_buf
    mov rcx, r13
    call fs_write_binary_file
    call maybe_auto_sync
    lea rdi, [party_scratch]
    call party_val_set_none
    lea rsi, [party_scratch]
    call party_push_val
    jmp .bfw_out
.bfw_err_htype:
    lea rsi, [msg_party_fh_type]
    call party_set_err
    jmp .bfw_out
.bfw_err_ttype:
    lea rsi, [msg_party_fwrite_type]
    call party_set_err
    jmp .bfw_out
.bfw_err_toobig:
    lea rsi, [msg_party_fwrite_toobig]
    call party_set_err
.bfw_out:
    ret

; ---- fclose(h) -> none ----
party_bi_fclose:
    cmp r14, 1
    je .bfc_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bfc_argc_ok:
    lea rdi, [party_scratch1]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .bfc_out
    cmp byte [party_scratch1], PV_INT
    jne .bfc_err_type
    mov rax, [party_scratch1+8]
    call party_fh_check
    cmp al, 1
    jne .bfc_out
    mov byte [party_fh_used+rcx], 0
    lea rdi, [party_scratch]
    call party_val_set_none
    lea rsi, [party_scratch]
    call party_push_val
    jmp .bfc_out
.bfc_err_type:
    lea rsi, [msg_party_fh_type]
    call party_set_err
.bfc_out:
    ret

; ---- fexists(path) -> bool ----
; Deliberately never errors on a nonexistent path (unlike the rest of
; this API) - testing existence is the whole point, so a path that
; simply doesn't resolve just yields `false`, matching the usual
; meaning of an "exists" check in other languages. A wrong argument
; type is still a runtime error like everywhere else.
party_bi_fexists:
    cmp r14, 1
    je .bfe_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bfe_argc_ok:
    lea rdi, [party_scratch1]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .bfe_out
    cmp byte [party_scratch1], PV_STR
    jne .bfe_err_type
    mov rsi, [party_scratch1+16]
    mov rcx, [party_scratch1+24]
    call party_copy_str_to_cpath
    cmp al, 1
    jne .bfe_out
    mov rax, [cur_dir]
    lea rsi, [party_fh_path_buf]
    lea rdi, [leaf1_buf]
    call fs_resolve_path
    cmp rax, -1
    je .bfe_false
    mov r11, rax
    lea rsi, [leaf1_buf]
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .bfe_false
    lea rdi, [party_scratch]
    call party_val_set_bool_true
    jmp .bfe_push
.bfe_false:
    lea rdi, [party_scratch]
    call party_val_set_bool_false
.bfe_push:
    lea rsi, [party_scratch]
    call party_push_val
    jmp .bfe_out
.bfe_err_type:
    lea rsi, [msg_party_fexists_type]
    call party_set_err
.bfe_out:
    ret

; ---- fdelete(path) -> none ----
; Unlike fexists, deleting a path that doesn't exist IS a runtime
; error - fdelete is an action the script expects to have an effect,
; so silently no-op'ing on a bad path would hide a bug (same "error,
; not silent" philosophy as everywhere else in this language). Uses
; fs_delete_tree, so deleting a folder path removes its contents too.
party_bi_fdelete:
    cmp r14, 1
    je .bfd_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bfd_argc_ok:
    lea rdi, [party_scratch1]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .bfd_out
    cmp byte [party_scratch1], PV_STR
    jne .bfd_err_type
    mov rsi, [party_scratch1+16]
    mov rcx, [party_scratch1+24]
    call party_copy_str_to_cpath
    cmp al, 1
    jne .bfd_out
    mov rax, [cur_dir]
    lea rsi, [party_fh_path_buf]
    lea rdi, [leaf1_buf]
    call fs_resolve_path
    cmp rax, -1
    je .bfd_err_notfound
    mov r11, rax
    lea rsi, [leaf1_buf]
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .bfd_err_notfound
    call fs_delete_tree
    call maybe_auto_sync
    lea rdi, [party_scratch]
    call party_val_set_none
    lea rsi, [party_scratch]
    call party_push_val
    jmp .bfd_out
.bfd_err_type:
    lea rsi, [msg_party_fexists_type]
    call party_set_err
    jmp .bfd_out
.bfd_err_notfound:
    lea rsi, [msg_party_fdelete_notfound]
    call party_set_err
.bfd_out:
    ret

; ============================================================
;  IN-LANGUAGE ARRAYS (Phase 4)
;
; Surface (PARTY_SPEC.md section 10): builtin functions, the same
; function-call-shaped "cannot be shadowed by a user func" mechanism
; Phase 3's file API uses - no new syntax, no TOK_LBRACKET/RBRACKET,
; no postfix-indexing parser work. This was a deliberate scope call
; (see phases.txt for the tradeoff): `a[i]` / `a[i] = x` / `[1,2,3]`
; literal syntax is real parser work (a new expression production,
; and a new assignment-target grammar alongside the existing
; ident-only `.pes_assign`) that a later phase can add on top of this
; one without touching the underlying storage below.
;
;     vars a = arr_new(3)     ; new array, 3 elements, each int 0
;     arr_set(a, 0, "hi")     ; statement only, like fwrite
;     display arr_get(a, 0)  ; "hi"
;     display arr_len(a)     ; 3
;     arr_free(a)             ; releases the slot
;
; Storage: a fixed pool of PARTY_ARR_MAX array "slots", each holding
; up to PARTY_ARR_CAP elements (ordinary 32-byte Party values, so an
; array can hold any type, including nested arrays - nothing in the
; value model prevents it, it just wasn't a design goal this phase).
; A PV_ARRAY value's [+8] field is the slot index - the same
; handle-into-a-fixed-table shape PARTY_FH_* already uses for file
; handles - so copying a PV_ARRAY value (assignment, passing it as a
; function argument, returning it) copies the handle only: arrays
; are reference types, every alias sees the same underlying storage.
; This was the OTHER locked-in scope decision (avoids needing a deep
; -copy pass through party_val_copy, which stays a flat 32-byte copy
; for every value type, arrays included).
;
; PARTY_ARR_MAX=4 / PARTY_ARR_CAP=16 are deliberately small - see the
; sizing note by the equ's below. No arr_grow/append: an array's size
; is fixed at arr_new and never changes, matching "fixed-size" from
; the two options phases.txt raised as the very first open design
; question (growable was the other option; not done here).
; ============================================================

PARTY_ARR_MAX equ 4     ; concurrently-alive arrays. Kept deliberately
                         ; tiny: this table gets copied into EVERY
                         ; party_ctx_table save/restore (background
                         ; processes), which is itself replicated
                         ; MAX_PROCESSES times in kernel.asm's
                         ; proc_bg_ctx - and kernel.asm already trimmed
                         ; MAX_PROCESSES from 4 to 2 "to fit the
                         ; kernel's BSS under 0xA0000" (kernel.asm
                         ; ~18343). A bigger array table here directly
                         ; eats into that same tight budget. 4 arrays x
                         ; 16 elements was picked to keep the total
                         ; addition small (see party_arr_data below);
                         ; raise it only after confirming real
                         ; link-time BSS headroom in the full dev tree
                         ; ("nasm party.asm standalone" only checks
                         ; syntax, not final image size) - not done
                         ; this session, no boot/link environment here.
PARTY_ARR_CAP equ 16    ; elements per array

; party_arr_alloc: finds a free array slot. Out: rax = slot index, or
; -1 if the table is full (msg_party_arr_full via party_set_err).
; Clobbers rax, rcx. Mirrors party_fh_alloc exactly.
party_arr_alloc:
    xor rcx, rcx
.paa_loop:
    cmp rcx, PARTY_ARR_MAX
    jae .paa_full
    cmp byte [party_arr_used+rcx], 0
    je .paa_found
    inc rcx
    jmp .paa_loop
.paa_found:
    mov byte [party_arr_used+rcx], 1
    mov rax, rcx
    ret
.paa_full:
    lea rsi, [msg_party_arr_full]
    call party_set_err
    mov rax, -1
    ret

; party_arr_check: rax = handle value (a PV_ARRAY value's [+8] field).
; Validates it's in range and currently allocated.
; Out: on success, rbx = pointer to the array's element-0 slot inside
; party_arr_data, rcx = handle/slot index, al = 1. On failure, sets
; party_exec_ok = 0 via party_set_err (msg_party_arr_invalid) and
; al = 0. Clobbers rax, rbx, rcx, rdx, rsi.
party_arr_check:
    cmp rax, 0
    jl .pac_bad
    cmp rax, PARTY_ARR_MAX
    jae .pac_bad
    mov rcx, rax
    cmp byte [party_arr_used+rcx], 0
    je .pac_bad
    mov rbx, rcx
    imul rbx, PARTY_ARR_CAP*32
    lea rdx, [party_arr_data]
    add rbx, rdx
    mov al, 1
    ret
.pac_bad:
    lea rsi, [msg_party_arr_invalid]
    call party_set_err
    xor al, al
    ret

; ---- arr_new(n) -> array; n elements, each initialized to int 0 ----
party_bi_arr_new:
    cmp r14, 1
    je .ban_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.ban_argc_ok:
    lea rdi, [party_scratch1]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .ban_out
    cmp byte [party_scratch1], PV_INT
    jne .ban_err_type
    mov rax, [party_scratch1+8]
    cmp rax, 0
    jl .ban_err_range
    cmp rax, PARTY_ARR_CAP
    ja .ban_err_range
    mov r12, rax                   ; requested count
    call party_arr_alloc
    cmp rax, -1
    je .ban_out                    ; party_arr_alloc already set the error
    mov rcx, rax                   ; slot index
    mov [party_arr_count+rcx*8], r12
    mov rbx, rcx
    imul rbx, PARTY_ARR_CAP*32
    lea rdx, [party_arr_data]
    add rbx, rdx                   ; rbx = element-0 slot
    xor r8, r8
.ban_zero_loop:
    cmp r8, r12
    jae .ban_zero_done
    lea rdi, [rbx]
    xor rax, rax
    call party_val_set_int
    add rbx, 32
    inc r8
    jmp .ban_zero_loop
.ban_zero_done:
    lea rdi, [party_scratch]
    mov byte [rdi], PV_ARRAY
    mov qword [rdi+8], rcx
    mov qword [rdi+16], 0
    mov qword [rdi+24], 0
    lea rsi, [party_scratch]
    call party_push_val
    jmp .ban_out
.ban_err_type:
    lea rsi, [msg_party_arr_new_args]
    call party_set_err
    jmp .ban_out
.ban_err_range:
    lea rsi, [msg_party_arr_new_range]
    call party_set_err
.ban_out:
    ret

; ---- arr_len(a) -> int ----
party_bi_arr_len:
    cmp r14, 1
    je .bal_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bal_argc_ok:
    lea rdi, [party_scratch1]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .bal_out
    cmp byte [party_scratch1], PV_ARRAY
    jne .bal_err_type
    mov rax, [party_scratch1+8]
    call party_arr_check
    cmp al, 1
    jne .bal_out
    mov rax, [party_arr_count+rcx*8]
    lea rdi, [party_scratch]
    call party_val_set_int
    lea rsi, [party_scratch]
    call party_push_val
    jmp .bal_out
.bal_err_type:
    lea rsi, [msg_party_arr_argtype]
    call party_set_err
.bal_out:
    ret

; ---- arr_get(a, i) -> value (a copy of the element - any type) ----
party_bi_arr_get:
    cmp r14, 2
    je .bag_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bag_argc_ok:
    lea rdi, [party_scratch2]      ; index (on top)
    call party_pop_val
    lea rdi, [party_scratch1]      ; array
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .bag_out
    cmp byte [party_scratch1], PV_ARRAY
    jne .bag_err_argtype
    cmp byte [party_scratch2], PV_INT
    jne .bag_err_idxtype
    mov rax, [party_scratch1+8]
    call party_arr_check
    cmp al, 1
    jne .bag_out
    mov rdx, rcx                   ; slot index (party_arr_check clobbers rcx below)
    mov rax, [party_scratch2+8]    ; requested index
    cmp rax, 0
    jl .bag_err_bounds
    cmp rax, [party_arr_count+rdx*8]
    jae .bag_err_bounds
    imul rax, 32
    add rbx, rax                   ; rbx = element pointer (base from party_arr_check)
    lea rdi, [party_scratch]
    mov rsi, rbx
    call party_val_copy
    lea rsi, [party_scratch]
    call party_push_val
    jmp .bag_out
.bag_err_argtype:
    lea rsi, [msg_party_arr_argtype]
    call party_set_err
    jmp .bag_out
.bag_err_idxtype:
    lea rsi, [msg_party_arr_index_type]
    call party_set_err
    jmp .bag_out
.bag_err_bounds:
    lea rsi, [msg_party_arr_bounds]
    call party_set_err
.bag_out:
    ret

; ---- arr_set(a, i, v) -> none (statement only, like fwrite) ----
party_bi_arr_set:
    cmp r14, 3
    je .bas_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bas_argc_ok:
    lea rdi, [party_scratch3]      ; value (on top)
    call party_pop_val
    lea rdi, [party_scratch2]      ; index
    call party_pop_val
    lea rdi, [party_scratch1]      ; array
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .bas_out
    cmp byte [party_scratch1], PV_ARRAY
    jne .bas_err_argtype
    cmp byte [party_scratch2], PV_INT
    jne .bas_err_idxtype
    mov rax, [party_scratch1+8]
    call party_arr_check
    cmp al, 1
    jne .bas_out
    mov rdx, rcx                   ; slot index
    mov rax, [party_scratch2+8]    ; requested index
    cmp rax, 0
    jl .bas_err_bounds
    cmp rax, [party_arr_count+rdx*8]
    jae .bas_err_bounds
    imul rax, 32
    add rbx, rax                   ; rbx = element pointer
    mov rdi, rbx
    lea rsi, [party_scratch3]
    call party_val_copy
    lea rdi, [party_scratch]
    call party_val_set_none
    lea rsi, [party_scratch]
    call party_push_val
    jmp .bas_out
.bas_err_argtype:
    lea rsi, [msg_party_arr_argtype]
    call party_set_err
    jmp .bas_out
.bas_err_idxtype:
    lea rsi, [msg_party_arr_index_type]
    call party_set_err
    jmp .bas_out
.bas_err_bounds:
    lea rsi, [msg_party_arr_bounds]
    call party_set_err
.bas_out:
    ret

; ---- arr_free(a) -> none; releases the slot back to the pool ----
; Using the handle again afterwards (arr_len/arr_get/arr_set/
; arr_free on it) is a runtime error, same as an already-fclose'd
; file handle - party_arr_check has no way to tell "stale" from
; "never valid" and doesn't need to.
party_bi_arr_free:
    cmp r14, 1
    je .baf_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.baf_argc_ok:
    lea rdi, [party_scratch1]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .baf_out
    cmp byte [party_scratch1], PV_ARRAY
    jne .baf_err_type
    mov rax, [party_scratch1+8]
    call party_arr_check
    cmp al, 1
    jne .baf_out
    mov byte [party_arr_used+rcx], 0
    lea rdi, [party_scratch]
    call party_val_set_none
    lea rsi, [party_scratch]
    call party_push_val
    jmp .baf_out
.baf_err_type:
    lea rsi, [msg_party_arr_argtype]
    call party_set_err
.baf_out:
    ret

; ============================================================
;  RANDOM + TIME BUILTINS  (Phase 5)
; ============================================================
; random: a xorshift64* generator (state = party_rand_state) lazily
; seeded on first use from RDTSC mixed with the RTC clock, so two
; runs started a second or more apart get different sequences without
; the script having to call randseed() itself. randseed() reseeds it
; explicitly (e.g. for a repeatable test run).
;
; time: there's no real epoch on this hardware, only the CMOS RTC's
; wall-clock fields (see rtc_update/rtc_sec..rtc_century, kernel.asm
; ~15322+). time() converts those into a seconds count from a fixed
; reference point (2000-01-01 00:00:00) using ordinary calendar math
; - it's not a true Unix timestamp, but it's monotonic across a run
; and good enough for elapsed-time measurements and for seeding
; things. datestr()/timestr() just wrap the kernel's existing
; format_date/format_time helpers (the same ones cmd_date/cmd_time
; use) as Party-callable strings.

party_rand_state:   dq 0
party_rand_seeded:  db 0
ALIGN 8
party_rand_k1:      dq 0x2545F4914F6CDD1D   ; xorshift64* multiplier

; party_rand_next: out = rax = next 64-bit pseudo-random value.
; Lazily seeds party_rand_state on first call. Clobbers rax, rcx, rdx.
party_rand_next:
    cmp byte [party_rand_seeded], 0
    jne .prn_seeded
    rdtsc                          ; edx:eax = timestamp counter
    shl rdx, 32
    or rax, rdx                    ; rax = 64-bit tsc reading
    push rax                       ; stash it - rtc_sec_now below clobbers rax
    call rtc_sec_now                ; eax = current RTC seconds (0..59)
    pop rdx                        ; rdx = the saved tsc reading
    xor rax, rdx                   ; fold the RTC second into the tsc bits
    or rax, 1                      ; xorshift64 can't recover from an all-zero state
    mov [party_rand_state], rax
    mov byte [party_rand_seeded], 1
.prn_seeded:
    mov rax, [party_rand_state]
    mov rcx, rax
    shr rcx, 12
    xor rax, rcx
    mov rcx, rax
    shl rcx, 25
    xor rax, rcx
    mov rcx, rax
    shr rcx, 7
    xor rax, rcx
    mov [party_rand_state], rax
    imul rax, [party_rand_k1]      ; scramble the output (xorshift64*)
    ret

; ---- rand() -> float in [0, 1) ----
party_bi_rand:
    cmp r14, 0
    je .brd_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.brd_argc_ok:
    call party_rand_next
    shr rax, 32                    ; keep the top 32 bits: a clean 0..2^32-1
    mov [party_ftmp_i], rax
    fild qword [party_ftmp_i]
    fdiv qword [fp_2p32]
    lea rdi, [party_scratch]
    call party_val_set_float
    lea rsi, [party_scratch]
    call party_push_val
    ret

; ---- randint(lo, hi) -> int, inclusive on both ends ----
party_bi_randint:
    cmp r14, 2
    je .bri_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bri_argc_ok:
    lea rdi, [party_scratch2]      ; hi (on top)
    call party_pop_val
    lea rdi, [party_scratch1]      ; lo
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .bri_out
    cmp byte [party_scratch1], PV_INT
    jne .bri_err_type
    cmp byte [party_scratch2], PV_INT
    jne .bri_err_type
    mov rax, [party_scratch1+8]    ; lo
    mov rcx, [party_scratch2+8]    ; hi
    cmp rcx, rax
    jl .bri_err_range
    sub rcx, rax                   ; rcx = span = hi - lo
    inc rcx                        ; rcx = count = span + 1
    ; stash lo/count in party_scratch3 (plain scratch, not a tagged PV
    ; value here) since party_rand_next clobbers rax/rcx/rdx
    mov [party_scratch3], rax      ; [0]  = lo
    mov [party_scratch3+8], rcx    ; [8]  = count
    call party_rand_next           ; rax = 64-bit draw
    xor rdx, rdx
    div qword [party_scratch3+8]   ; rdx = draw mod count
    add rdx, [party_scratch3]      ; + lo
    mov rax, rdx
    lea rdi, [party_scratch]
    call party_val_set_int
    lea rsi, [party_scratch]
    call party_push_val
    jmp .bri_out
.bri_err_type:
    lea rsi, [msg_party_randint_argtype]
    call party_set_err
    jmp .bri_out
.bri_err_range:
    lea rsi, [msg_party_randint_range]
    call party_set_err
.bri_out:
    ret

; ---- randseed(n) -> none; reseeds the generator with n ----
party_bi_randseed:
    cmp r14, 1
    je .brs_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.brs_argc_ok:
    lea rdi, [party_scratch1]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .brs_out
    cmp byte [party_scratch1], PV_INT
    jne .brs_err_type
    mov rax, [party_scratch1+8]
    or rax, 1                      ; xorshift64 can't recover from an all-zero state
    mov [party_rand_state], rax
    mov byte [party_rand_seeded], 1
    lea rdi, [party_scratch]
    call party_val_set_none
    lea rsi, [party_scratch]
    call party_push_val
    jmp .brs_out
.brs_err_type:
    lea rsi, [msg_party_arg_int]
    call party_set_err
.brs_out:
    ret

; ---- time() -> int, seconds since 2000-01-01 00:00:00 (RTC-derived,
; not a real Unix epoch - see the section header comment above) ----
party_days_before_month: dd 0,31,59,90,120,151,181,212,243,273,304,334
party_bi_time:
    cmp r14, 0
    je .bti_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bti_argc_ok:
    call rtc_update
    movzx rax, byte [rtc_century]
    cmp al, 20
    je .bti_cent_ok
    cmp al, 21
    je .bti_cent_ok
    mov al, 20
.bti_cent_ok:
    imul rax, 100
    movzx rcx, byte [rtc_year]
    add rax, rcx
    sub rax, 2000                  ; rax = years since 2000
    mov r8, rax                    ; r8 = years
    mov r9, rax
    add r9, 3
    shr r9, 2                      ; r9 = leap days before this year (see header comment's derivation)
    xor r10, r10
    mov rax, r8
    and rax, 3
    setz r10b                      ; r10 = 1 if this year is a leap year, else 0
    movzx rax, byte [rtc_month]    ; 1..12
    dec rax
    mov ecx, [party_days_before_month+rax*4]
    movzx rax, byte [rtc_day]      ; 1..31
    dec rax
    add rax, rcx                   ; + days_before_month[month-1]
    add rax, r9                    ; + leap days before this year
    imul r11, r8, 365
    add rax, r11                   ; + years*365
    ; days_before_month[] above is the non-leap table; a leap year's Feb 29
    ; only affects months from March onward, so only add the extra day once
    ; we're past February - Jan/Feb of a leap year need no adjustment.
    cmp byte [rtc_month], 2
    jbe .bti_no_leap_adj
    test r10, r10
    jz .bti_no_leap_adj
    inc rax
.bti_no_leap_adj:
    ; rax = total whole days since 2000-01-01
    imul rax, 86400
    movzx rcx, byte [rtc_hour]
    imul rcx, 3600
    add rax, rcx
    movzx rcx, byte [rtc_min]
    imul rcx, 60
    add rax, rcx
    movzx rcx, byte [rtc_sec]
    add rax, rcx
    lea rdi, [party_scratch]
    call party_val_set_int
    lea rsi, [party_scratch]
    call party_push_val
    ret

; ---- datestr() -> string "YYYY-MM-DD" ----
party_bi_datestr:
    cmp r14, 0
    je .bds_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bds_argc_ok:
    lea rdi, [party_time_str_buf1]
    call format_date
    lea rsi, [party_time_str_buf1]
    call str_len
    mov rcx, rax
    lea rdi, [party_scratch]
    lea rsi, [party_time_str_buf1]
    call party_val_set_str
    lea rsi, [party_scratch]
    call party_push_val
    ret

; ---- timestr() -> string "HH:MM:SS" ----
party_bi_timestr:
    cmp r14, 0
    je .bts_argc_ok
    lea rsi, [msg_party_arg_count]
    call party_set_err
    ret
.bts_argc_ok:
    lea rdi, [party_time_str_buf2]
    call format_time
    lea rsi, [party_time_str_buf2]
    call str_len
    mov rcx, rax
    lea rdi, [party_scratch]
    lea rsi, [party_time_str_buf2]
    call party_val_set_str
    lea rsi, [party_scratch]
    call party_push_val
    ret

ALIGN 8
fp_2p32:              dq 4294967296.0
party_time_str_buf1:  times 16 db 0     ; "YYYY-MM-DD", separate from buf2 so
party_time_str_buf2:  times 16 db 0     ; datestr()+timestr() in one expression don't alias

msg_party_randint_argtype: db 'randint requires two ints', 0
msg_party_randint_range:   db 'randint: lo must be <= hi', 0
msg_party_arg_int:         db 'expected an int', 0

; ============================================================
;  BINARY OPERATORS
; ============================================================
; Each pops the two top values (rhs first, then lhs) and pushes the
; result. On failure they record an error and push nothing.

; ---- arithmetic (PLUS/MINUS/STAR/SLASH): rax = op token ----
party_op_bin:
    cmp byte [party_exec_ok], 0
    je .out
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rax
    lea rdi, [party_scratch2]
    call party_pop_val
    lea rdi, [party_scratch1]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .out2
    mov al, [party_scratch1]
    cmp al, PV_BOOL
    je .bop_l1_ok
    cmp al, PV_INT
    je .bop_l1_ok
    cmp al, PV_FLOAT
    je .bop_l1_ok
    jmp .bop_err_type
.bop_l1_ok:
    mov al, [party_scratch2]
    cmp al, PV_BOOL
    je .bop_l2_ok
    cmp al, PV_INT
    je .bop_l2_ok
    cmp al, PV_FLOAT
    je .bop_l2_ok
    jmp .bop_err_type
.bop_l2_ok:
    xor r14, r14                   ; r14 = 1 -> float mode
    cmp byte [party_scratch1], PV_FLOAT
    je .bop_check_pct_float
    cmp byte [party_scratch2], PV_FLOAT
    jne .bop_do_int
.bop_check_pct_float:
    ; '%' is int-only: a float operand on either side is an error,
    ; caught here before falling into the shared float path.
    cmp r12, TOK_PERCENT
    je .bop_err_type
    mov r14, 1
    jmp .bop_do_float
.bop_do_int:
    mov rax, [party_scratch1+8]
    mov rbx, [party_scratch2+8]
    cmp r12, TOK_PLUS
    je .bop_iadd
    cmp r12, TOK_MINUS
    je .bop_isub
    cmp r12, TOK_STAR
    je .bop_imul
    cmp rbx, 0
    je .bop_err_div0
    cqo
    idiv rbx
    cmp r12, TOK_PERCENT
    je .bop_imod
    jmp .bop_istore
.bop_imod:
    mov rax, rdx                   ; idiv leaves the remainder in rdx
    jmp .bop_istore
.bop_iadd:
    add rax, rbx
    jmp .bop_istore
.bop_isub:
    sub rax, rbx
    jmp .bop_istore
.bop_imul:
    imul rax, rbx
.bop_istore:
    mov [party_scratch1+8], rax
    mov byte [party_scratch1], PV_INT
    jmp .bop_push
.bop_do_float:
    mov rax, [party_scratch1+8]
    mov [party_ftmp_i], rax
    cmp byte [party_scratch1], PV_FLOAT
    je .bop_fld_l
    fild qword [party_ftmp_i]
    jmp .bop_fld_r
.bop_fld_l:
    fld qword [party_ftmp_i]
.bop_fld_r:
    mov rax, [party_scratch2+8]
    mov [party_ftmp_i], rax
    cmp byte [party_scratch2], PV_FLOAT
    je .bop_fld_r2
    fild qword [party_ftmp_i]
    jmp .bop_fop
.bop_fld_r2:
    fld qword [party_ftmp_i]
.bop_fop:
    ; st0 = rhs, st1 = lhs
    cmp r12, TOK_PLUS
    je .bop_fadd
    cmp r12, TOK_MINUS
    je .bop_fsub
    cmp r12, TOK_STAR
    je .bop_fmul
    fdivp st1, st0
    jmp .bop_fstore
.bop_fadd:
    faddp st1, st0
    jmp .bop_fstore
.bop_fsub:
    fsubp st1, st0
    jmp .bop_fstore
.bop_fmul:
    fmulp st1, st0
.bop_fstore:
    fstp qword [party_scratch1+8]
    mov byte [party_scratch1], PV_FLOAT
.bop_push:
    lea rsi, [party_scratch1]
    call party_push_val
    jmp .out2
.bop_err_type:
    lea rsi, [msg_party_bad_arith]
    call party_set_err
    jmp .out2
.bop_err_div0:
    lea rsi, [msg_party_div0]
    call party_set_err
.out2:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.out:
    ret

; ---- equality (==): works on any matching type; mismatched types
;      are not equal (never an error) ----
party_op_eq:
    cmp byte [party_exec_ok], 0
    je .out
    push rbx
    push rcx
    push rsi
    push rdi
    lea rdi, [party_scratch2]
    call party_pop_val
    lea rdi, [party_scratch1]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .out2
    mov al, [party_scratch1]
    mov ah, [party_scratch2]
    cmp al, PV_STR
    je .eq_str
    cmp al, PV_BOOL
    je .eq_bool
    cmp al, PV_FLOAT
    je .eq_float
    cmp al, PV_INT
    je .eq_int
    jmp .eq_false
.eq_int:
    cmp ah, PV_FLOAT
    je .eq_float_cmp
    cmp ah, PV_INT
    je .eq_int_cmp
    cmp ah, PV_BOOL
    je .eq_int_cmp
    jmp .eq_false
.eq_bool:
    cmp ah, PV_BOOL
    jne .eq_false
    mov rax, [party_scratch1+8]
    cmp rax, [party_scratch2+8]
    je .eq_true
    jmp .eq_false
.eq_float:
    cmp ah, PV_FLOAT
    je .eq_float_cmp
    cmp ah, PV_INT
    je .eq_float_cmp
    cmp ah, PV_BOOL
    je .eq_float_cmp
    jmp .eq_false
.eq_str:
    cmp ah, PV_STR
    jne .eq_false
    mov rcx, [party_scratch1+24]
    cmp rcx, [party_scratch2+24]
    jne .eq_false
    mov rsi, [party_scratch1+16]
    mov rdi, [party_scratch2+16]
.eq_str_loop:
    cmp rcx, 0
    je .eq_true
    mov al, [rsi]
    mov ah, [rdi]
    cmp al, ah
    jne .eq_false
    inc rsi
    inc rdi
    dec rcx
    jmp .eq_str_loop
.eq_int_cmp:
    mov rax, [party_scratch1+8]
    cmp rax, [party_scratch2+8]
    je .eq_true
    jmp .eq_false
.eq_float_cmp:
    mov rax, [party_scratch1+8]
    mov [party_ftmp_i], rax
    cmp byte [party_scratch1], PV_FLOAT
    je .eq_fld_l1
    fild qword [party_ftmp_i]
    jmp .eq_fld_r
.eq_fld_l1:
    fld qword [party_ftmp_i]
.eq_fld_r:
    mov rax, [party_scratch2+8]
    mov [party_ftmp_i], rax
    cmp byte [party_scratch2], PV_FLOAT
    je .eq_fld_r1
    fild qword [party_ftmp_i]
    jmp .eq_fcmp
.eq_fld_r1:
    fld qword [party_ftmp_i]
.eq_fcmp:
    ; st0 = rhs, st1 = lhs
    fcomip st0, st1
    fstp st0
    jz .eq_true
    jmp .eq_false
.eq_true:
    lea rdi, [party_scratch1]
    call party_val_set_bool_true
    jmp .eq_push
.eq_false:
    lea rdi, [party_scratch1]
    call party_val_set_bool_false
.eq_push:
    lea rsi, [party_scratch1]
    call party_push_val
.out2:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
.out:
    ret

; ---- not-equal: run == then flip the top bool ----
party_op_neq:
    cmp byte [party_exec_ok], 0
    je .out
    push rbx
    call party_op_eq
    cmp byte [party_exec_ok], 1
    jne .out2
    mov rax, [party_vsp]
    lea rbx, [party_vstack]
    imul rdx, rax, 32
    sub rdx, 32
    add rbx, rdx
    cmp qword [rbx+8], 0
    jne .pon_false
    mov qword [rbx+8], 1
    jmp .out2
.pon_false:
    mov qword [rbx+8], 0
.out2:
    pop rbx
.out:
    ret

; ---- relational (< <= > >=): rax = op token; numbers only ----
party_op_rel:
    cmp byte [party_exec_ok], 0
    je .out
    push rbx
    push r12
    push r13
    push r14
    mov r12, rax
    lea rdi, [party_scratch2]
    call party_pop_val
    lea rdi, [party_scratch1]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .out2
    mov al, [party_scratch1]
    cmp al, PV_BOOL
    je .rl_lhs_ok
    cmp al, PV_INT
    je .rl_lhs_ok
    cmp al, PV_FLOAT
    je .rl_lhs_ok
    jmp .rl_err_type
.rl_lhs_ok:
    mov al, [party_scratch2]
    cmp al, PV_BOOL
    je .rl_rhs_ok
    cmp al, PV_INT
    je .rl_rhs_ok
    cmp al, PV_FLOAT
    je .rl_rhs_ok
    jmp .rl_err_type
.rl_rhs_ok:
    mov rax, [party_scratch1+8]
    mov [party_ftmp_i], rax
    cmp byte [party_scratch1], PV_FLOAT
    je .rl_fld_l1
    fild qword [party_ftmp_i]
    jmp .rl_load_rhs
.rl_fld_l1:
    fld qword [party_ftmp_i]
.rl_load_rhs:
    mov rax, [party_scratch2+8]
    mov [party_ftmp_i], rax
    cmp byte [party_scratch2], PV_FLOAT
    je .rl_fld_r1
    fild qword [party_ftmp_i]
    jmp .rl_fcmp
.rl_fld_r1:
    fld qword [party_ftmp_i]
.rl_fcmp:
    ; st0 = rhs, st1 = lhs; CF=1 -> rhs<lhs, ZF=1 -> rhs==lhs
    fcomip st0, st1
    fstp st0
    setc r9b                   ; r9b = (rhs < lhs)
    setz r10b                  ; r10b = (rhs == lhs)
    cmp r12, TOK_LT
    je .rl_lt
    cmp r12, TOK_LTE
    je .rl_lte
    cmp r12, TOK_GT
    je .rl_gt
    ; fall-through: GTE (lhs >= rhs)
    cmp r9b, 1
    je .rl_true
    cmp r10b, 1
    je .rl_true
    jmp .rl_false
.rl_lt:
    cmp r9b, 1
    je .rl_false
    cmp r10b, 1
    je .rl_false
    jmp .rl_true
.rl_lte:
    cmp r9b, 1
    je .rl_false
    jmp .rl_true
.rl_gt:
    cmp r9b, 1
    je .rl_true
    jmp .rl_false
.rl_true:
    lea rdi, [party_scratch1]
    call party_val_set_bool_true
    jmp .rl_push
.rl_false:
    lea rdi, [party_scratch1]
    call party_val_set_bool_false
.rl_push:
    lea rsi, [party_scratch1]
    call party_push_val
    jmp .out2
.rl_err_type:
    lea rsi, [msg_party_cmp_num]
    call party_set_err
.out2:
    pop r14
    pop r13
    pop r12
    pop rbx
.out:
    ret

; ============================================================
;  VARIABLES
; ============================================================
; Globals live in party_var_* (fixed MAXVARS slots). A function's
; locals live in the party_loc_* pool as a contiguous run from the
; frame's locbase to the pool end; a call frame remembers where its
; run starts so it can be freed on return. Lookup searches the
; current frame's run first, then globals.

; party_scope_has_name: rsi = name -> al=1 if the name already
; exists in the CURRENT scope (globals at top level, current frame's
; locals inside a function). Preserves rsi.
party_scope_has_name:
    push rsi
    push rdi
    push rcx
    cmp qword [party_call_depth], 0
    jne .shn_locals
    xor rcx, rcx
.shn_g_loop:
    cmp rcx, MAXVARS
    jae .shn_no
    cmp byte [party_var_used+rcx], 0
    je .shn_g_next
    lea rdi, [party_var_name]
    imul rdx, rcx, PARTY_IDENT_MAX
    add rdi, rdx
    call str_eq
    cmp al, 1
    je .shn_yes
.shn_g_next:
    inc rcx
    jmp .shn_g_loop
.shn_locals:
    mov rax, [party_call_depth]
    dec rax
    mov ecx, [party_frame_locbase + rax*4]
    mov rbx, [party_loc_count]
    dec rbx
.shn_l_loop:
    cmp rbx, rcx
    jl .shn_no
    cmp byte [party_loc_used+rbx], 0
    je .shn_l_next
    lea rdi, [party_loc_name]
    imul rdx, rbx, PARTY_IDENT_MAX
    add rdi, rdx
    call str_eq
    cmp al, 1
    je .shn_yes
.shn_l_next:
    dec rbx
    jmp .shn_l_loop
.shn_yes:
    mov al, 1
    pop rcx
    pop rdi
    pop rsi
    ret
.shn_no:
    xor al, al
    pop rcx
    pop rdi
    pop rsi
    ret

; party_var_get_ptr: rsi = name -> rbx = pointer to the 32-byte
; value slot, al=1 if found, else al=0. Preserves rsi.
party_var_get_ptr:
    push rsi
    push rdi
    push rcx
    mov rax, [party_call_depth]
    cmp rax, 0
    je .vgg_globals
    dec rax
    mov ecx, [party_frame_locbase + rax*4]
    mov rbx, [party_loc_count]
    dec rbx
.vgl_loop:
    cmp rbx, rcx
    jl .vgg_globals
    cmp byte [party_loc_used+rbx], 0
    je .vgl_next
    lea rdi, [party_loc_name]
    imul rdx, rbx, PARTY_IDENT_MAX
    add rdi, rdx
    call str_eq
    cmp al, 1
    je .vgl_found
.vgl_next:
    dec rbx
    jmp .vgl_loop
.vgl_found:
    imul rdx, rbx, 32
    lea rbx, [party_loc_val]
    add rbx, rdx
    mov al, 1
    pop rcx
    pop rdi
    pop rsi
    ret
.vgg_globals:
    xor rcx, rcx
.vgg_loop:
    cmp rcx, MAXVARS
    jae .vgg_notfound
    cmp byte [party_var_used+rcx], 0
    je .vgg_next
    lea rdi, [party_var_name]
    imul rdx, rcx, PARTY_IDENT_MAX
    add rdi, rdx
    call str_eq
    cmp al, 1
    je .vgg_found
.vgg_next:
    inc rcx
    jmp .vgg_loop
.vgg_found:
    lea rbx, [party_var_val]
    imul rdx, rcx, 32
    add rbx, rdx
    mov al, 1
    pop rcx
    pop rdi
    pop rsi
    ret
.vgg_notfound:
    xor al, al
    pop rcx
    pop rdi
    pop rsi
    ret

; party_var_declare: rsi = name; pops the value from the value stack
; into a new variable in the current scope (global at top level,
; local inside a function). Redeclaring a name in the same scope is
; an error. Preserves rsi.
party_var_declare:
    push rsi
    push rdi
    push rcx
    push rsi
    call party_scope_has_name
    pop rsi
    cmp al, 1
    je .pvd_err_decl
    cmp qword [party_call_depth], 0
    jne .pvd_local
    xor rcx, rcx
.pvd_g_loop:
    cmp rcx, MAXVARS
    jae .pvd_err_full
    cmp byte [party_var_used+rcx], 0
    je .pvd_g_found
    inc rcx
    jmp .pvd_g_loop
.pvd_g_found:
    mov byte [party_var_used+rcx], 1
    lea rdi, [party_var_name]
    imul rax, rcx, PARTY_IDENT_MAX
    add rdi, rax
    call str_copy
    lea rdi, [party_var_val]
    imul rax, rcx, 32
    add rdi, rax
    call party_pop_val
    jmp .pvd_out
.pvd_local:
    mov rax, [party_loc_count]
    cmp rax, MAXLOCALS
    jae .pvd_err_locfull
    mov rcx, rax
    mov byte [party_loc_used+rcx], 1
    lea rdi, [party_loc_name]
    imul rax, rcx, PARTY_IDENT_MAX
    add rdi, rax
    call str_copy
    lea rdi, [party_loc_val]
    imul rax, rcx, 32
    add rdi, rax
    call party_pop_val
    inc qword [party_loc_count]
    jmp .pvd_out
.pvd_err_decl:
    lea rsi, [msg_party_var_declared]
    call party_set_err
    jmp .pvd_out
.pvd_err_full:
    lea rsi, [msg_party_globals_full]
    call party_set_err
    jmp .pvd_out
.pvd_err_locfull:
    lea rsi, [msg_party_locals_full]
    call party_set_err
.pvd_out:
    pop rcx
    pop rdi
    pop rsi
    ret

; party_local_create: rsi = name, rdi = pointer to a 32-byte value;
; allocates a local (used for binding params). Preserves rsi, rdi.
party_local_create:
    push rcx
    push rsi
    push rdi
    mov rax, [party_loc_count]
    cmp rax, MAXLOCALS
    jae .plc_err
    mov rcx, rax
    mov byte [party_loc_used+rcx], 1
    lea rdi, [party_loc_name]
    imul rax, rcx, PARTY_IDENT_MAX
    add rdi, rax
    call str_copy
    mov rsi, [rsp]                 ; original value pointer (pushed last)
    lea rdi, [party_loc_val]
    imul rax, rcx, 32
    add rdi, rax
    call party_val_copy
    inc qword [party_loc_count]
    jmp .plc_out
.plc_err:
    lea rsi, [msg_party_locals_full]
    call party_set_err
.plc_out:
    pop rdi
    pop rsi
    pop rcx
    ret

; party_var_assign: rsi = name; pops the value from the value stack
; into the existing variable. Undeclared name is an error. Preserves
; rsi.
party_var_assign:
    push rdi
    call party_var_get_ptr
    cmp al, 1
    jne .pva_err
    mov rdi, rbx
    call party_pop_val
    jmp .pva_out
.pva_err:
    lea rsi, [msg_party_undef_var]
    call party_set_err
.pva_out:
    pop rdi
    ret

; ============================================================
;  FUNCTIONS
; ============================================================

; party_func_find: rsi = name -> r15 = func table index, or -1.
party_func_find:
    push rsi
    push rdi
    push rcx
    mov r15, -1
    xor rcx, rcx
.pff_loop:
    cmp rcx, [party_func_count]
    jae .pff_done
    lea rdi, [party_func_name]
    imul rdx, rcx, PARTY_IDENT_MAX
    add rdi, rdx
    call str_eq
    cmp al, 1
    je .pff_found
    inc rcx
    jmp .pff_loop
.pff_found:
    mov r15, rcx
.pff_done:
    pop rcx
    pop rdi
    pop rsi
    ret

; party_invoke_func: executes the function with index r15. The
; evaluated args are already on the value stack (first arg first).
; Binds params as locals, runs the body, frees the frame's locals,
; and pushes the return value (PV_NONE if the function fell off the
; end or returned bare). Clobbers rax, rbx, r8-r15.
party_invoke_func:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rax, [party_call_depth]
    cmp rax, MAXCALLS
    jae .pif_overflow
    mov [party_frame_ret_r13 + rax*4], r13d
    mov ecx, [party_loc_count]
    mov [party_frame_locbase + rax*4], ecx
    movzx edx, byte [party_func_nparams+r15]
    mov [party_frame_nparams + rax], dl
    mov byte [party_frame_returned + rax], 0
    inc qword [party_call_depth]
    movzx r12, byte [party_func_nparams+r15]
.pif_bind_loop:
    cmp r12, 0
    je .pif_bind_done
    dec r12
    lea rdi, [party_scratch]
    call party_pop_val
    cmp byte [party_exec_ok], 1
    jne .pif_abort
    lea rdx, [party_func_paramtok]
    imul rax, r15, 8
    add rdx, rax
    mov r13d, [rdx + r12*4]
    call party_copy_tok_text_cur
    lea rsi, [party_ident_buf]
    lea rdi, [party_scratch]
    call party_local_create
    cmp byte [party_exec_ok], 1
    jne .pif_abort
    jmp .pif_bind_loop
.pif_bind_done:
    mov r13d, [party_func_bodytok + r15*4]
    mov r14, TOK_RBRACE
    call party_exec_stmts
    mov rax, [party_call_depth]
    dec rax
    cmp byte [party_exec_ok], 0
    je .pif_abort2
    cmp byte [party_killed], 0
    jne .pif_abort2
    mov r13d, [party_frame_ret_r13 + rax*4]
    cmp byte [party_frame_returned + rax], 1
    je .pif_have_ret
    lea rdi, [party_scratch]
    call party_val_set_none
    jmp .pif_push_ret
.pif_have_ret:
    mov rdx, rax
    shl rdx, 5
    lea rsi, [party_frame_retval + rdx]
    lea rdi, [party_scratch]
    call party_val_copy
.pif_push_ret:
    mov byte [party_returning], 0
    mov ecx, [party_frame_locbase + rax*4]
    mov rax, rcx
.pif_free_loop:
    cmp rax, [party_loc_count]
    jae .pif_free_done
    mov byte [party_loc_used + rax], 0
    inc rax
    jmp .pif_free_loop
.pif_free_done:
    mov [party_loc_count], rcx
    dec qword [party_call_depth]
    lea rsi, [party_scratch]
    call party_push_val
    jmp .pif_out
.pif_overflow:
    lea rsi, [msg_party_call_stack]
    call party_set_err
    jmp .pif_out
.pif_abort:
    mov rax, [party_call_depth]
    dec rax
    mov ecx, [party_frame_locbase + rax*4]
    mov rdx, rcx
.pif_abort_free_loop:
    cmp rdx, [party_loc_count]
    jae .pif_abort_free_done
    mov byte [party_loc_used + rdx], 0
    inc rdx
    jmp .pif_abort_free_loop
.pif_abort_free_done:
    mov [party_loc_count], rcx
    dec qword [party_call_depth]
    jmp .pif_out
.pif_abort2:
    mov ecx, [party_frame_locbase + rax*4]
    mov rdx, rcx
.pif_free2_loop:
    cmp rdx, [party_loc_count]
    jae .pif_free2_done
    mov byte [party_loc_used + rdx], 0
    inc rdx
    jmp .pif_free2_loop
.pif_free2_done:
    mov [party_loc_count], rcx
    dec qword [party_call_depth]
.pif_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; party_tok_ptr: in r13=token index -> rbx = &party_tokens[r13]
party_tok_ptr:
    lea rbx, [party_tokens]
    mov rax, r13
    shl rax, 3
    add rbx, rax
    ret

; party_line_at: in eax=byte offset into fs_io_buf -> eax=1-based line
; number (counts newlines from the start of the buffer up to offset).
party_line_at:
    push rbx
    push rcx
    push rsi
    mov ecx, eax
    mov rsi, [party_src_base]
    mov ebx, 1
.pla_loop:
    cmp ecx, 0
    je .pla_done
    mov al, [rsi]
    cmp al, 10
    jne .pla_next
    inc ebx
.pla_next:
    inc rsi
    dec ecx
    jmp .pla_loop
.pla_done:
    mov eax, ebx
    pop rsi
    pop rcx
    pop rbx
    ret

; party_print_tok_text: in rbx=token ptr -> prints the token's source
; text (fs_io_buf[start .. start+length)), truncated to 63 bytes, no
; quotes added even for TOK_STR (caller decides framing).
party_print_tok_text:
    push rax
    push rcx
    push rsi
    push rdi
    movzx rcx, word [rbx+2]
    mov eax, [rbx+4]
    mov rsi, [party_src_base]
    add rsi, rax
    lea rdi, [party_text_buf]
    cmp rcx, 63
    jbe .ptt_len_ok
    mov rcx, 63
.ptt_len_ok:
    push rcx
.ptt_copy:
    cmp rcx, 0
    je .ptt_copy_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .ptt_copy
.ptt_copy_done:
    mov byte [rdi], 0
    pop rcx
    mov rsi, party_text_buf
    call print_string
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------
; party_emit: appends one token. In: r8=type, r9=start_offset,
; r10=length. Out: al=1 ok, al=0 table full (party_lex_ok untouched -
; caller decides how to react).
; ------------------------------------------------------------
party_emit:
    push rbx
    push rdi
    movzx rbx, word [party_token_count]
    cmp rbx, PARTY_MAX_TOKENS
    jae .pe_full
    lea rdi, [party_tokens]
    imul rax, rbx, 8
    add rdi, rax
    mov [rdi], r8b                ; type
    mov byte [rdi+1], 0           ; reserved
    mov [rdi+2], r10w             ; length
    mov [rdi+4], r9d              ; start offset
    inc word [party_token_count]
    mov al, 1
    pop rdi
    pop rbx
    ret
.pe_full:
    xor al, al
    pop rdi
    pop rbx
    ret

; ------------------------------------------------------------
; party_dump_tokens: DEBUG ONLY - prints "TYPE_NAME [text]" per line.
; Will be deleted once the parser consumes the token stream directly.
; ------------------------------------------------------------
party_dump_tokens:
    push rbx
    push r12
    push r13
    movzx r12, word [party_token_count]
    xor r13, r13
.pd_loop:
    cmp r13, r12
    jae .pd_done
    lea rbx, [party_tokens]
    imul rax, r13, 8
    add rbx, rax

    movzx rax, byte [rbx]          ; type
    cmp rax, TOK_COUNT_KNOWN
    jae .pd_unknown
    lea rdi, [party_tok_names]
    mov rsi, [rdi + rax*8]
    jmp .pd_have_name
.pd_unknown:
    mov rsi, str_tok_error
.pd_have_name:
    call print_string

    ; for tokens that carry text, print " [text]"
    movzx rax, byte [rbx]
    cmp rax, TOK_IDENT
    je .pd_show_text
    cmp rax, TOK_STR
    je .pd_show_text
    cmp rax, TOK_INT
    je .pd_show_text
    cmp rax, TOK_FLOAT
    je .pd_show_text
    jmp .pd_no_text
.pd_show_text:
    mov rsi, str_tok_sep
    call print_string
    call party_print_tok_text
.pd_no_text:
    mov rsi, newline_str
    call print_string

    inc r13
    jmp .pd_loop
.pd_done:
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; data
; ------------------------------------------------------------
msg_party_usage:    db 'usage: party <file.pa> | party compile <file.pa> | party get <module>', 10, 0
msg_party_lex_err:  db 'party: lex error near line ', 0
msg_party_exec_err: db 'party: error near line ', 0
msg_party_killed:   db 10, 'party: script killed (Esc)', 10, 0
str_party:          db 'party', 0
str_compile_flag:   db 'compile', 0
str_get_flag:       db 'get', 0
str_tokens_flag:    db '-tokens', 0
str_minus_char:     db '-', 0

; ---- "party get modulename" ----
; Fetches a module from the shellybin community repo over HTTPS -
; see cmd_party's .do_get for the fetch/save logic. No certificate
; validation, same caveat as stake/sgive (https_warn_once).
PARTY_GET_NAME_MAX equ 64             ; longest bare module name accepted
PARTY_GET_URL_MAX  equ 256            ; fixed prefix (88) + name + ".pa" + NUL
PARTY_GET_DEST_MAX equ 160            ; matches arg2_buf/arg3_buf sizing

party_get_url_prefix: db 'https://raw.githubusercontent.com/TheServer-lab/shellybin/refs/heads/main/party/modules/', 0
party_get_pa_suffix:  db '.pa', 0
party_get_name_buf:   times PARTY_GET_NAME_MAX+1 db 0
party_get_url_buf:    times PARTY_GET_URL_MAX db 0
party_get_dest_buf:   times PARTY_GET_DEST_MAX db 0

msg_party_get_usage:      db 'usage: party get <modulename> [outfile.pa]', 10, 0
msg_party_get_fetching:   db 'party get: fetching ', 0
msg_party_get_saved:      db 'party get: saved to ', 0
msg_party_get_hint:       db 10, '  add: module "', 0
msg_party_get_hint2:      db '" to a script to use it', 10, 0
msg_party_get_notfound:   db 'party get: module not found on server: ', 0
msg_party_get_badname:    db "party get: module name may not contain '/'", 10, 0
msg_party_get_toolong:    db 'party get: module name too long', 10, 0
msg_party_get_createfail: db 'party get: failed to create file.', 10, 0

kw_vars:    db 'vars', 0
kw_if:      db 'if', 0
kw_else:    db 'else', 0
kw_while:   db 'while', 0
kw_func:    db 'func', 0
kw_return:  db 'return', 0
kw_display: db 'display', 0
kw_read:    db 'read', 0
kw_true:    db 'true', 0
kw_false:   db 'false', 0

; Phase 4: `display` formatting for PV_ARRAY (party_print_value)
lbracket_str: db '[', 0
rbracket_str: db ']', 0
comma_sp_str: db ', ', 0
kw_rush:    db 'rush', 0

str_tok_eof:     db 'EOF', 0
str_tok_ident:   db 'IDENT', 0
str_tok_str:     db 'STR', 0
str_tok_int:     db 'INT', 0
str_tok_float:   db 'FLOAT', 0
str_tok_true:    db 'TRUE', 0
str_tok_false:   db 'FALSE', 0
str_tok_vars:    db 'VARS', 0
str_tok_if:      db 'IF', 0
str_tok_else:    db 'ELSE', 0
str_tok_while:   db 'WHILE', 0
str_tok_func:    db 'FUNC', 0
str_tok_return:  db 'RETURN', 0
str_tok_display: db 'DISPLAY', 0
str_tok_newline: db 'NEWLINE', 0
str_tok_lbrace:  db 'LBRACE', 0
str_tok_rbrace:  db 'RBRACE', 0
str_tok_lparen:  db 'LPAREN', 0
str_tok_rparen:  db 'RPAREN', 0
str_tok_plus:    db 'PLUS', 0
str_tok_minus:   db 'MINUS', 0
str_tok_star:    db 'STAR', 0
str_tok_slash:   db 'SLASH', 0
str_tok_eq:      db 'EQ', 0
str_tok_eqeq:    db 'EQEQ', 0
str_tok_neq:     db 'NEQ', 0
str_tok_lt:      db 'LT', 0
str_tok_lte:     db 'LTE', 0
str_tok_gt:      db 'GT', 0
str_tok_gte:     db 'GTE', 0
str_tok_comma:   db 'COMMA', 0
str_tok_percent: db 'PERCENT', 0
str_tok_read:    db 'READ', 0
str_tok_rush:    db 'RUSH', 0
str_tok_error:   db 'ERROR', 0
str_tok_dbgpre:  db 'VGL tok=', 0
str_rel_dbgpre:  db 'REL op=', 0
str_free_dbgpre: db 'FREE', 0
str_tok_sep:     db ' [', 0

ALIGN 8
party_tok_names:
    dq str_tok_eof, str_tok_ident, str_tok_str, str_tok_int, str_tok_float
    dq str_tok_true, str_tok_false, str_tok_vars, str_tok_if, str_tok_else
    dq str_tok_while, str_tok_func, str_tok_return, str_tok_display
    dq str_tok_newline, str_tok_lbrace, str_tok_rbrace, str_tok_lparen
    dq str_tok_rparen, str_tok_plus, str_tok_minus, str_tok_star
    dq str_tok_slash, str_tok_eq, str_tok_eqeq, str_tok_neq, str_tok_lt
    dq str_tok_lte, str_tok_gt, str_tok_gte, str_tok_comma
    dq str_tok_percent, str_tok_read, str_tok_rush

party_lex_ok:      db 0
party_exec_ok:     db 0
party_killed:      db 0
party_error_line:  dd 0
party_src_base:    dq 0     ; source base that token text offsets are relative to
party_ident_buf:   times PARTY_IDENT_MAX db 0
party_call_name_buf: times PARTY_IDENT_MAX db 0

; Phase 3 builtin function names, compared against party_call_name_buf
; by party_call_builtin. These are not keywords - a call to any of
; them reaches the parser as a plain TOK_IDENT followed by '(',
; exactly like a call to a user-defined function; party_call_builtin
; intercepts the name before party_func_find ever sees it.
str_fn_fopen:    db 'fopen', 0
str_fn_fread:    db 'fread', 0
str_fn_fwrite:   db 'fwrite', 0
str_fn_fclose:   db 'fclose', 0
str_fn_fexists:  db 'fexists', 0
str_fn_fdelete:  db 'fdelete', 0

; Phase 4 builtin function names (in-language arrays), same
; not-a-keyword / can't-be-shadowed mechanism as the Phase 3 names
; just above.
str_fn_arr_new:  db 'arr_new', 0
str_fn_arr_len:  db 'arr_len', 0
str_fn_arr_get:  db 'arr_get', 0
str_fn_arr_set:  db 'arr_set', 0
str_fn_arr_free: db 'arr_free', 0

; Phase 5 builtin function names (random + time), same
; not-a-keyword / can't-be-shadowed mechanism as above.
str_fn_rand:     db 'rand', 0
str_fn_randint:  db 'randint', 0
str_fn_randseed: db 'randseed', 0
str_fn_time:     db 'time', 0
str_fn_datestr:  db 'datestr', 0
str_fn_timestr:  db 'timestr', 0

; Phase 3 open-file-handle table, parallel arrays indexed by handle
; slot (party_fh_alloc/party_fh_check). party_fh_pending_mode is
; scratch used only inside party_bi_fopen, between validating the
; mode argument and allocating the slot that will store it.
party_fh_used:  times PARTY_FH_MAX db 0
ALIGN 4
party_fh_node:  times PARTY_FH_MAX dd 0
party_fh_mode:  times PARTY_FH_MAX db 0
party_fh_pending_mode: db 0
party_fh_path_buf: times PARTY_PATH_MAX db 0

; Phase 4 array-slot table, indexed by handle (party_arr_alloc/
; party_arr_check). See PARTY_ARR_MAX/PARTY_ARR_CAP comments (up by
; the Phase 4 code) for why these are sized so small - kernel.asm's
; BSS budget is tight and this table is replicated into every
; background process's saved ctx.
party_arr_used:  times PARTY_ARR_MAX db 0
ALIGN 8
party_arr_count: times PARTY_ARR_MAX dq 0
party_arr_data:  times PARTY_ARR_MAX*PARTY_ARR_CAP*32 db 0

party_stmt_name_buf: times PARTY_IDENT_MAX db 0
party_text_buf:    times 64 db 0
PARTY_READ_MAX equ 256
party_read_buf:    times PARTY_READ_MAX db 0
PARTY_INTERP_MAX equ 1024   ; string-interpolation output buffer capacity
party_interp_buf: times PARTY_INTERP_MAX db 0
party_interp_ident_buf: times PARTY_IDENT_MAX db 0
party_pel_char_scratch: db 0
ALIGN 8
party_token_count:  dw 0
party_tokens:       times PARTY_MAX_TOKENS*8 db 0

; ------------------------------------------------------------
; interpreter state
; ------------------------------------------------------------
msg_party_bad_stmt:       db 'unknown statement', 0
msg_party_undef_var:      db 'undeclared variable', 0
msg_party_expr_expected:  db 'expected expression', 0
msg_party_rparen:         db "expected ')'", 0
msg_party_lparen:         db "expected '('", 0
msg_party_lbrace:         db "expected '{'", 0
msg_party_undef_func:     db 'unknown function', 0
msg_party_arg_count:      db 'wrong number of arguments', 0
msg_party_call_stack:     db 'call stack overflow', 0
msg_party_vstack:         db 'value stack overflow', 0
msg_party_vstack_und:     db 'value stack underflow', 0
msg_party_locals_full:    db 'local variable table full', 0
msg_party_globals_full:   db 'variable table full', 0
msg_party_funcs_full:     db 'function table full', 0
msg_party_bad_func:       db 'malformed function declaration', 0
msg_party_noretval:       db 'function returned nothing', 0
msg_party_cmp_num:        db 'comparison requires numbers', 0
msg_party_bad_arith:      db 'bad operand type', 0
msg_party_div0:           db 'division by zero', 0
msg_party_bad_unary:      db 'cannot negate this value', 0
msg_party_var_declared:   db 'variable already declared', 0
msg_party_rush_type:      db 'rush requires a string', 0
msg_party_interp_unterm:    db "unterminated '{' in string", 0
msg_party_interp_badident:  db 'invalid {name} in string', 0
msg_party_interp_overflow:  db 'interpolated string too long', 0
msg_party_eof:            db 'unexpected end of script', 0
msg_party_err_near:        db ' near line ', 0

; ---- Phase 3: in-language file access API (fopen/fread/fwrite/
; fclose/fexists/fdelete) ----
msg_party_fh_full:          db 'too many open files', 0
msg_party_fh_invalid:       db 'invalid file handle', 0
msg_party_fh_type:          db 'file handle must be an int', 0
msg_party_fh_readonly:      db 'file not opened for writing', 0
msg_party_fopen_args:       db 'fopen requires (string, string)', 0
msg_party_fopen_mode:       db 'fopen mode must be "r", "w", or "a"', 0
msg_party_fopen_path:       db "fopen: path doesn't resolve", 0
msg_party_fopen_notfound:   db 'fopen: file does not exist', 0
msg_party_fopen_isdir:      db 'fopen: path is a folder', 0
msg_party_fopen_full:       db 'fopen: filesystem is full', 0
msg_party_fread_toobig:     db 'file too large to read', 0
msg_party_fwrite_type:      db 'fwrite requires a string', 0
msg_party_fwrite_toobig:    db 'file too large to write', 0
msg_party_fexists_type:     db 'path argument must be a string', 0
msg_party_fdelete_notfound: db "fdelete: path doesn't exist", 0
msg_party_path_too_long:    db 'path too long', 0

; ---- Phase 4: in-language arrays (arr_new/arr_len/arr_get/arr_set/
; arr_free) ----
msg_party_arr_full:         db 'too many arrays open', 0
msg_party_arr_invalid:      db 'invalid array handle', 0
msg_party_arr_argtype:      db 'expected an array', 0
msg_party_arr_new_args:     db 'arr_new requires an int', 0
msg_party_arr_new_range:    db 'arr_new size out of range', 0
msg_party_arr_index_type:   db 'array index must be an int', 0
msg_party_arr_bounds:       db 'array index out of bounds', 0

party_returning:         db 0     ; 1 while a `return` is unwinding
ALIGN 8
party_err_msg_ptr:       dq 0     ; message for the current interpreter error
party_vsp:               dq 0     ; value stack count
party_call_depth:        dq 0     ; active call-frame count
party_loc_count:         dq 0     ; locals pool next-free index
party_func_count:        dq 0     ; collected function count

party_while_cond_tok:    dd 0     ; '(' token index of an active while
party_while_body_tok:    dd 0     ; first body-token index of an active while

party_scratch:   times 32 db 0    ; temp value slots used by the interpreter
party_scratch1:  times 32 db 0
party_scratch2:  times 32 db 0
party_scratch3:  times 32 db 0    ; Phase 4: arr_set(a, i, v) is the first
                                  ; builtin with 3 args, needing a 3rd slot

party_ftmp_i:    dq 0             ; int/float temp for x87 loads
party_tmp_i:     dq 0             ; int temp for float formatting
party_fp_cw:     dw 0
party_fp_cw2:    dw 0
ALIGN 4
fp_10:           dd 10.0
fp_1em7:         dd 0.0000001
party_num_buf:   times 32 db 0    ; number formatting buffer

; value stack
ALIGN 8
party_vstack:    times MAXVSTACK*32 db 0

; global variables
party_var_used:  times MAXVARS db 0
ALIGN 8
party_var_val:   times MAXVARS*32 db 0
party_var_name:  times MAXVARS*PARTY_IDENT_MAX db 0

; locals pool
party_loc_used:  times MAXLOCALS db 0
ALIGN 8
party_loc_val:   times MAXLOCALS*32 db 0
party_loc_name:  times MAXLOCALS*PARTY_IDENT_MAX db 0

; function table
ALIGN 8
party_func_name:      times MAXFUNCS*PARTY_IDENT_MAX db 0
party_func_nparams:   times MAXFUNCS db 0
ALIGN 4
party_func_paramtok:  times MAXFUNCS*8 dd 0
party_func_bodytok:   times MAXFUNCS dd 0
party_func_bodyend:   times MAXFUNCS dd 0

; call frames
ALIGN 8
party_frame_ret_r13:  times MAXCALLS dd 0
party_frame_locbase:  times MAXCALLS dd 0
party_frame_nparams:  times MAXCALLS db 0
party_frame_returned: times MAXCALLS db 0
ALIGN 8
party_frame_retval:   times MAXCALLS*32 db 0

str_run_header_block:
    db "[ShellyForever]", 10
    db "[run 0.1]", 10
    db "program = v1", 10, 0

msg_party_compiled1: db "Compiled ", 0
msg_party_compiled2: db " -> ", 0

ALIGN 8
party_run_out_filename: times 64 db 0
party_run_bin_buf:      times 4096 db 0

derive_run_filename:
    push rsi
    push rdi
    push rcx
    push rbx
    mov rsi, arg2_buf
    mov rdi, party_run_out_filename
    call str_copy
    mov rsi, party_run_out_filename
.dr_len_loop:
    cmp byte [rsi], 0
    je .dr_found_end
    inc rsi
    jmp .dr_len_loop
.dr_found_end:
    sub rsi, 3
    cmp rsi, party_run_out_filename
    jl .dr_out
    cmp byte [rsi], '.'
    jne .dr_out
    cmp byte [rsi+1], 'p'
    jne .dr_out
    cmp byte [rsi+2], 'a'
    jne .dr_out
    mov byte [rsi], '.'
    mov byte [rsi+1], 'r'
    mov byte [rsi+2], 'u'
    mov byte [rsi+3], 'n'
    mov byte [rsi+4], 0
.dr_out:
    pop rbx
    pop rcx
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------
; party_emit_lit_display: emits one compiled "display <literal>"
; sequence (print text, then newline) into the .run code buffer,
; followed by the literal's text itself.
; In:  rdi = output cursor into party_run_bin_buf (the live codegen
;            cursor - callers keep using rdi after this returns)
;      rsi = pointer to the literal's raw text (no quotes, no minus)
;      rcx = length of that text
;      r11 = 1 to prepend a literal '-' before the text, 0 otherwise
; Out: rdi advanced past the emitted instructions + text + NUL.
; Clobbers: rax, rsi, rcx.
; ------------------------------------------------------------
party_emit_lit_display:
    ; LEA RSI, [RIP+disp]   (runtime instruction, being written here)
    ; disp must land exactly on the text bytes that follow the fixed
    ; 15-byte call/mov/call/jmp tail below (3+4+3+5), plus 1 more byte if
    ; a '-' is going to be written before the text.
    mov byte [rdi], 0x48
    mov byte [rdi+1], 0x8D
    mov byte [rdi+2], 0x35
    mov eax, 15                   ; was 10 - grew by 5 for the JMP added below
    cmp r11, 1
    jne .eld_disp_set
    inc eax
.eld_disp_set:
    mov [rdi+3], eax
    add rdi, 7

    mov byte [rdi], 0xFF          ; call [table+0]  -> kernel print_string
    mov byte [rdi+1], 0x57
    mov byte [rdi+2], 0x00
    add rdi, 3

    mov byte [rdi], 0x48          ; mov rsi, [table+0x18] -> newline_str
    mov byte [rdi+1], 0x8B
    mov byte [rdi+2], 0x77
    mov byte [rdi+3], 0x18
    add rdi, 4

    mov byte [rdi], 0xFF          ; call [table+0]  -> print the newline
    mov byte [rdi+1], 0x57
    mov byte [rdi+2], 0x00
    add rdi, 3

    ; JMP rel32, jumping over the embedded text literal that follows.
    ; Without this, execution fell straight off the end of the call above
    ; and started executing the raw text bytes as machine code - that was
    ; the crash: any compiled program with a "display <literal>" line
    ; would run fine right up until it hit the embedded text and then
    ; jump into garbage/random opcodes.
    mov byte [rdi], 0xE9
    mov eax, ecx                  ; text length
    cmp r11, 1
    jne .eld_jmp_set
    inc eax                       ; account for the leading '-' byte
.eld_jmp_set:
    inc eax                       ; account for the NUL terminator byte
    mov [rdi+1], eax
    add rdi, 5

    cmp r11, 1
    jne .eld_copy
    mov byte [rdi], '-'
    inc rdi
.eld_copy:
    rep movsb                     ; copies rcx bytes [rsi]->[rdi], advances both
    mov byte [rdi], 0
    inc rdi
    ret

party_compile_to_run:
    lea rdi, [party_run_bin_buf]
    mov rsi, str_run_header_block
    call str_copy
    dec rdi                        ; overwrite the trailing NUL str_copy
                                   ; wrote: the stub must sit immediately
                                   ; after the header's last \n so cmd_run's
                                   ; str_next_line lands on it, not on a gap

    ; ---- 14-byte entry stub + embedded source. A .run binary is now:
    ; 3-line header, a 14-byte stub, then the whole NUL-terminated Party
    ; source. 'run f.run' executes the stub byte-for-byte (LEA RSI,[RIP+7]
    ; -> the embedded source, CALL [RDI+0xE0] -> KAPI_BOOT -> the
    ; party_boot_compiled interpreter bootstrap, RET). 'run f.run -back'
    ; copies the source at [stub+14] into the process's own buffer and
    ; lexes it directly - the same layout serves both paths. ----
    mov byte [rdi], 0x48          ; lea rsi, [rip+7]
    mov byte [rdi+1], 0x8D
    mov byte [rdi+2], 0x35
    mov dword [rdi+3], 7
    mov byte [rdi+7], 0xFF        ; call [rdi+0xE0]
    mov byte [rdi+8], 0x57
    mov byte [rdi+9], 0xE0
    mov byte [rdi+10], 0xC3       ; ret
    mov byte [rdi+11], 0x90       ; nop x3 pads to the 14-byte stub
    mov byte [rdi+12], 0x90
    mov byte [rdi+13], 0x90
    add rdi, 14

    ; embed the whole Party source (the compile command lexed it out of
    ; fs_io_buf just before calling us), NUL-terminated
    lea rsi, [fs_io_buf]
.pc_src_copy:
    mov al, byte [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    cmp al, 0
    jne .pc_src_copy

    push rdi
    mov rax, [cur_dir]
    lea rsi, [party_run_out_filename]
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .pc_create_parent
    mov r11, rax
    jmp .pc_found_parent
.pc_create_parent:
    mov r11, [cur_dir]
.pc_found_parent:
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .pc_overwrite_file

    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2
    call fs_create_node
    cmp rax, -1
    je party_compile_fail
    mov r12, rax
    jmp .pc_do_write

.pc_overwrite_file:
    mov r12, rax

.pc_do_write:
    mov rax, r12
    lea rsi, [party_run_bin_buf]
    mov rcx, [rsp]              ; the saved write cursor (pushed above,
                                ; before fs_resolve_path clobbered rdi)
    sub rcx, rsi
    call fs_write_binary_file
    call maybe_auto_sync

    mov rsi, msg_party_compiled1
    mov al, [cur_normal_attr]
    call print_string_attr
    lea rsi, [arg2_buf]
    call print_string
    mov rsi, msg_party_compiled2
    call print_string
    lea rsi, [party_run_out_filename]
    call print_string
    mov rsi, newline_str
    call print_string
    pop rdi
    ret

msg_compile_fail: db "compile: error: failed to create node or write file", 10, 0

party_compile_fail:
    pop rdi
    mov rsi, msg_compile_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret