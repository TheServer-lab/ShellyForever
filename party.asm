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

    lea rsi, [fs_io_buf]
    call party_lex

    cmp byte [party_lex_ok], 1
    jne .lex_failed

    call derive_run_filename
    call party_compile_to_run
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
    call kbd_poll
    cmp byte [kill_flag], 0
    je .pes_not_killed
    mov byte [party_killed], 1
    mov rsi, msg_party_killed
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .pes_out
.pes_not_killed:
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
    cmp byte [party_in_compiled], 1
    je .pse_no_line          ; r13 is a codegen buffer cursor here, not a
                              ; token index - looking it up as one would
                              ; index party_tokens out of bounds. Compiled
                              ; runtime errors are reported without a line.
    call party_tok_ptr
    mov eax, [rbx+4]               ; token's start offset
    call party_line_at
    mov [party_error_line], eax
    jmp .pse_done
.pse_no_line:
    mov dword [party_error_line], 0
.pse_done:
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
    lea rsi, [fs_io_buf]
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

; party_val_set_float: rsi = ptr to an 8-byte IEEE-754 double, rdi =
; dest. Exposed to compiled .run programs (KAPI_VAL_SET_FLOAT) since
; float literals are folded to their 8-byte encoding at compile time
; and just need tagging + a copy at run time - no x87 parsing needed
; here, unlike party_parse_float_text.
party_val_set_float:
    mov byte [rdi], PV_FLOAT
    mov rax, [rsi]
    mov [rdi+8], rax
    mov qword [rdi+16], 0
    mov qword [rdi+24], 0
    ret

; ------------------------------------------------------------
; party_neg_top: negates the value on top of the value stack in
; place (unary minus). Only PV_INT/PV_FLOAT are negatable, same rule
; party_parse_unary already applies for interpreted code - this is
; the same logic factored out and exposed to compiled programs
; (KAPI_NEG_TOP) via the table, since compiled unary-minus can't
; inline x87 opcodes itself without duplicating this. On a bad type
; or empty stack, records an error via party_set_err (party_exec_ok
; becomes 0) and leaves the stack untouched. Clobbers rax, rbx, rdx.
; ------------------------------------------------------------
party_neg_top:
    push rbx
    push rdx
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
    jmp .pnt_out
.pnt_float:
    fld qword [rbx+8]
    fchs
    fstp qword [rbx+8]
    jmp .pnt_out
.pnt_err:
    lea rsi, [msg_party_bad_unary]
    call party_set_err
.pnt_out:
    pop rdx
    pop rbx
    ret

; ------------------------------------------------------------
; party_reset_runtime: clears all shared interpreter/compiled-runtime
; state (value stack, call depth, locals, globals, function table,
; error/kill/return flags) and resets the x87 FPU. party_exec does
; this inline for the tree-walking interpreter; this is the same
; reset factored out so cmd_run can call it once before handing
; control to a compiled .run program (which reuses the exact same
; global state via the kernel_api_table primitives) and so
; party_compile_to_run can call it before ITS OWN compile-time use of
; party_collect_funcs/party_push_val/etc, which would otherwise see
; whatever a previous script left behind.
; ------------------------------------------------------------
party_reset_runtime:
    push rbx
    push rdi
    push rcx
    fninit
    mov byte [party_exec_ok], 1
    mov byte [party_killed], 0
    mov byte [party_returning], 0
    mov byte [kill_flag], 0
    mov byte [party_in_compiled], 0
    mov qword [party_vsp], 0
    mov qword [party_call_depth], 0
    mov qword [party_loc_count], 0
    mov qword [party_func_count], 0
    mov qword [party_err_msg_ptr], 0
    mov dword [party_error_line], 0
    lea rdi, [party_var_used]
    mov rcx, MAXVARS
    call party_memzero
    lea rdi, [party_loc_used]
    mov rcx, MAXLOCALS
    call party_memzero
    lea rdi, [party_frame_returned]
    mov rcx, MAXCALLS
    call party_memzero
    pop rcx
    pop rdi
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
    lea rsi, [fs_io_buf]
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
    lea rsi, [fs_io_buf]
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
    lea rsi, [fs_io_buf]
    add rsi, rax
    lea rdi, [party_scratch]
    call party_val_set_str
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
    je .bop_fmode
    cmp byte [party_scratch2], PV_FLOAT
    jne .bop_do_int
.bop_fmode:
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
str_compile_flag:   db 'compile', 0
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

party_lex_ok:      db 0
party_exec_ok:     db 0
party_killed:      db 0
party_error_line:  dd 0
party_in_compiled: db 0    ; 1 while a compiled .run program is executing;
                           ; tells party_set_err that r13 isn't a token
                           ; index right now (see party_set_err).
ALIGN 8
party_c_table:     dq 0    ; kernel_api_table pointer, stashed here by a
                           ; compiled program's own entry prologue so the
                           ; rest of its emitted code can reload it (see
                           ; party_compile_to_run's PROLOGUE emission).
party_c_native_sp: dq 0    ; native rsp at compiled-program entry, so a
                           ; fatal runtime error can unwind arbitrarily
                           ; deep (recursive) call nesting in one step.
party_c_scratch:   times 32 db 0   ; one value-sized scratch slot compiled
                           ; code uses to shuttle values into/out of the
                           ; runtime primitives (e.g. pop-then-truthy for
                           ; an if/while condition).
party_ident_buf:   times PARTY_IDENT_MAX db 0
party_call_name_buf: times PARTY_IDENT_MAX db 0
party_stmt_name_buf: times PARTY_IDENT_MAX db 0
party_text_buf:    times 64 db 0
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
msg_party_eof:            db 'unexpected end of script', 0
msg_party_err_near:        db ' near line ', 0

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
    lea rsi, [party_run_bin_buf]
    call str_len
    add rdi, rax

    xor rbx, rbx
.pc_loop:
    cmp bx, [party_token_count]
    jae .pc_done
    mov rax, rbx
    imul rax, 8
    lea rsi, [party_tokens + rax]
    movzx r8, byte [rsi]
    cmp r8, TOK_DISPLAY
    jne .pc_check_while

    inc rbx
    mov rax, rbx
    imul rax, 8
    lea rsi, [party_tokens + rax]
    movzx r8, byte [rsi]

    xor r11, r11                   ; r11 = 1 if a leading unary '-' precedes the literal
    cmp r8, TOK_MINUS
    jne .pc_disp_dispatch
    mov r11, 1
    inc rbx
    mov rax, rbx
    imul rax, 8
    lea rsi, [party_tokens + rax]
    movzx r8, byte [rsi]

.pc_disp_dispatch:
    cmp r8, TOK_STR
    je .pc_disp_str
    cmp r8, TOK_INT
    je .pc_disp_num
    cmp r8, TOK_FLOAT
    je .pc_disp_num
    cmp r8, TOK_TRUE
    je .pc_disp_true
    cmp r8, TOK_FALSE
    je .pc_disp_false
    jmp .pc_next                   ; not compilable yet (vars/expr/etc) - skip

.pc_disp_str:
    cmp r11, 1
    je .pc_next                    ; "-"+string is invalid - skip, same as the interpreter
    movzx rcx, word [rsi + 2]      ; length = content only (lexer already excludes the quotes)
    mov eax, [rsi + 4]
    lea rsi, [fs_io_buf]
    add rsi, rax                   ; -> first content byte (no off-by-one skip needed)
    call party_emit_lit_display
    jmp .pc_next

.pc_disp_num:
    movzx rcx, word [rsi + 2]      ; length = full token span (digits, '.' for floats)
    mov eax, [rsi + 4]
    lea rsi, [fs_io_buf]
    add rsi, rax
    call party_emit_lit_display
    jmp .pc_next

.pc_disp_true:
    cmp r11, 1
    je .pc_next                    ; "-true" is invalid - skip
    lea rsi, [kw_true]
    mov rcx, 4
    call party_emit_lit_display
    jmp .pc_next

.pc_disp_false:
    cmp r11, 1
    je .pc_next                    ; "-false" is invalid - skip
    lea rsi, [kw_false]
    mov rcx, 5
    call party_emit_lit_display
    jmp .pc_next

; ------------------------------------------------------------
; while (true|false) { ... } compilation.
; Only a literal true/false condition is compilable right now - same
; "literals only" rule party_emit_lit_display already applies to display.
; A non-literal condition (a variable, comparison, etc.) falls through
; to .pc_next just like an uncompilable display argument does, i.e. the
; whole loop is silently skipped rather than crashing the compile.
; Nested while/if blocks inside the body aren't compiled (their DISPLAY
; statements still are, since brace tokens are otherwise just skipped),
; but a while(true) loop nested inside this loop's body isn't supported -
; only one loop level is tracked here.
; ------------------------------------------------------------
.pc_check_while:
    cmp r8, TOK_WHILE
    jne .pc_next
    inc rbx                        ; consume WHILE, rbx -> should be LPAREN
    cmp bx, [party_token_count]
    jae .pc_done
    mov rax, rbx
    imul rax, 8
    lea rsi, [party_tokens + rax]
    movzx r8, byte [rsi]
    cmp r8, TOK_LPAREN
    jne .pc_next                   ; malformed - bail, resume normal scan here
    inc rbx                        ; rbx -> condition token
    cmp bx, [party_token_count]
    jae .pc_done
    mov rax, rbx
    imul rax, 8
    lea rsi, [party_tokens + rax]
    movzx r8, byte [rsi]
    mov r9, r8                     ; r9 = condition token type (TRUE/FALSE/other)
    cmp r8, TOK_TRUE
    je .pc_while_cond_ok
    cmp r8, TOK_FALSE
    je .pc_while_cond_ok
    jmp .pc_next                   ; non-literal condition - not compilable yet
.pc_while_cond_ok:
    inc rbx                        ; rbx -> should be RPAREN
    cmp bx, [party_token_count]
    jae .pc_done
    mov rax, rbx
    imul rax, 8
    lea rsi, [party_tokens + rax]
    movzx r8, byte [rsi]
    cmp r8, TOK_RPAREN
    jne .pc_next
    inc rbx                        ; rbx -> should be LBRACE
    cmp bx, [party_token_count]
    jae .pc_done
    mov rax, rbx
    imul rax, 8
    lea rsi, [party_tokens + rax]
    movzx r8, byte [rsi]
    cmp r8, TOK_LBRACE
    jne .pc_next
    inc rbx                        ; rbx -> first token of the loop body

    cmp r9, TOK_FALSE
    jne .pc_while_true

    ; while(false): dead code - skip the whole body without emitting it,
    ; tracking brace depth so a nested { } inside doesn't end the skip early.
    mov r14, 1
.pc_while_skip:
    cmp bx, [party_token_count]
    jae .pc_done
    mov rax, rbx
    imul rax, 8
    lea rsi, [party_tokens + rax]
    movzx r8, byte [rsi]
    inc rbx
    cmp r8, TOK_LBRACE
    jne .pc_ws_chkclose
    inc r14
    jmp .pc_while_skip
.pc_ws_chkclose:
    cmp r8, TOK_RBRACE
    jne .pc_while_skip
    dec r14
    jnz .pc_while_skip
    jmp .pc_loop                   ; matching close brace consumed - resume

.pc_while_true:
    ; while(true): r13 = address in the .run code buffer where the loop
    ; body's compiled code starts, so the closing brace can jump back here.
    mov r13, rdi

    ; --- Esc/kill check, emitted once so it runs at the top of every
    ; iteration (the backward JMP re-enters right here). Without this,
    ; a while(true) loop can never be stopped, since this kernel has no
    ; preemption - the .run binary just runs to completion (or forever)
    ; once called. call [rdi_table+0x20] -> party_poll_kill_api, which
    ; returns al=1 if Esc was pressed or 'prs kill <pid/name>' targeted
    ; this process; if so, ret out of the compiled program entirely
    ; instead of looping.
    mov byte [rdi], 0xFF           ; call [rdi+0x20]
    mov byte [rdi+1], 0x57
    mov byte [rdi+2], 0x20
    add rdi, 3
    mov byte [rdi], 0x84           ; test al, al
    mov byte [rdi+1], 0xC0
    add rdi, 2
    mov byte [rdi], 0x74           ; jz +1 (skip the ret below if al==0)
    mov byte [rdi+1], 0x01
    add rdi, 2
    mov byte [rdi], 0xC3           ; ret (bail out of the whole .run program)
    inc rdi

    mov r14, 1                     ; brace depth
.pc_while_body:
    cmp bx, [party_token_count]
    jae .pc_done                   ; unterminated body - stop compiling rather
                                    ; than run off the end of the token array
    mov rax, rbx
    imul rax, 8
    lea rsi, [party_tokens + rax]
    movzx r8, byte [rsi]

    cmp r8, TOK_LBRACE
    jne .pc_wb_chkclose
    inc r14
    inc rbx
    jmp .pc_while_body
.pc_wb_chkclose:
    cmp r8, TOK_RBRACE
    jne .pc_wb_chkdisplay
    inc rbx
    dec r14
    jnz .pc_while_body             ; still inside a nested block - keep scanning
    ; this is the matching close brace for the loop - emit JMP rel32 back
    ; to r13 and resume the outer scan right after it
    mov byte [rdi], 0xE9
    mov rax, r13
    sub rax, rdi
    sub rax, 5                     ; rel32 is relative to the end of this jmp
    mov [rdi+1], eax
    add rdi, 5
    jmp .pc_loop
.pc_wb_chkdisplay:
    cmp r8, TOK_DISPLAY
    jne .pc_wb_next
    ; --- same literal-display compilation as the top-level handler above ---
    inc rbx
    mov rax, rbx
    imul rax, 8
    lea rsi, [party_tokens + rax]
    movzx r8, byte [rsi]

    xor r11, r11
    cmp r8, TOK_MINUS
    jne .pc_wb_disp_dispatch
    mov r11, 1
    inc rbx
    mov rax, rbx
    imul rax, 8
    lea rsi, [party_tokens + rax]
    movzx r8, byte [rsi]

.pc_wb_disp_dispatch:
    cmp r8, TOK_STR
    je .pc_wb_disp_str
    cmp r8, TOK_INT
    je .pc_wb_disp_num
    cmp r8, TOK_FLOAT
    je .pc_wb_disp_num
    cmp r8, TOK_TRUE
    je .pc_wb_disp_true
    cmp r8, TOK_FALSE
    je .pc_wb_disp_false
    jmp .pc_wb_next                ; not compilable yet - skip

.pc_wb_disp_str:
    cmp r11, 1
    je .pc_wb_next
    movzx rcx, word [rsi + 2]
    mov eax, [rsi + 4]
    lea rsi, [fs_io_buf]
    add rsi, rax
    call party_emit_lit_display
    jmp .pc_wb_next

.pc_wb_disp_num:
    movzx rcx, word [rsi + 2]
    mov eax, [rsi + 4]
    lea rsi, [fs_io_buf]
    add rsi, rax
    call party_emit_lit_display
    jmp .pc_wb_next

.pc_wb_disp_true:
    cmp r11, 1
    je .pc_wb_next
    lea rsi, [kw_true]
    mov rcx, 4
    call party_emit_lit_display
    jmp .pc_wb_next

.pc_wb_disp_false:
    cmp r11, 1
    je .pc_wb_next
    lea rsi, [kw_false]
    mov rcx, 5
    call party_emit_lit_display
    jmp .pc_wb_next

.pc_wb_next:
    inc rbx
    jmp .pc_while_body

.pc_next:
    inc rbx
    jmp .pc_loop

.pc_done:
    mov byte [rdi], 0xC3
    inc rdi
    mov byte [rdi], 0

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
    mov rcx, rdi
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