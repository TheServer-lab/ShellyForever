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
TOK_COUNT_KNOWN equ 31       ; number of entries in party_tok_names
TOK_ERROR   equ 255

; ------------------------------------------------------------
; cmd_party: shell entry point. "party <file.pa>"
; ------------------------------------------------------------
cmd_party:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_party_usage
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
    mov r11, rax
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .not_found

    lea rdi, [fs_io_buf]
    call fs_read_file

    lea rsi, [fs_io_buf]
    call party_lex

    cmp byte [party_lex_ok], 1
    jne .lex_failed

    ; "party foo.pa -tokens" dumps the raw token stream instead of
    ; running it - kept around from the lexer-only milestone, handy
    ; for debugging the lexer/parser independently of each other.
    mov rsi, arg2_buf
    mov rdi, str_tokens_flag
    call str_eq
    cmp al, 1
    je .want_tokens

    call party_exec
    cmp byte [party_exec_ok], 1
    jne .exec_failed
    ret

.want_tokens:
    call party_dump_tokens
    ret

.exec_failed:
    mov rsi, msg_party_exec_err
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
    lea rdi, [kw_true]
    call str_eq
    cmp al, 1
    je .pl_kw_true
    lea rsi, [party_ident_buf]
    lea rdi, [kw_false]
    call str_eq
    cmp al, 1
    je .pl_kw_false
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
.pl_kw_true:
    mov r8, TOK_TRUE
    jmp .pl_ident_emit
.pl_kw_false:
    mov r8, TOK_FALSE
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

; ------------------------------------------------------------
; party_exec: walks the token stream produced by party_lex and runs
; it. v0.1-of-v0.1: `display <literal>` statements (string/int/float/
; true/false, optional leading unary minus on a number) and `while
; (true|false) { ... }` loops with a bare boolean-literal condition
; are runnable now. vars/if/func are next - hitting one right now
; reports it as an unsupported-statement error rather than silently
; doing nothing, so scripts fail loudly instead of quietly.
; Out: party_exec_ok = 1 success, 0 failure (+ party_error_line set).
; ------------------------------------------------------------
party_exec:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor r13, r13                  ; token cursor
    mov byte [party_exec_ok], 1
    mov byte [party_killed], 0
    mov byte [kill_flag], 0

    mov r14, TOK_EOF               ; top level runs until EOF
    call party_exec_stmts

.pe_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; party_exec_stmts: executes statements starting at token r13 until
; it reaches a token whose type equals r14 (the "stop token" - callers
; pass TOK_EOF for the top level, TOK_RBRACE for a block body), or
; hits an error, or the running script is killed (Esc). Does NOT
; consume the stop token itself - the caller decides what to do with
; it. Recurses into itself for a while-loop's body.
; In: r13 = starting token index, r14 = stop token type.
; Out: r13 = index of the stop token (success), or of the offending
; token (error). party_exec_ok is left at 1 on success/kill, set to 0
; on error (+ party_error_line). Clobbers rax, rbx, r8-r11, r15.
; ------------------------------------------------------------
party_exec_stmts:
.pes_stmt_loop:
    cmp byte [party_killed], 0
    jne .pes_out                  ; Esc was pressed inside a nested loop - unwind
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_NEWLINE
    jne .pes_check_stop
    inc r13
    jmp .pes_stmt_loop
.pes_check_stop:
    cmp eax, r14d
    je .pes_out                   ; found our stop token - leave it unconsumed
    cmp eax, TOK_EOF
    je .pes_err_here              ; EOF before the expected stop token (e.g. unclosed '{')
    cmp eax, TOK_DISPLAY
    je .pes_display
    cmp eax, TOK_WHILE
    je .pes_while
    jmp .pes_err_here             ; vars/if/func: not runnable yet

.pes_display:
    inc r13                       ; consume 'display'
    call party_tok_ptr
    movzx eax, byte [rbx]

    xor r11, r11                  ; r11 = 1 if a leading '-' was seen
    cmp eax, TOK_MINUS
    jne .pes_disp_dispatch
    mov r11, 1
    inc r13
    call party_tok_ptr
    movzx eax, byte [rbx]

.pes_disp_dispatch:
    cmp eax, TOK_STR
    je .pes_disp_str
    cmp eax, TOK_INT
    je .pes_disp_num
    cmp eax, TOK_FLOAT
    je .pes_disp_num
    cmp eax, TOK_TRUE
    je .pes_disp_true
    cmp eax, TOK_FALSE
    je .pes_disp_false
    jmp .pes_err_here              ; display needs a literal for now

.pes_disp_str:
    cmp r11, 1
    je .pes_err_here               ; "-"+string makes no sense
    call party_print_tok_text
    inc r13
    jmp .pes_stmt_end

.pes_disp_num:
    cmp r11, 1
    jne .pes_disp_num_go
    mov rsi, str_minus_char
    call print_string
.pes_disp_num_go:
    call party_print_tok_text
    inc r13
    jmp .pes_stmt_end

.pes_disp_true:
    cmp r11, 1
    je .pes_err_here
    mov rsi, kw_true
    call print_string
    inc r13
    jmp .pes_stmt_end

.pes_disp_false:
    cmp r11, 1
    je .pes_err_here
    mov rsi, kw_false
    call print_string
    inc r13
    jmp .pes_stmt_end

.pes_stmt_end:
    mov rsi, newline_str
    call print_string
    jmp .pes_stmt_loop

; ---- while (true|false) { ... } ----
.pes_while:
    inc r13                        ; consume 'while'
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LPAREN
    jne .pes_err_here
    inc r13                        ; consume '('

    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_TRUE
    je .pes_while_cond_true
    cmp eax, TOK_FALSE
    je .pes_while_cond_false
    jmp .pes_err_here              ; only a bare true/false condition for now
.pes_while_cond_true:
    mov r15, 1
    jmp .pes_while_cond_done
.pes_while_cond_false:
    xor r15, r15
.pes_while_cond_done:
    inc r13                        ; consume true/false
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_RPAREN
    jne .pes_err_here
    inc r13                        ; consume ')'

    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_LBRACE
    jne .pes_err_here
    inc r13                        ; consume '{' - r13 now = first body token
    mov r10, r13                   ; remember body start, for re-running it

    cmp r15, 0
    jne .pes_while_run

    ; condition is false: skip the body without running it, consume
    ; the matching '}', and move on to whatever follows the loop.
    call party_skip_block
    call party_tok_ptr
    movzx eax, byte [rbx]
    cmp eax, TOK_RBRACE
    jne .pes_err_here
    inc r13
    jmp .pes_stmt_loop

.pes_while_run:
    ; condition is a constant `true`, so this really does loop
    ; forever (same as the language spec's own loop.pa example).
    ; Poll for Esc each iteration - there's no timer/IRQ here to
    ; preempt a tight loop otherwise, so without this the machine
    ; would just hang with no way to stop it.
    call kbd_poll
    cmp byte [kill_flag], 0
    je .pes_while_not_killed
    mov byte [party_killed], 1
    mov rsi, msg_party_killed
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .pes_out
.pes_while_not_killed:
    mov r13, r10
    push r10
    push r14
    mov r14, TOK_RBRACE
    call party_exec_stmts
    pop r14
    pop r10
    cmp byte [party_exec_ok], 0
    je .pes_out                   ; error already recorded by the nested call
    cmp byte [party_killed], 0
    jne .pes_out
    jmp .pes_while_run

.pes_err_here:
    call party_tok_ptr
    mov eax, [rbx+4]               ; token's start offset
    call party_line_at
    mov [party_error_line], eax
    mov byte [party_exec_ok], 0

.pes_out:
    ret

; ------------------------------------------------------------
; party_skip_block: r13 = first token inside a block (already past
; its opening '{'). Advances r13 past the block WITHOUT running any
; of it, stopping at the matching '}' (not consumed) - used to skip
; a while-body whose condition is false. Only tracks brace depth, so
; it doesn't validate anything inside the skipped block.
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
    lea rsi, [fs_io_buf]
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
    lea rsi, [fs_io_buf]
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
msg_party_usage:    db 'usage: party <file.pa>', 10, 0
msg_party_lex_err:  db 'party: lex error near line ', 0
msg_party_exec_err: db 'party: error near line ', 0
msg_party_killed:   db 10, 'party: script killed (Esc)', 10, 0
str_party:          db 'party', 0
str_tokens_flag:    db '-tokens', 0
str_minus_char:     db '-', 0

kw_vars:    db 'vars', 0
kw_if:      db 'if', 0
kw_else:    db 'else', 0
kw_while:   db 'while', 0
kw_func:    db 'func', 0
kw_return:  db 'return', 0
kw_display: db 'display', 0
kw_true:    db 'true', 0
kw_false:   db 'false', 0

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
str_tok_error:   db 'ERROR', 0
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

party_lex_ok:      db 0
party_exec_ok:     db 0
party_killed:      db 0
party_error_line:  dd 0
party_ident_buf:   times PARTY_IDENT_MAX db 0
party_text_buf:    times 64 db 0
ALIGN 8
party_token_count:  dw 0
party_tokens:       times PARTY_MAX_TOKENS*8 db 0