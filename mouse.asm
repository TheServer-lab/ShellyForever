; ============================================================
;  PS/2 MOUSE  (polled - no IRQs, matching the keyboard)
; ============================================================
; The kernel is fully polled: the keyboard reads ports 0x64/0x60
; directly. The PS/2 mouse shares those same two ports, so this
; driver is polled too. The 8042 status register (port 0x64) bit
; 5 (0x20) tells us when the byte waiting in port 0x60 came from
; the auxiliary (mouse) device, which is exactly how get_char and
; kbd_poll keep mouse bytes out of the keyboard scancode parser.
;
;   mouse            toggles the mouse cursor on/off
;
; The cursor is a text-mode overlay: the cell under the pointer is
; saved, the cell is redrawn reverse-video, and every routine that
; mutates the screen re-applies the cursor afterwards (putchar,
; scroll_screen, clear_screen, scrollback_render, browse_render),
; so the pointer stays on top of scrolling text and full-screen
; redraws without ever baking a stale copy of the cursor into the
; screen buffer.

MOUSE_SCALE     equ 8           ; raw mickey counts per text cell (tune feel)
MOUSE_CLAMP_X   equ VGA_COLS-1
MOUSE_CLAMP_Y   equ VGA_ROWS-1
MOUSE_BLOCK     equ 0x0FDB      ; char 0xDB, attr 0x0F: solid bright-white block
MOUSE_WHEEL_STEP equ 1          ; Z clicks accumulated before one scroll step

; ------------------------------------------------------------
;  PS/2 helpers
; ------------------------------------------------------------
; ps2_wait_ibf: block until the controller's input buffer is empty
; (bit 1 of status clear), i.e. it is safe to write 0x64/0x60.
ps2_wait_ibf:
    push rax
    in al, 0x64
    test al, 2
    jnz ps2_wait_ibf
    pop rax
    ret

; ps2_wait_obf: block until the controller's output buffer is full
; (bit 0 of status set), i.e. a byte is waiting in port 0x60.
ps2_wait_obf:
    push rax
    in al, 0x64
    test al, 1
    jz ps2_wait_obf
    pop rax
    ret

; mouse_send_cmd: al = command byte for the mouse. Writes it via the
; 0xD4 "write to auxiliary device" prefix and waits for the 0xFA ACK.
; Returns CF=0 on ACK, CF=1 on timeout/no ACK (no mouse attached).
mouse_send_cmd:
    push rcx
    push rdx
    push rax
    mov cl, al                   ; command byte
    call ps2_wait_ibf
    mov al, 0xD4                 ; write-to-aux prefix
    out 0x64, al
    call ps2_wait_ibf
    mov al, cl
    out 0x60, al
    mov rcx, 0xFFFFFF             ; ACK timeout (generous: some mice are slow)
.ack:
    in al, 0x64
    test al, 1
    jnz .have_byte
    loop .ack
    stc                          ; timed out - assume no mouse
    jmp .out
.have_byte:
    in al, 0x60
    cmp al, 0xFA                 ; ACK
    jne .bad
    clc
    jmp .out
.bad:
    cmp al, 0xFE                 ; RESEND - retry once
    jne .timeout
    loop .ack
.timeout:
    stc
.out:
    pop rax
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------
;  mouse_init: put the PS/2 mouse into default stream mode with
;  data reporting enabled. Returns CF=0 on success, CF=1 on failure.
mouse_init:
    push rax
    call ps2_wait_ibf
    mov al, 0xA8                 ; enable auxiliary device
    out 0x64, al
    call ps2_wait_ibf
    mov al, 0x20                 ; read controller config byte
    out 0x64, al
    call ps2_wait_obf
    in al, 0x60
    or al, 0x02                  ; bit1: enable aux IRQ (harmless if unused)
    and al, 0xDF                 ; bit5 clear: aux clock enabled
    push rax
    call ps2_wait_ibf
    mov al, 0x60                 ; write config byte
    out 0x64, al
    call ps2_wait_ibf
    pop rax
    out 0x60, al
    mov al, 0xF6                 ; set defaults (stream mode, reporting off)
    call mouse_send_cmd
    jc .fail
    ; IntelliMouse negotiation: sending sample rate 200 three times in a
    ; row switches a wheel mouse into 4-byte packets (flags/X/Y/Z). The
    ; device ID read confirms it - 0x03/0x04 = wheel present. If that
    ; doesn't take, retry with the IntelliMouse Explorer sequence
    ; (200/100/80). A mouse that answers neither stays in 3-byte mode.
    mov cl, 200
    call mouse_set_rate
    jc .wheel_off
    call mouse_set_rate
    jc .wheel_off
    call mouse_set_rate
    jc .wheel_off
    call mouse_read_id
    jc .wheel_off
    cmp al, 0x03
    je .wheel_on
    cmp al, 0x04
    je .wheel_on
    mov cl, 200
    call mouse_set_rate
    jc .wheel_off
    mov cl, 100
    call mouse_set_rate
    jc .wheel_off
    mov cl, 80
    call mouse_set_rate
    jc .wheel_off
    call mouse_read_id
    jc .wheel_off
    cmp al, 0x03
    je .wheel_on
    cmp al, 0x04
    jne .wheel_off
.wheel_on:
    mov byte [mouse_wheel], 1
    jmp .have_wheel
.wheel_off:
    mov byte [mouse_wheel], 0
.have_wheel:
    mov al, 0xF4                 ; enable data reporting
    call mouse_send_cmd
    jc .fail
    mov byte [mouse_pkt_idx], 0
    mov byte [mouse_acc_x], 0
    mov byte [mouse_acc_y], 0
    mov byte [mouse_wheel_acc], 0
    clc
    jmp .out
.fail:
    stc
.out:
    pop rax
    ret

; mouse_set_rate: cl = sample rate. Sends 0xF3, waits for its ACK, then
; sends the rate byte, waits for its ACK. CF=0 on both ACKs.
mouse_set_rate:
    push rax
    push rcx
    push rdx
    mov dl, cl                   ; rate byte
    mov al, 0xF3
    call mouse_send_cmd
    jc .fail
    call ps2_wait_ibf
    mov al, 0xD4
    out 0x64, al
    call ps2_wait_ibf
    mov al, dl
    out 0x60, al
    mov rcx, 0xFFFFFF
.ack:
    in al, 0x64
    test al, 1
    jnz .have_byte
    loop .ack
    stc
    jmp .out
.have_byte:
    in al, 0x60
    cmp al, 0xFA
    jne .fail
    clc
    jmp .out
.fail:
    stc
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; mouse_read_id: 0xF2 -> ACK (consumed by mouse_send_cmd) then the device
; ID byte is read from port 0x60. Returns the ID in al, CF=0.
mouse_read_id:
    push rcx
    mov al, 0xF2
    call mouse_send_cmd
    jc .fail
    call ps2_wait_obf
    in al, 0x60
    clc
    pop rcx
    ret
.fail:
    stc
    pop rcx
    ret

; mouse_disable_reporting: best-effort stop of the data stream
; (used when the cursor is toggled off so the mouse stops flooding
; port 0x60 while idle).
mouse_disable_reporting:
    push rax
    cmp byte [mouse_ena], 0
    je .out
    mov al, 0xF5                 ; disable data reporting
    call mouse_send_cmd
.out:
    pop rax
    ret

; ------------------------------------------------------------
;  Cursor overlay
; ------------------------------------------------------------
; mouse_hide: write the saved cell back over the cursor (used before
; scrolling/full redraws so the pointer block doesn't get copied or
; baked into a snapshot). No-op when not currently shown.
mouse_hide:
    push rax
    push rbx
    push rdi
    cmp byte [mouse_ena], 0
    je .out
    cmp byte [mouse_saved_valid], 0
    je .out
    call mouse_cell_addr         ; rdi = offset of cursor cell
    mov ax, [mouse_saved]
    mov [rdi], ax
    mov byte [mouse_saved_valid], 0
.out:
    pop rdi
    pop rbx
    pop rax
    ret

; mouse_show: snapshot the cell under the pointer and redraw it as a
; bright-white block. Re-applies on top of whatever just changed on
; screen, but only re-snapshots when the cell isn't already the cursor
; block - so the saved "underlying" cell is never the block itself.
mouse_show:
    push rax
    push rbx
    push rdi
    cmp byte [mouse_ena], 0
    je .out
    call mouse_cell_addr         ; rdi = offset of cursor cell
    mov ax, [rdi]
    cmp ax, MOUSE_BLOCK          ; cursor already drawn here (screen unchanged)?
    je .out                      ; keep the saved cell as-is - no re-snapshot
    mov [mouse_saved], ax
    mov word [rdi], MOUSE_BLOCK  ; solid bright-white block, hides text under it
    mov byte [mouse_saved_valid], 1
.out:
    pop rdi
    pop rbx
    pop rax
    ret

; mouse_cell_addr: rdi = VGA offset of the cell at mouse_x/mouse_y.
; clobbers rcx/rdx.
mouse_cell_addr:
    movzx rcx, byte [mouse_y]
    imul rcx, VGA_COLS
    movzx rdx, byte [mouse_x]
    add rcx, rdx
    imul rcx, 2
    lea rdi, [VGA_BASE + rcx]
    ret

; ------------------------------------------------------------
;  Packet parsing
; ------------------------------------------------------------
; mouse_byte: al = one raw byte read from port 0x60 that came from
; the aux device. Assembles 3-byte stream packets (flags/X/Y), or 4-byte
; IntelliMouse packets (flags/X/Y/Z wheel) when mouse_wheel is set.
mouse_byte:
    push rax
    push rbx
    movzx ebx, byte [mouse_pkt_idx]
    test ebx, ebx
    jnz .not_first
    test al, 0x08                ; bit 3 of a valid flags byte is always 1
    jz .out                      ; out-of-sync byte - drop it, stay resynced
    and al, 0x07
    mov [mouse_btn], al          ; low 3 bits: left/right/middle
    inc byte [mouse_pkt_idx]
    jmp .out
.not_first:
    cmp ebx, 1
    jne .not_second
    mov [mouse_pkt+1], al        ; X delta
    inc byte [mouse_pkt_idx]
    jmp .out
.not_second:
    cmp ebx, 2
    jne .fourth
    mov [mouse_pkt+2], al        ; Y delta
    inc byte [mouse_pkt_idx]
    cmp byte [mouse_wheel], 0
    jne .out                     ; 4-byte mode: the wheel byte is still to come
    mov byte [mouse_pkt_idx], 0
    call mouse_process
    jmp .out
.fourth:
    mov [mouse_pkt+3], al        ; Z (wheel) delta
    mov byte [mouse_pkt_idx], 0
    call mouse_process
    jmp .out
.out:
    pop rbx
    pop rax
    ret

; mouse_process: apply the accumulated packet (pkt[1]=X, pkt[2]=Y;
; PS/2 Y is positive-up, so it is negated for screen rows) using a
; small accumulator so slow movements are still fine-grained.
mouse_process:
    push rax
    push rbx
    push rcx

    call mouse_hide              ; restore the OLD cell first (position not yet changed)

    movsx eax, byte [mouse_pkt+1]
    add [mouse_acc_x], al
.x_loop:
    cmp byte [mouse_acc_x], MOUSE_SCALE
    jge .x_plus
    cmp byte [mouse_acc_x], -MOUSE_SCALE
    jle .x_minus
    jmp .x_done
.x_plus:
    cmp byte [mouse_x], MOUSE_CLAMP_X
    jae .x_done
    sub byte [mouse_acc_x], MOUSE_SCALE
    inc byte [mouse_x]
    jmp .x_loop
.x_minus:
    cmp byte [mouse_x], 0
    je .x_done
    add byte [mouse_acc_x], MOUSE_SCALE
    dec byte [mouse_x]
    jmp .x_loop
.x_done:

    movsx eax, byte [mouse_pkt+2]
    neg eax
    add [mouse_acc_y], al
.y_loop:
    cmp byte [mouse_acc_y], MOUSE_SCALE
    jge .y_plus
    cmp byte [mouse_acc_y], -MOUSE_SCALE
    jle .y_minus
    jmp .y_done
.y_plus:
    cmp byte [mouse_y], MOUSE_CLAMP_Y
    jae .y_done
    sub byte [mouse_acc_y], MOUSE_SCALE
    inc byte [mouse_y]
    jmp .y_loop
.y_minus:
    cmp byte [mouse_y], 0
    je .y_done
    add byte [mouse_acc_y], MOUSE_SCALE
    dec byte [mouse_y]
    jmp .y_loop
.y_done:

    ; ---- wheel (Z) scroll ----
    cmp byte [mouse_wheel], 0
    je .w_done
    movsx eax, byte [mouse_pkt+3]
    test eax, eax
    jz .w_done
    ; Windows-style mice send +/-120 per notch; PS/2 ones usually send
    ; +/-1..+/-15. A large Z is one notch, a small Z accumulates by unit.
    cmp eax, 120
    jge .w_one_up
    cmp eax, -120
    jle .w_one_down
    add [mouse_wheel_acc], al
.w_loop:
    cmp byte [mouse_wheel_acc], MOUSE_WHEEL_STEP
    jge .w_up
    cmp byte [mouse_wheel_acc], -MOUSE_WHEEL_STEP
    jle .w_down
    jmp .w_done
.w_up:
    sub byte [mouse_wheel_acc], MOUSE_WHEEL_STEP
    call wheel_scroll_up
    jmp .w_loop
.w_down:
    add byte [mouse_wheel_acc], MOUSE_WHEEL_STEP
    call wheel_scroll_down
    jmp .w_loop
.w_one_up:
    call wheel_scroll_up
    jmp .w_done
.w_one_down:
    call wheel_scroll_down
    jmp .w_done
.w_done:

    ; ---- mouse buttons: left-drag text selection ----
    mov al, [mouse_btn]
    mov bl, [mouse_btn_prev]
    mov [mouse_btn_prev], al
    test al, 1
    jz .l_not_down
    test bl, 1
    jnz .l_still_down
    ; rising edge: begin a selection at the pointer
    mov byte [sel_active], 1
    mov al, [mouse_x]
    mov [sel_ax], al
    mov [sel_cx], al
    mov al, [mouse_y]
    mov [sel_ay], al
    mov [sel_cy], al
    jmp .l_done
.l_still_down:
    ; still held: track the drag endpoint
    mov al, [mouse_x]
    mov [sel_cx], al
    mov al, [mouse_y]
    mov [sel_cy], al
    jmp .l_done
.l_not_down:
    test bl, 1
    jz .l_done
    ; falling edge: finalize the selection (Ctrl+C can now copy it)
    mov al, [mouse_x]
    mov [sel_cx], al
    mov al, [mouse_y]
    mov [sel_cy], al
    mov byte [sel_active], 0
    mov byte [sel_valid], 1
    call mouse_sel_redraw        ; extend the highlight to the final position
.l_done:

    cmp byte [sel_active], 0
    je .no_sel
    call mouse_sel_redraw        ; only refresh while actually dragging
.no_sel:

    call mouse_show
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
;  Text selection + clipboard
; ------------------------------------------------------------
; A selection is a rectangle of text cells between the left-button
; anchor (sel_ax/sel_ay) and the current drag endpoint (sel_cx/sel_cy).
; While a drag is live the covered cells are highlighted reverse-video,
; and a snapshot of those cells (char+attr) is kept so the highlight can
; be removed exactly when the drag moves or the screen is rewritten.
; sel_valid marks a finalized selection that Ctrl+C copies into clip_buf
; (one line per screen row, trailing spaces trimmed, newline separated).
; Ctrl+V pastes clip_buf back into the command line via KEY_PASTE.

; mouse_sel_clear: remove the highlight and drop all selection state.
; Called from clear_screen, scroll_screen, scrollback_render (full screen
; rewrites), putchar when a char lands inside the selection (its attr
; would otherwise come back from a stale snapshot), and 'mouse' off.
mouse_sel_clear:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    cmp byte [sel_snap_valid], 0
    je .clear_flags
    call mouse_sel_restore_snap
.clear_flags:
    mov byte [sel_active], 0
    mov byte [sel_valid], 0
    mov byte [sel_snap_valid], 0
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; mouse_sel_normalize: compute the rect sel_x1/y1/x2/y2 (top-left ..
; bottom-right, inclusive) from anchor and drag endpoint. Clobbers rax.
mouse_sel_normalize:
    push rbx
    mov al, [sel_ay]
    mov bl, [sel_cy]
    cmp al, bl
    jbe .y_ok
    xchg al, bl
.y_ok:
    mov [sel_y1], al
    mov [sel_y2], bl
    mov al, [sel_ax]
    mov bl, [sel_cx]
    cmp al, bl
    jbe .x_ok
    xchg al, bl
.x_ok:
    mov [sel_x1], al
    mov [sel_x2], bl
    pop rbx
    ret

; mouse_sel_snapshot: copy the rect's cells (char+attr) from VGA into
; sel_snap and set sel_snap_valid. Rect fields must be normalized.
; Clobbers rax/rbx/rcx/rdx/rsi/rdi.
mouse_sel_snapshot:
    lea rsi, [sel_snap]
    movzx ecx, byte [sel_y1]
.row_loop:
    cmp cl, byte [sel_y2]
    ja .done
    movzx edx, byte [sel_x1]
.col_loop:
    cmp dl, byte [sel_x2]
    ja .row_next
    movzx eax, cl
    imul eax, VGA_COLS
    movzx ebx, dl
    add eax, ebx
    shl eax, 1
    lea rdi, [VGA_BASE + rax]
    mov ax, [rdi]
    mov [rsi], ax
    add rsi, 2
    inc dl
    jmp .col_loop
.row_next:
    inc cl
    jmp .row_loop
.done:
    mov byte [sel_snap_valid], 1
    ret

; mouse_sel_highlight: swap the attr nibbles of every cell in the rect
; (chars preserved) - the reverse-video look. Rect must be normalized.
mouse_sel_highlight:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    movzx ecx, byte [sel_y1]
.row_loop:
    cmp cl, byte [sel_y2]
    ja .done
    movzx edx, byte [sel_x1]
.col_loop:
    cmp dl, byte [sel_x2]
    ja .row_next
    movzx eax, cl
    imul eax, VGA_COLS
    movzx ebx, dl
    add eax, ebx
    shl eax, 1
    lea rdi, [VGA_BASE + rax]
    mov al, [rdi+1]
    mov bl, al
    shr al, 4
    shl bl, 4
    or al, bl
    mov [rdi+1], al
    inc dl
    jmp .col_loop
.row_next:
    inc cl
    jmp .row_loop
.done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; mouse_sel_restore_snap: write sel_snap back over the rect the fields
; describe, removing the highlight. Clears sel_snap_valid.
mouse_sel_restore_snap:
    lea rsi, [sel_snap]
    movzx ecx, byte [sel_y1]
.row_loop:
    cmp cl, byte [sel_y2]
    ja .done
    movzx edx, byte [sel_x1]
.col_loop:
    cmp dl, byte [sel_x2]
    ja .row_next
    movzx eax, cl
    imul eax, VGA_COLS
    movzx ebx, dl
    add eax, ebx
    shl eax, 1
    lea rdi, [VGA_BASE + rax]
    mov ax, [rsi]
    mov [rdi], ax
    add rsi, 2
    inc dl
    jmp .col_loop
.row_next:
    inc cl
    jmp .row_loop
.done:
    mov byte [sel_snap_valid], 0
    ret

; mouse_sel_redraw: restore the previous highlight, then snapshot and
; re-highlight the current rect. Called once per drag update.
mouse_sel_redraw:
    push rax
    cmp byte [sel_snap_valid], 0
    je .fresh
    call mouse_sel_restore_snap
.fresh:
    call mouse_sel_normalize
    call mouse_sel_snapshot
    call mouse_sel_highlight
    pop rax
    ret

; mouse_sel_putchar_check: if a live highlight exists and the cell at
; cursor_row/cursor_col lies inside it, clear the whole selection (the
; cell's attr was just overwritten by putchar, so the snapshot would be
; stale). Preserves all registers. Called from putchar.
mouse_sel_putchar_check:
    push rax
    cmp byte [sel_snap_valid], 0
    je .out
    mov al, [cursor_row]
    cmp al, [sel_y1]
    jb .out
    cmp al, [sel_y2]
    ja .out
    mov al, [cursor_col]
    cmp al, [sel_x1]
    jb .out
    cmp al, [sel_x2]
    ja .out
    pop rax
    call mouse_sel_clear
    ret
.out:
    pop rax
    ret

; wheel_scroll_up/wheel_scroll_down: one wheel click. In browse view the
; page scrolls (like j/k); otherwise the terminal scrollback view scrolls
; (like Ctrl+Up/Ctrl+Down).
wheel_scroll_up:
    push rax
    cmp byte [browse_active], 0
    je .shell
    mov eax, [browse_scroll]
    test eax, eax
    jz .out
    dec eax
    mov [browse_scroll], eax
    call browse_render
    jmp .out
.shell:
    call scrollback_view_up
.out:
    pop rax
    ret

wheel_scroll_down:
    push rax
    cmp byte [browse_active], 0
    je .shell
    mov eax, [browse_scroll]
    inc eax
    mov [browse_scroll], eax
    call browse_clamp_scroll
    call browse_render
    jmp .out
.shell:
    call scrollback_view_down
.out:
    pop rax
    ret

; clip_copy: copy the finalized selection's visible text into clip_buf
; (trailing spaces trimmed per row, rows newline-terminated, NUL at the
; end, byte length in clip_len). No-op without a finalized selection.
clip_copy:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    cmp byte [sel_valid], 0
    je .out
    call mouse_sel_normalize
    lea rsi, [clip_buf]
    movzx ecx, byte [sel_y1]
.row_loop:
    cmp cl, byte [sel_y2]
    ja .done
    ; find the row's last non-space char, scanning right to left
    movzx edx, byte [sel_x2]
.scan:
    cmp dl, byte [sel_x1]
    jb .row_empty
    movzx eax, cl
    imul eax, VGA_COLS
    movzx ebx, dl
    add eax, ebx
    shl eax, 1
    lea rdi, [VGA_BASE + rax]
    cmp byte [rdi], ' '
    jne .have_text
    dec dl
    jmp .scan
.row_empty:
    jmp .row_next
.have_text:
    ; copy chars sel_x1..dl (inclusive) into clip_buf
    movzx ebx, byte [sel_x1]
.col_loop:
    cmp bl, dl
    ja .row_end
    movzx eax, cl
    imul eax, VGA_COLS
    movzx ebx, bl
    add eax, ebx
    shl eax, 1
    lea rdi, [VGA_BASE + rax]
    mov al, [rdi]
    mov [rsi], al
    inc rsi
    inc bl
    jmp .col_loop
.row_end:
    mov byte [rsi], 10
    inc rsi
.row_next:
    inc cl
    jmp .row_loop
.done:
    mov byte [rsi], 0
    mov rax, rsi
    lea rbx, [clip_buf]
    sub rax, rbx
    mov [clip_len], eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
;  Command
; ------------------------------------------------------------
; cmd_mouse: toggle the cursor. "mouse" shows it (and initialises the
; PS/2 mouse if needed), "mouse" again hides it.
cmd_mouse:
    cmp byte [mouse_ena], 0
    jne .disable
    call mouse_init
    jc .fail
    mov byte [mouse_ena], 1
    mov byte [mouse_x], 40       ; start centred
    mov byte [mouse_y], 12
    call mouse_show
    cmp byte [mouse_wheel], 0
    je .no_wheel
    mov rsi, msg_mouse_wheel
    jmp .print
.no_wheel:
    mov rsi, msg_mouse_no_wheel
.print:
    mov al, ATTR_PROMPT
    call print_string_attr
    ret
.disable:
    call mouse_hide
    call mouse_sel_clear
    mov byte [mouse_ena], 0
    call mouse_disable_reporting
    mov rsi, msg_mouse_off
    mov al, ATTR_PROMPT
    call print_string_attr
    ret
.fail:
    mov rsi, msg_mouse_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
;  Data
; ------------------------------------------------------------
mouse_ena:         db 0
mouse_x:           db 40
mouse_y:           db 12
mouse_saved:       dw 0
mouse_saved_valid: db 0
mouse_btn:         db 0
mouse_btn_prev:    db 0
mouse_pkt:         times 4 db 0     ; flags, X, Y, Z (wheel)
mouse_pkt_idx:     db 0
mouse_acc_x:       db 0
mouse_acc_y:       db 0
mouse_wheel:       db 0             ; 1 = IntelliMouse 4-byte packets negotiated
mouse_wheel_acc:   db 0

; --- text selection + clipboard ---
sel_active:        db 0        ; left button currently held (dragging)
sel_valid:         db 0        ; a finalized selection exists (Ctrl+C copyable)
sel_ax:            db 0        ; selection anchor col/row
sel_ay:            db 0
sel_cx:            db 0        ; drag endpoint col/row
sel_cy:            db 0
sel_x1:            db 0        ; normalized rect: top-left / bottom-right
sel_y1:            db 0
sel_x2:            db 0
sel_y2:            db 0
sel_snap_valid:    db 0
sel_snap:          times VGA_COLS*VGA_ROWS*2 db 0   ; char+attr of highlighted rect
clip_buf:          times 2048 db 0                   ; copied text (NUL terminated)
clip_len:          dd 0

msg_mouse_wheel: db "mouse: cursor enabled (wheel scrolling detected) - move the pointer, type 'mouse' again to hide", 10, 0
msg_mouse_no_wheel: db "mouse: cursor enabled (no wheel detected) - move the pointer, type 'mouse' again to hide", 10, 0
msg_mouse_off: db "mouse: cursor disabled", 10, 0
msg_mouse_fail: db "mouse: no PS/2 mouse detected", 10, 0
