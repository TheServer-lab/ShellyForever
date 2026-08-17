; ============================================================
;  sin.asm  --  Shelly package manager ("sin get")
;
;  One shell command, layered on top of https.asm's stake machinery
;  and install.asm's cmd_install:
;
;    sin get <programname> [-keep]
;
;  Downloads
;    https://raw.githubusercontent.com/TheServer-lab/shellybin/refs/heads/main/sin/programs/<programname>.sin
;  via TLS 1.3 (same "no certificate validation" trust model as
;  stake/sgive -- see https.asm's header comment and https_warn_once,
;  reused verbatim here), saves it into the current directory as
;  <programname>.sin, then hands that file straight to cmd_install
;  (install.asm) exactly as if the user had typed
;  "install <programname>.sin" themselves. Once cmd_install returns,
;  the downloaded .sin is deleted -- unless "-keep" was given as the
;  third argument, in which case it's left in the current directory
;  (matching apt's --keep-downloaded-packages / "apt -d" spirit,
;  minus the extra flag name since sin only ever has the one thing
;  worth keeping).
;
;  Design notes:
;    - This is deliberately a thin GET-then-install wrapper, not a
;      third HTTP/TLS client: http_parse_url / http_build_get /
;      https_bridge_tx / https_find_body / https_warn_once /
;      tls_do_exchange are all reused unchanged from http.asm /
;      https.asm, the same way https.asm itself reused http.asm's
;      pieces for stake/sgive. The only new wire-format code here is
;      building the request URL and the local filename.
;    - <programname> is restricted to a bare identifier (letters,
;      digits, '-', '_') by sin_validate_name before it's ever
;      concatenated into the request path or a filesystem path --
;      it's the only piece of this command that isn't an already-
;      trusted constant, so this is what stops a name containing
;      "/", "..", or whitespace from escaping the intended
;      .../sin/programs/ folder on the remote end or writing outside
;      the current directory on this end.
;    - Cleanup only ever deletes the exact file this command itself
;      just wrote (looked back up by name in the current directory,
;      the same way cmd_del looks up its target) -- never anything
;      cmd_install's whattodo.inst script may have copied elsewhere.
;      That mirrors install.asm's own uninstall scope note: no
;      manifest of an install's side effects exists to clean up
;      beyond the package file itself.
;    - Not tested in a real boot/QEMU environment -- only nasm
;      syntax-checked alongside the rest of the kernel image, same
;      caveat install.asm carries.
;
;  Included from kernel.asm, after https.asm (https_bridge_tx /
;  https_find_body / https_warn_once) and install.asm (cmd_install);
;  inherits BITS 64.
; ============================================================

SIN_NAME_MAX equ 60             ; max bytes for <programname> itself

; ------------------------------------------------------------
; sin_validate_name: rsi = candidate program name (NUL-terminated,
; from arg2_buf). Returns al=1 if it's a safe bare identifier --
; 1..SIN_NAME_MAX bytes, letters/digits/'-'/'_' only -- al=0
; otherwise. This is the only gate between user input and the
; request path / local filename built below, so it runs before
; either is touched.
; ------------------------------------------------------------
sin_validate_name:
    push rcx
    push rsi
    xor ecx, ecx
.svn_loop:
    mov al, [rsi]
    test al, al
    jz .svn_end
    cmp al, 'a'
    jb .svn_upper
    cmp al, 'z'
    jbe .svn_ok_char
.svn_upper:
    cmp al, 'A'
    jb .svn_digit
    cmp al, 'Z'
    jbe .svn_ok_char
.svn_digit:
    cmp al, '0'
    jb .svn_dash
    cmp al, '9'
    jbe .svn_ok_char
.svn_dash:
    cmp al, '-'
    je .svn_ok_char
    cmp al, '_'
    je .svn_ok_char
    jmp .svn_bad
.svn_ok_char:
    inc rsi
    inc ecx
    cmp ecx, SIN_NAME_MAX
    ja .svn_bad
    jmp .svn_loop
.svn_end:
    test ecx, ecx
    jz .svn_bad
    mov al, 1
    jmp .svn_out
.svn_bad:
    xor al, al
.svn_out:
    pop rsi
    pop rcx
    ret

; ============================================================
; cmd_sin: "sin get <programname> [-keep]"
;     Only one subcommand exists today (get); anything else, or a
;     bare "sin", prints usage -- same shape as cmd_prs's arg1_buf
;     subcommand dispatch in kernel.asm.
; ============================================================
cmd_sin:
    mov rsi, arg1_buf
    mov rdi, str_sin_get
    call str_eq
    cmp al, 1
    je cmd_sin_get

    mov rsi, msg_sin_usage
    mov al, [cur_normal_attr]
    call print_string_attr
    ret

; ------------------------------------------------------------
; cmd_sin_get: does the actual fetch + install + cleanup.
; ------------------------------------------------------------
cmd_sin_get:
    cmp byte [nic_present], 0
    je .no_nic
    cmp byte [arg2_buf], 0
    je .usage

    lea rsi, [arg2_buf]
    call sin_validate_name
    cmp al, 1
    jne .bad_name

    ; build the request URL: sin_url_buf = prefix + name + ".sin"
    lea rdi, [sin_url_buf]
    mov rsi, sin_url_prefix
    call str_copy
    lea rdi, [sin_url_buf]
    mov rsi, arg2_buf
    call str_append
    lea rdi, [sin_url_buf]
    mov rsi, sin_url_suffix
    call str_append

    ; build the local filename: sin_fname_buf = name + ".sin"
    lea rdi, [sin_fname_buf]
    mov rsi, arg2_buf
    call str_copy
    lea rdi, [sin_fname_buf]
    mov rsi, sin_url_suffix
    call str_append

    lea rsi, [sin_url_buf]
    call http_parse_url
    jc .bad_url
    cmp byte [http_url_scheme], 1
    jne .bad_url                ; sin_url_prefix is always https:// -- defensive only

    call https_warn_once

    call http_build_get
    mov [tcp_tx_len], eax
    call https_bridge_tx

    mov rsi, msg_sin_getting
    call print_string
    lea rsi, [sin_fname_buf]
    call print_string
    mov rsi, msg_nl
    call print_string

    lea rsi, [http_host_buf]
    mov dx, [http_port]
    call tls_do_exchange
    jc .done

    ; reject non-200 responses (e.g. a 404 for a typo'd name) before
    ; saving anything
    lea rsi, [tls_app_rx_buf]
    mov ecx, [tls_app_rx_len]
    call http_status_code
    jc .bad_status
    cmp eax, 200
    jne .bad_status

    ; find body in response
    call https_find_body
    jc .no_body

    ; rax = body ptr in tls_app_rx_buf, ecx = body len
    mov rsi, rax
    mov dword [http_body_len], ecx

    ; copy body to http_rx_buf and NUL-terminate
    test ecx, ecx
    jz .write_file
    cmp ecx, (HTTP_RX_BUF_SIZE - 1)
    jbe .body_fits
    mov ecx, (HTTP_RX_BUF_SIZE - 1)
.body_fits:
    mov dword [http_body_len], ecx   ; effective (capped) length - must store before
                                     ; rep movsb consumes ecx as the copy counter
    lea rdi, [http_rx_buf]
    rep movsb
    mov byte [rdi], 0

.write_file:
    ; resolve/create <programname>.sin in the current directory
    mov rax, [cur_dir]
    mov rsi, sin_fname_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .bad_path
    mov r11, rax                 ; parent folder
    call check_target_sys_auth
    cmp rax, 1
    je .done

    ; check if file already exists
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .sg_overwrite

    ; create new file
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2                  ; type file
    call fs_create_node
    cmp rax, -1
    je .sg_create_fail
    mov r12, rax
    jmp .sg_do_write

.sg_create_fail:
    mov rsi, msg_sin_createfail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .done

.sg_overwrite:
    mov r12, rax

.sg_do_write:
    ; http_rx_buf holds the body (http_body_len bytes) -- same shared
    ; staging buffer take/stake use, same NUL-scan to pick text vs.
    ; binary write. A .sin is a stored-mode zip so it's binary in
    ; practice, but this stays general the same way take/stake do.
    mov ecx, [http_body_len]
    test ecx, ecx
    jz .sg_text_write
    lea rdi, [http_rx_buf]
.sg_scan_nul:
    mov al, [rdi]
    test al, al
    je .sg_binary_write
    inc rdi
    dec ecx
    jnz .sg_scan_nul
.sg_text_write:
    mov rax, r12
    lea rsi, [http_rx_buf]
    call fs_write_file
    jmp .sg_written
.sg_binary_write:
    mov rax, r12
    lea rsi, [http_rx_buf]
    mov ecx, [http_body_len]
    call fs_write_binary_file
.sg_written:
    call maybe_auto_sync

    ; hand off to the installer: arg1_buf becomes the downloaded
    ; package's filename -- "get" (its value up to this point) is
    ; no longer needed, matching the "run <file.run> -back" shift
    ; trick in kernel.asm's dispatch, just simpler since we're
    ; overwriting rather than shifting.
    lea rdi, [arg1_buf]
    lea rsi, [sin_fname_buf]
    call str_copy
    call cmd_install

    ; clean up the downloaded package unless "-keep" was given
    mov rsi, arg3_buf
    mov rdi, str_sin_keep
    call str_eq
    cmp al, 1
    je .sin_keep

    mov rax, [cur_dir]
    mov rsi, sin_fname_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .done
    mov rax, rax                ; parent folder already in rax
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .done
    call fs_delete_tree
    call maybe_auto_sync
    mov rsi, msg_sin_cleaned
    mov al, [cur_normal_attr]
    call print_string_attr
    jmp .done

.sin_keep:
    mov rsi, msg_sin_kept
    mov al, [cur_normal_attr]
    call print_string_attr
    lea rsi, [sin_fname_buf]
    call print_string
    mov rsi, newline_str
    call print_string
    jmp .done

.no_body:
    mov rsi, msg_sin_nobody
    mov al, [cur_normal_attr]
    call print_string_attr
    jmp .done

.bad_status:
    push rax                    ; save status code across print_string calls
    mov rsi, msg_sin_badstatus
    mov al, ATTR_ERROR
    call print_string_attr
    pop rax
    call tcp_print_dec
    mov rsi, msg_sin_badstatus2
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .done

.bad_path:
    mov rsi, msg_sin_badpath
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .done

.bad_url:
    mov rsi, msg_sin_badurl
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.bad_name:
    mov rsi, msg_sin_badname
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.usage:
    mov rsi, msg_sin_usage
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.no_nic:
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.done:
    ret

; ------------------------------------------------------------
; sin.asm data
; ------------------------------------------------------------
str_sin:      db "sin", 0
str_sin_get:  db "get", 0
str_sin_keep: db "-keep", 0

sin_url_prefix: db "https://raw.githubusercontent.com/TheServer-lab/shellybin/refs/heads/main/sin/programs/", 0
sin_url_suffix: db ".sin", 0

msg_sin_usage:      db "sin: usage: sin get <programname> [-keep]", 10, 0
msg_sin_badname:    db "sin: invalid program name (letters, digits, - and _ only)", 10, 0
msg_sin_getting:    db "sin: fetching ", 0
msg_sin_badurl:     db "sin: bad package URL", 10, 0
msg_sin_createfail: db "sin: failed to create file.", 10, 0
msg_sin_badpath:    db "sin: bad file path.", 10, 0
msg_sin_nobody:     db "sin: no body in response.", 10, 0
msg_sin_badstatus:  db "sin: server returned status ", 0
msg_sin_badstatus2: db " -- package not saved.", 10, 0
msg_sin_kept:       db "sin: package kept as ", 0
msg_sin_cleaned:    db "sin: removed downloaded package", 10, 0

; scratch buffers -- sized like http_path_buf (128): sin_url_prefix's
; path portion is 54 bytes, so SIN_NAME_MAX(60) + ".sin"(4) leaves
; comfortable headroom under the URL parser's own 127-byte path cap.
sin_url_buf:   times 256 db 0
sin_fname_buf: times (SIN_NAME_MAX + 8) db 0
