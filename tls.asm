; ============================================================
;  tls.asm  --  minimal TLS 1.3 client (Phase 3)
;
;  A single-cipher TLS 1.3 client on top of tcp.asm's polled
;  engine: ClientHello builder, ServerHello parser, the RFC 8446
;  7.1 zero-PSK key schedule, ChaCha20-Poly1305 record layer
;  (TLS_CHACHA20_POLY1305_SHA256, the cipher suite chosen in
;  Phase 2), transcript tracking, ServerFinished verification,
;  ClientFinished, and application traffic secret derivation.
;  No certificate validation by design (see phases.txt scope) --
;  Certificate / CertificateVerify are parsed only enough to skip
;  them while keeping the transcript in sync.
;
;  Verified byte-for-byte against tls_ref.py (the Python oracle),
;  which is itself validated against real OpenSSL in both
;  directions. tls_ref.py `vect` emits the exact bytes this module
;  must reproduce; the WSL ELF harness replays those vectors
;  through the shimmed transport.
;
;  Kernel conventions (Phase 1 note in phases.txt): NO `section`
;  directives -- kernel.asm is a flat ORG'd binary and buffers are
;  `times N db 0`, not `resb`. Every function below saves and
;  restores every register it touches. CF=0 success / CF=1 failure
;  where noted. Big-endian wire values are written byte-by-byte.
;
;  Entry points:
;    tls_connect_and_handshake   rsi=hostname(null-term), dx=port.
;                                TCP connect (reusing tcp.asm's
;                                setup) + full TLS handshake.
;                                CF=0 ready, CF=1 error printed.
;    tls_handshake_after_connect assumes TCP established (tcp_state
;                                == 2, peer/ports/seq set), does the
;                                TLS handshake only. CF=0 ready.
;    tls_pump                    drain tcp_rx_buf into tls_rx_buf
;                                (call netpoll first in the kernel;
;                                the harness shims both).
;    tls_poll_single_frame       CF=0 + dl=ct, ecx=payload len,
;                                rsi=payload ptr (inside tls_rx_buf)
;                                when one full TLS record is present;
;                                CF=1 otherwise.
;    tls_record_encrypt / tls_record_decrypt  app-data record layer
;                                for Phase 4.
; ============================================================

; ---- optional test-harness tracing hooks ----
; Real kernel builds never define TLS_TRACE, so these expand to
; nothing and tls.asm has zero undefined symbols on its own. The
; Linux test harness %defines TLS_TRACE 1 before %including this
; file and provides its own harness_trace_pump/got/consume labels.
%macro TLS_TRACE_PUMP 0
%ifdef TLS_TRACE
    call harness_trace_pump
%endif
%endmacro
%macro TLS_TRACE_GOT 0
%ifdef TLS_TRACE
    call harness_trace_got
%endif
%endmacro
%macro TLS_TRACE_CONSUME 0
%ifdef TLS_TRACE
    call harness_trace_consume
%endif
%endmacro

; ---- wire constants (RFC 8446) ----
TLS_VERSION_13          equ 0x0304
LEGACY_VERSION          equ 0x0303
SUITE_CHACHA20_POLY1305 equ 0x1303
GROUP_X25519            equ 0x001D

CT_CHANGE_CIPHER_SPEC   equ 20
CT_ALERT                equ 21
CT_HANDSHAKE            equ 22
CT_APPLICATION_DATA     equ 23

HS_CLIENT_HELLO         equ 1
HS_SERVER_HELLO         equ 2
HS_ENCRYPTED_EXTENSIONS equ 8
HS_CERTIFICATE          equ 11
HS_CERTIFICATE_VERIFY   equ 15
HS_FINISHED             equ 20

HASH_LEN    equ 32
AEAD_KEY_LEN equ 32
AEAD_IV_LEN equ 12
AEAD_TAG_LEN equ 16

; ============================================================
;  small wire helpers
; ============================================================
; store_be16: rdi = dst, ax = value (writes 2 bytes, advances rdi)
tls_store_be16:
    mov byte [rdi], ah
    mov byte [rdi+1], al
    add rdi, 2
    ret

; store_be24: rdi = dst, eax = value (writes 3 bytes, advances rdi)
tls_store_be24:
    mov byte [rdi+2], al
    shr eax, 8
    mov byte [rdi+1], al
    shr eax, 8
    mov byte [rdi], al
    add rdi, 3
    ret

; ============================================================
;  TLS record encryption (TLS_CHACHA20_POLY1305_SHA256)
;  rdi = key(32), rsi = iv(12), rdx = seq, rcx = content_type,
;  r8 = payload ptr, r9 = payload len, r10 = out buf
;  (needs 5 + len + 1 + 16 bytes). Returns eax = record length.
; ============================================================
tls_record_encrypt:
    ; NOTE: rax is NOT saved/restored here -- this routine returns its
    ; result in eax (record length), so pushing/popping rax would
    ; clobber the return value with the caller's stale rax right
    ; before ret. Every other touched register still follows the
    ; save-everything convention.
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi              ; key
    mov r13, rsi              ; iv
    mov r14, r10              ; out
    mov r15, rdx              ; seq
    movzx eax, cl             ; content_type
    mov [tls_ct_byte], al

    ; ---- inner = payload || ct (1 byte), built in tls_plain ----
    lea rdi, [tls_plain]
    mov rsi, r8
    mov rcx, r9
    rep movsb
    mov al, [tls_ct_byte]
    mov [tls_plain + r9], al
    lea eax, [r9 + 1]         ; inner_len = len + 1
    mov [tls_inner_len], eax

    ; ---- total record length = inner_len + 16 (tag) ----
    mov eax, [tls_inner_len]
    add eax, AEAD_TAG_LEN
    mov [tls_total_len], eax

    ; ---- nonce = iv XOR (00000000 || u64be(seq)) ----
    lea rdi, [tls_nonce_buf]
    mov rsi, r13
    mov ecx, 4
    rep movsb                 ; nonce[0..3] = iv[0..3]
    ; u64be(seq) into tls_seq_be (high bytes 0 for seq < 2^32)
    lea rdi, [tls_seq_be]
    mov rax, r15
    mov byte [rdi+7], al
    shr rax, 8
    mov byte [rdi+6], al
    shr rax, 8
    mov byte [rdi+5], al
    shr rax, 8
    mov byte [rdi+4], al
    shr rax, 8
    mov byte [rdi+3], al
    shr rax, 8
    mov byte [rdi+2], al
    shr rax, 8
    mov byte [rdi+1], al
    shr rax, 8
    mov byte [rdi+0], al
    ; nonce[4..11] = iv[4..11] XOR seq_be
    xor ecx, ecx
.tls_nc_xor:
    mov al, [r13 + 4 + rcx]      ; iv[4+i]
    mov dl, [tls_seq_be + rcx]   ; seq be byte i
    xor al, dl
    mov [tls_nonce_buf + 4 + rcx], al
    inc rcx
    cmp rcx, 8
    jne .tls_nc_xor

    ; ---- aad = 17 03 03 u16(total_len) ----
    lea rdi, [tls_aad_buf]
    mov byte [rdi], CT_APPLICATION_DATA
    mov byte [rdi+1], 0x03
    mov byte [rdi+2], 0x03
    mov eax, [tls_total_len]
    mov byte [rdi+3], ah
    mov byte [rdi+4], al

    ; ---- header at out: 17 03 03 u16(total_len) ----
    mov rdi, r14
    mov byte [rdi], CT_APPLICATION_DATA
    mov byte [rdi+1], 0x03
    mov byte [rdi+2], 0x03
    mov eax, [tls_total_len]
    mov byte [rdi+3], ah
    mov byte [rdi+4], al

    ; ---- encrypt ----
    ; chacha20_poly1305_encrypt:
    ;   rdi=ct_out, rsi=tag_out, rdx=pt, rcx=pt_len, r8=aad, r9=aad_len,
    ;   push nonce, push key, call (ret 16)
    lea rdi, [r14 + 5]                 ; ct_out
    lea rsi, [r14 + 5]                 ; tag_out = ct_out + inner_len
    mov eax, [tls_inner_len]
    add rsi, rax
    lea rdx, [tls_plain]
    mov ecx, [tls_inner_len]
    lea r8, [tls_aad_buf]
    mov r9d, 5
    lea rax, [tls_nonce_buf]
    push rax
    mov rax, r12
    push rax
    call chacha20_poly1305_encrypt

    ; total record len = 5 + inner_len + 16
    mov eax, [tls_inner_len]
    add eax, 21
    pop r15
    pop r14
    pop r13
    pop r12
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
;  TLS record decryption
;  rdi = key(32), rsi = iv(12), rdx = seq, rcx = record payload
;  ptr (after the 5-byte header), r8 = ct len (incl 16-byte tag),
;  r9 = out plaintext buf.
;  CF=0: eax = inner len (excl ct byte), dl = inner content type.
;  CF=1: auth failure.
; ============================================================
tls_record_decrypt:
    ; NOTE: rax is NOT saved/restored here -- CF=0 returns eax = inner
    ; len, so a push/pop rax pair would clobber that with the caller's
    ; stale rax right before ret (same hazard as tls_record_encrypt).
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi              ; key
    mov r13, rsi              ; iv
    mov r14, rcx              ; payload ptr
    mov r15, r9               ; out
    mov rbx, r8               ; stash ct_len(incl tag) -- r8 gets
                               ; reused as the AEAD call's aad_len arg
                               ; below, so it can't be read back after
    ; rdx = seq

    ; ---- reject a record shorter than the AEAD tag ----
    ; A peer (malicious, or just buggy/lossy) can send an application_data
    ; or handshake-phase record whose declared length is < AEAD_TAG_LEN
    ; (even 0 -- tls_poll_single_frame only requires the 5-byte header
    ; plus that many payload bytes, it never enforces a minimum). Without
    ; this check, "lea rdx, [r8 - AEAD_TAG_LEN]" below wraps r8=0..15
    ; around to a huge 64-bit value (e.g. r8=0 -> rdx=0xFFFFFFFFFFFFFFF0),
    ; which is then handed to chacha20_poly1305_decrypt as ct_len -- an
    ; effectively unbounded read past tls_frame_buf/tls_plain that
    ; corrupts memory well beyond this module. That's consistent with
    ; the illegal-instruction/triple-fault crash seen in practice: this
    ; kernel installs no IDT (see kernel.asm header), so any resulting
    ; fault is unrecoverable.
    cmp rbx, AEAD_TAG_LEN
    jb .tls_rd_fail

    ; ---- nonce = iv XOR (00000000 || u64be(seq)) ----
    lea rdi, [tls_nonce_buf]
    mov rsi, r13
    mov ecx, 4
    rep movsb
    lea rdi, [tls_seq_be]
    mov rax, rdx
    mov byte [rdi+7], al
    shr rax, 8
    mov byte [rdi+6], al
    shr rax, 8
    mov byte [rdi+5], al
    shr rax, 8
    mov byte [rdi+4], al
    shr rax, 8
    mov byte [rdi+3], al
    shr rax, 8
    mov byte [rdi+2], al
    shr rax, 8
    mov byte [rdi+1], al
    shr rax, 8
    mov byte [rdi+0], al
    xor ecx, ecx
.tls_rd_nc:
    mov al, [r13 + 4 + rcx]
    mov dl, [tls_seq_be + rcx]
    xor al, dl
    mov [tls_nonce_buf + 4 + rcx], al
    inc rcx
    cmp rcx, 8
    jne .tls_rd_nc

    ; ---- aad = 17 03 03 u16(r8) ----
    lea rdi, [tls_aad_buf]
    mov byte [rdi], CT_APPLICATION_DATA
    mov byte [rdi+1], 0x03
    mov byte [rdi+2], 0x03
    mov rax, r8
    mov byte [rdi+3], ah
    mov byte [rdi+4], al

    ; ---- decrypt ----
    ; chacha20_poly1305_decrypt:
    ;   rdi=pt_out, rsi=ct, rdx=ct_len, rcx=aad, r8=aad_len,
    ;   r9=tag16, push nonce, push key, call (ret 16), CF=1 fail
    mov rdi, r15                     ; pt_out
    mov rsi, r14                     ; ct
    lea rdx, [r8 - AEAD_TAG_LEN]     ; ct_len (without tag)
    lea rcx, [tls_aad_buf]
    mov r8d, 5
    lea r9, [r14]
    add r9, rdx                      ; tag = payload + ct_len
    lea rax, [tls_nonce_buf]
    push rax
    mov rax, r12
    push rax
    call chacha20_poly1305_decrypt
    jc .tls_rd_fail

    ; ---- scan from end for the inner content type byte ----
    ; NOTE: must use rbx (the ct_len incl tag stashed at entry), not r8 --
    ; r8 was clobbered to the AEAD call's aad_len (5) above.
    mov rdx, r15
    add rdx, rbx
    sub rdx, AEAD_TAG_LEN            ; rdx = end of plaintext
.tls_rd_scan:
    dec rdx
    mov al, [rdx]
    test al, al
    jz .tls_rd_scan
    ; rdx points at content type byte
    mov r10d, edx
    sub r10d, r15d                   ; eax = inner len (index of ct byte)
    mov eax, r10d
    mov dl, [rdx]
    mov [tls_last_ct], dl
    clc
    jmp .tls_rd_out
.tls_rd_fail:
    stc
.tls_rd_out:
    pop r15
    pop r14
    pop r13
    pop r12
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
;  tls_build_client_hello -- rsi = hostname ptr (null-term)
;  Builds the full ClientHello handshake message into tls_ch_buf,
;  stores its length in tls_ch_len. Uses tls_client_random,
;  tls_session_id, tls_client_pub.
; ============================================================
tls_build_client_hello:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    ; hostname length
    xor r14d, r14d
.tls_bch_hlen:
    mov al, [rsi + r14]
    test al, al
    jz .tls_bch_hlen_done
    inc r14d
    cmp r14d, 128
    jb .tls_bch_hlen
.tls_bch_hlen_done:
    mov [tls_host_len], r14d

    ; body builder pointer
    lea rdi, [tls_ch_buf + 4]        ; skip handshake header for now

    ; legacy_version 0x0303
    mov ax, LEGACY_VERSION
    call tls_store_be16

    ; client_random[32]
    lea rsi, [tls_client_random]
    mov ecx, 32
    rep movsb

    ; session_id: u8(32) + 32 bytes
    mov byte [rdi], 32
    inc rdi
    lea rsi, [tls_session_id]
    mov ecx, 32
    rep movsb

    ; cipher_suites: u16(2) + u16(0x1303)
    mov ax, 2
    call tls_store_be16
    mov ax, SUITE_CHACHA20_POLY1305
    call tls_store_be16

    ; compression methods: u8(1) + u8(0)
    mov byte [rdi], 1
    inc rdi
    mov byte [rdi], 0
    inc rdi

    ; ---- extensions ----
    ; ext header: u16(ext_len) -- patched at the end
    lea r13, [rdi + 2]               ; r13 = start of ext data
    lea r15, [tls_ext_start]         ; record where ext data begins
    mov [r15], r13
    add rdi, 2                       ; skip past the ext_len placeholder
                                      ; (patched in below once the real
                                      ; length is known)

    ; 1. server_name (SNI): id 0x0000
    ;   u16(0x0000) + u16(5+hostlen) + u16(3+hostlen) + u8(0)
    ;   + u16(hostlen) + hostname   (matches tls_ref / RFC 6066)
    mov ax, 0x0000
    call tls_store_be16
    mov eax, [tls_host_len]
    add eax, 5
    call tls_store_be16              ; ext data len
    mov eax, [tls_host_len]
    add eax, 3
    call tls_store_be16              ; server_name_list len
    mov byte [rdi], 0                ; name_type = host_name
    inc rdi
    mov ax, [tls_host_len]
    call tls_store_be16              ; name len
    mov rsi, [rsp + 40]              ; original rsi arg (hostname ptr)
    mov ecx, [tls_host_len]
    rep movsb

    ; 2. supported_groups: id 0x000A
    mov ax, 0x000A
    call tls_store_be16
    mov ax, 4
    call tls_store_be16              ; ext data len
    mov ax, 2
    call tls_store_be16              ; vector len
    mov ax, GROUP_X25519
    call tls_store_be16

    ; 3. signature_algorithms: id 0x000D
    mov ax, 0x000D
    call tls_store_be16
    mov ax, 14
    call tls_store_be16              ; ext data len = u16(12)+12
    mov ax, 12
    call tls_store_be16              ; vector len
    lea rsi, [tls_sig_algs]
    mov ecx, 12
    rep movsb

    ; 4. supported_versions: id 0x002B
    mov ax, 0x002B
    call tls_store_be16
    mov ax, 3
    call tls_store_be16              ; ext data len = u8(2)+u16
    mov byte [rdi], 2
    inc rdi
    mov ax, TLS_VERSION_13
    call tls_store_be16

    ; 5. key_share: id 0x0033
    mov ax, 0x0033
    call tls_store_be16
    mov ax, 38
    call tls_store_be16              ; ext data len = u16(36)+2+2+32
    mov ax, 36
    call tls_store_be16              ; client_shares vector len
    mov ax, GROUP_X25519
    call tls_store_be16
    mov ax, 32
    call tls_store_be16
    lea rsi, [tls_client_pub]
    mov ecx, 32
    rep movsb

    ; 6. application_layer_protocol_negotiation (ALPN): id 0x0010
    ;   u16(0x0010) + u16(ext_data_len=11) + u16(list_len=9) + u8(8) + "http/1.1"
    ; A real client (browser, curl, wget) sends this on essentially every
    ; TLS connection; going without it is an unusual fingerprint some
    ; edges use to silently drop scripted-looking clients rather than
    ; sending back an alert. We only ever speak HTTP/1.1, so offer just
    ; that one protocol.
    mov ax, 0x0010
    call tls_store_be16
    mov ax, 11
    call tls_store_be16              ; ext data len = u16(list_len)+list
    mov ax, 9
    call tls_store_be16              ; protocol_name_list len = 1+8
    mov byte [rdi], 8
    inc rdi
    lea rsi, [tls_alpn_http11]
    mov ecx, 8
    rep movsb

    ; ---- patch server_name ext length ----
    ; server_name ext starts at r13 (its id), data begins r13+4.
    ; ext data len = rdi - (r13+4) - (data len fields...) = rdi - r13 - 4
    ; but we already wrote the "data length" field as 3+hostlen before
    ; the name type. The overall ext length field (the one after the
    ; 2-byte id) is data_len + 2 (vector u16) ... The tls_ref encoding:
    ;   u16(0x0000) + u16(5+hostlen) + u16(3+hostlen) + u8(0) + u16(hostlen) + hostname
    ; The "5+hostlen" is ext_data_len = (3+hostlen) + 2. And "3+hostlen"
    ; is server_name_list length = u8(0)+u16(hostlen)+hostname = 3+hostlen.
    ; We wrote u16(3+hostlen) as the list length field correctly, and
    ; u16(5+hostlen) as ext data len. That matches tls_ref.
    ; No patch needed: values were written correctly above.

    ; ---- patch ext block length ----
    ; ext_len = rdi - ext_data_start (r13)
    mov rax, rdi
    mov rbx, [r15]
    sub rax, rbx                    ; ext data length
    mov [tls_ext_len], eax
    ; write u16(ext_len) at the ext length field (r13 - 2)
    lea rsi, [r13 - 2]
    mov eax, [tls_ext_len]
    mov byte [rsi], ah
    mov byte [rsi+1], al

    ; ---- patch handshake header ----
    ; body_len = rdi - tls_ch_buf - 4
    mov rax, rdi
    lea rbx, [tls_ch_buf]
    sub rax, rbx
    sub rax, 4
    mov [tls_ch_body_len], eax
    mov byte [tls_ch_buf], HS_CLIENT_HELLO
    ; u24(len): buf[1] high, buf[2] mid, buf[3] low
    mov rdx, rax
    shr rdx, 16
    mov byte [tls_ch_buf+1], dl
    mov rdx, rax
    shr rdx, 8
    mov byte [tls_ch_buf+2], dl
    mov rdx, rax
    mov byte [tls_ch_buf+3], dl
    ; total message length
    add rax, 4
    mov [tls_ch_len], eax

    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
;  tls_parse_server_hello -- rsi = SH handshake body ptr
;  (points at legacy_version, i.e. after the 4-byte handshake
;  header). Extracts server pubkey into tls_server_pub, checks the
;  suite. CF=1 on error.
; ============================================================
tls_parse_server_hello:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    ; legacy_version
    movzx eax, byte [rsi]
    shl eax, 8
    movzx edx, byte [rsi+1]
    or eax, edx
    cmp ax, LEGACY_VERSION
    jne .tls_psh_bad
    add rsi, 2
    ; random[32]
    add rsi, 32
    ; session_id
    movzx ecx, byte [rsi]
    inc rsi
    add rsi, rcx
    ; cipher_suite
    movzx eax, byte [rsi]
    shl eax, 8
    movzx edx, byte [rsi+1]
    or eax, edx
    cmp ax, SUITE_CHACHA20_POLY1305
    jne .tls_psh_bad
    mov [tls_suite], ax
    add rsi, 2
    ; legacy_compression_method (must be 0)
    movzx eax, byte [rsi]
    test eax, eax
    jnz .tls_psh_bad
    inc rsi
    ; extensions
    movzx eax, byte [rsi]
    shl eax, 8
    movzx edx, byte [rsi+1]
    or eax, edx
    add rsi, 2
    lea r8, [rsi + rax]              ; end of ext block
    ; scan for key_share (0x0033)
.tls_psh_ext:
    cmp rsi, r8
    jae .tls_psh_nokeyshare
    ; need at least 4 bytes left in the ext block for the header itself
    lea r9, [rsi + 4]
    cmp r9, r8
    ja .tls_psh_bad
    movzx eax, byte [rsi]
    shl eax, 8
    movzx edx, byte [rsi+1]
    or eax, edx
    movzx ecx, byte [rsi+2]
    shl ecx, 8
    movzx edx, byte [rsi+3]
    or ecx, edx                      ; ext data len
    ; the extension's declared data must not run past the ext block --
    ; without this, a truncated/malformed ServerHello could send rsi (and
    ; the key_share reads below) past the extensions block's real end.
    lea r9, [rsi + 4]
    add r9, rcx
    cmp r9, r8
    ja .tls_psh_bad
    cmp ax, 0x0033
    jne .tls_psh_next
    ; key_share ext: group(2) + keylen(2) + key(32) -- confirm the
    ; extension actually declared that much data before reading it
    cmp ecx, 36
    jb .tls_psh_bad
    movzx eax, byte [rsi+4]
    shl eax, 8
    movzx edx, byte [rsi+5]
    or eax, edx
    cmp ax, GROUP_X25519
    jne .tls_psh_bad
    movzx eax, byte [rsi+6]
    shl eax, 8
    movzx edx, byte [rsi+7]
    or eax, edx
    cmp ax, 32
    jne .tls_psh_bad
    lea rdi, [tls_server_pub]
    lea rsi, [rsi+8]
    mov ecx, 32
    rep movsb
    clc
    jmp .tls_psh_out
.tls_psh_next:
    add rsi, 4
    add rsi, rcx
    jmp .tls_psh_ext
.tls_psh_nokeyshare:
.tls_psh_bad:
    stc
.tls_psh_out:
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
;  tls_derive_secret -- RFC 8446 7.1 Derive-Secret
;  rdi = secret(32), rsi = label ptr, rdx = label len,
;  rcx = transcript hash(32), r8 = out(32)
;  = HKDF-Expand-Label(secret, label, transcript_hash, 32)
; ============================================================
tls_derive_secret:
    push r10
    push r9
    push r8
    push rcx
    push rdx
    push rsi
    push rdi
    ; hkdf_expand_label:
    ;   rdi=secret, rsi=label, edx=label len, rcx=context ptr,
    ;   r8d=context len, r9d=L, r10=out
    mov r10, r8
    mov r8d, HASH_LEN
    mov r9d, HASH_LEN
    call hkdf_expand_label
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop r8
    pop r9
    pop r10
    ret

; ============================================================
;  tls_traffic_key_iv -- rdi = traffic secret(32), r8 = key out(32),
;  r9 = iv out(12). Derives "key" and "iv" labels.
; ============================================================
tls_traffic_key_iv:
    push r10
    push r9
    push r8
    push rcx
    push rdx
    push rsi
    push rdi
    ; key
    mov r10, r8
    lea rsi, [tls_label_key]
    mov edx, 3
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, AEAD_KEY_LEN
    call hkdf_expand_label
    ; iv
    mov rdi, [rsp + 0]               ; original secret (saved rdi on stack)
    mov r10, [rsp + 40]              ; original r9 (iv out)
    lea rsi, [tls_label_iv]
    mov edx, 2
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, AEAD_IV_LEN
    call hkdf_expand_label
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop r8
    pop r9
    pop r10
    ret

; ============================================================
;  tls_finished_verify_data -- rdi = base key(32), rsi = transcript
;  hash(32), r8 = out(32)
;  = HMAC(HKDF-Expand-Label(base, "finished", "", 32), th)
; ============================================================
tls_finished_verify_data:
    push r8
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    ; finished_key
    mov r10, rdi
    ; hkdf_expand_label(secret, "finished", "", 0, 32, tls_finished_key)
    lea rdi, [tls_finished_key]
    push rdi
    mov rdi, r10
    lea rsi, [tls_label_finished]
    mov edx, 8
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, HASH_LEN
    mov r10, [rsp + 0]               ; tls_finished_key out
    call hkdf_expand_label
    pop rdi
    ; hmac_sha256: rdi=key, rcx=keylen, rsi=msg ptr, rdx=msglen, r8=out.
    ; rsi was clobbered above (set to the "finished" label ptr for the
    ; hkdf_expand_label call) -- must reload the original th ptr here,
    ; or this hashes the wrong message.
    lea rdi, [tls_finished_key]
    mov rcx, HASH_LEN
    mov rsi, [rsp + 16]               ; original rsi (th)
    mov rdx, HASH_LEN
    mov r8, [rsp + 40]               ; original r8 (out)
    call hmac_sha256
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop r8
    ret

; ============================================================
;  tls_key_schedule -- runs the RFC 8446 7.1 zero-PSK schedule.
;  Uses tls_ecdh_shared and tls_th_ch_sh (transcript hash of
;  ClientHello + ServerHello). Fills all tls_*_secret / traffic
;  secrets. Caller derives keys/ivs afterwards.
; ============================================================
tls_key_schedule:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10

    ; early_secret = HKDF-Extract(zeros, zeros)
    lea rdi, [tls_zero32]
    mov rcx, 32
    lea rsi, [tls_zero32]
    mov rdx, 32
    lea r8, [tls_early_secret]
    call hkdf_extract

    ; derived1 = Derive-Secret(early, "derived", Hash(""))
    lea rdi, [tls_early_secret]
    lea rsi, [tls_label_derived]
    mov edx, 7
    lea rcx, [tls_empty_hash]
    lea r8, [tls_derived1]
    call tls_derive_secret

    ; handshake_secret = HKDF-Extract(derived1, ecdh_shared)
    lea rdi, [tls_derived1]
    mov rcx, 32
    lea rsi, [tls_ecdh_shared]
    mov rdx, 32
    lea r8, [tls_hs_secret]
    call hkdf_extract

    ; c_hs / s_hs traffic secrets
    lea rdi, [tls_hs_secret]
    lea rsi, [tls_label_c_hs]
    mov edx, 12
    lea rcx, [tls_th_ch_sh]
    lea r8, [tls_c_hs_traffic]
    call tls_derive_secret

    lea rdi, [tls_hs_secret]
    lea rsi, [tls_label_s_hs]
    mov edx, 12
    lea rcx, [tls_th_ch_sh]
    lea r8, [tls_s_hs_traffic]
    call tls_derive_secret

    ; derived2 = Derive-Secret(hs, "derived", Hash(""))
    lea rdi, [tls_hs_secret]
    lea rsi, [tls_label_derived]
    mov edx, 7
    lea rcx, [tls_empty_hash]
    lea r8, [tls_derived2]
    call tls_derive_secret

    ; master_secret = HKDF-Extract(derived2, zeros)
    lea rdi, [tls_derived2]
    mov rcx, 32
    lea rsi, [tls_zero32]
    mov rdx, 32
    lea r8, [tls_master]
    call hkdf_extract

    pop r10
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
;  tls_transcript_append -- rsi = data, rcx = len. Appends to the
;  running transcript buffer (capped at TLS_TRANSCRIPT_MAX).
; ============================================================
tls_transcript_append:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    mov eax, [tls_transcript_len]
    cmp eax, TLS_TRANSCRIPT_MAX - 1
    jae .tls_ta_done
    mov edx, TLS_TRANSCRIPT_MAX
    sub edx, eax
    cmp ecx, edx
    ja .tls_ta_trunc
    lea rdi, [tls_transcript]
    add rdi, rax
    mov ebx, ecx                     ; stash length: rep movsb zeroes ecx
    rep movsb
    add [tls_transcript_len], ebx
    jmp .tls_ta_done
.tls_ta_trunc:
    mov ecx, edx
    lea rdi, [tls_transcript]
    add rdi, rax
    rep movsb
    mov dword [tls_transcript_len], TLS_TRANSCRIPT_MAX
.tls_ta_done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
;  tls_transcript_hash -- rdi = out (32 bytes). Computes sha256
;  over the running transcript.
; ============================================================
tls_transcript_hash:
    push rax
    push rcx
    push rsi
    push rdi
    mov rax, rdi                ; out
    lea rdi, [tls_transcript]   ; data
    mov ecx, [tls_transcript_len]
    mov rsi, rax                ; out
    call sha256_hash
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ============================================================
;  tls_pump -- drain tcp_rx_buf into tls_rx_buf stream.
;  Kernel: call netpoll first, then tls_pump. Harness: shims both.
; ============================================================
tls_pump:
    push rax
    push rcx
    push rsi
    push rdi
    mov eax, [tcp_rx_len]
    test eax, eax
    jz .tls_pump_done
    ; cap to remaining room in tls_rx_buf
    mov edx, TLS_RX_BUF_SIZE
    sub edx, [tls_rx_used]
    cmp eax, edx
    jbe .tls_pump_copy
    mov eax, edx
.tls_pump_copy:
    lea rdi, [tls_rx_buf]
    add edi, [tls_rx_used]           ; 32-bit add/zero-extend -- tls_rx_used
                                      ; is a dd; `add rdi,[tls_rx_used]` would
                                      ; read 8 bytes and pull in the following
                                      ; dword (tls_last_frame_len) as garbage
                                      ; upper bits once it's nonzero
    lea rsi, [tcp_rx_buf]
    mov ecx, eax
    rep movsb
    add [tls_rx_used], eax
    mov dword [tcp_rx_len], 0
.tls_pump_done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ============================================================
;  tls_poll_single_frame -- looks for one complete TLS record in
;  the tls_rx_buf stream. CF=0: dl=content type, ecx=payload len,
;  rsi=payload ptr (points into tls_rx_buf). CF=1: incomplete.
; ============================================================
tls_poll_single_frame:
    ; NOTE: rdx is NOT saved/restored here -- CF=0 returns dl = content
    ; type (set via `movzx edx, byte [tls_rx_buf]` below), so a
    ; push/pop rdx pair would clobber that with the caller's stale rdx
    ; right before ret. Same hazard tls_record_encrypt/decrypt hit with
    ; rax in Phase 3 (see phases.txt); this is the same class of bug,
    ; just found later because nothing exercised this routine's success
    ; path until Phase 4's tls_wait_for_record-driven receive loop --
    ; earlier tests all parsed record headers directly instead of going
    ; through tls_poll_single_frame.
    push rbx
    push rax
    mov eax, [tls_rx_used]
    cmp eax, 5
    jb .tls_psf_need
    ; length = u16(buf[3..4])
    movzx eax, byte [tls_rx_buf + 3]
    shl eax, 8
    movzx edx, byte [tls_rx_buf + 4]
    or eax, edx
    add eax, 5
    cmp [tls_rx_used], eax
    jb .tls_psf_need
    ; record complete: type + payload
    movzx edx, byte [tls_rx_buf]
    lea rsi, [tls_rx_buf + 5]
    sub eax, 5
    mov ecx, eax
    clc
    jmp .tls_psf_out
.tls_psf_need:
    stc
.tls_psf_out:
    pop rax
    pop rbx
    ret

; ============================================================
;  tls_consume_frame -- remove the front record from the stream.
;  rsi = payload ptr, ecx = payload len (as returned by
;  tls_poll_single_frame). Advances tls_rx_used.
; ============================================================
tls_consume_frame:
    push rax
    push rcx
    push rsi
    push rdi
    ; consumed = (payload ptr - rx_buf) + payload len  (header is included
    ; in the payload offset, which is always 5 for the front record)
    lea rax, [tls_rx_buf]
    mov rdx, rsi
    sub rdx, rax                     ; payload offset
    add rdx, rcx
    ; shift remaining stream left by consumed bytes
    mov eax, [tls_rx_used]
    cmp eax, edx
    jbe .tls_cf_empty
    sub eax, edx                     ; remaining
    lea rdi, [tls_rx_buf]
    lea rsi, [tls_rx_buf + rdx]
    mov ecx, eax
    rep movsb
    mov [tls_rx_used], eax
    jmp .tls_cf_done
.tls_cf_empty:
    mov dword [tls_rx_used], 0
.tls_cf_done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ============================================================
;  tls_handshake_after_connect -- TLS handshake only. Assumes:
;    tcp_state == 2 (established), tcp_peer_ip / tcp_peer_port /
;    tcp_my_port set, tcp_cur_seq / tcp_cur_ack set.
;  rsi = hostname (null-term). CF=0 ready, CF=1 error printed.
; ============================================================
tls_handshake_after_connect:
    push rax
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
    push r15

    mov r14, rsi                     ; hostname ptr

    ; ---- reset TLS stream state ----
    mov dword [tls_rx_used], 0
    mov dword [tls_transcript_len], 0
    mov qword [tls_wfr_resend_hook], 0

    ; ---- generate client random / session id / private key ----
    ; (rng_get64: rdi = 8-byte out; kernel uses RDRAND, harness stub)
    lea rdi, [tls_client_random]
    call rng_get64
    lea rdi, [tls_client_random + 8]
    call rng_get64
    lea rdi, [tls_client_random + 16]
    call rng_get64
    lea rdi, [tls_client_random + 24]
    call rng_get64

    lea rdi, [tls_session_id]
    call rng_get64
    lea rdi, [tls_session_id + 8]
    call rng_get64
    lea rdi, [tls_session_id + 16]
    call rng_get64
    lea rdi, [tls_session_id + 24]
    call rng_get64

    lea rdi, [tls_client_priv]
    call rng_get64
    lea rdi, [tls_client_priv + 8]
    call rng_get64
    lea rdi, [tls_client_priv + 16]
    call rng_get64
    lea rdi, [tls_client_priv + 24]
    call rng_get64

    ; ---- client pubkey = X25519(priv, basepoint9) ----
    lea rdi, [tls_client_pub]
    lea rsi, [tls_client_priv]
    lea rdx, [tls_basepoint9]
    call x25519_scalarmult

    ; ---- build + send ClientHello ----
    mov rsi, r14
    call tls_build_client_hello

    ; transcript += ch
    lea rsi, [tls_ch_buf]
    mov ecx, [tls_ch_len]
    call tls_transcript_append

    ; send CH as plaintext handshake record
    mov eax, [tcp_cur_seq]
    mov [tls_ch_seq], eax            ; remember for tls_resend_ch
    lea rsi, [tls_ch_buf]
    mov ecx, [tls_ch_len]
    mov rdx, CT_HANDSHAKE
    call tls_send_record
    jc .tls_ha_sendfail

    ; ---- read ServerHello record ----
    ; arm the retransmit hook: if this segment was dropped in transit, the
    ; server will never answer no matter how long we passively wait, so
    ; tls_wait_for_record needs to actually resend it once per round.
    mov qword [tls_wfr_resend_hook], tls_resend_ch
.tls_ha_sh_loop:
    call tls_wait_for_record
    jc .tls_ha_fail_wait
    cmp dl, CT_ALERT
    je .tls_ha_alert                 ; server told us exactly why -- show it
    cmp dl, CT_HANDSHAKE
    jne .tls_ha_sh_loop              ; skip CCS
    ; rsi = SH handshake msg (record payload), ecx = payload len
    mov r12, rsi                     ; save payload ptr
    ; got a real record -- disarm the hook regardless of what's in it, so
    ; a later timeout (e.g. in the encrypted-flight loop) doesn't keep
    ; resending a ClientHello the server has clearly already seen
    mov qword [tls_wfr_resend_hook], 0
    ; parse SH body (skip the 4-byte handshake header)
    lea rsi, [r12 + 4]
    call tls_parse_server_hello
    jc .tls_ha_fail_sh

    ; transcript += SH handshake message (the whole record payload)
    mov rsi, r12
    mov ecx, [tls_last_frame_len]
    call tls_transcript_append

    ; ---- transcript hash of CH + SH ----
    lea rdi, [tls_th_ch_sh]
    call tls_transcript_hash

    ; ---- ECDH shared secret ----
    lea rdi, [tls_ecdh_shared]
    lea rsi, [tls_client_priv]
    lea rdx, [tls_server_pub]
    call x25519_scalarmult

    ; ---- key schedule ----
    call tls_key_schedule

    ; ---- traffic keys ----
    lea rdi, [tls_s_hs_traffic]
    lea r8, [tls_s_hs_key]
    lea r9, [tls_s_hs_iv]
    call tls_traffic_key_iv
    lea rdi, [tls_c_hs_traffic]
    lea r8, [tls_c_hs_key]
    lea r9, [tls_c_hs_iv]
    call tls_traffic_key_iv

    ; ---- process encrypted server flight ----
    ; A handshake message (EncryptedExtensions / Certificate /
    ; CertificateVerify / Finished) is NOT guaranteed to fit inside a
    ; single TLS record -- RFC 8446 lets the sender split it across
    ; as many records as it likes, and real servers (e.g. GitHub's
    ; Fastly-fronted raw.githubusercontent.com, whose Certificate
    ; message carries a multi-KB chain) commonly do exactly that.
    ; tls_hsmsg_buf/tls_hsmsg_len accumulate decrypted plaintext
    ; across records so a message is only parsed once it's fully
    ; present, mirroring how tls_poll_single_frame already reassembles
    ; a TLS record out of multiple TCP segments -- this just does the
    ; same thing one layer up (records -> handshake messages).
    mov qword [tls_hs_seq], 0
    mov dword [tls_hsmsg_len], 0
    mov qword [tls_got_sfin], 0
.tls_ha_flight:
    call tls_wait_for_record
    jc .tls_ha_fail_wait
    cmp dl, CT_ALERT
    je .tls_ha_alert                 ; still-plaintext alert (rare here, but
                                      ; some servers bail before switching to
                                      ; encrypted records) -- show it instead
                                      ; of spinning until timeout
    cmp dl, CT_APPLICATION_DATA
    jne .tls_ha_flight                ; skip CCS etc
    ; rsi = ciphertext payload ptr, tls_last_frame_len = ct len (incl tag)
    mov r14, rsi                     ; save ct ptr
    ; decrypt: rdi=key, rsi=iv, rdx=seq, rcx=payload, r8=len, r9=out
    lea rdi, [tls_s_hs_key]
    lea rsi, [tls_s_hs_iv]
    mov rdx, [tls_hs_seq]
    mov rcx, r14
    mov r8d, [tls_last_frame_len]
    lea r9, [tls_plain]
    call tls_record_decrypt
    jc .tls_ha_badmac
    inc qword [tls_hs_seq]
    ; eax = this record's decrypted handshake-byte count (ct byte and
    ; any zero padding already stripped by tls_record_decrypt) --
    ; append it to the pending message-reassembly buffer.
    mov edx, eax                     ; bytes decrypted this record
    mov eax, [tls_hsmsg_len]
    add eax, edx
    cmp eax, TLS_RX_BUF_SIZE
    ja .tls_ha_fail_overflow         ; server flight too large to reassemble
    lea rdi, [tls_hsmsg_buf]
    add edi, [tls_hsmsg_len]         ; 32-bit add/zero-extend -- see tls_pump's
                                      ; identical note: `add rdi,[mem32]` would
                                      ; read 8 bytes and pull in garbage upper
                                      ; bits from whatever follows in memory
    lea rsi, [tls_plain]
    mov ecx, edx
    rep movsb
    mov [tls_hsmsg_len], eax
.tls_ha_msgloop:
    mov r15d, [tls_hsmsg_len]
    cmp r15d, 4
    jb .tls_ha_flight                 ; not even a full header yet -- need more records
    lea r13, [tls_hsmsg_buf]
    ; msg type
    movzx eax, byte [r13]
    mov r12d, eax
    ; msg length u24
    movzx eax, byte [r13+1]
    shl eax, 8
    movzx edx, byte [r13+2]
    or eax, edx
    shl eax, 8
    movzx edx, byte [r13+3]
    or eax, edx
    add eax, 4                       ; total msg bytes incl header
    cmp eax, r15d
    ja .tls_ha_flight                 ; message body continues in a later record
    ; switch on type
    cmp r12d, HS_FINISHED
    je .tls_ha_finished
    ; EE / Cert / CV / other: append to transcript, then drop it from
    ; the front of the reassembly buffer
    push rax
    mov rsi, r13
    mov rcx, rax
    call tls_transcript_append
    pop rax
    mov edx, eax
    call .tls_ha_shift_msg
    jmp .tls_ha_msgloop
.tls_ha_finished:
    ; transcript hash BEFORE adding sfin
    lea rdi, [tls_th_fin]
    call tls_transcript_hash
    ; expected = finished_verify_data(s_hs_traffic, th_fin)
    lea rdi, [tls_s_hs_traffic]
    lea rsi, [tls_th_fin]
    lea r8, [tls_expected_fin]
    call tls_finished_verify_data
    ; recompute msg len
    movzx eax, byte [r13+1]
    shl eax, 8
    movzx edx, byte [r13+2]
    or eax, edx
    shl eax, 8
    movzx edx, byte [r13+3]
    or eax, edx
    cmp eax, 32
    jne .tls_ha_fail_finlen
    lea rsi, [r13+4]
    lea rdi, [tls_expected_fin]
    mov rcx, 32
    call mem_eq
    test al, al
    jz .tls_ha_badfin
    ; append sfin to transcript
    push rax
    mov rsi, r13
    mov rcx, 36
    call tls_transcript_append
    pop rax
    mov edx, 36
    call .tls_ha_shift_msg
    mov qword [tls_got_sfin], 1
    jmp .tls_ha_msgdone
.tls_ha_msgdone:
    ; only reached via the Finished branch above now (a message that
    ; falls short is handled by looping back to .tls_ha_flight instead
    ; of falling through here), so no need to re-check tls_got_sfin.

    ; ---- client Finished ----
    ; th_after = transcript hash (CH..sfin)
    lea rdi, [tls_th_after]
    call tls_transcript_hash
    ; c_finished = finished_verify_data(c_hs_traffic, th_after)
    lea rdi, [tls_c_hs_traffic]
    lea rsi, [tls_th_after]
    lea r8, [tls_c_fin]
    call tls_finished_verify_data
    ; build client Finished handshake msg in tls_cfin_msg
    lea rdi, [tls_cfin_msg]
    mov byte [rdi], HS_FINISHED
    mov byte [rdi+1], 0x00
    mov byte [rdi+2], 0x00
    mov byte [rdi+3], 0x20
    add rdi, 4                ; advance past the 4-byte header -- the
                              ; header writes above use [rdi+n] addressing
                              ; and do NOT advance rdi, so without this the
                              ; rep movsb would overwrite the header with
                              ; the first 4 bytes of verify_data
    lea rsi, [tls_c_fin]
    mov ecx, 32
    rep movsb
    ; send as encrypted record (c_hs key/iv, seq 0)
    lea rdi, [tls_c_hs_key]
    lea rsi, [tls_c_hs_iv]
    xor rdx, rdx
    mov rcx, CT_HANDSHAKE
    lea r8, [tls_cfin_msg]
    mov r9d, 36
    lea r10, [tls_tx_buf]
    call tls_record_encrypt
    mov [tls_tx_len], eax
    lea rsi, [tls_tx_buf]
    mov ecx, eax
    call tls_send_record_raw
    jc .tls_ha_sendfail

    ; ---- application traffic secrets ----
    lea rdi, [tls_master]
    lea rsi, [tls_label_c_ap]
    mov edx, 12
    lea rcx, [tls_th_after]
    lea r8, [tls_c_ap_traffic]
    call tls_derive_secret
    lea rdi, [tls_master]
    lea rsi, [tls_label_s_ap]
    mov edx, 12
    lea rcx, [tls_th_after]
    lea r8, [tls_s_ap_traffic]
    call tls_derive_secret
    lea rdi, [tls_c_ap_traffic]
    lea r8, [tls_c_ap_key]
    lea r9, [tls_c_ap_iv]
    call tls_traffic_key_iv
    lea rdi, [tls_s_ap_traffic]
    lea r8, [tls_s_ap_key]
    lea r9, [tls_s_ap_iv]
    call tls_traffic_key_iv

    clc
    jmp .tls_ha_done
.tls_ha_alert:
    ; rsi/ecx from tls_wait_for_record still point at the 2-byte alert
    ; body: byte0 = level (1=warning, 2=fatal), byte1 = description
    ; (RFC 8446 6.2 -- e.g. 40=handshake_failure, 42=bad_certificate,
    ; 46=unsupported_certificate, 70=protocol_version, 112=unrecognized_name,
    ; 116=certificate_required). Printing these turns a completely opaque
    ; "handshake failed" into the actual reason the server gave us.
    cmp ecx, 2
    jb .tls_ha_fail                  ; malformed alert -- fall back to generic
    movzx r12d, byte [rsi]
    movzx r13d, byte [rsi+1]
    mov rsi, msg_tls_alert_level
    call tls_error_print
    mov eax, r12d
    call tcp_print_dec
    mov rsi, msg_tls_alert_desc
    call tls_error_print
    mov eax, r13d
    call tcp_print_dec
    mov rsi, msg_nl
    call print_string
    stc
    jmp .tls_ha_done
.tls_ha_badfin:
    mov rsi, msg_tls_badfin
    call tls_error_print
    stc
    jmp .tls_ha_done
.tls_ha_badmac:
    mov rsi, msg_tls_badmac
    call tls_error_print
    stc
    jmp .tls_ha_done
.tls_ha_sendfail:
    mov rsi, msg_tls_sendfail
    call tls_error_print
    stc
    jmp .tls_ha_done
.tls_ha_fail_wait:
    ; al comes straight from tls_wait_for_record: 1=timeout, 2=RST,
    ; 3=cancelled -- surface which one instead of a blanket "failed".
    cmp al, 1
    je .tls_ha_fw_timeout
    cmp al, 2
    je .tls_ha_fw_rst
    cmp al, 3
    je .tls_ha_fw_cancel
    jmp .tls_ha_fail                 ; unrecognized reason -- generic message
.tls_ha_fw_timeout:
    mov rsi, msg_tls_hs_timeout
    call tls_error_print
    stc
    jmp .tls_ha_done
.tls_ha_fw_rst:
    mov rsi, msg_tls_hs_reset
    call tls_error_print
    stc
    jmp .tls_ha_done
.tls_ha_fw_cancel:
    mov byte [kill_flag], 0
    mov rsi, msg_tls_cancelled
    call print_string
    stc
    jmp .tls_ha_done
.tls_ha_fail_sh:
    mov rsi, msg_tls_sh_reject
    call tls_error_print
    stc
    jmp .tls_ha_done
.tls_ha_fail_overflow:
    mov rsi, msg_tls_overflow
    call tls_error_print
    stc
    jmp .tls_ha_done
.tls_ha_fail_finlen:
    mov rsi, msg_tls_finlen
    call tls_error_print
    stc
    jmp .tls_ha_done
.tls_ha_fail:
    mov rsi, msg_tls_handshake_fail
    call tls_error_print
    stc
.tls_ha_done:
    pop r15
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
    pop rax
    ret

; ---- local helper: drop edx bytes from the front of the pending
; handshake-message reassembly buffer (tls_hsmsg_buf), shifting any
; leftover bytes -- the start of a message that hasn't fully arrived
; yet -- down to the front. Same shift-left pattern tls_consume_frame
; uses for the raw record stream, one layer up.
; in: edx = bytes to drop (the just-processed message's total length).
.tls_ha_shift_msg:
    push rax
    push rcx
    push rsi
    push rdi
    mov eax, [tls_hsmsg_len]
    cmp eax, edx
    jbe .tls_ha_shift_empty
    sub eax, edx                     ; eax = bytes remaining after the drop
    lea rdi, [tls_hsmsg_buf]
    lea rsi, [tls_hsmsg_buf + rdx]
    mov ecx, eax
    rep movsb
    mov [tls_hsmsg_len], eax
    jmp .tls_ha_shift_done
.tls_ha_shift_empty:
    mov dword [tls_hsmsg_len], 0
.tls_ha_shift_done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ============================================================
;  tls_wait_for_record -- polls the transport until a full TLS
;  record is in the stream (or timeout/error). The frame is copied
;  into tls_frame_buf and consumed from the stream, so each call
;  yields the next record. CF=0: dl=content type, ecx=payload len,
;  rsi=payload ptr (into tls_frame_buf), tls_last_frame_len set.
;  CF=1: al = reason (1=timeout, 2=RST, 3=cancelled) -- added in Phase 4
;  so tls_do_exchange can salvage already-received data on a timeout
;  without treating a RST/cancel the same way. NOTE: rax is NOT saved/
;  restored here (same hazard class as tls_record_encrypt/decrypt in
;  Phase 3 -- a push/pop rax would clobber this al return value with
;  the caller's stale rax right before ret). Every other touched
;  register still follows the save-everything convention.
; ============================================================
tls_wait_for_record:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov byte [tls_wait_ticks], TCP_ROUND_SECS
    mov byte [tls_retry], 0
    call rtc_sec_now
    mov [tls_last_sec], eax
.tls_wfr_loop:
    ; try to extract a frame from what we already have
    call tls_poll_single_frame
    jnc .tls_wfr_got
    ; nothing complete: poll transport
    call kbd_poll
    cmp byte [kill_flag], 0
    jne .tls_wfr_cancel
    call netpoll
    call tls_pump
    TLS_TRACE_PUMP
    cmp byte [tcp_rst_got], 0
    jne .tls_wfr_rst
    ; retry/timeout tick
    call rtc_sec_now
    cmp eax, [tls_last_sec]
    je .tls_wfr_loop
    mov [tls_last_sec], eax
    dec byte [tls_wait_ticks]
    jns .tls_wfr_loop
    cmp byte [tls_retry], TCP_MAX_RETRIES
    jae .tls_wfr_timeout
    inc byte [tls_retry]
    mov byte [tls_wait_ticks], TCP_ROUND_SECS
    cmp qword [tls_wfr_resend_hook], 0
    je .tls_wfr_loop
    call qword [tls_wfr_resend_hook]
    jmp .tls_wfr_loop
.tls_wfr_got:
    ; rsi = payload ptr in stream, ecx = payload len, dl = content type
    mov [tls_last_frame_len], ecx
    push rdx
    push rsi
    push rcx
    push rsi
    push rcx
    push rdx
    TLS_TRACE_GOT
    pop rdx
    pop rcx
    pop rsi
    lea rdi, [tls_frame_buf]
    rep movsb                          ; copy payload to stable buffer
    mov rsi, [rsp + 8]                 ; stream payload ptr
    mov rcx, [rsp + 0]                 ; payload len
    push rsi
    push rcx
    TLS_TRACE_CONSUME
    pop rcx
    pop rsi
    call tls_consume_frame
    pop rcx
    pop rsi
    pop rdx
    lea rsi, [tls_frame_buf]
    clc
    jmp .tls_wfr_out
.tls_wfr_cancel:
    mov al, 3
    jmp .tls_wfr_stc
.tls_wfr_rst:
    mov al, 2
    jmp .tls_wfr_stc
.tls_wfr_timeout:
    mov al, 1
.tls_wfr_stc:
    stc
.tls_wfr_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
;  tls_send_record -- plaintext record: rsi = payload, ecx = len,
;  rdx = content type. Wraps in the 5-byte header and sends via
;  tcp_send_segment (PSH|ACK). Advances tcp_cur_seq.
; ============================================================
tls_send_record:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    ; build into tls_tx_buf: ct 03 03 u16(len)
    lea rdi, [tls_tx_buf]
    mov byte [rdi], dl
    mov byte [rdi+1], 0x03
    mov byte [rdi+2], 0x03
    mov byte [rdi+3], ch
    mov byte [rdi+4], cl
    ; copy payload
    lea rdi, [tls_tx_buf + 5]
    push rcx
    push rsi
    rep movsb
    pop rsi
    pop rcx
    add ecx, 5
    lea rsi, [tls_tx_buf]
    call tls_send_record_raw
    jc .tls_sr_fail
    clc
    jmp .tls_sr_out
.tls_sr_fail:
    stc
.tls_sr_out:
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
;  tls_send_record_raw -- rsi = record bytes, ecx = total len.
;  Sends via tcp_send_segment and advances tcp_cur_seq.
; ============================================================
tls_send_record_raw:
    push rax
    push rcx
    push rsi
    push r8
    push r9
    push r10
    push r11
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_PSH | TCP_FLAG_ACK
    call tcp_send_segment
    jc .tls_srr_fail
    ; advance seq by the record length
    mov eax, [tcp_cur_seq]
    add eax, [rsp + 40]              ; original ecx (total len)
    mov [tcp_cur_seq], eax
    clc
    jmp .tls_srr_out
.tls_srr_fail:
    stc
.tls_srr_out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rcx
    pop rax
    ret

; ============================================================
;  tls_resend_ch -- retransmit the already-built ClientHello (tls_ch_buf/
;  tls_ch_len) at its ORIGINAL sequence number (tls_ch_seq), not the
;  current tcp_cur_seq (which has already moved past it). This is a true
;  retransmission, not a new send: tcp_cur_seq is restored to its pre-call
;  value afterward so the "next new data" pointer is unaffected. Used as
;  tls_wait_for_record's resend hook while waiting for the ServerHello --
;  see the note by tls_wfr_resend_hook for why this exists.
; ============================================================
tls_resend_ch:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov rsi, msg_tls_resend_ch
    call print_string                ; visible proof this actually fired --
                                      ; if the wire were the problem, this
                                      ; should print up to 3 times before
                                      ; the final timeout
    mov eax, [tcp_cur_seq]           ; save the current "next new data" seq
    push rax
    mov eax, [tls_ch_seq]
    mov [tcp_cur_seq], eax           ; rewind to the ClientHello's own seq
    lea rdi, [tls_tx_buf]
    mov byte [rdi], CT_HANDSHAKE
    mov byte [rdi+1], 0x03
    mov byte [rdi+2], 0x03
    mov eax, [tls_ch_len]
    mov byte [rdi+3], ah
    mov byte [rdi+4], al
    lea rdi, [tls_tx_buf + 5]
    lea rsi, [tls_ch_buf]
    mov ecx, [tls_ch_len]
    rep movsb
    mov eax, [tls_ch_len]
    add eax, 5
    mov ecx, eax
    lea rsi, [tls_tx_buf]
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_PSH | TCP_FLAG_ACK
    call tcp_send_segment            ; ignore CF -- this is best-effort; a
                                      ; real failure here surfaces the usual
                                      ; way once the round budget still
                                      ; expires and tls_wait_for_record times
                                      ; out normally
    pop rax
    mov [tcp_cur_seq], eax           ; restore -- unaffected by a retransmit
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ============================================================
;  tls_error_print -- rsi = error string. Prints in red.
; ============================================================
tls_error_print:
    push rax
    mov al, ATTR_ERROR
    call print_string_attr
    pop rax
    ret

; ============================================================
;  tls_connect_and_handshake -- rsi = hostname (null-term),
;  dx = port. Resolves, does the TCP 3-way handshake (mirroring
;  cmd_tcp), then runs the TLS handshake. CF=0 ready, CF=1 error.
; ============================================================
tls_connect_and_handshake:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    mov r14, rsi                     ; hostname
    mov r15w, dx                     ; port

    ; ---- zero tls_dns_buf ----
    lea rdi, [tls_dns_buf]
    xor al, al
    mov rcx, 128
    rep stosb
    ; ---- copy hostname into tls_dns_buf (keep r14 = hostname) ----
    ; Bounded copy: tls_dns_buf is 128 bytes and was just zeroed above, so
    ; stopping at 127 chars always leaves the terminating NUL in place.
    ; (Every other buffer copy in this file is bounds-checked -- this one
    ; wasn't, and an over-length host would silently overrun tls_dns_buf
    ; into whatever data follows it.)
    lea rdi, [tls_dns_buf]
    mov rsi, r14
    xor ecx, ecx
.tls_ch_copy:
    cmp ecx, 127
    jae .tls_ch_copy_done
    mov al, [rsi]
    test al, al
    jz .tls_ch_copy_done
    mov [rdi], al
    inc rsi
    inc rdi
    inc ecx
    jmp .tls_ch_copy
.tls_ch_copy_done:
    lea rsi, [tls_dns_buf]
    call dns_query
    cmp eax, 0xFFFFFFFF
    je .tls_conn_dnsfail
    mov [tcp_peer_ip], eax
    mov [tcp_peer_port], r15w
    mov dword [tls_dns_ip_idx], 0     ; eax == nic_dns_ips[0] already

    ; ---- trace every frame for the rest of this call ----
    ; dns_query already turned nic_diag_verbose back off internally by
    ; the time it returns (it only traces its own DNS wait), so the SYN,
    ; SYN-ACK, our ACK, the ClientHello send, and anything (or nothing)
    ; coming back from the peer were all completely invisible on the
    ; console -- the trace stopped right after the DNS reply. Turn it on
    ; for the rest of the TCP+TLS connect so a stalled handshake can
    ; actually be diagnosed. .tls_conn_done turns it back off on every
    ; exit path (success or failure).
    mov byte [nic_diag_verbose], 1
    mov byte [nic_diag_tx_dumped], 0
    mov byte [nic_diag_rx_count], 0

    ; ---- pick an ephemeral source port ----
    ; NOTE: this used to be just [nic_ip_id] + 0x4000. nic_ip_id resets to
    ; a fixed value at every boot and only a handful of packets (DNS) go
    ; out before this point, so tcp_my_port came out IDENTICAL on every
    ; run. If a previous attempt to this same host crashed/rebooted
    ; without a clean FIN/RST, the remote server is still retransmitting
    ; on that old connection -- and those stale segments land on our
    ; brand-new SYN_SENT connection (same src port, same peer) and
    ; confuse the TCP state machine. That's what the stray
    ; "rx: ... proto=0x06 src=<peer>" frames arriving before we've even
    ; sent a SYN are. Mix in rtc_sec_now so the port actually varies
    ; from run to run.
    call rtc_sec_now
    mov ecx, eax
    movzx eax, word [nic_ip_id]
    xor eax, ecx
    and eax, 0x3FFF
    add eax, 0x4000
    mov [tcp_my_port], ax
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

    mov rsi, msg_tls_connecting
    call print_string
    lea rsi, [tcp_peer_ip]
    call print_ip4
    mov rsi, msg_tls_colon
    call print_string
    movzx eax, word [tcp_peer_port]
    call tcp_print_dec
    mov rsi, msg_tls_nl
    call print_string

    ; ---- SYN ----
.tls_conn_send_syn:
    xor rsi, rsi
    xor ecx, ecx
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_SYN
    call tcp_send_segment
    jc .tls_conn_sendfail
    call rtc_sec_now
    mov r13, rax
.tls_conn_wait:
    call kbd_poll
    cmp byte [kill_flag], 0
    jne .tls_conn_cancel
    call netpoll
    cmp byte [tcp_state], 2
    je .tls_conn_connected
    cmp byte [tcp_rst_got], 0
    jne .tls_conn_reset
    call rtc_sec_now
    cmp eax, r13d
    jne .tls_conn_tick
    jmp .tls_conn_wait
.tls_conn_tick:
    mov r13, rax
    dec byte [tcp_wait_ticks]
    jns .tls_conn_wait
    cmp byte [tcp_retry], TCP_MAX_RETRIES
    jae .tls_conn_timeout
    inc byte [tcp_retry]
    mov byte [tcp_wait_ticks], TCP_ROUND_SECS
    xor rsi, rsi
    xor ecx, ecx
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_SYN
    call tcp_send_segment
    jc .tls_conn_sendfail
    call rtc_sec_now
    mov r13, rax
    jmp .tls_conn_wait
.tls_conn_connected:
    mov rsi, msg_tls_connected
    call print_string
    ; ---- TLS handshake ----
    mov rsi, r14
    call tls_handshake_after_connect
    jc .tls_conn_tlsfail
    mov rsi, msg_tls_handshake_ok
    call print_string
    clc
    jmp .tls_conn_done
.tls_conn_dnsfail:
    mov rsi, msg_net_unresolved
    call tls_error_print
    stc
    jmp .tls_conn_done
.tls_conn_sendfail:
    mov rsi, msg_tcp_sendfail
    call tls_error_print
    stc
    jmp .tls_conn_done
.tls_conn_cancel:
    mov byte [kill_flag], 0
    mov rsi, msg_tls_cancelled
    call print_string
    stc
    jmp .tls_conn_done
.tls_conn_reset:
    mov rsi, msg_tcp_reset
    call tls_error_print
    stc
    jmp .tls_conn_done
.tls_conn_timeout:
    ; a lot of hostnames (raw.githubusercontent.com among them) resolve to
    ; several anycast IPs, and it's common for only some of them to be
    ; reachable from a given network -- one edge times out while another
    ; answers instantly. Before giving up outright, work through any other
    ; A records the DNS reply gave us.
    movzx eax, byte [nic_dns_ip_count]
    mov ecx, [tls_dns_ip_idx]
    inc ecx
    cmp ecx, eax
    jae .tls_conn_timeout_final        ; no more candidates left
    mov [tls_dns_ip_idx], ecx
    mov eax, [nic_dns_ips + rcx*4]
    mov [tcp_peer_ip], eax
    mov rsi, msg_tls_retry_ip
    call print_string
    lea rsi, [tcp_peer_ip]
    call print_ip4
    mov rsi, msg_tls_nl
    call print_string
    ; fresh connection state for the new peer
    call rtc_sec_now
    mov ecx, eax
    movzx eax, word [nic_ip_id]
    xor eax, ecx
    and eax, 0x3FFF
    add eax, 0x4000
    mov [tcp_my_port], ax
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
    jmp .tls_conn_send_syn
.tls_conn_timeout_final:
    mov rsi, msg_tcp_timeout
    call tls_error_print
    stc
    jmp .tls_conn_done
.tls_conn_tlsfail:
    stc
.tls_conn_done:
    mov byte [nic_diag_verbose], 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
;  tls_send_app_record -- Phase 4. Encrypts + sends one record using
;  the CLIENT application traffic key/iv and tls_c_ap_seq (the post-
;  handshake sequence counter -- separate from tls_hs_seq, which is
;  only used during the handshake flight in Phase 3 above).
;  rsi = payload ptr, ecx = payload len, dl = inner content type
;  (CT_APPLICATION_DATA for a request, CT_ALERT for close_notify).
;  CF=0 sent, CF=1 send failed (tcp_send_segment failure).
; ============================================================
tls_send_app_record:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10

    movzx ebx, dl                    ; stash content type (dl clobbered below)
    mov r8, rsi                      ; payload ptr
    mov r9d, ecx                     ; payload len
    lea rdi, [tls_c_ap_key]
    lea rsi, [tls_c_ap_iv]
    mov rdx, [tls_c_ap_seq]          ; seq
    mov rcx, rbx                     ; content type
    lea r10, [tls_tx_buf]
    call tls_record_encrypt          ; -> eax = record length
    mov [tls_tx_len], eax
    inc qword [tls_c_ap_seq]
    lea rsi, [tls_tx_buf]
    mov ecx, eax
    call tls_send_record_raw
    jc .tls_sar_fail
    clc
    jmp .tls_sar_out
.tls_sar_fail:
    stc
.tls_sar_out:
    pop r10
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
;  tls_recv_app_frame -- Phase 4. Waits for and processes one TLS
;  record during the app-data phase: decrypts it with the SERVER
;  application traffic key/iv and tls_s_ap_seq, and dispatches on
;  the inner content type.
;
;  OUT (CF=0):
;    al = 1  application data -- appended to tls_app_rx_buf
;             (bounded by TLS_APP_RX_MAX; excess is dropped, not
;             overflowed)
;    al = 2  close_notify alert -- clean end of data
;    al = 3  something harmless was skipped (a stray non-application-
;             data outer record, a post-handshake handshake message
;             such as NewSessionTicket -- out of scope, see phases.txt
;             -- or an unrecognized inner content type). Caller should
;             just call again.
;  OUT (CF=1): error already printed. al = tls_wait_for_record's
;    reason code (1=timeout, 2=RST, 3=cancelled) when the failure
;    came from the wait itself, or 4 (record auth failure / fatal
;    alert) when a record was received but rejected.
; ============================================================
tls_recv_app_frame:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    push r13

    call tls_wait_for_record         ; CF=0: dl=ct,ecx=len,rsi=ptr
                                      ; CF=1: al=reason (1/2/3)
    jc .tls_raf_wfr_fail

    cmp dl, CT_APPLICATION_DATA
    je .tls_raf_appdata
    ; Any other outer record type here (a stray unencrypted alert,
    ; a leftover CCS, etc.) is unexpected during the app-data phase --
    ; skip it and let the caller poll again, mirroring how the Phase 3
    ; handshake-flight loop skips CCS records.
    mov al, 3
    clc
    jmp .tls_raf_out

.tls_raf_appdata:
    mov r12, rsi                     ; ciphertext ptr (in tls_frame_buf)
    mov r13d, ecx                    ; ciphertext len incl 16-byte tag
    lea rdi, [tls_s_ap_key]
    lea rsi, [tls_s_ap_iv]
    mov rdx, [tls_s_ap_seq]
    mov rcx, r12
    mov r8d, r13d
    lea r9, [tls_plain]
    call tls_record_decrypt
    jc .tls_raf_badmac
    inc qword [tls_s_ap_seq]
    mov r12d, eax                    ; inner len
    mov dl, [tls_last_ct]
    cmp dl, CT_APPLICATION_DATA
    je .tls_raf_data
    cmp dl, CT_ALERT
    je .tls_raf_alert
    ; CT_HANDSHAKE here is a post-handshake message (NewSessionTicket
    ; is the only one a real server sends) -- session resumption is
    ; explicitly out of scope (phases.txt parking lot), so skip its
    ; content and keep going. Anything else unrecognized: also skip.
    mov al, 3
    clc
    jmp .tls_raf_out

.tls_raf_data:
    ; append tls_plain[0..r12d) to tls_app_rx_buf, bounded by
    ; TLS_APP_RX_MAX (leaves room for the 0-terminator tls_do_exchange
    ; writes once the exchange is done).
    mov eax, [tls_app_rx_len]
    mov edx, TLS_APP_RX_MAX
    sub edx, eax
    cmp r12d, edx
    jbe .tls_raf_data_fits
    mov r12d, edx                    ; truncate rather than overflow
.tls_raf_data_fits:
    lea rdi, [tls_app_rx_buf]
    add rdi, rax
    lea rsi, [tls_plain]
    mov ecx, r12d
    rep movsb
    add [tls_app_rx_len], r12d
    mov al, 1
    clc
    jmp .tls_raf_out

.tls_raf_alert:
    cmp r12d, 2
    jne .tls_raf_alert_fatal
    mov al, [tls_plain]
    mov [tls_alert_level], al
    mov al, [tls_plain+1]
    mov [tls_alert_desc], al
    test al, al                      ; 0 = close_notify
    jnz .tls_raf_alert_fatal
    mov byte [tls_close_notify_got], 1
    mov al, 2
    clc
    jmp .tls_raf_out
.tls_raf_alert_fatal:
    mov rsi, msg_tls_alert
    call tls_error_print
    mov al, 4
    stc
    jmp .tls_raf_out

.tls_raf_badmac:
    mov rsi, msg_tls_badmac
    call tls_error_print
    mov al, 4
    stc
    jmp .tls_raf_out

.tls_raf_wfr_fail:
    ; al already carries tls_wait_for_record's reason code (1/2/3);
    ; print the matching message here so tls_do_exchange doesn't have
    ; to duplicate this dispatch.
    cmp al, 2
    je .tls_raf_wfr_rst
    cmp al, 3
    je .tls_raf_wfr_cancel
    mov rsi, msg_tcp_timeout
    call tls_error_print
    mov al, 1
    stc
    jmp .tls_raf_out
.tls_raf_wfr_rst:
    mov rsi, msg_tcp_reset
    call tls_error_print
    mov al, 2
    stc
    jmp .tls_raf_out
.tls_raf_wfr_cancel:
    mov byte [kill_flag], 0
    mov rsi, msg_tls_cancelled
    call print_string
    mov al, 3
    stc
.tls_raf_out:
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

; ============================================================
;  tls_do_exchange -- Phase 4. Mirrors http.asm's tcp_do_exchange
;  contract, but TLS-wrapped end to end: TCP connect -> TLS handshake
;  (Phase 3) -> encrypt+send the request -> receive/decrypt the reply
;  (looping over possibly multiple TCP segments/TLS records, same
;  "no new data for a full tick means done" coalescing tcp_do_exchange
;  uses -- here that patience comes from tls_wait_for_record's own
;  TCP_ROUND_SECS/TCP_MAX_RETRIES budget, so there's still only ONE
;  timeout scheme in the whole client, not a second one bolted on) ->
;  send close_notify -> TCP FIN.
;
;  IN:  rsi = hostname (null-terminated), dx = port.
;       Caller has already placed the plaintext request in
;       tls_app_tx_buf with its length in tls_app_tx_len. (Buffer
;       sizing decision, per phases.txt Phase 4 point 4: tls_app_tx_buf
;       / tls_app_rx_buf are dedicated buffers, sized off http.asm's
;       HTTP_TX_MAX=1200 / HTTP_RX_BUF_SIZE=3072 with headroom --
;       TLS_APP_TX_MAX=2048, TLS_APP_RX_MAX=4096 -- rather than reusing
;       tcp_tx_buf/tcp_rx_buf directly. tcp_tx_buf/tcp_rx_buf stay
;       exactly as they are for the plain-HTTP path (cmd_tcp / a future
;       plain take/give), so this Phase cannot regress them. The
;       already-existing tls_tx_buf (sized TLS_RX_BUF_SIZE+64) is reused
;       unchanged as the encrypted-record staging area -- it was already
;       sized generously enough by Phase 3. Phase 5's cmd_stake/cmd_sgive
;       will bridge http_build_get/http_build_post's tcp_tx_buf output
;       into tls_app_tx_buf, and tls_app_rx_buf back into whatever
;       http_find_body ends up reading -- see phases.txt Phase 5.
;  OUT: CF=0 -- decrypted reply is in tls_app_rx_buf, length in
;       tls_app_rx_len, 0-terminated (same convention as tcp_rx_buf).
;       CF=1 -- error already printed.
; ============================================================
TLS_APP_TX_MAX equ 2048
TLS_APP_RX_MAX equ 4096

tls_do_exchange:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13

    mov r12, rsi                     ; hostname
    mov r13w, dx                     ; port

    ; ---- connect + handshake (Phase 3) ----
    mov rsi, r12
    mov dx, r13w
    call tls_connect_and_handshake
    jc .tls_dx_fail

    ; ---- reset app-data state for this exchange ----
    mov qword [tls_c_ap_seq], 0
    mov qword [tls_s_ap_seq], 0
    mov dword [tls_app_rx_len], 0
    mov byte [tls_close_notify_got], 0

    ; ---- encrypt + send the request as one application_data record ----
    lea rsi, [tls_app_tx_buf]
    mov ecx, [tls_app_tx_len]
    mov dl, CT_APPLICATION_DATA
    call tls_send_app_record
    jc .tls_dx_sendfail

    ; ---- receive/decrypt loop ----
.tls_dx_recv:
    ; A TCP-level FIN with nothing left buffered means the peer closed
    ; without a TLS close_notify (some servers do this on HTTP/1.0-style
    ; connections). If we already have reply data, that's fine -- treat
    ; it like tcp_do_exchange's own tcp_fin_got check. If we have
    ; nothing yet, keep waiting and let tls_wait_for_record's own
    ; timeout decide.
    cmp byte [tcp_fin_got], 0
    je .tls_dx_recv_go
    cmp dword [tls_rx_used], 0
    jne .tls_dx_recv_go              ; still buffered bytes -- drain first
    cmp dword [tls_app_rx_len], 0
    je .tls_dx_recv_go
    jmp .tls_dx_close
.tls_dx_recv_go:
    call tls_recv_app_frame
    jc .tls_dx_recv_fail
    cmp al, 2
    je .tls_dx_close                 ; close_notify -- clean end
    jmp .tls_dx_recv                 ; data appended or harmlessly skipped

.tls_dx_recv_fail:
    ; Same salvage tc_timeout/de_timeout use: a timeout with data
    ; already in hand is treated as a successful (if abrupt) end of
    ; the reply. RST / cancel / a record auth failure are hard fails
    ; regardless of what's already been received.
    cmp al, 1
    jne .tls_dx_fail
    cmp dword [tls_app_rx_len], 0
    je .tls_dx_fail
    ; fall through: salvage what we have

.tls_dx_close:
    mov eax, [tls_app_rx_len]
    mov byte [tls_app_rx_buf + rax], 0
    ; ---- send close_notify (warning-level, RFC 8446 6.1) ----
    ; Best-effort: we already have our data, so a failure sending this
    ; is not itself a reason to report the exchange as failed.
    lea rsi, [tls_close_notify_payload]
    mov ecx, 2
    mov dl, CT_ALERT
    call tls_send_app_record
    ; ---- TCP FIN|ACK to close cleanly ----
    xor rsi, rsi
    xor ecx, ecx
    mov r8d, [tcp_peer_ip]
    mov r9w, [tcp_peer_port]
    mov r10w, [tcp_my_port]
    mov r11w, TCP_FLAG_FIN | TCP_FLAG_ACK
    call tcp_send_segment
    clc
    jmp .tls_dx_done
.tls_dx_sendfail:
    mov rsi, msg_tls_sendfail
    call tls_error_print
    stc
    jmp .tls_dx_done
.tls_dx_fail:
    stc
.tls_dx_done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
;  data
; ============================================================
TLS_TRANSCRIPT_MAX equ 16384
TLS_RX_BUF_SIZE    equ 16384

tls_zero32:    times 32 db 0
tls_basepoint9: db 9
    times 31 db 0

tls_sig_algs:
    db 0x08, 0x04, 0x04, 0x03
    db 0x08, 0x05, 0x05, 0x03
    db 0x08, 0x06, 0x06, 0x03

tls_alpn_http11: db "http/1.1"

; key schedule scratch
tls_early_secret:   times 32 db 0
tls_derived1:       times 32 db 0
tls_hs_secret:      times 32 db 0
tls_derived2:       times 32 db 0
tls_master:         times 32 db 0
tls_c_hs_traffic:   times 32 db 0
tls_s_hs_traffic:   times 32 db 0
tls_c_ap_traffic:   times 32 db 0
tls_s_ap_traffic:   times 32 db 0

; traffic keys/ivs
tls_c_hs_key:  times 32 db 0
tls_c_hs_iv:   times 12 db 0
tls_s_hs_key:  times 32 db 0
tls_s_hs_iv:   times 12 db 0
tls_c_ap_key:  times 32 db 0
tls_c_ap_iv:   times 12 db 0
tls_s_ap_key:  times 32 db 0
tls_s_ap_iv:   times 12 db 0

; transcript state
tls_transcript:     times TLS_TRANSCRIPT_MAX db 0
tls_transcript_len: dd 0
tls_th_ch_sh:       times 32 db 0
tls_th_fin:         times 32 db 0
tls_th_after:       times 32 db 0
tls_th_scratch:     times 32 db 0

; key exchange
tls_client_priv:    times 32 db 0
tls_client_pub:     times 32 db 0
tls_client_random:  times 32 db 0
tls_session_id:     times 32 db 0
tls_server_pub:     times 32 db 0
tls_ecdh_shared:    times 32 db 0

; handshake message buffers
tls_ch_buf:         times 512 db 0
tls_ch_len:         dd 0
tls_ch_body_len:    dd 0
tls_cfin_msg:       times 64 db 0
tls_c_fin:          times 32 db 0
tls_expected_fin:   times 32 db 0
tls_finished_key:   times 32 db 0

; handshake-message reassembly (see .tls_ha_flight/.tls_ha_msgloop in
; tls_handshake_after_connect) -- holds decrypted server-flight bytes
; that have been received but not yet consumed as a complete message.
tls_hsmsg_buf:       times TLS_RX_BUF_SIZE db 0
tls_hsmsg_len:       dd 0

; record scratch
tls_plain:          times TLS_RX_BUF_SIZE + 64 db 0
tls_tx_buf:         times TLS_RX_BUF_SIZE + 64 db 0
tls_tx_len:         dd 0
tls_nonce_buf:      times 12 db 0
tls_aad_buf:        times 5 db 0
tls_seq_be:         times 8 db 0
tls_inner_len:      dd 0
tls_total_len:      dd 0
tls_last_ct:        db 0
tls_ct_byte:        db 0
tls_frame_buf:      times TLS_RX_BUF_SIZE + 64 db 0

; receive stream
tls_rx_buf:         times TLS_RX_BUF_SIZE db 0
tls_rx_used:        dd 0
tls_last_frame_len: dd 0

; handshake sequence numbers
tls_hs_seq:         dq 0
tls_got_sfin:       dq 0

; ---- Phase 4: application-data phase ----
; separate sequence counters from tls_hs_seq -- RFC 8446 resets the
; record sequence number to 0 for each new set of traffic keys.
tls_c_ap_seq:       dq 0
tls_s_ap_seq:       dq 0

; dedicated plaintext staging buffers for tls_do_exchange -- see the
; sizing note in tls_do_exchange's header comment above.
tls_app_tx_buf:     times TLS_APP_TX_MAX db 0
tls_app_tx_len:     dd 0
tls_app_rx_buf:     times TLS_APP_RX_MAX + 1 db 0   ; +1 for 0-terminator
tls_app_rx_len:     dd 0

tls_close_notify_got:    db 0
tls_alert_level:         db 0
tls_alert_desc:           db 0
tls_close_notify_payload: db 1, 0   ; level=warning, description=close_notify

; misc
tls_host_len:       dd 0
tls_ext_len:        dd 0
tls_ext_start:      dq 0
tls_suite:          dw 0
tls_wait_ticks:     db 0
tls_retry:          db 0
tls_last_sec:       dd 0
; optional retransmit hook for tls_wait_for_record: if nonzero, called once
; per elapsed retry round (mirrors the SYN retransmit tls_connect_and_
; handshake already does). Needed because unlike the SYN phase, nothing
; else re-sends the ClientHello -- if that one TCP segment is dropped in
; transit, the server never even sees the request, so no amount of passive
; waiting will ever produce a reply. Caller sets/clears it around the call.
tls_wfr_resend_hook: dq 0
tls_ch_seq:          dd 0        ; tcp_cur_seq the ClientHello was sent at,
                                  ; so a retransmit can reuse the same seq
                                  ; instead of the (already advanced) next one
tls_dns_buf:        times 128 db 0
tls_dns_ip_idx:     dd 0        ; which entry of nic_dns_ips we're on

; labels (no "tls13 " prefix -- hkdf_expand_label adds it)
tls_label_derived:  db "derived"
tls_label_c_hs:     db "c hs traffic"
tls_label_s_hs:     db "s hs traffic"
tls_label_c_ap:     db "c ap traffic"
tls_label_s_ap:     db "s ap traffic"
tls_label_finished: db "finished"
tls_label_key:      db "key"
tls_label_iv:       db "iv"

; SHA-256 of the empty string (used as Hash("") context)
tls_empty_hash:
    db 0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14
    db 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24
    db 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c
    db 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55

; messages
msg_tls_retry_ip:     db "tls: no reply from that address, trying ", 0
msg_tls_connecting:   db "tls: connecting to ", 0
msg_tls_resend_ch:    db "tls: no ServerHello yet -- resending ClientHello", 10, 0
msg_tls_colon:        db ":", 0
msg_tls_nl:           db 10, 0
msg_tls_connected:    db 10, "tls: connected.", 10, 0
msg_tls_handshake_ok: db "tls: handshake OK.", 10, 0
msg_tls_cancelled:    db "tls: cancelled.", 10, 0
msg_tls_badfin:       db "tls: server Finished mismatch", 10, 0
msg_tls_badmac:       db "tls: record auth failure", 10, 0
msg_tls_sendfail:     db "tls: send failed", 10, 0
msg_tls_handshake_fail: db "tls: handshake failed", 10, 0
msg_tls_hs_timeout:   db "tls: handshake failed -- no reply from server (timeout waiting for a record)", 10, 0
msg_tls_hs_reset:     db "tls: handshake failed -- connection reset by peer", 10, 0
msg_tls_sh_reject:    db "tls: handshake failed -- ServerHello rejected (bad version/cipher/compression, or no usable key_share)", 10, 0
msg_tls_overflow:     db "tls: handshake failed -- server's encrypted flight was too large to reassemble", 10, 0
msg_tls_finlen:       db "tls: handshake failed -- server Finished message had the wrong length", 10, 0
msg_tls_alert_level:  db "tls: server sent alert, level=", 0
msg_tls_alert_desc:   db " description=", 0
msg_tls_alert:        db "tls: fatal alert from server", 10, 0
