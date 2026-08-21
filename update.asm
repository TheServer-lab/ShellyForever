; ============================================================
;  update.asm  --  "auth sys update": fetch a newer boot.bin /
;  stage2.bin / kernel_body.bin straight from the shellybin repo and
;  write them directly to their fixed disk LBAs (layout.inc).
;
;  WHY NOT A .zip (like sin.asm's packages)?
;    Every transfer in this OS is deliberately capped around 20KB
;    (EDIT_MAX / HTTP_RX_BUF_SIZE / TLS_APP_RX_MAX all trace back to
;    EDIT_MAX -- see http.asm's header comment). zip.asm's cmd_unpack
;    loads a whole archive into a 20KB buffer and extracts into the
;    filesystem (SFFS nodes). boot.bin/stage2.bin/kernel_body.bin are
;    not filesystem files at all -- they're raw sectors at fixed LBAs
;    (STAGE2_LBA, KERNEL_BODY_LBA) -- and kernel_body.bin alone can be
;    up to KERNEL_BODY_SECTORS*512 = ~1.1MB, ~50x past that cap. So
;    this reuses http.asm/https.asm/tls.asm's request-building and TLS
;    plumbing exactly like stake/sin do, but adds a Range-GET request
;    builder and a chunked download-and-write loop that never lands
;    more than UPDATE_CHUNK_BYTES in memory at once, and never goes
;    through the filesystem or zip.asm at all.
;
;  REMOTE LAYOUT this expects (all under .../sys/ in the shellybin repo):
;    version.sly           "current-version=X.Y.Z"           (existing)
;    <version>/manifest.sly  three lines, in any order:
;      boot.bin=<size>,<crc32-hex>
;      stage2.bin=<size>,<crc32-hex>
;      kernel_body.bin=<size>,<crc32-hex>
;    (the shellybin repo has historically shipped this file misspelled
;    as "mainfest.sly" -- the fetch below tries "manifest.sly" first
;    and falls back to that spelling)
;    <version>/boot.bin
;    <version>/stage2.bin
;    <version>/kernel_body.bin
;
;  FLOW ("auth sys update", gated exactly like "auth sys reset"):
;    1. GET version.sly, compare its current-version= value against
;       the running kernel's own shelly_version string. Equal -> done.
;    2. GET <version>/manifest.sly, parse expected size+crc32 for all
;       three components. A component whose claimed size exceeds its
;       fixed on-disk budget (STAGE2_SECTORS/KERNEL_BODY_SECTORS) is
;       rejected before anything is written -- that budget is the only
;       thing standing between an oversized write and the filesystem
;       region that starts right after it (FS_LBA_START).
;    3. For kernel_body.bin, then stage2.bin, then boot.bin (biggest/
;       most-replaceable first, the tiny fallback-critical MBR last):
;       Range-GET the file in UPDATE_CHUNK_BYTES pieces, writing each
;       chunk straight to disk via disk_write_sector as it arrives,
;       running a CRC32 across all of it, and comparing the final CRC32
;       to the manifest's value.
;
;  HONEST CAVEAT: there is no spare disk region to stage a component in
;  before committing it, and this codebase's existing destructive
;  commands (sys reset, install.asm) already accept "no rollback" as
;  their risk model -- this follows the same one. A component is
;  written to its real, final LBAs as it downloads; if a component's
;  CRC fails, or the network drops mid-file, the update stops
;  immediately (does not touch the next component) and prints a clear
;  error, but whatever was already written to that component's sectors
;  is NOT rolled back. Re-running "auth sys update" downloads and
;  rewrites everything from scratch, so a failed run is recoverable as
;  long as boot.bin/stage2.bin themselves still work well enough to
;  reach the network stack again -- there's no A/B partition scheme
;  here to make an update atomic. boot.bin is written last precisely so
;  a failed kernel_body/stage2 write never touches the one sector that
;  is `hardest` to recover without a second machine.
;
;  No certificate validation, same trust model as stake/sin -- see
;  https.asm's header comment and https_warn_once, reused verbatim.
;
;  Included from kernel.asm, after https.asm/zip.asm/sin.asm (needs
;  http_parse_url/http_build_get/https_bridge_tx/https_find_body/
;  https_warn_once/tls_do_exchange/http_status_code/zip_crc32_table/
;  disk_write_sector/disk_select_device, all already defined by then);
;  inherits BITS 64.
; ============================================================

; 32 sectors per HTTPS Range request over a persistent connection (see
; tls_open_session/tls_exchange_on_session in tls.asm) -- one TLS
; handshake per *component*, not per chunk. TLS_APP_RX_MAX (== 
; HTTP_RX_BUF_SIZE, ~20.5KB) still has to hold the whole headers+body
; for one chunk's response, so this still leaves a ~4.5KB margin for
; response headers.
;
; This used to be the main lever against a real problem: at the
; original 8KB chunk size with a *fresh handshake per chunk*,
; kernel_body.bin (~1.1MB) needed ~140 separate connections, and was
; observed failing partway through a run in three different ways
; (handshake timeout, app-data timeout, connection reset by peer) --
; almost certainly the remote CDN not tolerating that many rapid
; back-to-back connections well. Persistent connections fix the actual
; cause (now ~1 handshake per component instead of ~70-140), so the
; chunk size itself is no longer doing much load-bearing work here;
; kept at 16KB mainly because there's no reason to shrink it back.
UPDATE_CHUNK_BYTES equ 16384

; A single chunk request -- or the connection carrying it -- can still
; legitimately fail (a transient reset, an idle keep-alive connection
; the far end decided to close, etc.) without the whole component
; being unrecoverable, so a chunk gets a few attempts before
; update_fetch_component gives up on the component entirely. Each
; retry closes the (presumably now-dead) session and opens a fresh
; one -- see update_fetch_component's .retry_fail.
UPDATE_MAX_RETRIES equ 3
UPDATE_RETRY_DELAY_MS equ 400

UPDATE_CV_PREFIX_LEN equ 16     ; strlen("current-version=")

; Same content as kernel.asm's http_extra_headers except the
; Connection header -- update_https_get_range_ka's requests go out
; over a session opened once per component and reused for every
; chunk (see tls_open_session/tls_exchange_on_session in tls.asm),
; so "Connection: close" here would be actively wrong: the server
; would tear the connection down after the very first chunk.
update_extra_headers_keepalive:
    db "User-Agent: rush/1.0", 13, 10, "Accept: */*", 13, 10, "Connection: keep-alive", 13, 10, 0

; ============================================================
; cmd_sys's "update" subcommand -- called from kernel.asm's cmd_sys
; as ".sys_update", auth-gated exactly like ".sys_reset". See the
; header comment above for the full flow; this is just the top-level
; driver, built entirely out of the pieces below it in this file.
; ============================================================
sys_do_update:
    cmp byte [nic_present], 0
    jne .have_nic
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_nic:
    call https_warn_once

    mov rsi, msg_update_checking
    mov al, [cur_normal_attr]
    call print_string_attr

    mov rsi, update_version_url
    call update_https_get
    jc .neterr

    ; rax = version.sly body ptr, ecx = body len (unused -- body is
    ; already NUL-terminated by tls_do_exchange)
    mov rdi, rax
    mov rsi, update_cv_prefix
    call update_str_find
    test rax, rax
    jz .badmanifest
    add rax, UPDATE_CV_PREFIX_LEN
    mov rsi, rax
    lea rdi, [update_remote_ver_buf]
    call update_copy_version_token

    call update_get_local_version

    lea rsi, [update_remote_ver_buf]
    lea rdi, [update_local_ver_buf]
    call str_eq
    cmp al, 1
    jne .have_new
    mov rsi, msg_update_uptodate
    mov al, [cur_normal_attr]
    call print_string_attr
    ret

.have_new:
    mov rsi, msg_update_found
    mov al, [cur_normal_attr]
    call print_string_attr
    lea rsi, [update_remote_ver_buf]
    call print_string
    mov rsi, newline_str
    call print_string

    ; manifest URL = prefix + version + "/" + <manifest name>. The
    ; shellybin repo shipped its 0.1.21 manifest as "mainfest.sly"
    ; (swapped letters) while this code asks for "manifest.sly" -- a
    ; 404 there surfaces here as a generic network error and the whole
    ; update aborts before a single byte of kernel is fetched. Try the
    ; correct spelling first, then fall back to the typo'd name so both
    ; old (typo'd) and fixed repos work.
    mov byte [update_manifest_alt], 0
.manifest_retry:
    lea rdi, [update_url_buf]
    mov rsi, update_url_prefix
    call str_copy
    lea rdi, [update_url_buf]
    lea rsi, [update_remote_ver_buf]
    call str_append
    lea rdi, [update_url_buf]
    mov rsi, update_slash
    call str_append
    lea rdi, [update_url_buf]
    cmp byte [update_manifest_alt], 0
    jne .manifest_alt_name
    mov rsi, update_manifest_name
    jmp .manifest_name_picked
.manifest_alt_name:
    mov rsi, update_manifest_name_alt
.manifest_name_picked:
    call str_append

    lea rsi, [update_url_buf]
    call update_https_get
    jnc .have_manifest
    cmp byte [update_manifest_alt], 0
    jne .neterr                    ; already tried both spellings
    mov byte [update_manifest_alt], 1
    jmp .manifest_retry
.have_manifest:

    ; rax = manifest.sly body ptr -- update_manifest_get never modifies
    ; rdi, so the same haystack pointer is reused for all three lookups.
    mov rdi, rax

    mov rsi, update_boot_name
    lea rdx, [update_exp_size]
    lea rcx, [update_exp_crc]
    call update_manifest_get
    jc .badmanifest

    mov rsi, update_stage2_name
    lea rdx, [update_exp_size+4]
    lea rcx, [update_exp_crc+4]
    call update_manifest_get
    jc .badmanifest

    mov rsi, update_kernel_name
    lea rdx, [update_exp_size+8]
    lea rcx, [update_exp_crc+8]
    call update_manifest_get
    jc .badmanifest

    ; sizes must fit their fixed on-disk budgets *before* anything is
    ; written -- this is the only thing standing between a bad/malicious
    ; manifest and a write that runs into the filesystem region.
    mov eax, [update_exp_size]
    cmp eax, 512
    jne .badsize
    mov eax, [update_exp_size+4]
    cmp eax, STAGE2_SECTORS*512
    ja .badsize
    mov eax, [update_exp_size+8]
    cmp eax, KERNEL_BODY_SECTORS*512
    ja .badsize

    ; ---- kernel_body.bin first ----
    mov rsi, msg_update_fetching_kernel
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, update_kernel_name
    call update_build_comp_url
    mov eax, KERNEL_BODY_LBA
    mov [update_comp_lba], eax
    mov eax, [update_exp_size+8]
    mov [update_comp_size], eax
    mov eax, [update_exp_crc+8]
    mov [update_comp_crc], eax
    call update_fetch_component
    cmp al, 1
    jne .compfail

    ; ---- stage2.bin ----
    mov rsi, msg_update_fetching_stage2
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, update_stage2_name
    call update_build_comp_url
    mov eax, STAGE2_LBA
    mov [update_comp_lba], eax
    mov eax, [update_exp_size+4]
    mov [update_comp_size], eax
    mov eax, [update_exp_crc+4]
    mov [update_comp_crc], eax
    call update_fetch_component
    cmp al, 1
    jne .compfail

    ; ---- boot.bin last -- see header comment for why ----
    mov rsi, msg_update_fetching_boot
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, update_boot_name
    call update_build_comp_url
    xor eax, eax
    mov [update_comp_lba], eax
    mov eax, [update_exp_size]
    mov [update_comp_size], eax
    mov eax, [update_exp_crc]
    mov [update_comp_crc], eax
    call update_fetch_component
    cmp al, 1
    jne .compfail

    mov rsi, msg_update_done
    mov al, [cur_normal_attr]
    call print_string_attr
    ret

.compfail:
    mov rsi, msg_update_compfail
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.badsize:
    mov rsi, msg_update_badsize
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.badmanifest:
    mov rsi, msg_update_badmanifest
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.neterr:
    mov rsi, msg_update_neterr
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; update_build_comp_url: rsi = component filename (e.g. update_kernel_name).
; Fills update_comp_url with prefix + update_remote_ver_buf + "/" + name.
update_build_comp_url:
    push rsi
    lea rdi, [update_comp_url]
    mov rsi, update_url_prefix
    call str_copy
    lea rdi, [update_comp_url]
    lea rsi, [update_remote_ver_buf]
    call str_append
    lea rdi, [update_comp_url]
    mov rsi, update_slash
    call str_append
    pop rsi
    lea rdi, [update_comp_url]
    call str_append
    ret

; update_get_local_version: extracts the running kernel's own version
; (digits/dots only, skipping shelly_version's leading spaces and 'v')
; into update_local_ver_buf.
update_get_local_version:
    push rsi
    push rdi
    mov rsi, shelly_version
.skip_space:
    cmp byte [rsi], ' '
    jne .after_space
    inc rsi
    jmp .skip_space
.after_space:
    cmp byte [rsi], 'v'
    jne .no_v
    inc rsi
.no_v:
    lea rdi, [update_local_ver_buf]
    call update_copy_version_token
    pop rdi
    pop rsi
    ret

; update_copy_version_token: rsi = start of a "X.Y.Z"-shaped token, rdi =
; destination buffer. Copies digits/'.' only, stops at anything else,
; NUL-terminates rdi. Advances rsi past what it consumed.
update_copy_version_token:
    push rax
.loop:
    mov al, [rsi]
    cmp al, '0'
    jb .check_dot
    cmp al, '9'
    jbe .take
.check_dot:
    cmp al, '.'
    jne .done
.take:
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .loop
.done:
    mov byte [rdi], 0
    pop rax
    ret

; ============================================================
; update_https_get: rsi = https:// URL (NUL-terminated). Plain
; single-shot GET, same shape as cmd_stake/cmd_sin_get's own inline
; sequence -- reused here instead of duplicated a third time.
; Side effect: leaves http_host_buf/http_path_buf/http_port set from
; the URL, same as http_parse_url always does.
; Out: CF=0, rax = body ptr (into tls_app_rx_buf, NUL-terminated),
;      ecx = body len. CF=1 on any failure (bad URL, wrong scheme,
;      network error, non-200 status, or no body found).
; ============================================================
update_https_get:
    call http_parse_url
    jc .fail
    cmp byte [http_url_scheme], 1
    jne .fail

    call http_build_get
    mov [tcp_tx_len], eax
    call https_bridge_tx

    lea rsi, [http_host_buf]
    mov dx, [http_port]
    call tls_do_exchange
    jc .fail

    lea rsi, [tls_app_rx_buf]
    mov ecx, [tls_app_rx_len]
    call http_status_code
    jc .fail
    cmp eax, 200
    jne .fail

    call https_find_body
    jc .fail
    clc
    ret
.fail:
    stc
    ret

; ============================================================
; update_https_get_range: edx = range start (byte offset), ecx = range
; end (inclusive byte offset). Assumes http_host_buf/http_path_buf/
; http_port are already set (by a prior update_https_get or
; http_parse_url call against the same URL).
; Out: CF=0, rax = body ptr (into tls_app_rx_buf), ecx = body len.
;      CF=1 on network error or a status other than 200/206.
; ============================================================
update_https_get_range:
    lea r10, [http_extra_headers]
    call http_build_get_range
    mov [tcp_tx_len], eax
    call https_bridge_tx

    lea rsi, [http_host_buf]
    mov dx, [http_port]
    call tls_do_exchange
    jc .fail

    lea rsi, [tls_app_rx_buf]
    mov ecx, [tls_app_rx_len]
    call http_status_code
    jc .fail
    cmp eax, 206
    je .status_ok
    cmp eax, 200
    jne .fail
.status_ok:
    call https_find_body
    jc .fail
    clc
    ret
.fail:
    stc
    ret

; ============================================================
; update_https_get_range_ka: persistent-session counterpart to
; update_https_get_range above -- edx = range start, ecx = range end
; (inclusive). Assumes http_host_buf/http_path_buf/http_port are
; already set AND that tls_open_session has already succeeded for
; this host:port (see update_fetch_component, which opens one
; session per component and reuses it for every chunk instead of a
; fresh handshake each time). Does NOT open or close the connection.
; Out: CF=0, rax = body ptr (into tls_app_rx_buf), ecx = body len --
;      tls_exchange_on_session already resolved this from the
;      response's actual Content-Length, so unlike
;      update_https_get_range there's no separate https_find_body
;      call needed here.
;      CF=1 -- network error, the session died partway through (see
;      tls_exchange_on_session's contract in tls.asm), or a status
;      other than 200/206. Caller should tls_close_session and open
;      a fresh one before retrying -- this never leaves the session
;      in a state worth continuing to reuse.
; ============================================================
update_https_get_range_ka:
    lea r10, [update_extra_headers_keepalive]
    call http_build_get_range
    mov [tcp_tx_len], eax
    call https_bridge_tx

    call tls_exchange_on_session
    jc .fail

    ; stash the body ptr/len on the stack (not registers) across the
    ; status-code check -- http.asm isn't code this file can verify
    ; the register-preservation contract of the same way kernel.asm's
    ; own functions were checked earlier, so this doesn't assume
    ; anything about what it clobbers.
    push rax
    push rcx
    lea rsi, [tls_app_rx_buf]
    mov ecx, [tls_app_rx_len]
    call http_status_code
    jc .status_fail
    cmp eax, 206
    je .status_ok
    cmp eax, 200
    jne .status_fail
.status_ok:
    pop rcx
    pop rax
    clc
    ret
.status_fail:
    pop rcx
    pop rax
.fail:
    stc
    ret

; ============================================================
; http_build_get_range: builds "GET <path> HTTP/1.1" with a
; "Range: bytes=<edx>-<ecx>" header, into tcp_tx_buf. Near-duplicate of
; http.asm's http_build_get (see that function) with the Range header
; spliced in between the Host header and the extra-headers block.
; In:  edx = range start, ecx = range end (inclusive), r10 = pointer
;      to a NUL-terminated, already-CRLF-terminated-per-line extra
;      headers block (e.g. kernel.asm's http_extra_headers, or
;      update_extra_headers_keepalive above) -- copied in verbatim
;      the same way http_extra_headers always was, just no longer
;      hardcoded to that one block so a persistent-connection caller
;      can supply "Connection: keep-alive" instead of "close".
; Out: eax = total request length
; ============================================================
http_build_get_range:
    push rbx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r8d, edx
    mov r9d, ecx

    lea rdi, [tcp_tx_buf]
    mov dword [rdi], 'GET '
    add rdi, 4
    lea rsi, [http_path_buf]
.path:
    mov al, [rsi]
    test al, al
    jz .path_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .path
.path_done:
    mov byte [rdi], ' '
    inc rdi
    mov dword [rdi], 'HTTP'
    mov byte [rdi+4], '/'
    mov byte [rdi+5], '1'
    mov byte [rdi+6], '.'
    mov byte [rdi+7], '1'
    add rdi, 8
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    add rdi, 2
    mov dword [rdi], 'Host'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    add rdi, 6
    lea rsi, [http_host_buf]
.host:
    mov al, [rsi]
    test al, al
    jz .host_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .host
.host_done:
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    add rdi, 2

    ; Range: bytes=<start>-<end>\r\n
    mov byte [rdi], 'R'
    mov byte [rdi+1], 'a'
    mov byte [rdi+2], 'n'
    mov byte [rdi+3], 'g'
    mov byte [rdi+4], 'e'
    mov byte [rdi+5], ':'
    mov byte [rdi+6], ' '
    add rdi, 7
    mov byte [rdi], 'b'
    mov byte [rdi+1], 'y'
    mov byte [rdi+2], 't'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], 's'
    mov byte [rdi+5], '='
    add rdi, 6
    mov eax, r8d
    call .emit_dec
    mov byte [rdi], '-'
    inc rdi
    mov eax, r9d
    call .emit_dec
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    add rdi, 2

    mov rsi, r10
.extra:
    mov al, [rsi]
    test al, al
    jz .extra_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .extra
.extra_done:
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    add rdi, 2

    lea rax, [tcp_tx_buf]
    sub rdi, rax
    mov rax, rdi

    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    ret

; .emit_dec: eax = unsigned 32-bit value, writes decimal ASCII digits at
; [rdi] and advances rdi past them. No leading zeroes, "0" for zero.
.emit_dec:
    push rbx
    push rcx
    push rdx
    test eax, eax
    jnz .ed_digits
    mov byte [rdi], '0'
    inc rdi
    jmp .ed_done
.ed_digits:
    xor ecx, ecx
.ed_loop:
    test eax, eax
    jz .ed_reverse
    mov ebx, 10
    xor edx, edx
    div ebx
    add dl, '0'
    push rdx
    inc ecx
    jmp .ed_loop
.ed_reverse:
    test ecx, ecx
    jz .ed_done
.ed_pop:
    pop rdx
    mov [rdi], dl
    inc rdi
    dec ecx
    jnz .ed_pop
.ed_done:
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; update_fetch_component: downloads and writes one component, in
; UPDATE_CHUNK_BYTES pieces, straight to its final on-disk LBAs, all
; over a single persistent TLS session (tls_open_session once, then
; tls_exchange_on_session per chunk, tls_close_session at the end --
; see tls.asm) rather than a fresh TCP+TLS handshake per chunk.
; In (all pre-set by the caller):
;   update_comp_url  = full https:// URL for this component
;   update_comp_lba  = base LBA to write it at
;   update_comp_size = expected size in bytes
;   update_comp_crc  = expected crc32 of the whole file
; Out: al = 1 on success (written and CRC-verified), al = 0 on any
;      failure (bad URL, network/session error, a chunk shorter than
;      requested, a disk write error, or a final CRC32 mismatch).
;
; Register plan: r12d = component size (constant this call), r13d =
; bytes downloaded so far (persists across update_https_get_range_ka
; calls -- both survive because tls_recv_app_frame, which those calls
; loop on internally, explicitly saves/restores r12/r13). r8/r9/r10
; hold per-chunk write state and do NOT need to survive a network
; call, since they're only live between one call finishing and the
; next one starting.
; ============================================================
update_fetch_component:
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

    mov rsi, update_comp_url
    call http_parse_url
    jc .fail
    cmp byte [http_url_scheme], 1
    jne .fail

    ; disk_write_sector depends on disk_select_device having pointed
    ; [disk_use_ahci]/the active drive at the OS volume's own device --
    ; some other command run earlier in the session could have left it
    ; pointed at a mounted external drive instead (same reason fs_save
    ; re-selects [boot_device] before its own writes).
    movzx eax, byte [boot_device]
    call disk_select_device

    ; one persistent TLS session for the whole component instead of a
    ; fresh TCP+TLS handshake per UPDATE_CHUNK_BYTES chunk -- see
    ; tls_open_session/tls_exchange_on_session/tls_close_session in
    ; tls.asm. A large component previously needed dozens of fresh
    ; handshakes, which in practice against a real CDN was both slow
    ; and unreliable.
    mov byte [update_session_open], 0
    lea rsi, [http_host_buf]
    mov dx, [http_port]
    call tls_open_session
    jc .fail
    mov byte [update_session_open], 1

    mov dword [update_crc_state], 0xFFFFFFFF
    xor r13d, r13d
    mov r12d, [update_comp_size]

    ; total chunk count for progress printing below, ceil(size/chunk).
    ; This is purely cosmetic (so a long fetch shows visible forward
    ; progress instead of looking hung behind tls.asm's diagnostic
    ; packet trace) -- it plays no part in the transfer/retry logic.
    mov eax, r12d
    add eax, UPDATE_CHUNK_BYTES - 1
    xor edx, edx
    mov ecx, UPDATE_CHUNK_BYTES
    div ecx
    mov [update_total_chunks], eax
    mov dword [update_chunk_index], 0

.loop:
    cmp r13d, r12d
    jae .alldone

    ; let Esc cancel a stuck update between chunks -- a retry loop on a
    ; dead connection could otherwise sit here for several seconds
    ; per chunk with no way out until UPDATE_MAX_RETRIES is exhausted.
    cmp byte [kill_flag], 0
    jne .fail

    mov eax, r12d
    sub eax, r13d
    cmp eax, UPDATE_CHUNK_BYTES
    jbe .len_ok
    mov eax, UPDATE_CHUNK_BYTES
.len_ok:
    mov [update_chunk_want], eax

    ; visible progress line -- tls_connect_and_handshake turns on
    ; nic_diag_verbose for the whole connect+handshake, which floods
    ; the console with raw packet dumps on every chunk; without this,
    ; a long, retry-heavy fetch is indistinguishable from a genuine
    ; hang since nothing here otherwise says "still working."
    inc dword [update_chunk_index]
    mov rsi, msg_update_chunk_progress
    mov al, [cur_normal_attr]
    call print_string_attr
    mov eax, [update_chunk_index]
    call tcp_print_dec
    mov rsi, msg_update_chunk_of
    call print_string
    mov eax, [update_total_chunks]
    call tcp_print_dec
    mov rsi, newline_str
    call print_string

    mov byte [update_retry_count], 0
.retry:
    mov edx, r13d
    mov ecx, r13d
    add ecx, [update_chunk_want]
    dec ecx
    call update_https_get_range_ka
    jc .retry_fail

    cmp ecx, [update_chunk_want]
    jne .retry_fail
    jmp .got_chunk

.retry_fail:
    inc byte [update_retry_count]
    cmp byte [update_retry_count], UPDATE_MAX_RETRIES
    jae .fail
    cmp byte [kill_flag], 0
    jne .fail
    mov rsi, msg_update_chunk_retry
    mov al, [cur_normal_attr]
    call print_string_attr
    movzx eax, byte [update_retry_count]
    call tcp_print_dec
    mov rsi, msg_update_chunk_of_retries
    call print_string
    mov eax, UPDATE_MAX_RETRIES
    call tcp_print_dec
    mov rsi, msg_update_chunk_retry_tail
    call print_string
    mov edi, UPDATE_RETRY_DELAY_MS
    call sleep_ms

    ; whatever failed -- transport error, or a short/mismatched body
    ; that desyncs where the next response would start -- the session
    ; isn't safe to keep reusing. Close it (best-effort; it may
    ; already be half-dead) and open a fresh one for the retry, same
    ; as update_fetch_component's own entry above.
    mov byte [update_session_open], 0
    call tls_close_session
    mov rsi, update_comp_url
    call http_parse_url
    jc .fail
    lea rsi, [http_host_buf]
    mov dx, [http_port]
    call tls_open_session
    jc .fail
    mov byte [update_session_open], 1
    jmp .retry

.got_chunk:
    ; running CRC32 over this chunk. update_crc32_update clobbers rax
    ; (it's used as the running accumulator and never restored, despite
    ; the "preserves everything" comment on the function) -- so the
    ; chunk pointer has to be captured into r8 *before* the call, not
    ; read back out of rax afterward.
    mov rsi, rax
    mov r8, rax
    mov r9d, ecx
    mov rcx, r9
    call update_crc32_update

    ; write it out sector by sector, zero-padding a final partial
    ; sector (only ever the truly last chunk of the whole component can
    ; have one, since UPDATE_CHUNK_BYTES itself is sector-aligned)
    mov eax, r13d
    shr eax, 9
    add eax, [update_comp_lba]
    mov r10, rax

.wsec:
    cmp r9d, 0
    je .chunk_done
    cmp r9d, 512
    jae .full_sector

    lea rdi, [update_sector_pad]
    mov rsi, r8
    mov ecx, r9d
    rep movsb
    mov ecx, 512
    sub ecx, r9d
    xor al, al
    rep stosb

    mov rax, r10
    lea rsi, [update_sector_pad]
    call disk_write_sector
    jc .fail

    xor r9d, r9d
    jmp .wsec

.full_sector:
    mov rax, r10
    mov rsi, r8
    call disk_write_sector
    jc .fail

    add r8, 512
    sub r9d, 512
    inc r10
    jmp .wsec

.chunk_done:
    mov eax, [update_chunk_want]
    add r13d, eax
    jmp .loop

.alldone:
    call update_crc32_final
    cmp eax, [update_comp_crc]
    jne .fail

    cmp byte [update_session_open], 0
    je .adone_no_session
    call tls_close_session
    mov byte [update_session_open], 0
.adone_no_session:

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
    mov al, 1
    ret

.fail:
    cmp byte [update_session_open], 0
    je .fail_no_session
    call tls_close_session
    mov byte [update_session_open], 0
.fail_no_session:

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
    xor al, al
    ret

; ============================================================
; CRC32, incremental across many calls (same table/polynomial as
; zip.asm's zip_crc32 -- reused unchanged -- just split into
; init/update/final so it can accumulate across many small chunks
; instead of running over one whole in-memory buffer at once).
; State lives in update_crc_state, set to 0xFFFFFFFF by
; update_fetch_component before the first chunk of each component.
; ============================================================

; update_crc32_update: rsi = buf, rcx = len. Updates update_crc_state.
; Preserves rbx/rcx/rdx/rsi. Does NOT preserve rax -- it's the running
; accumulator and is left holding mid-computation state on return.
; Callers that need their own rax across this call must save it first.
update_crc32_update:
    push rbx
    push rcx
    push rdx
    push rsi
    mov eax, [update_crc_state]
.loop:
    test rcx, rcx
    jz .done
    movzx edx, byte [rsi]
    xor dl, al
    movzx edx, dl
    mov edx, [zip_crc32_table + rdx*4]
    shr eax, 8
    xor eax, edx
    inc rsi
    dec rcx
    jmp .loop
.done:
    mov [update_crc_state], eax
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; update_crc32_final: returns eax = the finished CRC32 (state XOR'd
; with 0xFFFFFFFF, same as zip_crc32's .done step).
update_crc32_final:
    mov eax, [update_crc_state]
    xor eax, 0xFFFFFFFF
    ret

; ============================================================
; update_str_find: rdi = haystack (NUL-terminated), rsi = needle
; (NUL-terminated, non-empty). Returns rax = ptr to first match in
; haystack, or 0 if none. Preserves rdi/rsi/rdx/rcx/rbx.
; ============================================================
update_str_find:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdx, rsi
.outer:
    cmp byte [rdi], 0
    je .notfound
    mov rbx, rdi
    mov rsi, rdx
.inner:
    mov cl, [rsi]
    test cl, cl
    jz .match
    mov al, [rbx]
    test al, al
    jz .next
    cmp al, cl
    jne .next
    inc rbx
    inc rsi
    jmp .inner
.match:
    mov rax, rdi
    jmp .out
.next:
    inc rdi
    jmp .outer
.notfound:
    xor rax, rax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; update_parse_hex_run: rsi = hex digit string (0-9/A-F/a-f). Returns
; eax = value, advances rsi past the digits consumed. Caller must have
; already verified [rsi] is a hex digit, same contract as
; parse_uint_run.
; ============================================================
update_parse_hex_run:
    push rbx
    push rcx
    xor eax, eax
.loop:
    mov bl, [rsi]
    cmp bl, '0'
    jb .done
    cmp bl, '9'
    jbe .digit
    cmp bl, 'A'
    jb .done
    cmp bl, 'F'
    jbe .upper
    cmp bl, 'a'
    jb .done
    cmp bl, 'f'
    ja .done
    sub bl, 'a'
    add bl, 10
    jmp .take
.upper:
    sub bl, 'A'
    add bl, 10
    jmp .take
.digit:
    sub bl, '0'
.take:
    movzx ecx, bl
    shl eax, 4
    add eax, ecx
    inc rsi
    jmp .loop
.done:
    pop rcx
    pop rbx
    ret

; ============================================================
; update_manifest_get: rdi = manifest text (haystack), rsi = key
; needle (e.g. update_boot_name -- "boot.bin"... actually the "="
; itself is NOT part of these name constants, see below), rdx = ptr to
; a dword to receive the size, rcx = ptr to a dword to receive the
; crc32. Looks for "<name>=" in the haystack, then "<size>,<hexcrc>"
; right after it. CF=0 on success, CF=1 if not found or malformed.
; Does not modify rdi, so a caller can reuse the same haystack pointer
; for repeated calls (see sys_do_update's three manifest lookups).
; ============================================================
update_manifest_get:
    push rbx
    push r8
    push r9
    push r10
    mov r8, rdx                  ; size-out ptr
    mov r9, rcx                  ; crc-out ptr
    mov r10, rdi                 ; save haystack ptr -- rdi gets reused below

    ; build "<name>=" into a scratch buffer (needle passed in is just
    ; the bare filename, e.g. update_boot_name -- "boot.bin")
    lea rdi, [update_manifest_key_buf]
    call str_copy                ; rsi=name (caller's), rdi=key buf
    lea rdi, [update_manifest_key_buf]
    mov rsi, update_equals
    call str_append               ; key buf now "<name>="

    mov rdi, r10                  ; restore haystack
    lea rsi, [update_manifest_key_buf]
    call update_str_find          ; rax = match ptr, or 0
    test rax, rax
    jz .fail

    ; advance rax past "<name>=" itself, walking the key buffer's own
    ; length alongside it
    mov rbx, rax
    lea rsi, [update_manifest_key_buf]
.skip:
    cmp byte [rsi], 0
    je .skipped
    inc rbx
    inc rsi
    jmp .skip
.skipped:
    mov rsi, rbx                  ; rsi -> first digit of the size
    cmp byte [rsi], '0'
    jb .fail
    cmp byte [rsi], '9'
    ja .fail
    call parse_uint_run            ; eax = size, rsi advances past it
    mov [r8], eax

    cmp byte [rsi], ','
    jne .fail
    inc rsi

    ; require at least one hex digit before trusting update_parse_hex_run
    ; (which silently returns 0 rather than erroring on a non-hex byte)
    mov al, [rsi]
    cmp al, '0'
    jb .fail
    cmp al, '9'
    jbe .hexok
    cmp al, 'A'
    jb .fail
    cmp al, 'F'
    jbe .hexok
    cmp al, 'a'
    jb .fail
    cmp al, 'f'
    ja .fail
.hexok:
    call update_parse_hex_run       ; eax = crc32, rsi advances
    mov [r9], eax

    pop r10
    pop r9
    pop r8
    pop rbx
    clc
    ret
.fail:
    pop r10
    pop r9
    pop r8
    pop rbx
    stc
    ret

; ------------------------------------------------------------
; update.asm data
; ------------------------------------------------------------
update_version_url:   db "https://raw.githubusercontent.com/TheServer-lab/shellybin/refs/heads/main/sys/version.sly", 0
update_url_prefix:    db "https://raw.githubusercontent.com/TheServer-lab/shellybin/refs/heads/main/sys/", 0
update_manifest_name: db "manifest.sly", 0
update_manifest_name_alt: db "mainfest.sly", 0   ; the spelling actually
                                                  ; present in the shellybin
                                                  ; repo (see the fallback
                                                  ; in sys_do_update)
update_boot_name:      db "boot.bin", 0
update_stage2_name:    db "stage2.bin", 0
update_kernel_name:    db "kernel_body.bin", 0
update_cv_prefix:      db "current-version=", 0
update_slash:          db "/", 0
update_equals:         db "=", 0

msg_update_checking:        db "sys: checking for updates...", 10, 0
msg_update_uptodate:        db "sys: already up to date.", 10, 0
msg_update_found:            db "sys: update available: ", 0
msg_update_fetching_kernel:  db "sys: fetching kernel_body.bin...", 10, 0
msg_update_fetching_stage2:  db "sys: fetching stage2.bin...", 10, 0
msg_update_fetching_boot:    db "sys: fetching boot.bin...", 10, 0
msg_update_done:              db "sys: update complete. Reboot to apply.", 10, 0
msg_update_compfail:          db "sys: update FAILED partway through -- do not rely on the current boot chain. Re-run 'auth sys update' before rebooting.", 10, 0
msg_update_chunk_progress:    db "  chunk ", 0
msg_update_chunk_of:          db "/", 0
msg_update_chunk_retry:       db "  chunk failed, retrying (attempt ", 0
msg_update_chunk_of_retries:  db "/", 0
msg_update_chunk_retry_tail:  db ")...", 10, 0
msg_update_badsize:            db "sys: update aborted -- manifest claims a component larger than its on-disk budget.", 10, 0
msg_update_badmanifest:        db "sys: update aborted -- could not parse version.sly/manifest.sly.", 10, 0
msg_update_neterr:              db "sys: update aborted -- network error talking to the update server.", 10, 0

update_remote_ver_buf: times 32 db 0
update_local_ver_buf:  times 32 db 0
update_manifest_key_buf: times 24 db 0

update_url_buf:  times 256 db 0
update_comp_url: times 256 db 0

update_exp_size: times 3 dd 0     ; 0=boot, 1=stage2, 2=kernel_body
update_exp_crc:  times 3 dd 0

update_comp_lba:  dd 0
update_comp_size: dd 0
update_comp_crc:  dd 0
update_chunk_want: dd 0
update_crc_state:  dd 0
update_retry_count: db 0
update_manifest_alt: db 0        ; 1 = already fell back to the repo's
                                 ; "mainfest.sly" spelling this run
update_total_chunks: dd 0
update_chunk_index:  dd 0
update_session_open: db 0       ; 1 while a tls_open_session'd connection
                                 ; is live -- guards .fail/.alldone below
                                 ; from sending a close on a connection
                                 ; that was never opened (e.g. a failure
                                 ; before tls_open_session even ran) or
                                 ; one already closed by a retry.

update_sector_pad: times 512 db 0
