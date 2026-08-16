; ============================================================
;  https.asm  --  HTTPS stake / sgive (Phase 5 of the https.asm
;  build plan -- see phases.txt)
;
;  Two shell commands, user-facing parity with http.asm's take/give:
;    stake <url> <file>   TLS 1.3 GET,  save body to a file
;    sgive <url> <file>   TLS 1.3 POST, send file content to server
;
;  URL format: https://host[:port]/path  (default port 443)
;
;  *** NO CERTIFICATE VALIDATION ***  tls.asm (Phase 3) does not
;  verify the server's Certificate/CertificateVerify chain -- see
;  phases.txt's SCOPE DECISION. This is the same trust model as
;  `curl -k` / `wget --no-check-certificate`: the connection is
;  encrypted but the server's identity is NOT authenticated. A
;  warning is printed once per session the first time stake/sgive
;  runs (https_warn_once, called from both commands below) so this
;  is never mistaken for a verifying client.
;
;  Design (per phases.txt Phase 5):
;    - http_parse_url (http.asm) now recognizes both http:// and
;      https:// and records which one in http_url_scheme (0/1).
;      stake/sgive require scheme==1 (https://); take/give (already
;      edited in http.asm) require scheme==0 -- separate verbs, not
;      scheme-sniffing on a shared command, per the "pick ONE
;      approach" note.
;    - http_build_get / http_build_post are content-format-agnostic
;      and reused completely unchanged; they still write into
;      tcp_tx_buf / http_tx_big as before. https_bridge_tx below
;      copies the finished request from tcp_tx_buf into
;      tls_app_tx_buf (tls_do_exchange's input buffer) since the two
;      are sized differently (TCP_PAYLOAD_MAX=1536 vs
;      TLS_APP_TX_MAX=2048) and tls_do_exchange doesn't read
;      tcp_tx_buf directly.
;    - https_find_body is http_find_body's logic re-pointed at
;      tls_app_rx_buf/tls_app_rx_len instead of tcp_rx_buf/
;      tcp_rx_len, for the same reason in the other direction
;      (TLS_APP_RX_MAX=4096 is a different buffer with a different
;      purpose than tcp_rx_buf, which only ever holds raw handshake-
;      phase record bytes before tls_pump drains it -- see
;      TCP_RX_BUF_SIZE in tcp.asm).
;      tcp_rx_buf/tcp_rx_len themselves are untouched by this phase.
;
;  Included from kernel.asm; inherits BITS 64.
; ============================================================

; ---- bridge: copy the finished request from tcp_tx_buf (built by
; http_build_get / http_build_post, [tcp_tx_len] bytes) into
; tls_app_tx_buf, the buffer tls_do_exchange actually reads. Both
; HTTP_TX_MAX (1200) and the GET path's short header block fit
; comfortably inside TLS_APP_TX_MAX (2048), so no bounds check is
; needed here beyond what http_build_get/http_build_post already do
; against HTTP_TX_MAX/tcp_tx_buf. ----
https_bridge_tx:
    push rax
    push rcx
    push rsi
    push rdi
    mov ecx, [tcp_tx_len]
    mov [tls_app_tx_len], ecx
    lea rsi, [tcp_tx_buf]
    lea rdi, [tls_app_tx_buf]
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ---- find HTTP headers end (CRLF CRLF) in tls_app_rx_buf ----
; Same contract/logic as http.asm's http_find_body, re-pointed at the
; TLS app-data buffer -- see header comment above for why this can't
; just reuse http_find_body against tcp_rx_buf.
; Returns: rax = ptr into tls_app_rx_buf past the blank line (body
;          start), ecx = body length remaining.
;          CF=1 if no body found.
https_find_body:
    push rbx
    push rdi
    push rsi
    push rdx

    mov dword [http_body_len], 0
    lea rsi, [tls_app_rx_buf]
    mov ecx, [tls_app_rx_len]
    test ecx, ecx
    jz .nob

.scan:
    cmp ecx, 3                  ; need at least 4 bytes
    jbe .nob
    cmp byte [rsi], 13
    jne .next
    cmp byte [rsi+1], 10
    jne .next
    cmp byte [rsi+2], 13
    jne .next
    cmp byte [rsi+3], 10
    jne .next
    ; found. rax = body start pointer
    lea rax, [rsi+4]
    ; body length = (tls_app_rx_buf + tls_app_rx_len) - rax
    mov ecx, [tls_app_rx_len]
    lea rdx, [tls_app_rx_buf]
    add rdx, rcx
    sub rdx, rax
    mov ecx, edx
    clc
    jmp .sout
.next:
    inc rsi
    dec ecx
    jmp .scan
.nob:
    stc
.sout:
    pop rdx
    pop rsi
    pop rdi
    pop rbx
    ret

; ---- print the "no certificate validation" warning once per session.
; Called at the top of both cmd_stake and cmd_sgive, after usage/URL
; checks pass, so it's shown before any network activity but not on
; every failed/mistyped invocation. ----
https_warn_once:
    push rax
    push rsi
    cmp byte [https_warn_shown], 0
    jne .hw_done
    mov byte [https_warn_shown], 1
    mov rsi, msg_https_nocert
    mov al, ATTR_ERROR
    call print_string_attr
.hw_done:
    pop rsi
    pop rax
    ret

; ============================================================
; cmd_stake: "stake <url> <file>"
;     TLS 1.3 GET from an https:// URL, save response body to a file.
;     Structurally a near-duplicate of http.asm's cmd_take -- see
;     that routine for the file-write logic this mirrors verbatim.
; ============================================================
cmd_stake:
    cmp byte [nic_present], 0
    je .no_nic
    cmp byte [arg1_buf], 0
    je .usage
    cmp byte [arg2_buf], 0
    je .usage

    lea rsi, [arg1_buf]
    call http_parse_url
    jc .bad_url
    cmp byte [http_url_scheme], 1
    jne .bad_url              ; http:// -- use "take" instead

    call https_warn_once

    call http_build_get
    mov [tcp_tx_len], eax
    call https_bridge_tx

    mov rsi, msg_stake_getting
    call print_string
    lea rsi, [http_path_buf]
    call print_string
    mov rsi, msg_stake_from
    call print_string
    lea rsi, [http_host_buf]
    call print_string
    mov rsi, msg_nl
    call print_string

    lea rsi, [http_host_buf]
    mov dx, [http_port]
    call tls_do_exchange
    jc .done

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
    ; resolve/create file in current directory (pattern from cmd_mkfl)
    mov rax, [cur_dir]
    mov rsi, arg2_buf
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
    jne .tk_overwrite

    ; create new file
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2                  ; type file
    call fs_create_node
    cmp rax, -1
    je .tk_create_fail
    mov r12, rax
    jmp .tk_do_write

.tk_create_fail:
    mov rsi, msg_stake_createfail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .done

.tk_overwrite:
    mov r12, rax

.tk_do_write:
    ; http_rx_buf holds the body (http_body_len bytes) -- same shared
    ; staging buffer cmd_take uses, same NUL-scan to pick text vs.
    ; binary write.
    mov ecx, [http_body_len]
    test ecx, ecx
    jz .tk_text_write
    lea rdi, [http_rx_buf]
.tk_scan_nul:
    mov al, [rdi]
    test al, al
    je .tk_binary_write
    inc rdi
    dec ecx
    jnz .tk_scan_nul
.tk_text_write:
    mov rax, r12
    lea rsi, [http_rx_buf]
    call fs_write_file
    jmp .tk_written
.tk_binary_write:
    mov rax, r12
    lea rsi, [http_rx_buf]
    mov ecx, [http_body_len]
    call fs_write_binary_file
.tk_written:
    call maybe_auto_sync
    mov rsi, msg_stake_saved
    call print_string
    mov rsi, arg2_buf
    call print_string
    mov rsi, msg_nl
    call print_string
    jmp .done

.no_body:
    mov rsi, msg_stake_nobody
    mov al, [cur_normal_attr]
    call print_string_attr
    mov eax, [tls_app_rx_len]
    call tcp_print_dec
    mov rsi, msg_stake_nobody2
    mov al, [cur_normal_attr]
    call print_string_attr
    jmp .done

.bad_path:
    mov rsi, msg_stake_badpath
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .done

.bad_url:
    mov rsi, msg_stake_badurl
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.usage:
    mov rsi, msg_stake_usage
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

; ============================================================
; cmd_sgive: "sgive <url> <file>"
;     Reads local file, TLS 1.3 POST to an https:// URL, prints
;     reply headers. Near-duplicate of http.asm's cmd_give.
; ============================================================
cmd_sgive:
    cmp byte [nic_present], 0
    je .no_nic
    cmp byte [arg1_buf], 0
    je .usage
    cmp byte [arg2_buf], 0
    je .usage

    lea rsi, [arg1_buf]
    call http_parse_url
    jc .bad_url
    cmp byte [http_url_scheme], 1
    jne .bad_url              ; http:// -- use "give" instead

    call https_warn_once

    ; resolve file and read its content
    mov rax, [cur_dir]
    mov rsi, arg2_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .bad_path

    mov r14, rax
    mov rax, r14
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .nofile

    mov r12, rax                ; file node index
    mov eax, [node_bin_len + r12*4]
    test eax, eax
    jnz .gv_len_binary
    mov rax, r12
    call fs_file_len
    jmp .gv_len_done
.gv_len_binary:
    mov eax, [node_bin_len + r12*4]
.gv_len_done:
    cmp rax, (HTTP_RX_BUF_SIZE - 1)
    jbe .len_ok
    mov eax, (HTTP_RX_BUF_SIZE - 1)
.len_ok:
    mov r13, rax                ; r13 = content length
    mov rax, r12
    lea rdi, [http_rx_buf]
    cmp dword [node_bin_len + r12*4], 0
    je .gv_read_text
    call fs_read_binary_file    ; binary-safe read for compiled .run files
    jmp .gv_read_done
.gv_read_text:
    call fs_read_file           ; reads file into http_rx_buf
.gv_read_done:
    mov byte [http_rx_buf + r13], 0   ; NUL-terminate

    lea rsi, [http_rx_buf]
    mov rcx, r13
    call http_build_post
    jc .too_big_to_send
    call https_bridge_tx

    mov rsi, msg_sgive_posting
    call print_string
    lea rsi, [http_path_buf]
    call print_string
    mov rsi, msg_sgive_to
    call print_string
    lea rsi, [http_host_buf]
    call print_string
    mov rsi, msg_nl
    call print_string

    lea rsi, [http_host_buf]
    mov dx, [http_port]
    call tls_do_exchange
    jc .gv_done

    ; print reply (up to 512 chars)
    lea rsi, [tls_app_rx_buf]
    mov ecx, [tls_app_rx_len]
    test ecx, ecx
    jz .gv_nobody
    cmp ecx, 512
    jbe .gv_prn
    mov ecx, 512
    mov byte [tls_app_rx_buf + rcx], 0
.gv_prn:
    lea rsi, [tls_app_rx_buf]
    call print_string
    mov rsi, msg_nl
    call print_string
    jmp .gv_done
.gv_nobody:
    mov rsi, msg_sgive_noreply
    mov al, [cur_normal_attr]
    call print_string_attr
.gv_done:
    ret

.nofile:
    mov rsi, msg_sgive_nofile
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.too_big_to_send:
    mov rsi, msg_sgive_too_big
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.bad_path:
    mov rsi, msg_stake_badpath
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.bad_url:
    mov rsi, msg_stake_badurl
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.usage:
    mov rsi, msg_sgive_usage
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.no_nic:
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    ret
