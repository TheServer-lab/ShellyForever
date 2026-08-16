; ============================================================
; tcp.asm -- minimal polled TCP engine (Milestone C)
;
; A deliberately tiny TCP client: 3-way handshake (SYN -> SYN-ACK ->
; ACK), seq/ack tracking, one retransmit per wait phase, a single
; send + receive of up to TCP_PAYLOAD_MAX bytes, and Esc-cancellable
; waits. This is the foundation for Milestone D's HTTP take/give.
;
; Entry points:
; tcp_send_segment build + transmit one segment (seq/ack from
; tcp_cur_seq / tcp_cur_ack)
; tcp_handle_segment called from handle_ipv4 for IP_PROTO_TCP;
; rsi = TCP header ptr inside nic_rx_frame
; cmd_tcp "tcp <host> <port> [payload]" shell command
;
; All state lives in the data area at the end of kernel.asm (tcp_*),
; declared separately so the module here stays pure code.
; ============================================================
TCP_PAYLOAD_MAX equ 1536 ; fits inside net_build_buf (4096 build area) and
                              ; nic_tx_buf (2KB): frame = 34 + 20 + 1536 = 1590 < 2048.
                              ; This is a SEND-side limit only (one segment has to
                              ; fit in one Ethernet frame) - see TCP_RX_BUF_SIZE
                              ; below for why the receive side can't reuse it.
; TCP_RX_BUF_SIZE -- capacity of tcp_rx_buf, the landing buffer tcp_handle_segment
; appends incoming payload into before tls_pump drains it into tls_rx_buf (16KB).
; This used to just be TCP_PAYLOAD_MAX (1536), which is fine for cmd_tcp's small
; test replies but not for a real TLS handshake: netpoll() drains every frame
; currently queued from the NIC in one call, invoking tcp_handle_segment for
; each, and tls_pump only runs once *after* netpoll returns. A server's
; encrypted flight (EncryptedExtensions + Certificate + CertificateVerify +
; Finished - routinely several KB for a real cert chain) commonly arrives as a
; burst of several back-to-back segments before we ever get a chance to pump.
; Once more than TCP_PAYLOAD_MAX-1 bytes piled up, tcp_handle_segment's
; "buffer full" path silently dropped the remainder while STILL acknowledging
; it as received (see the ack-anyway comment below) - the server believed we
; got everything and never resent it, so the truncated TLS record could never
; complete and tls_wait_for_record spun until the final timeout. Give the
; landing buffer the same headroom as tls_rx_buf so a whole flight fits
; between polls.
TCP_RX_BUF_SIZE equ 16384
; Wait budget for SYN-ACK / reply waits. A SYN (or a data segment) has to
; make a real round trip to a host out past the gateway - unlike ARP/DHCP,
; which only ever talk to something on the local segment. The old code gave
; up after one whole-second tick plus a single immediate retransmit (~1-2s
; total), which is nowhere near enough for a real WAN round trip and made
; perfectly healthy connections report "timed out" before a reply had any
; chance to arrive. Mirror nic_arp_resolve's fix: a multi-second budget per
; round, several resend rounds before finally giving up.
TCP_ROUND_SECS equ 5 ; ~5-6s of continuous polling per round
TCP_MAX_RETRIES equ 3 ; up to 3 retransmits (4 sends total) per phase
TCP_FLAG_FIN equ 0x01
TCP_FLAG_SYN equ 0x02
TCP_FLAG_RST equ 0x04
TCP_FLAG_PSH equ 0x08
TCP_FLAG_ACK equ 0x10
; ---- 32-bit big-endian (wire order) helpers ----
; tcp_load_be32: rsi = ptr -> eax = big-endian dword as a host value.
tcp_load_be32:
    movzx eax, byte [rsi]
    shl eax, 8
    movzx edx, byte [rsi+1]
    or eax, edx
    shl eax, 8
    movzx edx, byte [rsi+2]
    or eax, edx
    shl eax, 8
    movzx edx, byte [rsi+3]
    or eax, edx
    ret
; tcp_store_be32: rdi = ptr, eax = host value -> stores big-endian dword.
tcp_store_be32:
    push rdx
    mov edx, eax
    shr edx, 24
    mov [rdi], dl
    mov edx, eax
    shr edx, 16
    mov [rdi+1], dl
    mov edx, eax
    shr edx, 8
    mov [rdi+2], dl
    mov [rdi+3], al
    pop rdx
    ret
; net_tcp_checksum: rsi = TCP segment ptr, ecx = segment len, r8d = src IP,
; r9d = dst IP -> ax = one's-complement checksum. Same pseudo-header trick
; as net_udp_checksum (12-byte pseudo header + segment with the checksum
; field zeroed), but with protocol byte 0x06 and the full TCP length.
net_tcp_checksum:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    mov r10, rsi
    mov r11d, ecx
    ; Pseudo-header scratch lives at +2048, not +1536: at TCP_PAYLOAD_MAX the
    ; segment is 1556 bytes (1536 payload + 20 header), and the old +1536
    ; destination (effectively +1548 after the 12-byte pseudo header) started
    ; INSIDE that still-unread 0..1556 source range - rep movsb was reading
    ; bytes it had already overwritten a few iterations earlier, silently
    ; corrupting the checksum input for any large record (a full-size TLS
    ; Certificate/ClientHello segment, for instance). +2048 puts the
    ; destination safely past any segment this buffer can hold
    ; (net_build_buf is 4096 bytes; 2048+12+1556 = 3616 still fits).
    lea rdi, [net_build_buf + 2048]
    mov eax, r8d
    mov [rdi], eax
    mov eax, r9d
    mov [rdi+4], eax
    mov byte [rdi+8], 0
    mov byte [rdi+9], 0x06
    mov ax, r11w
    rol ax, 8
    mov [rdi+10], ax
    lea rdi, [net_build_buf + 2048 + 12]
    mov rsi, r10
    mov ecx, r11d
    rep movsb
    mov word [net_build_buf + 2048 + 12 + 16], 0 ; zero the checksum field
    lea rsi, [net_build_buf + 2048]
    mov ecx, r11d
    add ecx, 12
    call net_checksum16
    cmp ax, 0
    jne .ntc_ok
    mov ax, 0xFFFF
.ntc_ok:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
; ---- segment transmit ----
; tcp_send_segment: builds the TCP segment in net_build_buf and ships it.
; in: rsi = payload ptr (xor rsi,rsi / 0 for none)
; ecx = payload len (<= TCP_PAYLOAD_MAX)
; r8d = dst IP
; r9w = dst port
; r10w = src port
; r11w = TCP flags (low byte)
; seq/ack for the header come from tcp_cur_seq / tcp_cur_ack
; out: CF = 0 sent, CF = 1 TX failed
tcp_send_segment:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r9
    push r10
    push r11
    push r12
    push r13
    mov rbx, r8 ; dst IP (r8 is clobbered by the checksum/send calls)
    mov r12, rsi ; payload ptr
    mov r13d, ecx ; payload len
    lea rdi, [net_build_buf]
    mov ax, r10w
    mov byte [rdi], ah
    mov byte [rdi+1], al
    mov ax, r9w
    mov byte [rdi+2], ah
    mov byte [rdi+3], al
    lea rdi, [net_build_buf+4]
    mov eax, [tcp_cur_seq]
    call tcp_store_be32
    lea rdi, [net_build_buf+8]
    xor eax, eax
    test r11b, TCP_FLAG_ACK
    jz .tss_noack
    mov eax, [tcp_cur_ack]
.tss_noack:
    call tcp_store_be32
    mov byte [net_build_buf+12], 0x50 ; data offset 5 (20 bytes), reserved 0
    mov byte [net_build_buf+13], r11b ; flags
    mov word [net_build_buf+14], 0x0020 ; window = 8192, wire-order big-endian
                                          ; (bytes 0x20,0x00 -- x86 `mov word`
                                          ; stores the immediate little-endian
                                          ; in memory, so the byte-swapped
                                          ; literal is what actually lands as
                                          ; big-endian on the wire. seq/ack use
                                          ; tcp_store_be32 and the ports are
                                          ; swapped by hand above; this field
                                          ; was the one spot still storing a
                                          ; raw little-endian word, so every
                                          ; segment advertised a receive
                                          ; window of 0x0020 = 32 bytes
                                          ; instead of 0x2000 = 8192.
    mov word [net_build_buf+16], 0 ; checksum (computed below)
    mov word [net_build_buf+18], 0 ; urgent pointer
    test r12, r12
    jz .tss_nopayload
    test r13d, r13d
    jz .tss_nopayload
    lea rdi, [net_build_buf+20]
    mov rsi, r12
    mov rcx, r13
    rep movsb
.tss_nopayload:
    lea eax, [r13d + 20]
    mov r12d, eax ; total TCP segment length
    lea rsi, [net_build_buf]
    mov ecx, r12d
    mov r8d, [nic_ip]
    mov r9d, ebx
    call net_tcp_checksum
    ror ax, 8
    mov word [net_build_buf+16], ax
    lea rsi, [net_build_buf]
    mov ecx, r12d
    mov r8d, ebx
    mov r9b, IP_PROTO_TCP
    call nic_send_ip
    jc .tss_fail
    clc
    jmp .tss_out
.tss_fail:
    stc
.tss_out:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
; ---- receive path ----
; tcp_handle_segment: rsi = TCP header ptr inside nic_rx_frame. Only
; segments addressed to our (peer,my) port pair are considered. Updates
; the handshake state, ACKs received data, and copies payload into
; tcp_rx_buf. Preserves everything.
tcp_handle_segment:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r13, rsi ; TCP header base
    ; src port must match the peer's
    movzx eax, byte [r13]
    shl eax, 8
    movzx edx, byte [r13+1]
    or eax, edx
    cmp ax, [tcp_peer_port]
    jne .th_out
    ; dst port must match ours
    movzx eax, byte [r13+2]
    shl eax, 8
    movzx edx, byte [r13+3]
    or eax, edx
    cmp ax, [tcp_my_port]
    jne .th_out
    mov al, [r13+13]
    mov r14b, al ; flags byte
    test al, TCP_FLAG_RST
    jz .th_norst
    mov byte [tcp_rst_got], 1
    mov byte [tcp_state], 3
    jmp .th_out
.th_norst:
    cmp byte [tcp_state], 1
    je .th_syn_sent
    cmp byte [tcp_state], 2
    je .th_est
    jmp .th_out
.th_syn_sent:
    ; waiting for SYN-ACK
    test r14b, TCP_FLAG_SYN
    jz .th_out
    test r14b, TCP_FLAG_ACK
    jz .th_out
    lea rsi, [r13+4]
    call tcp_load_be32
    mov [tcp_peer_seq], eax
    inc eax
    mov [tcp_cur_ack], eax ; our ACK number = peer ISN + 1
    mov eax, [tcp_isn]
    inc eax
    mov [tcp_cur_seq], eax ; next outgoing seq = our ISN + 1
    lea rsi, [r13+8]
    call tcp_load_be32
    mov [tcp_last_ack], eax
    ; acknowledge the SYN-ACK (empty ACK)
    xor rsi, rsi
    xor ecx, ecx
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_ACK
    call tcp_send_segment
    mov byte [tcp_state], 2
    jmp .th_out
.th_est:
    test r14b, TCP_FLAG_ACK
    jz .th_est_data
    lea rsi, [r13+8]
    call tcp_load_be32
    mov [tcp_last_ack], eax
.th_est_data:
    ; payload length = IP total length - ihl - TCP header length
    xor ebx, ebx ; payload length, 0 unless a payload branch sets it
    movzx eax, byte [nic_rx_frame + 14 + 2]
    shl eax, 8
    movzx edx, byte [nic_rx_frame + 14 + 3]
    or eax, edx
    movzx edx, byte [nic_ihl]
    sub eax, edx
    jbe .th_est_fin
    movzx ecx, byte [r13+12]
    shr ecx, 4
    shl ecx, 2 ; TCP header length
    cmp ecx, eax
    jae .th_est_fin
    sub eax, ecx ; payload length
    jz .th_est_fin
    mov r15d, eax ; full payload length (for the ACK advance)
    mov ebx, r15d
    ; append capped at TCP_RX_BUF_SIZE (accumulate across segments)
    mov eax, [tcp_rx_len]
    mov edx, TCP_RX_BUF_SIZE - 1 ; reserve 1 byte for the NUL terminator
                                    ; written below (tcp_rx_buf is exactly
                                    ; TCP_RX_BUF_SIZE bytes, immediately
                                    ; followed by tcp_tx_buf - without this
                                    ; reservation a full-size response makes
                                    ; the terminator overwrite tcp_tx_buf[0])
    sub edx, eax ; free space left
    jbe .th_est_fin ; buffer full - ack anyway
    cmp r15d, edx
    jbe .th_append_all
    mov r15d, edx
.th_append_all:
    lea rdi, [tcp_rx_buf]
    add edi, [tcp_rx_len]
    lea rsi, [r13]
    add rsi, rcx
    mov ecx, r15d
    rep movsb
    add [tcp_rx_len], r15d
    mov edx, [tcp_rx_len]
    mov byte [tcp_rx_buf + rdx], 0 ; 0-terminate for print_string
.th_est_fin:
    ; a FIN ends the data phase
    test r14b, TCP_FLAG_FIN
    jz .th_est_nofin
    mov byte [tcp_fin_got], 1
    mov byte [tcp_rx_got], 1
.th_est_nofin:
    ; ACK only segments that advance the exchange (payload or FIN). Pure
    ; ACKs from the peer must NOT be echoed: our empty ACK carries the
    ; same old sequence number, and the peer answers each one - an ACK
    ; echo loop. ACK value = seg_seq + payload, +1 when FIN consumes a seq.
    test ebx, ebx
    jnz .th_est_ack
    test r14b, TCP_FLAG_FIN
    jz .th_out
.th_est_ack:
    lea rsi, [r13+4]
    call tcp_load_be32
    add eax, ebx
    test r14b, TCP_FLAG_FIN
    jz .th_est_ack1
    inc eax
.th_est_ack1:
    cmp eax, [tcp_cur_ack]
    jbe .th_est_acknoupd ; never let the ACK go backwards
    mov [tcp_cur_ack], eax
.th_est_acknoupd:
    xor rsi, rsi
    xor ecx, ecx
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_ACK
    call tcp_send_segment
    jmp .th_out
.th_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
; ---- helpers for the shell command ----
; tcp_parse_port: rsi = decimal string -> CF=0 and eax = port (1..65535),
; else CF=1.
tcp_parse_port:
    push rbx
    push rdx
    push rsi
    xor eax, eax
.tpp_loop:
    mov bl, [rsi]
    test bl, bl
    jz .tpp_done
    cmp bl, '0'
    jb .tpp_bad
    cmp bl, '9'
    ja .tpp_bad
    sub bl, '0'
    movzx edx, bl ; zero-extend the digit - ebx's upper bits are stale garbage
                    ; from whatever the caller last left in rbx, and using the
                    ; full ebx here corrupted the parsed port (e.g. "80" could
                    ; come out as some unrelated 5-digit value)
    imul eax, eax, 10
    add eax, edx
    cmp eax, 65535
    ja .tpp_bad
    inc rsi
    jmp .tpp_loop
.tpp_done:
    test eax, eax
    jz .tpp_bad
    clc
    jmp .tpp_out
.tpp_bad:
    stc
.tpp_out:
    pop rsi
    pop rdx
    pop rbx
    ret
; tcp_print_dec: eax = value -> prints it in decimal via putchar.
tcp_print_dec:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov ecx, 10
    lea rdi, [tcp_dec_buf]
    add rdi, 9
    mov byte [rdi], 0
.tpd_loop:
    xor edx, edx
    div ecx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test eax, eax
    jnz .tpd_loop
    mov rsi, rdi
    call print_string
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
; ---- the shell command ----
tcp_default_payload:
    db "GET / HTTP/1.0", 13, 10, 13, 10
TCP_DEFAULT_PAYLOAD_LEN equ ($ - tcp_default_payload)
; cmd_tcp: "tcp <host> <port> [payload]" - resolve, handshake, send a
; payload, wait for a reply, print it, close. Esc cancels any wait.
cmd_tcp:
    cmp byte [nic_present], 0
    je .no_nic
    cmp byte [arg1_buf], 0
    je .usage
    cmp byte [arg2_buf], 0
    je .usage
    lea rsi, [arg1_buf]
    call dns_query
    cmp eax, 0xFFFFFFFF
    je .unresolved
    mov [tcp_peer_ip], eax
    lea rsi, [arg2_buf]
    call tcp_parse_port
    jc .badport
    mov [tcp_peer_port], ax
    mov ax, [nic_ip_id]
    add ax, 0x4000
    mov [tcp_my_port], ax
    ; init the engine for a fresh connection
    mov byte [kill_flag], 0
    mov dword [tcp_isn], 0x00010000
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
    mov rsi, msg_tcp_connecting
    call print_string
    lea rsi, [tcp_peer_ip]
    call print_ip4
    mov rsi, msg_tcp_colon
    call print_string
    movzx eax, word [tcp_peer_port]
    call tcp_print_dec
    mov rsi, msg_nl
    call print_string
    ; send SYN
    xor rsi, rsi
    xor ecx, ecx
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_SYN
    call tcp_send_segment
    jc .sendfail
    call rtc_sec_now
    mov r13, rax
.tc_wait:
    call kbd_poll
    cmp byte [kill_flag], 0
    jne .tc_cancel
    call netpoll
    cmp byte [tcp_state], 2
    je .tc_connected
    cmp byte [tcp_rst_got], 0
    jne .tc_reset
    call rtc_sec_now
    cmp eax, r13d
    jne .tc_tick
    jmp .tc_wait
.tc_tick:
    mov r13, rax
    dec byte [tcp_wait_ticks]
    jns .tc_wait ; still budget left this round - keep polling
    cmp byte [tcp_retry], TCP_MAX_RETRIES
    jae .tc_timeout
    inc byte [tcp_retry]
    mov byte [tcp_wait_ticks], TCP_ROUND_SECS
    xor rsi, rsi
    xor ecx, ecx
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_SYN
    call tcp_send_segment
    jc .sendfail
    call rtc_sec_now
    mov r13, rax
    jmp .tc_wait
.tc_connected:
    mov rsi, msg_tcp_connected
    call print_string
    ; pick the payload: arg3_buf if given, else the default HTTP GET
    cmp byte [arg3_buf], 0
    je .tc_def_payload
    lea rsi, [arg3_buf]
    lea rdi, [tcp_tx_buf]
    xor ecx, ecx
.tc_payload_copy:
    mov al, [rsi]
    test al, al
    jz .tc_payload_done
    mov [rdi], al
    inc rsi
    inc rdi
    inc ecx
    cmp ecx, TCP_PAYLOAD_MAX
    jae .tc_payload_done
    jmp .tc_payload_copy
.tc_payload_done:
    mov [tcp_tx_len], ecx
    jmp .tc_have_payload
.tc_def_payload:
    lea rsi, [tcp_default_payload]
    lea rdi, [tcp_tx_buf]
    mov ecx, TCP_DEFAULT_PAYLOAD_LEN
    mov [tcp_tx_len], ecx
    rep movsb
.tc_have_payload:
    mov byte [tcp_rx_got], 0
    mov byte [tcp_fin_got], 0
    mov byte [tcp_retry], 0
    mov byte [tcp_wait_ticks], TCP_ROUND_SECS
    mov dword [tcp_last_ack], 0
    mov dword [tcp_rx_len], 0
    mov dword [tcp_rx_prev], 0
    lea rsi, [tcp_tx_buf]
    mov ecx, [tcp_tx_len]
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_PSH | TCP_FLAG_ACK
    call tcp_send_segment
    jc .sendfail
    mov rsi, msg_tcp_sent
    call print_string
    mov eax, [tcp_tx_len]
    call tcp_print_dec
    mov rsi, msg_tcp_bytes
    call print_string
    call rtc_sec_now
    mov r13, rax
.tc_wait2:
    call kbd_poll
    cmp byte [kill_flag], 0
    jne .tc_cancel
    call netpoll
    cmp byte [tcp_rx_got], 0
    jne .tc_reply
    cmp byte [tcp_rst_got], 0
    jne .tc_reset
    call rtc_sec_now
    cmp eax, r13d
    jne .tc_tick2
    jmp .tc_wait2
.tc_tick2:
    ; if data arrived and nothing new for a full second, the exchange is done
    cmp dword [tcp_rx_len], 0
    je .tc_tick2_nodata
    mov eax, [tcp_rx_prev]
    cmp eax, [tcp_rx_len]
    je .tc_reply
    mov eax, [tcp_rx_len]
    mov [tcp_rx_prev], eax
    ; fresh data landed this tick - the peer is alive, so give it a full
    ; new round of patience rather than counting this tick against a
    ; budget that started before any of this data showed up.
    mov byte [tcp_retry], 0
    mov byte [tcp_wait_ticks], TCP_ROUND_SECS
    jmp .tc_wait2
.tc_tick2_nodata:
    dec byte [tcp_wait_ticks]
    jns .tc_wait2 ; still budget left this round - keep polling
    cmp byte [tcp_retry], TCP_MAX_RETRIES
    jae .tc_timeout
    inc byte [tcp_retry]
    mov byte [tcp_wait_ticks], TCP_ROUND_SECS
    lea rsi, [tcp_tx_buf]
    mov ecx, [tcp_tx_len]
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_PSH | TCP_FLAG_ACK
    call tcp_send_segment
    jc .sendfail
    call rtc_sec_now
    mov r13, rax
    jmp .tc_wait2
.tc_reply:
    mov rsi, msg_tcp_recv
    call print_string
    mov eax, [tcp_rx_len]
    call tcp_print_dec
    mov rsi, msg_tcp_bytes
    call print_string
    lea rsi, [tcp_rx_buf]
    call print_string
    mov rsi, msg_nl
    call print_string
    ; advance our seq past the payload we sent, then FIN|ACK
    mov eax, [tcp_cur_seq]
    add eax, [tcp_tx_len]
    mov [tcp_cur_seq], eax
    xor rsi, rsi
    xor ecx, ecx
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_FIN | TCP_FLAG_ACK
    call tcp_send_segment
    ret
.tc_cancel:
    mov byte [kill_flag], 0
    mov rsi, msg_tcp_cancelled
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.tc_reset:
    mov rsi, msg_tcp_reset
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.tc_timeout:
    ; show whatever accumulated if anything arrived, otherwise report the timeout
    cmp dword [tcp_rx_len], 0
    jne .tc_reply
    mov rsi, msg_tcp_timeout
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.sendfail:
    ; nic_arp_resolve records WHY the send failed: a genuine raw-TX/hardware
    ; problem (reason 0) versus the broadcast going out fine but nobody ever
    ; answering it (reason 1). These are very different situations and used
    ; to be reported identically as a "TX error - link/chip problem", which
    ; is actively misleading when the NIC itself did nothing wrong.
    cmp byte [nic_last_fail_reason], 1
    je .sendfail_noreply
    mov rsi, msg_tcp_sendfail
    mov al, ATTR_ERROR
    call print_string_attr
    ; RTL8168: dump PCI Status + the failed TX descriptor + a fresh TPPoll
    ; readback, same diagnostic the dhcp wait path prints on send failure -
    ; this distinguishes a bus-level error (abort/parity) from the descriptor
    ; engine silently never touching the slot. Only meaningful for a genuine
    ; raw-TX failure, so skip it entirely for the no-reply case above.
    cmp byte [nic_driver_type], 2
    jne .sendfail_done
    call netdiag_dump_tx
    jmp .sendfail_done
.sendfail_noreply:
    mov rsi, msg_tcp_sendfail_noreply
    mov al, ATTR_ERROR
    call print_string_attr
.sendfail_done:
    ret
.unresolved:
    mov rsi, msg_net_unresolved
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.badport:
    mov rsi, msg_tcp_badport
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.usage:
    mov rsi, msg_tcp_usage
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.no_nic:
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    ret