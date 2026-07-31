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

MAX_NODES       equ 64
NAME_LEN        equ 32
CONTENT_LEN     equ 160
LINE_MAX        equ 220

MAX_VARS        equ 16
VAR_NAME_LEN    equ 32
MAX_CALC_TOKENS equ 32

; get_char returns these for arrow keys instead of an ASCII byte. Values
; are chosen outside the 0x00-0x7E range that the scancode tables and
; every other control code (8/13/27) ever produce, so they can never be
; confused with a real typed character.
KEY_UP          equ 0x91
KEY_DOWN        equ 0x92
KEY_CTRL_UP     equ 0x93
KEY_CTRL_DOWN   equ 0x94

; command history (Up/Down arrow recall). Ring buffer, must be a power
; of two so "index mod HIST_MAX" can be done with a plain AND.
HIST_MAX        equ 16

; output scrollback (Ctrl+Up/Ctrl+Down). Ring buffer of whole VGA text
; rows, also power-of-two sized for the same reason. 256 rows is ~10
; screenfuls of history.
SCROLLBACK_LINES equ 256

; disk region (LBA sectors) where the filesystem is persisted.
; kernel occupies LBA 1..64 (see boot.asm KERNEL_SECTORS), so LBA 100
; leaves plenty of headroom for the kernel to grow.
FS_LBA_START    equ 100

; --- USB project transfer format (usb list/info/export/import/delete/rename) ---
; This is intentionally NOT FAT/exFAT - it's a tiny purpose-built layout for
; moving ShellyForever project folders between machines on a USB drive.
;   LBA 0        : index header (magic/version/project count)
;   LBA 1..2     : project table (USB_MAX_PROJECTS fixed-size entries)
;   LBA 3..      : project archives, one fixed-size slot per table entry
USB_MAX_PROJECTS       equ 16
USB_ENTRY_SIZE         equ 64             ; bytes per project-table entry
USB_TABLE_LBA          equ 1              ; table is 16*64=1024 bytes = 2 sectors
USB_DATA_START_LBA     equ 3
USB_PROJECT_SLOT_SECTORS equ 32           ; sectors reserved per project archive
USB_PROJECT_SLOT_BYTES equ USB_PROJECT_SLOT_SECTORS*512   ; 16384 bytes/project

; project-table entry field offsets (within USB_ENTRY_SIZE bytes)
USB_ENT_NAME    equ 0      ; NAME_LEN bytes, null-padded
USB_ENT_LBA     equ 32     ; dd - starting LBA of this project's archive
USB_ENT_SIZE    equ 36     ; dd - archive size in bytes (used part of slot)
USB_ENT_FLAGS   equ 40     ; db - bit0 = 1 if this entry is in use

; project archive header (first 16 bytes of every archive)
USB_ARC_HDR_SIZE equ 16
; archive record layout (one per filesystem node, pre-order/parent-first)
USB_REC_TYPE    equ 0      ; db  - 1=folder, 2=file
USB_REC_PARENT  equ 1      ; dw  - local index of parent record, 0xFFFF = archive root
USB_REC_NAME    equ 3      ; NAME_LEN bytes, null-padded
USB_REC_CLEN    equ 3+NAME_LEN         ; dw - content length (files only)
USB_REC_CONTENT equ 3+NAME_LEN+2       ; CONTENT_LEN bytes, null-padded
USB_REC_SIZE    equ 3+NAME_LEN+2+CONTENT_LEN

; ============================================================
kernel_entry:
    cli
    mov rsp, 0x9F000

    ; boot.asm only had room (512-byte sector) to identity-map the first
    ; 64MB. That's not enough for acpi_shutdown's ACPI table walk later -
    ; firmware can put the FADT/DSDT well above 64MB (e.g. ~127MB on a
    ; 128MB guest) - so extend the map to 4GB right away, before anything
    ; else runs. See expand_identity_map below for details.
    call expand_identity_map

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
        call hist_push
    
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

    ; Tokenize and dispatch the segment
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
    je .chain_skip

    call dispatch

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
    je .chain_end

    call dispatch

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

    ; Tokenize the segment
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

    ; Skip empty commands
    cmp byte [cmd_buf], 0
    je .rr_chain_skip

    ; Save rr_content_ptr and proc_cur_slot before dispatch
    push qword [rr_content_ptr]
    movzx rax, byte [proc_cur_slot]
    push rax
    call dispatch
    pop rax
    mov [proc_cur_slot], al
    pop qword [rr_content_ptr]

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
    je .rr_chain_end

    push qword [rr_content_ptr]
    movzx rax, byte [proc_cur_slot]
    push rax
    call dispatch
    pop rax
    mov [proc_cur_slot], al
    pop qword [rr_content_ptr]

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
    mov rdi, str_usbinfo
    call str_eq
    cmp al, 1
    je cmd_usbinfo

    mov rsi, cmd_buf
    mov rdi, str_usbdisk
    call str_eq
    cmp al, 1
    je cmd_usbdisk

    mov rsi, cmd_buf
    mov rdi, str_usb
    call str_eq
    cmp al, 1
    je cmd_usb

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
cmd_help:
    mov rsi, help_text
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
    call fs_delete_tree          ; recurses for folders, deletes a single node for files
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
;  USB STACK - PHASE 1: PCI bus enumeration
;  Finds a UHCI USB host controller so later phases can drive it.
;  Only bus 0 is scanned for now (every USB controller QEMU exposes, and
;  the vast majority on real desktop hardware, lives there); scanning PCI
;  bridges down into other buses is a straightforward extension for later
;  if a real machine needs it.
; ============================================================

; hex_to_str: rax=value, rcx=number of hex digits to print, rdi=buffer.
; Writes rcx uppercase hex digits (zero-padded) + null terminator.
hex_to_str:
    push rax
    push rbx
    push rcx
    push rsi
    mov rsi, rdi
    add rsi, rcx
    mov byte [rsi], 0
.htz_loop:
    dec rsi
    mov rbx, rax
    and rbx, 0xF
    cmp rbx, 10
    jl .htz_digit
    add rbx, 'A'-10
    jmp .htz_store
.htz_digit:
    add rbx, '0'
.htz_store:
    mov [rsi], bl
    shr rax, 4
    dec rcx
    jnz .htz_loop
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; pci_config_read_dword: rdi=bus, rsi=device, rdx=function, rcx=offset
; (offset need not be pre-aligned; low 2 bits are masked off).
; Returns: eax = the dword read from PCI config space.
; Uses the standard CONFIG_ADDRESS/CONFIG_DATA I/O ports (0xCF8/0xCFC),
; which work identically in real, protected, and long mode.
pci_config_read_dword:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov eax, 0x80000000
    mov ebx, edi
    and ebx, 0xFF
    shl ebx, 16
    or eax, ebx
    mov ebx, esi
    and ebx, 0x1F
    shl ebx, 11
    or eax, ebx
    mov ebx, edx
    and ebx, 0x07
    shl ebx, 8
    or eax, ebx
    mov ebx, ecx
    and ebx, 0xFC
    or eax, ebx

    mov dx, 0x0CF8
    out dx, eax
    mov dx, 0x0CFC
    in eax, dx

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; pci_report_device: r15=device index, r13=function index (bus fixed at 0).
; Prints the device's vendor/device IDs; if it's a UHCI USB controller,
; also records its I/O base (BAR4) into usb_uhci_* for later phases.
pci_report_device:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rdi, 0
    mov rsi, r15
    mov rdx, r13
    mov rcx, 0
    call pci_config_read_dword
    mov [pci_tmp_vendev], eax

    mov rdi, 0
    mov rsi, r15
    mov rdx, r13
    mov rcx, 0x08
    call pci_config_read_dword
    mov [pci_tmp_class], eax

    mov rsi, msg_pci_dev
    mov al, ATTR_NORMAL
    call print_string_attr
    mov rax, r15
    mov rdi, hexbuf
    mov rcx, 2
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov rsi, msg_pci_func
    call print_string
    mov rax, r13
    mov rdi, hexbuf
    mov rcx, 1
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov rsi, msg_pci_vendor
    call print_string
    mov eax, [pci_tmp_vendev]
    and eax, 0xFFFF
    mov rdi, hexbuf
    mov rcx, 4
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov rsi, msg_pci_device
    call print_string
    mov eax, [pci_tmp_vendev]
    shr eax, 16
    mov rdi, hexbuf
    mov rcx, 4
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov rsi, newline_str
    call print_string

    ; class code lives in byte 3, subclass in byte 2, prog-if in byte 1
    ; of the dword read at config offset 0x08.
    mov eax, [pci_tmp_class]
    mov ebx, eax
    shr ebx, 24
    cmp ebx, 0x0C                  ; class 0x0C = serial bus controller
    jne .prd_done
    mov ebx, eax
    shr ebx, 16
    and ebx, 0xFF
    cmp ebx, 0x03                  ; subclass 0x03 = USB controller
    jne .prd_done

    mov ebx, eax
    shr ebx, 8
    and ebx, 0xFF                  ; prog-if: 0x00=UHCI 0x10=OHCI 0x20=EHCI 0x30=XHCI
    cmp ebx, 0x00
    jne .prd_not_uhci

    ; Only the first UHCI controller found gets used - real hardware can
    ; have several, but everything from here on (frame list, port state)
    ; assumes exactly one active controller.
    cmp byte [usb_uhci_found], 1
    je .prd_done

    mov rdi, 0
    mov rsi, r15
    mov rdx, r13
    mov rcx, 0x20                  ; BAR4 holds the UHCI I/O-space base
    call pci_config_read_dword
    and eax, 0xFFFC                ; clear the I/O-space/reserved low bits
    mov [usb_uhci_io_base], ax
    mov byte [usb_uhci_bus], 0
    mov [usb_uhci_dev], r15b
    mov [usb_uhci_func], r13b
    mov byte [usb_uhci_found], 1

    mov rsi, msg_uhci_found
    mov al, ATTR_NORMAL
    call print_string_attr
    movzx eax, word [usb_uhci_io_base]
    mov rdi, hexbuf
    mov rcx, 4
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov rsi, newline_str
    call print_string

    call uhci_init                 ; bring the controller up + report ports
    jmp .prd_done

.prd_not_uhci:
    mov rsi, msg_usb_other
    mov al, ATTR_NORMAL
    call print_string_attr

.prd_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; cmd_dscan: scan PCI bus 0, device 0..31 (all functions on multi-function
; devices), report every device found, and flag the first UHCI USB host
; controller for the mount phase to use.
cmd_dscan:
    mov rsi, msg_dscan_header
    mov al, ATTR_NORMAL
    call print_string_attr
    mov byte [usb_uhci_found], 0

    xor r15, r15                   ; r15 = device index 0..31
.dsc_dev_loop:
    cmp r15, 32
    jae .dsc_dev_done

    mov rdi, 0
    mov rsi, r15
    mov rdx, 0
    mov rcx, 0
    call pci_config_read_dword
    cmp eax, 0xFFFFFFFF
    je .dsc_next_dev                ; nothing at function 0 -> device absent

    ; header type byte (offset 0x0C dword, byte 2) tells us whether to
    ; probe functions 1-7 too.
    mov rdi, 0
    mov rsi, r15
    mov rdx, 0
    mov rcx, 0x0C
    call pci_config_read_dword
    mov ebx, eax
    shr ebx, 16
    and ebx, 0xFF
    test ebx, 0x80
    jz .dsc_single_func

    xor r13, r13                    ; r13 = function index
.dsc_func_loop:
    cmp r13, 8
    jae .dsc_next_dev
    mov rdi, 0
    mov rsi, r15
    mov rdx, r13
    mov rcx, 0
    call pci_config_read_dword
    cmp eax, 0xFFFFFFFF
    je .dsc_func_next
    call pci_report_device
.dsc_func_next:
    inc r13
    jmp .dsc_func_loop

.dsc_single_func:
    xor r13, r13
    call pci_report_device

.dsc_next_dev:
    inc r15
    jmp .dsc_dev_loop

.dsc_dev_done:
    cmp byte [usb_uhci_found], 1
    je .dsc_ret
    mov rsi, msg_dscan_none
    mov al, ATTR_ERROR
    call print_string_attr
.dsc_ret:
    ret

; ============================================================
;  USB STACK - PHASE 2: UHCI controller init + root hub port detection
; ============================================================

; UHCI I/O-space register offsets (relative to usb_uhci_io_base)
UHCI_USBCMD     equ 0x00
UHCI_USBSTS     equ 0x02
UHCI_FRNUM      equ 0x06
UHCI_FRBASEADD  equ 0x08
UHCI_PORTSC1    equ 0x10
UHCI_PORTSC2    equ 0x12

; USBCMD bits
UHCI_CMD_RS       equ 0x0001        ; run/stop
UHCI_CMD_HCRESET  equ 0x0002        ; host controller reset
UHCI_CMD_GRESET   equ 0x0004        ; global reset (resets attached devices)
UHCI_CMD_CF       equ 0x0040        ; configure flag
UHCI_CMD_MAXP     equ 0x0080        ; max packet (64 bytes for full-speed)

; PORTSC bits
UHCI_PORT_CCS     equ 0x0001        ; current connect status

; uhci_delay: crude fixed busy-wait, calibrated generously since there's
; no timer (PIT/HPET) driver yet - matches the bounded-poll style already
; used by the ATA driver (see ata_wait_bsy) rather than a real millisecond
; timer. UHCI's global-reset pulse needs to hold for a while (spec allows
; up to 10-50ms); this errs long rather than risk cutting it short.
UHCI_DELAY_SPINS equ 0x4000000
uhci_delay:
    push rcx
    mov rcx, UHCI_DELAY_SPINS
.spin:
    loop .spin
    pop rcx
    ret

; uhci_init: brings up the UHCI controller at usb_uhci_io_base and reports
; root hub port status. No parameters/return value - state goes into
; usb_uhci_ready and uhci_port1_status/uhci_port2_status for later phases.
uhci_init:
    push rax
    push rdx
    push r8

    movzx r8, word [usb_uhci_io_base]

    ; ---- global reset: pulses a reset signal out to attached devices ----
    mov dx, r8w
    add dx, UHCI_USBCMD
    mov ax, UHCI_CMD_GRESET
    out dx, ax
    call uhci_delay
    xor ax, ax
    out dx, ax                      ; clear GRESET

    ; ---- host controller reset: resets the HC's own internal state ----
    mov ax, UHCI_CMD_HCRESET
    out dx, ax
.hcreset_wait:
    in ax, dx
    test ax, UHCI_CMD_HCRESET
    jnz .hcreset_wait               ; hardware clears this bit when done

    ; ---- point the controller at an empty frame list ----
    ; Every entry has its Terminate bit (bit0) set, so the controller
    ; won't try to process any queue/transfer descriptors yet - that
    ; comes in a later phase once we're actually issuing transfers.
    mov dx, r8w
    add dx, UHCI_FRBASEADD
    mov eax, uhci_frame_list        ; physical == linear here (identity map)
    out dx, eax

    mov dx, r8w
    add dx, UHCI_FRNUM
    xor ax, ax
    out dx, ax

    ; ---- clear stale status bits (write-1-to-clear register) ----
    mov dx, r8w
    add dx, UHCI_USBSTS
    mov ax, 0xFFFF
    out dx, ax

    ; ---- start the controller running ----
    mov dx, r8w
    add dx, UHCI_USBCMD
    mov ax, UHCI_CMD_RS | UHCI_CMD_CF | UHCI_CMD_MAXP
    out dx, ax

    mov byte [usb_uhci_ready], 1
    mov rsi, msg_uhci_init_ok
    mov al, ATTR_NORMAL
    call print_string_attr

    ; ---- root hub port detection ----
    mov dx, r8w
    add dx, UHCI_PORTSC1
    in ax, dx
    mov [uhci_port1_status], ax
    test ax, UHCI_PORT_CCS
    jz .port1_empty
    mov rsi, msg_uhci_port1_device
    jmp .port1_report
.port1_empty:
    mov rsi, msg_uhci_port1_empty
.port1_report:
    mov al, ATTR_NORMAL
    call print_string_attr

    mov dx, r8w
    add dx, UHCI_PORTSC2
    in ax, dx
    mov [uhci_port2_status], ax
    test ax, UHCI_PORT_CCS
    jz .port2_empty
    mov rsi, msg_uhci_port2_device
    jmp .port2_report
.port2_empty:
    mov rsi, msg_uhci_port2_empty
.port2_report:
    mov al, ATTR_NORMAL
    call print_string_attr

    pop r8
    pop rdx
    pop rax
    ret

; ============================================================
;  USB STACK - PHASE 3: control transfers
;  Builds UHCI Transfer Descriptors (TDs) and a Queue Head (QH) to run a
;  standard three-stage USB control transfer (SETUP + optional DATA +
;  STATUS), then uses that primitive to move the device off the default
;  address (0) and read its device and configuration descriptors. TD/QH
;  pointers are physical addresses; this kernel is identity-mapped so
;  linear == physical, the same assumption uhci_frame_list already relies
;  on in Phase 2.
; ============================================================

; ---- UHCI TD token PIDs ----
UHCI_PID_SETUP  equ 0x2D
UHCI_PID_IN     equ 0x69
UHCI_PID_OUT    equ 0xE1

; ---- UHCI TD Control/Status dword bits ----
UHCI_TD_SPD      equ (1 << 29)     ; short packet ends the queue, not an error
UHCI_TD_CERR3    equ (3 << 27)     ; retry up to 3 times before giving up
UHCI_TD_ACTIVE   equ (1 << 23)
UHCI_TD_ERR_MASK equ 0x007E0000    ; bits 17-22: Bitstuff/CRC/NAK/Babble/Buffer/Stalled

; conservative EP0 packet size: the spec-guaranteed minimum for every
; full/low-speed control endpoint. A real driver would read the device's
; actual bMaxPacketSize0 and switch to it; we always use the safe minimum,
; which costs a few extra TDs on larger reads but works unconditionally.
UHCI_CTRL_MAXPKT  equ 8
UHCI_CTRL_TIMEOUT equ 0x200000     ; poll budget, ATA_TIMEOUT-style (see ata_wait_bsy)

; uhci_ctrl_transfer: runs one control transfer over EP0 using the fixed
; QH/TD pool. Caller fills in first:
;   usb_xfer_addr  - target device address (0 = default address)
;   usb_xfer_setup - 8-byte setup packet
;   usb_xfer_buf   - data-stage buffer pointer; ignored if usb_xfer_len=0
;   usb_xfer_len   - data-stage length in bytes (0 = no data stage)
;   usb_xfer_dir   - 1 = IN (device->host), 0 = OUT; ignored if len=0
; Returns al=1 on success, al=0 on failure (timeout or a TD error bit).
; On a successful IN transfer, the received bytes are at usb_xfer_buf.
uhci_ctrl_transfer:
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

    mov rsi, usb_xfer_setup
    mov rdi, uhci_setup_pkt
    mov rcx, 8
    rep movsb                       ; SETUP TD's buffer points at this copy

    ; ---- how many 8-byte data TDs does this transfer need? ----
    movzx r13, word [usb_xfer_len]
    xor r10, r10
    test r13, r13
    jz .uct_no_data_tds
    mov rax, r13
    add rax, UHCI_CTRL_MAXPKT - 1
    xor rdx, rdx
    mov rcx, UHCI_CTRL_MAXPKT
    div rcx                         ; rax = ceil(len / MAXPKT)
    mov r10, rax
.uct_no_data_tds:
    ; bail out rather than overrun the pool if a caller ever asks for more
    ; than it can hold (SETUP + data TDs + STATUS)
    mov rax, r10
    add rax, 2
    cmp rax, UHCI_MAX_TDS
    jbe .uct_size_ok
    xor al, al
    jmp .uct_ret
.uct_size_ok:

    lea r12, [uhci_td_pool + 16]    ; r12 = cursor, starts at TD #1

    ; ---- TD #0: SETUP stage (always present, always DATA0) ----
    mov rdi, uhci_td_pool
    mov eax, r12d
    or eax, 0x04                    ; Vf=1 (depth-first), Q=0, T=0
    mov [rdi], eax
    mov eax, UHCI_TD_ACTIVE | UHCI_TD_CERR3
    mov [rdi+4], eax
    movzx eax, byte [usb_xfer_addr]
    shl eax, 8
    or eax, UHCI_PID_SETUP          ; endpoint=0, toggle=DATA0 (both bits 0)
    mov ecx, 7                      ; MaxLen field = actual_len(8) - 1
    shl ecx, 21
    or eax, ecx
    mov [rdi+8], eax
    mov eax, uhci_setup_pkt
    mov [rdi+12], eax

    ; ---- data TDs (0 or more): alternate DATA1/DATA0, IN or OUT ----
    xor r8, r8                      ; data TD index
    mov r9, 1                       ; toggle, data stage starts at DATA1
    mov r11, [usb_xfer_buf]         ; buffer cursor
    movzx r13, word [usb_xfer_len]  ; bytes remaining
    test r10, r10
    jz .uct_data_tds_done
.uct_data_td_loop:
    cmp r8, r10
    jae .uct_data_tds_done

    mov r14, r13                    ; chunk length = min(remaining, MAXPKT)
    cmp r14, UHCI_CTRL_MAXPKT
    jbe .uct_chunk_ok
    mov r14, UHCI_CTRL_MAXPKT
.uct_chunk_ok:

    mov rdi, r12
    lea rax, [r12 + 16]              ; next TD - the next data TD, or the
    or eax, 0x04                     ; STATUS TD once the loop ends
    mov [rdi], eax

    mov eax, UHCI_TD_ACTIVE | UHCI_TD_CERR3 | UHCI_TD_SPD
    mov [rdi+4], eax

    movzx eax, byte [usb_xfer_addr]
    shl eax, 8
    cmp byte [usb_xfer_dir], 1
    je .uct_data_pid_in
    or eax, UHCI_PID_OUT
    jmp .uct_data_pid_set
.uct_data_pid_in:
    or eax, UHCI_PID_IN
.uct_data_pid_set:
    mov ecx, r9d
    shl ecx, 19
    or eax, ecx                      ; data toggle bit
    mov edx, r14d
    dec edx
    and edx, 0x7FF
    shl edx, 21
    or eax, edx                      ; MaxLen = chunk_len - 1
    mov [rdi+8], eax

    mov eax, r11d
    mov [rdi+12], eax

    add r11, r14
    sub r13, r14
    xor r9, 1                        ; flip toggle
    add r12, 16
    inc r8
    jmp .uct_data_td_loop
.uct_data_tds_done:

    ; ---- STATUS stage: zero-length, always DATA1, opposite direction of
    ; the data stage (or IN if there was no data stage at all) ----
    mov rdi, r12
    mov dword [rdi], 0x00000001      ; Terminate: nothing follows STATUS
    mov eax, UHCI_TD_ACTIVE | UHCI_TD_CERR3
    mov [rdi+4], eax
    movzx eax, byte [usb_xfer_addr]
    shl eax, 8
    test r10, r10
    jz .uct_status_in
    cmp byte [usb_xfer_dir], 1
    je .uct_status_out
.uct_status_in:
    or eax, UHCI_PID_IN
    jmp .uct_status_pid_set
.uct_status_out:
    or eax, UHCI_PID_OUT
.uct_status_pid_set:
    or eax, (1 << 19)                ; data toggle = DATA1
    mov ecx, 0x7FF                   ; MaxLen encoding for a 0-byte packet
    shl ecx, 21
    or eax, ecx
    mov [rdi+8], eax
    mov dword [rdi+12], 0            ; zero-length: buffer pointer unused

    ; ---- hand the chain to the controller ----
    mov dword [uhci_qh], 0x00000001  ; Head Link: unused, Terminate
    mov eax, uhci_td_pool            ; Element -> first TD (Q=0, T=0)
    mov [uhci_qh+4], eax

    ; splice the QH into every frame-list slot so it starts on the very
    ; next SOF regardless of the controller's current frame number; it
    ; gets unlinked again below once the transfer finishes (or times out).
    mov eax, uhci_qh
    or eax, 0x02                     ; Q=1: this pointer targets a QH
    mov rdi, uhci_frame_list
    mov rcx, 1024
.uct_link_loop:
    mov [rdi], eax
    add rdi, 4
    loop .uct_link_loop

    ; ---- poll for completion ----
    ; Hardware advances the QH's Element pointer past each TD as it
    ; completes successfully, leaving it at Terminate once the whole chain
    ; has run. An error (stall/timeout) clears a TD's Active bit without
    ; advancing the pointer, so we also watch every TD's error bits.
    mov rcx, UHCI_CTRL_TIMEOUT
.uct_poll:
    mov eax, [uhci_qh+4]
    test eax, 0x01
    jnz .uct_poll_done

    push rcx
    mov rdi, uhci_td_pool
    mov rcx, r10
    add rcx, 2                       ; SETUP + data TDs + STATUS
.uct_err_scan:
    mov eax, [rdi+4]
    test eax, UHCI_TD_ERR_MASK
    jnz .uct_err_found
    add rdi, 16
    loop .uct_err_scan
    pop rcx
    loop .uct_poll
    jmp .uct_timeout
.uct_err_found:
    pop rcx
    jmp .uct_fail

.uct_poll_done:
    ; one last sweep - covers the STATUS TD erroring right as the element
    ; pointer advanced past it
    mov rdi, uhci_td_pool
    mov rcx, r10
    add rcx, 2
.uct_final_scan:
    mov eax, [rdi+4]
    test eax, UHCI_TD_ERR_MASK
    jnz .uct_fail
    add rdi, 16
    loop .uct_final_scan
    jmp .uct_success

.uct_timeout:
.uct_fail:
    mov rdi, uhci_frame_list
    mov rcx, 1024
    mov eax, 1
.uct_unlink_fail:
    mov [rdi], eax
    add rdi, 4
    loop .uct_unlink_fail
    xor al, al
    jmp .uct_ret

.uct_success:
    mov rdi, uhci_frame_list
    mov rcx, 1024
    mov eax, 1
.uct_unlink_ok:
    mov [rdi], eax
    add rdi, 4
    loop .uct_unlink_ok
    mov al, 1

.uct_ret:
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
    ret

; usb_set_address: SET_ADDRESS(1), issued to the current default address
; (0). Per spec the device needs a short recovery window after the status
; stage before it responds at the new address; uhci_delay is generous
; enough to cover the required >=2ms. Returns al=1/0.
usb_set_address:
    push rdi

    mov byte [usb_xfer_addr], 0
    mov word [usb_xfer_len], 0

    mov rdi, usb_xfer_setup
    mov byte [rdi+0], 0x00           ; host->device, standard, device
    mov byte [rdi+1], 0x05           ; SET_ADDRESS
    mov byte [rdi+2], 1              ; wValue low = new address
    mov byte [rdi+3], 0
    mov byte [rdi+4], 0              ; wIndex = 0
    mov byte [rdi+5], 0
    mov byte [rdi+6], 0              ; wLength = 0
    mov byte [rdi+7], 0

    call uhci_ctrl_transfer
    cmp al, 1
    jne .usa_fail

    call uhci_delay
    mov byte [usb_dev_address], 1
    mov al, 1
    jmp .usa_ret
.usa_fail:
    xor al, al
.usa_ret:
    pop rdi
    ret

; usb_get_descriptor: standard GET_DESCRIPTOR request.
;   rdi = descriptor type (1=DEVICE, 2=CONFIGURATION, ...)
;   rsi = descriptor index
;   rdx = requested length in bytes
;   rcx = destination buffer
;   r8b = device address to target
; Returns al=1/0. On success, up to rdx bytes land in the buffer (fewer if
; the device replies with a short packet).
usb_get_descriptor:
    push rbx
    push rsi
    push rdi
    push rdx
    push rcx
    push r8

    mov [usb_xfer_addr], r8b
    mov [usb_xfer_buf], rcx
    mov [usb_xfer_len], dx
    mov byte [usb_xfer_dir], 1       ; IN

    mov rbx, usb_xfer_setup
    mov byte [rbx+0], 0x80           ; device->host, standard, device
    mov byte [rbx+1], 0x06           ; GET_DESCRIPTOR
    mov al, sil
    mov [rbx+2], al                  ; wValue low = index
    mov al, dil
    mov [rbx+3], al                  ; wValue high = type
    mov byte [rbx+4], 0              ; wIndex = 0
    mov byte [rbx+5], 0
    mov [rbx+6], dl                  ; wLength low
    mov [rbx+7], dh                  ; wLength high

    call uhci_ctrl_transfer

    pop r8
    pop rcx
    pop rdx
    pop rdi
    pop rsi
    pop rbx
    ret

; usb_parse_config_descriptor: walks usb_cfg_desc for the first interface
; whose bInterfaceClass is Mass Storage (0x08) and records its bulk IN/OUT
; endpoint numbers into usb_bulk_in_ep/usb_bulk_out_ep for Phase 4.
; Assumes usb_cfg_desc/usb_cfg_total_len were already filled in by a
; successful GET_DESCRIPTOR(CONFIGURATION, ...).
usb_parse_config_descriptor:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r9

    mov byte [usb_msc_iface_num], 0xFF
    mov byte [usb_bulk_in_ep], 0xFF
    mov byte [usb_bulk_out_ep], 0xFF

    movzx rcx, word [usb_cfg_total_len]
    cmp rcx, UHCI_CFG_BUFSZ
    jbe .upc_len_ok
    mov rcx, UHCI_CFG_BUFSZ           ; clamp to what we actually have
.upc_len_ok:
    cmp rcx, 9
    jbe .upc_ret                      ; nothing beyond the config header
    sub rcx, 9
    lea rsi, [usb_cfg_desc + 9]       ; first sub-descriptor
    xor bl, bl                        ; "currently inside our MSC interface?"

.upc_loop:
    cmp rcx, 2
    jb .upc_ret
    movzx r9, byte [rsi]               ; bLength
    test r9b, r9b
    jz .upc_ret                        ; malformed (0-length) - stop
    cmp r9, rcx
    ja .upc_ret                        ; descriptor claims to run past what we have

    movzx rdx, byte [rsi+1]            ; bDescriptorType
    cmp dl, 4                          ; INTERFACE
    je .upc_iface
    cmp dl, 5                          ; ENDPOINT
    je .upc_endpoint
    jmp .upc_next

.upc_iface:
    cmp byte [usb_msc_iface_num], 0xFF
    jne .upc_iface_other               ; already found our interface - ignore rest
    cmp byte [rsi+5], 0x08             ; bInterfaceClass == Mass Storage
    jne .upc_iface_other
    mov al, [rsi+2]
    mov [usb_msc_iface_num], al
    mov al, [rsi+5]
    mov [usb_msc_iface_class], al
    mov al, [rsi+6]
    mov [usb_msc_iface_subclass], al
    mov al, [rsi+7]
    mov [usb_msc_iface_protocol], al
    mov bl, 1
    jmp .upc_next
.upc_iface_other:
    xor bl, bl
    jmp .upc_next

.upc_endpoint:
    test bl, bl
    jz .upc_next
    mov al, [rsi+3]
    and al, 0x03
    cmp al, 0x02                       ; Bulk transfer type
    jne .upc_next
    mov al, [rsi+2]                    ; bEndpointAddress
    test al, 0x80
    jz .upc_ep_out
    and al, 0x0F
    mov [usb_bulk_in_ep], al
    jmp .upc_next
.upc_ep_out:
    and al, 0x0F
    mov [usb_bulk_out_ep], al

.upc_next:
    add rsi, r9
    sub rcx, r9
    jmp .upc_loop

.upc_ret:
    pop r9
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; usb_init_device: full Phase 3 sequence - address the device, read its
; device and configuration descriptors, and locate its mass-storage bulk
; endpoints. Requires uhci_init to have already run.
usb_init_device:
    call usb_set_address
    cmp al, 1
    jne .uid_addr_fail

    mov rsi, msg_usb_addr_ok
    mov al, ATTR_NORMAL
    call print_string_attr

    mov rdi, 1                         ; DEVICE descriptor
    mov rsi, 0
    mov rdx, 18
    mov rcx, usb_dev_desc
    movzx r8, byte [usb_dev_address]
    call usb_get_descriptor
    cmp al, 1
    jne .uid_desc_fail

    mov rsi, msg_usb_vendor
    mov al, ATTR_NORMAL
    call print_string_attr
    movzx eax, word [usb_dev_desc+8]   ; idVendor
    mov rdi, hexbuf
    mov rcx, 4
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov rsi, msg_usb_product
    call print_string
    movzx eax, word [usb_dev_desc+10]  ; idProduct
    mov rdi, hexbuf
    mov rcx, 4
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov rsi, newline_str
    call print_string

    ; a short packet (SPD) ends this early once the device's actual,
    ; usually-smaller, descriptor set has been delivered
    mov rdi, 2                         ; CONFIGURATION descriptor
    mov rsi, 0
    mov rdx, UHCI_CFG_BUFSZ
    mov rcx, usb_cfg_desc
    movzx r8, byte [usb_dev_address]
    call usb_get_descriptor
    cmp al, 1
    jne .uid_desc_fail

    movzx eax, word [usb_cfg_desc+2]   ; wTotalLength
    mov [usb_cfg_total_len], ax

    call usb_parse_config_descriptor

    ; the device stays in the Addressed state (EP0 only) until this is
    ; issued - required before either bulk endpoint will respond to
    ; anything Phase 4 sends it
    call usb_set_configuration
    cmp al, 1
    jne .uid_cfg_fail

    mov rsi, msg_usb_cfg_ok
    mov al, ATTR_NORMAL
    call print_string_attr

    cmp byte [usb_msc_iface_num], 0xFF
    je .uid_no_msc

    mov rsi, msg_usb_msc_found
    mov al, ATTR_NORMAL
    call print_string_attr

    mov rsi, msg_usb_bulk_in
    call print_string
    movzx eax, byte [usb_bulk_in_ep]
    mov rdi, hexbuf
    mov rcx, 2
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov rsi, msg_usb_bulk_out
    call print_string
    movzx eax, byte [usb_bulk_out_ep]
    mov rdi, hexbuf
    mov rcx, 2
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

.uid_no_msc:
    mov rsi, msg_usb_no_msc
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.uid_addr_fail:
    mov rsi, msg_usb_addr_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.uid_desc_fail:
    mov rsi, msg_usb_desc_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.uid_cfg_fail:
    mov rsi, msg_usb_cfg_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; cmd_usbinfo: shell entry point for Phase 3 - requires a prior 'dscan' to
; have found a UHCI controller with a device physically connected before
; attempting to address/enumerate it.
cmd_usbinfo:
    cmp byte [usb_uhci_found], 1
    je .ui_have_ctrl
    mov rsi, msg_usbinfo_no_ctrl
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.ui_have_ctrl:
    test word [uhci_port1_status], UHCI_PORT_CCS
    jnz .ui_go
    test word [uhci_port2_status], UHCI_PORT_CCS
    jnz .ui_go
    mov rsi, msg_usbinfo_no_dev
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.ui_go:
    call usb_init_device
    ret

; ============================================================
;  USB STACK - PHASE 4: bulk transfers + mass storage (BOT/SCSI)
;  Adds uhci_bulk_transfer, a bulk IN/OUT primitive with no SETUP/STATUS
;  stage that persists each endpoint's DATA0/DATA1 toggle across calls
;  the way real bulk endpoints require. On top of that, the USB Mass
;  Storage Bulk-Only Transport (Command Block Wrapper out, optional data
;  stage, Command Status Wrapper in) drives a handful of SCSI commands -
;  TEST UNIT READY, INQUIRY, READ CAPACITY(10), READ(10) - and the
;  'usbdisk' shell command strings them together as a smoke test of the
;  whole path.
;
;  Known simplification: on a data-stage transport failure inside
;  usb_msc_command, a real driver would run a Bulk-Only Mass Storage
;  Reset + Clear Halt on both endpoints before trusting anything else;
;  that recovery path isn't implemented here, so a wedged endpoint after
;  an error may need a fresh 'dscan'/'usbinfo' (which re-addresses and
;  re-configures the device) to recover. Same spirit as the fixed EP0
;  packet size flagged in Phase 3.
; ============================================================

UHCI_BULK_MAXPKT  equ 64            ; full-speed bulk endpoint max packet
UHCI_BULK_TIMEOUT equ 0x200000      ; same generous poll budget as control

; uhci_bulk_transfer: runs one bulk transfer (no SETUP/STATUS stage) over
; the shared TD pool/QH. Caller fills in first:
;   usb_bulk_ep   - target endpoint number (0-15)
;   usb_bulk_buf  - buffer pointer (linear==physical); ignored if len=0
;   usb_bulk_len  - length in bytes (0 = nothing to send/receive)
;   usb_bulk_dir  - 1 = IN (device->host), 0 = OUT
;   rdi           - pointer to the persisted toggle byte for this
;                    endpoint (usb_bulk_in_toggle / usb_bulk_out_toggle);
;                    read as the starting DATA0/DATA1 state and updated
;                    in place once the transfer completes successfully.
; Targets usb_dev_address. Returns al=1 on success, al=0 on failure
; (timeout or a TD error bit) - the toggle byte is left unchanged on
; failure, since the device's own toggle state after an error is
; unknown.
uhci_bulk_transfer:
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

    mov r15, rdi                    ; toggle-byte pointer, kept for later

    ; ---- how many MAXPKT-sized TDs does this transfer need? ----
    movzx r13, word [usb_bulk_len]
    xor r10, r10
    test r13, r13
    jz .ubt_no_tds
    mov rax, r13
    add rax, UHCI_BULK_MAXPKT - 1
    xor rdx, rdx
    mov rcx, UHCI_BULK_MAXPKT
    div rcx
    mov r10, rax
.ubt_no_tds:
    test r10, r10
    jnz .ubt_have_tds
    mov al, 1                       ; zero-length transfer: nothing to do
    jmp .ubt_ret
.ubt_have_tds:
    cmp r10, UHCI_MAX_TDS
    jbe .ubt_size_ok
    xor al, al
    jmp .ubt_ret
.ubt_size_ok:

    lea r12, [uhci_td_pool]         ; cursor - no SETUP TD ahead of it here
    xor r8, r8                      ; TD index
    movzx r9, byte [r15]            ; starting toggle
    mov r11, [usb_bulk_buf]         ; buffer cursor
    ; r13 already holds total remaining bytes

.ubt_td_loop:
    cmp r8, r10
    jae .ubt_tds_done

    mov r14, r13                    ; chunk length = min(remaining, MAXPKT)
    cmp r14, UHCI_BULK_MAXPKT
    jbe .ubt_chunk_ok
    mov r14, UHCI_BULK_MAXPKT
.ubt_chunk_ok:

    mov rdi, r12
    mov rax, r8
    inc rax
    cmp rax, r10
    jae .ubt_last_td
    lea rax, [r12 + 16]
    or eax, 0x04                    ; Vf=1 (depth-first), more TDs follow
    mov [rdi], eax
    jmp .ubt_link_set
.ubt_last_td:
    mov dword [rdi], 0x00000001     ; Terminate: this is the last TD
.ubt_link_set:

    mov eax, UHCI_TD_ACTIVE | UHCI_TD_CERR3 | UHCI_TD_SPD
    mov [rdi+4], eax

    movzx eax, byte [usb_dev_address]
    shl eax, 8
    movzx ecx, byte [usb_bulk_ep]
    and ecx, 0x0F
    shl ecx, 15
    or eax, ecx
    cmp byte [usb_bulk_dir], 1
    je .ubt_pid_in
    or eax, UHCI_PID_OUT
    jmp .ubt_pid_set
.ubt_pid_in:
    or eax, UHCI_PID_IN
.ubt_pid_set:
    mov ecx, r9d
    shl ecx, 19
    or eax, ecx                     ; data toggle bit
    mov edx, r14d
    dec edx
    and edx, 0x7FF
    shl edx, 21
    or eax, edx                     ; MaxLen = chunk_len - 1
    mov [rdi+8], eax

    mov eax, r11d
    mov [rdi+12], eax

    add r11, r14
    sub r13, r14
    xor r9, 1                       ; flip toggle
    add r12, 16
    inc r8
    jmp .ubt_td_loop
.ubt_tds_done:

    ; ---- hand the chain to the controller ----
    mov dword [uhci_qh], 0x00000001 ; Head Link: unused, Terminate
    mov eax, uhci_td_pool           ; Element -> first TD (Q=0, T=0)
    mov [uhci_qh+4], eax

    mov eax, uhci_qh
    or eax, 0x02                    ; Q=1: this pointer targets a QH
    mov rdi, uhci_frame_list
    mov rcx, 1024
.ubt_link_loop:
    mov [rdi], eax
    add rdi, 4
    loop .ubt_link_loop

    ; ---- poll for completion (see uhci_ctrl_transfer for the rationale) ----
    mov rcx, UHCI_BULK_TIMEOUT
.ubt_poll:
    mov eax, [uhci_qh+4]
    test eax, 0x01
    jnz .ubt_poll_done

    push rcx
    mov rdi, uhci_td_pool
    mov rcx, r10
.ubt_err_scan:
    mov eax, [rdi+4]
    test eax, UHCI_TD_ERR_MASK
    jnz .ubt_err_found
    add rdi, 16
    loop .ubt_err_scan
    pop rcx
    loop .ubt_poll
    jmp .ubt_timeout
.ubt_err_found:
    pop rcx
    jmp .ubt_fail

.ubt_poll_done:
    mov rdi, uhci_td_pool
    mov rcx, r10
.ubt_final_scan:
    mov eax, [rdi+4]
    test eax, UHCI_TD_ERR_MASK
    jnz .ubt_fail
    add rdi, 16
    loop .ubt_final_scan
    jmp .ubt_success

.ubt_timeout:
.ubt_fail:
    mov rdi, uhci_frame_list
    mov rcx, 1024
    mov eax, 1
.ubt_unlink_fail:
    mov [rdi], eax
    add rdi, 4
    loop .ubt_unlink_fail
    xor al, al
    jmp .ubt_ret

.ubt_success:
    mov rdi, uhci_frame_list
    mov rcx, 1024
    mov eax, 1
.ubt_unlink_ok:
    mov [rdi], eax
    add rdi, 4
    loop .ubt_unlink_ok
    mov [r15], r9b                  ; persist toggle for the next call
    mov al, 1

.ubt_ret:
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
    ret

; usb_set_configuration: SET_CONFIGURATION(bConfigurationValue) - moves
; the device from Addressed into Configured state, which every real USB
; device requires before any endpoint other than EP0 (i.e. the bulk
; endpoints this phase needs) will respond. Assumes usb_cfg_desc already
; holds a successfully-read configuration descriptor. Resets both bulk
; toggle-tracking bytes to DATA0 on success, matching what SetConfiguration
; does to the device's own endpoint state. Returns al=1/0.
usb_set_configuration:
    push rdi

    movzx eax, byte [usb_dev_address]
    mov [usb_xfer_addr], al
    mov word [usb_xfer_len], 0

    mov rdi, usb_xfer_setup
    mov byte [rdi+0], 0x00          ; host->device, standard, device
    mov byte [rdi+1], 0x09          ; SET_CONFIGURATION
    mov al, [usb_cfg_desc+5]        ; bConfigurationValue
    mov [rdi+2], al
    mov byte [rdi+3], 0
    mov byte [rdi+4], 0
    mov byte [rdi+5], 0
    mov byte [rdi+6], 0
    mov byte [rdi+7], 0

    call uhci_ctrl_transfer
    cmp al, 1
    jne .usc_ret

    mov byte [usb_bulk_in_toggle], 0
    mov byte [usb_bulk_out_toggle], 0

.usc_ret:
    pop rdi
    ret

; usb_msc_command: runs one SCSI command over the USB Mass Storage
; Bulk-Only Transport (CBW -> optional data stage -> CSW). Caller
; supplies:
;   rsi - pointer to the CDB bytes (copied into the CBW, up to 16)
;   rcx - CDB length in bytes (6 or 10 for everything used here)
;   rdx - data-stage length in bytes (0 = no data stage)
;   rdi - data-stage buffer (linear==physical)
;   r8b - 1 = IN (device->host), 0 = OUT; ignored if rdx=0
; Targets usb_dev_address/usb_bulk_in_ep/usb_bulk_out_ep. Returns al=1 on
; a matching, successful (bCSWStatus==0) CSW; al=0 on any transport
; failure, a signature/tag mismatch, or a non-zero CSW status.
usb_msc_command:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    mov [usb_msc_data_dir], r8b     ; save direction (r8b) before r8 reused
    mov r9, rdi                     ; stash data-stage buffer pointer
    mov r8, rcx                     ; stash CDB length
    mov [usb_msc_data_len], dx      ; stash data-stage length

    ; ---- zero and build the CBW ----
    mov rdi, usb_msc_cbw
    xor eax, eax
    mov rcx, 31
    rep stosb

    mov byte [usb_msc_cbw+0], 0x55
    mov byte [usb_msc_cbw+1], 0x53
    mov byte [usb_msc_cbw+2], 0x42
    mov byte [usb_msc_cbw+3], 0x43  ; dCBWSignature = "USBC"

    mov eax, [usb_msc_cur_tag]
    mov [usb_msc_cbw+4], eax
    mov [usb_msc_last_tag], eax
    inc dword [usb_msc_cur_tag]

    movzx eax, word [usb_msc_data_len]
    mov [usb_msc_cbw+8], eax        ; dCBWDataTransferLength

    mov al, 0x80
    cmp byte [usb_msc_data_dir], 1
    je .umc_flags_set
    xor al, al
.umc_flags_set:
    mov [usb_msc_cbw+12], al        ; bmCBWFlags
    mov byte [usb_msc_cbw+13], 0    ; bCBWLUN
    mov [usb_msc_cbw+14], r8b       ; bCBWCBLength

    lea rdi, [usb_msc_cbw+15]
    mov rcx, r8
    cmp rcx, 16
    jbe .umc_cdblen_ok
    mov rcx, 16
.umc_cdblen_ok:
    rep movsb                       ; rsi still points at caller's CDB

    ; ---- send the CBW (bulk OUT) ----
    movzx eax, byte [usb_bulk_out_ep]
    mov [usb_bulk_ep], al
    mov rax, usb_msc_cbw
    mov [usb_bulk_buf], rax
    mov word [usb_bulk_len], 31
    mov byte [usb_bulk_dir], 0
    mov rdi, usb_bulk_out_toggle
    call uhci_bulk_transfer
    cmp al, 1
    je .umc_cbw_ok
    xor al, al
    jmp .umc_ret
.umc_cbw_ok:

    ; ---- optional data stage ----
    movzx rax, word [usb_msc_data_len]
    test rax, rax
    jz .umc_data_done
    cmp byte [usb_msc_data_dir], 1
    jne .umc_data_out
    movzx eax, byte [usb_bulk_in_ep]
    mov [usb_bulk_ep], al
    mov byte [usb_bulk_dir], 1
    mov rdi, usb_bulk_in_toggle
    jmp .umc_data_go
.umc_data_out:
    movzx eax, byte [usb_bulk_out_ep]
    mov [usb_bulk_ep], al
    mov byte [usb_bulk_dir], 0
    mov rdi, usb_bulk_out_toggle
.umc_data_go:
    mov [usb_bulk_buf], r9
    mov ax, [usb_msc_data_len]
    mov [usb_bulk_len], ax
    call uhci_bulk_transfer
    ; on failure here a real driver would run Bulk-Only Mass Storage Reset
    ; + Clear Halt before trusting the CSW - see the Phase 4 header comment
.umc_data_done:

    ; ---- read the CSW (bulk IN) ----
    movzx eax, byte [usb_bulk_in_ep]
    mov [usb_bulk_ep], al
    mov rax, usb_msc_csw
    mov [usb_bulk_buf], rax
    mov word [usb_bulk_len], 13
    mov byte [usb_bulk_dir], 1
    mov rdi, usb_bulk_in_toggle
    call uhci_bulk_transfer
    cmp al, 1
    je .umc_csw_ok
    xor al, al
    jmp .umc_ret
.umc_csw_ok:

    cmp byte [usb_msc_csw+0], 0x55
    jne .umc_bad
    cmp byte [usb_msc_csw+1], 0x53
    jne .umc_bad
    cmp byte [usb_msc_csw+2], 0x42
    jne .umc_bad
    cmp byte [usb_msc_csw+3], 0x53
    jne .umc_bad                    ; dCSWSignature != "USBS"
    mov eax, [usb_msc_csw+4]
    cmp eax, [usb_msc_last_tag]
    jne .umc_bad                    ; tag mismatch - stale/mismatched CSW
    cmp byte [usb_msc_csw+12], 0
    jne .umc_bad                    ; bCSWStatus != 0
    mov al, 1
    jmp .umc_ret
.umc_bad:
    xor al, al

.umc_ret:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; usb_msc_test_unit_ready: SCSI TEST UNIT READY (6-byte CDB, no data
; stage). Returns al=1 if the device reports ready, al=0 otherwise
; (including any transport failure).
usb_msc_test_unit_ready:
    push rsi
    push rcx
    push rdx
    push rdi
    push r8

    mov rdi, usb_msc_cdb
    xor eax, eax
    mov rcx, 16
    rep stosb                       ; opcode 0x00 = TEST UNIT READY

    mov rsi, usb_msc_cdb
    mov rcx, 6
    xor rdx, rdx                    ; no data stage
    xor rdi, rdi
    xor r8, r8
    call usb_msc_command

    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rsi
    ret

; usb_msc_inquiry: SCSI INQUIRY, 36-byte data stage into
; usb_msc_inquiry_buf. Returns al=1/0.
usb_msc_inquiry:
    push rsi
    push rcx
    push rdx
    push rdi
    push r8

    mov rdi, usb_msc_cdb
    xor eax, eax
    mov rcx, 16
    rep stosb
    mov byte [usb_msc_cdb+0], 0x12  ; INQUIRY
    mov byte [usb_msc_cdb+4], 36    ; allocation length

    mov rsi, usb_msc_cdb
    mov rcx, 6
    mov rdx, 36
    mov rdi, usb_msc_inquiry_buf
    mov r8, 1                       ; IN
    call usb_msc_command

    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rsi
    ret

; usb_msc_read_capacity: SCSI READ CAPACITY(10), 8-byte data stage into
; usb_msc_cap_buf (dLastLBA, dBlockSize - both big-endian on the wire).
; On success also fills usb_msc_block_count (=dLastLBA+1) and
; usb_msc_block_size, both converted to host byte order. Returns al=1/0.
usb_msc_read_capacity:
    push rsi
    push rcx
    push rdx
    push rdi
    push r8

    mov rdi, usb_msc_cdb
    xor eax, eax
    mov rcx, 16
    rep stosb
    mov byte [usb_msc_cdb+0], 0x25  ; READ CAPACITY (10)

    mov rsi, usb_msc_cdb
    mov rcx, 10
    mov rdx, 8
    mov rdi, usb_msc_cap_buf
    mov r8, 1                       ; IN
    call usb_msc_command
    cmp al, 1
    jne .urc_ret

    mov eax, [usb_msc_cap_buf]
    bswap eax
    inc eax                         ; dLastLBA -> total block count
    mov [usb_msc_block_count], eax

    mov eax, [usb_msc_cap_buf+4]
    bswap eax
    mov [usb_msc_block_size], eax

    mov al, 1
.urc_ret:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rsi
    ret

; usb_msc_read10: SCSI READ(10). rax = starting LBA, rdi = destination
; buffer, rdx = number of blocks to read. Block size is
; usb_msc_block_size if READ CAPACITY has already run and found one,
; else the 512-byte default nearly every USB flash drive uses. Callers
; here only ever ask for one block at a time, which keeps the data
; stage's TD count well under UHCI_MAX_TDS (see uhci_bulk_transfer).
; Returns al=1/0.
usb_msc_read10:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    mov r9, rdi                     ; destination buffer
    mov ebx, eax                    ; LBA
    mov r8, rdx                     ; block count

    mov rdi, usb_msc_cdb
    xor eax, eax
    mov rcx, 16
    rep stosb
    mov byte [usb_msc_cdb+0], 0x28  ; READ(10)
    mov eax, ebx
    bswap eax
    mov [usb_msc_cdb+2], eax        ; LBA, big-endian

    mov ax, r8w
    xchg al, ah                     ; transfer length, big-endian
    mov [usb_msc_cdb+7], ax

    mov eax, [usb_msc_block_size]
    test eax, eax
    jnz .ur10_have_bs
    mov eax, 512
.ur10_have_bs:
    imul eax, r8d
    mov edx, eax                    ; total data-stage length in bytes

    mov rsi, usb_msc_cdb
    mov rcx, 10
    mov rdi, r9
    mov r8, 1                       ; IN
    call usb_msc_command

    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; usb_msc_write10: SCSI WRITE(10). rax = starting LBA, rsi = source buffer,
; rdx = number of blocks to write. Mirrors usb_msc_read10 but with the
; data stage in the OUT direction and CDB opcode 0x2A. Returns al=1/0.
usb_msc_write10:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    mov r9, rsi                     ; source buffer
    mov ebx, eax                    ; LBA
    mov r8, rdx                     ; block count

    mov rdi, usb_msc_cdb
    xor eax, eax
    mov rcx, 16
    rep stosb
    mov byte [usb_msc_cdb+0], 0x2A  ; WRITE(10)
    mov eax, ebx
    bswap eax
    mov [usb_msc_cdb+2], eax        ; LBA, big-endian

    mov ax, r8w
    xchg al, ah                     ; transfer length, big-endian
    mov [usb_msc_cdb+7], ax

    mov eax, [usb_msc_block_size]
    test eax, eax
    jnz .uw10_have_bs
    mov eax, 512
.uw10_have_bs:
    imul eax, r8d
    mov edx, eax                    ; total data-stage length in bytes

    mov rsi, usb_msc_cdb
    mov rcx, 10
    mov rdi, r9                     ; usb_msc_command's OUT data comes from rdi
    mov r8, 0                       ; OUT
    call usb_msc_command

    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; usb_read_sector: rax=LBA, rdi=512-byte destination buffer. al=1/0.
usb_read_sector:
    push rdx
    mov rdx, 1
    call usb_msc_read10
    pop rdx
    ret

; usb_write_sector: rax=LBA, rsi=512-byte source buffer. al=1/0.
usb_write_sector:
    push rdx
    mov rdx, 1
    call usb_msc_write10
    pop rdx
    ret

; print_raw_bytes: rsi=buffer, rcx=count, al=attribute. Prints raw bytes
; as characters with no null terminator required - used for fixed-width
; ASCII fields like SCSI INQUIRY's vendor/product strings.
print_raw_bytes:
    push rax
    push rbx
    push rcx
    push rsi
    mov bl, al
    test rcx, rcx
    jz .prb_done
.prb_loop:
    mov al, [rsi]
    push rbx
    call putchar
    pop rbx
    inc rsi
    loop .prb_loop
.prb_done:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; cmd_usbdisk: shell entry point for Phase 4 - runs TEST UNIT READY,
; INQUIRY, READ CAPACITY(10) and a one-block READ(10) against the
; mass-storage device usbinfo already enumerated and configured, as a
; smoke test for the bulk transfer engine and the BOT/SCSI layer above.
cmd_usbdisk:
    push r12

    cmp byte [usb_bulk_in_ep], 0xFF
    je .ud_no_msc
    cmp byte [usb_bulk_out_ep], 0xFF
    je .ud_no_msc
    jmp .ud_go
.ud_no_msc:
    mov rsi, msg_usbdisk_no_msc
    mov al, ATTR_ERROR
    call print_string_attr
    pop r12
    ret

.ud_go:
    call usb_msc_test_unit_ready
    cmp al, 1
    jne .ud_not_ready
    mov rsi, msg_usbdisk_ready
    mov al, ATTR_NORMAL
    call print_string_attr
    jmp .ud_inquiry
.ud_not_ready:
    mov rsi, msg_usbdisk_not_ready
    mov al, ATTR_ERROR
    call print_string_attr

.ud_inquiry:
    call usb_msc_inquiry
    cmp al, 1
    je .ud_inquiry_ok
    mov rsi, msg_usbdisk_inquiry_fail
    mov al, ATTR_ERROR
    call print_string_attr
    pop r12
    ret
.ud_inquiry_ok:
    mov rsi, msg_usbdisk_vendor
    mov al, ATTR_NORMAL
    call print_string_attr
    lea rsi, [usb_msc_inquiry_buf+8]
    mov rcx, 8
    mov al, ATTR_NORMAL
    call print_raw_bytes
    mov rsi, msg_usbdisk_product
    call print_string
    lea rsi, [usb_msc_inquiry_buf+16]
    mov rcx, 16
    mov al, ATTR_NORMAL
    call print_raw_bytes
    mov rsi, newline_str
    call print_string

    call usb_msc_read_capacity
    cmp al, 1
    je .ud_cap_ok
    mov rsi, msg_usbdisk_cap_fail
    mov al, ATTR_ERROR
    call print_string_attr
    pop r12
    ret
.ud_cap_ok:
    mov rsi, msg_usbdisk_blocks
    mov al, ATTR_NORMAL
    call print_string_attr
    mov eax, [usb_msc_block_count]
    mov rdi, hexbuf
    mov rcx, 8
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov rsi, msg_usbdisk_blocksize
    call print_string
    mov eax, [usb_msc_block_size]
    mov rdi, hexbuf
    mov rcx, 8
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov rsi, msg_usbdisk_bytes_each
    call print_string

    xor rax, rax                    ; LBA 0
    mov rdi, usb_msc_sector_buf
    mov rdx, 1                      ; one block
    call usb_msc_read10
    cmp al, 1
    je .ud_read_ok
    mov rsi, msg_usbdisk_read_fail
    mov al, ATTR_ERROR
    call print_string_attr
    pop r12
    ret
.ud_read_ok:
    mov rsi, msg_usbdisk_sector0
    mov al, ATTR_NORMAL
    call print_string_attr
    xor r12, r12
.ud_dump_loop:
    cmp r12, 16
    jae .ud_dump_done
    movzx eax, byte [usb_msc_sector_buf + r12]
    mov rdi, hexbuf
    mov rcx, 2
    call hex_to_str
    mov rsi, hexbuf
    call print_string
    mov al, ' '
    mov bl, ATTR_NORMAL
    call putchar
    inc r12
    jmp .ud_dump_loop
.ud_dump_done:
    mov rsi, newline_str
    call print_string
    pop r12
    ret

; ============================================================
;  USB STACK - PHASE 5: project transfer (the 'usb' command)
;  Not a general-purpose filesystem (no FAT/exFAT) - just a small fixed
;  layout (header + project table + fixed-size per-project archive slots)
;  for moving whole ShellyForever project folders between machines. Only
;  usb_read_sector/usb_write_sector below know about USB/SCSI; everything
;  above that works purely in terms of sectors, the same way fs_save/
;  fs_load only know about ata_read_sector/ata_write_sector.
; ============================================================

; usb_count_projects: scans the in-memory table -> al = number of entries
; with USB_ENT_FLAGS bit0 set.
usb_count_projects:
    push rbx
    push rcx
    push rdx
    xor rdx, rdx
    xor rcx, rcx
.ucp_loop:
    cmp rcx, USB_MAX_PROJECTS
    jae .ucp_done
    mov rbx, rcx
    imul rbx, USB_ENTRY_SIZE
    add rbx, usb_idx_table
    test byte [rbx + USB_ENT_FLAGS], 1
    jz .ucp_next
    inc rdx
.ucp_next:
    inc rcx
    jmp .ucp_loop
.ucp_done:
    mov rax, rdx
    pop rdx
    pop rcx
    pop rbx
    ret

; usb_find_project: rsi=name -> rax=table index or -1. Only matches
; entries with USB_ENT_FLAGS bit0 set.
usb_find_project:
    push rbx
    push rcx
    push rdi
    push rsi
    xor rcx, rcx
.ufp_loop:
    cmp rcx, USB_MAX_PROJECTS
    jae .ufp_notfound
    mov rbx, rcx
    imul rbx, USB_ENTRY_SIZE
    add rbx, usb_idx_table
    test byte [rbx + USB_ENT_FLAGS], 1
    jz .ufp_next
    pop rsi
    push rsi
    lea rdi, [rbx + USB_ENT_NAME]
    push rcx
    call str_eq
    pop rcx
    cmp al, 1
    je .ufp_found
.ufp_next:
    inc rcx
    jmp .ufp_loop
.ufp_found:
    mov rax, rcx
    jmp .ufp_out
.ufp_notfound:
    mov rax, -1
.ufp_out:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; usb_find_free_slot: rax = first table index with USB_ENT_FLAGS==0, or -1
; if all USB_MAX_PROJECTS slots are in use.
usb_find_free_slot:
    push rbx
    push rcx
    xor rcx, rcx
.uffs_loop:
    cmp rcx, USB_MAX_PROJECTS
    jae .uffs_full
    mov rbx, rcx
    imul rbx, USB_ENTRY_SIZE
    add rbx, usb_idx_table
    test byte [rbx + USB_ENT_FLAGS], 1
    jz .uffs_found
    inc rcx
    jmp .uffs_loop
.uffs_found:
    mov rax, rcx
    jmp .uffs_out
.uffs_full:
    mov rax, -1
.uffs_out:
    pop rcx
    pop rbx
    ret

; usb_load_index: reads the header sector (LBA 0) and, if its magic/
; version check out, the project table (LBA 1..2) too. If the magic is
; wrong (blank/foreign drive) this starts a fresh empty in-memory table
; instead of failing - the drive just hasn't been formatted for
; ShellyForever project storage yet, which 'usb export' will do on first
; write. Returns al=1 on success (including "fresh"), al=0 only on an
; actual sector-read failure.
usb_load_index:
    push rdi
    push rax
    push rcx
    mov rax, 0
    mov rdi, usb_idx_header
    call usb_read_sector
    cmp al, 1
    jne .uli_fail
    cmp byte [usb_idx_header+0], 'S'
    jne .uli_fresh
    cmp byte [usb_idx_header+1], 'F'
    jne .uli_fresh
    cmp byte [usb_idx_header+2], 'U'
    jne .uli_fresh
    cmp byte [usb_idx_header+3], 'S'
    jne .uli_fresh
    cmp byte [usb_idx_header+4], 1
    jne .uli_fresh

    mov rax, USB_TABLE_LBA
    mov rdi, usb_idx_table
    call usb_read_sector
    cmp al, 1
    jne .uli_fail
    mov rax, USB_TABLE_LBA+1
    lea rdi, [usb_idx_table+512]
    call usb_read_sector
    cmp al, 1
    jne .uli_fail
    mov al, 1
    jmp .uli_done
.uli_fresh:
    mov rdi, usb_idx_header
    xor eax, eax
    mov rcx, 512
    rep stosb
    mov rdi, usb_idx_table
    xor eax, eax
    mov rcx, USB_MAX_PROJECTS*USB_ENTRY_SIZE
    rep stosb
    mov al, 1
    jmp .uli_done
.uli_fail:
    xor al, al
.uli_done:
    pop rcx
    pop rax
    pop rdi
    ret

; usb_save_index: writes the in-memory header+table back to LBA 0..2.
; Returns al=1/0.
usb_save_index:
    push rdi
    push rsi
    push rax
    mov byte [usb_idx_header+0], 'S'
    mov byte [usb_idx_header+1], 'F'
    mov byte [usb_idx_header+2], 'U'
    mov byte [usb_idx_header+3], 'S'
    mov byte [usb_idx_header+4], 1
    call usb_count_projects
    mov [usb_idx_header+5], al

    mov rax, 0
    mov rsi, usb_idx_header
    call usb_write_sector
    cmp al, 1
    jne .usi_fail
    mov rax, USB_TABLE_LBA
    mov rsi, usb_idx_table
    call usb_write_sector
    cmp al, 1
    jne .usi_fail
    mov rax, USB_TABLE_LBA+1
    lea rsi, [usb_idx_table+512]
    call usb_write_sector
    cmp al, 1
    jne .usi_fail
    mov al, 1
    jmp .usi_done
.usi_fail:
    xor al, al
.usi_done:
    pop rax
    pop rsi
    pop rdi
    ret

; usb_archive_emit: recursively serializes a filesystem subtree into
; usb_archive_buf as it's walked (pre-order, parent always emitted before
; its children - see USB_REC_PARENT above).
; in: rax = node index (real fs node), rbx = this node's parent's LOCAL
;     archive index (0xFFFF for the project root itself)
usb_archive_emit:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    push r13
    push r14

    mov r12, rax                    ; node idx
    mov r13, rbx                    ; parent local index

    cmp byte [usb_archive_overflow], 1
    je .uae_out

    mov rax, [usb_archive_ptr]
    lea rdx, [rax + USB_REC_SIZE]
    mov rcx, usb_archive_buf + USB_PROJECT_SLOT_BYTES
    cmp rdx, rcx
    jbe .uae_cap_ok
    mov byte [usb_archive_overflow], 1
    jmp .uae_out
.uae_cap_ok:
    mov [usb_rec_base], rax
    movzx r14, word [usb_archive_count]
    inc word [usb_archive_count]

    mov rdi, [usb_rec_base]
    movzx eax, byte [node_type + r12]
    mov [rdi + USB_REC_TYPE], al
    mov [rdi + USB_REC_PARENT], r13w

    lea rdi, [rdi + USB_REC_NAME]
    push rdi
    mov rcx, NAME_LEN
    xor al, al
    rep stosb
    pop rdi
    mov rax, r12
    imul rax, NAME_LEN
    lea rsi, [node_name + rax]
    call str_copy

    movzx eax, byte [node_type + r12]
    cmp eax, 2
    jne .uae_no_content
    mov rax, r12
    imul rax, CONTENT_LEN
    lea rsi, [node_content + rax]
    call str_len                    ; rax=len, preserves rsi
    mov rdi, [usb_rec_base]
    mov [rdi + USB_REC_CLEN], ax
    lea rdi, [rdi + USB_REC_CONTENT]
    push rsi
    mov rcx, CONTENT_LEN
    xor al, al
    push rdi
    rep stosb
    pop rdi
    pop rsi
    call str_copy
    jmp .uae_content_done
.uae_no_content:
    mov rdi, [usb_rec_base]
    mov word [rdi + USB_REC_CLEN], 0
.uae_content_done:

    mov rax, [usb_rec_base]
    add rax, USB_REC_SIZE
    mov [usb_archive_ptr], rax

    cmp byte [node_type + r12], 1   ; only folders have children
    jne .uae_out
    xor r8, r8
.uae_childloop:
    cmp r8, MAX_NODES
    jae .uae_out
    cmp byte [node_type + r8], 0
    je .uae_childnext
    movzx r9, word [node_parent + r8*2]
    cmp r9, r12
    jne .uae_childnext
    cmp byte [usb_archive_overflow], 1
    je .uae_out
    mov rax, r8
    mov rbx, r14
    push r8
    call usb_archive_emit
    pop r8
.uae_childnext:
    inc r8
    jmp .uae_childloop
.uae_out:
    pop r14
    pop r13
    pop r12
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; cmd_usb: shell entry point. arg1_buf = subcommand, arg2_buf/arg3_buf =
; its arguments. Every subcommand needs an addressed, configured
; mass-storage device (i.e. 'dscan' then 'usbinfo' already run), same
; precondition as 'usbdisk'.
cmd_usb:
    cmp byte [usb_bulk_in_ep], 0xFF
    je .cu_no_device
    cmp byte [usb_bulk_out_ep], 0xFF
    jne .cu_have_device
.cu_no_device:
    mov rsi, msg_usb_no_device
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.cu_have_device:
    mov rsi, arg1_buf
    mov rdi, str_usb_list
    call str_eq
    cmp al, 1
    je cmd_usb_list

    mov rsi, arg1_buf
    mov rdi, str_usb_info
    call str_eq
    cmp al, 1
    je cmd_usb_info

    mov rsi, arg1_buf
    mov rdi, str_usb_export
    call str_eq
    cmp al, 1
    je cmd_usb_export

    mov rsi, arg1_buf
    mov rdi, str_usb_import
    call str_eq
    cmp al, 1
    je cmd_usb_import

    mov rsi, arg1_buf
    mov rdi, str_usb_delete
    call str_eq
    cmp al, 1
    je cmd_usb_delete

    mov rsi, arg1_buf
    mov rdi, str_usb_rename
    call str_eq
    cmp al, 1
    je cmd_usb_rename

    mov rsi, msg_usb_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret

cmd_usb_list:
    push r12
    push r13
    push r14
    push r15
    call usb_load_index
    cmp al, 1
    je .cul_ok
    mov rsi, msg_usb_read_fail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_list_exit
.cul_ok:
    mov rsi, newline_str
    call print_string
    xor r12, r12
    xor r13, r13                    ; r13 = how many printed
.cul_loop:
    cmp r12, USB_MAX_PROJECTS
    jae .cul_done
    mov rbx, r12
    imul rbx, USB_ENTRY_SIZE
    add rbx, usb_idx_table
    test byte [rbx + USB_ENT_FLAGS], 1
    jz .cul_next
    inc r13
    lea rsi, [rbx + USB_ENT_NAME]
    call print_string
    mov rsi, newline_str
    call print_string
.cul_next:
    inc r12
    jmp .cul_loop
.cul_done:
    cmp r13, 0
    jne .cul_ret
    mov rsi, msg_usb_none_found
    call print_string
.cul_ret:
    jmp .cmd_usb_list_exit

.cmd_usb_list_exit:
    pop r15
    pop r14
    pop r13
    pop r12
    ret
cmd_usb_info:
    call usb_load_index
    cmp al, 1
    je .cui_ok
    mov rsi, msg_usb_read_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.cui_ok:
    call usb_msc_inquiry
    cmp al, 1
    je .cui_inquiry_ok
    mov rsi, msg_usbdisk_inquiry_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.cui_inquiry_ok:
    mov rsi, msg_usb_info_vendor
    call print_string
    lea rsi, [usb_msc_inquiry_buf+8]
    mov rcx, 8
    mov al, ATTR_NORMAL
    call print_raw_bytes
    mov rsi, newline_str
    call print_string
    mov rsi, msg_usb_info_product
    call print_string
    lea rsi, [usb_msc_inquiry_buf+16]
    mov rcx, 16
    mov al, ATTR_NORMAL
    call print_raw_bytes
    mov rsi, newline_str
    call print_string

    call usb_msc_read_capacity
    cmp al, 1
    je .cui_cap_ok
    mov rsi, msg_usbdisk_cap_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.cui_cap_ok:
    mov rsi, msg_usb_info_capacity
    call print_string
    mov eax, [usb_msc_block_count]
    mov ebx, [usb_msc_block_size]
    mul ebx                         ; rax = total bytes (edx:eax, fits rax)
    shr rax, 20                     ; -> MB
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, msg_usb_info_mb
    call print_string

    mov rsi, msg_usb_info_projects
    call print_string
    call usb_count_projects
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

cmd_usb_export:
    push r12
    push r13
    push r14
    push r15
    cmp byte [arg2_buf], 0
    jne .cue_have_name
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_export_exit
.cue_have_name:
    call usb_load_index
    cmp al, 1
    je .cue_idx_ok
    mov rsi, msg_usb_read_fail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_export_exit
.cue_idx_ok:
    ; find the project folder locally (current-folder-only, like cpy/mov)
    mov rax, [cur_dir]
    mov rsi, arg2_buf
    mov r10, 1                      ; must be a folder
    call fs_find_child
    cmp rax, -1
    jne .cue_local_found
    mov rsi, msg_usb_no_project1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg2_buf
    call print_string
    mov rsi, msg_usb_no_project2
    call print_string
    jmp .cmd_usb_export_exit
.cue_local_found:
    mov r15, rax                    ; project's fs node index

    mov rsi, arg2_buf
    call usb_find_project
    cmp rax, -1
    je .cue_not_taken
    mov rsi, msg_usb_exists
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_export_exit
.cue_not_taken:
    call usb_find_free_slot
    cmp rax, -1
    jne .cue_have_slot
    mov rsi, msg_usb_full
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_export_exit
.cue_have_slot:
    mov r14, rax                    ; table slot index

    mov rsi, msg_usb_exporting
    call print_string

    mov rax, usb_archive_buf + USB_ARC_HDR_SIZE
    mov [usb_archive_ptr], rax
    mov word [usb_archive_count], 0
    mov byte [usb_archive_overflow], 0

    mov rax, r15
    mov rbx, 0xFFFF
    call usb_archive_emit

    cmp byte [usb_archive_overflow], 1
    jne .cue_fits
    mov rsi, msg_usb_full
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_export_exit
.cue_fits:
    mov byte [usb_archive_buf+0], 'S'
    mov byte [usb_archive_buf+1], 'F'
    mov byte [usb_archive_buf+2], 'P'
    mov byte [usb_archive_buf+3], 'A'
    mov byte [usb_archive_buf+4], 1
    mov byte [usb_archive_buf+5], 0
    mov ax, [usb_archive_count]
    mov [usb_archive_buf+6], ax
    mov qword [usb_archive_buf+8], 0

    mov rsi, msg_usb_creating_archive
    call print_string

    mov rax, [usb_archive_ptr]
    sub rax, usb_archive_buf
    mov r12, rax                    ; total archive bytes
    add rax, 511
    shr rax, 9
    mov r13, rax                    ; sector count

    mov rax, r14
    imul rax, USB_PROJECT_SLOT_SECTORS
    add rax, USB_DATA_START_LBA
    mov r15, rax                    ; starting LBA for this project's archive

    mov rsi, msg_usb_writing
    call print_string

    xor rbx, rbx                    ; sector index
.cue_write_loop:
    cmp rbx, r13
    jae .cue_write_done
    mov rax, r15
    add rax, rbx
    mov rsi, usb_archive_buf
    mov rcx, rbx
    shl rcx, 9
    add rsi, rcx
    call usb_write_sector
    cmp al, 1
    je .cue_write_next
    mov rsi, msg_usb_write_fail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_export_exit
.cue_write_next:
    inc rbx
    jmp .cue_write_loop
.cue_write_done:

    mov rbx, r14
    imul rbx, USB_ENTRY_SIZE
    add rbx, usb_idx_table
    push rdi
    lea rdi, [rbx + USB_ENT_NAME]
    push rcx
    mov rcx, NAME_LEN
    xor al, al
    rep stosb
    pop rcx
    pop rdi
    lea rdi, [rbx + USB_ENT_NAME]
    mov rsi, arg2_buf
    call str_copy
    mov eax, r15d
    mov [rbx + USB_ENT_LBA], eax
    mov eax, r12d
    mov [rbx + USB_ENT_SIZE], eax
    mov byte [rbx + USB_ENT_FLAGS], 1

    call usb_save_index
    cmp al, 1
    je .cue_saved
    mov rsi, msg_usb_write_fail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_export_exit
.cue_saved:
    mov rsi, msg_usb_done
    call print_string
    jmp .cmd_usb_export_exit

.cmd_usb_export_exit:
    pop r15
    pop r14
    pop r13
    pop r12
    ret
cmd_usb_import:
    push r12
    push r13
    push r14
    push r15
    cmp byte [arg2_buf], 0
    jne .cui2_have_name
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_import_exit
.cui2_have_name:
    call usb_load_index
    cmp al, 1
    je .cui2_idx_ok
    mov rsi, msg_usb_read_fail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_import_exit
.cui2_idx_ok:
    mov rsi, arg2_buf
    call usb_find_project
    cmp rax, -1
    jne .cui2_found
    mov rsi, msg_usb_no_project1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg2_buf
    call print_string
    mov rsi, msg_usb_no_project2
    call print_string
    jmp .cmd_usb_import_exit
.cui2_found:
    mov r14, rax                    ; table slot index

    mov rax, [cur_dir]
    mov rsi, arg2_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .cui2_dest_ok
    mov rsi, msg_usb_exists
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_import_exit
.cui2_dest_ok:
    mov rbx, r14
    imul rbx, USB_ENTRY_SIZE
    add rbx, usb_idx_table
    mov eax, [rbx + USB_ENT_LBA]
    mov r15, rax                    ; start LBA
    mov eax, [rbx + USB_ENT_SIZE]
    mov r12, rax                    ; archive size in bytes

    add rax, 511
    shr rax, 9
    mov r13, rax                    ; sector count

    mov rsi, msg_usb_creating_project
    call print_string

    xor rbx, rbx
.cui2_read_loop:
    cmp rbx, r13
    jae .cui2_read_done
    mov rax, r15
    add rax, rbx
    mov rdi, usb_archive_buf
    mov rcx, rbx
    shl rcx, 9
    add rdi, rcx
    call usb_read_sector
    cmp al, 1
    je .cui2_read_next
    mov rsi, msg_usb_read_fail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_import_exit
.cui2_read_next:
    inc rbx
    jmp .cui2_read_loop
.cui2_read_done:

    cmp byte [usb_archive_buf+0], 'S'
    jne .cui2_corrupt
    cmp byte [usb_archive_buf+1], 'F'
    jne .cui2_corrupt
    cmp byte [usb_archive_buf+2], 'P'
    jne .cui2_corrupt
    cmp byte [usb_archive_buf+3], 'A'
    jne .cui2_corrupt
    cmp byte [usb_archive_buf+4], 1
    jne .cui2_corrupt
    movzx r13, word [usb_archive_buf+6]     ; node count
    test r13, r13
    jz .cui2_corrupt
    cmp r13, MAX_NODES
    ja .cui2_corrupt
    jmp .cui2_ok
.cui2_corrupt:
    mov rsi, msg_usb_corrupt
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_import_exit
.cui2_ok:
    mov rsi, msg_usb_copying
    call print_string

    mov qword [usb_import_root_real], -1
    xor r12, r12                    ; record index 0..node_count-1
    mov rax, usb_archive_buf + USB_ARC_HDR_SIZE
    mov [usb_rec_base], rax
.cui2_node_loop:
    cmp r12, r13
    jae .cui2_import_done

    mov rdi, [usb_rec_base]
    movzx r9, byte [rdi + USB_REC_TYPE]     ; node type
    movzx r8, word [rdi + USB_REC_PARENT]   ; parent local idx

    cmp r8, 0xFFFF
    jne .cui2_lookup_parent
    mov rax, [cur_dir]
    jmp .cui2_have_parent
.cui2_lookup_parent:
    movzx rax, word [usb_local_map + r8*2]
.cui2_have_parent:
    mov r11, rax                    ; real parent idx

    lea rsi, [rdi + USB_REC_NAME]
    mov rax, r11
    mov r10, r9
    call fs_create_node
    cmp rax, -1
    jne .cui2_created
    jmp .cui2_import_fail
.cui2_created:
    mov [usb_local_map + r12*2], ax
    cmp r12, 0
    jne .cui2_not_root
    mov [usb_import_root_real], rax
.cui2_not_root:
    cmp r9, 2                       ; file? copy content
    jne .cui2_next_node
    mov rbx, rax
    imul rbx, CONTENT_LEN
    lea rdi, [node_content + rbx]
    mov [usb_tmp_dest], rdi
    mov rdi, [usb_rec_base]
    lea rsi, [rdi + USB_REC_CONTENT]
    mov rdi, [usb_tmp_dest]
    call str_copy
.cui2_next_node:
    mov rax, [usb_rec_base]
    add rax, USB_REC_SIZE
    mov [usb_rec_base], rax
    inc r12
    jmp .cui2_node_loop

.cui2_import_fail:
    cmp qword [usb_import_root_real], -1
    je .cui2_fail_msg
    mov rax, [usb_import_root_real]
    call fs_delete_tree
.cui2_fail_msg:
    mov rsi, msg_full
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_import_exit

.cui2_import_done:
    mov rsi, msg_usb_done
    call print_string
    jmp .cmd_usb_import_exit

.cmd_usb_import_exit:
    pop r15
    pop r14
    pop r13
    pop r12
    ret
cmd_usb_delete:
    push r12
    push r13
    push r14
    push r15
    cmp byte [arg2_buf], 0
    jne .cud_have_name
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_delete_exit
.cud_have_name:
    call usb_load_index
    cmp al, 1
    je .cud_idx_ok
    mov rsi, msg_usb_read_fail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_delete_exit
.cud_idx_ok:
    mov rsi, arg2_buf
    call usb_find_project
    cmp rax, -1
    jne .cud_found
    mov rsi, msg_usb_no_project1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg2_buf
    call print_string
    mov rsi, msg_usb_no_project2
    call print_string
    jmp .cmd_usb_delete_exit
.cud_found:
    mov rbx, rax
    imul rbx, USB_ENTRY_SIZE
    add rbx, usb_idx_table
    mov rdi, rbx
    push rcx
    mov rcx, USB_ENTRY_SIZE
    xor al, al
    rep stosb
    pop rcx
    call usb_save_index
    cmp al, 1
    je .cud_saved
    mov rsi, msg_usb_write_fail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_delete_exit
.cud_saved:
    mov rsi, msg_usb_deleted1
    call print_string
    mov rsi, arg2_buf
    call print_string
    mov rsi, msg_usb_deleted2
    call print_string
    jmp .cmd_usb_delete_exit

.cmd_usb_delete_exit:
    pop r15
    pop r14
    pop r13
    pop r12
    ret
cmd_usb_rename:
    push r12
    push r13
    push r14
    push r15
    cmp byte [arg2_buf], 0
    jne .cur_check2
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_rename_exit
.cur_check2:
    cmp byte [arg3_buf], 0
    jne .cur_have_args
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_rename_exit
.cur_have_args:
    mov rsi, arg3_buf
    call str_len
    cmp rax, NAME_LEN
    jae .cur_toolong
    call usb_load_index
    cmp al, 1
    je .cur_idx_ok
    mov rsi, msg_usb_read_fail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_rename_exit
.cur_idx_ok:
    mov rsi, arg2_buf
    call usb_find_project
    cmp rax, -1
    jne .cur_found
    mov rsi, msg_usb_no_project1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg2_buf
    call print_string
    mov rsi, msg_usb_no_project2
    call print_string
    jmp .cmd_usb_rename_exit
.cur_found:
    mov r14, rax
    mov rsi, arg3_buf
    call usb_find_project
    cmp rax, -1
    je .cur_new_free
    mov rsi, msg_usb_exists
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_rename_exit
.cur_new_free:
    mov rbx, r14
    imul rbx, USB_ENTRY_SIZE
    add rbx, usb_idx_table
    lea rdi, [rbx + USB_ENT_NAME]
    push rcx
    mov rcx, NAME_LEN
    xor al, al
    rep stosb
    pop rcx
    lea rdi, [rbx + USB_ENT_NAME]
    mov rsi, arg3_buf
    call str_copy
    call usb_save_index
    cmp al, 1
    je .cur_saved
    mov rsi, msg_usb_write_fail
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_rename_exit
.cur_saved:
    mov rsi, msg_usb_renamed1
    call print_string
    mov rsi, arg2_buf
    call print_string
    mov rsi, msg_usb_renamed2
    call print_string
    mov rsi, arg3_buf
    call print_string
    mov rsi, msg_usb_renamed3
    call print_string
    jmp .cmd_usb_rename_exit
.cur_toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cmd_usb_rename_exit

.cmd_usb_rename_exit:
    pop r15
    pop r14
    pop r13
    pop r12
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
    xor r9, r9
.loop:
    cmp r9, MAX_NODES
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
ata_wait_bsy:
    push rax
    push rdx
    push rcx
    mov rcx, ATA_TIMEOUT
    mov dx, 0x1F7
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
    mov dx, 0x1F7
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
    mov dx, 0x1F6
    mov rax, rbx
    shr rax, 24
    and al, 0x0F
    or al, 0xE0                  ; LBA mode, master drive
    out dx, al
    mov dx, 0x1F2
    mov al, 1                    ; sector count = 1
    out dx, al
    mov dx, 0x1F3
    mov al, bl
    out dx, al                   ; LBA[0:7]
    mov dx, 0x1F4
    mov rax, rbx
    shr rax, 8
    out dx, al                   ; LBA[8:15]
    mov dx, 0x1F5
    mov rax, rbx
    shr rax, 16
    out dx, al                   ; LBA[16:23]
    mov dx, 0x1F7
    mov al, 0x20                 ; READ SECTORS (with retry)
    out dx, al
    call ata_wait_bsy
    jc .fail
    call ata_wait_drq
    jc .fail
    mov dx, 0x1F0
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
    mov dx, 0x1F6
    mov rax, rbx
    shr rax, 24
    and al, 0x0F
    or al, 0xE0
    out dx, al
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    mov dx, 0x1F3
    mov al, bl
    out dx, al
    mov dx, 0x1F4
    mov rax, rbx
    shr rax, 8
    out dx, al
    mov dx, 0x1F5
    mov rax, rbx
    shr rax, 16
    out dx, al
    mov dx, 0x1F7
    mov al, 0x30                 ; WRITE SECTORS (with retry)
    out dx, al
    call ata_wait_bsy
    jc .fail
    call ata_wait_drq
    jc .fail
    mov dx, 0x1F0
    mov rcx, 256
.writeloop:
    mov ax, [rsi]
    out dx, ax
    add rsi, 2
    loop .writeloop
    call ata_wait_bsy
    jc .fail
    mov dx, 0x1F7
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

; fs_save: serialize node_type/node_parent/node_name/node_content (plus a
; small magic/version header) out to FS_LBA_START.. on disk.
; returns CF=0 on success, CF=1 if the disk isn't there/isn't responding.
fs_save:
    push rax
    push rsi
    push rcx
    cmp byte [fs_disk_available], 0
    je .fail                     ; already known-absent this session, don't retry
    mov byte [fs_disk_header+0], 'S'
    mov byte [fs_disk_header+1], 'F'
    mov byte [fs_disk_header+2], 'F'
    mov byte [fs_disk_header+3], 'S'
    mov byte [fs_disk_header+4], 1     ; format version
    mov byte [fs_disk_header+5], 0
    mov byte [fs_disk_header+6], 0
    mov byte [fs_disk_header+7], 0
    mov rax, FS_LBA_START
    lea rsi, [fs_disk_header]
    mov rcx, FS_SECTORS
.loop:
    push rax
    push rcx
    call ata_write_sector
    pop rcx
    pop rax
    jc .disk_gone
    add rsi, 512
    inc rax
    loop .loop
    pop rcx
    pop rsi
    pop rax
    clc
    ret
.disk_gone:
    mov byte [fs_disk_available], 0
.fail:
    pop rcx
    pop rsi
    pop rax
    stc
    ret

; fs_load: read the persisted region straight into the live fs structures;
; if the magic/version don't check out (blank disk, older format, etc.) or
; there's simply no disk responding at the legacy ATA ports (common on
; real hardware without a PATA/IDE controller, or booting off USB), fall
; back to fs_init for a fresh in-memory-only filesystem instead.
; sets fs_loaded_from_disk and fs_disk_available accordingly.
fs_load:
    push rax
    push rdi
    push rcx
    mov rax, FS_LBA_START
    lea rdi, [fs_disk_header]
    mov rcx, FS_SECTORS
.loop:
    push rax
    push rcx
    call ata_read_sector
    pop rcx
    pop rax
    jc .no_disk
    add rdi, 512
    inc rax
    loop .loop

    cmp byte [fs_disk_header+0], 'S'
    jne .invalid
    cmp byte [fs_disk_header+1], 'F'
    jne .invalid
    cmp byte [fs_disk_header+2], 'F'
    jne .invalid
    cmp byte [fs_disk_header+3], 'S'
    jne .invalid
    cmp byte [fs_disk_header+4], 1
    jne .invalid

    mov qword [cur_dir], 0
    mov byte [fs_loaded_from_disk], 1
    jmp .done
.invalid:
    call fs_init
    mov byte [fs_loaded_from_disk], 0
    jmp .done
.no_disk:
    mov byte [fs_disk_available], 0
    call fs_init
    mov byte [fs_loaded_from_disk], 0
.done:
    pop rcx
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
putchar:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi

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

    ; stash the top row (about to be scrolled off) into the scrollback
    ; ring so Ctrl+Up can bring it back later
    movzx rax, word [scrollback_write]
    imul rax, VGA_COLS*2
    mov rdi, scrollback_buf
    add rdi, rax
    mov rsi, VGA_BASE
    mov rcx, VGA_COLS
    rep movsw

    mov ax, [scrollback_write]
    inc ax
    and ax, SCROLLBACK_LINES-1
    mov [scrollback_write], ax

    cmp word [scrollback_count], SCROLLBACK_LINES
    jae .sb_capped
    inc word [scrollback_count]
.sb_capped:

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

; get_char: blocks until a key is pressed, returns ascii in al. Also
; recognizes the arrow keys (which arrive as an 0xE0-prefixed 2-byte
; "extended" scancode sequence) and Ctrl, returning them as one of the
; KEY_* virtual codes above rather than an ASCII byte - Up/Down are for
; command history recall, Ctrl+Up/Ctrl+Down are for output scrollback.
get_char:
    push rbx
.wait:
    in al, 0x64
    test al, 1
    jz .wait
    in al, 0x60
    mov bl, al

    cmp bl, 0xE0
    je .extended

    test bl, 0x80
    jnz .breakcode
    cmp bl, 0x2A
    je .setshift
    cmp bl, 0x36
    je .setshift
    cmp bl, 0x1D
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
    pop rbx
    ret
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

.extended:
    ; 0xE0 prefix seen - the byte that follows is the real code
.ext_wait:
    in al, 0x64
    test al, 1
    jz .ext_wait
    in al, 0x60
    mov bl, al

    test bl, 0x80
    jnz .ext_break

    cmp bl, 0x48                  ; up arrow, make code
    je .ext_up
    cmp bl, 0x50                  ; down arrow, make code
    je .ext_down
    cmp bl, 0x1D                  ; right ctrl, make code
    je .ctrl_make
    jmp .wait                     ; ignore any other extended key

.ext_break:
    and bl, 0x7F
    cmp bl, 0x1D                  ; right ctrl, break code
    je .ctrl_break
    jmp .wait

.ext_up:
    cmp byte [ctrl_state], 0
    je .plain_up
    mov al, KEY_CTRL_UP
    jmp .ext_have
.plain_up:
    mov al, KEY_UP
    jmp .ext_have
.ext_down:
    cmp byte [ctrl_state], 0
    je .plain_down
    mov al, KEY_CTRL_DOWN
    jmp .ext_have
.plain_down:
    mov al, KEY_DOWN
.ext_have:
    pop rbx
    ret

; read_line: rdi=buffer, rcx=max chars. Echoes to screen, handles
; backspace, terminates on Enter. Buffer is null terminated.
; Also handles Up/Down (recall previously entered lines from the
; history ring - see hist_push/hist_apply_line) and Ctrl+Up/Ctrl+Down
; (scroll the visible output back/forward through scrollback_buf).
; r11 = history nav depth for this call (0 = live editing, 1 = most
; recent entry, 2 = the one before that, etc).
read_line:
    push rax
    push rbx
    push rdi
    push rcx
    xor r8, r8
    mov r9, rdi
    mov r10, rcx
    xor r11, r11
.loop:
    call get_char

    cmp al, KEY_CTRL_UP
    je .ctrlup
    cmp al, KEY_CTRL_DOWN
    je .ctrldown

    ; any key other than Ctrl+Up/Ctrl+Down snaps back to the live view
    ; first, if we were showing a scrolled-back screen
    cmp word [scroll_offset], 0
    je .not_scrolled
    call scrollback_snap_live
.not_scrolled:

    cmp al, KEY_UP
    je .histup
    cmp al, KEY_DOWN
    je .histdown
    cmp al, 0x0D
    je .enter
    cmp al, 0x08
    je .bksp
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
.enter:
    mov byte [r9 + r8], 0
    mov al, 0x0A
    call putchar
    pop rcx
    pop rdi
    pop rbx
    pop rax
    ret

.histup:
    cmp word [hist_count], 0
    je .loop                          ; no history yet
    cmp r11, 0
    jne .histup_cont
    ; first Up this line - stash whatever's currently typed so Down
    ; can bring it back later
    mov byte [r9 + r8], 0
    mov rsi, r9
    mov rdi, hist_saved_line
    call str_copy
.histup_cont:
    movzx rax, word [hist_count]
    cmp r11, rax
    jae .loop                          ; already at the oldest entry
    inc r11
    mov ax, [hist_head]
    sub ax, r11w
    and ax, HIST_MAX-1
    movzx rcx, ax
    imul rcx, LINE_MAX
    mov rsi, hist_buf
    add rsi, rcx
    call hist_apply_line
    jmp .loop

.histdown:
    cmp r11, 0
    je .loop                           ; not browsing history
    dec r11
    cmp r11, 0
    jne .histdown_pick
    mov rsi, hist_saved_line
    call hist_apply_line
    jmp .loop
.histdown_pick:
    mov ax, [hist_head]
    sub ax, r11w
    and ax, HIST_MAX-1
    movzx rcx, ax
    imul rcx, LINE_MAX
    mov rsi, hist_buf
    add rsi, rcx
    call hist_apply_line
    jmp .loop

.ctrlup:
    cmp word [scroll_offset], 0
    jne .ctrlup_cont
    call scrollback_capture_live
.ctrlup_cont:
    mov ax, [scroll_offset]
    cmp ax, [scrollback_count]
    jae .loop                          ; already at the oldest scrollback line
    inc word [scroll_offset]
    call scrollback_render
    jmp .loop

.ctrldown:
    cmp word [scroll_offset], 0
    je .loop                           ; already live
    dec word [scroll_offset]
    call scrollback_render
    cmp word [scroll_offset], 0
    jne .loop
    mov al, [saved_cursor_row]
    mov [cursor_row], al
    mov al, [saved_cursor_col]
    mov [cursor_col], al
    call update_cursor
    jmp .loop

; hist_apply_line: replaces the line currently being edited with a new
; string - erases what's on screen, copies the new content into the
; line buffer, and re-prints it.
; in:  rsi = new content (null terminated), r8 = currently displayed
;      length, r9 = line buffer to write into.
; out: r8 = new length, r9's buffer updated, screen redrawn.
hist_apply_line:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
.hal_erase:
    cmp r8, 0
    je .hal_erase_done
    call do_backspace
    dec r8
    jmp .hal_erase
.hal_erase_done:
    mov rdi, r9
    call str_copy
    mov rsi, r9
    call str_len
    mov r8, rax
    mov rsi, r9
.hal_print:
    mov al, [rsi]
    cmp al, 0
    je .hal_done
    mov bl, ATTR_NORMAL
    call putchar
    inc rsi
    jmp .hal_print
.hal_done:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; hist_push: appends line_buf to the history ring, unless it's empty or
; identical to the most recently stored entry (avoids duplicate spam
; when a user just hits Enter on the same command repeatedly).
hist_push:
    push rax
    push rsi
    push rdi
    push rcx
    cmp byte [line_buf], 0
    je .hp_done
    cmp word [hist_count], 0
    je .hp_store
    mov ax, [hist_head]
    sub ax, 1
    and ax, HIST_MAX-1
    movzx rcx, ax
    imul rcx, LINE_MAX
    mov rsi, line_buf
    mov rdi, hist_buf
    add rdi, rcx
    call str_eq
    cmp al, 1
    je .hp_done
.hp_store:
    movzx rcx, word [hist_head]
    imul rcx, LINE_MAX
    mov rdi, hist_buf
    add rdi, rcx
    mov rsi, line_buf
    call str_copy
    mov ax, [hist_head]
    add ax, 1
    and ax, HIST_MAX-1
    mov [hist_head], ax
    cmp word [hist_count], HIST_MAX
    jae .hp_done
    inc word [hist_count]
.hp_done:
    pop rcx
    pop rdi
    pop rsi
    pop rax
    ret

; scrollback_capture_live: snapshots the current 25 on-screen rows and
; cursor position into live_snapshot/saved_cursor_*, so the real live
; view can be restored exactly once the user scrolls back down.
scrollback_capture_live:
    push rax
    push rcx
    push rsi
    push rdi
    mov rsi, VGA_BASE
    mov rdi, live_snapshot
    mov rcx, VGA_COLS*VGA_ROWS
    rep movsw
    mov al, [cursor_row]
    mov [saved_cursor_row], al
    mov al, [cursor_col]
    mov [saved_cursor_col], al
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; scrollback_render: redraws all 25 VGA rows for the current
; [scroll_offset] (0 = live bottom), pulling each row from either
; scrollback_buf (older content) or live_snapshot (the screen as it
; looked when the scrollback session began).
scrollback_render:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    xor rbx, rbx                       ; rbx = screen_row (0..24)
.sr_row:
    cmp rbx, VGA_ROWS
    jae .sr_done
    movzx rax, word [scrollback_count]
    mov rcx, rax                       ; rcx = scrollback_count
    movzx rdx, word [scroll_offset]
    sub rax, rdx
    add rax, rbx                       ; rax = base = count - offset + screen_row
    cmp rax, rcx
    jb .sr_from_scrollback
.sr_from_live:
    sub rax, rcx                       ; rax = live row index (0..24)
    imul rax, VGA_COLS*2
    mov rsi, live_snapshot
    add rsi, rax
    jmp .sr_copy
.sr_from_scrollback:
    movzx rdx, word [scrollback_write]
    sub rdx, rcx
    add rdx, rax
    and rdx, SCROLLBACK_LINES-1
    imul rdx, VGA_COLS*2
    mov rsi, scrollback_buf
    add rsi, rdx
.sr_copy:
    imul rdi, rbx, VGA_COLS*2
    add rdi, VGA_BASE
    mov rcx, VGA_COLS
    rep movsw
    inc rbx
    jmp .sr_row
.sr_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; scrollback_snap_live: jumps straight back to the live view (used when
; the user types/backspaces/enters while scrolled back - like a normal
; terminal, any activity snaps the view back to the bottom).
scrollback_snap_live:
    mov word [scroll_offset], 0
    call scrollback_render
    mov al, [saved_cursor_row]
    mov [cursor_row], al
    mov al, [saved_cursor_col]
    mov [cursor_col], al
    call update_cursor
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
ctrl_state:   db 0                   ; 1 while either Ctrl key is held
cur_dir:      dq 0
auth_valid:   db 0                   ; set by 'auth' command, checked by dangerous commands

; --- command history (Up/Down arrow) ---
hist_count: dw 0                     ; number of entries stored (caps at HIST_MAX)
hist_head:  dw 0                     ; ring index of the NEXT slot to write

; --- output scrollback (Ctrl+Up/Ctrl+Down) ---
scroll_offset:     dw 0              ; 0 = live view; N = N rows scrolled back
scrollback_write:  dw 0              ; ring index of the NEXT row to write
scrollback_count:  dw 0              ; rows stored so far (caps at SCROLLBACK_LINES)
saved_cursor_row:  db 0              ; cursor position captured when a
saved_cursor_col:  db 0              ; scrollback session begins

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
str_dscan:  db "dscan", 0
str_usbinfo: db "usbinfo", 0
str_usbdisk: db "usbdisk", 0
str_usb:     db "usb", 0
str_usb_list:   db "list", 0
str_usb_info:   db "info", 0
str_usb_export: db "export", 0
str_usb_import: db "import", 0
str_usb_delete: db "delete", 0
str_usb_rename: db "rename", 0
str_rmv_all: db "all", 0
str_force:  db "-force", 0
str_silent: db "-silent", 0
str_info:   db "-info", 0

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

; --- dscan / PCI messages ---
msg_dscan_header: db "Scanning PCI bus 0 for controllers...", 10, 0
msg_dscan_none:   db "No USB host controller found.", 10, 0
msg_pci_dev:      db "  dev ", 0
msg_pci_func:     db " func ", 0
msg_pci_vendor:   db " vendor=0x", 0
msg_pci_device:   db " device=0x", 0
msg_uhci_found:   db "    -> UHCI USB controller, I/O base 0x", 0
msg_usb_other:    db "    -> USB controller (not UHCI - not yet supported)", 10, 0
msg_uhci_init_ok: db "    -> UHCI controller reset and started.", 10, 0
msg_uhci_port1_device: db "    -> Port 1: device connected.", 10, 0
msg_uhci_port1_empty:  db "    -> Port 1: empty.", 10, 0
msg_uhci_port2_device: db "    -> Port 2: device connected.", 10, 0
msg_uhci_port2_empty:  db "    -> Port 2: empty.", 10, 0

; --- usbinfo / Phase 3 control-transfer messages ---
msg_usbinfo_no_ctrl: db "No UHCI controller found - run 'dscan' first.", 10, 0
msg_usbinfo_no_dev:  db "No device connected on either root hub port.", 10, 0
msg_usb_addr_ok:     db "    -> Device addressed (address 1).", 10, 0
msg_usb_addr_fail:   db "    -> SET_ADDRESS failed (no response / transfer error).", 10, 0
msg_usb_desc_fail:   db "    -> GET_DESCRIPTOR failed (no response / transfer error).", 10, 0
msg_usb_vendor:      db "    -> Vendor ID: 0x", 0
msg_usb_product:     db ", Product ID: 0x", 0
msg_usb_msc_found:   db "    -> Mass-storage interface found.", 10, 0
msg_usb_no_msc:      db "    -> No mass-storage interface in this configuration.", 10, 0
msg_usb_bulk_in:     db "    -> Bulk IN endpoint:  0x", 0
msg_usb_bulk_out:    db ", Bulk OUT endpoint: 0x", 0
msg_usb_cfg_fail:    db "    -> SET_CONFIGURATION failed (no response / transfer error).", 10, 0
msg_usb_cfg_ok:      db "    -> Device configured.", 10, 0

; --- usbdisk / Phase 4 bulk-transfer + BOT/SCSI messages ---
msg_usbdisk_no_msc:      db "usbdisk: run 'usbinfo' first - no mass-storage endpoints found.", 10, 0
msg_usbdisk_ready:       db "    -> TEST UNIT READY: device reports ready.", 10, 0
msg_usbdisk_not_ready:   db "    -> TEST UNIT READY: device not ready (continuing anyway).", 10, 0
msg_usbdisk_inquiry_fail: db "    -> INQUIRY failed (no response / transfer error).", 10, 0
msg_usbdisk_vendor:      db "    -> Vendor: ", 0
msg_usbdisk_product:     db ", Product: ", 0
msg_usbdisk_cap_fail:    db "    -> READ CAPACITY(10) failed (no response / transfer error).", 10, 0
msg_usbdisk_blocks:      db "    -> Capacity: 0x", 0
msg_usbdisk_blocksize:   db " blocks x 0x", 0
msg_usbdisk_bytes_each:  db " bytes each", 10, 0
msg_usbdisk_read_fail:   db "    -> READ(10) LBA 0 failed (no response / transfer error).", 10, 0
msg_usbdisk_sector0:     db "    -> First 16 bytes of LBA 0: ", 0

; --- 'usb' project transfer command ---
msg_usb_no_device:    db "No USB device detected.", 10, 0
msg_usb_usage:        db "usb: usage: usb <list|info|export|import|delete|rename> [args]", 10, 0
msg_usb_read_fail:    db "error: Failed to read sector.", 10, 0
msg_usb_write_fail:   db "error: Failed to write sector.", 10, 0
msg_usb_full:         db "error: USB storage is full.", 10, 0
msg_usb_exists:       db "error: Project already exists.", 10, 0
msg_usb_corrupt:      db "error: Archive is corrupted.", 10, 0
msg_usb_no_project1:  db 'error: No project named "', 0
msg_usb_no_project2:  db '".', 10, 0
msg_usb_none_found:   db "No projects found.", 10, 0
msg_usb_info_vendor:  db "Vendor : ", 0
msg_usb_info_product: db "Product: ", 0
msg_usb_info_capacity: db "Capacity: ", 0
msg_usb_info_mb:      db " MB", 10, 0
msg_usb_info_projects: db "Projects: ", 0
msg_usb_exporting:    db "Exporting project...", 10, 10, 0
msg_usb_creating_archive: db "Creating archive...", 10, 0
msg_usb_writing:      db "Writing to USB...", 10, 0
msg_usb_done:         db "Done.", 10, 0
msg_usb_creating_project: db "Creating project...", 10, 10, 0
msg_usb_copying:      db "Copying files...", 10, 0
msg_usb_deleted1:     db "Deleted project '", 0
msg_usb_deleted2:     db "'.", 10, 0
msg_usb_renamed1:     db "Renamed project '", 0
msg_usb_renamed2:     db "' to '", 0
msg_usb_renamed3:     db "'.", 10, 0

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
    db "  sync               save the filesystem to disk", 10
    db "  rboot              save to disk, then restart (requires auth)", 10
    db "  sdown              shut down (requires auth)", 10
    db "  dscan              scan the PCI bus for a USB storage controller", 10
    db "  usbinfo            address a USB device found by dscan and probe it", 10
    db "  usbdisk            probe a USB mass-storage device found by usbinfo", 10
    db "  usb list/info      list projects on USB, or show USB device info", 10
    db "  usb export <name>  export a project folder to USB (needs dscan+usbinfo)", 10
    db "  usb import <name>  import a project folder from USB", 10
    db "  usb delete <name>  delete a project archive from USB", 10
    db "  usb rename <a> <b> rename a project archive on USB", 10
    db "  ;                  chain commands, e.g. show hi ; show bye", 10
    db "  $                  comment line (lines starting with $ are skipped)", 10
    db "  up/down arrows     recall previously entered commands", 10
    db "  ctrl+up/down       scroll the screen back/forward through output", 10, 10, 0

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
; fs_disk_header..fs_image_end is exactly what fs_save/fs_load ship to/from
; disk as one blob. fs_pad rounds that blob up to a whole number of sectors
; so sector-sized disk I/O never spills into unrelated memory (path_stack
; etc.) that happens to sit right after it.
ALIGN 8
fs_disk_header:
    db 'SFFS'                    ; magic
    db 1                         ; format version
    db 0, 0, 0                   ; reserved
fs_image_start:
node_type:    times MAX_NODES db 0
node_parent:  times MAX_NODES dw 0
node_name:    times MAX_NODES*NAME_LEN db 0
node_content: times MAX_NODES*CONTENT_LEN db 0
fs_image_end:
FS_IMAGE_SIZE equ fs_image_end - fs_disk_header
FS_PAD_SIZE   equ (512 - (FS_IMAGE_SIZE % 512)) % 512
fs_pad:       times FS_PAD_SIZE db 0
fs_disk_block_end:
FS_SECTORS    equ (fs_disk_block_end - fs_disk_header) / 512

fs_loaded_from_disk: db 0
fs_disk_available:   db 1     ; optimistic default; cleared on first ATA failure
fs_name_too_long:    db 0     ; set by fs_create_node when a name won't fit

path_stack:   times 16 dw 0

; --- scratch for fs_resolve_path ---
path_comp_buf: times 64 db 0     ; one path component at a time
leaf1_buf:      times 64 db 0    ; resolved leaf name for arg1_buf paths
leaf2_buf:      times 64 db 0    ; resolved leaf name for arg2_buf paths

; --- USB (dscan/mount) state ---
; hexbuf is scratch for hex_to_str; 9 bytes covers an 8-digit dword plus
; null terminator, which is the widest thing we currently print in hex.
hexbuf:          times 9 db 0
pci_tmp_vendev:  dd 0
pci_tmp_class:   dd 0
usb_uhci_found:  db 0             ; set by dscan once a UHCI controller is seen
usb_uhci_bus:    db 0
usb_uhci_dev:    db 0
usb_uhci_func:   db 0
usb_uhci_io_base: dw 0            ; UHCI I/O-space base (from BAR4)
usb_uhci_ready:   db 0             ; set by uhci_init once the controller
                                   ; has been reset and started
uhci_port1_status: dw 0            ; last PORTSC1/2 value read by uhci_init
uhci_port2_status: dw 0            ; (bit0 = device currently connected)

; UHCI's frame list must be 4KB-aligned; ALIGN is computed against this
; file's actual load address (ORG 0x8000 above), not file offset, so this
; lands on a real page boundary in memory.
ALIGN 4096
uhci_frame_list: times 1024 dd 1  ; 1024 entries, each Terminate-bit-set
                                  ; (no queue heads scheduled yet)

; --- Phase 3: control-transfer QH/TD pool ---
; QH and every TD must be 16-byte aligned (their Link/Element Pointer
; fields reserve the low 4 bits for T/Q/Vf flags).
ALIGN 16
uhci_qh: dd 0                     ; Head Link Pointer (unused - Terminate)
         dd 0                     ; Element Link Pointer -> first TD

; UHCI_MAX_TDS covers SETUP + STATUS + up to 18 data TDs at
; UHCI_CTRL_MAXPKT(8) bytes each - enough for the largest transfer we
; issue (a UHCI_CFG_BUFSZ-byte configuration descriptor read).
UHCI_MAX_TDS equ 20
ALIGN 16
uhci_td_pool: times (UHCI_MAX_TDS*16) db 0   ; 16 bytes/TD: link,ctrl,token,buf

; scratch copy of the 8-byte setup packet - this is what the SETUP TD's
; buffer pointer actually targets, so it needs a stable address of its own
; rather than pointing directly at caller-supplied stack/buffer memory.
uhci_setup_pkt: times 8 db 0

; --- uhci_ctrl_transfer's "call frame" (this codebase's usual style of
; passing state through named globals rather than deep argument lists) ---
usb_xfer_addr:  db 0               ; target device address for the transfer
usb_xfer_buf:   dq 0                ; data-stage buffer (linear==physical)
usb_xfer_len:   dw 0                ; data-stage length in bytes (0 = none)
usb_xfer_dir:   db 0                ; 1 = IN (device->host), 0 = OUT
usb_xfer_setup: times 8 db 0        ; 8-byte setup packet, filled by caller

; --- addressed-device state (Phase 3 output, Phase 4 input) ---
usb_dev_address:   db 0             ; address assigned by usb_set_address
usb_dev_desc:      times 18 db 0    ; full device descriptor
UHCI_CFG_BUFSZ equ 128
usb_cfg_desc:      times UHCI_CFG_BUFSZ db 0   ; full configuration descriptor
usb_cfg_total_len: dw 0             ; wTotalLength from the config header

usb_msc_iface_num:      db 0xFF     ; 0xFF = "not found"
usb_msc_iface_class:    db 0
usb_msc_iface_subclass: db 0
usb_msc_iface_protocol: db 0
usb_bulk_in_ep:  db 0xFF            ; endpoint number 0-15, 0xFF = not found
usb_bulk_out_ep: db 0xFF

; --- uhci_bulk_transfer's "call frame" (mirrors usb_xfer_* above) ---
usb_bulk_ep:  db 0
usb_bulk_buf: dq 0
usb_bulk_len: dw 0
usb_bulk_dir: db 0

; per-endpoint data toggle state, reset to DATA0 by usb_set_configuration
; whenever the device is (re-)configured
usb_bulk_in_toggle:  db 0
usb_bulk_out_toggle: db 0

; --- USB Mass Storage Bulk-Only Transport / SCSI state ---
usb_msc_cbw:  times 31 db 0         ; Command Block Wrapper
usb_msc_csw:  times 13 db 0         ; Command Status Wrapper
usb_msc_cdb:  times 16 db 0         ; scratch SCSI command block
usb_msc_cur_tag:  dd 1              ; next dCBWTag to use, incremented each command
usb_msc_last_tag: dd 0              ; dCBWTag of the in-flight command, for CSW matching
usb_msc_data_len: dw 0              ; usb_msc_command's "call frame"
usb_msc_data_dir: db 0

usb_msc_inquiry_buf: times 36 db 0  ; full INQUIRY response
usb_msc_cap_buf:     times 8  db 0  ; raw READ CAPACITY(10) response
usb_msc_block_count: dd 0           ; total blocks, host byte order
usb_msc_block_size:  dd 0           ; bytes/block, host byte order
usb_msc_sector_buf:  times 512 db 0 ; scratch data-stage buffer for READ(10)

; --- 'usb' project transfer state ---
usb_idx_header: times 512 db 0                       ; LBA 0 mirror
ALIGN 8
usb_idx_table:  times USB_MAX_PROJECTS*USB_ENTRY_SIZE db 0   ; LBA 1..2 mirror (1024 bytes)
usb_archive_buf: times USB_PROJECT_SLOT_BYTES db 0    ; one project's serialized archive
usb_archive_ptr:      dq 0     ; usb_archive_emit's current write pointer
usb_archive_count:    dw 0     ; nodes emitted so far
usb_archive_overflow: db 0     ; set if a project's archive would exceed its slot
usb_rec_base:         dq 0     ; scratch: current record's base address
usb_tmp_dest:         dq 0     ; scratch: saved destination pointer around str_copy
usb_import_root_real: dq -1    ; real fs node idx of the just-created project root,
                                ; used to roll back (fs_delete_tree) a failed import
usb_local_map:  times MAX_NODES dw 0  ; archive-local index -> real fs node idx (import)

; --- line editing buffers ---
line_buf: times LINE_MAX db 0
chain_scan_buf: times LINE_MAX db 0  ; scratch copy for ; chaining
cmd_buf:  times 32  db 0

; --- command history storage (ring of HIST_MAX previously-entered lines) ---
ALIGN 8
hist_buf: times HIST_MAX*LINE_MAX db 0
; holds whatever the user had typed-but-not-submitted when they started
; browsing history, so Down can bring them back to it (like real shells).
hist_saved_line: times LINE_MAX db 0

; --- output scrollback storage ---
; scrollback_buf holds whole VGA rows (char+attr word per cell, same
; layout as VGA memory) that have scrolled off the top of the screen.
; live_snapshot holds the 25 rows that were actually on screen at the
; moment a scrollback session began, so the real live view can be
; restored exactly (without re-deriving it) when the user scrolls back
; down to the bottom.
ALIGN 8
scrollback_buf:  times SCROLLBACK_LINES*VGA_COLS dw 0
live_snapshot:   times VGA_ROWS*VGA_COLS dw 0
arg1_buf: times 96  db 0
arg2_buf: times 160 db 0
arg3_buf: times 32  db 0             ; for flags (-force, -silent, -info)
arg4_buf: times 32  db 0             ; for additional flags

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