; ============================================================
;  http.asm  --  HTTP take / give (Milestone D)
;
;  Two shell commands:
;    take <url> <file>   HTTP/1.0 GET, save body to a file
;    give <url> <file>   HTTP/1.0 POST, send file content to server
;
;  URL format: http://host[:port]/path
;  e.g.:  take http://10.0.2.2:80/notes.txt notes.txt
;         give http://10.0.2.2:8000/upload notes.txt
;
;  Included from kernel.asm; inherits BITS 64.
; ============================================================

HTTP_DEFAULT_PORT equ 80
HTTP_RX_BUF_SIZE equ 3072
HTTP_TX_MAX      equ 1200

; ---- URL parser ----
; http_parse_url: rsi = url string. Fills http_host_buf, http_port,
; http_path_buf (defaults to "/"). CF=0 on success, CF=1 on bad URL.
http_parse_url:
    push rbx
    push rcx
    push rdi
    push rsi
    mov word [http_port], HTTP_DEFAULT_PORT
    lea rdi, [http_path_buf]
    mov byte [rdi], '/'
    mov byte [rdi+1], 0
    ; verify "http://"
    cmp byte [rsi], 'h'
    jne .bad
    cmp byte [rsi+1], 't'
    jne .bad
    cmp byte [rsi+2], 't'
    jne .bad
    cmp byte [rsi+3], 'p'
    jne .bad
    cmp byte [rsi+4], ':'
    jne .bad
    cmp byte [rsi+5], '/'
    jne .bad
    cmp byte [rsi+6], '/'
    jne .bad
    add rsi, 7
    ; extract hostname (up to ':', '/', '#', '?', or NUL)
    lea rdi, [http_host_buf]
    xor ecx, ecx
.hlp:
    mov al, [rsi]
    test al, al
    jz .hdn
    cmp al, ':'
    je .hdn
    cmp al, '/'
    je .hdn
    cmp al, '#'
    je .hdn
    cmp al, '?'
    je .hdn
    cmp ecx, 63
    jae .hdn
    mov [rdi], al
    inc rsi
    inc rdi
    inc ecx
    jmp .hlp
.hdn:
    mov byte [rdi], 0
    test ecx, ecx
    jz .bad
    mov al, [rsi]
    test al, al
    jz .ok
    cmp al, '/'
    je .ppath
    cmp al, ':'
    je .pport
    cmp al, '#'
    je .ok
    cmp al, '?'
    je .ok
    jmp .bad

.pport:
    inc rsi
    xor edx, edx
    xor ebx, ebx
.port_lp:
    mov al, [rsi]
    cmp al, '0'
    jb .port_dn
    cmp al, '9'
    ja .port_dn
    sub al, '0'
    imul edx, edx, 10
    movzx eax, al
    add edx, eax
    cmp edx, 65535
    ja .bad
    inc rsi
    inc ebx
    jmp .port_lp
.port_dn:
    test ebx, ebx
    jz .bad
    mov [http_port], dx
    mov al, [rsi]
    test al, al
    jz .ok
    cmp al, '/'
    je .ppath
    cmp al, '#'
    je .ok
    cmp al, '?'
    je .ok
    jmp .bad

.ppath:
    lea rdi, [http_path_buf]
.plp:
    mov al, [rsi]
    test al, al
    jz .pdn
    cmp al, '#'
    je .pdn
    cmp al, '?'
    je .pdn
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .plp
.pdn:
    mov byte [rdi], 0
.ok:
    clc
    jmp .out
.bad:
    stc
.out:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; ---- build GET request into tcp_tx_buf ----
; Returns eax = total length.
http_build_get:
    push rdi
    push rsi
    lea rdi, [tcp_tx_buf]
    mov dword [rdi], 'GET '
    add rdi, 4
    lea rsi, [http_path_buf]
.bg_p:
    mov al, [rsi]
    test al, al
    jz .bg_pd
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .bg_p
.bg_pd:
    mov byte [rdi], ' '
    inc rdi
    mov dword [rdi], 'HTTP'
    mov byte [rdi+4], '/'
    mov byte [rdi+5], '1'
    mov byte [rdi+6], '.'
    mov byte [rdi+7], '0'
    add rdi, 8
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    add rdi, 2
    mov dword [rdi], 'Host'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    add rdi, 6
    lea rsi, [http_host_buf]
.bg_h:
    mov al, [rsi]
    test al, al
    jz .bg_hd
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .bg_h
.bg_hd:
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    add rdi, 2
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    add rdi, 2
    lea rax, [tcp_tx_buf]
    sub rdi, rax
    mov rax, rdi
    pop rsi
    pop rdi
    ret

; ---- build POST request into tcp_tx_buf ----
; Input: rsi = body ptr, rcx = body length (from file read)
; Returns eax = total request length (capped at 1024).
http_build_post:
    push rbx
    push rdi
    push rsi
    push r12
    push r13
    mov r12, rsi
    mov r13, rcx

    lea rdi, [http_tx_big]
    mov dword [rdi], 'POST'
    add rdi, 4
    mov byte [rdi], ' '
    inc rdi
    lea rbx, [http_path_buf]
.p1:
    mov al, [rbx]
    test al, al
    jz .p1d
    mov [rdi], al
    inc rbx
    inc rdi
    jmp .p1
.p1d:
    mov byte [rdi], ' '
    inc rdi
    mov dword [rdi], 'HTTP'
    mov byte [rdi+4], '/'
    mov byte [rdi+5], '1'
    mov byte [rdi+6], '.'
    mov byte [rdi+7], '0'
    add rdi, 8
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    add rdi, 2
    ; Host: header
    mov dword [rdi], 'Host'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    add rdi, 6
    lea rbx, [http_host_buf]
.p2:
    mov al, [rbx]
    test al, al
    jz .p2d
    mov [rdi], al
    inc rbx
    inc rdi
    jmp .p2
.p2d:
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    add rdi, 2
    ; Content-Type: text/plain
    mov dword [rdi], 'Cont'
    mov dword [rdi+4], 'ent-'
    mov dword [rdi+8], 'Type'
    mov word [rdi+12], ': '
    mov dword [rdi+14], 'text'
    mov dword [rdi+18], '/pla'
    mov dword [rdi+22], 'in'
    add rdi, 24
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    add rdi, 2
    ; Content-Length: <N>
    mov dword [rdi], 'Cont'
    mov dword [rdi+4], 'ent-'
    mov dword [rdi+8], 'Leng'
    mov dword [rdi+12], 'th: '
    add rdi, 16
    mov rax, r13                ; body len
    call int_to_str             ; writes decimal starting at rdi
    ; Advance rdi past the decimal string (rdi was saved/restored, so
    ; we scan forward from the saved position - use dec_tmp_buf approach)
    mov rbx, rdi
.find_nul:
    cmp byte [rbx], 0
    je .got_nul
    inc rbx
    jmp .find_nul
.got_nul:
    mov byte [rbx], 13          ; overwrite NUL with CR
    mov byte [rbx+1], 10
    lea rdi, [rbx+2]
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    add rdi, 2
    ; body
    test r13, r13
    jz .bp_nobody
    mov rsi, r12
    mov rcx, r13
.bp_body:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jnz .bp_body
.bp_nobody:
    lea rax, [http_tx_big]
    sub rdi, rax
    ; copy to tcp_tx_buf (cap at 1024)
    cmp rdi, 1024
    jbe .bp_fit
    mov rdi, 1024
.bp_fit:
    mov [tcp_tx_len], edi
    lea rsi, [http_tx_big]
    lea rdi, [tcp_tx_buf]
    mov ecx, [tcp_tx_len]
    rep movsb
    mov eax, [tcp_tx_len]
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rbx
    ret

; ============================================================
; tcp_do_exchange -- Full TCP exchange: DNS + handshake + send + recv + close
;   IN:  http_host_buf, http_port already set
;        tcp_tx_buf filled, [tcp_tx_len] = payload length
;   OUT: CF=0 -> tcp_rx_buf reply at [tcp_rx_len] bytes
;        CF=1 -> error (message already printed)
; ============================================================
tcp_do_exchange:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    lea rsi, [http_host_buf]
    call dns_query
    cmp eax, 0xFFFFFFFF
    je .de_unresolved
    mov [tcp_peer_ip], eax

    movzx eax, word [http_port]
    mov [tcp_peer_port], ax

    mov ax, [nic_ip_id]
    add ax, 0x1000
    mov [tcp_my_port], ax

    mov byte [kill_flag], 0
    mov dword [tcp_isn], 0x00020000
    mov eax, [tcp_isn]
    mov [tcp_cur_seq], eax
    mov dword [tcp_cur_ack], 0
    mov dword [tcp_last_ack], 0
    mov byte [tcp_rst_got], 0
    mov byte [tcp_fin_got], 0
    mov byte [tcp_rx_got], 0
    mov byte [tcp_retry], 0
    mov byte [tcp_wait_ticks], TCP_ROUND_SECS
    mov byte [tcp_state], 1

    ; send SYN
    xor rsi, rsi
    xor ecx, ecx
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_SYN
    call tcp_send_segment
    jc .de_sendfail

    call rtc_sec_now
    mov r14d, eax
.de_w1:
    call kbd_poll
    cmp byte [kill_flag], 0
    jne .de_cancel
    call netpoll
    cmp byte [tcp_state], 2
    je .de_est
    cmp byte [tcp_rst_got], 0
    jne .de_reset
    call rtc_sec_now
    cmp eax, r14d
    jne .de_rt_syn
    jmp .de_w1
.de_rt_syn:
    mov r14d, eax
    dec byte [tcp_wait_ticks]
    jns .de_w1                  ; still budget left this round - keep polling
    cmp byte [tcp_retry], TCP_MAX_RETRIES
    jae .de_timeout
    inc byte [tcp_retry]
    mov byte [tcp_wait_ticks], TCP_ROUND_SECS
    xor rsi, rsi
    xor ecx, ecx
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_SYN
    call tcp_send_segment
    jc .de_sendfail
    call rtc_sec_now
    mov r14d, eax
    jmp .de_w1

.de_est:
    mov byte [tcp_rx_got], 0
    mov byte [tcp_fin_got], 0
    mov byte [tcp_retry], 0
    mov byte [tcp_wait_ticks], TCP_ROUND_SECS
    mov dword [tcp_last_ack], 0
    mov dword [tcp_rx_len], 0
    mov dword [tcp_rx_prev], 0

    mov r15d, [tcp_tx_len]
    lea rsi, [tcp_tx_buf]
    mov ecx, r15d
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_PSH | TCP_FLAG_ACK
    call tcp_send_segment
    jc .de_sendfail

    call rtc_sec_now
    mov r14d, eax
.de_w2:
    cmp byte [kill_flag], 0
    jne .de_cancel
    call netpoll
    cmp byte [tcp_rx_got], 0
    jne .de_reply
    cmp byte [tcp_rst_got], 0
    jne .de_reset
    call rtc_sec_now
    cmp eax, r14d
    jne .de_tick2
    jmp .de_w2
.de_tick2:
    cmp dword [tcp_rx_len], 0
    je .de_tick2_nodata
    mov eax, [tcp_rx_prev]
    cmp eax, [tcp_rx_len]
    je .de_reply
    mov eax, [tcp_rx_len]
    mov [tcp_rx_prev], eax
    ; fresh data landed this tick - the peer is alive, so give it a full
    ; new round of patience rather than counting this tick against a
    ; budget that started before any of this data showed up.
    mov byte [tcp_retry], 0
    mov byte [tcp_wait_ticks], TCP_ROUND_SECS
    jmp .de_w2
.de_tick2_nodata:
    dec byte [tcp_wait_ticks]
    jns .de_w2                  ; still budget left this round - keep polling
    cmp byte [tcp_retry], TCP_MAX_RETRIES
    jae .de_timeout
    inc byte [tcp_retry]
    mov byte [tcp_wait_ticks], TCP_ROUND_SECS
    lea rsi, [tcp_tx_buf]
    mov ecx, r15d
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_PSH | TCP_FLAG_ACK
    call tcp_send_segment
    jc .de_sendfail
    call rtc_sec_now
    mov r14d, eax
    jmp .de_w2

.de_reply:
    mov qword [tcp_err_msg], 0
    ; advance seq + FIN
    mov eax, [tcp_cur_seq]
    add eax, r15d
    mov [tcp_cur_seq], eax
    xor rsi, rsi
    xor ecx, ecx
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_FIN | TCP_FLAG_ACK
    call tcp_send_segment
    clc
    jmp .de_out

.de_sendfail:
    cmp byte [nic_last_fail_reason], 1
    je .de_sendfail_noreply
    mov rsi, msg_tcp_sendfail
    mov [tcp_err_msg], rsi
    mov al, ATTR_ERROR
    call print_string_attr
    stc
    jmp .de_out
.de_sendfail_noreply:
    mov rsi, msg_tcp_sendfail_noreply
    mov [tcp_err_msg], rsi
    mov al, ATTR_ERROR
    call print_string_attr
    stc
    jmp .de_out
.de_unresolved:
    mov rsi, msg_http_unresolved
    mov [tcp_err_msg], rsi
    mov al, ATTR_ERROR
    call print_string_attr
    stc
    jmp .de_out
.de_cancel:
    mov byte [kill_flag], 0
    mov rsi, msg_http_cancelled
    mov [tcp_err_msg], rsi
    mov al, [cur_normal_attr]
    call print_string_attr
    stc
    jmp .de_out
.de_reset:
    mov rsi, msg_tcp_reset
    mov [tcp_err_msg], rsi
    mov al, ATTR_ERROR
    call print_string_attr
    stc
    jmp .de_out
.de_timeout:
    cmp dword [tcp_rx_len], 0
    jne .de_reply
    mov rsi, msg_tcp_timeout
    mov [tcp_err_msg], rsi
    mov al, ATTR_ERROR
    call print_string_attr
    stc
    jmp .de_out
.de_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- find HTTP headers end (CRLF CRLF) in tcp_rx_buf ----
; Returns: rax = ptr into tcp_rx_buf past the blank line (body start),
;          ecx = body length remaining.
;          CF=1 if no body found.
http_find_body:
    push rbx
    push rdi
    push rsi
    push rdx

    mov dword [http_body_len], 0
    lea rsi, [tcp_rx_buf]
    mov ecx, [tcp_rx_len]
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
    ; body length = (tcp_rx_buf + tcp_rx_len) - rax
    mov ecx, [tcp_rx_len]
    lea rdx, [tcp_rx_buf]
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

; ============================================================
; cmd_take: "take <url> <file>"
;     HTTP/1.0 GET from URL, save response body to a file.
; ============================================================
cmd_take:
    cmp byte [nic_present], 0
    je .no_nic
    cmp byte [arg1_buf], 0
    je .usage
    cmp byte [arg2_buf], 0
    je .usage

    lea rsi, [arg1_buf]
    call http_parse_url
    jc .bad_url

    call http_build_get
    mov [tcp_tx_len], eax

    mov rsi, msg_take_getting
    call print_string
    lea rsi, [http_path_buf]
    call print_string
    mov rsi, msg_take_from
    call print_string
    lea rsi, [http_host_buf]
    call print_string
    mov rsi, msg_nl
    call print_string

    call tcp_do_exchange
    jc .done

    ; find body in response
    call http_find_body
    jc .no_body

    ; rax = body ptr in tcp_rx_buf, ecx = body len
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
    mov rsi, msg_take_createfail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .done

.tk_overwrite:
    mov r12, rax

.tk_do_write:
    ; http_rx_buf holds the body (http_body_len bytes). Text bodies are
    ; written with fs_write_file; a body containing embedded NUL bytes is
    ; binary (e.g. a compiled .run program) and must go through
    ; fs_write_binary_file or it gets truncated at the first NUL.
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
    mov rsi, msg_take_saved
    call print_string
    mov rsi, arg2_buf
    call print_string
    mov rsi, msg_nl
    call print_string
    jmp .done

.no_body:
    mov rsi, msg_take_nobody
    mov al, [cur_normal_attr]
    call print_string_attr
    jmp .done

.bad_path:
    mov rsi, msg_take_badpath
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .done

.bad_url:
    mov rsi, msg_take_badurl
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.usage:
    mov rsi, msg_take_usage
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
; cmd_give: "give <url> <file>"
;     Reads local file, HTTP/1.0 POST to URL, prints reply headers.
; ============================================================
cmd_give:
    cmp byte [nic_present], 0
    je .no_nic
    cmp byte [arg1_buf], 0
    je .usage
    cmp byte [arg2_buf], 0
    je .usage

    lea rsi, [arg1_buf]
    call http_parse_url
    jc .bad_url

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

    mov rsi, msg_give_posting
    call print_string
    lea rsi, [http_path_buf]
    call print_string
    mov rsi, msg_give_to
    call print_string
    lea rsi, [http_host_buf]
    call print_string
    mov rsi, msg_nl
    call print_string

    call tcp_do_exchange
    jc .gv_done

    ; print reply (up to 512 chars)
    lea rsi, [tcp_rx_buf]
    mov ecx, [tcp_rx_len]
    test ecx, ecx
    jz .gv_nobody
    cmp ecx, 512
    jbe .gv_prn
    mov ecx, 512
    mov byte [tcp_rx_buf + rcx], 0
.gv_prn:
    lea rsi, [tcp_rx_buf]
    call print_string
    mov rsi, msg_nl
    call print_string
    jmp .gv_done
.gv_nobody:
    mov rsi, msg_give_noreply
    mov al, [cur_normal_attr]
    call print_string_attr
.gv_done:
    ret

.nofile:
    mov rsi, msg_give_nofile
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.bad_path:
    mov rsi, msg_take_badpath
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.bad_url:
    mov rsi, msg_take_badurl
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.usage:
    mov rsi, msg_give_usage
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.no_nic:
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    ret
