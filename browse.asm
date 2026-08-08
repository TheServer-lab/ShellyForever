; ============================================================
;  browse.asm  --  Text-based web browser (Milestone E)
;  Command: browse <url>
;
;  A Lynx-style plain-text browser:
;    - HTTP page downloads (built on the Milestone D http/tcp stack)
;    - HTML stripped to readable text, <a href> links collected
;    - Hyperlink selection by number ([N] markers in the text)
;    - Back / Forward navigation
;    - Bookmarks (session only)
;    - "t" saves the current page's raw body to a file (take-style)
;
;  The stripped page text lives in tcp_rx_buf (in-place compacted from
;  the raw body, which is staged in http_rx_buf). See browse_fetch_url.
;
;  Included from kernel.asm; inherits BITS 64.
; ============================================================

BROWSE_LINKS_MAX equ 64
BROWSE_LINK_BUF  equ 128          ; bytes per stored URL (links, history, bookmarks)
BROWSE_HIST_MAX  equ 16
BROWSE_BMK_MAX   equ 16
BROWSE_PAGE_MAX  equ TCP_PAYLOAD_MAX   ; page text = tcp_rx_buf (1536 bytes)
BROWSE_VROWS     equ 23               ; visible page rows on screen (80x25)

ATTR_BRW_HEADER equ 0x1F          ; white on blue
ATTR_BRW_STATUS equ 0x1E          ; yellow on blue
ATTR_BRW_LINK   equ 0x0E          ; yellow

; ============================================================
;  browse_emit: al = char -> writes to [rdi] (output ptr), advances rdi.
;  out: CF=1 if output buffer full (char NOT written).
browse_emit:
    cmp rdi, r14
    jae .emit_full
    mov [rdi], al
    inc rdi
    clc
    ret
.emit_full:
    stc
    ret

; browse_cp_str: rsi = NUL-terminated src -> copies to rdi (advances rdi
; past the terminating NUL).
browse_cp_str:
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    test al, al
    jnz browse_cp_str
    ret

; browse_cp_str_max: rsi = src, rdi = dst, rcx = max bytes (incl NUL).
; Copies at most rcx-1 chars plus a NUL. rdi advances.
browse_cp_str_max:
    push rsi
    push rdi
    push rcx
    test rcx, rcx
    jz .bcsm_zero
    dec rcx
.bcsm_loop:
    test rcx, rcx
    jz .bcsm_done
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .bcsm_done
    inc rsi
    inc rdi
    dec rcx
    jmp .bcsm_loop
.bcsm_zero:
    mov byte [rdi], 0
    jmp .bcsm_out
.bcsm_done:
    mov byte [rdi], 0
.bcsm_out:
    pop rcx
    pop rdi
    pop rsi
    ret

; browse_read_tagname: rsi = ptr, rdi = out buf. Reads [A-Za-z]* into the
; buffer (lowercased, NUL-terminated). rsi ends at the first non-letter.
; r13 = name length.
browse_read_tagname:
    push rdi
    xor r13, r13
.rtn_loop:
    cmp rsi, r8
    jae .rtn_done
    mov al, [rsi]
    cmp al, 'a'
    jb .rtn_chkA
    cmp al, 'z'
    jbe .rtn_keep
.rtn_chkA:
    cmp al, 'A'
    jb .rtn_done
    cmp al, 'Z'
    ja .rtn_done
    or al, 0x20
.rtn_keep:
    cmp r13, 20
    jae .rtn_done
    mov [rdi], al
    inc rdi
    inc r13
    inc rsi
    jmp .rtn_loop
.rtn_done:
    mov byte [rdi], 0
    ; h1..h6: a lone "h" followed by a heading digit keeps the digit, so
    ; browse_check_block can tell headings apart from a bare "h".
    cmp r13, 1
    jne .rtn_fin
    mov al, [rdi-1]
    or al, 0x20
    cmp al, 'h'
    jne .rtn_fin
    cmp rsi, r8
    jae .rtn_fin
    mov al, [rsi]
    cmp al, '1'
    jb .rtn_fin
    cmp al, '6'
    ja .rtn_fin
    mov [rdi], al
    inc rdi
    inc r13
    inc rsi
    mov byte [rdi], 0
.rtn_fin:
    pop rdi
    ret

; browse_check_block: checks browse_tag_buf against the block-tag list.
; out: CF=1 if it's a block-level tag that should force a newline.
browse_check_block:
    push rsi
    push rdi
    lea rsi, [browse_tag_buf]
    lea rdi, [bstr_p]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_div]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_br]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_li]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_tr]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_td]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_th]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_ul]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_ol]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_dl]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_dt]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_dd]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_table]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_blockquote]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_pre]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_hr]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_center]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_form]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_section]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_article]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_header]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_footer]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_nav]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_main]
    call str_eq
    cmp al, 1
    je .bc_yes
    lea rdi, [bstr_aside]
    call str_eq
    cmp al, 1
    je .bc_yes
    ; h1..h6
    lea rsi, [browse_tag_buf]
    mov al, [rsi]
    or al, 0x20
    cmp al, 'h'
    jne .bc_no
    mov al, [rsi+1]
    cmp al, '1'
    jb .bc_no
    cmp al, '6'
    ja .bc_no
    jmp .bc_yes
.bc_yes:
    pop rdi
    pop rsi
    stc
    ret
.bc_no:
    pop rdi
    pop rsi
    clc
    ret

; browse_skip_to_gt: rsi = ptr, r8 = input end. Advances rsi to just past
; the next '>'. out: CF=1 if no '>' found.
browse_skip_to_gt:
.stg_loop:
    cmp rsi, r8
    jae .stg_fail
    cmp byte [rsi], '>'
    je .stg_found
    inc rsi
    jmp .stg_loop
.stg_found:
    inc rsi
    clc
    ret
.stg_fail:
    stc
    ret

; browse_emit_newline: emits a newline (if not suppressed). Uses r9 = the
; consecutive-newline counter and r10 = last emitted char.
browse_emit_newline:
    cmp r10, 0
    je .en_skip               ; nothing emitted yet - no leading blank lines
    cmp r9, 2
    jae .en_skip
    inc r9
    mov al, 10
    movzx eax, al
    mov r10, rax
    call browse_emit
.en_skip:
    ret

; browse_emit_link_marker: emits "[N]" where N = [browse_link_cnt] (already
; incremented). Advances rdi.
browse_emit_link_marker:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [browse_num_tmp]
    mov eax, [browse_link_cnt]
    call int_to_str
    pop rdi
    mov al, '['
    call browse_emit
    jc .elm_done
    lea rsi, [browse_num_tmp]
.elm_digit:
    mov al, [rsi]
    test al, al
    jz .elm_digit_done
    call browse_emit
    jc .elm_done
    inc rsi
    jmp .elm_digit
.elm_digit_done:
    mov al, ']'
    call browse_emit
.elm_done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
;  browse_strip_html -- HTML -> plain text, collecting links.
;  in:  rsi = body start (http_rx_buf), ecx = body length
;  out: page text written to tcp_rx_buf (NUL-terminated), eax = length,
;       browse_link_cnt = number of links collected. CF=1 if truncated.
;
;  Registers used across the whole routine (kept stable between the
;  many sub-paths):
;    rsi = input ptr     rdi = output ptr     r8 = input end
;    r9  = newline cap   r10 = last char      r14 = output cap
;    r13 = transient     r12 = transient      r11 = transient
browse_strip_html:
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

    mov r8, rsi
    add r8, rcx                 ; r8 = end of input
    lea rdi, [tcp_rx_buf]
    lea r14, [tcp_rx_buf + BROWSE_PAGE_MAX - 1]
    mov dword [browse_link_cnt], 0
    xor r9, r9
    xor r10, r10

.loop:
    cmp rsi, r8
    jae .done
    mov al, [rsi]
    cmp al, '<'
    je .tag
    cmp al, 13
    je .next
    cmp al, ' '
    je .space
    cmp al, 9
    je .space
    cmp al, 10
    je .newline
    cmp al, '&'
    je .entity
    ; plain character
    movzx eax, al
    mov r10, rax
    call browse_emit
    jc .overflow
    xor r9, r9
    jmp .next

.space:
    cmp r10, ' '
    je .next
    cmp r10, 10
    je .next
    cmp r10, 0
    je .next
    mov al, ' '
    movzx eax, al
    mov r10, rax
    call browse_emit
    jc .overflow
    jmp .next

.newline:
    call browse_emit_newline
    jc .overflow
    jmp .next

.entity:
    ; decode a small set of entities; anything unknown is skipped whole.
    mov r12, rsi                ; '&' position
    lea rbx, [browse_tag_buf]
    lea rsi, [r12+1]
    xor r13, r13                ; token length
.ent_scan:
    cmp rsi, r8
    jae .ent_skip_all
    mov al, [rsi]
    cmp al, ';'
    je .ent_semi
    cmp r13, 8
    jae .ent_skip_all
    mov [rbx], al
    inc rbx
    inc r13
    inc rsi
    jmp .ent_scan
.ent_semi:
    mov byte [rbx], 0
    mov r11, rsi
    inc r11                     ; r11 = position after ';'
    lea rsi, [browse_tag_buf]
    push rdi
    lea rdi, [ent_amp]
    call str_eq
    pop rdi
    cmp al, 1
    jne .ent_t_lt
    mov al, '&'
    jmp .ent_have
.ent_t_lt:
    push rdi
    lea rdi, [ent_lt]
    call str_eq
    pop rdi
    cmp al, 1
    jne .ent_t_gt
    mov al, '<'
    jmp .ent_have
.ent_t_gt:
    push rdi
    lea rdi, [ent_gt]
    call str_eq
    pop rdi
    cmp al, 1
    jne .ent_t_quot
    mov al, '>'
    jmp .ent_have
.ent_t_quot:
    push rdi
    lea rdi, [ent_quot]
    call str_eq
    pop rdi
    cmp al, 1
    jne .ent_t_apos
    mov al, '"'
    jmp .ent_have
.ent_t_apos:
    push rdi
    lea rdi, [ent_apos]
    call str_eq
    pop rdi
    cmp al, 1
    jne .ent_t_nbsp
    mov al, 39
    jmp .ent_have
.ent_t_nbsp:
    push rdi
    lea rdi, [ent_nbsp]
    call str_eq
    pop rdi
    cmp al, 1
    jne .ent_t_num
    mov al, ' '
    jmp .ent_have
.ent_t_num:
    ; &#NN; / &#xNN; numeric
    lea rsi, [browse_tag_buf]
    mov al, [rsi]
    cmp al, '#'
    jne .ent_skip
    inc rsi
    mov al, [rsi]
    cmp al, 'x'
    je .ent_num_hex
    cmp al, 'X'
    je .ent_num_hex
    xor r13, r13
.ent_nd:
    mov al, [rsi]
    cmp al, '0'
    jb .ent_num_done
    cmp al, '9'
    ja .ent_num_done
    imul r13d, r13d, 10
    movzx eax, al
    sub eax, '0'
    add r13d, eax
    inc rsi
    jmp .ent_nd
.ent_num_hex:
    inc rsi
    xor r13, r13
.ent_nh:
    mov al, [rsi]
    cmp al, '0'
    jb .ent_num_done
    cmp al, '9'
    ja .ent_nh_af
    imul r13d, r13d, 16
    movzx eax, al
    sub eax, '0'
    add r13d, eax
    inc rsi
    jmp .ent_nh
.ent_nh_af:
    cmp al, 'a'
    jb .ent_num_done
    cmp al, 'f'
    ja .ent_num_done
    imul r13d, r13d, 16
    movzx eax, al
    sub eax, 'a'
    add eax, 10
    add r13d, eax
    inc rsi
    jmp .ent_nh
.ent_num_done:
    cmp r13d, 32
    jb .ent_skip
    cmp r13d, 126
    ja .ent_skip
    mov eax, r13d
    jmp .ent_have
.ent_have:
    ; al = char to emit
    mov rsi, r11
    movzx eax, al
    mov r10, rax
    call browse_emit
    jc .overflow
    xor r9, r9
    jmp .loop
.ent_skip:
    mov rsi, r11
    jmp .next
.ent_skip_all:
    mov rsi, r12
    inc rsi
    jmp .next

.tag:
    inc rsi
    cmp rsi, r8
    jae .done
    mov al, [rsi]
    cmp al, '!'
    je .doctype_or_comment
    cmp al, '/'
    je .close_tag
    ; opening tag: read name into browse_tag_buf
    push rdi
    lea rdi, [browse_tag_buf]
    call browse_read_tagname
    pop rdi
    test r13, r13
    jz .skip_tag
    ; rsi is now the input position right after the tag name. Save it in r12:
    ; the str_eq comparisons below re-point rsi at browse_tag_buf, and
    ; str_eq preserves that, so without this every tag would be parsed from
    ; the wrong buffer (data section) instead of the HTTP body.
    mov r12, rsi
    ; script / style -> skip raw content until the matching close tag
    lea rsi, [browse_tag_buf]
    push rdi
    lea rdi, [str_script]
    call str_eq
    pop rdi
    cmp al, 1
    je .skip_raw
    lea rsi, [browse_tag_buf]
    push rdi
    lea rdi, [str_style]
    call str_eq
    pop rdi
    cmp al, 1
    je .skip_raw
    ; anchor?
    lea rsi, [browse_tag_buf]
    push rdi
    lea rdi, [str_a]
    call str_eq
    pop rdi
    cmp al, 1
    je .anchor_tag
    ; block tag?
    call browse_check_block
    jc .tag_block
    mov rsi, r12
    jmp .skip_tag
.tag_block:
    mov rsi, r12

.block_nl:
    call browse_emit_newline
    jc .overflow
    jmp .skip_tag

.close_tag:
    inc rsi
    cmp rsi, r8
    jae .done
    push rdi
    lea rdi, [browse_tag_buf]
    call browse_read_tagname
    pop rdi
    test r13, r13
    jz .skip_tag
    call browse_check_block
    jc .block_nl
    jmp .skip_tag

.doctype_or_comment:
    inc rsi
    cmp rsi, r8
    jae .done
    cmp byte [rsi], '-'
    jne .skip_tag               ; <!DOCTYPE ...>
    inc rsi
    cmp rsi, r8
    jae .done
    cmp byte [rsi], '-'
    jne .skip_tag
    inc rsi
.cmt_loop:
    cmp rsi, r8
    jae .done
    cmp byte [rsi], '-'
    jne .cmt_next
    cmp byte [rsi+1], '-'
    jne .cmt_next
    cmp byte [rsi+2], '>'
    je .cmt_end
.cmt_next:
    inc rsi
    jmp .cmt_loop
.cmt_end:
    add rsi, 3
    jmp .loop

.skip_raw:
    ; rsi must be the input position after the opening tag name (restored
    ; from r12 - the str_eq checks above left rsi at browse_tag_buf). Skip
    ; the rest of the opening tag, then scan for "</name".
    mov rsi, r12
    call browse_skip_to_gt
    jc .done
    mov eax, r13d
    mov [browse_tag_len], eax
.skip_raw_loop:
    cmp rsi, r8
    jae .done
    cmp byte [rsi], '<'
    jne .skip_raw_next
    cmp byte [rsi+1], '/'
    jne .skip_raw_next
    ; candidate closing tag name at rsi+2
    push rsi
    lea rsi, [rsi+2]
    push rdi
    lea rdi, [browse_tag_buf2]
    call browse_read_tagname
    pop rdi
    mov eax, [browse_tag_len]
    cmp r13d, eax
    jne .skip_raw_cand_no
    lea rsi, [browse_tag_buf2]
    push rdi
    lea rdi, [browse_tag_buf]
    call str_eq
    pop rdi
    cmp al, 1
    jne .skip_raw_cand_no
    pop rdx                     ; discard saved rsi - resume after the close tag name
    jmp .loop
.skip_raw_cand_no:
    pop rsi
    inc rsi
    jmp .skip_raw_loop
.skip_raw_next:
    inc rsi
    jmp .skip_raw_loop

.anchor_tag:
    ; rsi must be the input position after the "a" name (restored from r12 -
    ; the str_eq chain above left rsi at browse_tag_buf). Scan the rest of
    ; the tag for href="..." / href='...' / href=...
    mov rsi, r12
    mov r13, rsi
.href_scan:
    cmp r13, r8
    jae .skip_tag
    mov al, [r13]
    cmp al, '>'
    je .skip_tag
    ; reject "href" in the middle of a word (e.g. "thref")
    cmp r13, rsi
    je .href_check
    mov al, [r13-1]
    cmp al, 'a'
    jb .href_chkA
    cmp al, 'z'
    jbe .href_scan_next
.href_chkA:
    cmp al, 'A'
    jb .href_check
    cmp al, 'Z'
    jbe .href_scan_next
    cmp al, '-'
    je .href_scan_next
    cmp al, '0'
    jb .href_check
    cmp al, '9'
    jbe .href_scan_next
.href_check:
    mov eax, [r13]
    or eax, 0x20202020
    cmp eax, 'href'
    jne .href_scan_next
    ; check the char after "href"
    mov al, [r13+4]
    cmp al, ' '
    je .href_found
    cmp al, 9
    je .href_found
    cmp al, 10
    je .href_found
    cmp al, '='
    je .href_found
    cmp al, '>'
    je .href_scan_next
.href_scan_next:
    inc r13
    jmp .href_scan

.href_found:
    add r13, 4
.hf_ws:
    cmp r13, r8
    jae .skip_tag
    mov al, [r13]
    cmp al, ' '
    je .hf_ws_inc
    cmp al, 9
    je .hf_ws_inc
    jmp .hf_eq
.hf_ws_inc:
    inc r13
    jmp .hf_ws
.hf_eq:
    cmp byte [r13], '='
    jne .skip_tag
    inc r13
.hf_ws2:
    cmp r13, r8
    jae .skip_tag
    mov al, [r13]
    cmp al, ' '
    je .hf_ws2_inc
    cmp al, 9
    je .hf_ws2_inc
    jmp .hf_quote
.hf_ws2_inc:
    inc r13
    jmp .hf_ws2
.hf_quote:
    ; set up the link slot
    mov r12d, [browse_link_cnt]
    cmp r12, BROWSE_LINKS_MAX
    jae .skip_tag
    imul r12d, BROWSE_LINK_BUF
    lea r12, [browse_link_urls + r12]
    mov r11, r12
    add r11, BROWSE_LINK_BUF - 1
    mov al, [r13]
    inc r13
    cmp al, '"'
    je .hf_copy
    cmp al, 39
    je .hf_copy
    dec r13
    jmp .hf_copy_nq
.hf_copy:
    cmp r13, r8
    jae .hf_copy_end
    mov al, [r13]
    cmp al, '"'
    je .hf_copy_end
    cmp al, 39
    je .hf_copy_end
    cmp r12, r11
    jae .hf_copy_full
    mov [r12], al
    inc r12
    inc r13
    jmp .hf_copy
.hf_copy_nq:
    cmp r13, r8
    jae .hf_copy_end
    mov al, [r13]
    cmp al, ' '
    je .hf_copy_end
    cmp al, 9
    je .hf_copy_end
    cmp al, 10
    je .hf_copy_end
    cmp al, '>'
    je .hf_copy_end
    cmp r12, r11
    jae .hf_copy_full
    mov [r12], al
    inc r12
    inc r13
    jmp .hf_copy_nq
.hf_copy_full:
    mov byte [r12], 0
    inc dword [browse_link_cnt]
    call browse_emit_link_marker
    jc .overflow
    jmp .skip_tag
.hf_copy_end:
    mov byte [r12], 0
    inc dword [browse_link_cnt]
    call browse_emit_link_marker
    jc .overflow
    jmp .skip_tag

.skip_tag:
    cmp rsi, r8
    jae .done
    mov al, [rsi]
    cmp al, '>'
    je .tag_end
    inc rsi
    jmp .skip_tag
.tag_end:
    inc rsi
    jmp .loop

.next:
    inc rsi
    jmp .loop

.done:
    clc
    jmp .done_full
.overflow:
    stc
.done_full:
    mov byte [rdi], 0
    lea rax, [tcp_rx_buf]
    sub rdi, rax
    mov eax, edi
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

; ============================================================
;  browse_norm_path -- collapses "./", "../", "//" in a URL path in place.
;  in: rsi = NUL-terminated path (inside browse_url_tmp)
;  out: normalized path written back at rsi; rdi = end ptr.
browse_norm_path:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15

    ; copy path to browse_url_tmp2 (safe scratch for segment reads)
    lea rdi, [browse_url_tmp2]
.bnp_copy:
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    test al, al
    jnz .bnp_copy

    lea r15, [browse_url_tmp2]     ; read ptr
    lea r14, [browse_seg_off]      ; segment offset table
    xor r12, r12                   ; segment count
    xor r13, r13                   ; leading-slash flag
.bnp_lead:
    cmp byte [r15], '/'
    jne .bnp_segs
    mov r13, 1
    inc r15
    jmp .bnp_lead
.bnp_segs:
    cmp byte [r15], 0
    je .bnp_assemble
.bnp_skip_slash:
    cmp byte [r15], '/'
    jne .bnp_have
    inc r15
    jmp .bnp_skip_slash
.bnp_have:
    cmp byte [r15], 0
    je .bnp_assemble
    cmp byte [r15], '.'
    jne .bnp_push
    cmp byte [r15+1], '/'
    je .bnp_skip_dot
    cmp byte [r15+1], 0
    je .bnp_assemble
    cmp byte [r15+1], '.'
    jne .bnp_push
    cmp byte [r15+2], '/'
    je .bnp_dotdot
    cmp byte [r15+2], 0
    je .bnp_assemble
    jmp .bnp_push
.bnp_skip_dot:
    inc r15
    jmp .bnp_segs
.bnp_dotdot:
    test r12, r12
    jz .bnp_skip_dot2
    dec r12
.bnp_skip_dot2:
    add r15, 2
    jmp .bnp_segs
.bnp_push:
    cmp r12, 63
    jae .bnp_assemble
    mov [r14], r15d
    add r14, 4
    inc r12
.bnp_seg_end:
    cmp byte [r15], '/'
    je .bnp_segs
    cmp byte [r15], 0
    je .bnp_assemble
    inc r15
    jmp .bnp_seg_end
.bnp_assemble:
    mov rdi, rsi                   ; rsi was the original path start (saved)
    test r13, r13
    jz .bnp_nolead
    mov byte [rdi], '/'
    inc rdi
.bnp_nolead:
    lea r14, [browse_seg_off]
    xor r15, r15
.bnp_asm_loop:
    cmp r15, r12
    jae .bnp_asm_end
    cmp r15, 0
    jne .bnp_asm_sep
    test r13, r13
    jne .bnp_asm_nosep
.bnp_asm_sep:
    mov byte [rdi], '/'
    inc rdi
.bnp_asm_nosep:
    mov eax, [r14]
    mov rbx, rax
.bnp_asm_copy:
    mov al, [rbx]
    cmp al, '/'
    je .bnp_asm_seg_done
    cmp al, 0
    je .bnp_asm_seg_done
    mov [rdi], al
    inc rdi
    inc rbx
    jmp .bnp_asm_copy
.bnp_asm_seg_done:
    add r14, 4
    inc r15
    jmp .bnp_asm_loop
.bnp_asm_end:
    mov byte [rdi], 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
;  browse_resolve_url -- resolve a (possibly relative) href against the
;  current page (browse_base_url) into an absolute URL.
;  in: rsi = href (NUL-terminated), rdi = out buf (browse_url_tmp)
;  out: CF=0 -> absolute URL in out buf; CF=1 -> not navigable.
browse_resolve_url:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15

    mov r13, rsi                 ; href ptr
    mov r14, rdi                 ; out start

    cmp byte [r13], 0
    je .bad
    ; absolute http:// ?
    mov eax, [r13]
    or eax, 0x20202020
    cmp eax, 'http'
    jne .not_abs
    cmp byte [r13+4], ':'
    jne .not_abs
    cmp byte [r13+5], '/'
    jne .not_abs
    cmp byte [r13+6], '/'
    jne .not_abs
    ; copy as-is
    mov rsi, r13
    mov rdi, r14
    call browse_cp_str
    clc
    jmp .out
.not_abs:
    ; skip non-navigable schemes
    mov al, [r13]
    cmp al, '#'
    je .bad
    cmp al, '?'
    je .bad
    mov eax, [r13]
    or eax, 0x20202020
    cmp eax, 'mail'
    je .bad
    mov eax, [r13]
    or eax, 0x20202020
    cmp eax, 'java'
    je .bad
    mov eax, [r13]
    or eax, 0x20202020
    cmp eax, 'data'
    je .bad
    mov eax, [r13]
    or eax, 0x20202020
    cmp eax, 'tel:'
    je .bad
    cmp byte [browse_base_url], 0
    je .bad
    ; relative: build scheme://host + basedir + href, then normalize.
    lea rbx, [browse_base_url + 7]
    mov r12, rbx
.rv_host_scan:
    cmp byte [r12], 0
    je .rv_host_done
    cmp byte [r12], '/'
    je .rv_host_done
    inc r12
    jmp .rv_host_scan
.rv_host_done:
    ; r12 = host end (in base). copy base[0..r12) to out
    mov rdi, r14
    lea rsi, [browse_base_url]
.rv_host_copy:
    cmp rsi, r12
    jae .rv_host_copy_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .rv_host_copy
.rv_host_copy_done:
    ; rdi = out ptr after scheme://host
    mov rsi, r13
    mov al, [rsi]
    cmp al, '/'
    je .rv_copy_href
    ; copy the base path directory (base path up to its last '/')
    mov rbx, r12
    mov r15, r12                 ; last '/' position (default: none)
.rv_base_scan:
    mov al, [rbx]
    cmp al, 0
    je .rv_base_done
    cmp al, '/'
    jne .rv_base_next
    mov r15, rbx
.rv_base_next:
    inc rbx
    jmp .rv_base_scan
.rv_base_done:
    mov rsi, r12
.rv_base_copy:
    cmp rsi, r15
    jae .rv_base_copy_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .rv_base_copy
.rv_base_copy_done:
    ; ensure a '/' separates host/dir from the href
    cmp byte [rdi-1], '/'
    je .rv_copy_href
    mov byte [rdi], '/'
    inc rdi
.rv_copy_href:
    mov rsi, r13
.rv_copy_href_loop:
    mov al, [rsi]
    cmp al, 0
    je .rv_copy_href_done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .rv_copy_href_loop
.rv_copy_href_done:
    mov byte [rdi], 0
    ; normalize the path portion
    lea rbx, [browse_base_url]
    mov rax, r12
    sub rax, rbx                 ; bytes of scheme+host
    lea rbx, [browse_url_tmp]
    add rbx, rax                 ; path start in the out buffer
    mov rsi, rbx
    call browse_norm_path
    clc
    jmp .out
.bad:
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
;  browse_make_error_page -- rsi = message; builds an error page into
;  tcp_rx_buf (replacing any current page).
browse_make_error_page:
    push rdi
    push rsi
    lea rdi, [tcp_rx_buf]
    call browse_cp_str
    mov byte [rdi], 10
    inc rdi
    lea rsi, [browse_base_url]
    call browse_cp_str
    ; append the underlying reason (dns / timeout / reset / tx) if we have one
    mov rsi, [tcp_err_msg]
    test rsi, rsi
    jz .bmp_no_reason
    mov byte [rdi], 10
    inc rdi
    mov byte [rdi], ' '
    inc rdi
.bmp_reason_loop:
    mov al, [rsi]
    cmp al, 10
    je .bmp_reason_done
    cmp al, 0
    je .bmp_reason_done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .bmp_reason_loop
.bmp_reason_done:
    mov byte [rdi], 10
    inc rdi
.bmp_no_reason:
    mov byte [rdi], 0
    mov dword [browse_scroll], 0
    mov dword [browse_link_cnt], 0
    pop rsi
    pop rdi
    ret

; ============================================================
;  browse_fetch_url -- fetch an absolute URL and strip it to a page.
;  in: rsi = absolute URL (NUL-terminated)
;  out: CF=0 -> page in tcp_rx_buf, eax = len, browse_link_cnt set
;       CF=1 -> tcp_rx_buf holds an error page
browse_fetch_url:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    mov r12, rsi
    lea rdi, [browse_base_url]
    call browse_cp_str

    mov qword [tcp_err_msg], 0

    lea rsi, [browse_base_url]
    call http_parse_url
    jc .bad_url

    call http_build_get
    mov [tcp_tx_len], eax

    call tcp_do_exchange
    jc .fetch_fail

    call http_find_body
    jc .no_body

    ; rax = body ptr, ecx = body len -> stage in http_rx_buf
    mov r13d, ecx
    cmp ecx, HTTP_RX_BUF_SIZE-1
    jbe .body_ok
    mov ecx, HTTP_RX_BUF_SIZE-1
.body_ok:
    mov r13d, ecx
    lea rdi, [http_rx_buf]
    mov rsi, rax
    rep movsb
    mov byte [rdi], 0
    mov [http_body_len], r13d

    ; strip HTML in-place into tcp_rx_buf
    lea rsi, [http_rx_buf]
    mov ecx, r13d
    call browse_strip_html
    mov dword [browse_scroll], 0
    clc
    jmp .out

.bad_url:
    lea rsi, [browse_err_msg_badurl]
    call browse_make_error_page
    stc
    jmp .out
.fetch_fail:
    lea rsi, [browse_err_msg_fetch]
    call browse_make_error_page
    stc
    jmp .out
.no_body:
    lea rsi, [browse_err_msg_nobody]
    call browse_make_error_page
    stc
    jmp .out
.out:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
;  browse_navigate -- push URL onto history and fetch it.
;  in: rsi = absolute URL
browse_navigate:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12

    mov r12, rsi

    cmp dword [browse_hist_cnt], 0
    jne .nav_append
    mov rdi, browse_hist
    mov rsi, r12
    call browse_cp_str
    mov dword [browse_hist_cnt], 1
    mov dword [browse_hist_pos], 0
    jmp .nav_fetch
.nav_append:
    mov eax, [browse_hist_pos]
    inc eax
    cmp eax, BROWSE_HIST_MAX
    jae .nav_shift
    mov [browse_hist_pos], eax
    inc eax
    mov [browse_hist_cnt], eax
    mov eax, [browse_hist_pos]
    jmp .nav_store
.nav_shift:
    xor rdx, rdx
.nav_shift_loop:
    cmp rdx, BROWSE_HIST_MAX-1
    jae .nav_shift_done
    mov eax, edx
    imul eax, eax, BROWSE_LINK_BUF
    lea rdi, [browse_hist + rax]
    lea rsi, [browse_hist + rax + BROWSE_LINK_BUF]
    mov ecx, BROWSE_LINK_BUF
    rep movsb
    inc rdx
    jmp .nav_shift_loop
.nav_shift_done:
    mov eax, [browse_hist_pos]
    dec eax
    mov [browse_hist_pos], eax
    mov eax, BROWSE_HIST_MAX-1
.nav_store:
    imul eax, eax, BROWSE_LINK_BUF
    lea rdi, [browse_hist + rax]
    mov rsi, r12
    call browse_cp_str
.nav_fetch:
    mov rsi, r12
    call browse_fetch_url
    pop r12
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
;  browse_count_lines -- eax = number of display lines in tcp_rx_buf text.
browse_count_lines:
    push rsi
    lea rsi, [tcp_rx_buf]
    xor eax, eax
    xor edx, edx
.cl_loop:
    mov dl, [rsi]
    cmp dl, 0
    je .cl_done
    cmp dl, 10
    jne .cl_notnl
    inc eax
.cl_notnl:
    inc rsi
    jmp .cl_loop
.cl_done:
    cmp dl, 10
    je .cl_out
    cmp dl, 0
    je .cl_out
    inc eax
.cl_out:
    pop rsi
    ret

; browse_clamp_scroll: keeps browse_scroll within [0, max] for the page.
browse_clamp_scroll:
    push rax
    push rcx
    call browse_count_lines
    cmp eax, BROWSE_VROWS
    jbe .cs_zero
    sub eax, BROWSE_VROWS
    mov ecx, [browse_scroll]
    cmp ecx, eax
    jbe .cs_ok
    mov [browse_scroll], eax
.cs_ok:
    pop rcx
    pop rax
    ret
.cs_zero:
    mov dword [browse_scroll], 0
    pop rcx
    pop rax
    ret

; browse_write_row: al = row, rsi = NUL-terminated string, bl = attr.
; Writes up to 80 columns, pads the rest with spaces.
browse_write_row:
    push rax
    push rcx
    push rsi
    push rdi
    movzx eax, al
    imul eax, eax, 80
    imul eax, eax, 2
    add rax, VGA_BASE
    mov rdi, rax
    mov rcx, 80
.wr_loop:
    mov al, [rsi]
    cmp al, 0
    je .wr_pad
    mov [rdi], al
    mov [rdi+1], bl
    inc rsi
    add rdi, 2
    dec rcx
    jnz .wr_loop
    jmp .wr_done
.wr_pad:
    mov word [rdi], 0x0720
    add rdi, 2
    dec rcx
    jnz .wr_pad
.wr_done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; browse_set_status: rsi = message -> copies into browse_status_msg (capped).
browse_set_status:
    push rcx
    push rdi
    push rsi
    lea rdi, [browse_status_msg]
    mov rcx, 39
    call browse_cp_str_max
    pop rsi
    pop rdi
    pop rcx
    ret

; browse_draw_status: builds + draws the bottom status row (row 24).
browse_draw_status:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13

    lea rdi, [browse_status_buf]
    mov byte [rdi], 0
    lea rsi, [msg_browse_hints]
    call browse_cp_str

    cmp byte [browse_link_entry], 0
    je .st_msg
    mov dword [rdi], ' lnk'
    add rdi, 4
    mov byte [rdi], ':'
    inc rdi
    mov eax, [browse_enter_val]
    call int_to_str
    mov rbx, rdi
.st_num_scan:
    cmp byte [rbx], 0
    je .st_num_done
    inc rbx
    jmp .st_num_scan
.st_num_done:
    mov rdi, rbx
.st_msg:
    cmp byte [browse_status_msg], 0
    je .st_scroll
    mov byte [rdi], ' '
    inc rdi
    lea rsi, [browse_status_msg]
    call browse_cp_str
.st_scroll:
    mov byte [rdi], ' '
    inc rdi
    mov byte [rdi], ' '
    inc rdi
    call browse_count_lines
    mov r13d, eax
    mov eax, [browse_scroll]
    inc eax
    call int_to_str
    mov rbx, rdi
.st_sc2:
    cmp byte [rbx], 0
    je .st_sc2d
    inc rbx
    jmp .st_sc2
.st_sc2d:
    mov rdi, rbx
    mov byte [rdi], '/'
    inc rdi
    mov eax, r13d
    call int_to_str
    mov rbx, rdi
.st_sc3:
    cmp byte [rbx], 0
    je .st_sc3d
    inc rbx
    jmp .st_sc3
.st_sc3d:
    mov rdi, rbx

    mov bl, ATTR_BRW_STATUS
    mov al, 24
    lea rsi, [browse_status_buf]
    call browse_write_row

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
;  browse_render -- full-screen redraw of the current page.
browse_render:
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

    call mouse_hide
    call clear_screen

    ; header row
    lea rdi, [browse_status_buf]
    lea rsi, [msg_browse_header]
    call browse_cp_str
    lea rsi, [browse_base_url]
    call browse_cp_str
    mov bl, ATTR_BRW_HEADER
    mov al, 0
    lea rsi, [browse_status_buf]
    call browse_write_row

    call browse_clamp_scroll

    ; body
    lea rsi, [tcp_rx_buf]
    mov r10d, [browse_scroll]
    test r10d, r10d
    jz .skip_done
.skip_lines:
    mov al, [rsi]
    cmp al, 0
    je .skip_done
    cmp al, 10
    jne .skip_next
    dec r10d
    jz .skip_done
.skip_next:
    inc rsi
    jmp .skip_lines
.skip_done:
    cmp byte [rsi], 0
    je .empty_page

    mov r13, VGA_BASE + (1*80)*2
    mov r15d, BROWSE_VROWS
    xor r8, r8                    ; link-marker flag
.body_row:
    test r15d, r15d
    jz .status
    xor ecx, ecx
.body_char:
    cmp ecx, 80
    jae .body_row_adv
    mov al, [rsi]
    cmp al, 0
    je .status
    cmp al, 10
    je .body_row_nl
    mov bl, [cur_normal_attr]
    test r8, r8
    jz .not_in_marker
    cmp al, ']'
    je .in_marker_close
    cmp al, '0'
    jb .marker_end
    cmp al, '9'
    ja .marker_end
    mov bl, ATTR_BRW_LINK
    jmp .draw_char
.in_marker_close:
    mov bl, ATTR_BRW_LINK
    xor r8, r8
    jmp .draw_char
.marker_end:
    xor r8, r8
    jmp .draw_char
.not_in_marker:
    cmp al, '['
    jne .draw_char
    mov ah, [rsi+1]
    cmp ah, '0'
    jb .draw_char
    cmp ah, '9'
    ja .draw_char
    mov r8, 1
    mov bl, ATTR_BRW_LINK
.draw_char:
    movzx r11, al              ; preserve the char (al is clobbered below)
    mov rdi, r13
    mov eax, ecx
    shl rax, 1
    add rdi, rax
    mov [rdi], r11b
    mov [rdi+1], bl
    inc ecx
    inc rsi
    jmp .body_char
.body_row_nl:
    inc rsi
.body_row_adv:
    add r13, 80*2
    dec r15d
    xor r8, r8
    jmp .body_row
.empty_page:
    mov bl, [cur_normal_attr]
    mov al, 2
    lea rsi, [browse_empty_page]
    call browse_write_row
.status:
    call browse_draw_status
    mov byte [cursor_row], 24
    mov byte [cursor_col], 0
    call update_cursor
    call mouse_show

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

; browse_path_leaf: rsi = path string -> rax = ptr to leaf (after last '/'),
; or 0 if the leaf is empty.
browse_path_leaf:
    mov rax, rsi
    xor rdx, rdx
.pl_scan:
    mov cl, [rsi]
    test cl, cl
    jz .pl_done
    cmp cl, '/'
    jne .pl_next
    mov rdx, rsi
.pl_next:
    inc rsi
    jmp .pl_scan
.pl_done:
    test rdx, rdx
    jz .pl_none
    lea rax, [rdx+1]
    cmp byte [rax], 0
    je .pl_none
    ret
.pl_none:
    xor rax, rax
    ret

; browse_save_page: saves the current raw body (http_rx_buf) to a file in
; the current directory, named from the URL path's last segment.
browse_save_page:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r11
    push r12
    push r13

    lea rsi, [http_path_buf]
    call browse_path_leaf
    test rax, rax
    jnz .bsp_have_name
    lea rax, [browse_default_name]
.bsp_have_name:
    mov rsi, rax
    lea rdi, [leaf1_buf]
    call browse_cp_str

    mov rax, [cur_dir]
    lea rsi, [leaf1_buf]
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .bsp_badpath
    mov r11, rax

    mov rax, r11
    lea rsi, [leaf1_buf]
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .bsp_have_node

    mov rax, r11
    lea rsi, [leaf1_buf]
    mov r10, 2
    call fs_create_node
    cmp rax, -1
    je .bsp_fail
.bsp_have_node:
    mov r12, rax
    lea rsi, [http_rx_buf]
    call fs_write_file

    lea rdi, [browse_status_msg]
    lea rsi, [msg_browse_taken]
    call browse_cp_str
    lea rsi, [leaf1_buf]
.find_end:
    cmp byte [rdi], 0
    je .found_end
    inc rdi
    jmp .find_end
.found_end:
    lea rbx, [browse_status_msg + 39]
.append_loop:
    cmp rdi, rbx
    jae .append_done
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .append_done
    inc rdi
    inc rsi
    jmp .append_loop
.append_done:
    mov byte [rdi], 0
    jmp .bsp_out
.bsp_badpath:
    lea rsi, [msg_browse_take_badpath]
    call browse_set_status
    jmp .bsp_out
.bsp_fail:
    lea rsi, [msg_browse_take_fail]
    call browse_set_status
.bsp_out:
    pop r13
    pop r12
    pop r11
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; browse_add_bmk: bookmark the current page URL.
browse_add_bmk:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13

    mov r13d, [browse_bmk_cnt]
    xor r12, r12
.bmk_chk:
    cmp r12, r13
    jae .bmk_chk_done
    mov eax, r12d
    imul eax, eax, BROWSE_LINK_BUF
    lea rdi, [browse_bmks + rax]
    lea rsi, [browse_base_url]
    push r12
    push r13
    call str_eq
    pop r13
    pop r12
    cmp al, 1
    je .bmk_dup
    inc r12
    jmp .bmk_chk
.bmk_chk_done:
    cmp r13, BROWSE_BMK_MAX
    jae .bmk_full
    mov eax, r13d
    imul eax, eax, BROWSE_LINK_BUF
    lea rdi, [browse_bmks + rax]
    lea rsi, [browse_base_url]
    call browse_cp_str
    inc dword [browse_bmk_cnt]
    lea rsi, [msg_bmk_added]
    call browse_set_status
    jmp .bmk_out
.bmk_dup:
    lea rsi, [msg_bmk_dup]
    call browse_set_status
    jmp .bmk_out
.bmk_full:
    lea rsi, [msg_bmk_full]
    call browse_set_status
.bmk_out:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; browse_list_bmks: draw the bookmark list; pick a number to load, q/Esc to
; cancel. After it returns, the caller re-renders the page.
browse_list_bmks:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13

    cmp dword [browse_bmk_cnt], 0
    je .blk_none

    mov bl, ATTR_BRW_HEADER
    mov al, 1
    lea rsi, [msg_bmk_title]
    call browse_write_row

    xor r12, r12
    mov r13d, [browse_bmk_cnt]
.blk_row:
    cmp r12, r13
    jae .blk_key
    lea rdi, [browse_status_buf]
    mov byte [rdi], '['
    inc rdi
    mov eax, r12d
    inc eax
    call int_to_str
    mov rbx, rdi
.blk_num_scan:
    cmp byte [rbx], 0
    je .blk_num_done
    inc rbx
    jmp .blk_num_scan
.blk_num_done:
    mov rdi, rbx
    mov byte [rdi], ']'
    inc rdi
    mov byte [rdi], ' '
    inc rdi
    mov eax, r12d
    imul eax, eax, BROWSE_LINK_BUF
    lea rsi, [browse_bmks + rax]
    call browse_cp_str
    mov al, r12b
    add al, 2
    mov bl, [cur_normal_attr]
    lea rsi, [browse_status_buf]
    call browse_write_row
    inc r12
    jmp .blk_row
.blk_key:
    call get_char
    cmp al, 0x1B
    je .blk_done
    cmp al, 'q'
    je .blk_done
    cmp al, '0'
    jb .blk_key
    cmp al, '9'
    ja .blk_key
    movzx eax, al
    sub eax, '0'
    test eax, eax
    jz .blk_key
    cmp eax, r13d
    ja .blk_key
    dec eax
    imul eax, eax, BROWSE_LINK_BUF
    lea rsi, [browse_bmks + rax]
    lea rdi, [browse_url_tmp]
    call browse_cp_str
    lea rsi, [browse_url_tmp]
    call browse_navigate
    jmp .blk_done
.blk_none:
    lea rsi, [msg_bmk_none]
    call browse_set_status
.blk_done:
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
;  browse_view -- interactive page view loop.
browse_view:
    mov byte [browse_link_entry], 0
    mov dword [browse_enter_val], 0
    lea rdi, [browse_status_msg]
    mov byte [rdi], 0
    call browse_render
.vloop:
    call get_char
    cmp al, 0x1B
    je .quit
    cmp al, 'q'
    je .quit
    cmp al, '0'
    jb .vkey
    cmp al, '9'
    jbe .vdigit
.vkey:
    cmp al, 13
    je .venter
    cmp al, 8
    je .vbs
    cmp al, KEY_UP
    je .vup
    cmp al, KEY_DOWN
    je .vdown
    cmp al, 'k'
    je .vup
    cmp al, 'j'
    je .vdown
    cmp al, 'p'
    je .vpgup
    cmp al, ' '
    je .vpgdn
    cmp al, 'b'
    je .vback
    cmp al, 'f'
    je .vfwd
    cmp al, 'a'
    je .vaddbmk
    cmp al, 'l'
    je .vlistbmk
    cmp al, 't'
    je .vtake
    jmp .vloop
.vdigit:
    ; any digit cancels the pending entry first
    mov byte [browse_link_entry], 1
    movzx eax, al
    sub eax, '0'
    mov ecx, [browse_enter_val]
    imul ecx, ecx, 10
    add ecx, eax
    cmp ecx, 999
    jbe .vdigit_ok
    mov ecx, 999
.vdigit_ok:
    mov [browse_enter_val], ecx
    jmp .vloop
.vbs:
    mov dword [browse_enter_val], 0
    mov byte [browse_link_entry], 0
    jmp .vloop
.venter:
    cmp byte [browse_link_entry], 0
    je .vloop
    mov eax, [browse_enter_val]
    test eax, eax
    jz .vbs
    cmp eax, [browse_link_cnt]
    ja .vbs
    dec eax
    imul eax, eax, BROWSE_LINK_BUF
    lea rsi, [browse_link_urls + rax]
    lea rdi, [browse_url_tmp]
    call browse_resolve_url
    jc .vbs
    mov byte [browse_link_entry], 0
    mov dword [browse_enter_val], 0
    lea rsi, [browse_url_tmp]
    call browse_navigate
    call browse_render
    jmp .vloop
.vup:
    mov dword [browse_link_entry], 0
    mov eax, [browse_scroll]
    test eax, eax
    jz .vloop
    dec eax
    mov [browse_scroll], eax
    call browse_render
    jmp .vloop
.vdown:
    mov dword [browse_link_entry], 0
    mov eax, [browse_scroll]
    inc eax
    mov [browse_scroll], eax
    call browse_clamp_scroll
    call browse_render
    jmp .vloop
.vpgup:
    mov dword [browse_link_entry], 0
    mov eax, [browse_scroll]
    cmp eax, 22
    jbe .vpgup_zero
    sub eax, 22
    mov [browse_scroll], eax
    call browse_render
    jmp .vloop
.vpgup_zero:
    mov dword [browse_scroll], 0
    call browse_render
    jmp .vloop
.vpgdn:
    mov dword [browse_link_entry], 0
    mov eax, [browse_scroll]
    add eax, 22
    mov [browse_scroll], eax
    call browse_clamp_scroll
    call browse_render
    jmp .vloop
.vback:
    mov dword [browse_link_entry], 0
    mov eax, [browse_hist_pos]
    test eax, eax
    jz .vloop
    dec eax
    mov [browse_hist_pos], eax
    imul eax, eax, BROWSE_LINK_BUF
    lea rsi, [browse_hist + rax]
    call browse_fetch_url
    call browse_render
    jmp .vloop
.vfwd:
    mov dword [browse_link_entry], 0
    mov eax, [browse_hist_pos]
    inc eax
    cmp eax, [browse_hist_cnt]
    jae .vloop
    mov [browse_hist_pos], eax
    imul eax, eax, BROWSE_LINK_BUF
    lea rsi, [browse_hist + rax]
    call browse_fetch_url
    call browse_render
    jmp .vloop
.vaddbmk:
    mov dword [browse_link_entry], 0
    call browse_add_bmk
    call browse_render
    jmp .vloop
.vlistbmk:
    mov dword [browse_link_entry], 0
    call browse_list_bmks
    call browse_render
    jmp .vloop
.vtake:
    mov dword [browse_link_entry], 0
    call browse_save_page
    call browse_render
    jmp .vloop
.quit:
    call clear_screen
    ret

; ============================================================
;  cmd_browse -- "browse <url>"
cmd_browse:
    cmp byte [nic_present], 0
    je .no_nic
    cmp byte [arg1_buf], 0
    je .usage
    ; build an absolute URL from arg1
    lea rsi, [arg1_buf]
    mov eax, [rsi]
    or eax, 0x20202020
    cmp eax, 'http'
    jne .prepend
    cmp byte [rsi+4], ':'
    jne .prepend
    cmp byte [rsi+5], '/'
    jne .prepend
    cmp byte [rsi+6], '/'
    jne .prepend
    lea rdi, [browse_url_tmp]
    call browse_cp_str
    jmp .have_url
.prepend:
    lea rdi, [browse_url_tmp]
    mov dword [rdi], 'http'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], '/'
    mov byte [rdi+6], '/'
    add rdi, 7
    lea rsi, [arg1_buf]
    call browse_cp_str
.have_url:
    lea rsi, [browse_url_tmp]
    call browse_navigate
    mov byte [browse_active], 1
    call browse_view
    mov byte [browse_active], 0
    ret
.no_nic:
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.usage:
    mov rsi, msg_browse_usage
    mov al, [cur_normal_attr]
    call print_string_attr
    ret

; ============================================================
;  Browse data (buffers + strings). Allocated here so kernel.asm's data
;  section stays untouched.
; ============================================================
browse_link_cnt:  dd 0
browse_tag_len:   dd 0
browse_scroll:    dd 0
browse_hist_cnt:  dd 0
browse_hist_pos:  dd 0
browse_bmk_cnt:   dd 0
browse_enter_val: dd 0
browse_link_entry: db 0
browse_active:     db 0      ; set while browse_view is the active input loop

browse_base_url:   times 256 db 0
browse_url_tmp:    times 256 db 0
browse_url_tmp2:   times 256 db 0
browse_path_tmp:   times 256 db 0
browse_seg_off:    times 64 dd 0
browse_tag_buf:    times 24 db 0
browse_tag_buf2:   times 24 db 0
browse_num_tmp:    times 8 db 0
browse_status_buf: times 128 db 0
browse_status_msg: times 48 db 0
browse_link_urls:  times BROWSE_LINKS_MAX*BROWSE_LINK_BUF db 0
browse_hist:       times BROWSE_HIST_MAX*BROWSE_LINK_BUF db 0
browse_bmks:       times BROWSE_BMK_MAX*BROWSE_LINK_BUF db 0

ent_amp:  db "amp", 0
ent_lt:   db "lt", 0
ent_gt:   db "gt", 0
ent_quot: db "quot", 0
ent_apos: db "apos", 0
ent_nbsp: db "nbsp", 0

str_script: db "script", 0
str_style:  db "style", 0
str_a:      db "a", 0

bstr_p:         db "p", 0
bstr_div:       db "div", 0
bstr_br:        db "br", 0
bstr_li:        db "li", 0
bstr_tr:        db "tr", 0
bstr_td:        db "td", 0
bstr_th:        db "th", 0
bstr_ul:        db "ul", 0
bstr_ol:        db "ol", 0
bstr_dl:        db "dl", 0
bstr_dt:        db "dt", 0
bstr_dd:        db "dd", 0
bstr_table:     db "table", 0
bstr_blockquote: db "blockquote", 0
bstr_pre:       db "pre", 0
bstr_hr:        db "hr", 0
bstr_center:    db "center", 0
bstr_form:      db "form", 0
bstr_section:   db "section", 0
bstr_article:   db "article", 0
bstr_header:    db "header", 0
bstr_footer:    db "footer", 0
bstr_nav:       db "nav", 0
bstr_main:      db "main", 0
bstr_aside:     db "aside", 0
bstr_h:         db "h", 0

msg_browse_usage:       db "browse: usage: browse <url>", 10, 0
msg_browse_header:      db "  ShellyForever Browser    URL: ", 0
msg_browse_hints:       db "[b]ack [f]wd [a]dd-bm [l]ist-bm [t]save [q]uit", 0
msg_browse_taken:       db "saved raw page to ", 0
msg_browse_take_fail:   db "browse: failed to save file.", 0
msg_browse_take_badpath: db "browse: bad file path.", 0
browse_err_msg_badurl:  db "browse: bad URL format. Use http://host[:port]/path", 0
browse_err_msg_fetch:   db "browse: failed to load page.", 0
browse_err_msg_nobody:  db "browse: server returned no content.", 0
browse_empty_page:      db "( empty page )", 0
browse_default_name:    db "page.html", 0

msg_bmk_title:  db "  Bookmarks - type a number then Enter, q/Esc to cancel", 0
msg_bmk_added:  db "bookmarked", 0
msg_bmk_dup:    db "already bookmarked", 0
msg_bmk_full:   db "bookmarks full", 0
msg_bmk_none:   db "no bookmarks", 0
