; ============================================================
;  ShellyForever  --  kernel.asm
;  Loaded flat at physical address 0x8000 by boot.asm, already
;  running in 64-bit long mode with the first 2MB identity
;  mapped. No IDT/interrupts are set up - keyboard is polled.
; ============================================================

BITS 64
ORG 0x8000

; ---------------- constants ----------------
VGA_BASE        equ 0xB8000
VGA_COLS        equ 80
VGA_ROWS        equ 25
ATTR_NORMAL     equ 0x0A          ; bright green on black
ATTR_PROMPT     equ 0x0E          ; yellow
ATTR_ERROR      equ 0x0C          ; red

OS_NODES        equ 64              ; nodes per volume (each drive holds its own 64-node table)
MAX_MOUNTS      equ 2               ; how many extra drives can be mounted at once

; AHCI (SATA) support: device ids 0-3 are still the legacy ATA PIO slots
; (primary/secondary x master/slave); ids 4..4+AHCI_MAX_PORTS-1 are AHCI
; ports discovered at boot (see ahci_init). dscan/fmt/mount all iterate
; 0..TOTAL_DEVICES-1 and go through disk_select_device, which routes each
; id to the right driver - see that routine for the full explanation.
AHCI_MAX_PORTS  equ 4
TOTAL_DEVICES   equ 4 + AHCI_MAX_PORTS
VOL_NODES       equ OS_NODES        ; every volume, OS or mounted, is the same size
MAX_NODES       equ OS_NODES * (1 + MAX_MOUNTS)   ; 192 = OS volume + 2 mounts
NAME_LEN        equ 32
CONTENT_LEN     equ 160
LINE_MAX        equ 220

SCROLLBACK_LINES equ 100         ; extra off-screen rows kept for Ctrl+Up/Down
HISTORY_MAX      equ 20          ; command history entries kept for Up/Down
KEY_UP           equ 0x11        ; sentinel byte get_char returns for the Up arrow
KEY_DOWN         equ 0x12        ; sentinel byte get_char returns for the Down arrow

MAX_VARS        equ 16
VAR_NAME_LEN    equ 32
MAX_CALC_TOKENS equ 32

PIPE_CAP_MAX    equ 192       ; max bytes captured from a "~" pipe's left side

; ------------------------------------------------------------------
;  SFFS v2 -- ShellyForever File Storage format (on-disk layout).
;  Every drive (OS boot drive and any data drives) uses the same
;  fixed layout so any drive can be scanned, formatted, and mounted:
;
;    LBA  FS_LBA_START     : superblock (512B) - magic 'SFFS', version
;                             byte, reserved, 32-byte disk label
;    LBA  FS_LBA_START+1   : node_type[VOL_NODES]  (1 sector, padded)
;    LBA  FS_LBA_START+2   : node_parent[VOL_NODES] (1 sector, padded)
;    LBA  FS_LBA_START+3.. : node_name[VOL_NODES*NAME_LEN] (4 sectors)
;    LBA  FS_LBA_START+7.. : node_content[VOL_NODES*CONTENT_LEN] (20)
;
;  dscan probes all four ATA device slots for the magic, format writes
;  a fresh empty volume + label, and mount loads a volume's node table
;  into memory (remapping its parent indices) rooted at /<label>/.
;  The kernel occupies LBA 1..260 (KERNEL_SECTORS in boot.asm), so the
;  filesystem region at LBA 300 is well clear of it.
; ------------------------------------------------------------------
FS_LBA_START    equ 300
SFFS_VERSION    equ 2
SUPER_LABEL_OFF equ 8               ; label lives at superblock offset 8..39
SUPER_LBA       equ FS_LBA_START
TYPE_LBA        equ SUPER_LBA + 1
PARENT_LBA      equ SUPER_LBA + 2
NAME_LBA        equ SUPER_LBA + 3
CONTENT_LBA     equ SUPER_LBA + 7
NAME_SECTORS    equ (VOL_NODES * NAME_LEN) / 512          ; 4
CONTENT_SECTORS equ (VOL_NODES * CONTENT_LEN) / 512       ; 20

; ============================================================
kernel_entry:
    cli
    mov rsp, 0x9F000

    ; --- TEMPORARY diagnostic checkpoint A: proves boot.asm's real-mode ->
    ; protected-mode -> long-mode transition landed here at all, before
    ; expand_identity_map or ahci_init get a chance to run/crash. If you
    ; only ever see "12" and never "A", the failure is inside boot.asm's
    ; mode-switch code (A20/GDT/paging/long-mode jump), not in the kernel.
    mov rdi, 0xB8000 + (24*80 + 6) * 2
    mov byte [rdi], 'A'
    mov byte [rdi+1], 0x1F

    ; boot.asm only had room (512-byte sector) to identity-map the first
    ; 64MB. That's not enough for acpi_shutdown's ACPI table walk later -
    ; firmware can put the FADT/DSDT well above 64MB (e.g. ~127MB on a
    ; 128MB guest) - so extend the map to 4GB right away, before anything
    ; else runs. See expand_identity_map below for details.
    call expand_identity_map

    ; --- TEMPORARY diagnostic checkpoint X: expand_identity_map returned
    ; without crashing/hanging. If "A" shows but "X" doesn't, the 4GB
    ; identity-map rebuild is where things go wrong on this hardware.
    mov rdi, 0xB8000 + (24*80 + 7) * 2
    mov byte [rdi], 'X'
    mov byte [rdi+1], 0x1F

    ; probe for a PCI AHCI (SATA) controller and bring up its ports, if any,
    ; as extra disk device slots (4..4+AHCI_MAX_PORTS-1) alongside the four
    ; legacy ATA slots. Inert/no-op if there isn't one (ahci_port_count stays
    ; 0) - the OS behaves exactly as it always did in that case.
    call ahci_init

    ; checkpoint 9: kernel code is executing (proves boot.asm's jump into
    ; 0x8000 landed correctly). Matches the DBG16/32/64 checkpoints in
    ; boot.asm - if you see 1..8 but not this, the kernel wasn't loaded/
    ; jumped to correctly; if the OS otherwise looks fine you can ignore it.
    mov rdi, 0xB8000 + (24*80 + 8) * 2
    mov byte [rdi], 'K'
    mov byte [rdi+1], 0x0F

    call clear_screen
    call fs_load                ; loads persisted fs from disk, or fs_init's a fresh one

    mov rsi, banner
    mov al, ATTR_NORMAL
    call print_string_attr

    cmp byte [fs_disk_available], 0
    je .say_no_disk
    cmp byte [fs_loaded_from_disk], 1
    je .say_loaded
    mov rsi, msg_fresh_fs
    mov al, ATTR_NORMAL
    call print_string_attr
    jmp .banner_done
.say_loaded:
    mov rsi, msg_loaded_fs
    mov al, ATTR_NORMAL
    call print_string_attr
    jmp .banner_done
.say_no_disk:
    mov rsi, msg_no_disk
    mov al, ATTR_ERROR
    call print_string_attr
.banner_done:

    .shell_loop:
        call print_prompt
    
        mov rdi, line_buf
        mov rcx, LINE_MAX-1
        call read_line
    
        ; skip $ comments (lines starting with $)
        cmp byte [line_buf], '$'
        je .shell_loop
    
        ; process ;-chained commands (tokenize + dispatch each segment)
        call process_chain
        jmp .shell_loop

; ------------------------------------------------------------
; process_chain: splits line_buf on ; (respecting double quotes),
; copies each segment to line_buf, then tokenizes and dispatches.
; This lets users write: show hello ; show world
process_chain:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov byte [chain_is_rr], 0

    ; Copy line_buf to chain_scan_buf so we can scan without destroying it
    mov rsi, line_buf
    mov rdi, chain_scan_buf
    call str_copy

    mov r12, chain_scan_buf   ; r12 = start of current segment
    mov r13, chain_scan_buf   ; r13 = scan pointer
    mov r14b, 0               ; r14b = quote state (0=outside, 1=inside)

.chain_scan:
    mov al, [r13]
    test al, al
    jz .chain_done            ; end of string, process last segment

    cmp al, '"'
    je .toggle_quotes

    cmp al, ';'
    je .chain_break

    inc r13
    jmp .chain_scan

.toggle_quotes:
    xor r14b, 1               ; toggle quote state
    inc r13
    jmp .chain_scan

.chain_break:
    ; Found ; at r13 (outside quotes)
    ; Copy segment [r12 .. r13) into line_buf
    push r13                  ; save scan pointer
    mov rsi, r12
    mov rdi, line_buf
.chain_copy:
    mov al, [rsi]
    cmp al, ';'
    je .chain_copy_done
    test al, al
    je .chain_copy_done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .chain_copy
.chain_copy_done:
    mov byte [rdi], 0         ; null-terminate line_buf

    ; Tokenize (and, if a "~" pipe is present, split/capture/rejoin) and
    ; dispatch the segment - see process_segment below.
    call process_segment

.chain_skip:
    pop r13                   ; restore scan pointer (points to ;)
    inc r13                   ; advance past ;
    mov r12, r13              ; r12 = start of next segment
    jmp .chain_scan

.chain_done:
    ; Process last segment (from r12 to end of chain_scan_buf)
    mov rsi, r12
    mov rdi, line_buf
    call str_copy             ; copy last segment to line_buf

    call process_segment

.chain_end:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; process_chain_rr: same as process_chain but for rr script lines.
; Splits on ; (respecting quotes), copies each segment to line_buf,
; tokenizes, and dispatches. Between segments, checks kill_flag
; (set by Esc key or prs kill) and saves/restores rr_content_ptr
; and proc_cur_slot around each dispatch call (dispatch may call
; cmd_rr recursively, clobbering these).
process_chain_rr:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov byte [chain_is_rr], 1

    ; Copy line_buf to chain_scan_buf for scanning
    mov rsi, line_buf
    mov rdi, chain_scan_buf
    call str_copy

    mov r12, chain_scan_buf   ; r12 = start of current segment
    mov r13, chain_scan_buf   ; r13 = scan pointer
    mov r14b, 0               ; r14b = quote state (0=outside, 1=inside)

.rr_chain_scan:
    ; Check for Esc key / kill_flag between segments
    call kbd_poll
    cmp byte [kill_flag], 0
    jne .rr_chain_killed

    mov al, [r13]
    test al, al
    jz .rr_chain_done         ; end of string, process last segment

    cmp al, '"'
    je .rr_toggle_quotes

    cmp al, ';'
    je .rr_chain_break

    inc r13
    jmp .rr_chain_scan

.rr_toggle_quotes:
    xor r14b, 1               ; toggle quote state
    inc r13
    jmp .rr_chain_scan

.rr_chain_break:
    ; Found ; at r13 (outside quotes)
    ; Copy segment [r12 .. r13) into line_buf
    push r13                  ; save scan pointer
    mov rsi, r12
    mov rdi, line_buf
.rr_chain_copy:
    mov al, [rsi]
    cmp al, ';'
    je .rr_chain_copy_done
    test al, al
    je .rr_chain_copy_done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .rr_chain_copy
.rr_chain_copy_done:
    mov byte [rdi], 0         ; null-terminate line_buf

    ; Tokenize (splitting on "~" if present) and dispatch the segment.
    ; process_segment itself saves/restores rr_content_ptr/proc_cur_slot
    ; around every dispatch call it makes, since chain_is_rr is set.
    call process_segment

.rr_chain_skip:
    pop r13                   ; restore scan pointer (points to ;)
    inc r13                   ; advance past ;
    mov r12, r13              ; r12 = start of next segment
    jmp .rr_chain_scan

.rr_chain_done:
    ; Process last segment (from r12 to end of chain_scan_buf)
    mov rsi, r12
    mov rdi, line_buf
    call str_copy             ; copy last segment to line_buf

    call process_segment

.rr_chain_end:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.rr_chain_killed:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; process_segment: called with a single ;-delimited command segment
; sitting null-terminated in line_buf (chain_is_rr says whether this
; came from process_chain or process_chain_rr, which changes how
; do_dispatch_call below wraps dispatch). Looks for a "~" outside
; double quotes:
;
;   left ~ right
;
; If none is found, this is exactly the original behaviour: tokenize
; line_buf and dispatch it.
;
; If one is found, "left" is run with its output captured instead of
; printed (e.g. calc's printed result, a variable's show'd value, a
; file's view'd content). "right" is then either:
;   - "= name" or "=name"  -> the captured text is parsed as a decimal
;     integer and stored into that variable (same rules as ordinary
;     "name = value" assignment).
;   - any other command    -> the captured text is appended to it as
;     one extra quoted argument and the whole thing is dispatched, e.g.
;     "calc 2+2 ~ show" becomes "show 4".
;
; Example: calc 1 + 1 * 5 ~ = a ; show a   -->  prints 6
process_segment:
    push rbx
    push r12
    push r14

    ; --- scan line_buf for '~' outside double quotes ---
    mov rsi, line_buf
    xor r14, r14              ; r14b = quote state (0=outside, 1=inside)
    xor r12, r12               ; r12 = pointer to '~' (0 = none found)
.pseg_scan:
    mov al, [rsi]
    test al, al
    jz .pseg_scan_done
    cmp al, '"'
    je .pseg_toggle
    cmp al, '~'
    je .pseg_found
    inc rsi
    jmp .pseg_scan
.pseg_toggle:
    xor r14b, 1
    inc rsi
    jmp .pseg_scan
.pseg_found:
    mov r12, rsi
.pseg_scan_done:

    test r12, r12
    jz .pseg_plain

    ; ---------- "~" pipe path ----------
    ; copy the left half [line_buf .. r12) into pipe_left_buf
    mov rsi, line_buf
    mov rdi, pipe_left_buf
.pseg_copyleft:
    cmp rsi, r12
    je .pseg_copyleft_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .pseg_copyleft
.pseg_copyleft_done:
    mov byte [rdi], 0

    ; copy the right half (r12+1..end), skipping leading spaces, into
    ; pipe_right_buf. Must happen before line_buf gets overwritten below.
    lea rsi, [r12+1]
.pseg_skipsp:
    cmp byte [rsi], ' '
    jne .pseg_right_start
    inc rsi
    jmp .pseg_skipsp
.pseg_right_start:
    mov rdi, pipe_right_buf
    call str_copy

    ; run the left side with its output captured instead of printed
    mov rsi, pipe_left_buf
    mov rdi, line_buf
    call str_copy

    mov byte [pipe_capture_buf], 0
    mov qword [pipe_capture_len], 0
    mov byte [pipe_capture_on], 1

    mov rsi, line_buf
    mov rdi, cmd_buf
    call next_token
    mov rdi, arg1_buf
    call next_token
    mov rdi, arg2_buf
    call next_token
    mov rdi, arg3_buf
    call next_token
    mov rdi, arg4_buf
    call next_token

    cmp byte [cmd_buf], 0
    je .pseg_left_empty
    call do_dispatch_call
.pseg_left_empty:
    mov byte [pipe_capture_on], 0

    ; trim a single trailing newline left behind by the captured command
    mov rax, [pipe_capture_len]
    test rax, rax
    jz .pseg_trim_done
    lea rbx, [pipe_capture_buf + rax - 1]
    cmp byte [rbx], 10
    jne .pseg_trim_done
    mov byte [rbx], 0
.pseg_trim_done:

    ; tokenize the right side to see if it's the "= name" shorthand
    mov rsi, pipe_right_buf
    mov rdi, cmd_buf
    call next_token
    mov rdi, arg1_buf
    call next_token

    cmp byte [cmd_buf], 0
    je .pseg_done              ; nothing after the pipe - nothing to do

    cmp byte [cmd_buf], '='
    jne .pseg_generic

    ; assignment shorthand: "= name" (name in arg1_buf) or "=name"
    ; (name is cmd_buf+1)
    lea rsi, [cmd_buf+1]
    cmp byte [rsi], 0
    jne .pseg_have_name
    mov rsi, arg1_buf
.pseg_have_name:
    push rsi                   ; save name pointer across parse_int
    mov rsi, pipe_capture_buf
    call parse_int
    pop rsi
    cmp cl, 1
    jne .pseg_bad_value
    mov rbx, rax
    call var_set
    jmp .pseg_done

.pseg_bad_value:
    mov rsi, msg_bad_value
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .pseg_done

.pseg_generic:
    ; rebuild line_buf as: <right side> "<captured value>" and dispatch
    mov rsi, pipe_right_buf
    mov rdi, line_buf
    call str_copy
    mov rsi, pipe_space_quote_str
    mov rdi, line_buf
    call str_append
    mov rsi, pipe_capture_buf
    mov rdi, line_buf
    call str_append
    mov rsi, pipe_quote_str
    mov rdi, line_buf
    call str_append

    mov rsi, line_buf
    mov rdi, cmd_buf
    call next_token
    mov rdi, arg1_buf
    call next_token
    mov rdi, arg2_buf
    call next_token
    mov rdi, arg3_buf
    call next_token
    mov rdi, arg4_buf
    call next_token

    cmp byte [cmd_buf], 0
    je .pseg_done
    call do_dispatch_call
    jmp .pseg_done

.pseg_plain:
    ; no "~" pipe: original behaviour - tokenize line_buf as-is, dispatch
    mov rsi, line_buf
    mov rdi, cmd_buf
    call next_token
    mov rdi, arg1_buf
    call next_token
    mov rdi, arg2_buf
    call next_token
    mov rdi, arg3_buf
    call next_token
    mov rdi, arg4_buf
    call next_token

    cmp byte [cmd_buf], 0
    je .pseg_done
    call do_dispatch_call

.pseg_done:
    pop r14
    pop r12
    pop rbx
    ret

; do_dispatch_call: calls dispatch on the tokenized cmd_buf/arg*_buf.
; When chain_is_rr is set (we're running inside an rr script), wraps
; the call exactly like process_chain_rr always did: dispatch may
; recurse into cmd_rr, clobbering rr_content_ptr/proc_cur_slot, so
; those are saved/restored around it.
do_dispatch_call:
    cmp byte [chain_is_rr], 0
    je .ddc_plain
    push qword [rr_content_ptr]
    movzx rax, byte [proc_cur_slot]
    push rax
    call dispatch
    pop rax
    mov [proc_cur_slot], al
    pop qword [rr_content_ptr]
    ret
.ddc_plain:
    call dispatch
    ret

; ------------------------------------------------------------
; expand_identity_map: extends boot.asm's minimal 0-64MB identity map to
; a full 0-4GB identity map using 2MB pages.
;
; Bug this fixes: "sdown" was rebooting the machine instead of shutting
; it down. Root cause: boot.asm's page tables only identity-map the
; first 64MB of physical memory (PML4@0x1000 -> PDPT@0x2000 -> a single
; PD@0x3000 with 32 entries). acpi_shutdown later walks the firmware's
; RSDT/XSDT/FADT/DSDT tables to find the real ACPI power-off port/value,
; and those tables are NOT guaranteed to live under 64MB - confirmed by
; tracing this exact machine: the FADT/DSDT land around 127MB with a
; 128MB guest. Touching that unmapped memory takes a page fault, and
; since there's no IDT installed yet, it escalates straight to a triple
; fault - which looks exactly like a reboot from the user's perspective.
;
; Fix: before anything else runs, reuse boot.asm's existing PML4/PDPT
; (no need to touch those) and add 3 more PD tables (PD1-PD3 at
; 0x4000/0x5000/0x6000, alongside boot.asm's PD0 at 0x3000), wiring all
; 4 into PDPT[0..3]. Then refill all 4 PDs (contiguous in memory) with
; 2048 sequential 2MB pages, giving a full 4GB identity map - enough
; headroom for any RAM size/firmware table placement QEMU, Bochs,
; VirtualBox, or real hardware is likely to use.
expand_identity_map:
    push rax
    push rcx
    push rdi

    ; PDPT[1..3] -> PD1/PD2/PD3 (present+rw). PDPT[0] already points at
    ; boot.asm's PD0 @ 0x3000.
    mov dword [0x2000 + 1*8], 0x4000 | 0x3
    mov dword [0x2000 + 1*8 + 4], 0
    mov dword [0x2000 + 2*8], 0x5000 | 0x3
    mov dword [0x2000 + 2*8 + 4], 0
    mov dword [0x2000 + 3*8], 0x6000 | 0x3
    mov dword [0x2000 + 3*8 + 4], 0

    ; PD0..PD3 are contiguous (0x3000..0x6FFF = 16KB = 2048 qwords).
    ; Refill them all with sequential 2MB pages 0, 2MB, ... 4094MB,
    ; replacing boot.asm's partial PD0 (only entries 0-31 were valid)
    ; with a complete map.
    mov rdi, 0x3000
    mov rax, 0x83                  ; present+rw+PS(2MB), base 0
    mov rcx, 512 * 4               ; 512 entries/PD * 4 PDs = 4GB total
.fill:
    mov [rdi], rax
    add rax, 0x200000
    add rdi, 8
    loop .fill

    mov rax, cr3                   ; reload CR3 to flush any stale TLB
    mov cr3, rax                   ; entries from the old partial map

    pop rdi
    pop rcx
    pop rax
    ret

; ============================================================
; dispatch: compares cmd_buf against known commands
; ============================================================
dispatch:
    ; --- variable assignment:  name = value ---
    mov rsi, arg1_buf
    mov rdi, str_eq_sign
    call str_eq
    cmp al, 1
    je cmd_assign

    mov rsi, cmd_buf
    mov rdi, str_calc
    call str_eq
    cmp al, 1
    je cmd_calc

    mov rsi, cmd_buf
    mov rdi, str_edit
    call str_eq
    cmp al, 1
    je cmd_edit

    mov rsi, cmd_buf
    mov rdi, str_cf
    call str_eq
    cmp al, 1
    je cmd_cf

    mov rsi, cmd_buf
    mov rdi, str_mkf
    call str_eq
    cmp al, 1
    je cmd_mkf

    mov rsi, cmd_buf
    mov rdi, str_mkfl
    call str_eq
    cmp al, 1
    je cmd_mkfl

    mov rsi, cmd_buf
    mov rdi, str_show
    call str_eq
    cmp al, 1
    je cmd_show

    mov rsi, cmd_buf
    mov rdi, str_ls
    call str_eq
    cmp al, 1
    je cmd_ls

    mov rsi, cmd_buf
    mov rdi, str_cat
    call str_eq
    cmp al, 1
    je cmd_cat

    mov rsi, cmd_buf
    mov rdi, str_pwd
    call str_eq
    cmp al, 1
    je cmd_pwd

    mov rsi, cmd_buf
    mov rdi, str_clear
    call str_eq
    cmp al, 1
    je cmd_clear

    mov rsi, cmd_buf
    mov rdi, str_help
    call str_eq
    cmp al, 1
    je cmd_help

    mov rsi, cmd_buf
    mov rdi, str_reboot
    call str_eq
    cmp al, 1
    je cmd_reboot

    mov rsi, cmd_buf
    mov rdi, str_sync
    call str_eq
    cmp al, 1
    je cmd_sync

    mov rsi, cmd_buf
    mov rdi, str_del
    call str_eq
    cmp al, 1
    je cmd_del

    mov rsi, cmd_buf
    mov rdi, str_rmv
    call str_eq
    cmp al, 1
    je cmd_rmv

    mov rsi, cmd_buf
    mov rdi, str_sdown
    call str_eq
    cmp al, 1
    je cmd_sdown

    mov rsi, cmd_buf
    mov rdi, str_rname
    call str_eq
    cmp al, 1
    je cmd_rname

    mov rsi, cmd_buf
    mov rdi, str_cpy
    call str_eq
    cmp al, 1
    je cmd_cpy

    mov rsi, cmd_buf
    mov rdi, str_mov
    call str_eq
    cmp al, 1
    je cmd_mov

    mov rsi, cmd_buf
    mov rdi, str_rr
    call str_eq
    cmp al, 1
    je cmd_rr

    mov rsi, cmd_buf
    mov rdi, str_prs
    call str_eq
    cmp al, 1
    je cmd_prs

    mov rsi, cmd_buf
    mov rdi, str_auth
    call str_eq
    cmp al, 1
    je cmd_auth

    mov rsi, cmd_buf
    mov rdi, str_vars
    call str_eq
    cmp al, 1
    je cmd_vars

    mov rsi, cmd_buf
    mov rdi, str_dscan
    call str_eq
    cmp al, 1
    je cmd_dscan

    mov rsi, cmd_buf
    mov rdi, str_format
    call str_eq
    cmp al, 1
    je cmd_format

    mov rsi, cmd_buf
    mov rdi, str_mount
    call str_eq
    cmp al, 1
    je cmd_mount

    mov rsi, cmd_buf
    mov rdi, str_label
    call str_eq
    cmp al, 1
    je cmd_label

    ; unknown command
    mov rsi, msg_unknown1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, cmd_buf
    call print_string
    mov rsi, msg_unknown2
    call print_string
    ret

; ------------------------------------------------------------
cmd_cf:
    cmp byte [arg1_buf], 0
    jne .have_arg
    ret
.have_arg:
    ; fs_resolve_path handles "/", "/home", "..", ".", multi-segment
    ; paths, and plain single names all through one code path now.
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    xor rdi, rdi               ; whole-path mode: resolve every component
    call fs_resolve_path
    cmp rax, -1
    je .not_found
    mov [cur_dir], rax
    ret
.not_found:
    mov rsi, msg_no_folder
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
cmd_mkf:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .bad_path
    mov r11, rax                ; parent dir the new folder goes in
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, -1                ; any type counts as "exists"
    call fs_find_child
    cmp rax, -1
    jne .exists
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 1                 ; type folder
    call fs_create_node
    cmp rax, -1
    je .full
    ret
.exists:
    mov rsi, msg_exists
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.full:
    cmp byte [fs_name_too_long], 1
    je .toolong
    mov rsi, msg_full
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.bad_path:
    mov rsi, msg_bad_path
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_mkfl: make a file. Supports flags in arg3/arg4:
;   -force   overwrite if file already exists (prints warning)
;   -silent  suppress the -force overwrite warning
;   -info    print verbose info (filename + content length)
; ------------------------------------------------------------
cmd_mkfl:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .bad_path
    mov r11, rax                 ; parent dir the new file goes in
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .exists
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2                  ; type file
    call fs_create_node
    cmp rax, -1
    je .full
    ; rax = new node index, copy arg2 into its content
    mov rbx, rax
    mov rdi, rbx
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    mov rsi, arg2_buf
    call str_copy

    ; Check -info flag
    mov rsi, arg3_buf
    mov rdi, str_info
    call str_eq
    cmp al, 1
    je .print_info_new
    mov rsi, arg4_buf
    mov rdi, str_info
    call str_eq
    cmp al, 1
    je .print_info_new
    jmp .mkfl_done

.print_info_new:
    mov rsi, msg_mkfl_info
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_mkfl_info2
    call print_string
    mov rsi, arg2_buf
    xor rcx, rcx
.mkfl_strlen1:
    cmp byte [rsi], 0
    je .mkfl_strlen1_done
    inc rcx
    inc rsi
    jmp .mkfl_strlen1
.mkfl_strlen1_done:
    mov rax, rcx
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, msg_mkfl_info3
    call print_string
    jmp .mkfl_done

.exists:
    ; rax = existing node index; save it (str_eq clobbers al)
    mov rbx, rax

    ; Check -force flag in arg3_buf or arg4_buf
    mov rsi, arg3_buf
    mov rdi, str_force
    call str_eq
    cmp al, 1
    je .force_ok
    mov rsi, arg4_buf
    mov rdi, str_force
    call str_eq
    cmp al, 1
    je .force_ok
    jmp .no_force

.force_ok:
    ; -force: print warning unless -silent
    mov rsi, arg3_buf
    mov rdi, str_silent
    call str_eq
    cmp al, 1
    je .overwrite
    mov rsi, arg4_buf
    mov rdi, str_silent
    call str_eq
    cmp al, 1
    je .overwrite
    mov rsi, msg_mkfl_overwrite
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string

.overwrite:
    ; rbx = existing node index, overwrite content
    mov rax, rbx
    mov rdi, rax
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    mov rsi, arg2_buf
    call str_copy

    ; Check -info flag
    mov rsi, arg3_buf
    mov rdi, str_info
    call str_eq
    cmp al, 1
    je .print_info_overwrite
    mov rsi, arg4_buf
    mov rdi, str_info
    call str_eq
    cmp al, 1
    je .print_info_overwrite
    jmp .mkfl_done

.print_info_overwrite:
    mov rsi, msg_mkfl_info
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_mkfl_info2
    call print_string
    mov rsi, arg2_buf
    xor rcx, rcx
.mkfl_strlen2:
    cmp byte [rsi], 0
    je .mkfl_strlen2_done
    inc rcx
    inc rsi
    jmp .mkfl_strlen2
.mkfl_strlen2_done:
    mov rax, rcx
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, msg_mkfl_info3
    call print_string
    jmp .mkfl_done

.no_force:
    mov rsi, msg_exists
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.full:
    cmp byte [fs_name_too_long], 1
    je .toolong
    mov rsi, msg_full
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.bad_path:
    mov rsi, msg_bad_path
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret
.mkfl_done:
    ret

; ------------------------------------------------------------
cmd_show:
    mov rsi, arg1_buf
    call var_get
    cmp cl, 1
    je .show_var
    mov rsi, arg1_buf
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, newline_str
    call print_string
    ret
.show_var:
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_assign: reached when arg1_buf == "=" ; cmd_buf is the variable
; name, arg2_buf is either a decimal literal or another variable's name.
cmd_assign:
    mov rsi, arg2_buf
    call parse_int
    cmp cl, 1
    je .ca_haveval
    mov rsi, arg2_buf
    call var_get
    cmp cl, 1
    je .ca_haveval
    mov rsi, msg_bad_value
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.ca_haveval:
    mov rbx, rax
    mov rsi, cmd_buf
    call var_set
    ret

; ------------------------------------------------------------
; cmd_calc: re-scans the raw line_buf (untouched by tokenizing) to get
; the full expression after the leading "calc" word, so expressions of
; any length/operator-count are supported (not just 2 args).
cmd_calc:
    mov rsi, line_buf
.cc_skipcmd:
    mov al, [rsi]
    cmp al, 0
    je .cc_noexpr
    cmp al, ' '
    je .cc_skipspaces
    inc rsi
    jmp .cc_skipcmd
.cc_skipspaces:
    mov al, [rsi]
    cmp al, ' '
    jne .cc_haveexpr
    inc rsi
    jmp .cc_skipspaces
.cc_haveexpr:
    cmp byte [rsi], 0
    je .cc_noexpr
    call eval_expr
    cmp cl, 1
    jne .cc_bad
    lea rdi, [calc_out_buf]
    call int_to_str
    mov rsi, calc_out_buf
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, newline_str
    call print_string
    ret
.cc_bad:
    mov rsi, msg_calc_err
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.cc_noexpr:
    mov rsi, msg_calc_need_expr
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
; cmd_edit: opens the built-in editor on an existing file. Types over
; a copy of the file's content (backspace erases, Enter adds a newline),
; ESC ends editing and asks whether to save (y) or discard (n).
cmd_edit:
    cmp byte [arg1_buf], 0
    jne .ce_have_arg
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.ce_have_arg:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .ce_not_found
    push r15
    mov r15, rax

    mov rdi, rax
    imul rdi, CONTENT_LEN
    lea rsi, [node_content + rdi]
    lea rdi, [edit_buf]
    call str_copy

    call clear_screen
    mov rsi, msg_edit_header1
    mov al, ATTR_PROMPT
    call print_string_attr
    mov rsi, arg1_buf
    mov al, ATTR_PROMPT
    call print_string_attr
    mov rsi, msg_edit_header2
    mov al, ATTR_PROMPT
    call print_string_attr

    lea rsi, [edit_buf]
    mov al, ATTR_NORMAL
    call print_string_attr

    lea rsi, [edit_buf]
    call str_len
    push r14
    mov r14, rax
.ce_loop:
    call get_char
    cmp al, 27
    je .ce_finish
    cmp al, 0x0D
    je .ce_newline
    cmp al, 8
    je .ce_bksp
    cmp al, KEY_UP
    je .ce_loop                  ; no history/scrollback editing here, ignore
    cmp al, KEY_DOWN
    je .ce_loop
    cmp r14, CONTENT_LEN-1
    jae .ce_loop
    lea rdi, [edit_buf]
    mov [rdi + r14], al
    inc r14
    mov byte [rdi + r14], 0
    push rbx
    mov bl, ATTR_NORMAL
    call putchar
    pop rbx
    jmp .ce_loop
.ce_newline:
    cmp r14, CONTENT_LEN-1
    jae .ce_loop
    lea rdi, [edit_buf]
    mov byte [rdi + r14], 10
    inc r14
    mov byte [rdi + r14], 0
    mov al, 0x0A
    push rbx
    xor bl, bl
    call putchar
    pop rbx
    jmp .ce_loop
.ce_bksp:
    cmp r14, 0
    je .ce_loop
    dec r14
    lea rdi, [edit_buf]
    mov byte [rdi + r14], 0
    call do_backspace
    jmp .ce_loop
.ce_finish:
    mov rsi, msg_save_prompt
    mov al, ATTR_PROMPT
    call print_string_attr
.ce_wait_key:
    call get_char
    cmp al, 'y'
    je .ce_save
    cmp al, 'Y'
    je .ce_save
    cmp al, 'n'
    je .ce_discard
    cmp al, 'N'
    je .ce_discard
    jmp .ce_wait_key
.ce_save:
    mov rdi, r15
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    lea rsi, [edit_buf]
    call str_copy
    call clear_screen
    mov rsi, msg_saved
    mov al, ATTR_NORMAL
    call print_string_attr
    pop r14
    pop r15
    ret
.ce_discard:
    call clear_screen
    mov rsi, msg_discarded
    mov al, ATTR_NORMAL
    call print_string_attr
    pop r14
    pop r15
    ret
.ce_not_found:
    mov rsi, msg_no_file
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
cmd_pwd:
    call print_path
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
cmd_ls:
    xor r9, r9                  ; index
    xor r12, r12                ; found-any flag
.loop:
    cmp r9, MAX_NODES
    jae .done
    cmp byte [node_type + r9], 0
    je .next
    movzx rax, word [node_parent + r9*2]
    cmp rax, [cur_dir]
    jne .next
    mov r12, 1
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rsi, [node_name + rdi]
    mov al, ATTR_NORMAL
    call print_string_attr
    cmp byte [node_type + r9], 1
    jne .isfile
    mov rsi, tag_folder
    jmp .printtag
.isfile:
    mov rsi, tag_file
.printtag:
    call print_string
.next:
    inc r9
    jmp .loop
.done:
    cmp r12, 0
    jne .ret
    mov rsi, msg_empty
    call print_string
.ret:
    ret

; ------------------------------------------------------------
cmd_cat:
    cmp byte [arg1_buf], 0
    jne .have_arg
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
    mov rdi, rax
    imul rdi, CONTENT_LEN
    lea rsi, [node_content + rdi]
    mov al, ATTR_NORMAL
    call print_string_attr
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
cmd_clear:
    call clear_screen
    ret

; ------------------------------------------------------------
; cmd_help: with no argument, prints the full command list as before.
; With an argument ("help <command>"), prints just that command's
; detailed help text instead (see help_lookup/help_* strings below).
cmd_help:
    cmp byte [arg1_buf], 0
    jne help_lookup
    mov rsi, help_text
    mov al, ATTR_NORMAL
    call print_string_attr
    ret

; help_lookup: arg1_buf holds the command name (or symbol - ";", "~",
; "$" need to be quoted on the command line, e.g. help ";", since
; unquoted they'd be parsed as chaining/piping/comment syntax first).
help_lookup:
    mov rsi, arg1_buf
    mov rdi, str_cf
    call str_eq
    cmp al, 1
    je .h_cf

    mov rsi, arg1_buf
    mov rdi, str_mkf
    call str_eq
    cmp al, 1
    je .h_mkf

    mov rsi, arg1_buf
    mov rdi, str_mkfl
    call str_eq
    cmp al, 1
    je .h_mkfl

    mov rsi, arg1_buf
    mov rdi, str_show
    call str_eq
    cmp al, 1
    je .h_show

    mov rsi, arg1_buf
    mov rdi, str_ls
    call str_eq
    cmp al, 1
    je .h_ls

    mov rsi, arg1_buf
    mov rdi, str_cat
    call str_eq
    cmp al, 1
    je .h_cat

    mov rsi, arg1_buf
    mov rdi, str_edit
    call str_eq
    cmp al, 1
    je .h_edit

    mov rsi, arg1_buf
    mov rdi, str_del
    call str_eq
    cmp al, 1
    je .h_del

    mov rsi, arg1_buf
    mov rdi, str_rname
    call str_eq
    cmp al, 1
    je .h_rname

    mov rsi, arg1_buf
    mov rdi, str_cpy
    call str_eq
    cmp al, 1
    je .h_cpy

    mov rsi, arg1_buf
    mov rdi, str_mov
    call str_eq
    cmp al, 1
    je .h_mov

    mov rsi, arg1_buf
    mov rdi, str_eq_sign
    call str_eq
    cmp al, 1
    je .h_assign

    mov rsi, arg1_buf
    mov rdi, str_rmv
    call str_eq
    cmp al, 1
    je .h_rmv

    mov rsi, arg1_buf
    mov rdi, str_vars
    call str_eq
    cmp al, 1
    je .h_vars

    mov rsi, arg1_buf
    mov rdi, str_calc
    call str_eq
    cmp al, 1
    je .h_calc

    mov rsi, arg1_buf
    mov rdi, str_rr
    call str_eq
    cmp al, 1
    je .h_rr

    mov rsi, arg1_buf
    mov rdi, str_prs
    call str_eq
    cmp al, 1
    je .h_prs

    mov rsi, arg1_buf
    mov rdi, str_auth
    call str_eq
    cmp al, 1
    je .h_auth

    mov rsi, arg1_buf
    mov rdi, str_pwd
    call str_eq
    cmp al, 1
    je .h_pwd

    mov rsi, arg1_buf
    mov rdi, str_clear
    call str_eq
    cmp al, 1
    je .h_clear

    mov rsi, arg1_buf
    mov rdi, str_help
    call str_eq
    cmp al, 1
    je .h_help

    mov rsi, arg1_buf
    mov rdi, str_dscan
    call str_eq
    cmp al, 1
    je .h_dscan

    mov rsi, arg1_buf
    mov rdi, str_format
    call str_eq
    cmp al, 1
    je .h_fmt

    mov rsi, arg1_buf
    mov rdi, str_mount
    call str_eq
    cmp al, 1
    je .h_mount

    mov rsi, arg1_buf
    mov rdi, str_label
    call str_eq
    cmp al, 1
    je .h_label

    mov rsi, arg1_buf
    mov rdi, str_sync
    call str_eq
    cmp al, 1
    je .h_sync

    mov rsi, arg1_buf
    mov rdi, str_reboot
    call str_eq
    cmp al, 1
    je .h_rboot

    mov rsi, arg1_buf
    mov rdi, str_sdown
    call str_eq
    cmp al, 1
    je .h_sdown

    mov rsi, arg1_buf
    mov rdi, str_semicolon
    call str_eq
    cmp al, 1
    je .h_semicolon

    mov rsi, arg1_buf
    mov rdi, str_tilde
    call str_eq
    cmp al, 1
    je .h_tilde

    mov rsi, arg1_buf
    mov rdi, str_dollar
    call str_eq
    cmp al, 1
    je .h_dollar

    ; unknown command name
    mov rsi, msg_help_unknown1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, msg_help_unknown2
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.h_cf:
    mov rsi, help_cf
    jmp .h_print
.h_mkf:
    mov rsi, help_mkf
    jmp .h_print
.h_mkfl:
    mov rsi, help_mkfl
    jmp .h_print
.h_show:
    mov rsi, help_show
    jmp .h_print
.h_ls:
    mov rsi, help_ls
    jmp .h_print
.h_cat:
    mov rsi, help_cat
    jmp .h_print
.h_edit:
    mov rsi, help_edit
    jmp .h_print
.h_del:
    mov rsi, help_del
    jmp .h_print
.h_rname:
    mov rsi, help_rname
    jmp .h_print
.h_cpy:
    mov rsi, help_cpy
    jmp .h_print
.h_mov:
    mov rsi, help_mov
    jmp .h_print
.h_assign:
    mov rsi, help_assign
    jmp .h_print
.h_rmv:
    mov rsi, help_rmv
    jmp .h_print
.h_vars:
    mov rsi, help_vars
    jmp .h_print
.h_calc:
    mov rsi, help_calc
    jmp .h_print
.h_rr:
    mov rsi, help_rr
    jmp .h_print
.h_prs:
    mov rsi, help_prs
    jmp .h_print
.h_auth:
    mov rsi, help_auth
    jmp .h_print
.h_pwd:
    mov rsi, help_pwd
    jmp .h_print
.h_clear:
    mov rsi, help_clear
    jmp .h_print
.h_help:
    mov rsi, help_help
    jmp .h_print
.h_dscan:
    mov rsi, help_dscan
    jmp .h_print
.h_fmt:
    mov rsi, help_fmt
    jmp .h_print
.h_mount:
    mov rsi, help_mount
    jmp .h_print
.h_label:
    mov rsi, help_label
    jmp .h_print
.h_sync:
    mov rsi, help_sync
    jmp .h_print
.h_rboot:
    mov rsi, help_rboot
    jmp .h_print
.h_sdown:
    mov rsi, help_sdown
    jmp .h_print
.h_semicolon:
    mov rsi, help_semicolon
    jmp .h_print
.h_tilde:
    mov rsi, help_tilde
    jmp .h_print
.h_dollar:
    mov rsi, help_dollar

.h_print:
    mov al, ATTR_NORMAL
    call print_string_attr
    ret

; ------------------------------------------------------------
cmd_sync:
    call fs_save
    jc .fail
    mov rsi, msg_synced
    mov al, ATTR_NORMAL
    call print_string_attr
    ret
.fail:
    mov rsi, msg_sync_failed
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
; cmd_dscan: probe all four ATA device slots (primary/secondary x
; master/slave) for SFFS volumes and report what's attached.
cmd_dscan:
    push r13
    push r15
    mov rsi, msg_dscan_header
    mov al, ATTR_NORMAL
    call print_string_attr
    xor r15, r15                ; found-any flag
    xor r13, r13                ; device id
.scan:
    cmp r13, TOTAL_DEVICES
    jae .done
    mov al, r13b
    call disk_select_device
    mov rax, SUPER_LBA
    lea rdi, [fs_super_buf]
    call disk_read_sector
    jc .next                    ; no response -> slot is empty
    ; present; check for the SFFS magic + version
    cmp byte [fs_super_buf+0], 'S'
    jne .other
    cmp byte [fs_super_buf+1], 'F'
    jne .other
    cmp byte [fs_super_buf+2], 'F'
    jne .other
    cmp byte [fs_super_buf+3], 'S'
    jne .other
    cmp byte [fs_super_buf+4], SFFS_VERSION
    jne .other
    ; valid SFFS volume
    mov r15, 1
    mov rsi, msg_dscan_found1   ; "  device "
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rax, r13
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, msg_dscan_found2   ; " ("
    call print_string
    mov al, r13b
    call print_device_name
    mov rsi, msg_dscan_found3   ; "): SFFS volume '"
    call print_string
    lea rsi, [fs_super_buf + SUPER_LABEL_OFF]
    call print_string
    mov rsi, msg_dscan_found4   ; "'"
    call print_string
    mov rsi, newline_str
    call print_string
    jmp .next
.other:
    ; a drive is there but it isn't ours
    mov r15, 1
    mov rsi, msg_dscan_found1   ; "  device "
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rax, r13
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, msg_dscan_found2   ; " ("
    call print_string
    mov al, r13b
    call print_device_name
    mov rsi, msg_dscan_other2   ; "): present, not SFFS"
    call print_string
    mov rsi, newline_str
    call print_string
.next:
    inc r13
    jmp .scan
.done:
    cmp r15, 0
    jne .has
    mov rsi, msg_dscan_none
    mov al, ATTR_NORMAL
    call print_string_attr
.has:
    pop r15
    pop r13
    ret

; print_device_name: al = device id 0..TOTAL_DEVICES-1 -> prints "primary
; master" etc. for ids 0-3 (legacy ATA), or "ahci port <n>" (n = the real
; physical AHCI port number, from ahci_port_num) for ids 4+.
print_device_name:
    push rax
    push rbx
    push rsi
    mov bl, al
    cmp bl, 4
    jae .ahci
    and bl, 3
    cmp bl, 2
    jb .primary
    mov rsi, msg_dev_secondary
    jmp .which
.primary:
    mov rsi, msg_dev_primary
.which:
    call print_string
    test bl, 1
    jz .master
    mov rsi, msg_dev_slave
    call print_string
    jmp .done
.master:
    mov rsi, msg_dev_master
    call print_string
    jmp .done
.ahci:
    mov rsi, msg_dev_ahci
    call print_string
    sub bl, 4
    movzx eax, bl
    mov eax, [ahci_port_num + rax*4]
    lea rdi, [dev_name_num_buf]
    call int_to_str
    mov rsi, dev_name_num_buf
    call print_string
.done:
    pop rsi
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
; cmd_format: format a drive with the SFFS format and give it a label.
;   fmt <label>             first present drive that isn't SFFS yet        
;   fmt <label> -force      first present drive (even an existing volume)  
; The boot drive (device 0) is never touched unless -force is given.
cmd_format:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_fmt_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    mov rsi, arg1_buf
    call str_len
    cmp rax, 32
    jae .too_long
    ; find the target device
    xor r13, r13                ; device being scanned
    xor rbx, rbx                ; last valid SFFS device seen (for -force)
    mov r14b, 0                 ; any valid SFFS device seen?
.scan:
    cmp r13, TOTAL_DEVICES
    jae .scan_done
    mov al, r13b
    call disk_select_device
    mov rax, SUPER_LBA
    lea rdi, [fs_super_buf]
    call disk_read_sector
    jc .next                    ; absent
    cmp byte [fs_super_buf+0], 'S'
    jne .unformatted
    cmp byte [fs_super_buf+1], 'F'
    jne .unformatted
    cmp byte [fs_super_buf+2], 'F'
    jne .unformatted
    cmp byte [fs_super_buf+3], 'S'
    jne .unformatted
    cmp byte [fs_super_buf+4], SFFS_VERSION
    jne .unformatted
    ; already an SFFS volume - remember it for the -force path
    mov rbx, r13
    mov r14b, 1
    jmp .next
.unformatted:
    ; skip the boot drive (device 0) unless -force; it holds the OS
    cmp r13, 0
    je .next
    jmp .found
.next:
    inc r13
    jmp .scan
.scan_done:
    mov rsi, arg2_buf
    mov rdi, str_force
    call str_eq
    cmp al, 1
    jne .none
    cmp r14b, 1
    jne .none
    mov r13, rbx
    jmp .format_target
.none:
    mov rsi, msg_fmt_none
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.too_long:
    mov rsi, msg_fmt_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.found:
    ; format the first unformatted drive we hit
.format_target:
    mov al, r13b
    call disk_select_device
    ; superblock: magic + version + label
    mov rdi, fs_super_buf
    mov rcx, 512 / 8
    xor rax, rax
    rep stosq
    mov byte [fs_super_buf+0], 'S'
    mov byte [fs_super_buf+1], 'F'
    mov byte [fs_super_buf+2], 'F'
    mov byte [fs_super_buf+3], 'S'
    mov byte [fs_super_buf+4], SFFS_VERSION
    mov rsi, arg1_buf
    lea rdi, [fs_super_buf + SUPER_LABEL_OFF]
    call str_copy
    mov rax, SUPER_LBA
    lea rsi, [fs_super_buf]
    call disk_write_sector
    jc .disk_err
    ; node_type: a single root folder
    mov rdi, fs_super_buf
    mov rcx, 512 / 8
    xor rax, rax
    rep stosq
    mov byte [fs_super_buf], 1
    mov rax, TYPE_LBA
    lea rsi, [fs_super_buf]
    call disk_write_sector
    jc .disk_err
    ; node_parent: root parent = 0xFFFF
    mov rdi, fs_super_buf
    mov rcx, 512 / 8
    xor rax, rax
    rep stosq
    mov word [fs_super_buf], 0xFFFF
    mov rax, PARENT_LBA
    lea rsi, [fs_super_buf]
    call disk_write_sector
    jc .disk_err
    ; node_name: root named <label>, then zero sectors
    mov rdi, fs_super_buf
    mov rcx, 512 / 8
    xor rax, rax
    rep stosq
    mov rsi, arg1_buf
    lea rdi, [fs_super_buf]
    call str_copy
    mov rax, NAME_LBA
    mov rcx, NAME_SECTORS
.name_wr:
    push rax
    push rcx
    lea rsi, [fs_super_buf]
    call disk_write_sector
    pop rcx
    pop rax
    jc .disk_err
    inc rax
    loop .name_wr
    ; node_content: zero sectors
    mov rdi, fs_super_buf
    mov rcx, 512 / 8
    xor rax, rax
    rep stosq
    mov rax, CONTENT_LBA
    mov rcx, CONTENT_SECTORS
.content_wr:
    push rax
    push rcx
    lea rsi, [fs_super_buf]
    call disk_write_sector
    pop rcx
    pop rax
    jc .disk_err
    inc rax
    loop .content_wr
    ; report
    mov rsi, msg_fmt_ok1
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_fmt_ok2
    call print_string
    mov al, r13b
    call print_device_name
    mov rsi, msg_fmt_ok3
    call print_string
    mov rsi, newline_str
    call print_string
    ret
.disk_err:
    mov rsi, msg_fmt_err
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
; cmd_mount: attach a formatted drive to the filesystem tree.
;   mount <label>
; Loads the volume whose superblock label matches <label>, remaps its
; node table into a free mount slice, and roots it as /<label>/ under
; /home. Then 'cf <label>' (or 'cf /<label>') enters it.
cmd_mount:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_mount_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    ; already mounted?
    xor r12, r12
.already_loop:
    cmp r12, MAX_MOUNTS
    jae .already_done
    cmp byte [mount_used + r12], 0
    je .already_next
    mov rax, r12
    imul rax, 32
    lea rsi, [mount_label + rax]
    mov rdi, arg1_buf
    call str_eq
    cmp al, 1
    je .already_mounted
.already_next:
    inc r12
    jmp .already_loop
.already_done:
    ; find a device whose label matches
    xor r13, r13
.scan:
    cmp r13, TOTAL_DEVICES
    jae .not_found
    mov al, r13b
    call disk_select_device
    mov rax, SUPER_LBA
    lea rdi, [fs_super_buf]
    call disk_read_sector
    jc .scan_next
    cmp byte [fs_super_buf+0], 'S'
    jne .scan_next
    cmp byte [fs_super_buf+1], 'F'
    jne .scan_next
    cmp byte [fs_super_buf+2], 'F'
    jne .scan_next
    cmp byte [fs_super_buf+3], 'S'
    jne .scan_next
    cmp byte [fs_super_buf+4], SFFS_VERSION
    jne .scan_next
    lea rsi, [fs_super_buf + SUPER_LABEL_OFF]
    mov rdi, arg1_buf
    call str_eq
    cmp al, 1
    je .found
.scan_next:
    inc r13
    jmp .scan
.found:
    ; find a free mount slot
    xor r12, r12
.slot_loop:
    cmp r12, MAX_MOUNTS
    jae .too_many
    cmp byte [mount_used + r12], 0
    je .slot_ok
    inc r12
    jmp .slot_loop
.slot_ok:
    ; base node = VOL_NODES * (slot + 1)
    mov rdi, r12
    inc rdi
    imul rdi, VOL_NODES
    mov al, r13b
    call vol_read
    cmp rax, -1
    je .load_fail
    ; record the mount
    mov byte [mount_used + r12], 1
    mov byte [mount_device + r12], r13b
    mov rax, r12
    imul rax, 32
    lea rdi, [mount_label + rax]
    mov rsi, arg1_buf
    call str_copy
    ; root the volume as /<label>/ under the OS root
    mov rdi, r12
    inc rdi
    imul rdi, VOL_NODES
    mov byte [node_type + rdi], 1
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    mov rsi, arg1_buf
    call str_copy
    ; report
    mov rsi, msg_mount_ok1      ; "Mounted "
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_mount_ok2      ; " at /"
    call print_string
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_mount_ok3      ; "/. Use 'cf "
    call print_string
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_mount_ok4      ; "' to enter it."
    call print_string
    mov rsi, newline_str
    call print_string
    ret
.already_mounted:
    mov rsi, msg_mount_already
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret
.not_found:
    mov rsi, msg_mount_none
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_mount_none2
    call print_string
    ret
.too_many:
    mov rsi, msg_mount_full
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.load_fail:
    mov rsi, msg_mount_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
; cmd_label: rename a formatted drive's label in place.
;   label <old> <new>
; Finds the device whose on-disk superblock label is <old> and
; overwrites just the label field with <new> - the volume's node table
; (files/folders) is never touched, so this is safe even on a drive
; that already has data on it. Refuses if <new> is already in use by
; a different drive. If the target drive happens to be currently
; mounted, the in-memory mount_label and the mount's root folder name
; are updated too, so the change is visible immediately.
cmd_label:
    cmp byte [arg1_buf], 0
    jne .have_old
    mov rsi, msg_label_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_old:
    cmp byte [arg2_buf], 0
    jne .have_new
    mov rsi, msg_label_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_new:
    mov rsi, arg2_buf
    call str_len
    cmp rax, NAME_LEN
    jae .too_long
    ; refuse if <new> is already used by some other drive
    xor r13, r13
.dup_scan:
    cmp r13, TOTAL_DEVICES
    jae .dup_done
    mov al, r13b
    call disk_select_device
    mov rax, SUPER_LBA
    lea rdi, [fs_super_buf]
    call disk_read_sector
    jc .dup_next
    cmp byte [fs_super_buf+0], 'S'
    jne .dup_next
    cmp byte [fs_super_buf+1], 'F'
    jne .dup_next
    cmp byte [fs_super_buf+2], 'F'
    jne .dup_next
    cmp byte [fs_super_buf+3], 'S'
    jne .dup_next
    cmp byte [fs_super_buf+4], SFFS_VERSION
    jne .dup_next
    lea rsi, [fs_super_buf + SUPER_LABEL_OFF]
    mov rdi, arg2_buf
    call str_eq
    cmp al, 1
    je .in_use
.dup_next:
    inc r13
    jmp .dup_scan
.dup_done:
    ; find the target device whose label matches <old>
    xor r13, r13
.scan:
    cmp r13, TOTAL_DEVICES
    jae .not_found
    mov al, r13b
    call disk_select_device
    mov rax, SUPER_LBA
    lea rdi, [fs_super_buf]
    call disk_read_sector
    jc .scan_next
    cmp byte [fs_super_buf+0], 'S'
    jne .scan_next
    cmp byte [fs_super_buf+1], 'F'
    jne .scan_next
    cmp byte [fs_super_buf+2], 'F'
    jne .scan_next
    cmp byte [fs_super_buf+3], 'S'
    jne .scan_next
    cmp byte [fs_super_buf+4], SFFS_VERSION
    jne .scan_next
    lea rsi, [fs_super_buf + SUPER_LABEL_OFF]
    mov rdi, arg1_buf
    call str_eq
    cmp al, 1
    je .found
.scan_next:
    inc r13
    jmp .scan
.found:
    ; fs_super_buf still holds this device's just-read superblock;
    ; overwrite only the label field, leave everything else as-is
    mov rdi, fs_super_buf
    add rdi, SUPER_LABEL_OFF
    mov rcx, NAME_LEN
    xor al, al
    rep stosb
    mov rsi, arg2_buf
    mov rdi, fs_super_buf
    add rdi, SUPER_LABEL_OFF
    call str_copy
    ; the device is still selected from the scan above - write the
    ; patched superblock straight back (node table sectors are untouched)
    mov rax, SUPER_LBA
    lea rsi, [fs_super_buf]
    call disk_write_sector
    jc .io_fail
    ; if this device is currently mounted, keep live state in sync too
    xor r12, r12
.mount_check:
    cmp r12, MAX_MOUNTS
    jae .report
    cmp byte [mount_used + r12], 0
    je .mount_next
    movzx eax, byte [mount_device + r12]
    cmp eax, r13d
    jne .mount_next
    mov rax, r12
    imul rax, 32
    lea rdi, [mount_label + rax]
    mov rsi, arg2_buf
    call str_copy
    mov rdi, r12
    inc rdi
    imul rdi, VOL_NODES
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    mov rsi, arg2_buf
    call str_copy
    jmp .report
.mount_next:
    inc r12
    jmp .mount_check
.report:
    mov rsi, msg_label_ok1      ; "Relabeled '"
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_label_ok2      ; "' to '"
    call print_string
    mov rsi, arg2_buf
    call print_string
    mov rsi, msg_label_ok3      ; "'."
    call print_string
    ret
.in_use:
    mov rsi, msg_label_inuse1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg2_buf
    call print_string
    mov rsi, msg_label_inuse2
    call print_string
    ret
.not_found:
    mov rsi, msg_label_none1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_label_none2
    call print_string
    ret
.io_fail:
    mov rsi, msg_label_iofail
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.too_long:
    mov rsi, msg_label_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
cmd_reboot:
    cmp byte [auth_valid], 0
    jne .reboot_ok
    mov rsi, msg_auth_required
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.reboot_ok:
    call fs_save                ; persist filesystem before restarting (best effort)
.wait_kbd:
    in al, 0x64
    test al, 2
    jnz .wait_kbd
    mov al, 0xFE
    out 0x64, al
.hang:
    hlt
    jmp .hang

; ------------------------------------------------------------
; cmd_del: delete a file or folder in the current folder. Folders are
; deleted recursively (fs_delete_tree), files are deleted directly.
cmd_del:
    cmp byte [auth_valid], 0
    jne .del_ok
    mov rsi, msg_auth_required
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.del_ok:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_need_name
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
    mov r10, -1                 ; any type (file or folder)
    call fs_find_child
    cmp rax, -1
    je .not_found
    mov r14, rax
    call fs_delete_tree          ; recurses for folders, deletes a single node for files
    ; if we just deleted a mounted volume's root, drop that mount slot too
    xor r13, r13
.clear_mount_loop:
    cmp r13, MAX_MOUNTS
    jae .clear_mount_done
    cmp byte [mount_used + r13], 0
    je .clear_mount_next
    mov rdi, r13
    inc rdi
    imul rdi, VOL_NODES
    cmp rdi, r14
    jne .clear_mount_next
    mov byte [mount_used + r13], 0
    mov byte [mount_device + r13], 0
    mov rdi, r13
    imul rdi, 32
    lea rdi, [mount_label + rdi]
    mov rcx, 32
    xor al, al
    rep stosb
.clear_mount_next:
    inc r13
    jmp .clear_mount_loop
.clear_mount_done:
    ret
.not_found:
    mov rsi, msg_no_entry
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_rmv: remove a variable by name
cmd_rmv:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    mov rsi, arg1_buf
    call var_find
    cmp rax, -1
    je .not_found
    mov r9, rax
    mov byte [var_used + r9], 0
    mov qword [var_value + r9*8], 0
    mov rdi, r9
    imul rdi, VAR_NAME_LEN
    lea rdi, [var_name + rdi]
    mov rcx, VAR_NAME_LEN
    xor al, al
    rep stosb
    ret
.not_found:
    mov rsi, msg_no_var
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_sdown: save the filesystem, then power off. Tries a real ACPI
; shutdown first (finds the FADT/_S5 via the RSDP, which is what real
; hardware actually requires), then falls back to the fixed magic ports
; QEMU/Bochs/VirtualBox use as debug shutdown shortcuts, and finally
; just halts safely if nothing worked.
cmd_sdown:
    cmp byte [auth_valid], 0
    jne .sdown_ok
    mov rsi, msg_auth_required
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.sdown_ok:
    call fs_save
    mov rsi, msg_shutting_down
    mov al, ATTR_NORMAL
    call print_string_attr
    call acpi_shutdown            ; if this works, we never come back
    mov dx, 0x604                ; QEMU (older versions) ACPI PM control
    mov ax, 0x2000
    out dx, ax
    mov dx, 0xB004                ; Bochs / very old QEMU
    mov ax, 0x2000
    out dx, ax
    mov dx, 0x4004                ; VirtualBox
    mov ax, 0x3400
    out dx, ax
.hang:
    cli
    hlt
    jmp .hang

; ------------------------------------------------------------
; acpi_shutdown: real ACPI power-off, the mechanism real hardware
; actually needs (the hardcoded emulator ports above are debug
; shortcuts that only exist in software, not on physical machines).
;
; Steps (see the ACPI spec / OSDev wiki "Shutdown" page for the
; equivalent C version of this):
;   1) find the RSDP by scanning the EBDA and 0xE0000-0xFFFFF for the
;      "RSD PTR " signature
;   2) walk the RSDT (or XSDT on ACPI 2.0+) to find the FADT ("FACP")
;   3) from the FADT, get the DSDT pointer and the PM1a/PM1b control
;      ports, and enable ACPI mode via SMI_CMD if it isn't already on
;   4) scan the DSDT's AML bytecode for the "_S5_" package, which
;      encodes the SLP_TYPa/SLP_TYPb sleep-state values for power-off
;   5) write (SLP_TYP | SLP_EN) to the PM1 control port(s)
;
; If any step fails (table missing, signature doesn't check out, etc)
; this just returns and the caller falls back to the legacy ports.
; Requires boot.asm's identity map to cover wherever these tables land
; in physical memory - see the 64MB mapping in pm_entry.
acpi_shutdown:
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

    call acpi_find_rsdp
    test rax, rax
    jz .out
    mov r15, rax                  ; r15 = RSDP address

    ; prefer the XSDT (8-byte pointers) on ACPI 2.0+, else the RSDT
    ; (4-byte pointers)
    movzx eax, byte [r15+15]      ; RSDP revision
    cmp al, 2
    jb .use_rsdt
    mov rax, [r15+24]             ; XSDT address
    test rax, rax
    jz .use_rsdt
    mov r13, rax
    mov r12, 8                    ; pointer size in this table
    jmp .have_sdt
.use_rsdt:
    xor eax, eax
    mov eax, [r15+16]             ; RSDT address (32-bit)
    test rax, rax
    jz .out
    mov r13, rax
    mov r12, 4
.have_sdt:
    mov eax, [r13+4]              ; table Length
    sub eax, 36
    jle .out
    xor edx, edx
    mov ebx, r12d
    div ebx                       ; eax = number of table pointers
    mov rcx, rax
    lea rbx, [r13+36]             ; cursor into the pointer array
    xor r10, r10                  ; r10 = FADT address once found
.find_fadt:
    cmp rcx, 0
    je .fadt_done
    cmp r12, 4
    jne .ptr8
    xor eax, eax
    mov eax, [rbx]
    jmp .have_ptr
.ptr8:
    mov rax, [rbx]
.have_ptr:
    push rax
    mov rsi, rax
    lea rdi, [facp_sig]
    mov rcx, 4
    call bytes_eq
    mov r14b, al                 ; stash match result - 'pop rax' below would clobber al
    pop rax
    cmp r14b, 1
    jne .fadt_next
    mov r10, rax
    jmp .fadt_done
.fadt_next:
    add rbx, r12
    dec rcx
    jmp .find_fadt
.fadt_done:
    test r10, r10
    jz .out                       ; no FADT -> can't do a real ACPI shutdown

    mov eax, [r10 + FADT_PM1a_CNT_BLK]
    test eax, eax
    jz .out                       ; no PM1a control port, give up
    mov [acpi_pm1a_port], eax
    mov eax, [r10 + FADT_PM1b_CNT_BLK]
    mov [acpi_pm1b_port], eax

    ; enable ACPI mode (SCI_EN, bit 0 of PM1a control) if not already on
    mov dx, word [acpi_pm1a_port]
    in ax, dx
    test ax, 1
    jnz .have_acpi_mode
    mov edx, [r10 + FADT_SMI_CMD]
    test edx, edx
    jz .have_acpi_mode            ; no SMI_CMD -> assume already usable
    movzx eax, byte [r10 + FADT_ACPI_ENABLE]
    test eax, eax
    jz .have_acpi_mode            ; 0 means "n/a" per spec
    out dx, al
    mov r8, 1000000                ; bounded poll, never hang forever
.poll_acpi:
    mov dx, word [acpi_pm1a_port]
    in ax, dx
    test ax, 1
    jnz .have_acpi_mode
    dec r8
    jnz .poll_acpi
    ; timed out - try the shutdown write anyway; some firmwares still
    ; honor it
.have_acpi_mode:

    ; locate and validate the DSDT
    mov eax, [r10 + FADT_DSDT]
    test eax, eax
    jz .out
    xor r13, r13
    mov r13d, eax                 ; r13 = DSDT address
    mov rsi, r13
    lea rdi, [dsdt_sig]
    mov rcx, 4
    call bytes_eq
    cmp al, 1
    jne .out

    mov eax, [r13+4]               ; DSDT length
    mov r14, r13
    add r14, rax                   ; r14 = end of table
    sub r14, 4                     ; leave room for a 4-byte compare
    add r13, 36                    ; r13 = AML scan cursor, past the header

.find_s5:
    cmp r13, r14
    jae .out                       ; _S5_ not found -> give up
    mov rsi, r13
    lea rdi, [s5_sig]
    mov rcx, 4
    call bytes_eq
    cmp al, 1
    je .found_s5
    inc r13
    jmp .find_s5
.found_s5:
    ; classic decode of the AML PackageOp following "_S5_" to pull out
    ; SLP_TYPa / SLP_TYPb without a full AML parser
    add r13, 5                     ; skip "_S5_" (4 bytes) + PackageOp (1)
    movzx eax, byte [r13]
    mov ecx, eax
    shr ecx, 6                     ; top 2 bits of PkgLength lead byte
    add ecx, 2                     ; + the lead byte + NumElements byte
    add r13, rcx                   ; now at the first package element

    cmp byte [r13], 0x0A           ; AML ByteConst prefix
    jne .have_typa
    inc r13
.have_typa:
    movzx eax, byte [r13]
    mov [acpi_slp_typa], al
    inc r13
    cmp byte [r13], 0x0A
    jne .have_typb
    inc r13
.have_typb:
    movzx eax, byte [r13]
    mov [acpi_slp_typb], al

    movzx eax, byte [acpi_slp_typa]
    shl eax, 10
    or eax, 1 << 13                ; SLP_EN
    mov dx, word [acpi_pm1a_port]
    out dx, ax                     ; if this is really ACPI, we never return

    mov eax, [acpi_pm1b_port]
    test eax, eax
    jz .out
    movzx eax, byte [acpi_slp_typb]
    shl eax, 10
    or eax, 1 << 13
    mov dx, word [acpi_pm1b_port]
    out dx, ax

.out:
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

; acpi_find_rsdp: scans the EBDA, then 0xE0000-0xFFFFF, 16 bytes at a
; time, for the 8-byte "RSD PTR " signature with a valid checksum.
; Returns rax = RSDP address, or 0 if not found.
acpi_find_rsdp:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    xor eax, eax
    mov ax, [0x40E]                ; EBDA segment, BIOS data area
    shl eax, 4
    test eax, eax
    jz .pass2
    mov r8, rax
    mov r9, rax
    add r9, 1024
.ebda_loop:
    cmp r8, r9
    jae .pass2
    mov rsi, r8
    lea rdi, [rsdp_sig]
    mov rcx, 8
    call bytes_eq
    cmp al, 1
    jne .ebda_next
    mov rsi, r8
    call acpi_rsdp_checksum_ok
    cmp al, 1
    jne .ebda_next
    mov rax, r8
    jmp .found
.ebda_next:
    add r8, 16
    jmp .ebda_loop
.pass2:
    mov r8, 0xE0000
    mov r9, 0x100000
.main_loop:
    cmp r8, r9
    jae .notfound
    mov rsi, r8
    lea rdi, [rsdp_sig]
    mov rcx, 8
    call bytes_eq
    cmp al, 1
    jne .main_next
    mov rsi, r8
    call acpi_rsdp_checksum_ok
    cmp al, 1
    jne .main_next
    mov rax, r8
    jmp .found
.main_next:
    add r8, 16
    jmp .main_loop
.notfound:
    xor eax, eax
.found:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; acpi_rsdp_checksum_ok: rsi = candidate RSDP address. Returns al=1 if
; the first 20 bytes (the ACPI 1.0 fixed part, present in all versions)
; sum to 0 mod 256, else al=0.
acpi_rsdp_checksum_ok:
    push rsi
    push rcx
    push rbx
    xor bl, bl
    mov rcx, 20
.loop:
    add bl, [rsi]
    inc rsi
    loop .loop
    test bl, bl
    jnz .bad
    mov al, 1
    jmp .out
.bad:
    xor al, al
.out:
    pop rbx
    pop rcx
    pop rsi
    ret

; bytes_eq: rsi, rdi = buffers, rcx = length. Returns al=1 if equal.
bytes_eq:
    push rsi
    push rdi
    push rcx
.loop:
    cmp rcx, 0
    je .eq
    mov al, [rsi]
    cmp al, [rdi]
    jne .neq
    inc rsi
    inc rdi
    dec rcx
    jmp .loop
.eq:
    mov al, 1
    jmp .out
.neq:
    xor al, al
.out:
    pop rcx
    pop rdi
    pop rsi
    ret

FADT_SMI_CMD       equ 48
FADT_ACPI_ENABLE   equ 52
FADT_PM1a_CNT_BLK  equ 64
FADT_PM1b_CNT_BLK  equ 68
FADT_DSDT          equ 40

rsdp_sig: db "RSD PTR "
facp_sig: db "FACP"
dsdt_sig: db "DSDT"
s5_sig:   db "_S5_"
acpi_pm1a_port: dd 0
acpi_pm1b_port: dd 0
acpi_slp_typa:  db 0
acpi_slp_typb:  db 0

; ------------------------------------------------------------
; cmd_rname: rename a file or folder in the current folder
cmd_rname:
    cmp byte [arg1_buf], 0
    jne .check2
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.check2:
    cmp byte [arg2_buf], 0
    jne .have_args
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_args:
    mov rsi, arg2_buf
    call str_len
    cmp rax, NAME_LEN
    jae .toolong
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .not_found
    mov r13, rax                ; folder the source lives in
    mov rax, r13
    mov rsi, leaf1_buf
    mov r10, -1                 ; any type
    call fs_find_child
    cmp rax, -1
    je .not_found
    mov r9, rax                 ; node to rename
    mov rax, r13                ; new name is checked/applied in the same folder
    mov rsi, arg2_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .exists
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    mov rsi, arg2_buf
    call str_copy
    ret
.exists:
    mov rsi, msg_exists
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.not_found:
    mov rsi, msg_no_entry
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_cpy: copy a file or folder (recursively) within the current folder
; under a new name
cmd_cpy:
    cmp byte [arg1_buf], 0
    jne .check2
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.check2:
    cmp byte [arg2_buf], 0
    jne .have_args
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_args:
    ; resolve the source path -> (folder, leaf) and find the node
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .not_found
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .not_found
    mov r14, rax                ; src node index

    ; resolve the destination path -> (folder, leaf name to copy as).
    ; Same rule as mov: if arg2 names an existing folder, copy INTO it
    ; under the source's own name rather than treating the last path
    ; component as a literal new name.
    mov rax, [cur_dir]
    mov rsi, arg2_buf
    xor rdi, rdi                 ; rdi=0 -> whole-path mode
    call fs_resolve_path
    cmp rax, -1
    je .split_dest2
    mov r10, rax                  ; dest parent = the existing folder
    mov rsi, leaf1_buf
    lea rdi, [leaf2_buf]
    call str_copy
    jmp .have_dest2
.split_dest2:
    mov rax, [cur_dir]
    mov rsi, arg2_buf
    mov rdi, leaf2_buf
    call fs_resolve_path
    cmp rax, -1
    je .bad_dest
    mov r10, rax                 ; dest parent folder
.have_dest2:
    mov rax, r14
    mov rsi, leaf2_buf
    call fs_copy_node
    cmp rax, -1
    jne .ret_ok
    cmp byte [fs_name_too_long], 1
    je .toolong
    mov rsi, msg_copy_failed
    mov al, ATTR_ERROR
    call print_string_attr
.ret_ok:
    ret
.toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.bad_dest:
    mov rsi, msg_bad_path
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg2_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret
.not_found:
    mov rsi, msg_no_entry
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_mov: move/rename a file or folder (recursively) within the current
; folder - implemented as copy-then-delete-original.
cmd_mov:
    cmp byte [arg1_buf], 0
    jne .check2
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.check2:
    cmp byte [arg2_buf], 0
    jne .have_args
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_args:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .not_found
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .not_found
    mov r14, rax                 ; remember src idx to delete after copy

    ; If arg2 names an existing FOLDER (whole-path mode: every component,
    ; including the last, is resolved via fs_find_child instead of copied
    ; verbatim into leaf_buf), move INTO that folder under the source's own
    ; name - standard mv-into-directory behavior. Only fall back to treating
    ; the last component of arg2 as a brand-new name when arg2 doesn't
    ; resolve to an existing folder. Without this, "mov hi.txt /home/test"
    ; tried to create a file literally called "test" next to the folder
    ; "test" and failed with a bogus "already exists" error.
    mov rax, [cur_dir]
    mov rsi, arg2_buf
    xor rdi, rdi                  ; rdi=0 -> whole-path mode
    call fs_resolve_path
    cmp rax, -1
    je .split_dest
    mov r10, rax                  ; dest parent = the existing folder
    mov rsi, leaf1_buf
    lea rdi, [leaf2_buf]
    call str_copy                 ; keep the source's own name
    jmp .have_dest
.split_dest:
    mov rax, [cur_dir]
    mov rsi, arg2_buf
    mov rdi, leaf2_buf
    call fs_resolve_path
    cmp rax, -1
    je .bad_dest
    mov r10, rax                  ; dest parent folder
.have_dest:
    mov rax, r14
    mov rsi, leaf2_buf
    call fs_copy_node
    cmp rax, -1
    je .failed
    mov rax, r14
    call fs_delete_tree
    ret
.failed:
    cmp byte [fs_name_too_long], 1
    je .toolong
    mov rsi, msg_copy_failed
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.bad_dest:
    mov rsi, msg_bad_path
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg2_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret
.not_found:
    mov rsi, msg_no_entry
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ============================================================
;  NON-BLOCKING KEYBOARD POLL  (for Esc-to-kill during scripts)
; ============================================================
; kbd_poll: checks if a key is available (non-blocking). If it's
; Esc (scancode 0x01 make code), sets kill_flag. Other keys are
; consumed and discarded.
kbd_poll:
    in al, 0x64
    test al, 1
    jz .no_key
    in al, 0x60
    cmp al, 0x01                  ; Esc make code
    jne .no_key
    mov byte [kill_flag], 1
.no_key:
    ret

; ============================================================
;  PROCESS TABLE HELPERS
; ============================================================
; proc_alloc: finds a free slot, assigns a PID, sets state=running.
; Returns rax = slot index, or -1 if full.
proc_alloc:
    push rcx
    xor rcx, rcx
.palloc_loop:
    cmp rcx, MAX_PROCESSES
    jae .palloc_fail
    cmp byte [proc_state + rcx], 0
    je .palloc_found
    inc rcx
    jmp .palloc_loop
.palloc_found:
    mov [proc_cur_slot], cl
    mov byte [proc_state + rcx], 1    ; running
    mov rax, [proc_next_pid]
    mov [proc_id + rcx*2], ax
    inc word [proc_next_pid]
    mov rax, rcx
    jmp .palloc_out
.palloc_fail:
    mov rax, -1
.palloc_out:
    pop rcx
    ret

; proc_free_slot: rdi = slot index. Frees the slot.
proc_free_slot:
    push rbx
    push rcx
    push rdi
    mov rbx, rdi                    ; rbx = slot index
    mov byte [proc_state + rbx], 0
    mov word [proc_id + rbx*2], 0
    mov rax, rbx
    imul rax, 32
    lea rdi, [proc_name + rax]
    mov rcx, 32
    xor al, al
    rep stosb
    pop rdi
    pop rcx
    pop rbx
    ret

; ============================================================
;  cmd_rr: run a rush script file
;  Usage: rr <filename.rsh>
;  Creates a process called "runrush <filename>" with a PID.
;  Executes each line of the file as a rush command. Lines
;  starting with $ are treated as comments and skipped.
;  Press Esc to kill the running script.
; ============================================================
cmd_rr:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    ; Find the file in the filesystem (like "view" does)
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .not_found
    mov r11, rax                    ; parent dir
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2                      ; type file
    call fs_find_child
    cmp rax, -1
    je .not_found

    ; rax = node index, get content pointer
    mov rbx, rax                    ; node index
    mov rdi, rbx
    imul rdi, CONTENT_LEN
    lea r12, [node_content + rdi]   ; r12 = pointer to file content
    mov [rr_content_ptr], r12

    ; Allocate a process slot
    call proc_alloc
    cmp rax, -1
    je .proc_full

    ; Store process name "runrush"
    movzx rax, byte [proc_cur_slot]
    imul rax, 32
    lea rdi, [proc_name + rax]
    mov rsi, str_runrush
    call str_copy

    ; Reset kill flag
    mov byte [kill_flag], 0

    ; Print "runrush <filename> (pid N)"
    mov rsi, msg_rr_running
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    movzx rax, byte [proc_cur_slot]
    movzx rax, word [proc_id + rax*2]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, msg_rr_pid1
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, show_num_buf
    call print_string
    mov rsi, msg_rr_pid2
    call print_string

    ; Parse and execute lines
.rr_loop:
    ; Check for Esc key (non-blocking)
    call kbd_poll
    cmp byte [kill_flag], 0
    jne .killed

    ; Reload content pointer (dispatch may have clobbered registers)
    mov r12, [rr_content_ptr]

    ; Check if we're at end of content
    cmp byte [r12], 0
    je .done

    ; Copy one line to line_buf
    mov rdi, line_buf
    xor r14, r14                    ; line length counter
.rr_copy_loop:
    mov al, [r12]
    cmp al, 0
    je .rr_line_end
    cmp al, 0x0A                    ; newline
    je .rr_line_end
    cmp r14, LINE_MAX-1
    jae .rr_line_end
    mov [rdi], al
    inc rdi
    inc r14
    inc r12
    jmp .rr_copy_loop
.rr_line_end:
    ; Update content pointer
    mov [rr_content_ptr], r12

    ; Skip the newline if we hit one
    cmp byte [r12], 0x0A
    jne .rr_no_newline
    inc r12
    mov [rr_content_ptr], r12
.rr_no_newline:

    mov byte [rdi], 0               ; null-terminate line_buf

    ; Skip $ comments
    cmp byte [line_buf], '$'
    je .rr_next_line

    ; Skip empty lines
    cmp byte [line_buf], 0
    je .rr_next_line

    ; Process ;-chained commands with kill_flag checks between segments
    call process_chain_rr

.rr_next_line:
    jmp .rr_loop

.done:
    movzx rax, byte [proc_cur_slot]
    mov rdi, rax
    call proc_free_slot
    mov rsi, msg_rr_done
    mov al, ATTR_NORMAL
    call print_string_attr
    ret

.killed:
    movzx rax, byte [proc_cur_slot]
    mov rdi, rax
    call proc_free_slot
    mov rsi, msg_rr_killed
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.not_found:
    mov rsi, msg_rr_nofile
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

.proc_full:
    mov rsi, msg_rr_toomany
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ============================================================
;  cmd_prs: process status / kill command
;  Usage:
;    prs                  - list processes
;    prs kill <id>        - kill process by PID
;    prs kill rushrun     - kill the rushrun process
; ============================================================
cmd_prs:
    ; Check if arg1 is "kill"
    mov rsi, arg1_buf
    mov rdi, str_kill
    call str_eq
    cmp al, 1
    je .prs_kill

    ; No subcommand - show process info
    call prs_show
    ret

.prs_kill:
    ; Check if arg2 is "rushrun"
    mov rsi, arg2_buf
    mov rdi, str_rushrun
    call str_eq
    cmp al, 1
    je .kill_rushrun

    ; Check if arg2 is a number (PID)
    mov rsi, arg2_buf
    call parse_int
    cmp cl, 1
    jne .bad_kill_arg

    ; Search for process with this PID
    mov r12, rax                    ; target PID
    xor r13, r13                    ; slot index
.prs_find_pid:
    cmp r13, MAX_PROCESSES
    jae .kill_not_found
    cmp byte [proc_state + r13], 0
    je .kill_next
    movzx rax, word [proc_id + r13*2]
    cmp rax, r12
    je .kill_found_pid
.kill_next:
    inc r13
    jmp .prs_find_pid
.kill_found_pid:
    mov byte [kill_flag], 1
    mov rsi, msg_prs_killed
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rax, r12
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

.kill_rushrun:
    ; Find process named "runrush"
    xor r13, r13
.prs_find_rushrun:
    cmp r13, MAX_PROCESSES
    jae .kill_not_found
    cmp byte [proc_state + r13], 0
    je .rushrun_next
    mov rax, r13
    imul rax, 32
    lea rdi, [proc_name + rax]
    mov rsi, str_runrush
    call str_eq
    cmp al, 1
    je .kill_found_rushrun
.rushrun_next:
    inc r13
    jmp .prs_find_rushrun
.kill_found_rushrun:
    mov byte [kill_flag], 1
    mov rsi, msg_prs_killed
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, str_rushrun
    call print_string
    mov rsi, newline_str
    call print_string
    ret

.kill_not_found:
    mov rsi, msg_prs_noid
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.bad_kill_arg:
    mov rsi, msg_prs_noid
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; prs_show: display process table
prs_show:
    mov rsi, msg_prs_header
    mov al, ATTR_NORMAL
    call print_string_attr
    xor r13, r13
.prs_show_loop:
    cmp r13, MAX_PROCESSES
    jae .prs_show_done
    cmp byte [proc_state + r13], 0
    je .prs_show_next
    movzx rax, word [proc_id + r13*2]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, prs_spaces
    call print_string
    mov rax, r13
    imul rax, 32
    lea rsi, [proc_name + rax]
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, newline_str
    call print_string
.prs_show_next:
    inc r13
    jmp .prs_show_loop
.prs_show_done:
    ret

; ============================================================
;  cmd_auth: elevation system (like sudo).
;  Usage: auth <command> [args...]
;  Sets auth_valid, shifts arguments (arg1->cmd, arg2->arg1, etc.),
;  then dispatches the command with elevated privileges.
;  auth_valid is reset after the command returns.
; ============================================================
cmd_auth:
    cmp byte [arg1_buf], 0
    jne .have_cmd
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_cmd:
    ; Set auth flag
    mov byte [auth_valid], 1

    ; Print auth message
    mov rsi, msg_auth_granted
    mov al, ATTR_NORMAL
    call print_string_attr

    ; Shift arguments: arg1 -> cmd_buf, arg2 -> arg1_buf, etc.
    mov rsi, arg1_buf
    mov rdi, cmd_buf
    call str_copy
    mov rsi, arg2_buf
    mov rdi, arg1_buf
    call str_copy
    mov rsi, arg3_buf
    mov rdi, arg2_buf
    call str_copy
    mov rsi, arg4_buf
    mov rdi, arg3_buf
    call str_copy
    mov byte [arg4_buf], 0

    ; Dispatch the shifted command
    call dispatch

    ; Reset auth flag
    mov byte [auth_valid], 0
    ret

; ============================================================
;  cmd_vars: list all variables, or clear all with auth.
;  Usage:
;    vars              - list all variables
;    vars rmv all      - clear all variables (requires auth)
; ============================================================
cmd_vars:
    ; Check if arg1 is "rmv"
    mov rsi, arg1_buf
    mov rdi, str_rmv
    call str_eq
    cmp al, 1
    jne .vars_list

    ; Check if arg2 is "all"
    mov rsi, arg2_buf
    mov rdi, str_rmv_all
    call str_eq
    cmp al, 1
    jne .vars_list

    ; Check auth
    cmp byte [auth_valid], 0
    je .vars_no_auth

    ; Clear all variables
    mov byte [auth_valid], 0
    call vars_clear_all
    mov rsi, msg_vars_cleared
    mov al, ATTR_NORMAL
    call print_string_attr
    ret

.vars_no_auth:
    mov rsi, msg_auth_required
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.vars_list:
    call vars_list
    ret

; vars_list: iterate through variable table and print each variable
vars_list:
    push rbx
    push rcx
    push rdi
    push rsi

    mov rsi, msg_vars_header
    mov al, ATTR_NORMAL
    call print_string_attr

    xor rcx, rcx                    ; variable index
.vl_loop:
    cmp rcx, MAX_VARS
    jae .vl_done
    cmp byte [var_used + rcx], 0
    je .vl_next
    ; Print variable name
    mov rdi, rcx
    imul rdi, VAR_NAME_LEN
    lea rsi, [var_name + rdi]
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, msg_vars_sep
    call print_string
    ; Print variable value
    mov rax, [var_value + rcx*8]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rsi, newline_str
    call print_string
.vl_next:
    inc rcx
    jmp .vl_loop
.vl_done:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; vars_clear_all: clear all variables in the table
vars_clear_all:
    push rax
    push rcx
    push rdi
    push r8
    xor r8, r8                    ; r8 = loop index (separate from rcx)
.vca_loop:
    cmp r8, MAX_VARS
    jae .vca_done
    mov byte [var_used + r8], 0
    mov qword [var_value + r8*8], 0
    mov rdi, r8
    imul rdi, VAR_NAME_LEN
    lea rdi, [var_name + rdi]
    mov rcx, VAR_NAME_LEN
    xor al, al
    rep stosb
    inc r8
    jmp .vca_loop
.vca_done:
    pop r8
    pop rdi
    pop rcx
    pop rax
    ret
; ============================================================
fs_init:
    mov rdi, node_type
    mov rcx, MAX_NODES
    xor al, al
    rep stosb
    mov byte [node_type], 1          ; root: folder
    mov word [node_parent], 0xFFFF
    lea rdi, [node_name]
    mov rsi, str_home_name
    call str_copy
    mov qword [cur_dir], 0
    ; a fresh filesystem has nothing mounted
    mov rdi, mount_used
    mov rcx, MAX_MOUNTS
    xor al, al
    rep stosb
    mov rdi, mount_device
    mov rcx, MAX_MOUNTS
    xor al, al
    rep stosb
    mov rdi, mount_label
    mov rcx, MAX_MOUNTS*32
    xor al, al
    rep stosb
    ret

; fs_find_child: rax=parent_idx, rsi=name, r10=type filter (-1 = any)
; returns rax = index or -1
fs_find_child:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push rsi
    mov r8, rax                 ; parent to match
    xor r9, r9                  ; loop index
.loop:
    cmp r9, MAX_NODES
    jae .notfound
    cmp byte [node_type + r9], 0
    je .next
    cmp r10, -1
    je .typeok
    movzx rax, byte [node_type + r9]
    cmp rax, r10
    jne .next
.typeok:
    movzx rax, word [node_parent + r9*2]
    cmp rax, r8
    jne .next
    ; compare name
    pop rsi
    push rsi
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    xchg rsi, rdi
    call str_eq
    cmp al, 1
    je .found
.next:
    inc r9
    jmp .loop
.found:
    mov rax, r9
    jmp .out
.notfound:
    mov rax, -1
.out:
    pop rsi
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; fs_create_node: rax=parent_idx, rsi=name, r10=type
; returns rax = new index or -1 if full
fs_create_node:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push rsi
    mov byte [fs_name_too_long], 0
    mov r8, rax                 ; save parent idx before str_len clobbers rax
    ; reject names that won't fit in the fixed NAME_LEN slot (leaving room
    ; for the null terminator) instead of silently overflowing into the
    ; next node's name/type/parent fields
    call str_len
    cmp rax, NAME_LEN
    jae .name_too_long
    ; Nodes are partitioned into fixed VOL_NODES-sized slices, one per
    ; volume (OS volume first, then each mount slot). Search only within
    ; the parent's own slice - never across into another volume's range,
    ; or a node created here could get an index outside the volume it
    ; actually belongs to, and that volume's vol_write would never
    ; include it (silently losing it on the next sync/reboot).
    mov rax, r8
    xor rdx, rdx
    mov rcx, VOL_NODES
    div rcx                     ; rax = volume index = parent_idx / VOL_NODES
    imul rax, VOL_NODES         ; rax = first node index of that volume
    mov r9, rax
    mov rbx, r9
    add rbx, VOL_NODES          ; rbx = one-past-last node index of that volume
.loop:
    cmp r9, rbx
    jae .full
    cmp byte [node_type + r9], 0
    je .free
    inc r9
    jmp .loop
.free:
    mov byte [node_type + r9], r10b
    mov [node_parent + r9*2], r8w
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    pop rsi
    push rsi
    call str_copy
    mov rax, r9
    jmp .out
.name_too_long:
    mov byte [fs_name_too_long], 1
    mov rax, -1
    jmp .out
.full:
    mov rax, -1
.out:
    pop rsi
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; fs_delete_node: rax = node index. Frees just that one node (does not
; touch children - use fs_delete_tree if the node might be a folder with
; contents).
fs_delete_node:
    push rax
    push rdi
    push rcx
    push r9
    mov r9, rax
    mov byte [node_type + r9], 0
    mov word [node_parent + r9*2], 0
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    mov rcx, NAME_LEN
    xor al, al
    rep stosb
    mov rdi, r9
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    mov rcx, CONTENT_LEN
    xor al, al
    rep stosb
    pop r9
    pop rcx
    pop rdi
    pop rax
    ret

; fs_delete_tree: rax = node index. Recursively frees the node and, if
; it's a folder, everything inside it too.
fs_delete_tree:
    push rax
    push r8
    push r13
    mov r8, rax
    cmp byte [node_type + r8], 1
    jne .leaf
    xor r13, r13
.loop:
    cmp r13, MAX_NODES
    jae .leaf
    cmp byte [node_type + r13], 0
    je .next
    movzx rax, word [node_parent + r13*2]
    cmp rax, r8
    jne .next
    mov rax, r13
    call fs_delete_tree
.next:
    inc r13
    jmp .loop
.leaf:
    mov rax, r8
    call fs_delete_node
    pop r13
    pop r8
    pop rax
    ret

; fs_copy_node: rax=src node idx, r10=dest parent idx, rsi=dest name.
; Recursively copies a file, or a folder and everything inside it, to a
; new parent under a new name. Returns rax = new node idx, or -1 if that
; name is already taken at dest or the filesystem is full.
fs_copy_node:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r11
    push r12
    push r13
    mov r8, rax                  ; src idx
    mov r9, r10                  ; dest parent idx

    mov rax, r9
    mov r10, -1
    call fs_find_child            ; rsi (dest name) preserved by callee
    cmp rax, -1
    jne .taken

    movzx r11, byte [node_type + r8]
    mov rax, r9
    mov r10, r11
    call fs_create_node            ; rsi preserved
    cmp rax, -1
    je .full
    mov r12, rax

    cmp r11, 2
    jne .isfolder
    mov rdi, r12
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    mov rax, r8
    imul rax, CONTENT_LEN
    lea rsi, [node_content + rax]
    call str_copy
    jmp .done
.isfolder:
    xor r13, r13
.childloop:
    cmp r13, MAX_NODES
    jae .done
    cmp byte [node_type + r13], 0
    je .childnext
    movzx rax, word [node_parent + r13*2]
    cmp rax, r8
    jne .childnext
    mov rax, r13
    mov r10, r12
    mov rdi, r13
    imul rdi, NAME_LEN
    lea rsi, [node_name + rdi]
    call fs_copy_node
.childnext:
    inc r13
    jmp .childloop
.done:
    mov rax, r12
    jmp .out
.taken:
    mov rax, -1
    jmp .out
.full:
    mov rax, -1
.out:
    pop r13
    pop r12
    pop r11
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; fs_resolve_path: walks a '/'-separated path, one folder at a time,
; using the same node_parent/fs_find_child machinery every other command
; already relies on. Understands "/" (root), "." and ".." (like cf always
; has), collapses repeated or trailing slashes, and treats a leading
; "/home" as an alias for root (same alias cf used to special-case).
;
; in:  rax = starting dir index (normally [cur_dir])
;      rsi = path string, e.g. "docs/notes.txt", "..", "/home/docs", "notes.txt"
;      rdi = 0            -> whole-path mode: every component (including
;                             the last) is resolved as a folder. Used by cf.
;            leaf_buf ptr -> split mode: all components except the last
;                             are resolved as folders; the last component
;                             is copied verbatim into [leaf_buf] instead of
;                             being looked up. Used by anything that names
;                             a file/folder to act on (view, del, rname,
;                             cpy, mov, mkf, mkfl).
; out: rax = resolved dir index, or -1 if a folder component along the way
;            doesn't exist (leaf_buf, if any, is left untouched on failure)
; ============================================================
fs_resolve_path:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r12
    push r13
    push r14
    mov r12, rdi                ; leaf buf ptr, or 0 for whole-path mode
    mov r13, rax                ; running "current dir" as we walk
    mov r14, rsi                ; path cursor

    cmp byte [r14], '/'
    jne .parse_loop
    mov r13, 0                  ; absolute path -> start from root

.parse_loop:
.skip_seps:
    cmp byte [r14], '/'
    jne .extract_check
    inc r14
    jmp .skip_seps
.extract_check:
    cmp byte [r14], 0
    je .success                 ; nothing left to parse - done
    mov rdi, path_comp_buf
.copy_loop:
    mov al, [r14]
    cmp al, 0
    je .comp_done
    cmp al, '/'
    je .comp_done
    mov [rdi], al
    inc rdi
    inc r14
    jmp .copy_loop
.comp_done:
    mov byte [rdi], 0
    ; peek past any trailing slashes to see whether anything real remains
.skip_seps2:
    cmp byte [r14], '/'
    jne .check_last
    inc r14
    jmp .skip_seps2
.check_last:
    cmp byte [r14], 0
    jne .resolve_component      ; more path remains -> this is a folder step
    cmp r12, 0
    je .resolve_component        ; whole-path mode: resolve last comp too
    ; split mode, and this was the last component -> it's the leaf name
    push rsi
    mov rsi, path_comp_buf
    mov rdi, r12
    call str_copy
    pop rsi
    jmp .success
.resolve_component:
    mov rsi, path_comp_buf
    mov rdi, str_updir
    call str_eq
    cmp al, 1
    je .do_updir
    mov rsi, path_comp_buf
    mov rdi, str_dot
    call str_eq
    cmp al, 1
    je .after_resolve            ; "." is a no-op
    ; "/home" alias: while sitting at root, a literal "home" component
    ; is a no-op too (matches the old single-token "/home" special case)
    cmp r13, 0
    jne .lookup_child
    mov rsi, path_comp_buf
    mov rdi, str_home_name
    call str_eq
    cmp al, 1
    je .after_resolve
.lookup_child:
    mov rax, r13
    mov rsi, path_comp_buf
    mov r10, 1                   ; must be a folder to descend into
    call fs_find_child
    cmp rax, -1
    je .notfound
    mov r13, rax
    jmp .after_resolve
.do_updir:
    cmp r13, 0
    je .after_resolve            ; already at root, no-op
    movzx rbx, word [node_parent + r13*2]
    cmp bx, 0xFFFF
    je .after_resolve
    mov r13, rbx
.after_resolve:
    cmp byte [r14], 0
    je .success
    jmp .parse_loop
.notfound:
    mov rax, -1
    jmp .out
.success:
    mov rax, r13
.out:
    pop r14
    pop r13
    pop r12
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
;  DISK PERSISTENCE  (ATA PIO driver, primary bus, LBA28, polling)
; ============================================================
; Ports (primary ATA channel):
;   0x1F0 data, 0x1F1 features/error, 0x1F2 sector count,
;   0x1F3/4/5 LBA low/mid/high, 0x1F6 drive/head, 0x1F7 status/command.
; No IRQs are used anywhere in this kernel, so these routines just
; poll BSY/DRQ in the status register, matching the polled keyboard
; driver's style.

; ata_wait_bsy: block until BSY (bit 7) clears, or give up after a timeout.
; returns CF=0 on success, CF=1 on timeout (no device responding at all,
; e.g. real hardware with no legacy IDE controller / booting off USB).
ATA_TIMEOUT equ 0x400000
; ata_wait_bsy: block until BSY (bit 7) clears, or give up after a timeout.
; returns CF=0 on success, CF=1 on timeout (no device responding at all,
; e.g. real hardware with no legacy IDE controller / booting off USB).
ATA_TIMEOUT equ 0x400000
ata_wait_bsy:
    push rax
    push rdx
    push rcx
    mov rcx, ATA_TIMEOUT
    movzx edx, word [ata_port_base]
    add dx, 7
.wait:
    in al, dx
    test al, 0x80
    jz .ok
    loop .wait
    pop rcx
    pop rdx
    pop rax
    stc
    ret
.ok:
    pop rcx
    pop rdx
    pop rax
    clc
    ret

; ata_wait_drq: block until DRQ (bit 3) sets, or time out (see ata_wait_bsy)
ata_wait_drq:
    push rax
    push rdx
    push rcx
    mov rcx, ATA_TIMEOUT
    movzx edx, word [ata_port_base]
    add dx, 7
.wait:
    in al, dx
    test al, 0x08
    jnz .ok
    loop .wait
    pop rcx
    pop rdx
    pop rax
    stc
    ret
.ok:
    pop rcx
    pop rdx
    pop rax
    clc
    ret

; ata_select_device: al = device id (0=primary master, 1=primary slave,
; 2=secondary master, 3=secondary slave). Picks the I/O port base and the
; drive-select bit so every ATA routine below talks to the right drive.
ata_select_device:
    push rax
    and al, 3
    cmp al, 2
    jb .primary
    mov word [ata_port_base], 0x170
    sub al, 2
    jmp .drive
.primary:
    mov word [ata_port_base], 0x1F0
.drive:
    test al, 1
    jnz .slave
    mov byte [ata_drive_sel], 0xE0
    jmp .done
.slave:
    mov byte [ata_drive_sel], 0xF0
.done:
    pop rax
    ret

; ata_read_sector: rax = LBA (28-bit), rdi = 512-byte destination buffer
; returns CF=0 on success, CF=1 on failure/timeout (buffer left untouched
; or partially written - caller should not trust it on failure).
ata_read_sector:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    mov rbx, rax                 ; keep LBA
    call ata_wait_bsy
    jc .fail
    movzx edx, word [ata_port_base]
    add dx, 6
    mov rax, rbx
    shr rax, 24
    and al, 0x0F
    or al, [ata_drive_sel]       ; LBA mode + master/slave bit
    out dx, al
    movzx edx, word [ata_port_base]
    add dx, 2
    mov al, 1                    ; sector count = 1
    out dx, al
    movzx edx, word [ata_port_base]
    add dx, 3
    mov al, bl
    out dx, al                   ; LBA[0:7]
    movzx edx, word [ata_port_base]
    add dx, 4
    mov rax, rbx
    shr rax, 8
    out dx, al                   ; LBA[8:15]
    movzx edx, word [ata_port_base]
    add dx, 5
    mov rax, rbx
    shr rax, 16
    out dx, al                   ; LBA[16:23]
    movzx edx, word [ata_port_base]
    add dx, 7
    mov al, 0x20                 ; READ SECTORS (with retry)
    out dx, al
    call ata_wait_bsy
    jc .fail
    call ata_wait_drq
    jc .fail
    movzx edx, word [ata_port_base]
    mov rcx, 256                 ; 256 words = 512 bytes
.readloop:
    in ax, dx
    mov [rdi], ax
    add rdi, 2
    loop .readloop
    clc
    jmp .done
.fail:
    stc
.done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ata_write_sector: rax = LBA (28-bit), rsi = 512-byte source buffer
; returns CF=0 on success, CF=1 on failure/timeout.
ata_write_sector:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov rbx, rax
    call ata_wait_bsy
    jc .fail
    movzx edx, word [ata_port_base]
    add dx, 6
    mov rax, rbx
    shr rax, 24
    and al, 0x0F
    or al, [ata_drive_sel]
    out dx, al
    movzx edx, word [ata_port_base]
    add dx, 2
    mov al, 1
    out dx, al
    movzx edx, word [ata_port_base]
    add dx, 3
    mov al, bl
    out dx, al
    movzx edx, word [ata_port_base]
    add dx, 4
    mov rax, rbx
    shr rax, 8
    out dx, al
    movzx edx, word [ata_port_base]
    add dx, 5
    mov rax, rbx
    shr rax, 16
    out dx, al
    movzx edx, word [ata_port_base]
    add dx, 7
    mov al, 0x30                 ; WRITE SECTORS (with retry)
    out dx, al
    call ata_wait_bsy
    jc .fail
    call ata_wait_drq
    jc .fail
    movzx edx, word [ata_port_base]
    mov rcx, 256
.writeloop:
    mov ax, [rsi]
    out dx, ax
    add rsi, 2
    loop .writeloop
    call ata_wait_bsy
    jc .fail
    movzx edx, word [ata_port_base]
    add dx, 7
    mov al, 0xE7                 ; CACHE FLUSH so it actually hits the image
    out dx, al
    call ata_wait_bsy
    jc .fail
    clc
    jmp .done
.fail:
    stc
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------
;  disk_*: dispatcher in front of the two disk drivers below (legacy ATA
;  PIO above, AHCI further down). Every caller in this file - vol_read,
;  vol_write, dscan, fmt, mount - goes through these three routines with
;  al = device id, exactly like it always called ata_select_device /
;  ata_read_sector / ata_write_sector directly before. Ids 0-3 still mean
;  what they always meant (primary/secondary x master/slave); ids 4 and up
;  mean an AHCI port slot claimed by ahci_init at boot.
; ------------------------------------------------------------------

; disk_select_device: al = device id (0..TOTAL_DEVICES-1).
disk_select_device:
    push rax
    cmp al, 4
    jb .use_ata
    mov byte [disk_use_ahci], 1
    sub al, 4
    mov byte [ahci_cur_slot], al
    jmp .done
.use_ata:
    mov byte [disk_use_ahci], 0
    call ata_select_device
.done:
    pop rax
    ret

; disk_read_sector: rax=LBA, rdi=dest buffer. Same in/out contract as
; ata_read_sector - tail-jumps into whichever driver disk_select_device
; picked, so its own CF/register contract passes straight through.
disk_read_sector:
    cmp byte [disk_use_ahci], 0
    je ata_read_sector
    jmp ahci_read_sector

; disk_write_sector: rax=LBA, rsi=source buffer. Same contract as above.
disk_write_sector:
    cmp byte [disk_use_ahci], 0
    je ata_write_sector
    jmp ahci_write_sector

; ------------------------------------------------------------------
;  PCI configuration space access (legacy 0xCF8/0xCFC I/O ports). Used
;  only to find and configure the AHCI controller below.
; ------------------------------------------------------------------
PCI_CFG_ADDR equ 0x0CF8
PCI_CFG_DATA equ 0x0CFC

; pci_read32: ebx=bus, ecx=device(0-31), edx=function(0-7), r8b=offset
; (byte, dword-aligned - low 2 bits ignored). Returns eax = the 32-bit
; config space value at that offset. Preserves ebx/ecx/edx; clobbers r9.
pci_read32:
    push rbx
    push rcx
    push rdx
    push r9
    xor r9d, r9d
    mov r9b, bl
    shl r9d, 16                  ; bus -> bits 23:16
    mov eax, ecx
    and eax, 0x1F
    shl eax, 11                  ; device -> bits 15:11
    or r9d, eax
    mov eax, edx
    and eax, 0x07
    shl eax, 8                   ; function -> bits 10:8
    or r9d, eax
    mov eax, r8d
    and eax, 0xFC                ; register -> bits 7:2
    or r9d, eax
    or r9d, 0x80000000           ; enable bit
    mov eax, r9d
    mov dx, PCI_CFG_ADDR
    out dx, eax
    mov dx, PCI_CFG_DATA
    in eax, dx
    pop r9
    pop rdx
    pop rcx
    pop rbx
    ret

; pci_write32: ebx=bus, ecx=device, edx=function, r8b=offset, r10d=value.
; Preserves ebx/ecx/edx; clobbers r9.
pci_write32:
    push rax
    push rbx
    push rcx
    push rdx
    push r9
    xor r9d, r9d
    mov r9b, bl
    shl r9d, 16
    mov eax, ecx
    and eax, 0x1F
    shl eax, 11
    or r9d, eax
    mov eax, edx
    and eax, 0x07
    shl eax, 8
    or r9d, eax
    mov eax, r8d
    and eax, 0xFC
    or r9d, eax
    or r9d, 0x80000000
    mov eax, r9d
    mov dx, PCI_CFG_ADDR
    out dx, eax
    mov eax, r10d
    mov dx, PCI_CFG_DATA
    out dx, eax
    pop r9
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; pci_find_ahci: brute-force scan of PCI bus 0 only (per-device, and every
; function of a multi-function device). This covers the common case - the
; chipset's root complex, where AHCI controllers normally live, and is
; where QEMU/Bochs/VirtualBox and most real desktop chipsets put theirs -
; but doesn't walk PCI-to-PCI bridges out to other buses, which unusual
; multi-bus hardware could need. Looks for class 0x01 (mass storage),
; subclass 0x06 (SATA), regardless of programming interface.
; On success: CF=0, [ahci_pci_bus/dev/func] set. On failure: CF=1.
pci_find_ahci:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    xor ebx, ebx                 ; bus 0 only
    xor ecx, ecx                 ; device 0..31
.dev_loop:
    cmp ecx, 32
    jae .not_found
    xor edx, edx                 ; try function 0 first
    xor r8, r8
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .next_dev                 ; nothing in this slot
    mov r8b, 0x0C                ; header type lives at offset 0x0C, byte 2
    call pci_read32
    shr eax, 16
    and eax, 0xFF
    mov [pci_scratch_hdrtype], al
    mov r9d, 1                   ; how many functions to check
    test byte [pci_scratch_hdrtype], 0x80
    jz .func_loop_start
    mov r9d, 8                   ; multi-function device - check them all
.func_loop_start:
    xor edx, edx
.func_loop:
    cmp edx, r9d
    jae .next_dev
    xor r8, r8
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .func_next
    mov r8b, 0x08                ; class code dword
    call pci_read32
    mov r10d, eax
    shr r10d, 24                 ; class
    cmp r10b, 0x01
    jne .func_next
    mov r10d, eax
    shr r10d, 16
    and r10d, 0xFF                ; subclass
    cmp r10b, 0x06
    jne .func_next
    mov [ahci_pci_bus], bl
    mov [ahci_pci_dev], cl
    mov [ahci_pci_func], dl
    jmp .found
.func_next:
    inc edx
    jmp .func_loop
.next_dev:
    inc ecx
    jmp .dev_loop
.not_found:
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
.found:
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret

; ------------------------------------------------------------------
;  AHCI (SATA) driver. Talks to the HBA over MMIO (its ABAR, found via
;  PCI BAR5) instead of legacy IDE ports - a different I/O model from the
;  ata_* driver above, but the disk is identity-mapped memory either way
;  once ahci_mark_uncached has run, so it's read/written with plain
;  mov/or/and just like any other buffer in this file. No interrupts are
;  used here either, matching the polled style of the rest of the OS:
;  commands are issued and then polled for completion on PxCI.
; ------------------------------------------------------------------
PCI_CMD_OFFSET  equ 0x04
PCI_BAR5_OFFSET equ 0x24
AHCI_TIMEOUT    equ 0x400000

; ahci_mark_uncached: edi = a physical address inside the 2MB page to mark
; uncached (sets PCD, bit4) in the identity-map PDs built by
; expand_identity_map (4 contiguous page directories at 0x3000..0x6FFF,
; 512 entries each, 2MB pages). Without this, polling an HBA register
; through a cacheable mapping could read back a stale value instead of
; what the device just wrote - the ABAR sits in a dedicated MMIO range
; that nothing else in this kernel uses, so marking its whole 2MB page
; uncached doesn't affect anything else.
ahci_mark_uncached:
    push rax
    push rcx
    mov eax, edi
    shr eax, 21                  ; which 2MB page, 0..2047, across all 4 PDs
    mov ecx, eax
    shl ecx, 3                   ; * 8 (each PD entry is a qword)
    add ecx, 0x3000              ; PD0 starts at 0x3000 (see expand_identity_map)
    or qword [rcx], 0x10         ; set PCD
    mov rax, cr3
    mov cr3, rax                 ; flush stale TLB entries
    pop rcx
    pop rax
    ret

; ahci_port_init: rbx = this port's register base (ABAR + 0x100 +
; port*0x80), r14d = slot index (0..AHCI_MAX_PORTS-1, picks which static
; command-list/FIS buffer this port uses). Stops the port if it was
; already running, points it at our buffers, then starts it.
ahci_port_init:
    push rax
    push rcx
    push rdi

    mov eax, [rbx + 0x18]        ; PxCMD
    and eax, 0xFFFFFFFE          ; clear ST
    mov [rbx + 0x18], eax
    and eax, 0xFFFFFFEF          ; clear FRE
    mov [rbx + 0x18], eax

    ; wait for FR/CR to clear, but don't spin forever - some real
    ; controllers (unlike QEMU's virtual AHCI) can take a while here, or in
    ; rare cases never quiesce from this code's point of view. Bail out
    ; and skip this port rather than hanging the whole boot if it doesn't
    ; clear within AHCI_TIMEOUT iterations.
    mov rcx, AHCI_TIMEOUT
.wait_stop:
    mov eax, [rbx + 0x18]
    test eax, 0x8000             ; FR - FIS receive still running?
    jnz .wait_stop_dec
    mov eax, [rbx + 0x18]
    test eax, 0x4000             ; CR - command list still running?
    jz .stopped
.wait_stop_dec:
    loop .wait_stop
    jmp .skip_port               ; timed out - leave this port unclaimed
.stopped:

    mov eax, r14d
    imul eax, 1024
    lea rdi, [ahci_clb + rax]    ; this slot's 1KB-aligned command list
    mov [rbx + 0x00], edi        ; PxCLB
    mov dword [rbx + 0x04], 0    ; PxCLBU (we're always <4GB here)

    mov eax, r14d
    imul eax, 256
    lea rdi, [ahci_fis + rax]    ; this slot's 256B-aligned FIS receive area
    mov [rbx + 0x08], edi        ; PxFB
    mov dword [rbx + 0x0C], 0    ; PxFBU

    mov dword [rbx + 0x30], 0xFFFFFFFF   ; PxSERR - clear (write-1-to-clear)

    mov eax, [rbx + 0x18]
    or eax, 0x10                 ; FRE
    mov [rbx + 0x18], eax
    mov eax, [rbx + 0x18]
    or eax, 0x01                 ; ST
    mov [rbx + 0x18], eax

.skip_port:
    pop rdi
    pop rcx
    pop rax
    ret

; ahci_init: called once at boot. Finds a PCI AHCI controller if one's
; present, enables it, and brings up to AHCI_MAX_PORTS of its ports (that
; have an actual SATA disk attached) as extra disk device slots, ids
; 4..4+AHCI_MAX_PORTS-1. Completely inert if there's no AHCI controller:
; [ahci_port_count] stays 0 and the OS behaves exactly as it always did.
ahci_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r10
    push r12
    push r13
    push r14

    call pci_find_ahci
    jc .done

    ; Memory Space (bit1) + Bus Master (bit2) in the PCI command register -
    ; usually already on if firmware set the machine up, but make sure.
    movzx ebx, byte [ahci_pci_bus]
    movzx ecx, byte [ahci_pci_dev]
    movzx edx, byte [ahci_pci_func]
    mov r8b, PCI_CMD_OFFSET
    call pci_read32
    or eax, 0x0006
    mov r10d, eax
    movzx ebx, byte [ahci_pci_bus]
    movzx ecx, byte [ahci_pci_dev]
    movzx edx, byte [ahci_pci_func]
    mov r8b, PCI_CMD_OFFSET
    call pci_write32

    ; BAR5 = ABAR, the AHCI MMIO register window
    movzx ebx, byte [ahci_pci_bus]
    movzx ecx, byte [ahci_pci_dev]
    movzx edx, byte [ahci_pci_func]
    mov r8b, PCI_BAR5_OFFSET
    call pci_read32
    and eax, 0xFFFFFFF0           ; drop the low flag bits, keep the base
    mov [ahci_abar], eax
    mov edi, eax
    call ahci_mark_uncached

    mov ebx, [ahci_abar]          ; 32-bit load zero-extends into rbx - ahci_abar
                                   ; is only a dd, so a 64-bit load here would pull
                                   ; in the following ahci_ports_impl dword too
    mov eax, [rbx + 0x04]         ; GHC
    or eax, 0x80000000            ; AE - AHCI Enable
    mov [rbx + 0x04], eax

    mov eax, [rbx + 0x0C]         ; PI - ports implemented bitmap
    mov [ahci_ports_impl], eax

    xor r12d, r12d                ; physical port index, 0..31
    xor r13d, r13d                ; usable ports claimed so far
.port_scan:
    cmp r12d, 32
    jae .scan_done
    cmp r13d, AHCI_MAX_PORTS
    jae .scan_done
    mov eax, 1
    mov ecx, r12d
    shl eax, cl
    test eax, [ahci_ports_impl]
    jz .port_next                 ; this port number isn't implemented
    mov ebx, [ahci_abar]          ; 32-bit load, see note above - this is the site
                                   ; that was faulting once ahci_ports_impl went nonzero
    add rbx, 0x100
    mov eax, r12d
    shl eax, 7                    ; port registers are 0x80 bytes apart
    add rbx, rax
    mov eax, [rbx + 0x28]         ; PxSSTS
    and eax, 0x0F                 ; DET field
    cmp eax, 0x03                 ; 3 = device present, comms established
    jne .port_next
    mov eax, [rbx + 0x24]         ; PxSIG
    cmp eax, 0xEB140101            ; ATAPI signature - skip optical drives
    je .port_next
    mov eax, r13d
    mov [ahci_port_num + rax*4], r12d   ; remember the real port number
    mov rax, r13
    imul rax, 8
    mov [ahci_port_base + rax], rbx     ; remember its register base
    mov r14d, r13d
    call ahci_port_init
    inc r13d
.port_next:
    inc r12d
    jmp .port_scan
.scan_done:
    mov [ahci_port_count], r13b
.done:
    pop r14
    pop r13
    pop r12
    pop r10
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ahci_read_sector / ahci_write_sector: same calling convention as their
; ata_* counterparts (rax=LBA, rdi=dest / rsi=src, CF=0/1 on return), for
; whichever port [ahci_cur_slot] currently names. They just set which ATA
; command to send and which direction the data goes, then share the actual
; command-submission logic in ahci_rw_common below.
ahci_read_sector:
    mov byte [ahci_op_cmd], 0x25    ; READ DMA EXT
    mov byte [ahci_op_write], 0
    jmp ahci_rw_common

ahci_write_sector:
    mov byte [ahci_op_cmd], 0x35    ; WRITE DMA EXT
    mov byte [ahci_op_write], 1
    mov rdi, rsi                    ; unify on rdi as "the buffer" below
    jmp ahci_rw_common

; ahci_rw_common: rax=LBA, rdi=buffer, using [ahci_op_cmd]/[ahci_op_write]
; set by the caller above. Builds one command (command-list entry 0, its
; command table, and a Register H2D FIS) for a single 512-byte sector
; transfer, issues it, and polls PxCI until it clears (or times out).
; Returns CF=0 on success, CF=1 on failure/timeout.
ahci_rw_common:
    push rax
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

    mov r12, rax                  ; r12 = LBA
    mov r13, rdi                  ; r13 = buffer pointer

    movzx r14d, byte [ahci_cur_slot]
    mov rax, r14
    imul rax, 8
    mov r15, [ahci_port_base + rax]   ; r15 = this port's register base

    mov rax, r14
    imul rax, 1024
    lea r8, [ahci_clb + rax]      ; r8 = this port's command list (entry 0)

    xor eax, eax
    mov al, 5                     ; CFL = 5 DWORDS (20-byte Reg H2D FIS)
    cmp byte [ahci_op_write], 0
    je .no_w
    or eax, 0x40                  ; W bit - this is a write
.no_w:
    or eax, (1 << 16)             ; PRDTL = 1 (one PRDT entry)
    mov [r8], eax
    mov dword [r8 + 4], 0         ; PRDBC, cleared before each command

    mov rax, r14
    imul rax, 256
    lea r9, [ahci_cmdtbl + rax]   ; r9 = this port's command table
    mov [r8 + 8], r9d             ; CTBA
    mov dword [r8 + 12], 0        ; CTBAU

    ; zero the command table's FIS area (first 64 bytes) before building it
    push rdi
    mov rdi, r9
    xor eax, eax
    mov rcx, 8
    rep stosq
    pop rdi

    ; Register H2D FIS at command table offset 0
    mov byte [r9 + 0], 0x27       ; FIS_TYPE_REG_H2D
    mov byte [r9 + 1], 0x80       ; C = 1 (this FIS carries a Command)
    mov al, [ahci_op_cmd]
    mov byte [r9 + 2], al         ; Command register

    mov rax, r12
    mov byte [r9 + 4], al         ; LBA[7:0]
    mov rcx, rax
    shr rcx, 8
    mov byte [r9 + 5], cl         ; LBA[15:8]
    mov rcx, rax
    shr rcx, 16
    mov byte [r9 + 6], cl         ; LBA[23:16]
    mov byte [r9 + 7], 0x40       ; Device (LBA mode)
    mov rcx, rax
    shr rcx, 24
    mov byte [r9 + 8], cl         ; LBA[31:24]
    mov rcx, rax
    shr rcx, 32
    mov byte [r9 + 9], cl         ; LBA[39:32]
    mov rcx, rax
    shr rcx, 40
    mov byte [r9 + 10], cl        ; LBA[47:40]
    mov byte [r9 + 12], 1         ; sector count = 1

    ; PRDT entry, at command table offset 128: points straight at the
    ; caller's buffer (identity-mapped, so virtual == physical here).
    mov [r9 + 128], r13d          ; DBA
    mov dword [r9 + 132], 0       ; DBAU
    mov dword [r9 + 136], 0       ; reserved
    mov eax, 511                  ; byte count field is (N-1); no IRQ bit
    mov [r9 + 140], eax

    mov dword [r15 + 0x10], 0xFFFFFFFF   ; PxIS - clear stale status
    mov eax, 1
    mov [r15 + 0x38], eax                ; PxCI - issue command slot 0

    mov rcx, AHCI_TIMEOUT
.wait:
    mov eax, [r15 + 0x38]
    test eax, 1
    jz .check_err
    mov eax, [r15 + 0x20]         ; PxTFD - bail early on a device error
    test eax, 1
    jnz .fail
    loop .wait
    jmp .fail                     ; timed out
.check_err:
    mov eax, [r15 + 0x20]
    test eax, 1
    jnz .fail
    clc
    jmp .rw_done
.fail:
    stc
.rw_done:
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
    pop rax
    ret

; ------------------------------------------------------------------
;  SFFS v2 volume I/O
; ------------------------------------------------------------------

; vol_read: al = device id (0..3), rdi = base node index.
; Loads an SFFS volume from that device into the node table at
; [base .. base+VOL_NODES). For the OS volume (base 0) parents are
; copied verbatim; for mounted volumes, on-disk relative parent indices
; are remapped to the mount's global slice and the volume root becomes a
; child of the OS root (parent 0).
; returns rax = 0 on success, -1 on failure (absent device, bad magic,
; or an I/O error). Sets fs_disk_available=0 when the device never
; responded (i.e. there's no drive at that slot).
vol_read:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rdi                 ; r8 = base node index
    call disk_select_device
    mov rax, SUPER_LBA
    lea rdi, [fs_super_buf]
    call disk_read_sector
    jc .nodisk
    cmp byte [fs_super_buf+0], 'S'
    jne .fail
    cmp byte [fs_super_buf+1], 'F'
    jne .fail
    cmp byte [fs_super_buf+2], 'F'
    jne .fail
    cmp byte [fs_super_buf+3], 'S'
    jne .fail
    cmp byte [fs_super_buf+4], SFFS_VERSION
    jne .fail
    ; node_type
    mov rax, TYPE_LBA
    lea rdi, [node_type]
    add rdi, r8
    call disk_read_sector
    jc .fail
    ; node_parent -> scratch, then remap into place
    mov rax, PARENT_LBA
    lea rdi, [fs_parent_scratch]
    call disk_read_sector
    jc .fail
    mov r9, r8                   ; r9 = base + i (live table index)
    xor rcx, rcx                 ; rcx = i
.remap:
    cmp rcx, VOL_NODES
    jae .remap_done
    movzx rax, word [fs_parent_scratch + rcx*2]
    cmp r8, 0
    jne .remap_mount
    ; OS volume: parents are already global, copy verbatim
    mov [node_parent + r9*2], ax
    jmp .remap_next
.remap_mount:
    cmp rcx, 0
    je .remap_root
    cmp rax, 0xFFFF
    je .remap_root
    add rax, r8
    mov [node_parent + r9*2], ax
    jmp .remap_next
.remap_root:
    mov word [node_parent + r9*2], 0
.remap_next:
    inc rcx
    inc r9
    jmp .remap
.remap_done:
    ; node_name
    mov rax, NAME_LBA
    mov rcx, NAME_SECTORS
    lea rdi, [node_name]
    mov r9, r8
    imul r9, NAME_LEN
    add rdi, r9
.name_loop:
    push rax
    push rcx
    push rdi
    call disk_read_sector
    pop rdi
    pop rcx
    pop rax
    jc .fail
    add rdi, 512
    inc rax
    loop .name_loop
    ; node_content
    mov rax, CONTENT_LBA
    mov rcx, CONTENT_SECTORS
    lea rdi, [node_content]
    mov r9, r8
    imul r9, CONTENT_LEN
    add rdi, r9
.content_loop:
    push rax
    push rcx
    push rdi
    call disk_read_sector
    pop rdi
    pop rcx
    pop rax
    jc .fail
    add rdi, 512
    inc rax
    loop .content_loop
    xor rax, rax
    jmp .done
.nodisk:
    mov byte [fs_disk_available], 0
.fail:
    mov rax, -1
.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; vol_write: al = device id, rdi = base node index, rsi = label ptr.
; Writes the volume at [base .. base+VOL_NODES) plus a fresh superblock
; (magic + version + label) to that device. Parents are remapped back to
; on-disk relative indices (the volume root is stored as 0xFFFF).
; returns CF=0 on success, CF=1 on failure.
vol_write:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rdi                 ; r8 = base node index
    mov r9, rsi                 ; r9 = label ptr
    call disk_select_device
    ; --- build and write the superblock ---
    mov byte [fs_super_buf+0], 'S'
    mov byte [fs_super_buf+1], 'F'
    mov byte [fs_super_buf+2], 'F'
    mov byte [fs_super_buf+3], 'S'
    mov byte [fs_super_buf+4], SFFS_VERSION
    mov byte [fs_super_buf+5], 0
    mov byte [fs_super_buf+6], 0
    mov byte [fs_super_buf+7], 0
    mov rdi, fs_super_buf
    add rdi, SUPER_LABEL_OFF
    mov rcx, 32
    xor al, al
    rep stosb
    mov rsi, r9
    mov rdi, fs_super_buf
    add rdi, SUPER_LABEL_OFF
    xor rcx, rcx
.label_copy:
    cmp rcx, 31
    jae .label_done
    mov al, [rsi]
    test al, al
    jz .label_done
    mov [rdi], al
    inc rsi
    inc rdi
    inc rcx
    jmp .label_copy
.label_done:
    mov rax, SUPER_LBA
    lea rsi, [fs_super_buf]
    call disk_write_sector
    jc .fail
    ; --- node_type ---
    mov rax, TYPE_LBA
    lea rsi, [node_type]
    add rsi, r8
    call disk_write_sector
    jc .fail
    ; --- node_parent (remap to on-disk relative indices) ---
    xor rcx, rcx
.parent_loop:
    cmp rcx, VOL_NODES
    jae .parent_done
    cmp rcx, 0
    je .parent_root
    mov rax, r8
    add rax, rcx                 ; rax = global node index (base+i)
    shl rax, 1                   ; rax = byte offset into node_parent (word-sized)
    movzx rax, word [node_parent + rax]
    sub rax, r8
    mov [fs_parent_scratch + rcx*2], ax
    jmp .parent_next
.parent_root:
    mov word [fs_parent_scratch + rcx*2], 0xFFFF
.parent_next:
    inc rcx
    jmp .parent_loop
.parent_done:
    mov rax, PARENT_LBA
    lea rsi, [fs_parent_scratch]
    call disk_write_sector
    jc .fail
    ; --- node_name ---
    mov rax, NAME_LBA
    mov rcx, NAME_SECTORS
    lea rsi, [node_name]
    mov rdi, r8
    imul rdi, NAME_LEN
    add rsi, rdi
.name_loop:
    push rax
    push rcx
    push rsi
    call disk_write_sector
    pop rsi
    pop rcx
    pop rax
    jc .fail
    add rsi, 512
    inc rax
    loop .name_loop
    ; --- node_content ---
    mov rax, CONTENT_LBA
    mov rcx, CONTENT_SECTORS
    lea rsi, [node_content]
    mov rdi, r8
    imul rdi, CONTENT_LEN
    add rsi, rdi
.content_loop:
    push rax
    push rcx
    push rsi
    call disk_write_sector
    pop rsi
    pop rcx
    pop rax
    jc .fail
    add rsi, 512
    inc rax
    loop .content_loop
    clc
    jmp .done
.fail:
    stc
.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; fs_save: writes the OS volume (device 0, nodes 0..OS_NODES) then every
; mounted volume back to its own device. Returns CF=0 on success, CF=1 if
; the OS volume's disk isn't there/isn't responding. A mounted volume that
; fails to write is left mounted (best effort; sync still reports success).
fs_save:
    push rax
    push rbx
    push rsi
    push rdi
    push r13
    push r14
    xor r14b, r14b                ; r14b = 1 once anything has actually been saved
    cmp byte [fs_disk_available], 0
    je .skip_os_volume            ; no legacy-ATA OS disk this session - don't retry
                                   ; it, but still try any mounted AHCI volumes below
    ; OS volume: device 0, base 0, label = root node's name
    lea rsi, [node_name]
    xor rdi, rdi
    xor al, al
    call vol_write
    jc .disk_gone
    mov r14b, 1
.skip_os_volume:
    ; mounted volumes
    xor r13, r13
.mount_loop:
    cmp r13, MAX_MOUNTS
    jae .check_any
    cmp byte [mount_used + r13], 0
    je .mount_next
    movzx rax, byte [mount_device + r13]
    mov rdi, r13
    inc rdi
    imul rdi, VOL_NODES
    mov rbx, r13
    imul rbx, 32
    lea rsi, [mount_label + rbx]
    call vol_write
    jc .mount_next                ; a mounted volume failing to save is not fatal;
    mov r14b, 1                   ; keep it mounted, just don't count it as saved
.mount_next:
    inc r13
    jmp .mount_loop
.check_any:
    cmp r14b, 0
    je .fail                      ; nothing at all got saved - genuinely no disk
    pop r14
    pop r13
    pop rdi
    pop rsi
    pop rbx
    pop rax
    clc
    ret
.disk_gone:
    mov byte [fs_disk_available], 0
    jmp .skip_os_volume
.fail:
    pop r14
    pop r13
    pop rdi
    pop rsi
    pop rbx
    pop rax
    stc
    ret

; fs_load: reads the OS volume (device 0) into nodes 0..OS_NODES. If the
; magic/version don't check out (blank disk, older format, etc.) or there's
; simply no disk responding at the legacy ATA ports (common on real hardware
; without a PATA/IDE controller, or booting off USB), falls back to fs_init
; for a fresh in-memory-only filesystem. Mounted volumes are never loaded
; here - you re-attach them after boot with 'dscan' + 'mount'.
; sets fs_loaded_from_disk and fs_disk_available accordingly.
fs_load:
    push rax
    push rdi
    push rsi
    xor al, al                  ; device 0 (boot drive)
    xor rdi, rdi                ; base 0 = OS volume
    call vol_read
    cmp rax, -1
    jne .loaded
    ; failed: either no disk, or a disk that isn't SFFS yet
    cmp byte [fs_disk_available], 0
    je .no_disk
    call fs_init
    mov byte [fs_loaded_from_disk], 0
    jmp .done
.no_disk:
    call fs_init
    mov byte [fs_loaded_from_disk], 0
    jmp .done
.loaded:
    mov qword [cur_dir], 0
    mov byte [fs_loaded_from_disk], 1
.done:
    pop rsi
    pop rdi
    pop rax
    ret

; ============================================================
;  VARIABLES  (simple name -> int64 table used by assignment/show/calc)
; ============================================================

; str_len: rsi=string -> rax=length (not including null terminator)
str_len:
    push rsi
    xor rax, rax
.sl_loop:
    cmp byte [rsi], 0
    je .sl_done
    inc rax
    inc rsi
    jmp .sl_loop
.sl_done:
    pop rsi
    ret

; var_find: rsi=name -> rax=index or -1. Preserves rsi.
var_find:
    push rsi
    push rdi
    push rcx
    xor rcx, rcx
.vf_loop:
    cmp rcx, MAX_VARS
    jae .vf_notfound
    cmp byte [var_used+rcx], 0
    je .vf_next
    mov rdi, rcx
    imul rdi, VAR_NAME_LEN
    lea rdi, [var_name+rdi]
    push rsi
    push rcx
    call str_eq
    pop rcx
    pop rsi
    cmp al, 1
    je .vf_found
.vf_next:
    inc rcx
    jmp .vf_loop
.vf_found:
    mov rax, rcx
    jmp .vf_out
.vf_notfound:
    mov rax, -1
.vf_out:
    pop rcx
    pop rdi
    pop rsi
    ret

; var_get: rsi=name -> rax=value, cl=1 if found else cl=0 and rax=0
var_get:
    push rsi
    call var_find
    pop rsi
    cmp rax, -1
    je .vg_notfound
    mov r9, rax
    mov rax, [var_value + r9*8]
    mov cl, 1
    ret
.vg_notfound:
    xor rax, rax
    mov cl, 0
    ret

; var_set: rsi=name, rbx=value(int64). Creates the variable if it
; doesn't exist yet, otherwise updates it in place. Silently does
; nothing if the table is full (MAX_VARS reached).
var_set:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi
    push rbx
    call var_find
    pop rbx
    pop rsi
    cmp rax, -1
    jne .vs_have
    xor rcx, rcx
.vs_free:
    cmp rcx, MAX_VARS
    jae .vs_full
    cmp byte [var_used+rcx], 0
    je .vs_got
    inc rcx
    jmp .vs_free
.vs_got:
    mov byte [var_used+rcx], 1
    mov rdi, rcx
    imul rdi, VAR_NAME_LEN
    lea rdi, [var_name+rdi]
    call str_copy
    mov rax, rcx
    jmp .vs_setval
.vs_have:
.vs_setval:
    mov [var_value + rax*8], rbx
.vs_full:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; parse_int: rsi=null-terminated string -> rax=value(int64), cl=1 if the
; whole string was a valid (optionally negative) decimal integer, else
; cl=0. Does not preserve rcx (used to return the flag in cl).
parse_int:
    push rbx
    push rdx
    push r8
    push r9
    xor rax, rax
    xor rdx, rdx
    xor r8, r8
    mov bl, [rsi]
    cmp bl, '-'
    jne .pi_loop
    mov rdx, 1
    inc rsi
.pi_loop:
    mov bl, [rsi]
    cmp bl, 0
    je .pi_end
    cmp bl, '0'
    jb .pi_bad
    cmp bl, '9'
    ja .pi_bad
    imul rax, rax, 10
    movzx r9, bl
    sub r9, '0'
    add rax, r9
    inc r8
    inc rsi
    jmp .pi_loop
.pi_end:
    cmp r8, 0
    je .pi_bad
    cmp rdx, 1
    jne .pi_ok
    neg rax
.pi_ok:
    mov cl, 1
    jmp .pi_out
.pi_bad:
    xor rax, rax
    mov cl, 0
.pi_out:
    pop r9
    pop r8
    pop rdx
    pop rbx
    ret

; int_to_str: rax=value(signed) -> ascii decimal (with leading '-' if
; negative) written null-terminated to buffer rdi.
int_to_str:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    cmp rax, 0
    jge .its_pos
    mov byte [rdi], '-'
    inc rdi
    neg rax
.its_pos:
    cmp rax, 0
    jne .its_digits
    mov byte [rdi], '0'
    inc rdi
    mov byte [rdi], 0
    jmp .its_done
.its_digits:
    mov rsi, rdi
    xor rcx, rcx
.its_loop:
    cmp rax, 0
    je .its_reverse
    mov rbx, 10
    xor rdx, rdx
    div rbx
    add dl, '0'
    push rdx
    inc rcx
    jmp .its_loop
.its_reverse:
    xor rbx, rbx
.its_pop:
    cmp rbx, rcx
    je .its_termin
    pop rdx
    mov [rsi], dl
    inc rsi
    inc rbx
    jmp .its_pop
.its_termin:
    mov byte [rsi], 0
.its_done:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; parse_uint_run: reads a run of decimal digits starting at [rsi],
; advances rsi past them, returns rax=value. Caller must have already
; verified [rsi] is a digit before calling.
parse_uint_run:
    push rbx
    push r9
    xor rax, rax
.pur_loop:
    mov bl, [rsi]
    cmp bl, '0'
    jb .pur_done
    cmp bl, '9'
    ja .pur_done
    imul rax, rax, 10
    movzx r9, bl
    sub r9, '0'
    add rax, r9
    inc rsi
    jmp .pur_loop
.pur_done:
    pop r9
    pop rbx
    ret

; parse_ident_run: reads [a-zA-Z0-9]* starting at [rsi] (caller has
; verified the first char is a letter), advances rsi past it, looks it
; up as a variable. Returns rax=value, cl=1 if found else 0.
parse_ident_run:
    push rdi
    push rbx
    lea rdi, [ident_buf]
.pir_loop:
    mov al, [rsi]
    cmp al, 0
    je .pir_end
    cmp al, 'a'
    jb .pir_check_upper
    cmp al, 'z'
    jbe .pir_take
.pir_check_upper:
    cmp al, 'A'
    jb .pir_check_digit
    cmp al, 'Z'
    jbe .pir_take
.pir_check_digit:
    cmp al, '0'
    jb .pir_end
    cmp al, '9'
    ja .pir_end
.pir_take:
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .pir_loop
.pir_end:
    mov byte [rdi], 0
    mov rbx, rsi
    lea rsi, [ident_buf]
    push r9
    call var_get
    pop r9
    mov rsi, rbx
    pop rbx
    pop rdi
    ret

; ============================================================
;  CALC EXPRESSION EVALUATOR
;  Supports +, -, *, / with standard precedence (* / before + -),
;  unary minus, decimal literals, and variable names as operands.
;  eval_expr: rsi = expression text (null-terminated) -> rax=result,
;  cl=1 if valid else cl=0. Does not preserve rcx (return flag).
; ============================================================
eval_expr:
    push rbx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    xor r8, r8            ; count of parsed values so far
    mov r9, 1             ; expect_operand flag
    xor r10, r10          ; pending unary-negate flag

.ee_loop:
    mov al, [rsi]
    cmp al, 0
    je .ee_endloop
    cmp al, ' '
    je .ee_skip_space
    cmp r9, 1
    je .ee_operand
    jmp .ee_operator
.ee_skip_space:
    inc rsi
    jmp .ee_loop

.ee_operand:
    cmp al, '-'
    jne .ee_o_notminus
    xor r10, 1
    inc rsi
    jmp .ee_loop
.ee_o_notminus:
    cmp al, '+'
    jne .ee_o_notplus
    inc rsi
    jmp .ee_loop
.ee_o_notplus:
    cmp al, '0'
    jb .ee_o_ident
    cmp al, '9'
    ja .ee_o_ident
    call parse_uint_run
    jmp .ee_have_val
.ee_o_ident:
    cmp al, 'a'
    jb .ee_o_upper
    cmp al, 'z'
    jbe .ee_o_doident
.ee_o_upper:
    cmp al, 'A'
    jb .ee_bad
    cmp al, 'Z'
    ja .ee_bad
.ee_o_doident:
    call parse_ident_run
    cmp cl, 1
    jne .ee_bad
.ee_have_val:
    cmp r10, 1
    jne .ee_store
    neg rax
    xor r10, r10
.ee_store:
    cmp r8, MAX_CALC_TOKENS
    jae .ee_bad
    mov [calc_vals + r8*8], rax
    inc r8
    mov r9, 0
    jmp .ee_loop

.ee_operator:
    cmp al, '+'
    je .ee_op_ok
    cmp al, '-'
    je .ee_op_ok
    cmp al, '*'
    je .ee_op_ok
    cmp al, '/'
    je .ee_op_ok
    jmp .ee_bad
.ee_op_ok:
    mov r11, r8
    dec r11
    mov [calc_ops + r11], al
    inc rsi
    mov r9, 1
    jmp .ee_loop

.ee_endloop:
    cmp r9, 1
    je .ee_bad
    cmp r8, 0
    je .ee_bad

    ; ---- pass 1: fold * and / left-to-right ----
    mov rax, [calc_vals]
    mov [calc_vals2], rax
    mov r12, 1
    xor r13, r13
.ee_md_loop:
    mov rax, r8
    dec rax
    cmp r13, rax
    jae .ee_md_done
    movzx rcx, byte [calc_ops + r13]
    mov rdx, r12
    dec rdx
    cmp cl, '*'
    je .ee_domul
    cmp cl, '/'
    je .ee_dodiv
    mov rbx, r13
    inc rbx
    mov rax, [calc_vals + rbx*8]
    mov [calc_vals2 + r12*8], rax
    mov [calc_ops2 + r12 - 1], cl
    inc r12
    jmp .ee_md_next
.ee_domul:
    mov rax, [calc_vals2 + rdx*8]
    mov rbx, r13
    inc rbx
    imul rax, [calc_vals + rbx*8]
    mov [calc_vals2 + rdx*8], rax
    jmp .ee_md_next
.ee_dodiv:
    mov rax, [calc_vals2 + rdx*8]
    mov rbx, r13
    inc rbx
    mov rbx, [calc_vals + rbx*8]
    cmp rbx, 0
    je .ee_bad
    cqo
    idiv rbx
    mov [calc_vals2 + rdx*8], rax
.ee_md_next:
    inc r13
    jmp .ee_md_loop
.ee_md_done:

    ; ---- pass 2: fold + and - left-to-right ----
    mov rax, [calc_vals2]
    xor r14, r14
.ee_as_loop:
    mov rcx, r12
    dec rcx
    cmp r14, rcx
    jae .ee_as_done
    movzx rbx, byte [calc_ops2 + r14]
    mov rdx, r14
    inc rdx
    mov rcx, [calc_vals2 + rdx*8]
    cmp bl, '+'
    je .ee_doadd
    sub rax, rcx
    jmp .ee_as_next
.ee_doadd:
    add rax, rcx
.ee_as_next:
    inc r14
    jmp .ee_as_loop
.ee_as_done:
    mov cl, 1
    jmp .ee_out
.ee_bad:
    xor rax, rax
    mov cl, 0
.ee_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rbx
    ret

; ============================================================
;  SHELL / STRING HELPERS
; ============================================================

; print_prompt: prints "rush>" + current path + ": "
print_prompt:
    mov rsi, prompt_head
    mov al, ATTR_PROMPT
    call print_string_attr
    call print_path
    mov rsi, prompt_tail
    call print_string
    ret

; print_path: walks parent chain of cur_dir, prints /home/.../name
print_path:
    push rax
    push rbx
    push rcx
    push rsi
    xor rcx, rcx                    ; depth counter
    mov rax, [cur_dir]
.collect:
    mov [path_stack + rcx*2], ax
    inc rcx
    movzx rbx, word [node_parent + rax*2]
    cmp bx, 0xFFFF
    je .print
    mov rax, rbx
    jmp .collect
.print:
    mov al, '/'
    mov bl, ATTR_PROMPT
    call putchar
.printloop:
    dec rcx
    movzx rax, word [path_stack + rcx*2]
    imul rax, NAME_LEN
    lea rsi, [node_name + rax]
    mov al, ATTR_PROMPT
    push rcx
    call print_string_attr
    pop rcx
    cmp rcx, 0
    je .done
    mov al, '/'
    mov bl, ATTR_PROMPT
    call putchar
    jmp .printloop
.done:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; next_token: rsi = pointer into source line, rdi = dest buffer
; advances rsi; writes null-terminated token (may be empty) to rdi
; supports "quoted strings with spaces"
next_token:
    push rax
.skip:
    mov al, [rsi]
    cmp al, 0
    je .empty
    cmp al, ' '
    jne .check_quote
    inc rsi
    jmp .skip
.check_quote:
    cmp al, '"'
    jne .plain
    inc rsi
.qloop:
    mov al, [rsi]
    cmp al, 0
    je .term
    cmp al, '"'
    je .qend
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .qloop
.qend:
    inc rsi
    jmp .term
.plain:
.ploop:
    mov al, [rsi]
    cmp al, 0
    je .term
    cmp al, ' '
    je .term
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .ploop
.term:
    mov byte [rdi], 0
    pop rax
    ret
.empty:
    mov byte [rdi], 0
    pop rax
    ret

; str_copy: null-terminated string rsi -> rdi
str_copy:
    push rax
.loop:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    cmp al, 0
    jne .loop
    pop rax
    ret

; str_append: appends null-terminated string rsi onto the end of the
; null-terminated buffer starting at rdi (rdi = start of the buffer,
; not its current end - this walks to the end itself).
str_append:
    push rax
    push rsi
    push rdi
.sa_find_end:
    cmp byte [rdi], 0
    je .sa_end_found
    inc rdi
    jmp .sa_find_end
.sa_end_found:
.sa_copy:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    cmp al, 0
    jne .sa_copy
    pop rdi
    pop rsi
    pop rax
    ret

; str_eq: rsi, rdi null-terminated strings. returns al=1 if equal else 0
str_eq:
    push rsi
    push rdi
.loop:
    mov al, [rsi]
    mov ah, [rdi]
    cmp al, ah
    jne .neq
    cmp al, 0
    je .eq
    inc rsi
    inc rdi
    jmp .loop
.eq:
    pop rdi
    pop rsi
    mov al, 1
    ret
.neq:
    pop rdi
    pop rsi
    mov al, 0
    ret

; ============================================================
;  VGA TEXT OUTPUT
; ============================================================
clear_screen:
    push rax
    push rcx
    push rdi
    mov rdi, VGA_BASE
    mov rcx, VGA_COLS*VGA_ROWS
    mov ax, 0x0720           ; space, light grey
.loop:
    mov [rdi], ax
    add rdi, 2
    loop .loop
    mov byte [cursor_row], 0
    mov byte [cursor_col], 0
    call update_cursor
    pop rdi
    pop rcx
    pop rax
    ret

; update_cursor: programs the VGA CRTC hardware cursor (the blinking block)
; to match cursor_row/cursor_col, via the index/data port pair 0x3D4/0x3D5.
; Without this the blinking cursor never moves from wherever the BIOS left
; it, even though text is being printed elsewhere.
update_cursor:
    push rax
    push rcx
    push rdx
    movzx rcx, byte [cursor_row]
    imul rcx, VGA_COLS
    movzx rdx, byte [cursor_col]
    add rcx, rdx                 ; rcx = linear cursor position

    mov dx, 0x3D4
    mov al, 0x0F                 ; cursor location low byte
    out dx, al
    mov dx, 0x3D5
    mov al, cl
    out dx, al

    mov dx, 0x3D4
    mov al, 0x0E                 ; cursor location high byte
    out dx, al
    mov dx, 0x3D5
    mov al, ch
    out dx, al

    pop rdx
    pop rcx
    pop rax
    ret

; print_string: rsi = null terminated string, default attribute
print_string:
    push rax
    mov al, ATTR_NORMAL
    call print_string_attr
    pop rax
    ret

; print_string_attr: rsi=string, al=attribute byte
print_string_attr:
    push rax
    push rbx
    push rsi
    mov bl, al
.loop:
    mov al, [rsi]
    cmp al, 0
    je .done
    push rbx
    call putchar
    pop rbx
    inc rsi
    jmp .loop
.done:
    pop rsi
    pop rbx
    pop rax
    ret

; putchar: al = char to print, uses attribute in bl if caller set it via
; print_string_attr; falls back to ATTR_NORMAL when called directly.
; When pipe_capture_on is set (a "~" pipe is capturing a command's
; output - see process_segment), characters are appended to
; pipe_capture_buf instead of touching the screen/cursor at all.
putchar:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi

    cmp byte [pipe_capture_on], 0
    je .not_capturing
    cmp al, 0x0D
    je .cap_done              ; ignore carriage returns
    mov rcx, [pipe_capture_len]
    cmp rcx, PIPE_CAP_MAX-1
    jae .cap_done              ; capture buffer full - silently truncate
    lea rdi, [pipe_capture_buf]
    add rdi, rcx
    mov [rdi], al
    inc rcx
    mov [pipe_capture_len], rcx
    mov byte [pipe_capture_buf + rcx], 0
.cap_done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.not_capturing:
    cmp al, 0x0A
    je .newline
    cmp al, 0x0D
    je .newline

    ; compute video offset = (row*80+col)*2
    movzx rcx, byte [cursor_row]
    imul rcx, VGA_COLS
    movzx rdx, byte [cursor_col]
    add rcx, rdx
    imul rcx, 2
    lea rdi, [VGA_BASE]
    add rdi, rcx
    mov [rdi], al
    cmp bl, 0
    jne .useattr
    mov byte [rdi+1], ATTR_NORMAL
    jmp .advance
.useattr:
    mov [rdi+1], bl
.advance:
    inc byte [cursor_col]
    cmp byte [cursor_col], VGA_COLS
    jne .maybe_scroll
    mov byte [cursor_col], 0
    inc byte [cursor_row]
.maybe_scroll:
    cmp byte [cursor_row], VGA_ROWS
    jne .out
    call scroll_screen
    mov byte [cursor_row], VGA_ROWS-1
    jmp .out
.newline:
    mov byte [cursor_col], 0
    inc byte [cursor_row]
    cmp byte [cursor_row], VGA_ROWS
    jne .out
    call scroll_screen
    mov byte [cursor_row], VGA_ROWS-1
.out:
    call update_cursor
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

scroll_screen:
    push rax
    push rcx
    push rsi
    push rdi
    call scrollback_capture_row      ; archive row 0 before it's shifted away
    mov rsi, VGA_BASE + (VGA_COLS*2)
    mov rdi, VGA_BASE
    mov rcx, (VGA_ROWS-1)*VGA_COLS
    rep movsw
    mov rdi, VGA_BASE + ((VGA_ROWS-1)*VGA_COLS*2)
    mov rcx, VGA_COLS
    mov ax, 0x0720
.clr:
    mov [rdi], ax
    add rdi, 2
    loop .clr
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ============================================================
;  PS/2 KEYBOARD
; ============================================================

; get_char: blocks until a key is pressed, returns ascii in al.
; Also handles: Ctrl tracking (make/break of 0x1D, plain or E0-prefixed),
; E0-prefixed arrow keys (Up=0x48, Down=0x50), and Ctrl+Up/Ctrl+Down driving
; the on-screen scrollback view. Plain Up/Down (no Ctrl) are returned to the
; caller as the sentinel bytes KEY_UP/KEY_DOWN instead of an ascii char, so
; read_line can use them for command history. Right before returning any
; real key (ascii or arrow sentinel) to the caller, if the view is currently
; scrolled back it snaps back to the live screen first - typing or
; navigating history always means "I'm done reviewing, back to the prompt".
get_char:
    push rbx
.wait:
    in al, 0x64
    test al, 1
    jz .wait
    in al, 0x60
    mov bl, al

    cmp byte [kbd_ext_flag], 0
    je .not_ext_cont
    ; this byte follows an 0xE0 prefix byte
    mov byte [kbd_ext_flag], 0
    test bl, 0x80
    jnz .ext_break
    cmp bl, 0x48                 ; extended Up
    je .ext_up
    cmp bl, 0x50                 ; extended Down
    je .ext_down
    cmp bl, 0x1D                 ; right Ctrl make
    je .ext_ctrl_make
    jmp .wait                    ; ignore any other extended key
.ext_break:
    and bl, 0x7F
    cmp bl, 0x1D
    je .ext_ctrl_break
    jmp .wait
.ext_ctrl_make:
    mov byte [ctrl_state], 1
    jmp .wait
.ext_ctrl_break:
    mov byte [ctrl_state], 0
    jmp .wait
.ext_up:
    cmp byte [ctrl_state], 0
    je .return_up
    call scrollback_view_up
    jmp .wait
.ext_down:
    cmp byte [ctrl_state], 0
    je .return_down
    call scrollback_view_down
    jmp .wait
.return_up:
    mov al, KEY_UP
    jmp .snap_and_return
.return_down:
    mov al, KEY_DOWN
    jmp .snap_and_return

.not_ext_cont:
    cmp bl, 0xE0
    je .set_ext
    test bl, 0x80
    jnz .breakcode
    cmp bl, 0x2A
    je .setshift
    cmp bl, 0x36
    je .setshift
    cmp bl, 0x1D                 ; left Ctrl make
    je .ctrl_make
    movzx rbx, bl
    cmp byte [shift_state], 0
    jne .shifted
    mov al, [kbd_unshift + rbx]
    jmp .have
.shifted:
    mov al, [kbd_shift + rbx]
.have:
    cmp al, 0
    je .wait
    jmp .snap_and_return
.set_ext:
    mov byte [kbd_ext_flag], 1
    jmp .wait
.setshift:
    mov byte [shift_state], 1
    jmp .wait
.ctrl_make:
    mov byte [ctrl_state], 1
    jmp .wait
.breakcode:
    and bl, 0x7F
    cmp bl, 0x2A
    je .clrshift
    cmp bl, 0x36
    je .clrshift
    cmp bl, 0x1D
    je .ctrl_break
    jmp .wait
.clrshift:
    mov byte [shift_state], 0
    jmp .wait
.ctrl_break:
    mov byte [ctrl_state], 0
    jmp .wait

.snap_and_return:
    push rax
    cmp byte [scroll_offset], 0
    je .no_snap
    xor al, al
    call scrollback_render
.no_snap:
    pop rax
    pop rbx
    ret

; ============================================================
;  SCROLLBACK VIEW (Ctrl+Up / Ctrl+Down)
; ============================================================
; All of these routines save/restore every register they use, so they are
; safe to call from anywhere inside get_char without disturbing a caller
; like read_line that keeps its own state (buffer ptr/length/max) in
; r8/r9/r10 across get_char calls.

; scrollback_capture_row: archives the current row 0 (about to be shifted
; off by scroll_screen) into the scrollback ring buffer.
scrollback_capture_row:
    push rax
    push rcx
    push rsi
    push rdi

    movzx rax, byte [sb_write_idx]
    imul rax, VGA_COLS*2
    lea rdi, [scrollback_buf + rax]
    mov rsi, VGA_BASE
    mov rcx, VGA_COLS*2
    rep movsb

    movzx rax, byte [sb_write_idx]
    inc rax
    cmp rax, SCROLLBACK_LINES
    jne .no_wrap
    xor rax, rax
.no_wrap:
    mov [sb_write_idx], al

    cmp byte [sb_count], SCROLLBACK_LINES
    je .out
    inc byte [sb_count]
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; scrollback_render: al = desired scroll offset (0 = live). Clamps to
; [0, sb_count], stores the clamped value in scroll_offset, and redraws
; VGA_BASE either as the pure live screen (from live_snapshot) or as a
; composite of scrollback_buf + live_snapshot. Parks the hardware cursor
; off-screen while scrolled back, since it belongs to the live line the
; user is no longer looking at.
scrollback_render:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10

    movzx r9, byte [sb_count]
    movzx r8, al
    cmp r8, r9
    jbe .clamped
    mov r8, r9
.clamped:
    mov al, r8b
    mov [scroll_offset], al

    cmp r8, 0
    jne .composite

    lea rsi, [live_snapshot]
    mov rdi, VGA_BASE
    mov rcx, VGA_ROWS*VGA_COLS*2
    rep movsb
    call update_cursor
    jmp .done

.composite:
    mov rax, r9
    sub rax, r8                  ; rax = start virtual line index
    xor r10, r10                 ; r10 = output row 0..VGA_ROWS-1
.row_loop:
    cmp r10, VGA_ROWS
    jae .rows_done
    mov rdx, rax
    add rdx, r10                 ; rdx = virtual line index for this row

    cmp rdx, r9
    jb .from_sb

    mov rcx, rdx
    sub rcx, r9
    imul rcx, VGA_COLS*2
    lea rsi, [live_snapshot + rcx]
    jmp .copy_row

.from_sb:
    movzx rcx, byte [sb_write_idx]
    add rcx, SCROLLBACK_LINES
    sub rcx, r9
    add rcx, rdx
    xor rdx, rdx
    push rax
    mov rax, rcx
    mov rbx, SCROLLBACK_LINES
    div rbx
    mov rcx, rdx
    pop rax
    imul rcx, VGA_COLS*2
    lea rsi, [scrollback_buf + rcx]

.copy_row:
    mov rdi, VGA_BASE
    mov rcx, r10
    imul rcx, VGA_COLS*2
    add rdi, rcx
    mov rcx, VGA_COLS*2
    rep movsb
    inc r10
    jmp .row_loop

.rows_done:
    mov dx, 0x3D4
    mov al, 0x0F
    out dx, al
    mov dx, 0x3D5
    mov al, 0xFF
    out dx, al
    mov dx, 0x3D4
    mov al, 0x0E
    out dx, al
    mov dx, 0x3D5
    mov al, 0xFF
    out dx, al

.done:
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

; scrollback_view_up: Ctrl+Up. On the first press (scroll_offset==0),
; snapshots the current live screen so it can be exactly restored later,
; then scrolls the view back one more line (capped at what's stored).
scrollback_view_up:
    push rax
    push rcx
    push rsi
    push rdi

    cmp byte [scroll_offset], 0
    jne .already_scrolled
    mov rsi, VGA_BASE
    lea rdi, [live_snapshot]
    mov rcx, VGA_ROWS*VGA_COLS*2
    rep movsb
.already_scrolled:
    movzx rax, byte [scroll_offset]
    inc rax
    call scrollback_render

    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; scrollback_view_down: Ctrl+Down. Scrolls the view one line back toward
; the live screen (a no-op once already live).
scrollback_view_down:
    push rax
    cmp byte [scroll_offset], 0
    je .out
    movzx rax, byte [scroll_offset]
    dec rax
    call scrollback_render
.out:
    pop rax
    ret

; read_line: rdi=buffer, rcx=max chars. Echoes to screen, handles
; backspace, Up/Down command history, and terminates on Enter. Buffer is
; null terminated.
read_line:
    push rax
    push rbx
    push rdi
    push rcx
    xor r8, r8
    mov r9, rdi
    mov r10, rcx
    mov byte [history_nav], 0
.loop:
    call get_char
    cmp al, 0x0D
    je .enter
    cmp al, 0x08
    je .bksp
    cmp al, KEY_UP
    je .hist_up
    cmp al, KEY_DOWN
    je .hist_down
    cmp r8, r10
    jae .loop
    mov [r9 + r8], al
    inc r8
    mov bl, ATTR_NORMAL
    call putchar
    jmp .loop
.bksp:
    cmp r8, 0
    je .loop
    dec r8
    call do_backspace
    jmp .loop

.hist_up:
    cmp byte [history_count], 0
    je .loop
    movzx rax, byte [history_nav]
    movzx rbx, byte [history_count]
    cmp rax, rbx
    jae .loop                    ; already at the oldest entry
    cmp rax, 0
    jne .hu_have_saved
    mov rsi, r9
    lea rdi, [history_saved_line]
    call str_copy
.hu_have_saved:
    inc byte [history_nav]
    call .history_index          ; -> rax = ring index for history_nav
    imul rax, LINE_MAX
    lea rsi, [history_buf + rax]
    call .load_entry
    jmp .loop

.hist_down:
    cmp byte [history_nav], 0
    je .loop
    dec byte [history_nav]
    cmp byte [history_nav], 0
    jne .hd_older
    lea rsi, [history_saved_line]
    call .load_entry
    jmp .loop
.hd_older:
    call .history_index
    imul rax, LINE_MAX
    lea rsi, [history_buf + rax]
    call .load_entry
    jmp .loop

; .history_index: rax = (history_next + HISTORY_MAX - history_nav) mod HISTORY_MAX
.history_index:
    push rbx
    push rdx
    movzx rax, byte [history_next]
    add rax, HISTORY_MAX
    movzx rbx, byte [history_nav]
    sub rax, rbx
    xor rdx, rdx
    mov rbx, HISTORY_MAX
    div rbx
    mov rax, rdx
    pop rdx
    pop rbx
    ret

; .load_entry: rsi = null-terminated source string. Erases the currently
; displayed/buffered line and replaces it with the source string.
.load_entry:
    push rax
    push rcx
    mov rcx, r8
.le_erase:
    cmp rcx, 0
    je .le_erase_done
    call do_backspace
    dec rcx
    jmp .le_erase
.le_erase_done:
    xor r8, r8
.le_copy:
    mov al, [rsi + r8]
    cmp al, 0
    je .le_copy_done
    cmp r8, r10
    jae .le_copy_done
    mov [r9 + r8], al
    inc r8
    jmp .le_copy
.le_copy_done:
    mov byte [r9 + r8], 0
    xor rcx, rcx
.le_echo:
    cmp rcx, r8
    jae .le_echo_done
    mov al, [r9 + rcx]
    push rbx
    mov bl, ATTR_NORMAL
    call putchar
    pop rbx
    inc rcx
    jmp .le_echo
.le_echo_done:
    pop rcx
    pop rax
    ret

.enter:
    mov byte [r9 + r8], 0
    mov al, 0x0A
    call putchar
    cmp r8, 0
    je .no_history_push
    movzx rax, byte [history_next]
    imul rax, LINE_MAX
    lea rdi, [history_buf + rax]
    mov rsi, r9
    call str_copy
    movzx rax, byte [history_next]
    inc rax
    cmp rax, HISTORY_MAX
    jne .hn_no_wrap
    xor rax, rax
.hn_no_wrap:
    mov [history_next], al
    cmp byte [history_count], HISTORY_MAX
    je .no_history_push
    inc byte [history_count]
.no_history_push:
    pop rcx
    pop rdi
    pop rbx
    pop rax
    ret

; erase one character visually (move cursor back, blank it)
do_backspace:
    push rax
    cmp byte [cursor_col], 0
    je .maybeup
    dec byte [cursor_col]
    jmp .blank
.maybeup:
    cmp byte [cursor_row], 0
    je .out
    dec byte [cursor_row]
    mov byte [cursor_col], VGA_COLS-1
.blank:
    push rbx
    push rcx
    push rdx
    push rdi
    movzx rcx, byte [cursor_row]
    imul rcx, VGA_COLS
    movzx rdx, byte [cursor_col]
    add rcx, rdx
    imul rcx, 2
    lea rdi, [VGA_BASE]
    add rdi, rcx
    mov byte [rdi], ' '
    mov byte [rdi+1], 0x07
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    call update_cursor
.out:
    pop rax
    ret

; ============================================================
;  DATA
; ============================================================
ALIGN 8
cursor_row:   db 0
cursor_col:   db 0
shift_state:  db 0
cur_dir:      dq 0
auth_valid:   db 0                   ; set by 'auth' command, checked by dangerous commands

; --- keyboard/scrollback/history state ---
ctrl_state:    db 0                  ; 1 while either Ctrl key is held
kbd_ext_flag:  db 0                  ; 1 while waiting for the byte after an 0xE0 prefix
scroll_offset: db 0                  ; 0 = live view, N = N lines scrolled back
sb_write_idx:  db 0                  ; next slot to write in scrollback_buf (ring)
sb_count:      db 0                  ; valid lines currently stored in scrollback_buf
history_next:  db 0                  ; next slot to write in history_buf (ring)
history_count: db 0                  ; valid entries currently stored in history_buf
history_nav:   db 0                  ; 0 = not browsing history, else 1..history_count deep

ALIGN 8
scrollback_buf:     times SCROLLBACK_LINES*VGA_COLS*2 db 0
live_snapshot:       times VGA_ROWS*VGA_COLS*2 db 0
history_buf:         times HISTORY_MAX*LINE_MAX db 0
history_saved_line:  times LINE_MAX db 0

banner:
    db "ShellyForever v0.1 -- 'help' for commands", 10, 0

prompt_head: db "rush>", 0
prompt_tail: db ": ", 0
newline_str: db 10, 0

str_slash:  db "/", 0
str_home:   db "/home", 0
str_updir:  db "..", 0
str_dot:    db ".", 0
str_cf:     db "cf", 0
str_mkf:    db "mkf", 0
str_mkfl:   db "mkfl", 0
str_show:   db "show", 0
str_ls:     db "list", 0
str_cat:    db "view", 0
str_pwd:    db "current", 0
str_clear:  db "wipe", 0
str_help:   db "help", 0
str_reboot: db "rboot", 0
str_sync:   db "sync", 0
str_calc:   db "calc", 0
str_edit:   db "edit", 0
str_del:    db "del", 0
str_rmv:    db "rmv", 0
str_sdown:  db "sdown", 0
str_rr:     db "rr", 0
str_prs:    db "prs", 0
str_kill:   db "kill", 0
str_rushrun: db "rushrun", 0
str_runrush: db "runrush", 0
str_rname:  db "rname", 0
str_cpy:    db "cpy", 0
str_mov:    db "mov", 0
str_eq_sign: db "=", 0
str_home_name: db "home", 0
str_auth:   db "auth", 0
str_vars:   db "vars", 0
str_rmv_all: db "all", 0
str_force:  db "-force", 0
str_silent: db "-silent", 0
str_info:   db "-info", 0
str_dscan:  db "dscan", 0
str_format: db "fmt", 0
str_mount:  db "mount", 0
str_label:  db "label", 0
str_semicolon: db ";", 0
str_tilde:     db "~", 0
str_dollar:    db "$", 0

tag_folder: db "/", 10, 0
tag_file:   db "", 10, 0

msg_unknown1: db "rush: unknown command: ", 0
msg_unknown2: db " (type 'help')", 10, 0
msg_no_folder: db "cf: no such folder: ", 0
msg_bad_path:  db "error: no such folder in path: ", 0
msg_no_file:   db "view: no such file: ", 0
msg_no_entry:  db "no such file or folder: ", 0
msg_no_var:    db "rmv: no such variable: ", 0
msg_need_name: db "error: a name is required", 10, 0
msg_exists:    db "error: that name already exists here", 10, 0
msg_full:      db "error: filesystem is full", 10, 0
msg_name_too_long: db "error: name too long (max 31 characters)", 10, 0
msg_copy_failed: db "error: name already exists at destination, or filesystem is full", 10, 0
msg_shutting_down: db "Shutting down...", 10, 0
msg_empty:     db "(empty)", 10, 0
msg_synced:     db "Filesystem synced to disk.", 10, 0
msg_loaded_fs:  db "Loaded filesystem from disk.", 10, 10, 0
msg_fresh_fs:   db "No saved filesystem found - starting fresh.", 10, 10, 0
msg_no_disk:    db "No disk detected - filesystem will not persist.", 10, 10, 0
msg_sync_failed: db "error: sync failed - disk not available.", 10, 0

; --- SFFS disk / mount messages ---
msg_dscan_header: db "Scanning for SFFS disks...", 10, 0
msg_dscan_found1: db "  device ", 0
msg_dscan_found2: db " (", 0
msg_dscan_found3: db "): SFFS volume '", 0
msg_dscan_found4: db "'", 0
msg_dscan_other2: db "): present, not SFFS", 0
msg_dscan_none:   db "No SFFS disks found.", 10, 0
msg_dev_primary:  db "primary ", 0
msg_dev_secondary: db "secondary ", 0
msg_dev_master:   db "master", 0
msg_dev_slave:    db "slave", 0
msg_dev_ahci:     db "ahci port ", 0
msg_fmt_usage:    db "fmt: use 'fmt <label>' to format a drive", 10, 0
msg_fmt_none:     db "fmt: no unformatted drive found (use 'fmt <label> -force' to reuse one)", 10, 0
msg_fmt_long:     db "fmt: label too long (max 31 characters)", 10, 0
msg_fmt_ok1:      db "Formatted ", 0
msg_fmt_ok2:      db " on ", 0
msg_fmt_ok3:      db ". Use 'sync' to save, then 'mount <label>'.", 0
msg_fmt_err:      db "fmt: disk error - failed to write.", 10, 0
msg_mount_usage:  db "mount: use 'mount <label>' to mount a formatted drive", 10, 0
msg_mount_none:   db "mount: no disk labeled '", 0
msg_mount_none2:  db "' found. Run 'dscan'.", 10, 0
msg_mount_already: db "mount: already mounted: ", 0
msg_mount_full:   db "mount: too many drives mounted", 10, 0
msg_mount_fail:   db "mount: failed to read the drive.", 10, 0
msg_mount_ok1:    db "Mounted ", 0
msg_mount_ok2:    db " at /", 0
msg_mount_ok3:    db "/. Use 'cf ", 0
msg_mount_ok4:    db "' to enter it.", 0
msg_label_usage:  db "label: use 'label <old> <new>' to rename a drive", 10, 0
msg_label_long:   db "label: new label too long (max 31 characters)", 10, 0
msg_label_none1:  db "label: no drive labeled '", 0
msg_label_none2:  db "' found. Run 'dscan'.", 10, 0
msg_label_inuse1: db "label: '", 0
msg_label_inuse2: db "' is already used by another drive.", 10, 0
msg_label_iofail: db "label: disk error - failed to write.", 10, 0
msg_label_ok1:    db "Relabeled '", 0
msg_label_ok2:    db "' to '", 0
msg_label_ok3:    db "'.", 10, 0
msg_bad_value:   db "error: invalid value", 10, 0
msg_calc_err:      db "calc: invalid expression", 10, 0
msg_calc_need_expr: db "calc: need an expression, e.g. calc 1 + 2 * 3", 10, 0
msg_edit_header1: db "-- editing ", 0
msg_edit_header2: db "  (ESC when done, then y/n to save) --", 10, 10, 0
msg_save_prompt:  db 10, "Save changes? (y/n): ", 0
msg_saved:        db 10, "Saved.", 10, 0
msg_discarded:    db 10, "Discarded.", 10, 0

; --- rush script / process messages ---
msg_rr_running:   db "runrush ", 0
msg_rr_pid1:      db " (pid ", 0
msg_rr_pid2:      db ")", 10, 0
msg_rr_killed:    db "Process killed.", 10, 0
msg_rr_done:      db "Script done.", 10, 0
msg_rr_nofile:    db "rr: no such file: ", 0
msg_rr_toomany:   db "rr: too many processes running", 10, 0
msg_prs_none:     db "prs: no running processes", 10, 0
msg_prs_killed:   db "Killed process ", 0
msg_prs_noid:     db "prs: no such process", 10, 0
msg_prs_header:   db "PID  Name", 10, 0
prs_spaces:      db "   ", 0

; --- auth / vars / flags messages ---
msg_auth_required: db "error: this command requires authentication. Use 'auth <command>' first.", 10, 0
msg_auth_granted:  db "Authentication granted.", 10, 0
msg_vars_header:   db "Variables:", 10, 0
msg_vars_sep:     db " = ", 0
msg_vars_cleared:  db "All variables cleared.", 10, 0
msg_mkfl_overwrite: db "mkfl: overwriting existing file ", 0
msg_mkfl_info:     db "mkfl: creating '", 0
msg_mkfl_info2:    db "' (", 0
msg_mkfl_info3:    db " bytes)", 10, 0

help_text:
    db "Commands (name args accept paths: docs/notes.txt, ../x, /home/x):", 10
    db "  cf <path>          change folder ('cf ..' up, 'cf /home' root)", 10
    db "  mkf <path>         make a folder", 10
    db '  mkfl <path> "txt"  make a file with text content', 10
    db '  show "text"        print a message (or a variable to show its value)', 10
    db "  list               list contents of current folder", 10
    db "  view <path>        print a file's content", 10
    db "  edit <name>        open the built-in editor for a file", 10
    db "  del <path>         delete a file (requires auth)", 10
    db "  rname <path> <new> rename a file or folder (new name stays in same folder)", 10
    db "  cpy <src> <dest>   copy a file or folder (both can be paths)", 10
    db "  mov <src> <dest>   move/rename a file or folder (both can be paths)", 10
    db "  rr <script.rsh>    run a rush script file ($ = comment line)", 10
    db "  prs [kill <id>]    list processes, or kill by PID/rushrun", 10
    db "  vars               list all variables", 10
    db "  vars rmv all       clear all variables (requires auth)", 10
    db "  auth <cmd> [args]  elevate privileges for one dangerous command", 10
    db "  mkfl -force        overwrite existing file (use -silent to suppress warning)", 10
    db "  mkfl -info         verbose output (filename + content length)", 10
    db "  <name> = <value>   set a variable, e.g. a = 1", 10
    db "  rmv <name>         remove a variable", 10
    db "  calc <expr>        evaluate math, e.g. calc 1 + 2 * 3", 10
    db "  current            print current path", 10
    db "  wipe               clear the screen", 10
    db "  sync               save the filesystem (and mounted drives) to disk", 10
    db "  fmt <label>        format a drive with the SFFS format (-force reuses one)", 10
    db "  dscan              scan for SFFS drives attached to the ATA bus", 10
    db "  mount <label>      mount a formatted drive at /<label>/", 10
    db "  label <old> <new>  rename a formatted drive without touching its data", 10
    db "  rboot              save to disk, then restart (requires auth)", 10
    db "  sdown              shut down (requires auth)", 10
    db "  ;                  chain commands, e.g. show hi ; show bye", 10
    db "  ~                  pipe output, e.g. calc 1+2*3 ~ = a ; show a", 10
    db "  $                  comment line (lines starting with $ are skipped)", 10
    db "  help <command>     show detailed help for one command", 10, 10, 0

; --- per-command detail text for "help <command>" (see help_lookup) ---
msg_help_unknown1: db "help: unknown command '", 0
msg_help_unknown2: db "'", 10, 0

help_cf:
    db "cf <path>", 10
    db "  Change the current folder.", 10
    db "  e.g. cf docs        (descend into 'docs' here)", 10
    db "       cf ..          (go up one level)", 10
    db "       cf /home       (jump to the root)", 10, 0

help_mkf:
    db "mkf <path>", 10
    db "  Make a new folder in the current directory (or at a path).", 10
    db "  e.g. mkf docs", 10, 0

help_mkfl:
    db 'mkfl <path> "text" [-force] [-silent] [-info]', 10
    db "  Make a file here with the given text content.", 10
    db "  -force overwrites an existing file (prints a warning).", 10
    db "  -silent suppresses that overwrite warning.", 10
    db "  -info prints the filename and content length.", 10
    db '  e.g. mkfl hi.txt "hello" -force -silent', 10, 0

help_show:
    db 'show "text" | show <name>', 10
    db "  Print a literal message, or print a variable's current value.", 10
    db '  e.g. show "hello world"      show a', 10, 0

help_ls:
    db "list", 10
    db "  List the contents of the current folder.", 10, 0

help_cat:
    db "view <path>", 10
    db "  Print a file's content.", 10, 0

help_edit:
    db "edit <path>", 10
    db "  Open the built-in line editor on a file's content.", 10
    db "  Esc ends editing, then y/n saves or discards the change.", 10, 0

help_del:
    db "del <path>", 10
    db "  Delete a file in the current folder. Requires auth:", 10
    db "  auth del <path>", 10, 0

help_rname:
    db "rname <path> <new>", 10
    db "  Rename a file or folder. The new name stays in the same", 10
    db "  folder as the original.", 10, 0

help_cpy:
    db "cpy <src> <dest>", 10
    db "  Copy a file or folder here (recursive for folders).", 10, 0

help_mov:
    db "mov <src> <dest>", 10
    db "  Move/rename a file or folder here (recursive for folders).", 10, 0

help_assign:
    db "<name> = <value>", 10
    db "  Set a variable to a literal integer or another variable's", 10
    db "  value.  e.g. a = 5", 10, 0

help_rmv:
    db "rmv <name>", 10
    db "  Remove a variable.", 10, 0

help_vars:
    db "vars | vars rmv all", 10
    db "  List all variables, or clear all of them. Clearing requires", 10
    db "  auth: auth vars rmv all", 10, 0

help_calc:
    db "calc <expr>", 10
    db "  Evaluate a math expression (+ - * /), left-to-right with", 10
    db "  normal operator precedence.  e.g. calc 1 + 2 * 3", 10, 0

help_rr:
    db "rr <script.rsh>", 10
    db "  Run a rush script file line by line. Lines starting with $", 10
    db "  are comments, skipped just like at the interactive prompt.", 10
    db "  Esc interrupts a running script. ; chaining works inside", 10
    db "  script lines too.", 10, 0

help_prs:
    db "prs | prs kill <id> | prs kill <name>", 10
    db "  List currently running rr scripts, or kill one by its PID", 10
    db "  or by name.  e.g. prs kill 1        prs kill rushrun", 10, 0

help_auth:
    db "auth <command> [args]", 10
    db "  Elevate privileges for the one command that immediately", 10
    db "  follows (like sudo). Required for: sdown, rboot, del,", 10
    db "  and vars rmv all.  e.g. auth sdown", 10, 0

help_pwd:
    db "current", 10
    db "  Print the current folder's path.", 10, 0

help_clear:
    db "wipe", 10
    db "  Clear the screen.", 10, 0

help_help:
    db "help | help <command>", 10
    db "  List every command, or show detailed help for just one.", 10
    db "  e.g. help calc", 10, 0

help_dscan:
    db "dscan", 10
    db "  Scan all four ATA drive slots for SFFS volumes and report", 10
    db "  which ones are formatted.", 10, 0

help_fmt:
    db "fmt <label> [-force]", 10
    db "  Format the first unformatted drive with an SFFS label.", 10
    db "  -force lets you reuse an already-formatted, non-boot drive.", 10, 0

help_mount:
    db "mount <label>", 10
    db "  Mount a formatted drive's volume under /<label>/, next to", 10
    db "  /home. Up to 2 drives can be mounted at once.", 10, 0

help_label:
    db "label <old> <new>", 10
    db "  Rename a formatted drive's label in place. Only the superblock's", 10
    db "  label is rewritten - the drive's files are left untouched. Fails", 10
    db "  if <new> is already used by another drive.", 10, 0

help_sync:
    db "sync", 10
    db "  Save the filesystem (and any mounted volumes) to disk.", 10, 0

help_rboot:
    db "rboot", 10
    db "  Save to disk, then restart. Requires auth: auth rboot", 10, 0

help_sdown:
    db "sdown", 10
    db "  Save to disk, then shut down. Requires auth: auth sdown", 10, 0

help_semicolon:
    db "; (command chaining)", 10
    db "  Run multiple commands on one line, e.g. show hi ; show bye.", 10
    db "  A ; inside double quotes is literal, not a separator - this", 10
    db "  works inside rr scripts too.", 10, 0

help_tilde:
    db "~ (pipe)", 10
    db "  Pipe one command's output into another.", 10
    db "  calc 1+2*3 ~ = a     stores the result in the variable a", 10
    db "  calc 3 * 3 ~ show    pipes the result into show, prints 9", 10
    db "  The right side is '= name' (assign) or any other command,", 10
    db "  which gets the captured text appended as a quoted argument.", 10, 0

help_dollar:
    db "$ (comment)", 10
    db "  A line whose first character is $ is skipped, both at the", 10
    db "  interactive prompt and when running an rr script.", 10, 0


; --- scancode set 1 -> ascii tables (index = scancode, 0..0x39) ---
ALIGN 8
kbd_unshift:
    db 0,27,'1','2','3','4','5','6','7','8'      ; 0x00-0x09
    db '9','0','-','=',8,9                        ; 0x0A-0x0F
    db 'q','w','e','r','t','y','u','i','o','p'    ; 0x10-0x19
    db '[',']',13,0                                ; 0x1A-0x1D
    db 'a','s','d','f','g','h','j','k','l',';'    ; 0x1E-0x27
    db 39,'`',0,'\'                                ; 0x28-0x2B
    db 'z','x','c','v','b','n','m',',','.','/'    ; 0x2C-0x35
    db 0,'*',0,' '                                 ; 0x36-0x39

kbd_shift:
    db 0,27,'!','@','#','$','%','^','&','*'       ; 0x00-0x09
    db '(',')','_','+',8,9                         ; 0x0A-0x0F
    db 'Q','W','E','R','T','Y','U','I','O','P'    ; 0x10-0x19
    db '{','}',13,0                                ; 0x1A-0x1D
    db 'A','S','D','F','G','H','J','K','L',':'    ; 0x1E-0x27
    db 34,'~',0,'|'                                ; 0x28-0x2B
    db 'Z','X','C','V','B','N','M','<','>','?'    ; 0x2C-0x35
    db 0,'*',0,' '                                 ; 0x36-0x39

; --- filesystem storage ---
; One flat node table shared by every mounted volume. The OS volume lives
; in nodes 0..OS_NODES; mount slot k owns nodes VOL_NODES*(k+1)..VOL_NODES*(k+2)-1.
; Each volume is persisted separately (superblock + node arrays) to its own
; device - see the SFFS v2 layout notes near the top of this file.
;
; IMPORTANT: ata_read_sector/ata_write_sector always move a full 512-byte
; sector, so every buffer a sector is staged in/out of must hold 512 bytes.
; node_type and fs_parent_scratch are exactly that: the type/parent reads
; in vol_read/vol_write go straight at a whole sector each, and anything
; smaller would silently overflow into the adjacent arrays (which showed up
; as a black screen after 'mount' corrupted the node table).
ALIGN 8
fs_super_buf:   times 512 db 0        ; scratch for reading/building superblocks
fs_parent_scratch: times 512 db 0     ; staging for one full parent sector (512B)
mount_label:   times MAX_MOUNTS*32 db 0     ; label of each mounted volume
mount_device:  times MAX_MOUNTS db 0        ; device id each volume came from
mount_used:    times MAX_MOUNTS db 0        ; 1 = slot in use
; type sector = 512B per volume (base 0/64/128), so this must span the max
; extent of a sector write: base + 512. node indices still index it by node
; (1 byte per node); the per-volume padding holds whatever the sector has.
node_type:    times 512 * (1 + MAX_MOUNTS) db 0
node_parent:  times MAX_NODES dw 0
node_name:    times MAX_NODES*NAME_LEN db 0
node_content: times MAX_NODES*CONTENT_LEN db 0

fs_loaded_from_disk: db 0
fs_disk_available:   db 1     ; optimistic default; cleared on first ATA failure
fs_name_too_long:    db 0     ; set by fs_create_node when a name won't fit

ALIGN 8
ata_port_base: dw 0x1F0        ; 0x1F0 primary channel, 0x170 secondary
ata_drive_sel: db 0xE0         ; 0xE0 master, 0xF0 slave

; --- AHCI (SATA) driver state ---
pci_scratch_hdrtype: db 0
ahci_pci_bus:     db 0
ahci_pci_dev:     db 0
ahci_pci_func:    db 0
ALIGN 4
ahci_abar:        dd 0             ; physical base of the AHCI MMIO register window
ahci_ports_impl:  dd 0             ; PI bitmap read from the HBA at boot
ahci_port_count:  db 0             ; how many of ahci_port_num/base are valid
ahci_port_num:    times AHCI_MAX_PORTS dd 0   ; slot -> real HBA port number
ALIGN 8
ahci_port_base:   times AHCI_MAX_PORTS dq 0   ; slot -> port register base ptr
disk_use_ahci:    db 0             ; set by disk_select_device: 0=ATA, 1=AHCI
ahci_cur_slot:    db 0             ; which AHCI slot is currently selected
ahci_op_cmd:      db 0             ; pending ATA command byte (read vs write)
ahci_op_write:    db 0             ; 1 if the pending op is a write

; Command list (1KB/port, must be 1KB-aligned), FIS receive area (256B/port,
; must be 256B-aligned), and command table (256B/port, must be 128B-aligned,
; and big enough for a 20-byte Reg H2D FIS plus one 16-byte PRDT entry) for
; each AHCI port slot we bring up. Identity-mapped, so these labels' linked
; addresses double as the physical addresses the HBA needs - same trick the
; rest of this file already relies on for fs_super_buf and friends.
ALIGN 1024
ahci_clb:    times AHCI_MAX_PORTS*1024 db 0
ALIGN 256
ahci_fis:    times AHCI_MAX_PORTS*256 db 0
ALIGN 128
ahci_cmdtbl: times AHCI_MAX_PORTS*256 db 0

path_stack:   times 16 dw 0

; --- scratch for fs_resolve_path ---
path_comp_buf: times 64 db 0     ; one path component at a time
leaf1_buf:      times 64 db 0    ; resolved leaf name for arg1_buf paths
leaf2_buf:      times 64 db 0    ; resolved leaf name for arg2_buf paths

; --- line editing buffers ---
line_buf: times LINE_MAX db 0
chain_scan_buf: times LINE_MAX db 0  ; scratch copy for ; chaining
cmd_buf:  times 32  db 0
arg1_buf: times 96  db 0
arg2_buf: times 160 db 0
arg3_buf: times 32  db 0             ; for flags (-force, -silent, -info)
arg4_buf: times 32  db 0             ; for additional flags

; --- "~" pipe scratch (see process_segment) ---
chain_is_rr:       db 0             ; 0 = process_chain, 1 = process_chain_rr
pipe_left_buf:     times LINE_MAX db 0
pipe_right_buf:    times LINE_MAX db 0
pipe_capture_on:   db 0
ALIGN 8
pipe_capture_len:  dq 0
pipe_capture_buf:  times PIPE_CAP_MAX db 0
pipe_quote_str:       db '"', 0
pipe_space_quote_str: db ' ', '"', 0

; --- variables table (used by assignment, show, and calc) ---
ALIGN 8
var_name:  times MAX_VARS*VAR_NAME_LEN db 0
var_value: times MAX_VARS dq 0
var_used:  times MAX_VARS db 0

; --- calc evaluator scratch ---
ALIGN 8
calc_vals:  times MAX_CALC_TOKENS dq 0
calc_vals2: times MAX_CALC_TOKENS dq 0
calc_ops:   times MAX_CALC_TOKENS db 0
calc_ops2:  times MAX_CALC_TOKENS db 0
calc_out_buf: times 24 db 0
show_num_buf: times 24 db 0
dev_name_num_buf: times 24 db 0
ident_buf:  times 40 db 0

; --- built-in editor buffer (one file's worth of content) ---
edit_buf: times CONTENT_LEN db 0

; --- process table for rush scripts ---
MAX_PROCESSES equ 4
proc_id:       times MAX_PROCESSES dw 0
proc_name:     times MAX_PROCESSES*32 db 0
proc_state:    times MAX_PROCESSES db 0    ; 0=free, 1=running, 2=killed
proc_next_pid: dw 1
proc_cur_slot: db 0                         ; slot index of currently running script
kill_flag:     db 0                         ; set by Esc key or prs kill
rr_content_ptr: dq 0                         ; cursor into script file content