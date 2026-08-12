; ============================================================
;  ShellyForever  --  kernel.asm
;  Loaded flat at physical address 0x8000 by boot.asm. boot.asm hands off
;  here WHILE STILL IN REAL MODE (see splash_stub right below) so BIOS
;  video/keyboard calls are still available for a boot splash; splash_stub
;  then does the A20/GDT/protected-mode/long-mode transition itself (moved
;  here from boot.asm - see boot.asm's read_done for why) and falls into
;  kernel_entry, which is where actual 64-bit long-mode execution used to
;  begin directly. No IDT/interrupts are set up - keyboard is polled.
; ============================================================

BITS 64
ORG 0x8000

%include "splash.asm"

BITS 64
; ---------------- constants ----------------
VGA_BASE        equ 0xB8000
VGA_COLS        equ 80
VGA_ROWS        equ 25
ATTR_NORMAL     equ 0x0A          ; bright green on black
ATTR_PROMPT     equ 0x0E          ; yellow
ATTR_ERROR      equ 0x0C          ; red
ATTR_WIG        equ 0x0B          ; light cyan - used by the wig clock widget

; cmd_edit redraws its whole viewport from scratch on every keystroke (see
; cmd_edit below); the first EDIT_HEADER_ROWS screen rows are always the
; "-- editing <name> ... --" banner and a blank line, so the scrollable
; body only gets VGA_ROWS-EDIT_HEADER_ROWS rows. Must match the number of
; newlines msg_edit_header1+msg_edit_header2 print before file content.
EDIT_HEADER_ROWS equ 2

; SFFS v4 raises this from 64 to 256 (see the SFFS v4 block below) - the
; old 64-node table was shared by folders, files, AND every chain
; continuation node a file needed once its content passed 159 bytes, so a
; handful of ordinary-sized files could exhaust it well before the disk
; itself was anywhere near full ("error: filesystem is full" with tons of
; free space left). v2/v3 disks (still readable) keep working exactly as
; before; a sync upgrades them to v4 in place - see fs_layout_ver.
OS_NODES        equ 256             ; nodes per volume (each drive holds its own node table)
MAX_MOUNTS      equ 2               ; how many extra drives can be mounted at once

; AHCI (SATA) support: device ids 0-3 are still the legacy ATA PIO slots
; (primary/secondary x master/slave); ids 4..4+AHCI_MAX_PORTS-1 are AHCI
; ports discovered at boot (see ahci_init). dscan/fmt/mount all iterate
; 0..TOTAL_DEVICES-1 and go through disk_select_device, which routes each
; id to the right driver - see that routine for the full explanation.
AHCI_MAX_PORTS  equ 4
TOTAL_DEVICES   equ 4 + AHCI_MAX_PORTS
VOL_NODES       equ OS_NODES        ; every volume, OS or mounted, is the same size
MAX_NODES       equ OS_NODES * (1 + MAX_MOUNTS)   ; 768 = OS volume + 2 mounts
NAME_LEN        equ 32
CONTENT_LEN     equ 160
LINE_MAX        equ 220

SCROLLBACK_LINES equ 100         ; extra off-screen rows kept for Ctrl+Up/Down
HISTORY_MAX      equ 20          ; command history entries kept for Up/Down
KEY_UP           equ 0x11        ; sentinel byte get_char returns for the Up arrow
KEY_DOWN         equ 0x12        ; sentinel byte get_char returns for the Down arrow
KEY_PASTE        equ 0x13        ; sentinel byte get_char returns for Ctrl+V
KEY_LEFT         equ 0x14        ; sentinel byte get_char returns for the Left arrow
KEY_RIGHT        equ 0x15        ; sentinel byte get_char returns for the Right arrow
KEY_HOME         equ 0x16        ; sentinel byte get_char returns for Home
KEY_END          equ 0x17        ; sentinel byte get_char returns for End
KEY_DELETE       equ 0x18        ; sentinel byte get_char returns for Delete

MAX_VARS        equ 16
VAR_NAME_LEN    equ 32
MAX_CALC_TOKENS equ 32

MAX_ALIASES     equ 12         ; how many "ali <name> <commands>" aliases can exist at once
ALIAS_NAME_LEN  equ 32
ALIAS_BODY_LEN  equ LINE_MAX   ; an alias body is at most one full input line
ALIAS_MAX_DEPTH equ 8          ; guards against an alias (in)directly invoking itself

PIPE_CAP_MAX    equ 192       ; max bytes captured from a "~" pipe's left side

; ------------------------------------------------------------------
;  SFFS v4 -- ShellyForever File Storage format (on-disk layout).
;  Every drive (OS boot drive and any data drives) uses the same
;  fixed layout so any drive can be scanned, formatted, and mounted:
;
;    LBA  FS_LBA_START     : superblock (512B) - magic 'SFFS', version
;                             byte, reserved, 32-byte disk label
;    LBA  FS_LBA_START+1   : node_type[VOL_NODES]  (1 sector, padded)
;    LBA  FS_LBA_START+2   : node_parent[VOL_NODES] (1 sector, padded)
;    LBA  FS_LBA_START+3   : node_next[VOL_NODES]  (1 sector; 0xFFFF = no
;                             continuation). v3+ only - v2 has no next sector.
;    LBA  FS_LBA_START+4.. : node_name[VOL_NODES*NAME_LEN]    (NAME_SECTORS)
;    LBA  ..after name..   : node_content[VOL_NODES*CONTENT_LEN] (CONTENT_SECTORS)
;
;  A file whose content exceeds one 159-byte slot is stored as a chain:
;  the file's own node holds the first chunk, and its node_next points at
;  NODE_TYPE_CHAIN (type-3) continuation nodes, each holding the next 159
;  bytes and linked through their own node_next (0xFFFF terminates). Chain
;  nodes are invisible to path lookup, listing, and the allocator, and are
;  freed along with the file.
;
;  *** Why v4 exists ***
;  v2/v3 volumes had a hard VOL_NODES=64 ceiling, and that table was
;  shared by folders, files, AND every chain continuation node. A single
;  file bigger than 159 bytes already burns 2+ node slots, so it took
;  surprisingly few real files (e.g. a compiler test fixture) to trip
;  "error: filesystem is full" while the disk itself still had plenty of
;  free sectors - the node *table*, not the disk, was what ran out.
;  v4 keeps the exact same chain-of-nodes design (so all the code above
;  that walks node_next doesn't change) and simply widens VOL_NODES to
;  256, which needs bigger NAME/CONTENT regions - CONTENT_LBA is now
;  computed from NAME_LBA+NAME_SECTORS instead of being hardcoded, so
;  the two regions can never overlap as VOL_NODES changes again later.
;  It also nudges EDIT_MAX (one file's max size) up from ~10KB to ~40KB
;  as a side effect, since that's just VOL_NODES*CONTENT_LEN.
;
;  *** Backward compatibility ***
;  v2 volumes (no node_next sector, name LBA at SUPER_LBA+3 / content at
;  SUPER_LBA+7, 64 nodes) and v3 volumes (has node_next, but still the old
;  64-node-sized name/content regions at OLD_NAME_LBA/OLD_CONTENT_LBA)
;  both still load and read fine - see fs_layout_ver in vol_read. Loading
;  either one leaves nodes 64..255 of that volume's slice explicitly
;  cleared (free), so the moment you mkfl/mkf/edit again you're already
;  using the bigger table; a sync then writes the volume back out in the
;  current (v4) layout, upgrading it on disk permanently.
;
;  dscan probes all four ATA device slots for the magic, format writes
;  a fresh empty volume + label, and mount loads a volume's node table
;  into memory (remapping its parent indices) rooted at /<label>/.
;  The kernel occupies LBA 1..1500 (KERNEL_SECTORS in boot.asm; the real
;  kernel.bin is ~1180 sectors after MAX_PROCESSES was trimmed 4->2, so
;  1500 leaves some slack). HARD CEILING: the image is loaded flat at
;  0x8000 and base RAM tops out at 0x9FFFF (0xA0000 is the VGA adapter
;  window - not RAM - so anything past that boundary is silently lost; the
;  bg-scheduler arrays once grew the image to ~1373 sectors, past the edge,
;  and the boot crashed). Keep kernel.bin under 0x98000 bytes. The
;  filesystem region must start clear of KERNEL_SECTORS, with real
;  margin for the kernel to keep growing - not just enough for today's
;  build - so it starts at LBA 1560. v4's bigger name/content regions
;  need ~100 sectors per volume (was ~28) - make sure each disk image
;  you build/attach has enough room past LBA 1560 for that.
; ------------------------------------------------------------------
FS_LBA_START    equ 1560            ; bumped from 1150 - the background-process arrays
                                    ; once grew kernel.bin to ~1373 sectors, so boot.asm's
                                    ; KERNEL_SECTORS went 1100 -> 1500 and the filesystem
                                    ; must start past LBA 1500. *** BREAKING CHANGE: any
                                    ; image with a filesystem already written at the old
                                    ; FS_LBA_START=1150 needs to be reformatted (dscan/fmt)
                                    ; after this change, or that data is effectively at the
                                    ; wrong LBA and won't be found. ***
SFFS_VERSION    equ 4               ; current on-disk format (256-node volumes)
SFFS_VERSION_V3 equ 3               ; old format (64-node volumes, has node_next) - still readable
SFFS_VERSION_V2 equ 2               ; old, single-block format - still readable
SUPER_LABEL_OFF equ 8               ; label lives at superblock offset 8..39
SUPER_LBA       equ FS_LBA_START
TYPE_LBA        equ SUPER_LBA + 1
PARENT_LBA      equ SUPER_LBA + 2
NEXT_LBA        equ SUPER_LBA + 3
NAME_LBA        equ SUPER_LBA + 4
NAME_SECTORS    equ (VOL_NODES * NAME_LEN) / 512          ; 16 (256 nodes * 32B / 512)
CONTENT_LBA     equ NAME_LBA + NAME_SECTORS                ; computed, not hardcoded - see above
CONTENT_SECTORS equ (VOL_NODES * CONTENT_LEN) / 512       ; 80 (256 nodes * 160B / 512)
BINLEN_LBA      equ CONTENT_LBA + CONTENT_SECTORS          ; binary-length table, first free LBA
BINLEN_SECTORS  equ (VOL_NODES * 4) / 512                 ; 2 (256 nodes * 4B / 512)
NODE_TYPE_CHAIN equ 3               ; continuation node in a file's content chain

; --- legacy v3 (64-node) on-disk geometry, needed only so vol_read can
; still locate an old volume's name/content regions at their old fixed
; offsets before it gets upgraded to v4 on the next sync. Do not use these
; anywhere else - VOL_NODES/NAME_LBA/CONTENT_LBA above are the live ones. ---
OLD_VOL_NODES       equ 64
OLD_NAME_SECTORS    equ (OLD_VOL_NODES * NAME_LEN) / 512      ; 4
OLD_CONTENT_SECTORS equ (OLD_VOL_NODES * CONTENT_LEN) / 512   ; 20
OLD_NAME_LBA        equ SUPER_LBA + 4
OLD_CONTENT_LBA     equ SUPER_LBA + 8

EDIT_MAX        equ VOL_NODES * CONTENT_LEN   ; max bytes one file can hold (256*160)

; ============================================================
kernel_entry:
    cli
    mov rsp, 0x9F000

    ; bring up COM1 immediately so putchar can mirror every character there,
    ; letting QEMU capture the whole session to a file via -serial file:.
    call serial_init


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

    ; probe for a PCI RTL8139 NIC and bring up its ring buffers, if any.
    ; Inert/no-op if there isn't one (nic_present stays 0) - the OS behaves
    ; exactly as it always did in that case. See nic_init below.
    call nic_init

    ; bring up COM1 as a serial console; putchar mirrors every char there, so
    ; QEMU can capture the whole session to a file via -serial file:.
    call serial_init

    ; checkpoint 9: kernel code is executing (proves boot.asm's jump into
    ; 0x8000 landed correctly). Matches the DBG16/32/64 checkpoints in
    ; boot.asm - if you see 1..8 but not this, the kernel wasn't loaded/
    ; jumped to correctly; if the OS otherwise looks fine you can ignore it.
    mov rdi, 0xB8000 + (24*80 + 8) * 2
    mov byte [rdi], 'K'
    mov byte [rdi+1], 0x0F

    call clear_screen
    call fs_load                ; loads persisted fs from disk, or fs_init's a fresh one

    ; --- auto-create the system folders every boot, not just on a fresh
    ; filesystem or factory reset. ensure_sys_folder creates /home/sys
    ; (the OS volume's sys folder) plus its two plain-text config files
    ; alias.sly and sysconfig.sly if any of them are missing, so a user
    ; deleting them can't brick the aliases/config system. Then persist
    ; right away so the recreated folders/files survive even a hard
    ; power-off (i.e. we don't rely on a clean shutdown's fs_save). ---
    call ensure_sys_folder
    call fs_save

    ; the terminal starts in /home (the OS volume's home folder); be
    ; explicit about it so a stale cur_dir can never leak across reboots
    mov qword [cur_dir], 0

    call aliases_load           ; restore aliases saved to /home/sys/alias.sly, if any

    mov rsi, banner
    mov al, [cur_normal_attr]
    call print_string_attr

    mov rsi, build_stamp
    mov al, [cur_normal_attr]
    call print_string_attr

    cmp byte [fs_disk_available], 0
    je .say_no_disk
    cmp byte [fs_loaded_from_disk], 1
    je .say_loaded
    mov rsi, msg_fresh_fs
    mov al, [cur_normal_attr]
    call print_string_attr
    jmp .banner_done
.say_loaded:
    mov rsi, msg_loaded_fs
    mov al, [cur_normal_attr]
    call print_string_attr
    jmp .banner_done
.say_no_disk:
    mov rsi, msg_no_disk
    mov al, ATTR_ERROR
    call print_string_attr
.banner_done:

    .shell_loop:
        ; drain any inbound NIC frames (ARP/ICMP/UDP) that arrived while we
        ; were idle, so ARP replies / echo replies / DNS answers don't sit in
        ; the ring until the next command. Cheap no-op without a NIC.
        call netpoll
        call print_prompt
    
        mov rdi, line_buf
        mov rcx, LINE_MAX-1
        call read_line

        ; print any queued background-process completion notice now, on a
        ; fresh line, before this command's own output
        call bg_flush_notice

        ; skip $ comments (lines starting with $)
        cmp byte [line_buf], '$'
        je .shell_loop

        ; "ali <name> <commands>" defines an alias. This has to be
        ; intercepted here, before ; chaining/tokenizing get anywhere
        ; near the line, so that a body like "calc 5 + 5 ~ = a ; show a"
        ; is stored verbatim instead of being split on ; or ~ right now.
        call try_handle_ali_line
        cmp al, 1
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
    mov rdi, str_about
    call str_eq
    cmp al, 1
    je cmd_about

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
    mov rdi, str_syscmd
    call str_eq
    cmp al, 1
    je cmd_sys

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
    mov rdi, str_unmount
    call str_eq
    cmp al, 1
    je cmd_unmount

    mov rsi, cmd_buf
    mov rdi, str_label
    call str_eq
    cmp al, 1
    je cmd_label

    mov rsi, cmd_buf
    mov rdi, str_alis
    call str_eq
    cmp al, 1
    je cmd_alis

    mov rsi, cmd_buf
    mov rdi, str_color
    call str_eq
    cmp al, 1
    je cmd_color

    mov rsi, cmd_buf
    mov rdi, str_date
    call str_eq
    cmp al, 1
    je cmd_date

    mov rsi, cmd_buf
    mov rdi, str_time
    call str_eq
    cmp al, 1
    je cmd_time

    mov rsi, cmd_buf
    mov rdi, str_write
    call str_eq
    cmp al, 1
    je cmd_write

    mov rsi, cmd_buf
    mov rdi, str_wig
    call str_eq
    cmp al, 1
    je cmd_wig

    mov rsi, cmd_buf
    mov rdi, str_shelly
    call str_eq
    cmp al, 1
    je cmd_shelly

    mov rsi, cmd_buf
    mov rdi, str_run
    call str_eq
    cmp al, 1
    je cmd_run

    mov rsi, cmd_buf
    mov rdi, str_autosync
    call str_eq
    cmp al, 1
    je cmd_autosync

    mov rsi, cmd_buf
    mov rdi, str_party
    call str_eq
    cmp al, 1
    je cmd_party

    mov rsi, cmd_buf
    mov rdi, str_netinfo
    call str_eq
    cmp al, 1
    je cmd_netinfo

    mov rsi, cmd_buf
    mov rdi, str_bounce
    call str_eq
    cmp al, 1
    je cmd_bounce

    mov rsi, cmd_buf
    mov rdi, str_monitor
    call str_eq
    cmp al, 1
    je cmd_monitor

    mov rsi, cmd_buf
    mov rdi, str_dns
    call str_eq
    cmp al, 1
    je cmd_dns

    mov rsi, cmd_buf
    mov rdi, str_net
    call str_eq
    cmp al, 1
    je cmd_net

    mov rsi, cmd_buf
    mov rdi, str_dhcp
    call str_eq
    cmp al, 1
    je cmd_dhcp

    mov rsi, cmd_buf
    mov rdi, str_tcp
    call str_eq
    cmp al, 1
    je cmd_tcp

    mov rsi, cmd_buf
    mov rdi, str_take
    call str_eq
    cmp al, 1
    je cmd_take

    mov rsi, cmd_buf
    mov rdi, str_give
    call str_eq
    cmp al, 1
    je cmd_give

    mov rsi, cmd_buf
    mov rdi, str_browse
    call str_eq
    cmp al, 1
    je cmd_browse

    mov rsi, cmd_buf
    mov rdi, str_mouse
    call str_eq
    cmp al, 1
    je cmd_mouse

    ; --- typed a bare "<name>.run" filename directly? treat it the
    ; same as "run <name>.run" so scripts double as executables ---
    lea rax, [cmd_buf]
    mov rsi, rax
.dbr_len_loop:
    cmp byte [rsi], 0
    je .dbr_len_done
    inc rsi
    jmp .dbr_len_loop
.dbr_len_done:
    sub rsi, 4
    cmp rsi, rax
    jl .not_bare_run            ; cmd_buf shorter than ".run" itself
    cmp byte [rsi], '.'
    jne .not_bare_run
    cmp byte [rsi+1], 'r'
    jne .not_bare_run
    cmp byte [rsi+2], 'u'
    jne .not_bare_run
    cmp byte [rsi+3], 'n'
    jne .not_bare_run

    mov rsi, cmd_buf
    mov rdi, arg1_buf
    call str_copy
    jmp cmd_run
.not_bare_run:

    ; --- user-defined alias? (see "ali <name> <commands>") ---
    mov rsi, cmd_buf
    call alias_lookup
    cmp rax, -1
    je .no_alias_match
    mov [alias_match_idx], al
    jmp cmd_alias_invoke
.no_alias_match:

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
    call check_target_sys_auth
    cmp rax, 1
    je .bad_path
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
    call maybe_auto_sync
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
    ; --- detect -test flag; it may land in arg2 (no content given, e.g.
    ; "mkfl hi.txt -test") or in arg3/arg4 alongside real content/flags ---
    mov byte [mkfl_test_flag], 0
    lea rax, [arg2_buf]
    mov [mkfl_content_ptr], rax
    mov rsi, arg2_buf
    mov rdi, str_test
    call str_eq
    cmp al, 1
    jne .mkfl_arg2_not_test
    mov byte [mkfl_test_flag], 1
    lea rax, [empty_str]
    mov [mkfl_content_ptr], rax
.mkfl_arg2_not_test:
    mov rsi, arg3_buf
    mov rdi, str_test
    call str_eq
    cmp al, 1
    jne .mkfl_arg3_not_test
    mov byte [mkfl_test_flag], 1
.mkfl_arg3_not_test:
    mov rsi, arg4_buf
    mov rdi, str_test
    call str_eq
    cmp al, 1
    jne .mkfl_arg4_not_test
    mov byte [mkfl_test_flag], 1
.mkfl_arg4_not_test:

    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .bad_path
    mov r11, rax                 ; parent dir the new file goes in
    call check_target_sys_auth
    cmp rax, 1
    je .mkfl_done
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .exists
    cmp byte [mkfl_test_flag], 1
    je .test_would_create
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2                  ; type file
    call fs_create_node
    cmp rax, -1
    je .full
    ; rax = new node index, write arg2 into its content
    mov rbx, rax
    lea rsi, [arg2_buf]
    call fs_write_file
    call maybe_auto_sync

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
    mov al, [cur_normal_attr]
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

    cmp byte [mkfl_test_flag], 1
    jne .exists_not_test
    ; test mode: still check -force so the report matches what a real
    ; run would do, but never touch the existing node either way
    mov rsi, arg3_buf
    mov rdi, str_force
    call str_eq
    cmp al, 1
    je .test_would_overwrite
    mov rsi, arg4_buf
    mov rdi, str_force
    call str_eq
    cmp al, 1
    je .test_would_overwrite
    jmp .test_blocked_no_force
.exists_not_test:

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
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string

.overwrite:
    ; rbx = existing node index, overwrite content
    mov rax, rbx
    lea rsi, [arg2_buf]
    call fs_write_file
    call maybe_auto_sync

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
    mov al, [cur_normal_attr]
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

.test_would_create:
    ; file doesn't exist yet and -test was given: report, touch nothing
    mov rsi, msg_mkfl_test_create
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_mkfl_info2
    call print_string
    mov rsi, [mkfl_content_ptr]
    xor rcx, rcx
.test_cr_strlen:
    cmp byte [rsi], 0
    je .test_cr_strlen_done
    inc rcx
    inc rsi
    jmp .test_cr_strlen
.test_cr_strlen_done:
    mov rax, rcx
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, msg_mkfl_test_suffix
    call print_string
    jmp .mkfl_done

.test_would_overwrite:
    ; file exists and -force + -test were both given: report, touch nothing
    mov rsi, msg_mkfl_test_overwrite
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_mkfl_info2
    call print_string
    mov rsi, [mkfl_content_ptr]
    xor rcx, rcx
.test_ov_strlen:
    cmp byte [rsi], 0
    je .test_ov_strlen_done
    inc rcx
    inc rsi
    jmp .test_ov_strlen
.test_ov_strlen_done:
    mov rax, rcx
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, msg_mkfl_test_suffix
    call print_string
    jmp .mkfl_done

.test_blocked_no_force:
    ; file exists, -test given, no -force: a real run would refuse - say so
    mov rsi, msg_mkfl_test_blocked1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_mkfl_test_blocked2
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
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, newline_str
    call print_string
    ret
.show_var:
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    mov al, [cur_normal_attr]
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
    mov al, [cur_normal_attr]
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
; cmd_edit: opens the built-in editor on an existing file. Edits a copy of
; the file's content in place (typed chars/Enter insert at the cursor,
; Backspace/Delete remove around it, Left/Right/Home/End move it - all
; newline-aware), ESC ends editing and asks whether to save (y) or
; discard (n).
;
; Loop state (kept in registers across the whole edit session, same
; convention as cur_dir-style code elsewhere - callees here are all
; expected to preserve r12-r15):
;   r15 = node id being edited
;   r14 = content length (bytes used in fs_io_buf)
;   r13 = cursor index into fs_io_buf (0..r14)
;   r12 = "top row" - the 0-based row number (counting both embedded
;         newlines and 80-col wraps from the start of the buffer) that
;         .ce_render currently shows at the top of the scrollable body.
;
; Unlike read_line (which only ever holds one un-wrapped line, so it can
; patch the screen in place with cursor_step_left/right), fs_io_buf here
; contains real embedded newlines, and putchar forces column->0 on those
; regardless of the current column - so column-wrap-only cursor stepping
; would desync from the real screen layout on any line short of 80 cols.
; Simpler and robust: every navigation or edit fully redraws the visible
; page from a recomputed buffer offset (.ce_render below), rather than
; trying to patch deltas.
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
    push rax
    mov rax, r15
    call check_node_in_sys
    cmp al, 1
    jne .ce_auth_ok
    cmp byte [auth_valid], 1
    je .ce_auth_ok
    mov rsi, msg_auth_required
    mov al, ATTR_ERROR
    call print_string_attr
    pop rax
    pop r15
    ret
.ce_auth_ok:
    pop rax

    lea rdi, [fs_io_buf]
    call fs_read_file

    lea rsi, [fs_io_buf]
    call str_len
    push r12
    push r13
    push r14
    mov r14, rax                     ; content length
    mov r13, r14                     ; cursor starts at end (append point),
                                      ; matching the old typewriter behavior
    xor r12, r12                     ; top row starts at 0
    mov byte [edit_active], 1        ; makes get_char treat plain Up/Down as
                                      ; "scroll the view", not shell history
    call .ce_render                  ; initial draw (header + content + cursor)
.ce_loop:
    call get_char
    cmp al, 27
    je .ce_finish
    cmp al, 0x0D
    je .ce_newline
    cmp al, 8
    je .ce_bksp
    cmp al, KEY_UP                   ; edit_active makes get_char consume Up/Down
    je .ce_loop                      ; itself to scroll - these are just a safety net
    cmp al, KEY_DOWN                 ; in case a sentinel ever slips through anyway
    je .ce_loop
    cmp al, KEY_PASTE                ; paste isn't wired up in the editor yet -
    je .ce_loop                      ; ignore rather than insert the raw sentinel byte
    cmp al, KEY_LEFT
    je .ce_left
    cmp al, KEY_RIGHT
    je .ce_right
    cmp al, KEY_HOME
    je .ce_home
    cmp al, KEY_END
    je .ce_end
    cmp al, KEY_DELETE
    je .ce_delete
    call .ce_insert_at
    call .ce_render
    jmp .ce_loop
.ce_newline:
    mov al, 0x0A
    call .ce_insert_at
    call .ce_render
    jmp .ce_loop
.ce_bksp:
    cmp r13, 0
    je .ce_loop
    dec r13
    mov rdx, r13
    call .ce_delete_at
    call .ce_render
    jmp .ce_loop
.ce_delete:
    cmp r13, r14
    jae .ce_loop
    mov rdx, r13
    call .ce_delete_at
    call .ce_render
    jmp .ce_loop
.ce_left:
    cmp r13, 0
    je .ce_loop
    dec r13
    call .ce_render
    jmp .ce_loop
.ce_right:
    cmp r13, r14
    jae .ce_loop
    inc r13
    call .ce_render
    jmp .ce_loop
.ce_home:
    lea rsi, [fs_io_buf]
.ceh_scan:
    cmp r13, 0
    je .ceh_done
    cmp byte [rsi + r13 - 1], 10
    je .ceh_done
    dec r13
    jmp .ceh_scan
.ceh_done:
    call .ce_render
    jmp .ce_loop
.ce_end:
    lea rsi, [fs_io_buf]
.cee_scan:
    cmp r13, r14
    jae .cee_done
    cmp byte [rsi + r13], 10
    je .cee_done
    inc r13
    jmp .cee_scan
.cee_done:
    call .ce_render
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
    mov byte [edit_active], 0
    mov rax, r15
    lea rsi, [fs_io_buf]
    call fs_write_file
    call maybe_auto_sync
    call clear_screen
    mov rsi, msg_saved
    mov al, [cur_normal_attr]
    call print_string_attr
    pop r14
    pop r13
    pop r12
    pop r15
    ret
.ce_discard:
    mov byte [edit_active], 0
    call clear_screen
    mov rsi, msg_discarded
    mov al, [cur_normal_attr]
    call print_string_attr
    pop r14
    pop r13
    pop r12
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

; .ce_insert_at (in: al = char to insert at the cursor). Shifts
; fs_io_buf[r13..r14-1] right by one, stores al at r13, and advances
; r13/r14 past it. No-op if the file is already at EDIT_MAX. Mirrors
; read_line's .insert_char, but against the persistent file buffer
; instead of a stack line buffer. Clobbers rax/rbx/rcx/rsi.
.ce_insert_at:
    cmp r14, EDIT_MAX-1
    jae .cei_ret
    push rbx
    push rcx
    push rsi
    mov bl, al                       ; stash the typed char - the shift below uses al as scratch
    lea rsi, [fs_io_buf]
    mov rcx, r14                     ; walk from the end down to r13
.cei_shift:
    cmp rcx, r13
    je .cei_place
    mov al, [rsi + rcx - 1]
    mov [rsi + rcx], al
    dec rcx
    jmp .cei_shift
.cei_place:
    mov [rsi + r13], bl
    inc r14
    mov byte [rsi + r14], 0
    inc r13
    pop rsi
    pop rcx
    pop rbx
.cei_ret:
    ret

; .ce_delete_at (in: rdx = buffer index to remove). Shifts
; fs_io_buf[rdx+1..r14-1] left by one and decrements r14. Does not touch
; r13 - callers position the cursor (e.g. Backspace decrements r13 first,
; forward-Delete leaves it alone) before calling. Clobbers rax/rbx/rsi.
.ce_delete_at:
    push rax
    push rbx
    push rsi
    lea rsi, [fs_io_buf]
    mov rbx, rdx
.cda_loop:
    lea rax, [rbx+1]
    cmp rax, r14
    jae .cda_done
    mov al, [rsi + rax]
    mov [rsi + rbx], al
    inc rbx
    jmp .cda_loop
.cda_done:
    dec r14
    mov byte [rsi + r14], 0
    pop rsi
    pop rbx
    pop rax
    ret

; .ce_row_of (in: rcx = a buffer index). Scans fs_io_buf[0..rcx-1] applying
; the same row-break rules putchar does (embedded newline, or column wrap
; at VGA_COLS) -> out: rax = the 0-based row number that index rcx falls
; on. Clobbers rax/rbx/rsi/r8/r9/r10.
.ce_row_of:
    push rbx
    push rsi
    push r8
    push r9
    push r10
    xor r8, r8                       ; row
    xor r9, r9                       ; col
    xor r10, r10                     ; i
    lea rsi, [fs_io_buf]
.cro_loop:
    cmp r10, rcx
    jae .cro_done
    movzx ebx, byte [rsi + r10]
    cmp bl, 10
    je .cro_nl
    inc r9
    cmp r9, VGA_COLS
    jne .cro_next
    xor r9, r9
    inc r8
    jmp .cro_next
.cro_nl:
    xor r9, r9
    inc r8
.cro_next:
    inc r10
    jmp .cro_loop
.cro_done:
    mov rax, r8
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rbx
    ret

; .ce_offset_of_row (in: rcx = a target row number, uses r14 = content
; length). Runs the same row simulation forward from the start of the
; buffer until the row counter reaches rcx -> out: rax = the buffer index
; of the first character of that row (clamped to r14 if the buffer ends
; first). Clobbers rax/rbx/rsi/r8/r9/r10.
.ce_offset_of_row:
    push rbx
    push rsi
    push r8
    push r9
    push r10
    xor r8, r8                       ; row
    xor r9, r9                       ; col
    xor r10, r10                     ; i
    lea rsi, [fs_io_buf]
.cor_loop:
    cmp r8, rcx
    jae .cor_found
    cmp r10, r14
    jae .cor_found
    movzx ebx, byte [rsi + r10]
    cmp bl, 10
    je .cor_nl
    inc r9
    cmp r9, VGA_COLS
    jne .cor_next
    xor r9, r9
    inc r8
    jmp .cor_next
.cor_nl:
    xor r9, r9
    inc r8
.cor_next:
    inc r10
    jmp .cor_loop
.cor_found:
    mov rax, r10
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rbx
    ret

; .ce_render: the single redraw routine every cmd_edit navigation/edit
; op calls afterward. Scrolls r12 (top row) just enough to keep the
; cursor (r13) on screen, clears and redraws the header + the visible
; slice of fs_io_buf, and leaves the hardware cursor sitting exactly on
; r13's screen cell. O(visible page + scan-to-cursor) per call rather
; than O(1), which is fine for a polled-keyboard editor. Clobbers
; rax/rbx/rcx/rdx/rsi/rdi/r8/r9/r11.
.ce_render:
    mov rcx, r13
    call .ce_row_of                  ; rax = cursor's row number
    mov r11, rax
    cmp r11, r12
    jl .cer_scroll_up
    mov rbx, r12
    add rbx, (VGA_ROWS - EDIT_HEADER_ROWS - 1)
    cmp r11, rbx
    jle .cer_have_top
    mov r12, r11
    sub r12, (VGA_ROWS - EDIT_HEADER_ROWS - 1)
    jmp .cer_have_top
.cer_scroll_up:
    mov r12, r11
.cer_have_top:
    mov rcx, r12
    call .ce_offset_of_row           ; rax = buffer offset of the top row
    push rax

    call clear_screen
    mov rsi, msg_edit_header1
    mov al, ATTR_PROMPT
    call print_string_attr
    mov rsi, arg1_buf
    mov al, ATTR_PROMPT
    call print_string_attr
    mov rsi, msg_edit_header2
    mov al, ATTR_PROMPT
    call print_string_attr           ; ends in \n\n -> cursor now at row EDIT_HEADER_ROWS, col 0

    pop rbx                          ; rbx = i, walks the buffer from the top-row offset
    mov byte [ce_cursor_captured], 0
    lea rsi, [fs_io_buf]
    xor r9, r9                       ; rows drawn so far in the body (relative to top)
.cer_loop:
    cmp rbx, r14
    jae .cer_end_of_buf
    cmp rbx, r13
    jne .cer_no_capture
    cmp byte [ce_cursor_captured], 0
    jne .cer_no_capture
    mov al, [cursor_row]
    mov [ce_saved_row], al
    mov al, [cursor_col]
    mov [ce_saved_col], al
    mov byte [ce_cursor_captured], 1
.cer_no_capture:
    cmp r9, (VGA_ROWS - EDIT_HEADER_ROWS)
    jae .cer_done                    ; body's full - rest of the file stays off-screen
    movzx eax, byte [rsi + rbx]
    push rbx
    mov bl, [cur_normal_attr]
    call putchar
    pop rbx
    cmp byte [cursor_col], 0         ; putchar zeroed the column -> a row break just
    jne .cer_next                    ; happened, whether from '\n' or an 80-col wrap
    inc r9
.cer_next:
    inc rbx
    jmp .cer_loop
.cer_end_of_buf:
    cmp byte [ce_cursor_captured], 0
    jne .cer_done                    ; cursor is at end-of-content (r13==r14): current
    mov al, [cursor_row]             ; live cursor_row/col, right after the last drawn
    mov [ce_saved_row], al           ; char, is already exactly the right spot
    mov al, [cursor_col]
    mov [ce_saved_col], al
    mov byte [ce_cursor_captured], 1
.cer_done:
    mov al, [ce_saved_row]
    mov [cursor_row], al
    mov al, [ce_saved_col]
    mov [cursor_col], al
    call update_cursor
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
    cmp byte [node_type + r9], NODE_TYPE_CHAIN
    je .next
    movzx rax, word [node_parent + r9*2]
    cmp rax, [cur_dir]
    jne .next
    mov r12, 1
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rsi, [node_name + rdi]
    mov al, [cur_normal_attr]
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
    lea rdi, [fs_io_buf]
    call fs_read_file
    lea rsi, [fs_io_buf]
    mov al, [cur_normal_attr]
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
; cmd_about: "about <path>" - print type, size, and node-usage info for
; a file or folder without printing its content (unlike "view"). Handy
; for seeing exactly how many chain nodes a file is eating out of the
; volume's node table - the resource "error: filesystem is full" is
; actually about (see fs_create_node/vol_read comments above).
cmd_about:
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
    mov r11, rax
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, -1                  ; any type - about works on files and folders
    call fs_find_child
    cmp rax, -1
    je .not_found
    mov r12, rax                 ; r12 = the node we're describing

    ; --- header: about: '<path as given>' ---
    mov rsi, msg_about_hdr1
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_about_hdr2
    call print_string

    ; --- node id ---
    mov rsi, msg_about_nodeid
    call print_string
    mov rax, r12
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, newline_str
    call print_string

    movzx rax, byte [node_type + r12]
    cmp rax, 1
    je .is_folder

    ; --- file: type, size, blocks ---
    mov rsi, msg_about_type
    call print_string
    mov rsi, msg_type_file
    call print_string

    mov rax, r12
    lea rdi, [fs_io_buf]
    call fs_read_file
    lea rsi, [fs_io_buf]
    call str_len                 ; rax = content length in bytes
    mov r13, rax

    mov rsi, msg_about_size
    call print_string
    mov rax, r13
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, msg_about_bytes
    call print_string

    ; count how many nodes (head + chain continuations) this file occupies
    mov r13, 1
    movzx rax, word [node_next + r12*2]
.count_loop:
    cmp rax, 0xFFFF
    je .count_done
    inc r13
    movzx rax, word [node_next + rax*2]
    jmp .count_loop
.count_done:
    mov rsi, msg_about_blocks
    call print_string
    mov rax, r13
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    cmp r13, 1
    je .block_singular
    mov rsi, msg_about_blocks_plural
    call print_string
    jmp .done
.block_singular:
    mov rsi, msg_about_blocks_singular
    call print_string
    jmp .done

.is_folder:
    mov rsi, msg_about_type
    call print_string
    mov rsi, msg_type_folder
    call print_string

    ; count direct children (files/folders whose parent is this node)
    xor r13, r13
    xor rcx, rcx
.folder_loop:
    cmp rcx, MAX_NODES
    jae .folder_done
    cmp byte [node_type + rcx], 0
    je .folder_next
    cmp byte [node_type + rcx], NODE_TYPE_CHAIN
    je .folder_next
    movzx rax, word [node_parent + rcx*2]
    cmp rax, r12
    jne .folder_next
    inc r13
.folder_next:
    inc rcx
    jmp .folder_loop
.folder_done:
    mov rsi, msg_about_items
    call print_string
    mov rax, r13
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    cmp r13, 1
    je .item_singular
    mov rsi, msg_about_items_plural
    call print_string
    jmp .done
.item_singular:
    mov rsi, msg_about_items_singular
    call print_string
    jmp .done

.done:
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
    mov al, [cur_normal_attr]
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
    mov rdi, str_about
    call str_eq
    cmp al, 1
    je .h_about

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
    mov rdi, str_ali
    call str_eq
    cmp al, 1
    je .h_ali

    mov rsi, arg1_buf
    mov rdi, str_alis
    call str_eq
    cmp al, 1
    je .h_alis

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
    mov rdi, str_syscmd
    call str_eq
    cmp al, 1
    je .h_sys

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
    mov rdi, str_unmount
    call str_eq
    cmp al, 1
    je .h_unmount

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

    mov rsi, arg1_buf
    mov rdi, str_date
    call str_eq
    cmp al, 1
    je .h_date

    mov rsi, arg1_buf
    mov rdi, str_time
    call str_eq
    cmp al, 1
    je .h_time

    mov rsi, arg1_buf
    mov rdi, str_write
    call str_eq
    cmp al, 1
    je .h_write

    mov rsi, arg1_buf
    mov rdi, str_wig
    call str_eq
    cmp al, 1
    je .h_wig

    mov rsi, arg1_buf
    mov rdi, str_shelly
    call str_eq
    cmp al, 1
    je .h_shelly

    mov rsi, arg1_buf
    mov rdi, str_take
    call str_eq
    cmp al, 1
    je .h_take

    mov rsi, arg1_buf
    mov rdi, str_give
    call str_eq
    cmp al, 1
    je .h_give

    mov rsi, arg1_buf
    mov rdi, str_browse
    call str_eq
    cmp al, 1
    je .h_browse

    mov rsi, arg1_buf
    mov rdi, str_mouse
    call str_eq
    cmp al, 1
    je .h_mouse

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
.h_about:
    mov rsi, help_about
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
.h_ali:
    mov rsi, help_ali
    jmp .h_print
.h_alis:
    mov rsi, help_alis
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
.h_unmount:
    mov rsi, help_unmount
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
.h_sys:
    mov rsi, help_sys
    jmp .h_print
.h_semicolon:
    mov rsi, help_semicolon
    jmp .h_print
.h_tilde:
    mov rsi, help_tilde
    jmp .h_print
.h_dollar:
    mov rsi, help_dollar

.h_date:
    mov rsi, help_date
    jmp .h_print
.h_time:
    mov rsi, help_time
    jmp .h_print
.h_write:
    mov rsi, help_write
    jmp .h_print
.h_wig:
    mov rsi, help_wig
    jmp .h_print

.h_shelly:
    mov rsi, help_shelly
    jmp .h_print

.h_take:
    mov rsi, help_take
    jmp .h_print

.h_give:
    mov rsi, help_give
    jmp .h_print

.h_browse:
    mov rsi, help_browse
    jmp .h_print

.h_mouse:
    mov rsi, help_mouse
    jmp .h_print

.h_print:
    mov al, [cur_normal_attr]
    call print_string_attr
    ret

; ------------------------------------------------------------
cmd_sync:
    call fs_save
    jc .fail
    call spinner_clear
    mov rsi, msg_synced
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.fail:
    call spinner_clear
    mov rsi, msg_sync_failed
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
cmd_autosync:
    mov rsi, arg1_buf
    mov rdi, str_on
    call str_eq
    cmp al, 1
    je .as_on
    mov rsi, arg1_buf
    mov rdi, str_off
    call str_eq
    cmp al, 1
    je .as_off
    mov rsi, msg_autosync_status
    mov al, [cur_normal_attr]
    call print_string_attr
    cmp byte [auto_sync_enabled], 1
    je .as_print_on
    mov rsi, str_off
    call print_string
    jmp .as_newline
.as_print_on:
    mov rsi, str_on
    call print_string
.as_newline:
    mov rsi, newline_str
    call print_string
    ret
.as_on:
    mov byte [auto_sync_enabled], 1
    mov rsi, msg_autosync_enabled
    call print_string
    ret
.as_off:
    mov byte [auto_sync_enabled], 0
    mov rsi, msg_autosync_disabled
    call print_string
    ret

maybe_auto_sync:
    cmp byte [auto_sync_enabled], 1
    jne .mas_no
    call fs_save
.mas_no:
    ret

; ------------------------------------------------------------
; cmd_run: "run <file.run>"
; Executes a compiled ShellyForever RUN 0.1 binary.
; ------------------------------------------------------------
cmd_run:
    cmp byte [arg1_buf], 0
    jne .cr_have_arg
    mov rsi, msg_run_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.cr_have_arg:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .cr_not_found
    mov r11, rax
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .cr_not_found

    lea rdi, [fs_io_buf]
    call fs_read_binary_file

    lea rsi, [fs_io_buf]
    mov rdi, str_run_magic1
    call str_line_eq
    cmp al, 1
    jne .cr_bad_header

    call str_next_line
    mov rdi, str_run_magic2
    call str_line_eq
    cmp al, 1
    jne .cr_bad_header

    call str_next_line
    mov rdi, str_run_magic3
    call str_line_eq
    cmp al, 1
    jne .cr_bad_header

    call str_next_line
    mov r12, rsi

    ; Some older .run files were written with a NUL-filled gap between the
    ; header and the stub (the old compile cursor bug), so str_next_line can
    ; stop on that NUL instead of the stub. Scan forward for the stub's first
    ; three bytes (48 8D 35 = lea rsi, [rip+7]); the stub is always the first
    ; such occurrence before the embedded source.
    mov rcx, 128
.cr_stub_scan:
    mov al, [r12]
    cmp al, 0x48
    jne .cr_stub_next
    cmp byte [r12+1], 0x8D
    jne .cr_stub_next
    cmp byte [r12+2], 0x35
    je .cr_stub_found
.cr_stub_next:
    inc r12
    dec rcx
    jnz .cr_stub_scan
    jmp .cr_bad_header
.cr_stub_found:

    ; "run <file> -back" starts the script in the background: it shares the
    ; process slot but is stepped cooperatively by the shell when idle, its
    ; output is captured into a per-process ring for 'prs peek', and the
    ; prompt comes right back.
    mov rsi, arg2_buf
    mov rdi, str_run_back
    call str_eq
    cmp al, 1
    je cmd_run_back

    ; Allocate a process slot so this run shows up in 'prs' and can be
    ; stopped by name/pid via 'prs kill', same as rr scripts.
    call proc_alloc
    cmp rax, -1
    je .cr_toomany

    movzx rax, byte [proc_cur_slot]
    imul rax, 32
    lea rdi, [proc_name + rax]
    mov rsi, str_run_procname
    call str_copy

    mov byte [kill_flag], 0

    mov rsi, msg_run_running
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    movzx rax, byte [proc_cur_slot]
    movzx rax, word [proc_id + rax*2]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, msg_rr_pid1
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, show_num_buf
    call print_string
    mov rsi, msg_rr_pid2
    call print_string

    lea rdi, [kernel_api_table]
    mov qword [rdi + KAPI_PRINT_STRING], print_string
    mov qword [rdi + KAPI_PRINT_STRING_ATTR], print_string_attr
    mov qword [rdi + KAPI_GET_CHAR], get_char
    mov qword [rdi + KAPI_NEWLINE_STR], newline_str
    mov qword [rdi + KAPI_POLL_KILL], party_poll_kill_api
    mov qword [rdi + KAPI_PUSH_VAL], party_push_val
    mov qword [rdi + KAPI_POP_VAL], party_pop_val
    mov qword [rdi + KAPI_VAL_SET_INT], party_val_set_int
    mov qword [rdi + KAPI_VAL_SET_STR], party_val_set_str
    mov qword [rdi + KAPI_VAL_SET_BOOL_TRUE], party_val_set_bool_true
    mov qword [rdi + KAPI_VAL_SET_BOOL_FALSE], party_val_set_bool_false
    mov qword [rdi + KAPI_VAL_SET_NONE], party_val_set_none
    mov qword [rdi + KAPI_OP_BIN], party_op_bin
    mov qword [rdi + KAPI_OP_EQ], party_op_eq
    mov qword [rdi + KAPI_OP_NEQ], party_op_neq
    mov qword [rdi + KAPI_OP_REL], party_op_rel
    mov qword [rdi + KAPI_TRUTHY], party_truthy
    mov qword [rdi + KAPI_PRINT_VALUE], party_print_value
    mov qword [rdi + KAPI_VAR_DECLARE], party_var_declare
    mov qword [rdi + KAPI_VAR_ASSIGN], party_var_assign
    mov qword [rdi + KAPI_VAR_GET_PTR], party_var_get_ptr
    mov qword [rdi + KAPI_VAL_COPY], party_val_copy
    mov qword [rdi + KAPI_INVOKE_FUNC], party_invoke_func
    mov qword [rdi + KAPI_FUNC_FIND], party_func_find
    mov qword [rdi + KAPI_NEG_TOP], party_neg_top
    mov qword [rdi + KAPI_LEX], party_lex
    mov qword [rdi + KAPI_COLLECT_FUNCS], party_collect_funcs
    mov qword [rdi + KAPI_VAL_SET_FLOAT], party_val_set_float
    mov qword [rdi + KAPI_BOOT], party_boot_compiled

    ; A compiled .run program shares the SAME global interpreter state
    ; (value stack, variable table, function table, call depth) as the
    ; tree-walking interpreter above, in case a previous "party foo.pa"
    ; or "run bar.run" left it dirty. Reset it fresh for every run.
    call party_reset_runtime

    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp

    ; Never execute the file's embedded 14-byte entry stub - its bytes are
    ; DATA, and this stub's own encoding is broken (FF 57 E0 decodes as
    ; call [rdi-32], not call [rdi+0xE0]). Skip it and call the compiled
    ; runtime bootstrap directly with rsi = the embedded source (stub+14),
    ; exactly like cmd_run_back does. This also stops a .run file from
    ; running arbitrary machine code as ring-0.
    lea rsi, [r12 + 14]          ; embedded Party source (past the stub)
    mov rdi, kernel_api_table
    mov rax, [rdi + KAPI_BOOT]   ; party_boot_compiled (KAPI_BOOT=0xE0=224,
                                 ; too big for a signed disp8, so nasm uses
                                 ; disp32 - this reads [rdi+0xE0], NOT the
                                 ; [rdi-32] the stub's disp8 fell into)
    call rax

    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx

    movzx rax, byte [proc_cur_slot]
    mov rdi, rax
    call proc_free_slot

    cmp byte [kill_flag], 0
    je .cr_out
    mov rsi, msg_rr_killed
    mov al, ATTR_ERROR
    call print_string_attr
.cr_out:
    ret

.cr_toomany:
    mov rsi, msg_run_toomany
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.cr_bad_header:
    mov rsi, msg_run_badheader
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.cr_not_found:
    mov rsi, msg_no_file
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ============================================================
;  cmd_run_back: "run <file>.run -back". Starts a compiled .run
;  program as a background process. The .run binary embeds its whole
;  Party source (after a 3-line header + the 14-byte entry stub), so
;  we copy that source into the process's own buffer, lex + collect
;  functions right here (so syntax/collection errors are reported
;  immediately), park the resulting interpreter state into the
;  process's save area, and leave it for the idle scheduler to step.
;  Enters with r12 = pointer to the entry stub in fs_io_buf.
; ============================================================
cmd_run_back:
    push rbx
    push r12
    push r13
    push r14
    push r15

    call proc_alloc
    cmp rax, -1
    je .crb_toomany

    movzx r13, byte [proc_cur_slot]     ; slot index
    mov r14, r12
    add r14, 14                         ; embedded Party source (past the stub)

    ; Name the process "run", same as a foreground run.
    mov rax, r13
    imul rax, 32
    lea rdi, [proc_name + rax]
    mov rsi, str_run_procname
    call str_copy

    ; Copy the embedded source into the process's own source buffer.
    lea r15, [proc_bg_src]
    imul rax, r13, BG_SRC_MAX
    add r15, rax
    xor rcx, rcx
.crb_copy:
    mov al, [r14+rcx]
    cmp al, 0
    je .crb_copy_done
    cmp rcx, BG_SRC_MAX-1
    jae .crb_too_big
    mov [r15+rcx], al
    inc rcx
    jmp .crb_copy
.crb_copy_done:
    mov byte [r15+rcx], 0

    ; Lex + collect functions now, so the user sees any error immediately.
    call party_reset_runtime
    mov qword [party_src_base], r15
    mov rsi, r15
    call party_lex
    cmp byte [party_lex_ok], 1
    jne .crb_lex_fail
    call party_collect_funcs
    cmp byte [party_exec_ok], 1
    jne .crb_exec_fail

    ; Point the process's private stack at the bootstrap and park the
    ; freshly-created interpreter state.
    lea rax, [proc_bg_stack]
    imul rcx, r13, BG_STACK_SIZE
    add rax, rcx
    add rax, BG_STACK_SIZE-8
    mov rbx, party_bg_bootstrap
    mov [rax], rbx
    mov [proc_bg_rsp + r13*8], rax

    lea rdi, [proc_bg_ctx]
    imul rax, r13, PARTY_CTX_SIZE
    add rdi, rax
    call party_ctx_save

    mov byte [proc_bg + r13], 1
    mov byte [bg_notice_pending], 0
    mov byte [kill_flag], 0

    mov rsi, msg_run_bg_running
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    movzx rax, byte [proc_cur_slot]
    movzx rax, word [proc_id + rax*2]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, msg_rr_pid1
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, show_num_buf
    call print_string
    mov rsi, msg_rr_pid2
    call print_string
    jmp .crb_out

.crb_toomany:
    mov rsi, msg_run_toomany
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .crb_out

.crb_too_big:
    mov rdi, r13
    call proc_free_slot
    mov rsi, msg_run_bg_big
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, newline_str
    call print_string
    jmp .crb_out

.crb_lex_fail:
    mov rdi, r13
    call proc_free_slot
    mov rsi, msg_run_bg_lexerr
    mov al, ATTR_ERROR
    call print_string_attr
    mov eax, [party_error_line]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, newline_str
    call print_string
    jmp .crb_out

.crb_exec_fail:
    mov rdi, r13
    call proc_free_slot
    mov rsi, msg_run_bg_execerr
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, [party_err_msg_ptr]
    cmp rsi, 0
    je .crb_exec_line
    call print_string
.crb_exec_line:
    mov rsi, msg_party_err_near
    call print_string
    mov eax, [party_error_line]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    call print_string
    mov rsi, newline_str
    call print_string
    jmp .crb_out

.crb_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

str_line_eq:
    push rsi
    push rdi
    push rdx
.sle_loop:
    mov al, [rdi]
    mov dl, [rsi]
    cmp dl, 10
    je .sle_check_term
    cmp dl, 13
    je .sle_check_term
    cmp dl, 0
    je .sle_check_term
    cmp al, dl
    jne .sle_ne
    inc rsi
    inc rdi
    jmp .sle_loop
.sle_check_term:
    cmp byte [rdi], 0
    je .sle_eq
.sle_ne:
    xor al, al
    jmp .sle_out
.sle_eq:
    mov al, 1
.sle_out:
    pop rdx
    pop rdi
    pop rsi
    ret

str_next_line:
.snl_loop:
    mov al, [rsi]
    cmp al, 0
    je .snl_out
    inc rsi
    cmp al, 10
    je .snl_out
    cmp al, 13
    je .snl_cr_check
    jmp .snl_loop
.snl_cr_check:
    cmp byte [rsi], 10
    jne .snl_out
    inc rsi
.snl_out:
    ret

; ------------------------------------------------------------
; cmd_netinfo: show NIC MAC + static IP config, or a message if no NIC.
cmd_netinfo:
    cmp byte [nic_present], 0
    je .no_nic
    mov rsi, msg_ni_mac
    call print_string
    call print_mac
    mov rsi, msg_nl
    call print_string
    mov rsi, msg_ni_drv
    call print_string
    movzx eax, byte [nic_driver_type]
    cmp al, 0
    je .drv_8139
    cmp al, 1
    je .drv_e1000
    mov rsi, msg_ni_drv_8168
    call print_string
    jmp .drv_done
.drv_8139:
    mov rsi, msg_ni_drv_8139
    call print_string
    jmp .drv_done
.drv_e1000:
    mov rsi, msg_ni_drv_e1000
    call print_string
.drv_done:
    mov rsi, msg_ni_iobase
    call print_string
    mov eax, [nic_io_base]
    call print_hex32
    mov rsi, msg_nl
    call print_string
    mov rsi, msg_ni_link
    call print_string
    cmp byte [nic_driver_type], 2
    jne .link_na
    mov edi, [nic_io_base]
    add edi, RTL_IO_PHYSTATUS
    call nic_io_read8
    test al, RTL_PHYSTATUS_LINK
    jz .link_down
    mov rsi, msg_ni_link_up
    call print_string
    jmp .link_done
.link_down:
    mov rsi, msg_ni_link_down
    call print_string
    jmp .link_done
.link_na:
    mov rsi, msg_ni_link_na
    call print_string
.link_done:
    mov rsi, msg_ni_ip
    call print_string
    lea rsi, [nic_ip]
    call print_ip4
    mov rsi, msg_nl
    call print_string
    mov rsi, msg_ni_mask
    call print_string
    lea rsi, [nic_mask]
    call print_ip4
    mov rsi, msg_nl
    call print_string
    mov rsi, msg_ni_gw
    call print_string
    lea rsi, [nic_gw]
    call print_ip4
    mov rsi, msg_nl
    call print_string
    mov rsi, msg_ni_dns
    call print_string
    lea rsi, [nic_dns]
    call print_ip4
    mov rsi, msg_nl
    call print_string
    ret
.no_nic:
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
; cmd_net: net ip|gw|dns <a.b.c.d> | net on|off|reset
cmd_net:
    cmp byte [arg1_buf], 0
    je .usage
    ; "net on" / "net off" / "net reset" don't need arg2
    lea rsi, [arg1_buf]
    mov rdi, str_net_on
    call str_eq
    cmp al, 1
    je .net_on
    lea rsi, [arg1_buf]
    mov rdi, str_net_off
    call str_eq
    cmp al, 1
    je .net_off
    lea rsi, [arg1_buf]
    mov rdi, str_net_reset
    call str_eq
    cmp al, 1
    je .net_reset
    ; remaining subcommands need arg2
    cmp byte [arg2_buf], 0
    je .usage
    lea rsi, [arg1_buf]
    mov rdi, str_net_ip
    call str_eq
    cmp al, 1
    je .set_ip
    lea rsi, [arg1_buf]
    mov rdi, str_net_gw
    call str_eq
    cmp al, 1
    je .set_gw
    lea rsi, [arg1_buf]
    mov rdi, str_net_dns
    call str_eq
    cmp al, 1
    je .set_dns
.usage:
    mov rsi, msg_net_usage
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.net_on:
    cmp byte [nic_present], 0
    je .do_reinit
    mov rsi, msg_net_already_on
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.do_reinit:
    call nic_init
    cmp byte [nic_present], 0
    je .on_fail
    mov rsi, msg_net_on_ok
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.on_fail:
    mov rsi, msg_net_on_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.net_off:
    cmp byte [nic_present], 0
    je .off_already
    call nic_shutdown
    mov rsi, msg_net_off_ok
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.off_already:
    mov rsi, msg_net_already_off
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.net_reset:
    cmp byte [nic_present], 0
    jne .do_reset
    ; NIC isn't active - just try init
    call nic_init
    cmp byte [nic_present], 0
    je .on_fail
    mov rsi, msg_net_on_ok
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.do_reset:
    call nic_shutdown
    call nic_init
    cmp byte [nic_present], 0
    je .on_fail
    mov rsi, msg_net_reset_ok
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.set_ip:
    lea rsi, [arg2_buf]
    lea rdi, [nic_ip]
    call ip_parse_to
    jc .bad
    ret
.set_gw:
    lea rsi, [arg2_buf]
    lea rdi, [nic_gw]
    call ip_parse_to
    jc .bad
    ; routing changed - drop the ARP cache so the nexthop re-resolves
    xor al, al
    mov byte [nic_arp_next], 0
    lea rdi, [nic_arp_cache]
    mov rcx, NIC_ARP_CACHE_ENTRIES*10
    rep stosb
    ret
.set_dns:
    lea rsi, [arg2_buf]
    lea rdi, [nic_dns]
    call ip_parse_to
    jc .bad
    ret
.bad:
    mov rsi, msg_net_bad_ip
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg2_buf
    call print_string
    mov rsi, msg_nl
    call print_string
    ret

; ------------------------------------------------------------
; cmd_dns: dns <hostname> - resolve via the configured DNS server.
cmd_dns:
    cmp byte [nic_present], 0
    je .no_nic
    cmp byte [arg1_buf], 0
    jne .have
    mov rsi, msg_dns_usage
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.have:
    lea rsi, [arg1_buf]
    call dns_query
    cmp eax, 0xFFFFFFFF
    je .fail
    mov r12d, eax
    mov rsi, msg_dns_res
    call print_string
    lea rsi, [arg1_buf]
    call print_string
    mov rsi, msg_dns_equals
    call print_string
    mov r12d, [nic_dns_result]
    lea rsi, [nic_dns_result]
    call print_ip4
    mov rsi, msg_nl
    call print_string
    ret
.fail:
    mov rsi, msg_dns_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.no_nic:
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
; cmd_dhcp: dhcp - request IP lease via DHCP.
cmd_dhcp:
    cmp byte [nic_present], 0
    je .no_nic
    mov rsi, msg_dhcp_start
    mov al, [cur_normal_attr]
    call print_string_attr
    mov dword [nic_ip], 0
    mov byte [dhcp_done], 0
    mov dword [nic_rx_seen], 0
    mov byte [nic_diag_verbose], 1
    mov byte [nic_diag_tx_dumped], 0
    mov byte [nic_diag_rx_count], 0
    mov byte [nic_dns_seen], 0
    call rtc_sec_now
    add eax, 0x12345678
    mov [dhcp_xid], eax
    call dhcp_send_discover
    jc .send_fail
    call rtc_sec_now
    mov r13, rax
    mov byte [dhcp_retries], 0
.dhcp_wait:
    call netpoll
    cmp byte [dhcp_done], 1
    je .success
    call rtc_sec_now
    sub rax, r13
    cmp rax, 6                    ; ~6s per attempt (real switches/NICs are
    jb .dhcp_wait                 ; much slower to settle than QEMU's link)
    cmp byte [dhcp_retries], 3    ; up to 3 retries = 4 attempts, ~24s total
    jae .fail
    inc byte [dhcp_retries]
    call dhcp_send_discover
    jc .send_fail
    call rtc_sec_now
    mov r13, rax
    jmp .dhcp_wait
.success:
    mov byte [nic_diag_verbose], 0
    cmp byte [nic_dns_seen], 1
    je .dns_ok
    mov eax, [nic_gw]
    mov [nic_dns], eax
.dns_ok:
    mov rsi, msg_dhcp_ok
    call print_string
    mov rsi, msg_ni_ip
    call print_string
    lea rsi, [nic_ip]
    call print_ip4
    mov rsi, msg_nl
    call print_string
    mov rsi, msg_ni_mask
    call print_string
    lea rsi, [nic_mask]
    call print_ip4
    mov rsi, msg_nl
    call print_string
    mov rsi, msg_ni_gw
    call print_string
    lea rsi, [nic_gw]
    call print_ip4
    mov rsi, msg_nl
    call print_string
    mov rsi, msg_ni_dns
    call print_string
    lea rsi, [nic_dns]
    call print_ip4
    mov rsi, msg_nl
    call print_string
    ret
.fail:
    mov byte [nic_diag_verbose], 0
    mov rsi, msg_dhcp_fail
    mov al, ATTR_ERROR
    call print_string_attr
    mov eax, [nic_rx_seen]
    test eax, eax
    jnz .fail_had_frames
    mov rsi, msg_dhcp_no_frames
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .fail_count
.fail_had_frames:
    mov rsi, msg_dhcp_had_frames
    mov al, ATTR_ERROR
    call print_string_attr
.fail_count:
    mov rsi, msg_dhcp_rx_seen
    mov al, [cur_normal_attr]
    call print_string_attr
    mov eax, [nic_rx_seen]
    call print_hex32
    mov rsi, msg_nl
    call print_string
    ret
.send_fail:
    mov byte [nic_diag_verbose], 0
    mov rsi, msg_dhcp_send_fail
    mov al, ATTR_ERROR
    call print_string_attr
    cmp byte [nic_driver_type], 2
    jne .send_fail_done
    call netdiag_dump_tx
.send_fail_done:
    ret
.no_nic:
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; netdiag_dump_tx: prints, for the RTL8168 path, the PCI Status register
; (config offset 0x04, upper 16 bits - Master/Target Abort and parity error
; bits live here) and the raw failed TX descriptor's command dword plus a
; fresh TPPoll readback. This is diagnostic only - it tells us whether the
; hardware itself is reporting a bus-level error (abort/parity) versus the
; descriptor engine silently never touching the slot at all, which are two
; very different bugs that "TX error" alone can't distinguish.
netdiag_dump_tx:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r10

    ; which frame actually failed - ARP broadcast vs. a real data/segment
    ; send are two very different failure stories (e.g. an ARP TX failure
    ; means the handshake/segment never even got a chance to go out).
    cmp byte [nic_last_tx_ctx], 0
    je .ndt_ctx_seg
    mov rsi, msg_diag_txctx_arp
    jmp .ndt_ctx_print
.ndt_ctx_seg:
    mov rsi, msg_diag_txctx_seg
.ndt_ctx_print:
    mov al, [cur_normal_attr]
    call print_string_attr

    ; PCI Status register: dword at cfg offset 0x04 covers Command (low 16)
    ; + Status (high 16); shift down to isolate Status.
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_CMD
    call pci_read32
    push rax                         ; keep the raw dword safe across the prints below
                                      ; (r10 isn't guaranteed to survive print calls)
    shr eax, 16
    mov rsi, msg_diag_pcists
    push rax
    mov al, [cur_normal_attr]
    call print_string_attr
    pop rax
    call print_hex32
    mov rsi, msg_nl
    call print_string

    ; Status bits (8/11/12/13/14/15) are write-1-to-clear; Command (low 16)
    ; is plain RW. Writing back exactly what we just read clears any latched
    ; error bits without touching Command, so the NEXT dump reflects fresh
    ; state instead of re-showing the same abort forever after the first
    ; time it was ever set.
    pop r10                          ; the raw dword saved above
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_CMD
    call pci_write32

    ; raw command dword of the descriptor slot that just failed (rtl_tx_idx
    ; was already advanced on send, so back it up one slot, wrapping).
    mov eax, [rtl_tx_idx]
    dec eax
    jns .ndt_noeor
    mov eax, RTL_TX_DESC_COUNT - 1
.ndt_noeor:
    shl eax, 4
    lea rdi, [rtl_tx_desc + rax]
    mov eax, [rdi]
    mov rsi, msg_diag_txdesc
    push rax
    mov al, [cur_normal_attr]
    call print_string_attr
    pop rax
    call print_hex32
    mov rsi, msg_nl
    call print_string

    ; fresh TPPoll readback - if NPQ (bit6) is still set, the chip never
    ; even acknowledged the poll kick.
    mov edi, [nic_io_base]
    add edi, RTL_IO_TPPOLL
    call nic_io_read8
    movzx eax, al
    mov rsi, msg_diag_tppoll
    push rax
    mov al, [cur_normal_attr]
    call print_string_attr
    pop rax
    call print_hex32
    mov rsi, msg_nl
    call print_string

    ; real wall-clock seconds actually spent waiting before this failure was
    ; declared - printed in decimal so it reads at a glance against the
    ; ~5-6s budget, instead of inferring timing from how a failure "felt".
    mov rsi, msg_diag_waitsecs
    mov al, [cur_normal_attr]
    call print_string_attr
    movzx eax, byte [nic_tx_wait_elapsed]
    call tcp_print_dec
    mov rsi, msg_nl
    call print_string

    ; Raw start/end rtc_sec_now() readings plus the actual number of
    ; second-boundary ticks the wait loop observed, printed separately from
    ; the subtracted "elapsed" figure above. If elapsed reads suspiciously
    ; low (e.g. 0) despite the budget being generous, this tells us whether
    ; that's a bad subtraction (start/end look like a real ~20s apart once
    ; you account for a minute wrap) or a genuinely fast exit (ticks well
    ; below the ~21 a real timeout should produce) - two very different
    ; bugs that a single "elapsed: 0" can't distinguish between.
    mov rsi, msg_diag_rawsec
    mov al, [cur_normal_attr]
    call print_string_attr
    movzx eax, byte [nic_tx_wait_start]
    call tcp_print_dec
    mov rsi, msg_diag_rawsec_sep
    call print_string
    movzx eax, byte [nic_tx_wait_end]
    call tcp_print_dec
    mov rsi, msg_diag_rawsec_ticks
    call print_string
    movzx eax, byte [nic_tx_wait_ticks]
    call tcp_print_dec
    mov rsi, msg_nl
    call print_string

    pop r10
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    call netdiag_print_chip_id
    ret

; netdiag_print_chip_id: decodes nic_hwver_raw (captured right after reset)
; into a chip revision family using the same reg/ICVerID bit split real
; Realtek driver source uses (reg = val & 0x7C800000, ICVerID = val &
; 0x00700000). This only covers the older, well-documented 8168B/C/CP/D/DP
; generations - if none of those match, that itself is useful information:
; it means this is an 8168E-or-later chip, which needs additional
; MAC-OCP/PHY init pokes that aren't part of any register-level datasheet.
netdiag_print_chip_id:
    push rax
    push rcx
    push rsi

    mov eax, [nic_hwver_raw]
    mov rsi, msg_diag_chipraw
    push rax
    mov al, [cur_normal_attr]
    call print_string_attr
    pop rax
    call print_hex32
    mov rsi, msg_nl
    call print_string

    mov eax, [nic_hwver_raw]
    mov ecx, eax
    and eax, 0x7C800000       ; reg
    and ecx, 0x00700000       ; ICVerID (unused for the coarse match below,
                               ; kept here for future finer-grained lookup)

    mov rsi, msg_diag_chipname
    mov al, [cur_normal_attr]
    call print_string_attr

    cmp eax, 0x30000000
    je .m_8168b
    cmp eax, 0x38000000
    je .m_8168b
    cmp eax, 0x3C000000
    je .m_8168c
    cmp eax, 0x3C800000
    je .m_8168cp
    cmp eax, 0x28000000
    je .m_8168d
    cmp eax, 0x28800000
    je .m_8168dp
    jmp .m_unknown
.m_8168b:
    mov rsi, msg_chip_8168b
    jmp .m_print
.m_8168c:
    mov rsi, msg_chip_8168c
    jmp .m_print
.m_8168cp:
    mov rsi, msg_chip_8168cp
    jmp .m_print
.m_8168d:
    mov rsi, msg_chip_8168d
    jmp .m_print
.m_8168dp:
    mov rsi, msg_chip_8168dp
    jmp .m_print
.m_unknown:
    mov rsi, msg_chip_unknown
.m_print:
    call print_string
    mov rsi, msg_nl
    call print_string

    pop rsi
    pop rcx
    pop rax
    ret

dhcp_send_discover:
    push rax
    push rbx
    push rcx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    lea rdi, [net_build_buf]
    mov byte [rdi], 1
    mov byte [rdi+1], 1
    mov byte [rdi+2], 6
    mov byte [rdi+3], 0
    mov eax, [dhcp_xid]
    mov [rdi+4], eax
    mov word [rdi+8], 0
    ; flags field (offset 10): bit15 = broadcast flag, requests the server
    ; reply via L2 broadcast since we have no IP yet. `mov word ..., 0x8000`
    ; would store this little-endian (byte 0x00 then 0x80), landing as
    ; 0x0080 on the wire - broadcast bit never actually set, and a reserved
    ; bit (must be zero per RFC 2131) set instead. Write the bytes directly
    ; in wire order instead.
    mov byte [rdi+10], 0x80
    mov byte [rdi+11], 0x00
    mov dword [rdi+12], 0
    mov dword [rdi+16], 0
    mov dword [rdi+20], 0
    mov dword [rdi+24], 0
    ; chaddr lives at offset 28. rbx was computed to point there, but
    ; rep movsb reads/writes through rsi/rdi implicitly - it doesn't care
    ; about rbx at all. Without moving rdi to rbx first, this copy landed
    ; at rdi's current value (offset 0), stomping op/htype/hlen/hops and
    ; the low two bytes of xid with the MAC address, while chaddr itself
    ; was left to be zeroed by the padding step below - so every discover
    ; went out with op=0 (not 1/BOOTREQUEST) and a mangled xid, and the
    ; server had every reason to silently drop it.
    lea rsi, [nic_mac]
    add rdi, 28
    mov rcx, 6
    rep movsb
    ; zero the rest of chaddr (10 bytes) plus all of sname (64) and file
    ; (128) - previously only the first 10 zero-padding bytes after
    ; chaddr were touched at all; the remaining ~198 bytes were never
    ; initialized and carried over whatever net_build_buf last held,
    ; which is the "random numbers, mostly 0s" seen on the wire dump.
    xor al, al
    mov rcx, 202
    rep stosb
    lea rdi, [net_build_buf + 236]
    mov byte [rdi], 99
    mov byte [rdi+1], 130
    mov byte [rdi+2], 83
    mov byte [rdi+3], 99
    add rdi, 4
    mov byte [rdi], 53
    mov byte [rdi+1], 1
    mov byte [rdi+2], 1
    add rdi, 3
    ; option 61 (client identifier: hwtype + mac, 7 bytes of value) was
    ; tagged with code 6 instead of 61 - 6 is "domain name server", which
    ; a server receiving it from a client has no defined use for. Servers
    ; tolerate/ignore unrecognized options so this wasn't what was
    ; blocking the lease, but it's still wrong and worth fixing.
    mov byte [rdi], 61
    mov byte [rdi+1], 7
    mov byte [rdi+2], 1
    push rdi
    add rdi, 3
    lea rsi, [nic_mac]
    mov rcx, 6
    rep movsb
    pop rdi
    ; option 61 is tag+len+value = 1+1+7 = 9 bytes total, not 7. The old
    ; +7 landed 2 bytes short of the option's real end, so the next
    ; option's tag+len bytes got written over what should have been the
    ; MAC's last 2 bytes - and since option 61's length byte still
    ; (truthfully) claims 7 value bytes, a compliant parser reads 2 bytes
    ; too far into the next option, then finds garbage instead of a tag
    ; byte where option 55 should start, and everything after is
    ; misaligned nonsense to the server.
    add rdi, 9
    mov byte [rdi], 55
    mov byte [rdi+1], 4
    mov byte [rdi+2], 1
    mov byte [rdi+3], 3
    mov byte [rdi+4], 6
    mov byte [rdi+5], 15
    add rdi, 6
    mov byte [rdi], 57
    mov byte [rdi+1], 2
    mov byte [rdi+2], 2
    mov byte [rdi+3], 0x40
    add rdi, 4
    mov byte [rdi], 255
    inc rdi
    lea rcx, [net_build_buf]
    sub rdi, rcx
    mov rsi, net_build_buf
    mov ecx, edi
    mov r8d, 0xFFFFFFFF
    mov r9w, 67
    mov r10w, 68
    call nic_send_udp
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

dhcp_send_request:
    push rax
    push rbx
    push rcx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    lea rdi, [net_build_buf]
    mov byte [rdi], 1
    mov byte [rdi+1], 1
    mov byte [rdi+2], 6
    mov byte [rdi+3], 0
    mov eax, [dhcp_xid]
    mov [rdi+4], eax
    mov word [rdi+8], 0
    ; same flags-field byte-order bug as dhcp_send_discover - see comment
    ; there. Write the broadcast-flag bytes directly in wire order.
    mov byte [rdi+10], 0x80
    mov byte [rdi+11], 0x00
    mov dword [rdi+12], 0
    mov eax, [dhcp_offered_ip]
    mov [rdi+16], eax
    ; same chaddr-offset bug as dhcp_send_discover - see comment there.
    ; rdi is still at the buffer base here, so point it at chaddr (offset
    ; 28) directly instead of leaving it at offset 0.
    lea rsi, [nic_mac]
    add rdi, 28
    mov rcx, 6
    rep movsb
    ; zero the rest of chaddr + all of sname/file, same as discover.
    xor al, al
    mov rcx, 202
    rep stosb
    lea rdi, [net_build_buf + 236]
    mov byte [rdi], 99
    mov byte [rdi+1], 130
    mov byte [rdi+2], 83
    mov byte [rdi+3], 99
    add rdi, 4
    mov byte [rdi], 53
    mov byte [rdi+1], 1
    mov byte [rdi+2], 3
    add rdi, 3
    mov byte [rdi], 50
    mov byte [rdi+1], 4
    mov eax, [dhcp_offered_ip]
    mov [rdi+2], eax
    add rdi, 6
    ; same option-61-mislabeled-as-6 bug as dhcp_send_discover - see
    ; comment there.
    mov byte [rdi], 61
    mov byte [rdi+1], 7
    mov byte [rdi+2], 1
    push rdi
    add rdi, 3
    lea rsi, [nic_mac]
    mov rcx, 6
    rep movsb
    pop rdi
    ; same off-by-2 as dhcp_send_discover - option 61 is 9 bytes total
    ; (tag+len+7 value), not 7, so the END marker was landing 2 bytes
    ; into where the MAC's last 2 bytes should be, and option 61's
    ; length byte still claimed a 7-byte value that ran past the real
    ; end of the packet.
    add rdi, 9
    mov byte [rdi], 255
    inc rdi
    lea rcx, [net_build_buf]
    sub rdi, rcx
    mov rsi, net_build_buf
    mov ecx, edi
    mov r8d, 0xFFFFFFFF
    mov r9w, 67
    mov r10w, 68
    call nic_send_udp
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret
    inc rdi
    lea rcx, [net_build_buf]
    sub rdi, rcx
    mov rsi, net_build_buf
    mov ecx, edi
    mov r8d, 0xFFFFFFFF
    mov r9w, 67
    mov r10w, 68
    call nic_send_udp
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

dhcp_handle_packet:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r12
    push r13
    push r14
    push r15
    movzx eax, byte [nic_rx_frame+14]
    and al, 0x0F
    imul eax, 4
    lea r14, [nic_rx_frame + 14 + rax + 8]
    ; r14-8 is the UDP header. Its length field (offset +4/+5, big-endian)
    ; tells us exactly where the DHCP message ends. The option scan below
    ; MUST be bounded by this: some servers do not put a 255 end marker in
    ; their reply, and the old parser only worked because it dispatched as
    ; soon as it saw option 53. The rewrite moved dispatch to the 255
    ; marker, so on such a server the OFFER was never answered and lease
    ; acquisition failed. Stop scanning at the real message end instead.
    lea rsi, [r14 - 8]
    movzx eax, byte [rsi+4]
    shl eax, 8
    movzx edx, byte [rsi+5]
    or eax, edx
    sub eax, 8
    lea r15, [r14 + rax]
    ; Some embedded routers report a UDP length shorter than the real
    ; message. Never let the scan floor stop before it can at least read
    ; the first options (option 53 is almost always first), or such a
    ; server's OFFER would be skipped entirely and DHCP would time out.
    lea rdx, [r14 + 272]
    cmp r15, rdx
    jae .dh_bound_floor
    mov r15, rdx
.dh_bound_floor:
    ; clamp to a standard 300-byte DHCP message so a bad length field can't
    ; walk the scan outside the frame.
    lea rdx, [r14 + 300]
    cmp r15, rdx
    jbe .dh_bound_ok
    mov r15, rdx
.dh_bound_ok:
    mov eax, [r14+4]
    cmp eax, [dhcp_xid]
    jne .dh_ret
    mov eax, [r14+16]
    test eax, eax
    jz .dh_ret
    mov [dhcp_offered_ip], eax
    lea rsi, [r14 + 240]
    mov byte [dhcp_msg_type], 0
.dh_opt_loop:
    cmp rsi, r15
    jae .dh_opts_end
    mov al, [rsi]
    cmp al, 255
    je .dh_opts_end
    test al, al
    jz .dh_opt_pad
    movzx ecx, byte [rsi+1]
    cmp al, 53
    jne .dh_check_mask
    mov bl, [rsi+2]
    mov [dhcp_msg_type], bl
    jmp .dh_opt_next
.dh_check_mask:
    cmp al, 1
    jne .dh_check_router
    mov eax, [rsi+2]
    mov [nic_mask], eax
    jmp .dh_opt_next
.dh_check_router:
    cmp al, 3
    jne .dh_check_dns
    mov eax, [rsi+2]
    mov [nic_gw], eax
    jmp .dh_opt_next
.dh_check_dns:
    cmp al, 6
    jne .dh_opt_next
    mov eax, [rsi+2]
    mov [nic_dns], eax
    mov byte [nic_dns_seen], 1
.dh_opt_next:
    add rsi, 2
    add rsi, rcx
    jmp .dh_opt_loop
.dh_opt_pad:
    inc rsi
    jmp .dh_opt_loop
.dh_opts_end:
    cmp byte [dhcp_msg_type], 2
    je .dh_offer
    cmp byte [dhcp_msg_type], 5
    je .dh_ack
    jmp .dh_ret
.dh_offer:
    call dhcp_send_request
    jmp .dh_ret
.dh_ack:
    mov eax, [dhcp_offered_ip]
    mov [nic_ip], eax
    mov byte [dhcp_done], 1
    jmp .dh_ret
.dh_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
; cmd_bounce: bounce <host> - ICMP echo with a ~2s (retry: ~3s) timeout.
cmd_bounce:
    cmp byte [nic_present], 0
    je .no_nic
    cmp byte [arg1_buf], 0
    jne .have
    mov rsi, msg_bounce_usage
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.have:
    lea rsi, [arg1_buf]
    call dns_query
    cmp eax, 0xFFFFFFFF
    je .unresolved
    mov [nic_bounce_target], eax
    mov byte [nic_echo_retry], 0
    mov byte [nic_diag_verbose], 1
    mov byte [nic_diag_tx_dumped], 0
    mov byte [nic_diag_rx_count], 0
    call bounce_send
    jc .sendfail
    mov byte [nic_echo_got], 0
    call rtc_sec_now
    mov r13, rax
.cb_wait:
    call netpoll
    cmp byte [nic_echo_got], 0
    jne .cb_reply
    call rtc_sec_now
    cmp eax, r13d
    jne .cb_tick
    jmp .cb_wait
.cb_tick:
    cmp byte [nic_echo_retry], 0
    jne .cb_timeout
    mov byte [nic_echo_retry], 1
    call bounce_send
    jc .sendfail
    call rtc_sec_now
    mov r13, rax
    jmp .cb_wait
.cb_reply:
    mov byte [nic_diag_verbose], 0
    mov rsi, msg_bounce_reply
    call print_string
    lea rsi, [nic_echo_src_ip]
    call print_ip4
    mov rsi, msg_bounce_bytes
    call print_string
    ret
.cb_timeout:
    mov byte [nic_diag_verbose], 0
    mov rsi, msg_bounce_timeout
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.sendfail:
    mov byte [nic_diag_verbose], 0
    mov rsi, msg_bounce_timeout
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.unresolved:
    mov rsi, msg_net_unresolved
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.no_nic:
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
; cmd_monitor: monitor <host> - ping every ~2s, one line per reply,
; Esc stops. Pressing Esc also cancels a stuck wait.
cmd_monitor:
    cmp byte [nic_present], 0
    je .no_nic
    cmp byte [arg1_buf], 0
    jne .have
    mov rsi, msg_monitor_usage
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.have:
    lea rsi, [arg1_buf]
    call dns_query
    cmp eax, 0xFFFFFFFF
    je .unresolved
    mov [nic_bounce_target], eax
    mov byte [kill_flag], 0
    mov byte [nic_diag_verbose], 1
    mov byte [nic_diag_tx_dumped], 0
    mov byte [nic_diag_rx_count], 0
.cm_loop:
    mov byte [nic_echo_got], 0
    mov byte [nic_echo_retry], 0
    call bounce_send
    jc .cm_sendfail
    call rtc_sec_now
    mov r13, rax
.cm_wait:
    call kbd_poll
    cmp byte [kill_flag], 0
    jne .cm_stop
    call netpoll
    cmp byte [nic_echo_got], 0
    jne .cm_reply
    call rtc_sec_now
    cmp eax, r13d
    jne .cm_tick
    jmp .cm_wait
.cm_tick:
    cmp byte [nic_echo_retry], 0
    jne .cm_timedout
    mov byte [nic_echo_retry], 1
    call bounce_send
    jc .cm_sendfail
    call rtc_sec_now
    mov r13, rax
    jmp .cm_wait
.cm_reply:
    mov byte [nic_diag_verbose], 0
    mov rsi, msg_bounce_reply
    call print_string
    lea rsi, [nic_echo_src_ip]
    call print_ip4
    mov rsi, msg_bounce_bytes
    call print_string
    jmp .cm_loop
.cm_timedout:
    mov byte [nic_diag_verbose], 0
    mov rsi, msg_monitor_timeout
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cm_loop
.cm_sendfail:
    mov byte [nic_diag_verbose], 0
    mov rsi, msg_monitor_timeout
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .cm_loop
.cm_stop:
    mov byte [nic_diag_verbose], 0
    mov byte [kill_flag], 0
    mov rsi, msg_monitor_stopped
    mov al, [cur_normal_attr]
    call print_string_attr
    ret
.unresolved:
    mov rsi, msg_net_unresolved
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.no_nic:
    mov rsi, msg_net_no_nic
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
cmd_dscan:
    push r13
    push r15
    mov rsi, msg_dscan_header
    mov al, [cur_normal_attr]
    call print_string_attr
    xor r15, r15                ; found-any flag
    xor r13, r13                ; device id
.scan:
    cmp r13, TOTAL_DEVICES
    jae .done
    call spinner_step
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
    je .valid_sffs
    cmp byte [fs_super_buf+4], SFFS_VERSION_V2
    jne .other
.valid_sffs:
    ; valid SFFS volume
    mov r15, 1
    mov rsi, msg_dscan_found1   ; "  device "
    mov al, [cur_normal_attr]
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
    mov al, [cur_normal_attr]
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
    mov rsi, msg_dscan_orig     ; " - fmt target: "
    call print_string
    mov al, r13b
    call gen_orig_label
    mov rsi, orig_label_buf
    call print_string
    mov rsi, newline_str
    call print_string
.next:
    inc r13
    jmp .scan
.done:
    call spinner_clear
    cmp r15, 0
    jne .has
    mov rsi, msg_dscan_none
    mov al, [cur_normal_attr]
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
;   fmt <label>                       first unformatted drive gets this label
;   fmt <label> -force                first present drive (even an existing volume)
;   fmt <target> <new-label> [-force] format a SPECIFIC drive: <target> is
;                                      either the original label dscan shows
;                                      for it ("disk0", "disk1", ...) or an
;                                      existing SFFS volume's current label
;                                      (requires -force to reformat it)
; The boot drive (device 0) is never touched unless -force is given.
cmd_format:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_fmt_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    xor r15b, r15b                      ; force = 0 by default
    cmp byte [arg2_buf], 0
    je .single_setup                    ; fmt <label>
    mov rsi, arg2_buf
    mov rdi, str_force
    call str_eq
    cmp al, 1
    je .single_force_setup              ; fmt <label> -force
    jmp .target_setup                   ; fmt <target> <new-label> [-force]

.single_setup:
    mov rsi, arg1_buf
    call str_len
    cmp rax, 32
    jae .too_long
    lea rdi, [fmt_new_label]
    mov rsi, arg1_buf
    call str_copy
    jmp .scan_first_unformatted

.single_force_setup:
    mov rsi, arg1_buf
    call str_len
    cmp rax, 32
    jae .too_long
    mov r15b, 1
    lea rdi, [fmt_new_label]
    mov rsi, arg1_buf
    call str_copy
    jmp .scan_first_unformatted

.target_setup:
    mov rsi, arg2_buf
    call str_len
    cmp rax, 32
    jae .too_long
    mov rsi, arg3_buf
    mov rdi, str_force
    call str_eq
    cmp al, 1
    jne .ts_noforce
    mov r15b, 1
.ts_noforce:
    lea rdi, [fmt_new_label]
    mov rsi, arg2_buf
    call str_copy
    jmp .scan_by_target

; --- form 1: first unformatted drive (or, with -force, first present drive
; that already has an SFFS volume) - original behaviour, unchanged. ---
.scan_first_unformatted:
    xor r13, r13                ; device being scanned
    xor rbx, rbx                ; last valid SFFS device seen (for -force)
    mov r14b, 0                 ; any valid SFFS device seen?
.fu_scan:
    cmp r13, TOTAL_DEVICES
    jae .fu_scan_done
    mov al, r13b
    call disk_select_device
    mov rax, SUPER_LBA
    lea rdi, [fs_super_buf]
    call disk_read_sector
    jc .fu_next                 ; absent
    cmp byte [fs_super_buf+0], 'S'
    jne .fu_unformatted
    cmp byte [fs_super_buf+1], 'F'
    jne .fu_unformatted
    cmp byte [fs_super_buf+2], 'F'
    jne .fu_unformatted
    cmp byte [fs_super_buf+3], 'S'
    jne .fu_unformatted
    cmp byte [fs_super_buf+4], SFFS_VERSION
    je .fu_is_sffs
    cmp byte [fs_super_buf+4], SFFS_VERSION_V2
    jne .fu_unformatted
.fu_is_sffs:
    ; already an SFFS volume - remember it for the -force path
    mov rbx, r13
    mov r14b, 1
    jmp .fu_next
.fu_unformatted:
    ; skip the boot drive ([boot_device]) unless -force; it holds the OS
    movzx eax, byte [boot_device]
    cmp r13, rax
    je .fu_next
    jmp .format_target
.fu_next:
    inc r13
    jmp .fu_scan
.fu_scan_done:
    cmp r15b, 1
    jne .fu_none
    cmp r14b, 1
    jne .fu_none
    mov r13, rbx
    jmp .format_target
.fu_none:
    mov rsi, msg_fmt_none
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; --- form 2: a specific drive, chosen by its original "diskN" label or by
; an existing SFFS label. ---
.scan_by_target:
    xor r13, r13
.tg_scan:
    cmp r13, TOTAL_DEVICES
    jae .tg_not_found
    mov al, r13b
    call disk_select_device
    mov rax, SUPER_LBA
    lea rdi, [fs_super_buf]
    call disk_read_sector
    jc .tg_next                 ; absent - can't be a target
    ; does the original "diskN" label match?
    mov al, r13b
    call gen_orig_label
    mov rsi, arg1_buf
    mov rdi, orig_label_buf
    call str_eq
    cmp al, 1
    je .tg_found_orig
    ; does it already hold an SFFS volume whose label matches?
    cmp byte [fs_super_buf+0], 'S'
    jne .tg_next
    cmp byte [fs_super_buf+1], 'F'
    jne .tg_next
    cmp byte [fs_super_buf+2], 'F'
    jne .tg_next
    cmp byte [fs_super_buf+3], 'S'
    jne .tg_next
    cmp byte [fs_super_buf+4], SFFS_VERSION
    je .tg_is_sffs
    cmp byte [fs_super_buf+4], SFFS_VERSION_V2
    jne .tg_next
.tg_is_sffs:
    mov rsi, arg1_buf
    lea rdi, [fs_super_buf + SUPER_LABEL_OFF]
    call str_eq
    cmp al, 1
    jne .tg_next
    ; matched an existing SFFS volume by its current label - reformatting
    ; it (even to the same label) is destructive, so require -force
    cmp r15b, 1
    je .format_target
    mov rsi, msg_fmt_already
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.tg_found_orig:
    ; matched by the original diskN label - still don't touch the boot
    ; drive ([boot_device]) unless -force
    movzx eax, byte [boot_device]
    cmp r13, rax
    jne .format_target
    cmp r15b, 1
    je .format_target
    mov rsi, msg_fmt_boot_drive
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.tg_next:
    inc r13
    jmp .tg_scan
.tg_not_found:
    mov rsi, msg_fmt_no_such
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

.too_long:
    mov rsi, msg_fmt_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret

.format_target:
    ; format the drive now selected in r13, labelling it fmt_new_label
    mov al, r13b
    call disk_select_device
    call spinner_step
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
    mov rsi, fmt_new_label
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
    ; node_next: every node starts with no continuation
    mov rdi, fs_super_buf
    mov rcx, 512 / 2
    mov ax, 0xFFFF
    rep stosw
    mov rax, NEXT_LBA
    lea rsi, [fs_super_buf]
    call disk_write_sector
    jc .disk_err
    ; node_name: root named <label>, then zero sectors
    mov rdi, fs_super_buf
    mov rcx, 512 / 8
    xor rax, rax
    rep stosq
    mov rsi, fmt_new_label
    lea rdi, [fs_super_buf]
    call str_copy
    mov rax, NAME_LBA
    mov rcx, NAME_SECTORS
.name_wr:
    push rax
    push rcx
    call spinner_step
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
    call spinner_step
    lea rsi, [fs_super_buf]
    call disk_write_sector
    pop rcx
    pop rax
    jc .disk_err
    inc rax
    loop .content_wr
    ; node_bin_len: zero sectors
    mov rax, BINLEN_LBA
    mov rcx, BINLEN_SECTORS
.binlen_wr:
    push rax
    push rcx
    call spinner_step
    lea rsi, [fs_super_buf]
    call disk_write_sector
    pop rcx
    pop rax
    jc .disk_err
    inc rax
    loop .binlen_wr
    call spinner_clear
    ; report
    mov rsi, msg_fmt_ok1
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, fmt_new_label
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

; gen_orig_label: al = device id. Fills orig_label_buf with that device's
; original, always-available label ("disk0", "disk1", ...), derived purely
; from its slot number so it's stable and known before anything is ever
; formatted - this is what 'fmt <target> <new-label>' matches against to
; pick a specific drive instead of guessing "the first unformatted one".
gen_orig_label:
    push rax
    push rdi
    push rsi
    movzx rax, al
    lea rdi, [orig_label_buf]
    mov rsi, str_disk_prefix
    call str_copy
    lea rdi, [orig_label_num_tmp]
    call int_to_str
    lea rdi, [orig_label_buf]
    mov rsi, orig_label_num_tmp
    call str_append
    pop rsi
    pop rdi
    pop rax
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
    call spinner_step
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
    je .scan_is_sffs
    cmp byte [fs_super_buf+4], SFFS_VERSION_V2
    jne .scan_next
.scan_is_sffs:
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
    call spinner_step
    mov rdi, r12
    inc rdi
    imul rdi, VOL_NODES
    mov al, r13b
    call vol_read
    cmp rax, -1
    je .load_fail
    call spinner_clear
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
    mov al, [cur_normal_attr]
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
    call spinner_clear
    mov rsi, msg_mount_none
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_mount_none2
    call print_string
    ret
.too_many:
    call spinner_clear
    mov rsi, msg_mount_full
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.load_fail:
    call spinner_clear
    mov rsi, msg_mount_fail
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; ------------------------------------------------------------
; cmd_unmount: detach a mounted drive's volume from the filesystem.
;   unmount <label>
; Drops the mount slot (so 'sync' stops writing that volume back) and
; frees the volume's whole node slice in memory, making /<label>/ vanish
; from the tree. The data stays untouched on the drive - 'dscan' +
; 'mount' re-attach it. Refuses while the current directory is inside
; the volume, since that would strand the shell inside a freed tree.
cmd_unmount:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_unmount_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    ; find the mount slot whose label matches
    xor r12, r12
.find_loop:
    cmp r12, MAX_MOUNTS
    jae .not_mounted
    cmp byte [mount_used + r12], 0
    je .find_next
    mov rax, r12
    imul rax, 32
    lea rsi, [mount_label + rax]
    mov rdi, arg1_buf
    call str_eq
    cmp al, 1
    je .found
.find_next:
    inc r12
    jmp .find_loop
.found:
    ; base node index of this mount's slice
    mov rax, r12
    inc rax
    imul rax, VOL_NODES
    ; refuse if the current directory lives inside this volume
    mov rbx, [cur_dir]
    mov rcx, rax
    add rcx, VOL_NODES
    cmp rbx, rax
    jb .ok
    cmp rbx, rcx
    jb .busy
.ok:
    ; clear the mount slot
    mov byte [mount_used + r12], 0
    mov byte [mount_device + r12], 0
    mov rdi, r12
    imul rdi, 32
    lea rdi, [mount_label + rdi]
    mov rcx, 32
    xor al, al
    rep stosb
    ; free the whole slice so the volume disappears from the tree
    lea rdi, [node_type + rax]
    mov rcx, VOL_NODES
    xor al, al
    rep stosb
    ; clear the root node's name too
    mov rax, r12
    inc rax
    imul rax, VOL_NODES
    imul rax, NAME_LEN
    lea rdi, [node_name + rax]
    mov rcx, NAME_LEN
    xor al, al
    rep stosb
    ; report
    mov rsi, msg_unmount_ok1
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_unmount_ok2
    call print_string
    mov rsi, newline_str
    call print_string
    ret
.busy:
    mov rsi, msg_unmount_busy1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_unmount_busy2
    call print_string
    ret
.not_mounted:
    mov rsi, msg_unmount_none1
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_unmount_none2
    call print_string
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
    je .dup_is_sffs
    cmp byte [fs_super_buf+4], SFFS_VERSION_V2
    jne .dup_next
.dup_is_sffs:
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
    je .scan_is_sffs
    cmp byte [fs_super_buf+4], SFFS_VERSION_V2
    jne .scan_next
.scan_is_sffs:
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
    mov al, [cur_normal_attr]
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
    call maybe_auto_sync
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
    ; "rmv ali <name>" / "auth rmv ali all" - alias removal, not a variable
    mov rsi, arg1_buf
    mov rdi, str_ali
    call str_eq
    cmp al, 1
    je .rmv_ali

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

.rmv_ali:
    cmp byte [arg2_buf], 0
    jne .rmv_ali_have_name
    mov rsi, msg_need_name
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.rmv_ali_have_name:
    ; "rmv ali all" only clears everything when run as "auth rmv ali all"
    mov rsi, arg2_buf
    mov rdi, str_rmv_all
    call str_eq
    cmp al, 1
    je .rmv_ali_all

    mov rsi, arg2_buf
    call alias_lookup
    cmp rax, -1
    je .rmv_ali_not_found
    mov rcx, rax
    mov byte [alias_used + rcx], 0
    call aliases_persist
    ret
.rmv_ali_not_found:
    mov rsi, msg_no_alias
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg2_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

.rmv_ali_all:
    cmp byte [auth_valid], 0
    jne .rmv_ali_all_ok
    mov rsi, msg_auth_required
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.rmv_ali_all_ok:
    mov byte [auth_valid], 0
    call aliases_clear_all
    call aliases_persist
    mov rsi, msg_aliases_cleared
    mov al, [cur_normal_attr]
    call print_string_attr
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
    mov al, [cur_normal_attr]
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
; cmd_sys: "sys reset" - a factory reset for when a user's system is
; broken/full/messed up. Wipes every file and folder on the OS volume
; (nodes 0..OS_NODES-1 - mounted external drives are untouched), clears
; the in-memory variables and aliases, recreates the default system
; files (sys/, alias.sly, sysconfig - see ensure_sys_folder), and saves
; the result to disk immediately. Requires auth: "auth sys reset".
cmd_sys:
    cmp byte [arg1_buf], 0
    jne .have_arg
    mov rsi, msg_sys_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.have_arg:
    mov rsi, arg1_buf
    mov rdi, str_sys_reset
    call str_eq
    cmp al, 1
    je .sys_reset
    mov rsi, msg_sys_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.sys_reset:
    cmp byte [auth_valid], 0
    jne .reset_ok
    mov rsi, msg_auth_required
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.reset_ok:
    mov byte [auth_valid], 0
    call sys_do_reset
    mov rsi, msg_sys_reset_done
    mov al, [cur_normal_attr]
    call print_string_attr
    ret

; sys_do_reset: the actual factory-reset work for "sys reset". Keeps the
; OS volume's existing label (so the drive/system identity doesn't
; change), but wipes every node in its slice (nodes 0..OS_NODES-1) back
; to a single empty root folder, drops all session variables and
; aliases, recreates the default sys/ files, and persists it all to
; disk. Mounted external drives live in nodes OS_NODES..MAX_NODES-1 and
; are left completely untouched.
sys_do_reset:
    push rax
    push rcx
    push rsi
    push rdi

    ; remember the current label (root node's name) so the reset system
    ; keeps its identity instead of reverting to a generic default
    lea rsi, [node_name]
    lea rdi, [sys_reset_label_tmp]
    call str_copy

    ; wipe node_type/node_parent/node_next/node_name/node_content for
    ; just the OS volume's slice of nodes
    mov rdi, node_type
    mov rcx, OS_NODES
    xor al, al
    rep stosb

    mov rdi, node_parent
    mov rcx, OS_NODES
    xor ax, ax
    rep stosw

    mov rdi, node_next
    mov rcx, OS_NODES
    mov ax, 0xFFFF
    rep stosw

    mov rdi, node_name
    mov rcx, OS_NODES * NAME_LEN
    xor al, al
    rep stosb

    mov rdi, node_content
    mov rcx, OS_NODES * CONTENT_LEN
    xor al, al
    rep stosb

    ; recreate node 0 as an empty root folder under its old label
    mov byte [node_type], 1
    mov word [node_parent], 0xFFFF
    lea rsi, [sys_reset_label_tmp]
    lea rdi, [node_name]
    call str_copy

    ; back to the root of the freshly-wiped volume
    mov qword [cur_dir], 0

    ; this is a factory reset - drop session variables and aliases too
    call vars_clear_all
    call aliases_clear_all

    ; recreate sys/, alias.sly, sysconfig with their default content
    call ensure_sys_folder

    ; persist the reset system to disk right away
    call fs_save

    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

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
    call maybe_auto_sync
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
    call maybe_auto_sync
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
    call maybe_auto_sync
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
    test al, 0x20                  ; aux (mouse) byte waiting?
    jz .kbd_byte
    in al, 0x60
    cmp byte [mouse_ena], 0
    je .no_key
    call mouse_byte
    jmp .no_key
.kbd_byte:
    in al, 0x60
    cmp al, 0x01                  ; Esc make code
    jne .no_key
    mov byte [kill_flag], 1
.no_key:
    ret

; party_poll_kill_api: exposed to compiled .run programs at
; [kernel_api_table+0x20]. Called once per while(true) iteration so an
; otherwise-unbreakable loop can be stopped from outside it.
; Compiled .run code keeps its only persistent state in rdi (the api
; table pointer), so this preserves every register except rax rather
; than trusting kbd_poll's (and mouse_byte's) clobber list to stay rdi/
; rsi-safe forever.
; Out: al = 1 if the running program should stop (Esc pressed, or
;      killed via 'prs kill <pid/name>'), 0 to keep going.
party_poll_kill_api:
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
    call kbd_poll
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
    movzx eax, byte [kill_flag]
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
;  BACKGROUND PARTY SCHEDULER
;  A background .run is a Party program stepped cooperatively: it
;  executes on its OWN private stack (proc_bg_stack) with its OWN
;  parked interpreter state (proc_bg_ctx), so a background script
;  nested in while loops / function calls can be paused at any
;  statement boundary and resumed later without losing its call
;  stack. The shared interpreter globals are parked into/restored
;  from the process's ctx area around every step, which is what lets
;  a foreground 'party'/'run' (or another background process) safely
;  reuse them in between.
; ============================================================

; bg_step_proc: rax = slot. Restores the process's interpreter state,
; redirects putchar at its output ring, then switches to its private
; stack and resumes it (the first step lands in party_bg_bootstrap,
; later steps in the interpreter's own yield-resume point). Control
; returns to the scheduler - as if this call simply returned - either
; when the process yields after BG_QUANTUM statements or when it ends.
; Note this never returns via a normal `ret` (the process stack's saved
; top word is the resume IP), so it must NOT push anything after saving
; bg_shell_rsp. Clobbers rax, rbx, rcx, rdx, rsi, rdi, r8-r15.
bg_step_proc:
    movzx rbx, al
    mov [bg_cur_slot], rbx
    mov [bg_shell_rsp], rsp          ; scheduler's return address is on top

    ; restore the process's parked interpreter state
    lea rsi, [proc_bg_ctx]
    imul rax, rbx, PARTY_CTX_SIZE
    add rsi, rax
    call party_ctx_restore

    ; point putchar's capture at this process's output ring
    lea rax, [proc_bg_ring]
    imul rcx, rbx, BG_RING_CAP
    add rax, rcx
    mov [bg_capture_base], rax
    lea rcx, [proc_bg_ring_start]
    lea rax, [rcx + rbx*4]
    mov [bg_capture_start_ptr], rax
    lea rcx, [proc_bg_ring_len]
    lea rax, [rcx + rbx*4]
    mov [bg_capture_len_ptr], rax
    mov qword [bg_capture_max], BG_RING_CAP

    mov byte [party_bg_active], 1
    mov dword [party_bg_quantum], BG_QUANTUM
    fninit

    mov rax, rbx
    mov rsp, [proc_bg_rsp + rax*8]
    ret

; bg_scheduler_tick: steps every running background process once.
; Called from the shell's idle path (read_char_or_step) when no key is
; waiting, so background scripts run exactly when the shell would
; otherwise be sitting at the prompt. Finishing processes have their
; completion notice queued (bg_finish_notice) and their slots freed.
; Preserves all registers.
bg_scheduler_tick:
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

    mov byte [sched_slot], 0
.sched_loop:
    movzx r13, byte [sched_slot]
    cmp r13, MAX_PROCESSES
    jae .sched_done
    cmp byte [proc_bg + r13], 1
    jne .sched_next
    mov rax, r13
    call bg_step_proc
    ; The step returned (yielded or finished): the interpreter is no
    ; longer active, so stop capturing output.
    mov qword [bg_capture_base], 0
    mov byte [party_bg_active], 0
    ; bg_step_proc + the interpreter clobbered every register, so the
    ; slot is reloaded from sched_slot.
    movzx r13, byte [sched_slot]
    cmp byte [proc_bg + r13], 1
    jne .sched_finished
    jmp .sched_next
.sched_finished:
    mov rdi, r13
    call proc_free_slot
.sched_next:
    movzx r13, byte [sched_slot]
    inc r13
    mov [sched_slot], r13b
    jmp .sched_loop
.sched_done:
    mov qword [bg_capture_base], 0
    mov byte [party_bg_active], 0

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

; bg_finish_notice: called by party_bg_bootstrap when a background
; process's script actually ends (EOF, an interpreter error, or a
; kill). Clears the process's background flag (so the scheduler frees
; the slot) and queues a one-line completion notice for the shell to
; print at its next prompt. Clobbers rax, rbx, rcx, rdx, rsi, rdi.
bg_finish_notice:
    movzx rbx, byte [bg_cur_slot]
    mov byte [proc_bg + rbx], 0
    mov byte [bg_notice_pending], 1
    lea rdi, [bg_notice]
    mov byte [rdi], 0

    cmp byte [party_killed], 0
    jne .bfn_killed
    cmp byte [party_exec_ok], 1
    jne .bfn_error

    ; finished normally
    lea rsi, [msg_bg_notice_pre]
    call str_append
    movzx rax, word [proc_id + rbx*2]
    lea rdi, [show_num_buf]
    call int_to_str
    lea rdi, [bg_notice]
    lea rsi, [show_num_buf]
    call str_append
    lea rdi, [bg_notice]
    lea rsi, [msg_bg_notice_done]
    call str_append
    jmp .bfn_out

.bfn_killed:
    lea rsi, [msg_bg_notice_pre]
    call str_append
    movzx rax, word [proc_id + rbx*2]
    lea rdi, [show_num_buf]
    call int_to_str
    lea rdi, [bg_notice]
    lea rsi, [show_num_buf]
    call str_append
    lea rdi, [bg_notice]
    lea rsi, [msg_bg_notice_killed]
    call str_append
    jmp .bfn_out

.bfn_error:
    lea rsi, [msg_bg_notice_pre]
    call str_append
    movzx rax, word [proc_id + rbx*2]
    lea rdi, [show_num_buf]
    call int_to_str
    lea rdi, [bg_notice]
    lea rsi, [show_num_buf]
    call str_append
    lea rdi, [bg_notice]
    lea rsi, [msg_bg_notice_err]
    call str_append
    mov rsi, [party_err_msg_ptr]
    cmp rsi, 0
    je .bfn_err_line
    lea rdi, [bg_notice]
    call str_append
.bfn_err_line:
    lea rdi, [bg_notice]
    lea rsi, [msg_party_err_near]
    call str_append
    mov eax, [party_error_line]
    lea rdi, [show_num_buf]
    call int_to_str
    lea rdi, [bg_notice]
    lea rsi, [show_num_buf]
    call str_append
.bfn_out:
    lea rdi, [bg_notice]
    lea rsi, [newline_str]
    call str_append
    ret

; bg_flush_notice: prints a queued background-process completion notice.
; Called from the shell loop right after read_line returns, so the line
; lands cleanly above the next command's output.
bg_flush_notice:
    cmp byte [bg_notice_pending], 0
    je .bfn_flush_done
    mov byte [bg_notice_pending], 0
    lea rsi, [bg_notice]
    mov al, [cur_normal_attr]
    call print_string_attr
.bfn_flush_done:
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
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    movzx rax, byte [proc_cur_slot]
    movzx rax, word [proc_id + rax*2]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, msg_rr_pid1
    mov al, [cur_normal_attr]
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

    ; "ali <name> <commands>" defines an alias - same raw-line
    ; interception as the interactive shell (see try_handle_ali_line),
    ; so alias bodies containing ; or ~ survive intact inside scripts too.
    call try_handle_ali_line
    cmp al, 1
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
    mov al, [cur_normal_attr]
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
;    prs kill <name>      - kill process by its name in 'prs' (e.g.
;                            "run" for a running .run program), or
;                            "rushrun" for an rr script (legacy alias)
; ============================================================
cmd_prs:
    ; Check if arg1 is "kill"
    mov rsi, arg1_buf
    mov rdi, str_kill
    call str_eq
    cmp al, 1
    je .prs_kill

    ; Check if arg1 is "peek"
    mov rsi, arg1_buf
    mov rdi, str_peek
    call str_eq
    cmp al, 1
    je .prs_peek

    ; No subcommand - show process info
    call prs_show
    ret

.prs_peek:
    ; usage: prs peek <pid|name> [lower|last] <N>
    ; Find the process by pid (if arg2 is numeric) or by name.
    mov rsi, arg2_buf
    call parse_int
    cmp cl, 1
    je .peek_by_pid
    cmp byte [arg2_buf], 0
    je .peek_badarg
    xor r13, r13
.peek_find_name:
    cmp r13, MAX_PROCESSES
    jae .kill_not_found
    cmp byte [proc_state + r13], 0
    je .peek_name_next
    mov rax, r13
    imul rax, 32
    lea rdi, [proc_name + rax]
    mov rsi, arg2_buf
    call str_eq
    cmp al, 1
    je .peek_found
.peek_name_next:
    inc r13
    jmp .peek_find_name
.peek_by_pid:
    mov r12, rax                    ; target PID
    xor r13, r13
.peek_find_pid:
    cmp r13, MAX_PROCESSES
    jae .kill_not_found
    cmp byte [proc_state + r13], 0
    je .peek_pid_next
    movzx rax, word [proc_id + r13*2]
    cmp rax, r12
    je .peek_found
.peek_pid_next:
    inc r13
    jmp .peek_find_pid
.peek_found:
    ; r13 = slot. Only background processes capture output.
    cmp byte [proc_bg + r13], 1
    jne .peek_not_bg
    mov rsi, arg4_buf
    call parse_int
    cmp cl, 1
    jne .peek_default_n
    mov r12, rax
    jmp .peek_have_n
.peek_default_n:
    mov r12, 10
.peek_have_n:
    mov rdi, r13                    ; slot
    mov rsi, r12                    ; N lines
    call prs_peek_ring
    ret
.peek_not_bg:
    mov rsi, msg_prs_peek_notbg
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.peek_badarg:
    mov rsi, msg_prs_peek_usage
    mov al, ATTR_ERROR
    call print_string_attr
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
    jne .kill_by_name

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
    mov al, [cur_normal_attr]
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
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, str_rushrun
    call print_string
    mov rsi, newline_str
    call print_string
    ret

.kill_by_name:
    ; arg2 wasn't "rushrun" and isn't a PID - try matching it against
    ; any currently-running process's actual stored name (e.g. "run",
    ; the process a compiled .run program registers).
    cmp byte [arg2_buf], 0
    je .bad_kill_arg
    xor r13, r13
.prs_find_name:
    cmp r13, MAX_PROCESSES
    jae .kill_not_found
    cmp byte [proc_state + r13], 0
    je .name_next
    mov rax, r13
    imul rax, 32
    lea rdi, [proc_name + rax]
    mov rsi, arg2_buf
    call str_eq
    cmp al, 1
    je .kill_found_name
.name_next:
    inc r13
    jmp .prs_find_name
.kill_found_name:
    mov byte [kill_flag], 1
    mov rsi, msg_prs_killed
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg2_buf
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

; prs_peek_ring: rdi = slot, rsi = N. Linearizes the process's output
; ring and prints the last N lines. Clobbers rax, rbx, rcx, rdx,
; rsi, rdi, r8-r15.
prs_peek_ring:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi                    ; slot
    mov r13, rsi                    ; N
    mov eax, [proc_bg_ring_len + r12*4]
    mov ecx, [proc_bg_ring_start + r12*4]
    mov r15, rax                    ; byte count
    cmp r15, 0
    je .ppr_done
    cmp r15, BG_RING_CAP
    jbe .ppr_have_len
    mov r15, BG_RING_CAP
.ppr_have_len:
    mov rax, r12
    imul rax, BG_RING_CAP
    lea r14, [proc_bg_ring + rax]   ; ring base
    lea rdi, [prs_peek_buf]
    xor r8, r8                      ; copied count
.ppr_cp_loop:
    cmp r8, r15
    jae .ppr_cp_done
    lea rsi, [r14 + rcx]
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc r8
    inc rcx
    cmp rcx, BG_RING_CAP
    jb .ppr_cp_loop
    xor rcx, rcx
    jmp .ppr_cp_loop
.ppr_cp_done:
    ; prs_peek_buf[0..r15) = newest output. Find the first byte of the
    ; last N lines (the trailing newline terminates the last line; count
    ; newlines backwards from there).
    mov r8, 0                       ; print start
    mov rcx, r15
    cmp rcx, 0
    je .ppr_scan_done2
    dec rcx
    lea rsi, [prs_peek_buf + rcx]
    cmp byte [rsi], 0x0A
    jne .ppr_scan2
    dec rcx                         ; skip the trailing newline
.ppr_scan2:
    cmp rcx, 0
    jl .ppr_scan_done2              ; all lines kept: print from 0
    lea rsi, [prs_peek_buf + rcx]
    cmp byte [rsi], 0x0A
    jne .ppr_scan_dec
    dec r13
    jz .ppr_found
.ppr_scan_dec:
    dec rcx
    jmp .ppr_scan2
.ppr_found:
    mov r8, rcx
    inc r8                          ; print from after this newline
.ppr_scan_done2:
    lea rsi, [prs_peek_buf + r8]
    mov byte [prs_peek_buf + r15], 0
    cmp byte [prs_peek_buf + r15 - 1], 0x0A
    je .ppr_print
    mov byte [prs_peek_buf + r15], 0x0A
    mov byte [prs_peek_buf + r15 + 1], 0
.ppr_print:
    mov al, [cur_normal_attr]
    call print_string_attr
.ppr_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; prs_show: display process table
prs_show:
    mov rsi, msg_prs_header
    mov al, [cur_normal_attr]
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
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, prs_spaces
    call print_string
    mov rax, r13
    imul rax, 32
    lea rsi, [proc_name + rax]
    mov al, [cur_normal_attr]
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
    mov al, [cur_normal_attr]
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
    mov al, [cur_normal_attr]
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
    mov al, [cur_normal_attr]
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
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, msg_vars_sep
    call print_string
    ; Print variable value
    mov rax, [var_value + rcx*8]
    lea rdi, [show_num_buf]
    call int_to_str
    mov rsi, show_num_buf
    mov al, [cur_normal_attr]
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
;  Aliases ("ali <name> <commands>")
;
;  An alias binds a name to an arbitrary command string (which may
;  itself contain ; chains and a ~ pipe). Defining one is intercepted
;  as raw text before ; splitting ever sees it (try_handle_ali_line,
;  called from the interactive shell loop and from cmd_rr's script
;  loop); invoking one happens inside dispatch, when cmd_buf doesn't
;  match any built-in command but does match an alias name.
; ============================================================

; try_handle_ali_line: line_buf holds a raw, not-yet-tokenized input
; line. If it starts with the exact word "ali" followed by a name and
; at least one command, stores the alias and returns al=1 (caller
; should treat the line as fully handled and not process it further).
; Otherwise returns al=0 and leaves line_buf untouched, so the caller
; processes the line normally.
try_handle_ali_line:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov al, [line_buf]
    cmp al, 'a'
    jne .thal_no
    mov al, [line_buf+1]
    cmp al, 'l'
    jne .thal_no
    mov al, [line_buf+2]
    cmp al, 'i'
    jne .thal_no
    mov al, [line_buf+3]
    cmp al, ' '
    jne .thal_no             ; "ali" alone (NUL) or a longer word ("alias")

    lea rsi, [line_buf+4]
.thal_skip_sp1:
    cmp byte [rsi], ' '
    jne .thal_name_start
    inc rsi
    jmp .thal_skip_sp1
.thal_name_start:
    cmp byte [rsi], 0
    jne .thal_read_name
    jmp .thal_usage           ; only whitespace after "ali" - no name

.thal_read_name:
    lea rdi, [ali_name_tmp]
    xor rcx, rcx
.thal_name_loop:
    mov dl, [rsi]
    cmp dl, 0
    je .thal_name_done
    cmp dl, ' '
    je .thal_name_done
    cmp rcx, ALIAS_NAME_LEN-1
    jae .thal_name_skipchar   ; name too long: keep scanning, stop storing
    mov [rdi+rcx], dl
    inc rcx
.thal_name_skipchar:
    inc rsi
    jmp .thal_name_loop
.thal_name_done:
    mov byte [rdi+rcx], 0

    cmp byte [rsi], 0
    jne .thal_skip_sp2
    jmp .thal_usage           ; got a name but nothing after it

.thal_skip_sp2:
    cmp byte [rsi], ' '
    jne .thal_body_check
    inc rsi
    jmp .thal_skip_sp2
.thal_body_check:
    cmp byte [rsi], 0
    jne .thal_have_body
    jmp .thal_usage           ; only whitespace after the name

.thal_have_body:
    ; rsi -> rest of the line, verbatim (kept as-is, ; and ~ included)
    lea rdi, [ali_body_tmp]
    call str_copy
    call alias_store
    mov al, 1
    jmp .thal_ret

.thal_usage:
    mov rsi, msg_alias_usage
    mov al, ATTR_ERROR
    call print_string_attr
    mov al, 1
    jmp .thal_ret

.thal_no:
    mov al, 0

.thal_ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; alias_store: stores ali_name_tmp/ali_body_tmp into the alias table,
; overwriting an existing alias of the same name if one exists,
; otherwise using the first free slot. Prints an error if the table
; is full and the name isn't already present.
alias_store:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rbx, -1               ; rbx = first free slot seen so far
    xor rcx, rcx
.as_scan:
    cmp rcx, MAX_ALIASES
    jae .as_scan_done
    cmp byte [alias_used + rcx], 0
    je .as_free_candidate
    mov rdi, rcx
    imul rdi, ALIAS_NAME_LEN
    lea rdi, [alias_names + rdi]
    mov rsi, ali_name_tmp
    call str_eq
    cmp al, 1
    je .as_write              ; existing alias with this name - overwrite
    jmp .as_scan_next
.as_free_candidate:
    cmp rbx, -1
    jne .as_scan_next
    mov rbx, rcx
.as_scan_next:
    inc rcx
    jmp .as_scan
.as_scan_done:
    cmp rbx, -1
    je .as_full
    mov rcx, rbx
    mov byte [alias_used + rcx], 1
    jmp .as_write

.as_full:
    mov rsi, msg_alias_full
    mov al, ATTR_ERROR
    call print_string_attr
    jmp .as_ret

.as_write:
    mov rdi, rcx
    imul rdi, ALIAS_NAME_LEN
    lea rdi, [alias_names + rdi]
    mov rsi, ali_name_tmp
    call str_copy
    mov rdi, rcx
    imul rdi, ALIAS_BODY_LEN
    lea rdi, [alias_bodies + rdi]
    mov rsi, ali_body_tmp
    call str_copy

    cmp byte [alias_loading], 1
    je .as_ret                ; being restored from alias.sly at boot - don't re-write it
    call aliases_persist

.as_ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; alias_lookup: rsi = name to find. Returns rax = alias index, or -1.
alias_lookup:
    push rbx
    push rcx
    push rdi
    mov rbx, rsi
    xor rcx, rcx
.al_loop:
    cmp rcx, MAX_ALIASES
    jae .al_notfound
    cmp byte [alias_used + rcx], 0
    je .al_next
    mov rdi, rcx
    imul rdi, ALIAS_NAME_LEN
    lea rdi, [alias_names + rdi]
    mov rsi, rbx
    call str_eq
    cmp al, 1
    je .al_found
.al_next:
    inc rcx
    jmp .al_loop
.al_found:
    mov rax, rcx
    pop rdi
    pop rcx
    pop rbx
    ret
.al_notfound:
    mov rax, -1
    pop rdi
    pop rcx
    pop rbx
    ret

; cmd_alias_invoke: called from dispatch when cmd_buf matched an alias
; name, with [alias_match_idx] set to that alias's table index. Runs
; the alias's stored body exactly like a freshly-typed line, through
; the same chain processor (process_chain or process_chain_rr) that's
; currently active, so ; chaining and ~ piping inside the alias work
; normally and nested alias calls work too.
;
; This has to protect two pieces of global, shared state that would
; otherwise be clobbered by that nested call:
;   - chain_scan_buf: the outer process_chain(_rr) is still mid-scan
;     over it (via r12/r13), so it's backed up on the stack, restored
;     after the nested call returns. r12/r13 are ordinary registers,
;     saved/restored by normal callee-saved discipline, so only the
;     memory needs protecting, not the pointers themselves.
;   - chain_is_rr: process_chain/process_chain_rr each set this as a
;     side effect, so it's saved and restored too, otherwise an alias
;     call partway through an rr script could leave later segments in
;     that script using the wrong dispatch-wrapping behaviour.
; alias_depth guards against runaway recursion (an alias that invokes
; itself, directly or indirectly) overrunning the stack.
cmd_alias_invoke:
    push rax
    push rbx

    movzx rax, byte [alias_depth]
    cmp rax, ALIAS_MAX_DEPTH
    jl .cai_depth_ok
    mov rsi, msg_alias_too_deep
    mov al, ATTR_ERROR
    call print_string_attr
    pop rbx
    pop rax
    ret
.cai_depth_ok:
    inc byte [alias_depth]

    movzx rax, byte [chain_is_rr]
    push rax                        ; saved chain_is_rr, at [rsp+224] after the sub below

    sub rsp, 224                    ; > LINE_MAX, room to back up chain_scan_buf
    mov rsi, chain_scan_buf
    mov rdi, rsp
    call str_copy

    movzx rax, byte [alias_match_idx]
    mov rbx, ALIAS_BODY_LEN
    imul rax, rbx
    lea rsi, [alias_bodies + rax]
    mov rdi, line_buf
    call str_copy

    mov rax, [rsp+224]
    cmp al, 0
    je .cai_plain
    call process_chain_rr
    jmp .cai_after
.cai_plain:
    call process_chain
.cai_after:

    mov rsi, rsp
    mov rdi, chain_scan_buf
    call str_copy
    add rsp, 224

    pop rax
    mov [chain_is_rr], al

    dec byte [alias_depth]
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
; cmd_alis: list user-defined aliases.
;   alis                list all aliases and their bodies
; Removing aliases is done via cmd_rmv instead, for consistency with
; how variables are removed:
;   rmv ali <name>      remove one alias
;   auth rmv ali all     remove every alias (requires auth, since it's
;                         destructive)
cmd_alis:
    call aliases_list
    ret

; aliases_list: print every defined alias as "name: body"
aliases_list:
    push rbx
    push rcx
    push rdi
    push rsi

    mov rsi, msg_alis_header
    mov al, [cur_normal_attr]
    call print_string_attr

    xor rcx, rcx
.aal_loop:
    cmp rcx, MAX_ALIASES
    jae .aal_done
    cmp byte [alias_used + rcx], 0
    je .aal_next
    mov rdi, rcx
    imul rdi, ALIAS_NAME_LEN
    lea rsi, [alias_names + rdi]
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, msg_alis_sep
    call print_string
    mov rdi, rcx
    imul rdi, ALIAS_BODY_LEN
    lea rsi, [alias_bodies + rdi]
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, newline_str
    call print_string
.aal_next:
    inc rcx
    jmp .aal_loop
.aal_done:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; aliases_clear_all: clear every alias in the table
aliases_clear_all:
    push rax
    push rcx
    push rdi
    push r8
    xor r8, r8
.aca_loop:
    cmp r8, MAX_ALIASES
    jae .aca_done
    mov byte [alias_used + r8], 0
    mov rdi, r8
    imul rdi, ALIAS_NAME_LEN
    lea rdi, [alias_names + rdi]
    mov rcx, ALIAS_NAME_LEN
    xor al, al
    rep stosb
    mov rdi, r8
    imul rdi, ALIAS_BODY_LEN
    lea rdi, [alias_bodies + rdi]
    mov rcx, ALIAS_BODY_LEN
    xor al, al
    rep stosb
    inc r8
    jmp .aca_loop
.aca_done:
    pop r8
    pop rdi
    pop rcx
    pop rax
    ret

; aliases_persist: serializes every currently-defined alias as a plain
; text "ali <name> <commands>" line (the exact syntax that defines it -
; so the file doubles as a script alias_load can just re-parse) into
; /home/sys/alias.sly, creating the file if it doesn't exist yet.
; Writing to a node only updates the in-memory filesystem tree; the
; actual disk write still goes through maybe_auto_sync/fs_save like
; everything else, so this respects the 'autosync off' setting too.
aliases_persist:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    push r13

    mov byte [alias_sly_buf], 0
    xor r13, r13
.ap_loop:
    cmp r13, MAX_ALIASES
    jae .ap_built
    cmp byte [alias_used + r13], 0
    je .ap_next
    lea rdi, [alias_sly_buf]
    mov rsi, str_ali_line_prefix   ; "ali "
    call str_append
    mov rax, r13
    imul rax, ALIAS_NAME_LEN
    lea rsi, [alias_names + rax]
    lea rdi, [alias_sly_buf]
    call str_append
    lea rdi, [alias_sly_buf]
    mov rsi, str_single_space
    call str_append
    mov rax, r13
    imul rax, ALIAS_BODY_LEN
    lea rsi, [alias_bodies + rax]
    lea rdi, [alias_sly_buf]
    call str_append
    lea rdi, [alias_sly_buf]
    mov rsi, newline_str
    call str_append
.ap_next:
    inc r13
    jmp .ap_loop
.ap_built:
    xor rax, rax
    mov rsi, str_sys_name
    mov r10, 1
    call fs_find_child
    cmp rax, -1
    je .ap_out                      ; no /home/sys somehow - nothing to write to
    mov rbx, rax
    mov rax, rbx
    mov rsi, str_alias_sly_name
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    jne .ap_have_node
    mov rax, rbx
    mov rsi, str_alias_sly_name
    mov r10, 2
    call fs_create_node
    cmp rax, -1
    je .ap_out
.ap_have_node:
    lea rsi, [alias_sly_buf]
    call fs_write_file
    call maybe_auto_sync
.ap_out:
    pop r13
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; aliases_load: called once at boot (after the filesystem is available)
; to restore aliases saved by aliases_persist in a previous session.
; Reads /home/sys/alias.sly and feeds each line through the same
; try_handle_ali_line parser interactive "ali ..." typing uses, so the
; on-disk format and the live command can never drift apart. Sets
; alias_loading so alias_store doesn't immediately re-persist every
; single line it's busy restoring.
aliases_load:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    push r12

    xor rax, rax
    mov rsi, str_sys_name
    mov r10, 1
    call fs_find_child
    cmp rax, -1
    je .al_out
    mov rbx, rax
    mov rax, rbx
    mov rsi, str_alias_sly_name
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    je .al_out

    lea rdi, [alias_sly_buf]
    call fs_read_file

    mov byte [alias_loading], 1
    lea r12, [alias_sly_buf]
.al_line_loop:
    cmp byte [r12], 0
    je .al_done
    mov rdi, line_buf
    xor rcx, rcx
.al_copy_loop:
    mov al, [r12]
    cmp al, 0
    je .al_line_end
    cmp al, 10
    je .al_line_end
    cmp rcx, LINE_MAX-1
    jae .al_line_end
    mov [rdi], al
    inc rdi
    inc rcx
    inc r12
    jmp .al_copy_loop
.al_line_end:
    mov byte [rdi], 0
    cmp byte [r12], 10
    jne .al_no_nl
    inc r12
.al_no_nl:
    cmp byte [line_buf], 0
    je .al_line_loop
    call try_handle_ali_line
    jmp .al_line_loop
.al_done:
    mov byte [alias_loading], 0
.al_out:
    pop r12
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
;  color: change the foreground color used for normal ("show", "list",
;  etc.) output. Prompt (yellow) and error (red) messages are
;  deliberately left alone, since those colors are meaningful cues.
;    color               show current color + the list of names
;    color list          just the list of names
;    color reset         back to the default (green)
;    color <name>        set it
; ============================================================
cmd_color:
    cmp byte [arg1_buf], 0
    jne .col_have_arg
    call color_print_list
    ret

.col_have_arg:
    mov rsi, arg1_buf
    mov rdi, str_col_list
    call str_eq
    cmp al, 1
    je .col_list

    mov rsi, arg1_buf
    mov rdi, str_col_reset
    call str_eq
    cmp al, 1
    je .col_do_reset

    mov rsi, arg1_buf
    mov rdi, str_col_black
    call str_eq
    cmp al, 1
    je .col_black

    mov rsi, arg1_buf
    mov rdi, str_col_dblue
    call str_eq
    cmp al, 1
    je .col_dblue

    mov rsi, arg1_buf
    mov rdi, str_col_blue
    call str_eq
    cmp al, 1
    je .col_blue

    mov rsi, arg1_buf
    mov rdi, str_col_lblue
    call str_eq
    cmp al, 1
    je .col_blue

    mov rsi, arg1_buf
    mov rdi, str_col_dgreen
    call str_eq
    cmp al, 1
    je .col_dgreen

    mov rsi, arg1_buf
    mov rdi, str_col_green
    call str_eq
    cmp al, 1
    je .col_green

    mov rsi, arg1_buf
    mov rdi, str_col_lgreen
    call str_eq
    cmp al, 1
    je .col_green

    mov rsi, arg1_buf
    mov rdi, str_col_dcyan
    call str_eq
    cmp al, 1
    je .col_dcyan

    mov rsi, arg1_buf
    mov rdi, str_col_cyan
    call str_eq
    cmp al, 1
    je .col_cyan

    mov rsi, arg1_buf
    mov rdi, str_col_lcyan
    call str_eq
    cmp al, 1
    je .col_cyan

    mov rsi, arg1_buf
    mov rdi, str_col_dred
    call str_eq
    cmp al, 1
    je .col_dred

    mov rsi, arg1_buf
    mov rdi, str_col_red
    call str_eq
    cmp al, 1
    je .col_red

    mov rsi, arg1_buf
    mov rdi, str_col_lred
    call str_eq
    cmp al, 1
    je .col_red

    mov rsi, arg1_buf
    mov rdi, str_col_dmagenta
    call str_eq
    cmp al, 1
    je .col_dmagenta

    mov rsi, arg1_buf
    mov rdi, str_col_magenta
    call str_eq
    cmp al, 1
    je .col_magenta

    mov rsi, arg1_buf
    mov rdi, str_col_lmagenta
    call str_eq
    cmp al, 1
    je .col_magenta

    mov rsi, arg1_buf
    mov rdi, str_col_purple
    call str_eq
    cmp al, 1
    je .col_magenta

    mov rsi, arg1_buf
    mov rdi, str_col_brown
    call str_eq
    cmp al, 1
    je .col_brown

    mov rsi, arg1_buf
    mov rdi, str_col_orange
    call str_eq
    cmp al, 1
    je .col_brown

    mov rsi, arg1_buf
    mov rdi, str_col_gray
    call str_eq
    cmp al, 1
    je .col_gray

    mov rsi, arg1_buf
    mov rdi, str_col_grey
    call str_eq
    cmp al, 1
    je .col_gray

    mov rsi, arg1_buf
    mov rdi, str_col_dgray
    call str_eq
    cmp al, 1
    je .col_dgray

    mov rsi, arg1_buf
    mov rdi, str_col_dgrey
    call str_eq
    cmp al, 1
    je .col_dgray

    mov rsi, arg1_buf
    mov rdi, str_col_yellow
    call str_eq
    cmp al, 1
    je .col_yellow

    mov rsi, arg1_buf
    mov rdi, str_col_white
    call str_eq
    cmp al, 1
    je .col_white

    ; not recognized
    mov rsi, msg_color_unknown
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

.col_black:    mov dl, 0x00
               jmp .col_apply
.col_dblue:    mov dl, 0x01
               jmp .col_apply
.col_dgreen:   mov dl, 0x02
               jmp .col_apply
.col_dcyan:    mov dl, 0x03
               jmp .col_apply
.col_dred:     mov dl, 0x04
               jmp .col_apply
.col_dmagenta: mov dl, 0x05
               jmp .col_apply
.col_brown:    mov dl, 0x06
               jmp .col_apply
.col_gray:     mov dl, 0x07
               jmp .col_apply
.col_dgray:    mov dl, 0x08
               jmp .col_apply
.col_blue:     mov dl, 0x09
               jmp .col_apply
.col_green:    mov dl, 0x0A
               jmp .col_apply
.col_cyan:     mov dl, 0x0B
               jmp .col_apply
.col_red:      mov dl, 0x0C
               jmp .col_apply
.col_magenta:  mov dl, 0x0D
               jmp .col_apply
.col_yellow:   mov dl, 0x0E
               jmp .col_apply
.col_white:    mov dl, 0x0F
               jmp .col_apply
.col_do_reset:
    mov dl, ATTR_NORMAL

.col_apply:
    mov [cur_normal_attr], dl
    mov rsi, msg_color_set1
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, msg_color_set2
    call print_string
    ret

.col_list:
    call color_print_list
    ret

; color_print_list: print the current color and every available name
color_print_list:
    mov rsi, msg_color_current
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, newline_str
    call print_string
    mov rsi, color_list_text
    mov al, ATTR_NORMAL
    call print_string_attr
    ret

; ============================================================
fs_init:
    mov rdi, node_type
    mov rcx, MAX_NODES
    xor al, al
    rep stosb
    ; node_next: every node starts with no chain
    mov rdi, node_next
    mov rcx, MAX_NODES
    mov ax, 0xFFFF
    rep stosw
    ; node_bin_len: no binary file lengths yet
    mov rdi, node_bin_len
    mov rcx, MAX_NODES
    xor eax, eax
    rep stosd
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
    call ensure_sys_folder
    ret

ensure_sys_folder:
    push rax
    push rbx
    push rsi
    push rdi
    push r10
    mov rax, 0
    mov rsi, str_sys_name
    mov r10, 1
    call fs_find_child
    cmp rax, -1
    jne .sys_exists
    mov rax, 0
    mov rsi, str_sys_name
    mov r10, 1
    call fs_create_node
    cmp rax, -1
    je .done
    mov rbx, rax
    jmp .create_files
.sys_exists:
    mov rbx, rax
.create_files:
    mov rax, rbx
    mov rsi, str_alias_sly_name
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    jne .check_sysconfig
    mov rax, rbx
    mov rsi, str_alias_sly_name
    mov r10, 2
    call fs_create_node
    cmp rax, -1
    je .check_sysconfig
    mov rax, rax
    mov rsi, str_alias_sly_content
    call fs_write_file
.check_sysconfig:
    mov rax, rbx
    mov rsi, str_sysconfig_name
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    jne .done
    mov rax, rbx
    mov rsi, str_sysconfig_name
    mov r10, 2
    call fs_create_node
    cmp rax, -1
    je .done
    mov rax, rax
    mov rsi, str_sysconfig_content
    call fs_write_file
.done:
    pop r10
    pop rdi
    pop rsi
    pop rbx
    pop rax
    ret

check_node_in_sys:
    push rbx
    push rcx
    push rdx
    push rax
    mov rax, 0
    mov rsi, str_sys_name
    mov r10, 1
    call fs_find_child
    mov rdx, rax
    pop rax
    cmp rdx, -1
    je .not_in_sys
.walk_loop:
    cmp rax, 0xFFFF
    je .not_in_sys
    cmp rax, 0
    je .not_in_sys
    cmp rax, rdx
    je .in_sys
    movzx rax, word [node_parent + rax*2]
    jmp .walk_loop
.in_sys:
    mov al, 1
    jmp .out
.not_in_sys:
    xor al, al
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

check_target_sys_auth:
    push rax
    push rsi
    push rdi
    push rbx
    mov rax, r11
    call check_node_in_sys
    cmp al, 1
    je .check_auth_flag
    cmp r11, 0
    jne .allowed
    mov rsi, leaf1_buf
    mov rdi, str_sys_name
    call str_eq
    cmp al, 1
    jne .allowed
.check_auth_flag:
    cmp byte [auth_valid], 1
    je .allowed
    mov rsi, msg_auth_required
    mov al, ATTR_ERROR
    call print_string_attr
    mov rax, 1
    jmp .out
.allowed:
    xor rax, rax
.out:
    pop rbx
    pop rdi
    pop rsi
    pop rax
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
    cmp byte [node_type + r9], NODE_TYPE_CHAIN
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
    mov word [node_next + r9*2], 0xFFFF
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
    mov word [node_next + r9*2], 0xFFFF
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

; fs_file_len: rax = file node index. Returns rax = total content bytes
; (each slot stores a 0-terminated chunk, so this is the logical length).
fs_file_len:
    push rbx
    push rcx
    push rsi
    mov rcx, rax                ; current node in the chain
    xor rbx, rbx                ; running total
.len_loop:
    mov rsi, rcx
    imul rsi, CONTENT_LEN
    lea rsi, [node_content + rsi]
    call str_len
    add rbx, rax
    movzx rax, word [node_next + rcx*2]
    cmp rax, 0xFFFF
    je .done
    mov rcx, rax
    jmp .len_loop
.done:
    mov rax, rbx
    pop rsi
    pop rcx
    pop rbx
    ret

; fs_read_file: rax = file node index, rdi = destination buffer. Concatenates
; every chunk in the file's chain into the destination (0-terminated). The
; destination buffer must hold fs_file_len bytes + 1.
fs_read_file:
    push rbx
    push rsi
    push rdi
    mov rbx, rax                ; current node
.read_loop:
    mov rsi, rbx
    imul rsi, CONTENT_LEN
    lea rsi, [node_content + rsi]
    call str_copy               ; rdi ends up just past the NUL
    movzx rax, word [node_next + rbx*2]
    cmp rax, 0xFFFF
    je .done
    dec rdi                     ; step back over the NUL: the next chunk overwrites it
    mov rbx, rax
    jmp .read_loop
.done:
    pop rdi
    pop rsi
    pop rbx
    ret

; fs_write_file: rax = file node index, rsi = content to store (0-terminated).
; Writes the content across the file's chain, allocating NODE_TYPE_CHAIN
; continuation nodes in the same volume slice as needed and freeing any that
; become surplus. Returns CF=0 on success, CF=1 if the volume ran out of
; nodes (partial write possible - the file is still valid, just truncated).
fs_write_file:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov rbx, rax                ; current node (starts at the file's head)
    mov r8, rsi                 ; r8 = remaining content ptr
.write_loop:
    ; copy one chunk into the current node
    mov rdi, rbx
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    mov rcx, 0
.copy_char:
    mov al, [r8]
    cmp al, 0
    je .chunk_done
    cmp rcx, CONTENT_LEN - 1
    jae .need_next
    mov [rdi + rcx], al
    inc r8
    inc rcx
    jmp .copy_char
.chunk_done:
    mov byte [rdi + rcx], 0     ; NUL-terminate this chunk
    mov [rdi + CONTENT_LEN - 1], byte 0
    jmp .finish
.need_next:
    ; this node is full - link a continuation node if we don't have one
    mov byte [rdi + CONTENT_LEN - 1], 0
    movzx rdx, word [node_next + rbx*2]
    cmp rdx, 0xFFFF
    jne .use_next
    ; allocate a chain node in this volume's slice (parent = the file head)
    push rsi
    push r8
    mov rax, rbx
    mov rsi, empty_str
    mov r10, NODE_TYPE_CHAIN
    call fs_create_node
    pop r8
    pop rsi
    cmp rax, -1
    je .no_space
    mov rdx, rax
    mov [node_next + rbx*2], dx
.use_next:
    mov rbx, rdx
    jmp .write_loop
.finish:
    ; truncate any leftover chain nodes beyond what we wrote
    movzx rcx, word [node_next + rbx*2]
    cmp rcx, 0xFFFF
    je .clean
    mov [node_next + rbx*2], word 0xFFFF
    mov rax, rcx
    call fs_free_chain
.clean:
    clc
    jmp .out
.no_space:
    stc
.out:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; fs_write_binary_file: rax = file node index, rsi = buffer ptr, rcx = length in bytes.
; Writes arbitrary binary data across the file's chain.
fs_write_binary_file:
    mov [node_bin_len + rax*4], ecx
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    mov rbx, rax
    mov r8, rsi
    mov r9, rcx
.wb_loop:
    test r9, r9
    jle .wb_finish
    mov rdi, rbx
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    xor rcx, rcx
.wb_copy_byte:
    test r9, r9
    jle .wb_chunk_done
    cmp rcx, CONTENT_LEN - 1
    jae .wb_need_next
    mov al, [r8]
    mov [rdi + rcx], al
    inc r8
    dec r9
    inc rcx
    jmp .wb_copy_byte
.wb_chunk_done:
    mov byte [rdi + rcx], 0
    jmp .wb_finish
.wb_need_next:
    mov byte [rdi + rcx], 0
    movzx rdx, word [node_next + rbx*2]
    cmp rdx, 0xFFFF
    jne .wb_use_next
    push rsi
    push r8
    push r9
    mov rax, rbx
    mov rsi, empty_str
    mov r10, NODE_TYPE_CHAIN
    call fs_create_node
    pop r9
    pop r8
    pop rsi
    cmp rax, -1
    je .wb_no_space
    mov rdx, rax
    mov [node_next + rbx*2], dx
.wb_use_next:
    mov rbx, rdx
    jmp .wb_loop
.wb_finish:
    movzx rcx, word [node_next + rbx*2]
    cmp rcx, 0xFFFF
    je .wb_clean
    mov [node_next + rbx*2], word 0xFFFF
    mov rax, rcx
    call fs_free_chain
.wb_clean:
    clc
    jmp .wb_out
.wb_no_space:
    stc
.wb_out:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; fs_read_binary_file: rax = file node index, rdi = destination buffer.
; Binary-safe counterpart to fs_read_file: copies back the exact byte
; count fs_write_binary_file recorded for this node, instead of stopping
; at the first 0x00 byte - real binary content (e.g. a compiled .run
; program) contains plenty of those and isn't just a C string.
; Out: rax = number of bytes copied. Destination buffer must hold that
; many bytes (same buffers already sized for fs_read_file are fine -
; compiled programs are far smaller than fs_io_buf/EDIT_MAX).
fs_read_binary_file:
    push rbx
    push rcx
    push rsi
    push rdi
    push r8
    push r9
    mov r8d, [node_bin_len + rax*4]   ; r8 = bytes remaining to copy
    mov r9, r8                        ; r9 = total, for the return value
    mov rbx, rax                      ; current node
.rb_loop:
    test r8, r8
    jle .rb_done
    mov rsi, rbx
    imul rsi, CONTENT_LEN
    lea rsi, [node_content + rsi]
    xor rcx, rcx
.rb_copy_byte:
    test r8, r8
    jle .rb_done
    cmp rcx, CONTENT_LEN - 1
    jae .rb_next_node
    mov al, [rsi + rcx]
    mov [rdi], al
    inc rdi
    inc rcx
    dec r8
    jmp .rb_copy_byte
.rb_next_node:
    movzx rax, word [node_next + rbx*2]
    cmp rax, 0xFFFF
    je .rb_done                       ; chain ended early - shouldn't happen
    mov rbx, rax
    jmp .rb_loop
.rb_done:
    mov rax, r9
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; fs_free_chain: rax = node index. Frees every continuation node linked after
; it (not the node itself) and unlinks them. Never used on a folder.
fs_free_chain:
    push rax
    push rcx
    movzx rax, word [node_next + rax*2]   ; rax = first continuation node
.free_loop:
    cmp rax, 0xFFFF
    je .done
    movzx rcx, word [node_next + rax*2]   ; remember what follows this node
    mov [node_next + rax*2], word 0xFFFF  ; unlink it
    call fs_delete_node                   ; frees rax; rax & rcx are preserved
    mov rax, rcx                          ; walk to the next continuation node
    jmp .free_loop
.done:
    pop rcx
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
    cmp byte [node_type + r13], NODE_TYPE_CHAIN
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
    ; a file may own a chain of continuation nodes - free it first
    cmp byte [node_type + r8], 2
    jne .no_chain
    mov rax, r8
    call fs_free_chain
.no_chain:
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
    ; copy the whole file (possibly a multi-node chain) through staging
    mov rax, r8
    lea rdi, [fs_io_buf]
    call fs_read_file
    mov rax, r12
    lea rsi, [fs_io_buf]
    call fs_write_file
    jmp .done
.isfolder:
    xor r13, r13
.childloop:
    cmp r13, MAX_NODES
    jae .done
    cmp byte [node_type + r13], 0
    je .childnext
    cmp byte [node_type + r13], NODE_TYPE_CHAIN
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
    push r10
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
    ; accept v4 (current, 256-node), legacy v3 (64-node), and v2 (old
    ; single-block) formats. fs_layout_ver records which one so the
    ; name/content sections below know which LBAs/sector counts to use;
    ; the node_next section below still just needs "does this format even
    ; have a chain sector" (true for v3 and v4, false for v2).
    mov byte [fs_layout_ver], 0
    cmp byte [fs_super_buf+4], SFFS_VERSION
    je .is_v4
    cmp byte [fs_super_buf+4], SFFS_VERSION_V3
    je .is_v3
    cmp byte [fs_super_buf+4], SFFS_VERSION_V2
    je .version_ok
    jmp .fail
.is_v4:
    mov byte [fs_layout_ver], 2
    jmp .version_ok
.is_v3:
    mov byte [fs_layout_ver], 1
.version_ok:
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
    ; node_next (v3/v4 only) - a v2 volume gets a fresh no-chain slice instead
    cmp byte [fs_layout_ver], 0
    je .next_v2
    mov rax, NEXT_LBA
    lea rdi, [fs_next_scratch]
    call disk_read_sector
    jc .fail
    lea rsi, [fs_next_scratch]
    lea rdi, [node_next + r8*2]
    mov rcx, VOL_NODES
    rep movsw
    jmp .next_loaded
.next_v2:
    lea rdi, [node_next + r8*2]
    mov rcx, VOL_NODES
    mov ax, 0xFFFF
    rep stosw
.next_loaded:
    ; node_name: LBA/sector-count depends on layout version
    cmp byte [fs_layout_ver], 0
    jne .name_not_v2
    mov rax, SUPER_LBA + 3
    mov r10, 1                   ; v2 packed all names into a single sector
    jmp .name_go
.name_not_v2:
    cmp byte [fs_layout_ver], 1
    jne .name_v4
    mov rax, OLD_NAME_LBA
    mov r10, OLD_NAME_SECTORS
    jmp .name_go
.name_v4:
    mov rax, NAME_LBA
    mov r10, NAME_SECTORS
.name_go:
    mov rcx, r10
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
    ; node_content: LBA/sector-count depends on layout version
    cmp byte [fs_layout_ver], 0
    jne .content_not_v2
    mov rax, SUPER_LBA + 7
    mov r10, 1
    jmp .content_go
.content_not_v2:
    cmp byte [fs_layout_ver], 1
    jne .content_v4
    mov rax, OLD_CONTENT_LBA
    mov r10, OLD_CONTENT_SECTORS
    jmp .content_go
.content_v4:
    mov rax, CONTENT_LBA
    mov r10, CONTENT_SECTORS
.content_go:
    mov rcx, r10
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
    ; node_bin_len: only the v4 layout carries it; v2/v3 volumes predate
    ; binary files, so zero the whole table - stale memory must never
    ; look like a valid length for a binary file read.
    cmp byte [fs_layout_ver], 2
    jne .binlen_zero
    mov rax, BINLEN_LBA
    mov rcx, BINLEN_SECTORS
    lea rdi, [node_bin_len]
    mov r9, r8
    imul r9, 4
    add rdi, r9
.binlen_read_loop:
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
    loop .binlen_read_loop
    jmp .binlen_done
.binlen_zero:
    lea rdi, [node_bin_len]
    mov r9, r8
    imul r9, 4
    add rdi, r9
    mov rcx, VOL_NODES
    xor eax, eax
    rep stosd
.binlen_done:
    ; v2/v3 volumes only ever had OLD_VOL_NODES(64) real slots on disk -
    ; explicitly free the newly-available 64..255 range for this volume
    ; instead of trusting whatever bytes happened to land there, so the
    ; extra v4 capacity is guaranteed clean rather than full of stale
    ; leftovers from disk. A v4 volume already has all 256 slots valid
    ; as read, so this is skipped for it.
    cmp byte [fs_layout_ver], 2
    je .no_extend
    mov rcx, OLD_VOL_NODES
.extend_loop:
    cmp rcx, VOL_NODES
    jae .no_extend
    mov r9, r8
    add r9, rcx
    mov byte [node_type + r9], 0
    mov word [node_parent + r9*2], 0
    mov word [node_next + r9*2], 0xFFFF
    mov rdi, r9
    imul rdi, NAME_LEN
    lea rdi, [node_name + rdi]
    push rcx
    mov rcx, NAME_LEN
    xor al, al
    rep stosb
    pop rcx
    mov rdi, r9
    imul rdi, CONTENT_LEN
    lea rdi, [node_content + rdi]
    push rcx
    mov rcx, CONTENT_LEN
    xor al, al
    rep stosb
    pop rcx
    inc rcx
    jmp .extend_loop
.no_extend:
    xor rax, rax
    jmp .done
.nodisk:
    mov byte [fs_disk_available], 0
.fail:
    mov rax, -1
.done:
    pop r10
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
    ; --- node_next: this volume's 64 words padded to a full 0xFFFF sector ---
    mov rdi, fs_next_scratch
    mov rcx, 512 / 2
    mov ax, 0xFFFF
    rep stosw
    lea rsi, [node_next + r8*2]
    lea rdi, [fs_next_scratch]
    mov rcx, VOL_NODES
    rep movsw
    mov rax, NEXT_LBA
    lea rsi, [fs_next_scratch]
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
    call spinner_step
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
    call spinner_step
    call disk_write_sector
    pop rsi
    pop rcx
    pop rax
    jc .fail
    add rsi, 512
    inc rax
    loop .content_loop
    ; --- node_bin_len: exact byte count of binary files (written by
    ; fs_write_binary_file, e.g. compiled .run programs). Without it the
    ; length is lost on a reboot and fs_read_binary_file returns 0 bytes.
    mov rax, BINLEN_LBA
    mov rcx, BINLEN_SECTORS
    lea rsi, [node_bin_len]
    mov rdi, r8
    imul rdi, 4
    add rsi, rdi
.binlen_loop:
    push rax
    push rcx
    push rsi
    call spinner_step
    call disk_write_sector
    pop rsi
    pop rcx
    pop rax
    jc .fail
    add rsi, 512
    inc rax
    loop .binlen_loop
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

; ==================================================================
;  RTL8139 NIC driver + base network stack (Milestone B)
;  Polled, no IRQs. Inbound frames land in a DMA RX ring; the shell
;  loop calls netpoll to drain and dispatch them (ARP / IPv4 / ICMP /
;  UDP-DNS). Outbound frames are built in nic_tx_buf and pushed out
;  TSAD0/TSD0 by nic_send_raw. Static IP config lives in nic_ip /
;  nic_mask / nic_gw / nic_dns (defaults are the QEMU slirp values).
;  All register discipline: every function in this section saves and
;  restores every register it uses, so the polling loops (bounce /
;  monitor / dns) can hold state in r12/r13/r14/r15 across calls.
; ==================================================================
NIC_VENDOR_ID   equ 0x10EC
NIC_DEVICE_ID   equ 0x8139
NIC_PCI_CMD     equ 0x04
NIC_PCI_BAR0    equ 0x10

NIC_IO_IDR0     equ 0x00
NIC_IO_TSD0     equ 0x10
NIC_IO_TSAD0    equ 0x20
NIC_IO_RBSTART  equ 0x30
NIC_IO_CBR      equ 0x34
NIC_IO_CAPR     equ 0x38
NIC_IO_CMD      equ 0x37
NIC_IO_IMR      equ 0x3C
NIC_IO_ISR      equ 0x3E
NIC_IO_TCR      equ 0x40
NIC_IO_RCR      equ 0x44
NIC_IO_CFG1     equ 0x52

NIC_RX_RING_SIZE equ 0x2000        ; 8KB ring (fits the boot budget)
NIC_RX_RING_MASK equ 0x1FFF
NIC_TX_BUF_SIZE  equ 0x800         ; 2KB frame build/DMA buffer
ETH_TYPE_ARP_W   equ 0x0608        ; "08 06" as a little-endian memory word
ETH_TYPE_IP_W    equ 0x0008        ; "08 00" as a little-endian memory word
IP_PROTO_ICMP    equ 0x01
IP_PROTO_TCP     equ 0x06
IP_PROTO_UDP     equ 0x11

; ---- Intel e1000 (82540/82541/82545/82546/8257x "PRO/1000") support -----
; A second NIC backend behind the exact same nic_init/nic_send_raw/nic_fetch_rx
; entry points the RTL8139 driver above already exposes, so ARP/IPv4/ICMP/
; UDP-DNS and every shell command above never need to know which chip is
; live - they only ever touch nic_present/nic_mac and call nic_send_raw /
; nic_fetch_rx. nic_driver_type (0=rtl8139, 1=e1000) picks the branch inside
; those three functions. Unlike the RTL8139's port I/O, e1000 registers are
; memory-mapped (BAR0), so this backend uses ordinary loads/stores against
; the identity-mapped physical address in nic_mmio_base instead of in/out.
E1000_VENDOR_ID  equ 0x8086

E1000_CTRL       equ 0x0000
E1000_STATUS     equ 0x0008
E1000_ICR        equ 0x00C0
E1000_IMS        equ 0x00D0
E1000_IMC        equ 0x00D8
E1000_RCTL       equ 0x0100
E1000_TCTL       equ 0x0400
E1000_TIPG       equ 0x0410
E1000_RDBAL      equ 0x2800
E1000_RDBAH      equ 0x2804
E1000_RDLEN      equ 0x2808
E1000_RDH        equ 0x2810
E1000_RDT        equ 0x2818
E1000_TDBAL      equ 0x3800
E1000_TDBAH      equ 0x3804
E1000_TDLEN      equ 0x3808
E1000_TDH        equ 0x3810
E1000_TDT        equ 0x3818
E1000_MTA        equ 0x5200
E1000_RAL0       equ 0x5400
E1000_RAH0       equ 0x5404

E1000_CTRL_RST   equ 0x04000000
E1000_CTRL_SLU_ASDE equ 0x00000060   ; SLU (bit6) | ASDE (bit5)

E1000_RCTL_EN    equ 0x00000002
E1000_RCTL_UPE   equ 0x00000008
E1000_RCTL_MPE   equ 0x00000010
E1000_RCTL_BAM   equ 0x00008000
E1000_RCTL_SECRC equ 0x04000000      ; strip the 4-byte Ethernet CRC, like RTL8139's ring does

E1000_TCTL_EN    equ 0x00000002
E1000_TCTL_PSP   equ 0x00000008
E1000_TCTL_CT    equ 0x000000F0      ; collision threshold 0x0F << 4
E1000_TCTL_COLD  equ 0x00040000      ; collision distance 0x40 << 12 (full duplex)
E1000_TIPG_VAL   equ 0x0060200A      ; Intel-recommended IPGT/IPGR1/IPGR2 for full duplex

E1000_TXD_CMD_EOP_IFCS_RS equ 0x0B   ; EOP(0x01) | IFCS(0x02) | RS(0x08)
E1000_DD         equ 0x01            ; Descriptor Done, shared by RX/TX status bytes

E1000_RX_DESC_COUNT equ 8            ; 8 * 16B = 128B: the minimum ring length e1000 accepts
E1000_TX_DESC_COUNT equ 8
E1000_RX_BUF_SIZE   equ 2048

; ---- Realtek RTL8168/8169/8161 ("PCIe GBE Family Controller") support ---
; A third NIC backend behind the same nic_init/nic_send_raw/nic_fetch_rx
; entry points (nic_driver_type: 0=rtl8139, 1=e1000, 2=rtl8168). This is
; the common gigabit Realtek chip found on most real desktop motherboards -
; a completely different beast from the old RTL8139: descriptor rings like
; e1000, but reached over port I/O (BAR0) like the RTL8139 driver, so it
; reuses nic_io_read8/16/32 / nic_io_write8/16/32 against nic_io_base. Only
; the "normal priority" TX queue is used; the high-priority queue is left
; zeroed/unused. Register offsets and the reset/bring-up sequence follow
; the publicly documented RTL8169 programming model (OSDev.org's RTL8169
; page, itself sourced from Realtek's public datasheet).
RTL_VENDOR_ID    equ 0x10EC

RTL_IO_IDR0      equ 0x00             ; MAC address, 6 bytes
RTL_IO_TNPDS_LO  equ 0x20             ; Tx Normal Priority Descriptor Start Addr (low dword)
RTL_IO_TNPDS_HI  equ 0x24
RTL_IO_THPDS_LO  equ 0x28             ; Tx High Priority ring - unused, kept zeroed
RTL_IO_THPDS_HI  equ 0x2C
RTL_IO_CMD       equ 0x37             ; Chip Command register
RTL_IO_TPPOLL    equ 0x38             ; Transmit Priority Polling (kick DMA)
RTL_IO_IMR       equ 0x3C
RTL_IO_ISR       equ 0x3E
RTL_IO_TCR       equ 0x40             ; TxConfig
RTL_IO_RCR       equ 0x44             ; RxConfig
RTL_IO_9346CR    equ 0x50             ; EEPROM/config-register lock
RTL_IO_CPCMD     equ 0xE0             ; C+ Command Register
RTL_IO_RMS       equ 0xDA             ; Rx max packet size (word)
RTL_IO_MTPS      equ 0xEC             ; Tx max packet size, 128-byte units (byte)
RTL_IO_RDSAR_LO  equ 0xE4             ; Rx Descriptor Start Addr (low dword)
RTL_IO_RDSAR_HI  equ 0xE8
RTL_IO_PHYSTATUS equ 0x6C             ; PHY status register; bit1 = LinkStatus
RTL_IO_PHYAR     equ 0x60             ; PHY (MDIO) Access Register
RTL_PHYSTATUS_LINK equ 0x02

RTL_CMD_RST      equ 0x10
RTL_CMD_TE       equ 0x04
RTL_CMD_RE       equ 0x08
RTL_9346_UNLOCK  equ 0xC0
RTL_9346_LOCK    equ 0x00
RTL_TPPOLL_NPQ   equ 0x40

RTL_DESC_OWN     equ 0x80000000
RTL_DESC_EOR     equ 0x40000000
RTL_DESC_FS      equ 0x20000000
RTL_DESC_LS      equ 0x10000000

RTL_RX_DESC_COUNT equ 8
RTL_TX_DESC_COUNT equ 8
RTL_RX_BUF_SIZE   equ 2048

; ---- I/O helpers -------------------------------------------------
; nic_io_read8/16/32: edi = port -> al/ax/eax
nic_io_read8:
    mov dx, di
    in al, dx
    ret
nic_io_read16:
    mov dx, di
    in ax, dx
    ret
nic_io_read32:
    mov dx, di
    in eax, dx
    ret
; nic_io_write8/16/32: edi = port, data in al/ax/eax
nic_io_write8:
    mov dx, di
    out dx, al
    ret
nic_io_write16:
    mov dx, di
    out dx, ax
    ret
nic_io_write32:
    mov dx, di
    out dx, eax
    ret
; nic_io_read_block: edi = start port, rsi = dst, rcx = byte count
nic_io_read_block:
    push rax
    push rcx
    push rdi
    push rsi
.bloop:
    mov dx, di
    in al, dx
    mov [rsi], al
    inc edi
    inc rsi
    dec rcx
    jnz .bloop
    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret

; rtc_sec_now: eax = current RTC seconds (0..59), zero-extended. Used for
; coarse 1s-granularity timeouts in the ARP / ICMP / DNS wait loops.
rtc_sec_now:
    push rbx
    push rdx
.rsn_retry:
    call rtc_wait_uip            ; don't read while the RTC is mid-update
    mov al, 0x00
    call cmos_read
    mov bl, al                   ; first reading
    call rtc_wait_uip            ; guard again in case an update started
                                  ; between our address-select and data read
    mov al, 0x00
    call cmos_read
    cmp al, bl
    jne .rsn_retry                ; two reads disagree - torn/transient, retry
    ; BUGFIX: this used to return the raw CMOS byte unconverted. Real
    ; hardware defaults to BCD mode (status B bit2 clear), same as
    ; rtc_update already accounts for - so a seconds value of "10" comes
    ; back as the byte 0x10 (16 decimal), "20" as 0x20 (32 decimal), etc.
    ; Tick DETECTION (a plain inequality compare against the previous
    ; reading) still fired correctly every real second regardless, so the
    ; wait loop's actual budget was never shortened by this - but the
    ; elapsed-time SUBTRACTION in the error path assumes plain binary
    ; 0..59 seconds, so once start/end straddle a tens-digit boundary the
    ; math comes out wrong (this is why a real ~5-6s wait was being
    ; reported as "elapsed: 0" in netdiag_dump_tx). Mirror rtc_update's
    ; own check of status register B bit2 rather than assuming BCD
    ; unconditionally - only convert if the chip is actually in BCD mode.
    push rax
    mov al, 0x0B
    call cmos_read
    test al, 0x04
    jnz .rsn_binary               ; bit2 set = already binary, nothing to do
    pop rax
    mov al, bl
    call bcd_to_bin
    movzx eax, al
    jmp .rsn_done
.rsn_binary:
    pop rax
    movzx eax, bl
.rsn_done:
    pop rdx
    pop rbx
    ret

; ---- PCI ---------------------------------------------------------
; pci_find_nic: scans bus 0 for vendor 10EC device 8139. Returns CF=0 and
; nic_pci_bus/dev/func set, or CF=1.
; pci_find_nic: brute-force scan of every PCI bus (0..255), every device
; (0..31), function 0 first and then functions 1..7 if the header-type byte
; says the device is multi-function - matching vendor 0x10EC/device 0x8139.
; A bus-0-only scan (the original version of this routine) finds nothing on
; real hardware, where the NIC typically sits behind a PCIe root port on a
; non-zero bus; QEMU's flat topology just happened to put it on bus 0.
; Returns CF=0 and nic_pci_bus/dev/func set, or CF=1.
pci_find_nic:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r11
    xor ebx, ebx                     ; bus
.pbus_loop:
    cmp ebx, 256
    jae .pnot_found
    xor ecx, ecx                     ; device
.pdev_loop:
    cmp ecx, 32
    jae .pnext_bus
    xor edx, edx                     ; try function 0 first
    xor r8, r8
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .pnext_dev                    ; nothing at this slot at all
    cmp ax, NIC_VENDOR_ID
    jne .pf0_no_match
    shr eax, 16
    cmp ax, NIC_DEVICE_ID
    je .pfound
.pf0_no_match:
    xor edx, edx
    mov r8, 0x0C                     ; header-type dword
    call pci_read32
    shr eax, 16
    test al, 0x80                    ; multi-function bit
    jz .pnext_dev                    ; single-function: nothing more here
    mov r11d, 1
.pfunc_loop:
    cmp r11d, 8
    jae .pnext_dev
    mov edx, r11d
    xor r8, r8
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .pfunc_next
    cmp ax, NIC_VENDOR_ID
    jne .pfunc_next
    shr eax, 16
    cmp ax, NIC_DEVICE_ID
    je .pfound
.pfunc_next:
    inc r11d
    jmp .pfunc_loop
.pnext_dev:
    inc ecx
    jmp .pdev_loop
.pnext_bus:
    inc ebx
    jmp .pbus_loop
.pnot_found:
    pop r11
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
.pfound:
    mov [nic_pci_bus], bl
    mov [nic_pci_dev], cl
    mov [nic_pci_func], dl
    pop r11
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret

; pci_find_e1000: brute-force scan of PCI bus 0, vendor 0x8086, matching any
; device id in e1000_dev_ids. Real e1000-family silicon spans a lot of PCI
; device ids across generations (82540/82541/82545/82546/82571-82574/...),
; unlike the RTL8139's single fixed id, so this checks the incoming device
; id against a table instead of one constant. QEMU's "e1000" model reports
; 0x100E. Returns CF=0 and nic_pci_bus/dev/func set, or CF=1.
; pci_find_e1000: brute-force scan of every PCI bus (0..255), every device,
; function 0 first and then functions 1..7 if multi-function, vendor 0x8086,
; matching any device id in e1000_dev_ids. Real e1000-family silicon spans a
; lot of PCI device ids across generations (82540/82541/82545/82546/82571-
; 82574/...), unlike the RTL8139's single fixed id, so this checks the
; incoming device id against a table instead of one constant. QEMU's "e1000"
; model reports 0x100E. A bus-0-only scan misses real hardware, where the
; NIC usually sits behind a PCIe root port on a non-zero bus - see
; pci_find_nic above for the same fix. Returns CF=0 and nic_pci_bus/dev/func
; set, or CF=1.
pci_find_e1000:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    xor ebx, ebx                     ; bus
.ebus_loop:
    cmp ebx, 256
    jae .enot_found
    xor ecx, ecx                     ; device
.edev_loop:
    cmp ecx, 32
    jae .enext_bus
    xor edx, edx                     ; try function 0 first
    xor r8, r8
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .enext_dev                    ; nothing at this slot at all
    cmp ax, E1000_VENDOR_ID
    jne .ef0_no_match
    shr eax, 16                      ; eax = device id
    lea r9, [e1000_dev_ids]
    mov r10d, E1000_DEV_ID_COUNT
.ecmp_loop0:
    cmp word [r9], ax
    je .efound
    add r9, 2
    dec r10d
    jnz .ecmp_loop0
.ef0_no_match:
    xor edx, edx
    mov r8, 0x0C                     ; header-type dword
    call pci_read32
    shr eax, 16
    test al, 0x80                    ; multi-function bit
    jz .enext_dev                    ; single-function: nothing more here
    mov r11d, 1
.efunc_loop:
    cmp r11d, 8
    jae .enext_dev
    mov edx, r11d
    xor r8, r8
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .efunc_next
    cmp ax, E1000_VENDOR_ID
    jne .efunc_next
    shr eax, 16
    lea r9, [e1000_dev_ids]
    mov r10d, E1000_DEV_ID_COUNT
.ecmp_loopN:
    cmp word [r9], ax
    je .efound
    add r9, 2
    dec r10d
    jnz .ecmp_loopN
.efunc_next:
    inc r11d
    jmp .efunc_loop
.enext_dev:
    inc ecx
    jmp .edev_loop
.enext_bus:
    inc ebx
    jmp .ebus_loop
.enot_found:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
.efound:
    mov [nic_pci_bus], bl
    mov [nic_pci_dev], cl
    mov [nic_pci_func], dl
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret

; pci_find_rtl8168: brute-force scan of PCI bus 0, vendor 0x10EC, matching
; any device id in rtl_dev_ids. Returns CF=0 and nic_pci_bus/dev/func set,
; or CF=1.
; pci_find_rtl8168: brute-force scan of every PCI bus (0..255), every
; device, function 0 first and then functions 1..7 if multi-function,
; vendor 0x10EC, matching any device id in rtl_dev_ids. A bus-0-only scan
; misses real hardware, where the NIC usually sits behind a PCIe root port
; on a non-zero bus - see pci_find_nic above for the same fix. Returns
; CF=0 and nic_pci_bus/dev/func set, or CF=1.
pci_find_rtl8168:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    xor ebx, ebx                     ; bus
.rbus_loop:
    cmp ebx, 256
    jae .rnot_found
    xor ecx, ecx                     ; device
.rdev_loop:
    cmp ecx, 32
    jae .rnext_bus
    xor edx, edx                     ; try function 0 first
    xor r8, r8
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .rnext_dev                    ; nothing at this slot at all
    cmp ax, RTL_VENDOR_ID
    jne .rf0_no_match
    shr eax, 16                     ; eax = device id
    lea r9, [rtl_dev_ids]
    mov r10d, RTL_DEV_ID_COUNT
.rcmp_loop0:
    cmp word [r9], ax
    je .rfound
    add r9, 2
    dec r10d
    jnz .rcmp_loop0
.rf0_no_match:
    xor edx, edx
    mov r8, 0x0C                     ; header-type dword
    call pci_read32
    shr eax, 16
    test al, 0x80                    ; multi-function bit
    jz .rnext_dev                    ; single-function: nothing more here
    mov r11d, 1
.rfunc_loop:
    cmp r11d, 8
    jae .rnext_dev
    mov edx, r11d
    xor r8, r8
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .rfunc_next
    cmp ax, RTL_VENDOR_ID
    jne .rfunc_next
    shr eax, 16
    lea r9, [rtl_dev_ids]
    mov r10d, RTL_DEV_ID_COUNT
.rcmp_loopN:
    cmp word [r9], ax
    je .rfound
    add r9, 2
    dec r10d
    jnz .rcmp_loopN
.rfunc_next:
    inc r11d
    jmp .rfunc_loop
.rnext_dev:
    inc ecx
    jmp .rdev_loop
.rnext_bus:
    inc ebx
    jmp .rbus_loop
.rnot_found:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
.rfound:
    mov [nic_pci_bus], bl
    mov [nic_pci_dev], cl
    mov [nic_pci_func], dl
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret

; pci_pm_wake: force the device at nic_pci_bus/dev/func out of D3 into D0
; via its PCI Power Management capability, if it has one. On real hardware,
; firmware quite often leaves an onboard NIC parked in D3hot at handoff
; (or a previous OS's ACPI driver put it there and a warm reset didn't
; clear it) - config/IO/MMIO reads and writes to a device in D3 are
; unreliable (commonly read back as all-1s/garbage, writes silently
; dropped), so every other fix in the bring-up path is moot until this
; runs. QEMU's virtual devices are always already in D0, which is why
; this was invisible there. Walks the capabilities list from offset 0x34
; looking for PCI_CAP_ID_PM (0x01), clears the PowerState bits in PMCSR
; (cap_ptr+4) to select D0, then waits >=10ms per the PCI PM spec before
; the device's config space is touched again. No-op if the device has no
; PM capability, or is already in D0.
pci_pm_wake:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11

    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, 0x34                  ; Capabilities Pointer register
    call pci_read32
    movzx r11d, al                 ; r11 = offset of first capability
.pmw_walk:
    test r11d, r11d
    jz .pmw_done                   ; end of list: no PM capability, nothing to do
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8d, r11d
    and r8d, 0xFC
    call pci_read32                ; al=cap id, ah=next ptr (bits 8:15 of eax)
    cmp al, 0x01                   ; PCI_CAP_ID_PM
    je .pmw_found
    mov r10d, eax
    shr r10d, 8
    movzx r11d, r10b               ; next capability pointer
    jmp .pmw_walk
.pmw_found:
    mov r9d, r11d
    and r9d, 0xFC
    add r9d, 4                     ; PMCSR lives in the dword right after the cap header
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8d, r9d
    call pci_read32
    and eax, 0xFFFFFFFC            ; PowerState = 00b -> D0 (bits 1:0 of PMCSR)
    mov r10d, eax
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8d, r9d
    call pci_write32
    ; PCI Power Management spec: after a D3hot->D0 transition, software
    ; must not access the function's config/IO/memory space for >=10ms.
    mov r9, 0x8000000
.pmw_delay:
    dec r9
    jnz .pmw_delay
.pmw_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; pci_disable_aspm: clear ASPM (Active State Power Management, L0s/L1) in the
; PCI Express Capability's Link Control register for the device at
; nic_pci_bus/dev/func, if it has one. Firmware on most real boards leaves
; ASPM enabled by default; a driver that only pokes the legacy I/O BAR and
; never does the associated PCIe link power-state handshake can end up with
; a chip whose descriptor-DMA engine stalls in a low-power link state - a TX
; descriptor gets handed to it (OWN set) but the engine never actually
; drains it, even though the copper PHY link itself is up (PHY link state
; and PCIe link power state are independent). QEMU's virtual PCIe root port
; doesn't implement ASPM at all, which is why this is invisible there. Walks
; the same capabilities list pci_pm_wake does, looking for PCI_CAP_ID_EXP
; (0x10) this time, then clears bits 1:0 (ASPM Control) of the Link Control
; register at cap_ptr+0x10. No-op if the device has no PCIe capability, or
; ASPM is already off.
PCI_CAP_ID_EXP equ 0x10
pci_disable_aspm:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11

    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, 0x34                  ; Capabilities Pointer register
    call pci_read32
    movzx r11d, al                 ; r11 = offset of first capability
.asp_walk:
    test r11d, r11d
    jz .asp_done                   ; end of list: no PCIe capability
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8d, r11d
    and r8d, 0xFC
    call pci_read32                ; al=cap id, ah=next ptr (bits 8:15)
    cmp al, PCI_CAP_ID_EXP
    je .asp_found
    mov r10d, eax
    shr r10d, 8
    movzx r11d, r10b
    jmp .asp_walk
.asp_found:
    mov r9d, r11d
    and r9d, 0xFC
    add r9d, 0x10                  ; Link Control register: cap_ptr+0x10 (word)
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8d, r9d
    call pci_read32
    and eax, 0xFFFFFFFC             ; clear ASPM Control (bits 1:0): L0s/L1 off
    mov r10d, eax
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8d, r9d
    call pci_write32
.asp_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- e1000 MMIO helpers -------------------------------------------
; e1000_reg_read32:  edi = register offset -> eax = value
; e1000_reg_write32: edi = register offset, eax = value to write
; BAR0 is identity-mapped (same trick expand_identity_map already sets up
; for every other DMA buffer in this kernel), so this is a plain load/store
; against nic_mmio_base+offset - no port I/O involved.
e1000_reg_read32:
    push rbx
    push rdi
    mov ebx, [nic_mmio_base]
    add rbx, rdi
    mov eax, [rbx]
    pop rdi
    pop rbx
    ret
e1000_reg_write32:
    push rbx
    push rdi
    mov ebx, [nic_mmio_base]
    add rbx, rdi
    mov [rbx], eax
    pop rdi
    pop rbx
    ret

; ---- bring-up ----------------------------------------------------
nic_init:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push rdi
    push rsi

    mov byte [nic_present], 0
    mov byte [nic_driver_type], 0
    call pci_find_nic
    jc .try_e1000

    call pci_pm_wake                 ; make sure it's in D0 before we touch it
    call pci_disable_aspm            ; keep the PCIe link out of L0s/L1

    ; PCI command: enable I/O space (bit0) + bus master (bit2)
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_CMD
    call pci_read32
    or eax, 0x0005
    mov r10d, eax
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_CMD
    call pci_write32

    ; BAR0 must be an I/O bar (QEMU's RTL8139 uses I/O by default)
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_BAR0
    call pci_read32
    test eax, 1
    jz .ndone
    and eax, 0xFFFFFFFC
    mov [nic_io_base], eax

    ; read the MAC from IDR0..IDR5
    mov edi, [nic_io_base]
    add edi, NIC_IO_IDR0
    lea rsi, [nic_mac]
    mov rcx, 6
    call nic_io_read_block

    ; soft reset: write RST (0x10) to CMD, poll until it clears
    mov edi, [nic_io_base]
    add edi, NIC_IO_CMD
    mov al, 0x10
    call nic_io_write8
    mov r9, 0x200000
.nreset_wait:
    mov edi, [nic_io_base]
    add edi, NIC_IO_CMD
    call nic_io_read8
    test al, 0x10
    jz .nreset_done
    dec r9
    jnz .nreset_wait
    jmp .ndone
.nreset_done:

    ; CONFIG1=0, interrupt mask off, clear ISR
    mov edi, [nic_io_base]
    add edi, NIC_IO_CFG1
    xor al, al
    call nic_io_write8
    mov edi, [nic_io_base]
    add edi, NIC_IO_IMR
    xor ax, ax
    call nic_io_write16
    mov edi, [nic_io_base]
    add edi, NIC_IO_ISR
    mov ax, 0xFFFF
    call nic_io_write16

    ; point the 8KB RX ring at our DMA buffer (identity-mapped)
    mov edi, [nic_io_base]
    add edi, NIC_IO_RBSTART
    lea eax, [nic_rx_ring]
    call nic_io_write32

    ; RCR = AB|AM|APM|AAP (accept everything), TCR = 0, CAPR/CBR = 0
    mov edi, [nic_io_base]
    add edi, NIC_IO_RCR
    mov eax, 0x0000000F
    call nic_io_write32
    mov edi, [nic_io_base]
    add edi, NIC_IO_TCR
    xor eax, eax
    call nic_io_write32
    ; seed CAPR = ring - 16 (the chip trails the read position by 16), CBR = 0
    mov edi, [nic_io_base]
    add edi, NIC_IO_CAPR
    mov ax, NIC_RX_RING_SIZE - 16
    call nic_io_write16
    mov edi, [nic_io_base]
    add edi, NIC_IO_CBR
    xor eax, eax
    call nic_io_write32

    ; software state
    mov dword [nic_capr], 0
    mov byte [nic_arp_tried], 0
    mov byte [nic_dns_retry], 0
    mov byte [nic_tx_desc], 0
    mov word [nic_dns_id], 1
    mov word [nic_echo_id], 0x1234
    mov word [nic_echo_seq], 1
    mov byte [nic_echo_got], 0
    mov byte [nic_echo_retry], 0
    mov word [nic_ip_id], 0x4200

    ; CMD = RE|TE = 0x0C; live
    mov edi, [nic_io_base]
    add edi, NIC_IO_CMD
    mov al, 0x0C
    call nic_io_write8

    mov byte [nic_present], 1
    clc
    jmp .ndone

; ---- e1000 bring-up (only reached if no RTL8139 was found above) --
.try_e1000:
    call pci_find_e1000
    jc .try_rtl8168

    call pci_pm_wake                 ; make sure it's in D0 before we touch it
    call pci_disable_aspm            ; keep the PCIe link out of L0s/L1

    ; PCI command: enable memory space (bit1) + bus master (bit2)
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_CMD
    call pci_read32
    or eax, 0x0006
    mov r10d, eax
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_CMD
    call pci_write32

    ; BAR0 must be a memory BAR (bit0=0 - an I/O bar here would mean a chip
    ; this driver doesn't understand); mask off the low 4 type/prefetch bits
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_BAR0
    call pci_read32
    test eax, 1
    jnz .ndone
    and eax, 0xFFFFFFF0
    mov [nic_mmio_base], eax

    ; Same issue AHCI's ABAR had (see ahci_mark_uncached above): polling an
    ; MMIO register through a cacheable identity-map entry can read back a
    ; stale cached value on real hardware instead of what the device just
    ; wrote - e.g. CTRL.RST below could look permanently set and the reset
    ; loop would spin out and abandon the NIC even though the device reset
    ; fine. ahci_mark_uncached is generic (just sets PCD on whichever 2MB
    ; identity-map page contains the physical address in edi), so reuse it
    ; here for the e1000's BAR0 window too.
    mov edi, eax
    call ahci_mark_uncached

    ; full device reset: CTRL.RST, then poll for it to self-clear
    mov edi, E1000_CTRL
    mov eax, E1000_CTRL_RST
    call e1000_reg_write32
    mov r9, 0x1000000
.e1k_reset_wait:
    mov edi, E1000_CTRL
    call e1000_reg_read32
    test eax, E1000_CTRL_RST
    jz .e1k_reset_done
    dec r9
    jnz .e1k_reset_wait
    jmp .ndone
.e1k_reset_done:

    ; polled driver, same discipline as the RTL8139 side: mask interrupts,
    ; then read ICR once to drop anything reset/link-change latched there
    mov edi, E1000_IMC
    mov eax, 0xFFFFFFFF
    call e1000_reg_write32
    mov edi, E1000_ICR
    call e1000_reg_read32

    ; link up: CTRL.SLU + CTRL.ASDE so the PHY auto-negotiates on real wire
    mov edi, E1000_CTRL
    call e1000_reg_read32
    or eax, E1000_CTRL_SLU_ASDE
    mov edi, E1000_CTRL
    call e1000_reg_write32

    ; zero the multicast table array (128 x 32-bit entries)
    xor r9d, r9d
.e1k_mta_loop:
    cmp r9d, 128
    jae .e1k_mta_done
    mov ecx, r9d
    shl ecx, 2
    mov edi, E1000_MTA
    add edi, ecx
    xor eax, eax
    call e1000_reg_write32
    inc r9d
    jmp .e1k_mta_loop
.e1k_mta_done:

    ; MAC address: real e1000 hardware auto-loads it from the EEPROM into
    ; RAL0/RAH0 during PCI reset (the datasheets call this out explicitly -
    ; software isn't expected to read the EEPROM directly for it), so read
    ; it back here rather than talk to the EEPROM ourselves. That keeps this
    ; driver EEPROM-layout-agnostic and works the same on QEMU's model and
    ; on real 82540/82545/82571/82574-family cards.
    mov edi, E1000_RAL0
    call e1000_reg_read32
    mov [nic_mac], al
    mov [nic_mac+1], ah
    shr eax, 16
    mov [nic_mac+2], al
    mov [nic_mac+3], ah
    mov edi, E1000_RAH0
    call e1000_reg_read32
    mov [nic_mac+4], al
    mov [nic_mac+5], ah

    ; RX ring: E1000_RX_DESC_COUNT descriptors, each pointing at its own
    ; 2KB buffer in e1000_rx_bufs (identity-mapped, so the linked address
    ; is already the physical address the chip needs).
    xor r9d, r9d
.e1k_rxd_loop:
    cmp r9d, E1000_RX_DESC_COUNT
    jae .e1k_rxd_done
    mov eax, r9d
    shl eax, 4
    lea rdi, [e1000_rx_desc + rax]
    mov eax, r9d
    imul eax, E1000_RX_BUF_SIZE
    lea rsi, [e1000_rx_bufs + rax]
    mov [rdi], rsi
    mov dword [rdi+8], 0
    mov dword [rdi+12], 0
    inc r9d
    jmp .e1k_rxd_loop
.e1k_rxd_done:
    mov edi, E1000_RDBAL
    lea eax, [e1000_rx_desc]
    call e1000_reg_write32
    mov edi, E1000_RDBAH
    xor eax, eax
    call e1000_reg_write32
    mov edi, E1000_RDLEN
    mov eax, E1000_RX_DESC_COUNT * 16
    call e1000_reg_write32
    mov edi, E1000_RDH
    xor eax, eax
    call e1000_reg_write32
    mov edi, E1000_RDT
    mov eax, E1000_RX_DESC_COUNT - 1
    call e1000_reg_write32
    mov edi, E1000_RCTL
    mov eax, E1000_RCTL_EN | E1000_RCTL_UPE | E1000_RCTL_MPE | E1000_RCTL_BAM | E1000_RCTL_SECRC
    call e1000_reg_write32

    ; TX ring: every descriptor points at the same nic_tx_buf. That's safe
    ; because nic_send_raw_e1000 always waits for DD before returning (same
    ; synchronous, no-overlapping-sends contract nic_send_raw already keeps
    ; for the RTL8139 side), so only one send is ever in flight.
    xor r9d, r9d
.e1k_txd_loop:
    cmp r9d, E1000_TX_DESC_COUNT
    jae .e1k_txd_done
    mov eax, r9d
    shl eax, 4
    lea rdi, [e1000_tx_desc + rax]
    lea rsi, [nic_tx_buf]
    mov [rdi], rsi
    mov dword [rdi+8], 0
    mov dword [rdi+12], 0
    inc r9d
    jmp .e1k_txd_loop
.e1k_txd_done:
    mov edi, E1000_TDBAL
    lea eax, [e1000_tx_desc]
    call e1000_reg_write32
    mov edi, E1000_TDBAH
    xor eax, eax
    call e1000_reg_write32
    mov edi, E1000_TDLEN
    mov eax, E1000_TX_DESC_COUNT * 16
    call e1000_reg_write32
    mov edi, E1000_TDH
    xor eax, eax
    call e1000_reg_write32
    mov edi, E1000_TDT
    xor eax, eax
    call e1000_reg_write32
    mov edi, E1000_TIPG
    mov eax, E1000_TIPG_VAL
    call e1000_reg_write32
    mov edi, E1000_TCTL
    mov eax, E1000_TCTL_EN | E1000_TCTL_PSP | E1000_TCTL_CT | E1000_TCTL_COLD
    call e1000_reg_write32

    ; software state
    mov dword [e1000_rx_idx], 0
    mov dword [e1000_tx_idx], 0
    mov byte [nic_arp_tried], 0
    mov byte [nic_dns_retry], 0
    mov word [nic_dns_id], 1
    mov word [nic_echo_id], 0x1234
    mov word [nic_echo_seq], 1
    mov byte [nic_echo_got], 0
    mov byte [nic_echo_retry], 0
    mov word [nic_ip_id], 0x4200

    mov byte [nic_driver_type], 1
    mov byte [nic_present], 1
    clc
    jmp .ndone

; ---- RTL8168/8169/8161 bring-up (only reached if neither RTL8139 nor
; e1000 was found above) -------------------------------------------
.try_rtl8168:
    call pci_find_rtl8168
    jc .ndone

    call pci_pm_wake                 ; make sure it's in D0 before we touch it
    call pci_disable_aspm            ; keep the PCIe link out of L0s/L1 so the
                                      ; descriptor DMA engine doesn't stall

    ; PCI command: enable I/O space (bit0) + bus master (bit2) - same as
    ; the RTL8139 path, this chip is also reached over its I/O BAR0.
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_CMD
    call pci_read32
    or eax, 0x0005
    mov r10d, eax
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_CMD
    call pci_write32

    ; BAR0 must be an I/O bar
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_BAR0
    call pci_read32
    test eax, 1
    jz .ndone
    and eax, 0xFFFFFFFC
    mov [nic_io_base], eax

    ; --- REWRITE: do a real, standard RTL8168-style bring-up instead of
    ; the earlier "skip reset, hope the board firmware already configured
    ; it" workaround. That workaround was based on the theory that this
    ; 8168E+ chip needs vendor microcode this driver can't upload, so
    ; touching config registers would only break whatever good state
    ; existed. In practice it got RX/DHCP working but TX never got out of
    ; a confirmed, repeatable PCI Signaled Target-Abort on every send -
    ; i.e. TX was never actually in a known-good state to begin with, so
    ; there was nothing worth preserving on that side. A proper reset +
    ; full descriptor/TCR/RCR/CPCMD programming (the same sequence real
    ; r8169-family drivers do) is more likely to leave the TX DMA engine
    ; in a state this driver's simple descriptor ring can actually drive,
    ; even without the full microcode upload.
    ;
    ; unlock config registers (9346CR) before touching CMD/TCR/etc.
    mov edi, [nic_io_base]
    add edi, RTL_IO_9346CR
    mov al, RTL_9346_UNLOCK
    call nic_io_write8

    ; soft reset: CMD.RST (bit4). The chip clears this bit itself once
    ; the reset completes; poll with a bounded timeout rather than trust
    ; a fixed delay - real hardware resets can take a variable amount of
    ; time. MAC address (IDR0-5) survives this reset (EEPROM-backed).
    mov edi, [nic_io_base]
    add edi, RTL_IO_CMD
    mov al, RTL_CMD_RST
    call nic_io_write8
    mov r9d, 0x100000            ; generous bounded spin, real reset is fast
.rtl_reset_wait:
    mov edi, [nic_io_base]
    add edi, RTL_IO_CMD
    call nic_io_read8
    test al, RTL_CMD_RST
    jz .rtl_reset_done
    dec r9d
    jnz .rtl_reset_wait
.rtl_reset_done:

    ; read the MAC from IDR0..IDR5 (EEPROM-backed, survives soft reset)
    mov edi, [nic_io_base]
    add edi, RTL_IO_IDR0
    lea rsi, [nic_mac]
    mov rcx, 6
    call nic_io_read_block
    mov edi, [nic_io_base]
    add edi, RTL_IO_TCR
    call nic_io_read32
    mov [nic_hwver_raw], eax

    ; Kick the PHY: on some real boards it comes up in (or gets left in,
    ; by firmware) a powered-down/not-negotiating state that the MAC-side
    ; soft reset above never touches, since RST only resets the MAC, not
    ; the PHY. Without this, RTL_IO_PHYSTATUS's link bit can simply never
    ; assert - .rtl_link_wait below then always burns its whole ~5s budget
    ; and falls through with no link, which is silent (nic_present still
    ; gets set) but means every frame this driver sends from here on is
    ; just dropped, and every "tcp"/ping/dhcp call ends up hanging until
    ; its own retry budget in turn expires. Do this now, before the link
    ; wait, so autonegotiation has the whole ring-setup sequence below to
    ; run concurrently with it instead of starting cold right before we
    ; start polling.
    call rtl_phy_power_up_and_renegotiate

    ; interrupts off (polled driver), clear any latched status
    mov edi, [nic_io_base]
    add edi, RTL_IO_IMR
    xor ax, ax
    call nic_io_write16
    mov edi, [nic_io_base]
    add edi, RTL_IO_ISR
    mov ax, 0xFFFF
    call nic_io_write16

    ; TxConfig: interframe gap = normal (bits 25:24 = 3), max DMA burst
    ; = unlimited (bits 10:8 = 7). 0x03000700 is the standard generic
    ; value used across the RTL8139C+/8169/8168 family - this is the
    ; register the earlier workaround specifically avoided touching, and
    ; is the most likely reason TX DMA was never actually functional.
    mov edi, [nic_io_base]
    add edi, RTL_IO_TCR
    mov eax, 0x03000700
    call nic_io_write32

    ; RxConfig: accept broadcast/multicast/matching-unicast/all-phys,
    ; RX FIFO threshold = none (whole packet), max DMA burst = unlimited.
    mov edi, [nic_io_base]
    add edi, RTL_IO_RCR
    mov eax, 0x0000E70F
    call nic_io_write32

    ; RxMaxSize (0xDA): hardware length filter applied to every incoming
    ; frame before it reaches the descriptor ring. Just above MTU-1500
    ; (1518 + slack) and within RTL_RX_BUF_SIZE (2048).
    mov edi, [nic_io_base]
    add edi, RTL_IO_RMS
    mov ax, 0x0640
    call nic_io_write16

    ; MaxTxPacketSize (0xEC, 128-byte units). 0x3B * 128 = 7552 bytes,
    ; comfortably above anything this driver sends.
    mov edi, [nic_io_base]
    add edi, RTL_IO_MTPS
    mov al, 0x3B
    call nic_io_write8

    ; CPlusCmd: now that we've done a real reset, there's no vendor state
    ; left to preserve here - explicitly zero it (no VLAN de-tagging, no
    ; RX checksum offload, no PCI DAC) for the plainest, most predictable
    ; descriptor-mode behavior while we're establishing that TX works at
    ; all. Offload features can be layered back on once basic TX/RX is
    ; confirmed solid.
    mov edi, [nic_io_base]
    add edi, RTL_IO_CPCMD
    xor ax, ax
    call nic_io_write16

    ; RX ring: RTL_RX_DESC_COUNT descriptors {command dword, vlan dword
    ; (unused), buf_lo dword, buf_hi dword}, each pointing at its own
    ; 2KB buffer in rtl_rx_bufs (identity-mapped physical address).
    xor r9d, r9d
.rtl_rxd_loop:
    cmp r9d, RTL_RX_DESC_COUNT
    jae .rtl_rxd_done
    mov eax, r9d
    shl eax, 4
    lea rdi, [rtl_rx_desc + rax]
    mov eax, RTL_DESC_OWN
    or eax, RTL_RX_BUF_SIZE
    cmp r9d, RTL_RX_DESC_COUNT - 1
    jne .rtl_rxd_noeor
    or eax, RTL_DESC_EOR
.rtl_rxd_noeor:
    mov [rdi], eax
    mov dword [rdi+4], 0
    mov eax, r9d
    imul eax, RTL_RX_BUF_SIZE
    lea rsi, [rtl_rx_bufs + rax]
    mov [rdi+8], esi
    mov dword [rdi+12], 0
    inc r9d
    jmp .rtl_rxd_loop
.rtl_rxd_done:
    mov edi, [nic_io_base]
    add edi, RTL_IO_RDSAR_LO
    lea eax, [rtl_rx_desc]
    call nic_io_write32
    mov edi, [nic_io_base]
    add edi, RTL_IO_RDSAR_HI
    xor eax, eax
    call nic_io_write32

    ; TX ring: every descriptor points at the same nic_tx_buf, same
    ; single-frame-in-flight contract nic_send_raw_rtl8168 keeps.
    ; High-priority ring left zeroed/unused.
    xor r9d, r9d
.rtl_txd_loop:
    cmp r9d, RTL_TX_DESC_COUNT
    jae .rtl_txd_done
    mov eax, r9d
    shl eax, 4
    lea rdi, [rtl_tx_desc + rax]
    mov dword [rdi], 0
    mov dword [rdi+4], 0
    lea rsi, [nic_tx_buf]
    mov [rdi+8], esi
    mov dword [rdi+12], 0
    inc r9d
    jmp .rtl_txd_loop
.rtl_txd_done:
    mov edi, [nic_io_base]
    add edi, RTL_IO_TNPDS_LO
    lea eax, [rtl_tx_desc]
    call nic_io_write32
    mov edi, [nic_io_base]
    add edi, RTL_IO_TNPDS_HI
    xor eax, eax
    call nic_io_write32
    mov edi, [nic_io_base]
    add edi, RTL_IO_THPDS_LO
    xor eax, eax
    call nic_io_write32
    mov edi, [nic_io_base]
    add edi, RTL_IO_THPDS_HI
    xor eax, eax
    call nic_io_write32

    ; enable Rx+Tx, then lock config registers back down
    mov edi, [nic_io_base]
    add edi, RTL_IO_CMD
    mov al, RTL_CMD_RE | RTL_CMD_TE
    call nic_io_write8
    mov edi, [nic_io_base]
    add edi, RTL_IO_9346CR
    mov al, RTL_9346_LOCK
    call nic_io_write8

    ; wait for the copper link to actually come up before handing the NIC
    ; to the rest of the stack. QEMU's virtual link is always already "up",
    ; which is why this was never needed there - real Gigabit autonegotiation
    ; plus switch-port bring-up (STP listening/learning, etc.) commonly takes
    ; several seconds, and frames sent before the link is up are just dropped.
    ; ~5s budget (500 * ~10ms); if it times out we still proceed - nic_present
    ; is still set below so a late link-up will work once dhcp/ping retry.
    mov r9d, 500
.rtl_link_wait:
    mov edi, [nic_io_base]
    add edi, RTL_IO_PHYSTATUS
    call nic_io_read8
    test al, RTL_PHYSTATUS_LINK
    jnz .rtl_link_up
    mov r10, 0x80000              ; ~10ms busy-wait
.rtl_link_delay:
    dec r10
    jnz .rtl_link_delay
    dec r9d
    jnz .rtl_link_wait
.rtl_link_up:

    ; software state
    mov dword [rtl_rx_idx], 0
    mov dword [rtl_tx_idx], 0
    mov byte [nic_arp_tried], 0
    mov byte [nic_dns_retry], 0
    mov word [nic_dns_id], 1
    mov word [nic_echo_id], 0x1234
    mov word [nic_echo_seq], 1
    mov byte [nic_echo_got], 0
    mov byte [nic_echo_retry], 0
    mov word [nic_ip_id], 0x4200

    mov byte [nic_driver_type], 2
    mov byte [nic_present], 1
    clc
.ndone:
    pop rsi
    pop rdi
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; nic_shutdown -- Bring the active NIC down (stop TX/RX, soft reset).
;              Called by "net off" and "net reset". After calling
;              this, nic_present is 0 and nic_driver_type is 0 so
;              every network command will just print "no NIC".
; ============================================================
nic_shutdown:
    push rdi
    push rax
    push rcx
    push r9
    cmp byte [nic_present], 0
    je .ns_out

    cmp byte [nic_driver_type], 0
    je .ns_rtl8139
    cmp byte [nic_driver_type], 1
    je .ns_e1000
    cmp byte [nic_driver_type], 2
    je .ns_rtl8168
    jmp .ns_clear

.ns_rtl8139:
    ; Stop TX and RX engines (write 0 to CMD)
    mov edi, [nic_io_base]
    add edi, NIC_IO_CMD
    xor al, al
    call nic_io_write8
    ; Soft reset
    mov edi, [nic_io_base]
    add edi, NIC_IO_CMD
    mov al, 0x10
    call nic_io_write8
    mov r9d, 0x200000
.ns_r8139_wait:
    mov edi, [nic_io_base]
    add edi, NIC_IO_CMD
    call nic_io_read8
    test al, 0x10
    jz .ns_clear
    dec r9d
    jnz .ns_r8139_wait
    jmp .ns_clear

.ns_e1000:
    ; Disable RX/TX control, then device reset
    mov edi, E1000_CTRL
    xor eax, eax
    call e1000_reg_write32
    ; Device reset
    mov edi, E1000_CTRL
    mov eax, E1000_CTRL_RST
    call e1000_reg_write32
    mov r9d, 0x100000
.ns_e1k_wait:
    mov edi, E1000_CTRL
    call e1000_reg_read32
    test eax, E1000_CTRL_RST
    jz .ns_clear
    dec r9d
    jnz .ns_e1k_wait
    jmp .ns_clear

.ns_rtl8168:
    ; Unlock config registers first
    mov edi, [nic_io_base]
    add edi, RTL_IO_9346CR
    mov al, RTL_9346_UNLOCK
    call nic_io_write8
    ; Stop TX/RX
    mov edi, [nic_io_base]
    add edi, RTL_IO_CMD
    xor al, al
    call nic_io_write8
    ; Soft reset
    mov edi, [nic_io_base]
    add edi, RTL_IO_CMD
    mov al, RTL_CMD_RST
    call nic_io_write8
    mov r9d, 0x100000
.ns_r8168_wait:
    mov edi, [nic_io_base]
    add edi, RTL_IO_CMD
    call nic_io_read8
    test al, RTL_CMD_RST
    jz .ns_clear
    dec r9d
    jnz .ns_r8168_wait

.ns_clear:
    mov byte [nic_present], 0
    mov byte [nic_driver_type], 0
.ns_out:
    pop r9
    pop rcx
    pop rax
    pop rdi
    ret

; mdio_write_rtl: dl = PHY register address (0-31), eax = 16-bit value to
; write (low 16 bits used). Uses PHYAR (offset 0x60): bit31=1 triggers a
; write, register addr in bits 20:16, data in bits 15:0. Hardware clears
; bit31 when the write completes; we poll for that with a bounded budget.
mdio_write_rtl:
    push rax
    push rcx
    push rdx
    push rdi
    push r9

    movzx ecx, dl
    and ecx, 0x1F
    shl ecx, 16
    and eax, 0xFFFF
    or ecx, eax
    or ecx, 0x80000000
    mov edi, [nic_io_base]
    add edi, RTL_IO_PHYAR
    mov eax, ecx
    call nic_io_write32

    mov r9, 2000
.mwr_wait:
    mov edi, [nic_io_base]
    add edi, RTL_IO_PHYAR
    call nic_io_read32
    test eax, 0x80000000
    jz .mwr_done
    dec r9
    jnz .mwr_wait
.mwr_done:
    pop r9
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; rtl_phy_power_up_and_renegotiate: mirrors the real-hardware PHY bring-up
; sequence used by Realtek's own driver source (register page select via
; 0x1F, clear the power-down bit at 0x0E, then force BMCR reset + enable +
; restart-autonegotiation at register 0x00). Purely additive - if the PHY
; was already fine this just makes it renegotiate again, which is harmless.
rtl_phy_power_up_and_renegotiate:
    push rax
    push rdx

    mov dl, 0x1F
    xor eax, eax
    call mdio_write_rtl        ; select PHY register page 0

    mov dl, 0x0E
    xor eax, eax
    call mdio_write_rtl        ; clear power-down bit (page-specific reg)

    mov dl, 0x00                ; BMCR
    mov eax, 0x9200              ; RESET | ANENABLE | ANRESTART
    call mdio_write_rtl

    pop rdx
    pop rax
    ret

; nic_send_raw: rcx = byte length of the frame already built in nic_tx_buf.
; Loads TSAD0 with the buffer address, writes the length to TSD0 to trigger
; the DMA+transmit, then waits for TxStatOk (bit15) in TSD0. Returns CF=0 on
; success. Callers always wait for completion, so no in-flight TX precedes us.
;
; Pad undersized frames up to the Ethernet minimum (60 bytes, before the
; 4-byte FCS the NIC appends) before handing off to any backend. QEMU's
; device models are lenient about short frames, but real hardware is not
; guaranteed to be - this is exactly what was going on with the RTL8168
; "TX error" on ARP broadcasts (42 bytes): no PCI bus error, no stuck NPQ,
; the frame eventually completes, just unreliably/late relative to our
; completion-wait budget. DHCP frames never showed this because they're
; already well over 60 bytes. Doing this once, here, covers every backend
; (rtl8139/e1000/rtl8168) instead of patching each short-frame caller.
nic_send_raw:
    cmp ecx, 60
    jae .nsr_no_pad
    push rax
    push rcx
    push rdx
    push rdi
    mov edx, ecx                 ; edx = original frame length (pad start offset)
    mov eax, 60
    sub eax, edx                 ; eax = number of zero pad bytes needed
    lea rdi, [nic_tx_buf + rdx]
    mov ecx, eax
    xor al, al
    rep stosb
    pop rdi
    pop rdx
    pop rcx
    pop rax
    mov ecx, 60                  ; frame length is now the Ethernet minimum
.nsr_no_pad:
    cmp byte [nic_driver_type], 1
    je nic_send_raw_e1000
    cmp byte [nic_driver_type], 2
    je nic_send_raw_rtl8168
    push rax
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    ; Round-robin the 4 C-mode TX descriptors: QEMU's rtl8139 model only
    ; transmits the descriptor at its internal currTxDesc (which advances
    ; after every successful TX), so the driver must keep writing the
    ; descriptor the chip currently expects. nic_tx_desc tracks that.
    ; NOTE: desc*4 lives in r8 because nic_io_write32/read32 clobber dx.
    movzx r8d, byte [nic_tx_desc]
    shl r8d, 2
    mov edi, [nic_io_base]
    add edi, r8d
    add edi, NIC_IO_TSAD0
    lea eax, [nic_tx_buf]
    call nic_io_write32
    mov edi, [nic_io_base]
    add edi, r8d
    add edi, NIC_IO_TSD0
    mov eax, ecx
    and eax, 0xFFFF
    call nic_io_write32
    mov r9, 0x200000
.tsr_wait_done:
    mov edi, [nic_io_base]
    add edi, r8d
    add edi, NIC_IO_TSD0
    call nic_io_read32
    test eax, 0x2000                ; TOK (Transmit OK, bit 13)
    jnz .tsr_ok
    dec r9
    jnz .tsr_wait_done
    jmp .tsr_err
.tsr_ok:
    movzx eax, byte [nic_tx_desc]
    inc eax
    and eax, 3
    mov [nic_tx_desc], al
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.tsr_err:
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; nic_send_raw_e1000: same contract as nic_send_raw (rcx = frame length
; already built in nic_tx_buf, CF=0 on success). Every TX descriptor in the
; ring already points at nic_tx_buf (see nic_init's e1000 bring-up), so we
; only need to fill in length/cmd, kick TDT, and wait for the chip to set
; Descriptor Done on the slot we just queued.
nic_send_raw_e1000:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10

    mov r8d, [e1000_tx_idx]
    mov eax, r8d
    shl eax, 4
    lea r10, [e1000_tx_desc + rax]   ; kept across the TDT write below

    mov ax, cx
    mov [r10+8], ax                  ; length
    mov byte [r10+10], 0             ; cso
    mov byte [r10+11], E1000_TXD_CMD_EOP_IFCS_RS
    mov byte [r10+12], 0             ; status: clear DD before kicking the ring

    mov eax, r8d
    inc eax
    cmp eax, E1000_TX_DESC_COUNT
    jb .e1ks_no_wrap
    xor eax, eax
.e1ks_no_wrap:
    mov [e1000_tx_idx], eax

    mov edi, E1000_TDT
    call e1000_reg_write32           ; eax still holds the new tail index

    mov r9, 0x1000000
.e1ks_wait:
    movzx eax, byte [r10+12]
    test al, E1000_DD
    jnz .e1ks_ok
    dec r9
    jnz .e1ks_wait
    jmp .e1ks_err
.e1ks_ok:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.e1ks_err:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; nic_send_raw_rtl8168: same contract as nic_send_raw (rcx = frame length
; already built in nic_tx_buf, CF=0 on success). Every TX descriptor in the
; ring already points at nic_tx_buf, so we only need to fill in the
; command dword (OWN|FS|LS|len, +EOR on the last slot), kick TPPoll, and
; wait for the chip to clear OWN on the slot we just queued.
nic_send_raw_rtl8168:
    push rax
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    push r11

    mov r8d, [rtl_tx_idx]
    mov eax, r8d
    shl eax, 4
    lea r10, [rtl_tx_desc + rax]     ; kept across the TPPoll write below

    mov eax, RTL_DESC_OWN | RTL_DESC_FS | RTL_DESC_LS
    mov edx, ecx
    and edx, 0xFFFF
    or eax, edx
    cmp r8d, RTL_TX_DESC_COUNT - 1
    jne .rtks_noeor
    or eax, RTL_DESC_EOR
.rtks_noeor:
    mov [r10], eax                   ; command dword: hand this slot to the NIC

    mov eax, r8d
    inc eax
    cmp eax, RTL_TX_DESC_COUNT
    jb .rtks_no_wrap
    xor eax, eax
.rtks_no_wrap:
    mov [rtl_tx_idx], eax

    mov edi, [nic_io_base]
    add edi, RTL_IO_TPPOLL
    mov al, RTL_TPPOLL_NPQ
    call nic_io_write8

    ; Wait for the chip to clear OWN on this slot. QEMU clears it almost
    ; immediately, so a raw loop count worked there; on real hardware the
    ; first TX DMA after link bring-up can take far longer than a cached-
    ; RAM spin allows (the loop reads the descriptor from the CPU cache,
    ; which outruns the NIC's write-back by orders of magnitude). So wait
    ; on wall-clock RTC seconds instead: up to ~2s, re-kicking TPPoll each
    ; second in case the chip needed another poll to notice the slot.
    ; NOTE: budget is in whole-second ticks, but the tick boundary itself
    ; consumes no polling time - see the js/jz fix below. With r11d=N we
    ; get the remainder of the current second plus N full subsequent
    ; seconds of continuous OWN polling before giving up. Bumped from 2 to
    ; 5: field reports on real hardware still showed OWN clearing (and
    ; NPQ already down) moments after a "failure" even with the earlier
    ; 2-3s budget, especially around ring wraparound (EOR slot) - so the
    ; occasional real-world completion is simply slower than that.
    call rtc_sec_now
    mov r9d, eax
    mov [nic_tx_wait_start], al   ; true start second, kept separate from r9d
                                  ; (which gets overwritten every tick below) -
                                  ; so netdiag_dump_tx can report real elapsed
                                  ; wall-clock time on failure, not just a tick
                                  ; count that's always the same constant.
    ; Bumped 5 -> 20: with rtc_sec_now's BCD bug fixed we can finally trust
    ; the elapsed-time diagnostic, but the last two runs still failed with
    ; an identical signature (no PCI error, NPQ/OWN both eventually clear)
    ; even after padding ruled out short-frame handling as the cause. That
    ; points at this chip/link genuinely needing longer than 5-6s for its
    ; first TX after an idle gap (e.g. PHY/EEE low-power wake, or link
    ; re-training) rather than a logic bug in the wait itself. Widening
    ; the budget is a cheap way to confirm that: if this send now
    ; succeeds, the real elapsed-seconds print (now trustworthy) tells us
    ; how much headroom this hardware actually needs so the budget can be
    ; set correctly instead of guessed at again.
    mov r11d, 20                 ; ~20-21s budget
    mov byte [nic_tx_wait_ticks], 0
.rtks_wait:
    ; Force-flush any posted DMA write the NIC has queued upstream before
    ; trusting the in-RAM copy of the descriptor. Two separate runs of this
    ; exact failure now show the identical, deterministic pattern: OWN and
    ; the length field both read back cleared, TOK never observed set
    ; during the whole polling window, and yet no PCI abort/parity fault -
    ; and critically, the descriptor only ever shows the "completed" state
    ; *after* netdiag_dump_tx's own PCI config-space read runs, never while
    ; this loop is plain-RAM-polling. PCI/PCIe ordering only guarantees a
    ; posted write has landed once a read that traverses the same path
    ; completes ("reads push writes") - a legacy CF8/CFC config cycle is a
    ; much stronger/slower completion barrier on real chipsets than an I/O
    ; BAR register read, and is exactly what netdiag_dump_tx was doing
    ; right before the "already done" readback. So issue that same kind of
    ; read ourselves, every iteration, instead of only reading raw system
    ; RAM and hoping the write has already arrived.
    movzx ebx, byte [nic_pci_bus]
    movzx ecx, byte [nic_pci_dev]
    movzx edx, byte [nic_pci_func]
    mov r8b, NIC_PCI_CMD
    call pci_read32
    mov eax, [r10]
    test eax, RTL_DESC_OWN
    jz .rtks_ok
    ; Cross-check against ISR TOK (bit2, Transmit OK) as a second, independent
    ; completion signal. Field diagnostics (netdiag_dump_tx) have shown this
    ; chip family occasionally leaving the polled descriptor's OWN bit (and
    ; even its length field) in a state this driver's simple C+-descriptor
    ; model doesn't expect, while the PCI bus itself reports no abort/parity
    ; fault at all - i.e. the frame most likely did go out, but the
    ; descriptor-bit poll alone can't always see it. TOK is the standard,
    ; documented r8169 completion indicator and is independent of that
    ; descriptor race, so treat it as an equally valid "sent" signal.
    mov edi, [nic_io_base]
    add edi, RTL_IO_ISR
    call nic_io_read16
    test eax, 0x0004
    jz .rtks_no_tok
    ; write-1-to-clear just the TOK bit so a stale flag can't falsely
    ; short-circuit the next send's wait loop
    mov edi, [nic_io_base]
    add edi, RTL_IO_ISR
    mov ax, 0x0004
    call nic_io_write16
    jmp .rtks_ok
.rtks_no_tok:
    call rtc_sec_now
    cmp eax, r9d
    jne .rtks_tick
    jmp .rtks_wait
.rtks_tick:
    mov r9d, eax
    inc byte [nic_tx_wait_ticks]
    dec r11d
    ; BUGFIX: this used to be `jz .rtks_err`, which bails the instant the
    ; clock ticks into the budget's last second - without ever actually
    ; polling OWN during that second. On real hardware the chip can clear
    ; OWN right around that boundary (confirmed by netdiag_dump_tx showing
    ; OWN already clear moments after a reported failure), so the old code
    ; was declaring failure on transfers that were, in fact, completing.
    ; `js` lets r11d reach 0 and still poll through one more full second
    ; before truly giving up.
    js .rtks_err
    ; re-kick the normal-priority queue: harmless if already acknowledged
    mov edi, [nic_io_base]
    add edi, RTL_IO_TPPOLL
    mov al, RTL_TPPOLL_NPQ
    call nic_io_write8
    jmp .rtks_wait
.rtks_ok:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.rtks_err:
    call rtc_sec_now
    mov [nic_tx_wait_end], al
    sub al, [nic_tx_wait_start]
    jns .rtks_err_nowrap
    add al, 60                   ; CMOS seconds wrapped past 59 mid-wait
.rtks_err_nowrap:
    mov [nic_tx_wait_elapsed], al
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; ---- RX ----------------------------------------------------------
; nic_write_capr: write CAPR = (nic_capr - 16) mod ring. The RTL8139's CAPR
; trails the true read position by 16 bytes (QEMU adds 0x10 on every write),
; so the driver must program it 16 less than the next-packet offset.
nic_write_capr:
    push rax
    push rdi
    mov eax, [nic_capr]
    sub eax, 16
    and eax, NIC_RX_RING_MASK
    mov edi, [nic_io_base]
    add edi, NIC_IO_CAPR
    call nic_io_write16
    pop rdi
    pop rax
    ret

; nic_fetch_rx: if a packet is ready at the software CAPR, copies the actual
; ethernet frame (raw descriptor length minus the 4-byte CRC) from the ring
; into nic_rx_frame, handling wrap-around, advances/writes CAPR, and returns
; al=1. Returns al=0 when the ring is drained. nic_rx_len = frame bytes.
nic_fetch_rx:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    cmp byte [nic_present], 0
    je .frx_none
    cmp byte [nic_driver_type], 1
    je .frx_e1000
    cmp byte [nic_driver_type], 2
    je .frx_rtl8168
    mov eax, [nic_capr]
    and eax, NIC_RX_RING_MASK
    mov r8d, eax                  ; descriptor offset (for clearing ROK below)
    lea rsi, [nic_rx_ring + rax]
    mov ax, [rsi]
    test ax, 0x0001               ; ROK set? (QEMU always sets it; empty = 0)
    jz .frx_none
    movzx ecx, word [rsi+2]
    and ecx, 0x3FFF
    mov r9d, ecx                  ; raw length incl. the 4-byte CRC
    sub ecx, 4
    jbe .frx_skip                 ; raw length <= 4: error descriptor
    mov [nic_rx_len], ecx
    lea rbx, [nic_rx_ring]
    mov eax, [nic_capr]
    and eax, NIC_RX_RING_MASK
    add eax, 4
    mov edx, eax
    lea rdi, [nic_rx_frame]
.frx_copy:
    mov esi, edx
    and esi, NIC_RX_RING_MASK
    mov al, [rbx+rsi]
    mov [rdi], al
    inc edx
    inc rdi
    dec rcx
    jnz .frx_copy
.frx_adv:
    mov eax, [nic_capr]
    mov ecx, r9d
    add ecx, 3
    and ecx, 0xFFFFFFFC
    add eax, 4
    add eax, ecx
    and eax, NIC_RX_RING_MASK
    mov [nic_capr], eax
    call nic_write_capr
    ; clear ROK on the descriptor we just consumed. QEMU never resets the
    ; OWN bit on CAPR write, so without this a wrapped ring re-delivers the
    ; same frames forever once inbound traffic stops.
    lea rdi, [nic_rx_ring + r8]
    mov word [rdi], 0
    mov al, 1
    jmp .frx_out
.frx_skip:
    mov eax, [nic_capr]
    add eax, 4
    and eax, NIC_RX_RING_MASK
    mov [nic_capr], eax
    call nic_write_capr
    lea rdi, [nic_rx_ring + r8]
    mov word [rdi], 0
    jmp .frx_none

; e1000 RX path: descriptor-ring equivalent of the ring-buffer walk above.
; e1000_rx_idx is the software head - the next descriptor we expect the
; chip to have finished (status.DD set). RCTL's SECRC bit already strips
; the trailing 4-byte CRC, so the descriptor's length is the frame length.
.frx_e1000:
    mov eax, [e1000_rx_idx]
    mov ecx, eax
    shl ecx, 4
    lea rsi, [e1000_rx_desc + rcx]
    movzx edx, byte [rsi+12]         ; status byte
    test dl, E1000_DD
    jz .frx_none
    movzx ecx, word [rsi+8]          ; frame length
    cmp ecx, 1514
    ja .e1frx_skip
    cmp ecx, 0
    je .e1frx_skip
    mov [nic_rx_len], ecx
    mov rbx, [rsi]                   ; this descriptor's buffer_addr
    lea rdi, [nic_rx_frame]
.e1frx_copy:
    mov al, [rbx]
    mov [rdi], al
    inc rbx
    inc rdi
    dec rcx
    jnz .e1frx_copy
    mov byte [rsi+12], 0             ; clear DD: descriptor free for reuse
    mov edi, E1000_RDT
    mov eax, [e1000_rx_idx]
    call e1000_reg_write32           ; tell the chip this slot is available again
    mov eax, [e1000_rx_idx]
    inc eax
    cmp eax, E1000_RX_DESC_COUNT
    jb .e1frx_nowrap
    xor eax, eax
.e1frx_nowrap:
    mov [e1000_rx_idx], eax
    mov al, 1
    jmp .frx_out
.e1frx_skip:
    mov byte [rsi+12], 0
    mov edi, E1000_RDT
    mov eax, [e1000_rx_idx]
    call e1000_reg_write32
    mov eax, [e1000_rx_idx]
    inc eax
    cmp eax, E1000_RX_DESC_COUNT
    jb .e1frx_skip_nowrap
    xor eax, eax
.e1frx_skip_nowrap:
    mov [e1000_rx_idx], eax
    jmp .frx_none
; RTL8168 RX path: descriptor-ring walk, same shape as the e1000 branch
; above but over the RTL8169-style descriptor (command dword, vlan dword
; [unused], buf_lo, buf_hi=0). rtl_rx_idx is the software head - the next
; descriptor we expect the chip to have cleared OWN on. The low 14 bits
; of the command dword give the frame length *including* the trailing
; 4-byte CRC (this chip doesn't strip it for us), so we subtract 4 the
; same way the RTL8139 path above does.
.frx_rtl8168:
    mov r9d, [rtl_rx_idx]
    mov eax, r9d
    shl eax, 4
    lea rsi, [rtl_rx_desc + rax]
    mov eax, [rsi]
    test eax, RTL_DESC_OWN
    jnz .frx_none                    ; still owned by the NIC: nothing ready

    movzx ecx, ax
    and ecx, 0x3FFF
    sub ecx, 4                       ; drop the trailing CRC
    jbe .rtlfrx_skip                 ; runt/error descriptor: drop and requeue

    mov [nic_rx_len], ecx
    mov ebx, [rsi+8]                 ; buffer physical addr (identity-mapped)
    lea rdi, [nic_rx_frame]
.rtlfrx_copy:
    mov al, [rbx]
    mov [rdi], al
    inc rbx
    inc rdi
    dec rcx
    jnz .rtlfrx_copy

    mov eax, RTL_DESC_OWN | RTL_RX_BUF_SIZE
    cmp r9d, RTL_RX_DESC_COUNT - 1
    jne .rtlfrx_noeor1
    or eax, RTL_DESC_EOR
.rtlfrx_noeor1:
    mov [rsi], eax                   ; hand the descriptor back to the NIC

    mov eax, r9d
    inc eax
    cmp eax, RTL_RX_DESC_COUNT
    jb .rtlfrx_nowrap1
    xor eax, eax
.rtlfrx_nowrap1:
    mov [rtl_rx_idx], eax
    mov al, 1
    jmp .frx_out

.rtlfrx_skip:
    mov eax, RTL_DESC_OWN | RTL_RX_BUF_SIZE
    cmp r9d, RTL_RX_DESC_COUNT - 1
    jne .rtlfrx_noeor2
    or eax, RTL_DESC_EOR
.rtlfrx_noeor2:
    mov [rsi], eax

    mov eax, r9d
    inc eax
    cmp eax, RTL_RX_DESC_COUNT
    jb .rtlfrx_nowrap2
    xor eax, eax
.rtlfrx_nowrap2:
    mov [rtl_rx_idx], eax
    jmp .frx_none

.frx_none:
    xor al, al
.frx_out:
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; netpoll: drain the RX ring and dispatch each frame. Preserves everything.
netpoll:
    push rax
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
    cmp byte [nic_present], 0
    je .np_done
.np_loop:
    call nic_fetch_rx
    cmp al, 1
    jne .np_done
    inc dword [nic_rx_seen]
    cmp byte [nic_diag_verbose], 0
    je .np_nodiag
    cmp byte [nic_diag_rx_count], 12
    jae .np_nodiag
    inc byte [nic_diag_rx_count]
    call netdiag_dump_frame
.np_nodiag:
    mov ax, [nic_rx_frame+12]
    cmp ax, ETH_TYPE_ARP_W
    je .np_arp
    cmp ax, ETH_TYPE_IP_W
    je .np_ip
    jmp .np_loop
.np_arp:
    call handle_arp
    jmp .np_loop
.np_ip:
    call handle_ipv4
    jmp .np_loop
.np_done:
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
    pop rax
    ret

; ---- ARP ---------------------------------------------------------
; handle_arp: ARP request for our IP -> send a reply. ARP reply -> learn
; the sender into the cache.
handle_arp:
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
    lea rsi, [nic_rx_frame + 14]
    mov ax, [rsi+6]
    cmp ax, 0x0100
    je .arp_req
    cmp ax, 0x0200
    je .arp_rep
    jmp .arp_done
.arp_req:
    ; only answer if tpa (payload+24) == our IP
    mov eax, [rsi+24]
    cmp eax, [nic_ip]
    jne .arp_done
    ; build reply directly in nic_tx_buf
    lea rdi, [nic_tx_buf]
    lea rsi, [nic_rx_frame + 14 + 8]   ; requester MAC
    mov rcx, 6
    rep movsb
    lea rsi, [nic_mac]
    mov rcx, 6
    rep movsb
    mov byte [rdi], 0x08
    mov byte [rdi+1], 0x06
    add rdi, 2
    mov byte [rdi], 0x00
    mov byte [rdi+1], 0x01
    mov byte [rdi+2], 0x08
    mov byte [rdi+3], 0x00
    mov byte [rdi+4], 6
    mov byte [rdi+5], 4
    mov byte [rdi+6], 0x00
    mov byte [rdi+7], 0x02
    lea rsi, [nic_mac]
    mov rcx, 6
    push rdi
    add rdi, 8
    rep movsb
    pop rdi
    mov eax, [nic_ip]
    mov [rdi+14], eax
    lea rsi, [nic_rx_frame + 14 + 8]
    mov rcx, 6
    push rdi
    add rdi, 18
    rep movsb
    pop rdi
    mov eax, [nic_rx_frame + 14 + 14]
    mov [rdi+24], eax
    mov ecx, 42
    call nic_send_raw
    jmp .arp_done
.arp_rep:
    mov eax, [nic_rx_frame + 14 + 14]
    lea rsi, [nic_rx_frame + 14 + 8]
    call nic_arp_learn
    jmp .arp_done
.arp_done:
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

; nic_arp_request: eax = target IP. Broadcasts an ARP request.
nic_arp_request:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r9
    mov r9d, eax
    lea rdi, [nic_tx_buf]
    mov ecx, 6
    mov al, 0xFF
    rep stosb
    lea rsi, [nic_mac]
    mov rcx, 6
    rep movsb
    mov byte [rdi], 0x08
    mov byte [rdi+1], 0x06
    add rdi, 2
    mov byte [rdi], 0x00
    mov byte [rdi+1], 0x01
    mov byte [rdi+2], 0x08
    mov byte [rdi+3], 0x00
    mov byte [rdi+4], 6
    mov byte [rdi+5], 4
    mov byte [rdi+6], 0x00
    mov byte [rdi+7], 0x01
    lea rsi, [nic_mac]
    mov rcx, 6
    push rdi
    add rdi, 8
    rep movsb
    pop rdi
    mov eax, [nic_ip]
    mov [rdi+14], eax
    mov qword [rdi+18], 0
    mov [rdi+24], r9d
    mov ecx, 42
    cmp byte [nic_diag_verbose], 0
    je .areq_nodump
    push rcx
    mov rsi, msg_diag_tx
    mov al, [cur_normal_attr]
    call print_string_attr
    pop rcx
    push rcx
    lea rsi, [nic_tx_buf]
    call netdiag_dump_tx_frame
    pop rcx
.areq_nodump:
    mov byte [nic_last_tx_ctx], 1
    call nic_send_raw
    pop r9
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; nic_arp_learn: eax = IP, rsi = 6-byte MAC. Insert/replace in the cache.
nic_arp_learn:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    xor r9, r9
.learn_loop:
    cmp r9, NIC_ARP_CACHE_ENTRIES
    jae .learn_new
    imul rbx, r9, 10
    lea rdi, [nic_arp_cache + rbx + 6]
    cmp eax, [rdi]
    je .learn_hit
    inc r9
    jmp .learn_loop
.learn_new:
    movzx r9, byte [nic_arp_next]
    and r9, NIC_ARP_CACHE_ENTRIES-1
    movzx r10, byte [nic_arp_next]
    inc r10
    mov [nic_arp_next], r10b
.learn_hit:
    imul rbx, r9, 10
    lea rdi, [nic_arp_cache + rbx]
    mov rcx, 6
    rep movsb
    mov [rdi], eax
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; nic_arp_lookup: eax = IP -> CF=0 and rdi = MAC ptr if cached, else CF=1.
nic_arp_lookup:
    push rbx
    push rcx
    push r9
    xor r9, r9
.lloop:
    cmp r9, NIC_ARP_CACHE_ENTRIES
    jae .lmiss
    imul rbx, r9, 10
    lea rdi, [nic_arp_cache + rbx + 6]
    cmp eax, [rdi]
    je .lhit
    inc r9
    jmp .lloop
.lhit:
    imul rbx, r9, 10
    lea rdi, [nic_arp_cache + rbx]
    pop r9
    pop rcx
    pop rbx
    clc
    ret
.lmiss:
    pop r9
    pop rcx
    pop rbx
    stc
    ret

; nic_arp_resolve: eax = IP -> CF=0 and rdi = MAC ptr (cached or just
; resolved via broadcast + wait), or CF=1 after retries/timeout. On CF=1,
; nic_last_fail_reason tells the caller which of two very different things
; happened: 0 = the raw broadcast itself never got out (hardware/TX-level
; problem - see nic_send_raw_rtl8168), 1 = the broadcast went out fine but
; no ARP reply ever came back (peer/gateway didn't answer in time). These
; used to be reported identically, which is how a plain "nobody answered"
; timeout ended up being diagnosed as a NIC hardware fault.
nic_arp_resolve:
    push rbx
    push rcx
    push rdx
    push rsi
    push r9
    push r10
    push r12
    push r13
    push r14
    push r15
    mov r12, rax
    xor r15d, r15d           ; ARP-broadcast raw-TX retry counter - separate from
                              ; the reply-wait retry below. This covers the NIC
                              ; itself failing to get the broadcast frame out
                              ; (nic_send_raw_rtl8168 timeout/race), not the peer
                              ; failing to answer it. Previously a single failed
                              ; TX here killed the whole resolve/connect attempt
                              ; instantly, even though the same class of failure
                              ; is known to be a transient completion-detection
                              ; race on this chip (see nic_send_raw_rtl8168).
    xor ebx, ebx              ; ARP-reply resend-round counter (separate axis from
                              ; r15d above: this counts full "resend + wait again"
                              ; rounds after a genuinely-sent broadcast got no
                              ; reply, not raw TX failures).
.ares:
    mov eax, r12d
    call nic_arp_lookup
    jnc .ares_have
.ares_send:
    mov eax, r12d
    call nic_arp_request
    jnc .ares_sent
    cmp r15d, 3
    jae .ares_fail_tx
    inc r15d
    jmp .ares_send
.ares_sent:
    ; Wait for a reply using the same wall-clock-tick pattern as the raw TX
    ; wait: up to ~5-6s of continuous polling per round (budget in whole-
    ; second ticks; the current partial second is "free", same reasoning as
    ; nic_send_raw_rtl8168's js fix - see there for why `js` instead of `jz`).
    ; The old code gave up after at most a single, possibly sub-1-second,
    ; tick - nowhere near enough time for a real ARP reply, especially right
    ; after DHCP when the gateway/switch may not have us in its table yet.
    call rtc_sec_now
    mov r13d, eax
    mov r14d, 5               ; ~5-6s per round
.ares_wait:
    call netpoll
    mov eax, r12d
    call nic_arp_lookup
    jnc .ares_have
    call rtc_sec_now
    cmp eax, r13d
    jne .ares_tick
    jmp .ares_wait
.ares_tick:
    mov r13d, eax
    dec r14d
    js .ares_round_done        ; budget for this round exhausted
    jmp .ares_wait
.ares_round_done:
    ; Up to 3 resend rounds total (~15-18s of real reply-wait time) before
    ; giving up, instead of the old single near-instant attempt.
    cmp ebx, 2
    jae .ares_fail_noreply
    inc ebx
    jmp .ares_send              ; resend the broadcast, then wait again
.ares_have:
    clc
    jmp .ares_out
.ares_fail_tx:
    mov byte [nic_last_fail_reason], 0
    stc
    jmp .ares_out
.ares_fail_noreply:
    mov byte [nic_last_fail_reason], 1
    stc
.ares_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r10
    pop r9
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- IPv4 --------------------------------------------------------
; net_checksum16: rsi = data, ecx = byte count -> ax = one's-complement sum.
net_checksum16:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    xor eax, eax
    mov r8, rcx
    mov rdx, rcx
    shr rdx, 1
.cs_words:
    test rdx, rdx
    jz .cs_odd
    movzx ecx, byte [rsi]
    shl ecx, 8
    movzx ebx, byte [rsi+1]
    or ecx, ebx
    add eax, ecx
    adc eax, 0
    add rsi, 2
    dec rdx
    jmp .cs_words
.cs_odd:
    test r8, 1
    jz .cs_fold
    movzx ecx, byte [rsi]
    shl ecx, 8
    add eax, ecx
    adc eax, 0
.cs_fold:
    mov edx, eax
    shr edx, 16
    test edx, edx
    jz .cs_done
    and eax, 0xFFFF
    add eax, edx
    adc eax, 0
    jmp .cs_fold
.cs_done:
    not eax
    and eax, 0xFFFF
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; net_udp_checksum: rsi = udp datagram ptr, ecx = udp len, r8d = src IP, r9d = dst IP -> ax = checksum
net_udp_checksum:
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
    lea rdi, [net_build_buf + 1536]
    mov eax, r8d
    mov [rdi], eax
    mov eax, r9d
    mov [rdi+4], eax
    mov byte [rdi+8], 0
    mov byte [rdi+9], 0x11
    mov ax, r11w
    rol ax, 8
    mov [rdi+10], ax
    lea rdi, [net_build_buf + 1536 + 12]
    mov rsi, r10
    mov ecx, r11d
    rep movsb
    mov word [net_build_buf + 1536 + 12 + 6], 0
    lea rsi, [net_build_buf + 1536]
    mov ecx, r11d
    add ecx, 12
    call net_checksum16
    cmp ax, 0
    jne .uc_ok
    mov ax, 0xFFFF
.uc_ok:
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

; nic_send_ip: rsi = payload ptr, ecx = payload len, r8d = dst IP,
; r9b = protocol. Routes (same-subnet direct, else via nic_gw), resolves
; the nexthop MAC, builds the eth+ip frame in nic_tx_buf and sends it.
nic_send_ip:
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
    push r14
    push r15
    mov byte [nic_last_fail_reason], 0   ; default to "raw TX" until/unless
                                          ; nic_arp_resolve below says otherwise -
                                          ; prevents a stale reason from a
                                          ; previous, unrelated resolve leaking
                                          ; into this send's failure report
    mov r10, rsi
    mov r11d, ecx
    mov r12d, r8d
    mov r13b, r9b
    mov r14d, r12d
    mov eax, r12d
    cmp eax, 0xFFFFFFFF
    je .sip_broadcast
    and eax, [nic_mask]
    mov edx, [nic_ip]
    and edx, [nic_mask]
    cmp eax, edx
    je .sip_direct
    mov r14d, [nic_gw]
.sip_direct:
    mov eax, r14d
    call nic_arp_resolve
    jc .sip_fail
    mov rsi, rdi
    jmp .sip_have_mac
.sip_broadcast:
    lea rsi, [mac_broadcast]
.sip_have_mac:
    lea rdi, [nic_tx_buf]
    mov rcx, 6
    rep movsb
    lea rsi, [nic_mac]
    mov rcx, 6
    rep movsb
    mov byte [rdi], 0x08
    mov byte [rdi+1], 0x00
    add rdi, 2
    mov r15, rdi
    mov byte [rdi], 0x45
    mov byte [rdi+1], 0x00
    mov eax, r11d
    add eax, 20
    mov byte [rdi+3], al
    shr eax, 8
    mov byte [rdi+2], al
    mov ax, [nic_ip_id]
    mov byte [rdi+4], ah
    mov byte [rdi+5], al
    inc word [nic_ip_id]
    mov word [rdi+6], 0x0000
    mov byte [rdi+8], 64
    mov byte [rdi+9], r13b
    mov word [rdi+10], 0
    mov eax, [nic_ip]
    mov [rdi+12], eax
    mov [rdi+16], r12d
    add rdi, 20
    mov rsi, r10
    mov rcx, r11
    rep movsb
    mov rsi, r15
    mov ecx, 20
    call net_checksum16
    ror ax, 8
    mov word [r15+10], ax
    mov ecx, r11d
    add ecx, 34
    cmp byte [nic_diag_verbose], 0
    je .sip_nodump
    cmp byte [nic_diag_tx_dumped], 0
    jne .sip_nodump
    mov byte [nic_diag_tx_dumped], 1
    push rcx
    mov rsi, msg_diag_tx
    mov al, [cur_normal_attr]
    call print_string_attr
    pop rcx
    push rcx
    lea rsi, [nic_tx_buf]
    call netdiag_dump_tx_frame
    pop rcx
.sip_nodump:
    mov byte [nic_last_tx_ctx], 0
    call nic_send_raw
    jc .sip_fail
    clc
    jmp .sip_out
.sip_fail:
    stc
.sip_out:
    pop r15
    pop r14
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

; ---- ICMP --------------------------------------------------------
; handle_ipv4: parse the frame in nic_rx_frame. Echo requests get an echo
; reply; echo replies matching nic_echo_id are recorded for bounce/monitor;
; UDP port 53 is handed to dns_handle_reply.
handle_ipv4:
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
    lea rsi, [nic_rx_frame + 14]
    mov al, [rsi]
    shr al, 4
    cmp al, 4
    jne .ip_done
    movzx eax, byte [rsi]
    and al, 0x0F
    imul eax, 4
    mov [nic_ihl], al
    mov al, [rsi+9]
    mov eax, [rsi+16]
    cmp eax, [nic_ip]
    je .ip_ours
    cmp eax, 0xFFFFFFFF
    je .ip_ours
    cmp dword [nic_ip], 0
    je .ip_ours             ; no lease yet: accept unicast DHCP OFFER/ACK too
    jmp .ip_done
.ip_ours:
    mov al, [rsi+9]
    cmp al, IP_PROTO_ICMP
    je .ip_icmp
    cmp al, IP_PROTO_TCP
    je .ip_tcp
    cmp al, IP_PROTO_UDP
    je .ip_udp
    jmp .ip_done
.ip_icmp:
    ; icmp header at rsi + ihl
    movzx eax, byte [nic_ihl]
    add rsi, rax
    mov al, [rsi]
    cmp al, 8
    je .ip_icmp_req
    cmp al, 0
    jne .ip_done
    movzx eax, byte [rsi+4]
    shl eax, 8
    movzx edx, byte [rsi+5]
    or eax, edx
    cmp ax, [nic_echo_id]
    jne .ip_done
    mov byte [nic_echo_got], 1
    movzx eax, byte [rsi+6]
    shl eax, 8
    movzx edx, byte [rsi+7]
    or eax, edx
    mov [nic_echo_seq], ax
    mov eax, [nic_rx_frame + 14 + 12]
    mov [nic_echo_src_ip], eax
    jmp .ip_done
.ip_icmp_req:
    call icmp_send_reply
    jmp .ip_done
.ip_udp:
    movzx eax, byte [nic_ihl]
    add rsi, rax
    ; source port (bytes 0-1) - DNS server legitimately replies from :53
    movzx eax, byte [rsi]
    shl eax, 8
    movzx edx, byte [rsi+1]
    or eax, edx
    cmp ax, 53
    je .ip_udp_dns
    ; destination port (bytes 2-3) - DHCP replies are addressed to our :68
    movzx eax, byte [rsi+2]
    shl eax, 8
    movzx edx, byte [rsi+3]
    or eax, edx
    cmp ax, 68
    je .ip_udp_dhcp
    jmp .ip_done
.ip_udp_dns:
    call dns_handle_reply
    jmp .ip_done
.ip_udp_dhcp:
    call dhcp_handle_packet
    jmp .ip_done
.ip_tcp:
    ; TCP header at rsi + ihl; hand it to the minimal TCP engine.
    movzx eax, byte [nic_ihl]
    add rsi, rax
    call tcp_handle_segment
    jmp .ip_done
.ip_done:
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

; icmp_send_reply: build an echo reply for the request in nic_rx_frame.
icmp_send_reply:
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
    mov eax, [nic_rx_frame + 14 + 12]
    mov r12d, eax
    movzx eax, byte [nic_rx_frame + 14]
    and al, 0x0F
    imul eax, 4
    lea r13, [nic_rx_frame + 14 + rax]
    movzx eax, byte [nic_rx_frame+14+2]
    shl eax, 8
    movzx edx, byte [nic_rx_frame+14+3]
    or eax, edx
    movzx ecx, byte [nic_rx_frame+14]
    and cl, 0x0F
    imul ecx, 4
    sub eax, ecx
    mov r11d, eax
    lea rdi, [nic_tx_buf]
    lea rsi, [nic_rx_frame+6]
    mov rcx, 6
    rep movsb
    lea rsi, [nic_mac]
    mov rcx, 6
    rep movsb
    mov byte [rdi], 0x08
    mov byte [rdi+1], 0x00
    add rdi, 2
    mov byte [rdi], 0x45
    mov byte [rdi+1], 0x00
    mov eax, r11d
    add eax, 20
    mov byte [rdi+3], al
    shr eax, 8
    mov byte [rdi+2], al
    mov ax, [nic_ip_id]
    mov byte [rdi+4], ah
    mov byte [rdi+5], al
    inc word [nic_ip_id]
    mov word [rdi+6], 0
    mov byte [rdi+8], 64
    mov byte [rdi+9], IP_PROTO_ICMP
    mov word [rdi+10], 0
    mov eax, [nic_ip]
    mov [rdi+12], eax
    mov [rdi+16], r12d
    add rdi, 20
    mov byte [rdi], 0
    mov byte [rdi+1], 0
    mov word [rdi+2], 0
    mov ax, [r13+4]
    mov [rdi+4], ax
    mov ax, [r13+6]
    mov [rdi+6], ax
    mov r8, rdi
    add rdi, 8
    lea rsi, [r13+8]
    mov ecx, r11d
    sub ecx, 8
    rep movsb
    mov rsi, r8
    mov ecx, r11d
    call net_checksum16
    ror ax, 8
    mov word [r8+2], ax
    lea rsi, [nic_tx_buf + 14]
    mov ecx, 20
    call net_checksum16
    ror ax, 8
    mov word [nic_tx_buf + 14 + 10], ax
    mov ecx, r11d
    add ecx, 34
    call nic_send_raw
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

; bounce_send: sends an ICMP echo request to nic_bounce_target (dd) with
; id = nic_echo_id and seq = nic_echo_seq, then bumps the seq.
bounce_send:
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
    push r14
    push r15
    mov r12d, [nic_bounce_target]
    lea rdi, [net_build_buf]
    mov byte [rdi], 8
    mov byte [rdi+1], 0
    mov word [rdi+2], 0
    mov ax, [nic_echo_id]
    mov byte [rdi+4], ah
    mov byte [rdi+5], al
    mov ax, [nic_echo_seq]
    mov byte [rdi+6], ah
    mov byte [rdi+7], al
    lea rsi, [icmp_data_pad]
    mov ecx, 32
    add rdi, 8
    rep movsb
    lea rsi, [net_build_buf]
    mov ecx, 40
    call net_checksum16
    mov byte [net_build_buf+2], ah
    mov byte [net_build_buf+3], al
    lea rsi, [net_build_buf]
    mov ecx, 40
    mov r8d, r12d
    mov r9b, IP_PROTO_ICMP
    call nic_send_ip
    jc .bs_fail
    inc word [nic_echo_seq]
    clc
    jmp .bs_out
.bs_fail:
    stc
.bs_out:
    pop r15
    pop r14
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

; ---- UDP / DNS ---------------------------------------------------
; nic_send_udp: rsi = payload, ecx = payload len, r8d = dst IP, r9w = dst
; port, r10w = src port. Builds the UDP datagram in net_build_buf, then
; ships it as an IP payload.
nic_send_udp:
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
    push r14
    push r15
    mov r11, rsi
    mov r12d, ecx
    mov r13d, r8d
    mov r14w, r9w
    mov r15w, r10w
    ; The payload (r11) is often the same net_build_buf we're about to
    ; build the datagram in (callers construct their message there before
    ; calling us), aliased with dst = src+8. If we wrote the 8-byte UDP
    ; header first, it would destroy the payload's own first 8 bytes
    ; before they could ever be copied - no copy direction fixes that.
    ; So: shift the payload into place first (back-to-front, since
    ; dst > src makes that direction overlap-safe), and only write the
    ; header afterward, once bytes 0-7 are no longer needed as payload.
    mov rsi, r11
    add rsi, r12
    dec rsi
    lea rdi, [net_build_buf + 8]
    add rdi, r12
    dec rdi
    mov rcx, r12
    std
    rep movsb
    cld
    lea rdi, [net_build_buf]
    mov ax, r15w
    mov byte [rdi], ah
    mov byte [rdi+1], al
    mov ax, r14w
    mov byte [rdi+2], ah
    mov byte [rdi+3], al
    mov eax, r12d
    add eax, 8
    mov byte [rdi+4], ah
    mov byte [rdi+5], al
    mov word [rdi+6], 0
    push rax
    push rsi
    push rcx
    push r8
    push r9
    lea rsi, [net_build_buf]
    mov ecx, r12d
    add ecx, 8
    mov r8d, [nic_ip]
    mov r9d, r13d
    call net_udp_checksum
    ; net_checksum16's result is a host-order logical 16-bit value, same
    ; as nic_send_ip's IP-header checksum - that call site byte-swaps with
    ; ror ax,8 before the store (see nic_send_ip below) because `mov word`
    ; writes little-endian but the wire field needs big-endian. This call
    ; site was missing that same swap, so every outgoing UDP checksum
    ; (DHCP discover/request included) was written backwards. QEMU's slirp
    ; doesn't validate UDP checksums so this never showed up there, but a
    ; real DHCP server will silently drop a packet with a bad checksum -
    ; which is indistinguishable from "no response" on our end.
    ror ax, 8
    mov [net_build_buf + 6], ax
    pop r9
    pop r8
    pop rcx
    pop rsi
    pop rax
    lea rsi, [net_build_buf]
    mov ecx, r12d
    add ecx, 8
    mov r8d, r13d
    mov r9b, IP_PROTO_UDP
    call nic_send_ip
    pop r15
    pop r14
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

; dns_skip_name: rsi = ptr to a DNS name -> rsi advanced past it. Handles
; both plain label sequences and 2-byte compression pointers.
dns_skip_name:
    push rax
    push rbx
.dn_loop:
    mov al, [rsi]
    test al, al
    jz .dn_zterm
    mov bl, al
    and bl, 0xC0
    cmp bl, 0xC0
    je .dn_ptr
    movzx rax, al
    add rsi, rax
    inc rsi
    jmp .dn_loop
.dn_zterm:
    inc rsi
    jmp .dn_out
.dn_ptr:
    add rsi, 2
.dn_out:
    pop rbx
    pop rax
    ret

; dns_handle_reply: parse the DNS response whose UDP payload is in
; nic_rx_frame (ip header at +14). On an A record for our query id, store
; nic_dns_result and set nic_dns_done.
dns_handle_reply:
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
    movzx eax, byte [nic_rx_frame+14]
    and al, 0x0F
    imul eax, 4
    lea r14, [nic_rx_frame + 14 + rax + 8]   ; udp payload start
    movzx eax, byte [r14]
    shl eax, 8
    movzx edx, byte [r14+1]
    or eax, edx
    cmp ax, [nic_dns_query_id]
    jne .dh_done
    ; ancount at payload+6
    movzx r9d, byte [r14+6]
    shl r9d, 8
    movzx r10d, byte [r14+7]
    or r9d, r10d
    mov rsi, r14
    add rsi, 12
    call dns_skip_name
    add rsi, 4
    xor r11d, r11d
.dh_answer:
    cmp r11d, r9d
    jae .dh_notfound
    call dns_skip_name
    movzx r8d, byte [rsi]
    shl r8d, 8
    movzx r10d, byte [rsi+1]
    or r8d, r10d
    add rsi, 2
    add rsi, 2
    add rsi, 4
    movzx r10d, byte [rsi]
    shl r10d, 8
    movzx r12d, byte [rsi+1]
    or r10d, r12d
    add rsi, 2
    cmp r8d, 1
    jne .dh_skip
    cmp r10d, 4
    jne .dh_skip
    mov eax, [rsi]
    mov [nic_dns_result], eax
    mov byte [nic_dns_done], 1
    jmp .dh_done
.dh_skip:
    add rsi, r10
    inc r11d
    jmp .dh_answer
.dh_notfound:
    mov byte [nic_dns_done], 1
    mov dword [nic_dns_result], 0xFFFFFFFF
.dh_done:
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

; dns_query: rsi = hostname (null-terminated). If it's already a dotted
; quad, returns eax = IP. Otherwise sends a DNS A query to nic_dns:53,
; waits for the reply (with one retry), and returns eax = IP, or
; 0xFFFFFFFF on failure.
dns_query:
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
    call ip_parse_arg
    jnc .dq_done
    ; live-trace every frame that arrives while we wait (ARP reply, DNS
    ; reply) so a real-hardware "unresolved" can be localized to TX-vs-RX
    ; vs-parse from the console instead of guessing. Cleared below.
    mov byte [nic_diag_verbose], 1
    mov r12, rsi
    mov byte [nic_dns_retry], 0
    mov ax, [nic_dns_id]
    inc word [nic_dns_id]
    mov r13w, ax
    lea rdi, [net_build_buf]
    mov byte [rdi], ah
    mov byte [rdi+1], al
    mov byte [rdi+2], 0x01
    mov byte [rdi+3], 0x00
    mov byte [rdi+4], 0x00
    mov byte [rdi+5], 0x01
    mov byte [rdi+6], 0x00
    mov byte [rdi+7], 0x00
    mov byte [rdi+8], 0x00
    mov byte [rdi+9], 0x00
    mov byte [rdi+10], 0x00
    mov byte [rdi+11], 0x00
    add rdi, 12
    mov rsi, r12
.dq_label:
    mov r10, rsi
    mov r14, rdi
    inc rdi
    xor r11, r11
.dq_count:
    mov al, [rsi]
    cmp al, '.'
    je .dq_ldone
    test al, al
    jz .dq_ldone
    mov [rdi], al
    inc rdi
    inc rsi
    inc r11
    jmp .dq_count
.dq_ldone:
    mov [r14], r11b
    cmp byte [rsi], 0
    je .dq_lend
    inc rsi
    jmp .dq_label
.dq_lend:
    mov byte [rdi], 0
    inc rdi
    mov byte [rdi], 0x00
    mov byte [rdi+1], 0x01
    mov byte [rdi+2], 0x00
    mov byte [rdi+3], 0x01
    add rdi, 4
    lea rcx, [net_build_buf]
    sub rdi, rcx
    mov r14, rdi
    ; send
    mov byte [nic_dns_done], 0
    mov [nic_dns_query_id], r13w
    lea rsi, [net_build_buf]
    mov ecx, r14d
    mov r8d, [nic_dns]
    mov r9w, 53
    mov r10w, 0x8B00
    call nic_send_udp
    jc .dq_fail
.dq_send2:
    call rtc_sec_now
    mov r15, rax
.dq_wait:
    call netpoll
    cmp byte [nic_dns_done], 0
    jne .dq_have
    call rtc_sec_now
    cmp eax, r15d
    jne .dq_tick
    jmp .dq_wait
.dq_tick:
    cmp byte [nic_dns_retry], 0
    jne .dq_fail
    mov byte [nic_dns_retry], 1
    lea rsi, [net_build_buf]
    mov ecx, r14d
    mov r8d, [nic_dns]
    mov r9w, 53
    mov r10w, 0x8B00
    call nic_send_udp
    jc .dq_fail
    jmp .dq_send2
.dq_have:
    mov eax, [nic_dns_result]
    jmp .dq_done
.dq_fail:
    mov byte [nic_diag_verbose], 0
    mov eax, 0xFFFFFFFF
.dq_done:
    mov byte [nic_diag_verbose], 0
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

; ---- text helpers ------------------------------------------------
; ip_parse_arg: rsi = "a.b.c.d" -> CF=0 and eax = IP if valid, else CF=1.
ip_parse_arg:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    xor r8d, r8d
    mov r9d, 4
.ipa_octet:
    call parse_octet
    jc .ipa_fail
    shl r8d, 8
    or r8b, al
    dec r9d
    jz .ipa_all
    cmp byte [rsi], '.'
    jne .ipa_fail
    inc rsi
    jmp .ipa_octet
.ipa_all:
    mov al, [rsi]
    test al, al
    jz .ipa_ok
    cmp al, ' '
    je .ipa_ok
    jmp .ipa_fail
.ipa_ok:
    bswap r8d
    mov eax, r8d
    clc
    jmp .ipa_out
.ipa_fail:
    stc
.ipa_out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; parse_octet: rsi = decimal number -> al = value (0..255), rsi advanced.
parse_octet:
    push rbx
    push rcx
    push rdx
    xor rbx, rbx
    mov rcx, 3
.po_digit:
    cmp rcx, 0
    jle .po_done
    mov al, [rsi]
    cmp al, '0'
    jb .po_done
    cmp al, '9'
    ja .po_done
    imul rbx, 10
    sub al, '0'
    movzx rax, al
    add rbx, rax
    cmp rbx, 255
    ja .po_fail
    inc rsi
    dec rcx
    jmp .po_digit
.po_done:
    cmp rcx, 3
    je .po_fail
    mov al, bl
    clc
    jmp .po_out
.po_fail:
    stc
.po_out:
    pop rdx
    pop rcx
    pop rbx
    ret

; ip_parse_to: rsi = dotted quad string, rdi = 4-byte destination.
ip_parse_to:
    call ip_parse_arg
    jc .ipt_fail
    mov [rdi], eax
    clc
    ret
.ipt_fail:
    stc
    ret

; u8_to_dec: rbx = value (0..255), rcx = output buffer (>=4B). NUL-terminated.
u8_to_dec:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    test rbx, rbx
    jnz .u8_nonzero
    mov byte [rcx], '0'
    mov byte [rcx+1], 0
    jmp .u8_out
.u8_nonzero:
    lea r8, [rcx+3]
    mov byte [r8+1], 0
.u8_digit:
    mov rax, rbx
    xor edx, edx
    mov ebx, 10
    div ebx
    mov rbx, rax
    add dl, '0'
    mov [r8], dl
    dec r8
    test rbx, rbx
    jnz .u8_digit
    inc r8
.u8_shift:
    mov al, [r8]
    mov [rcx], al
    inc rcx
    inc r8
    test al, al
    jnz .u8_shift
.u8_out:
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ipv4_to_str: rsi = 4-byte IP, rdi = output buffer (>=16B).
ipv4_to_str:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    xor r8, r8
.i4s_octet:
    movzx rbx, byte [rsi + r8]
    lea rcx, [dec_tmp_buf]
    call u8_to_dec
    lea rcx, [dec_tmp_buf]
.i4s_append:
    mov al, [rcx]
    test al, al
    jz .i4s_sep
    mov [rdi], al
    inc rdi
    inc rcx
    jmp .i4s_append
.i4s_sep:
    inc r8
    cmp r8, 4
    jae .i4s_end
    mov byte [rdi], '.'
    inc rdi
    jmp .i4s_octet
.i4s_end:
    mov byte [rdi], 0
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; print_mac: prints nic_mac as xx:xx:xx:xx:xx:xx.
print_mac:
    push rbx
    push rcx
    push rsi
    lea rsi, [nic_mac]
    mov rcx, 6
.pm_loop:
    movzx rbx, byte [rsi]
    mov al, bl
    shr al, 4
    call print_hex_nibble
    mov al, bl
    and al, 0x0F
    call print_hex_nibble
    inc rsi
    dec rcx
    jz .pm_done
    mov al, ':'
    call putchar
    jmp .pm_loop
.pm_done:
    pop rsi
    pop rcx
    pop rbx
    ret
print_hex_nibble:
    cmp al, 10
    jb .phn_num
    add al, 'a'-10
    jmp .phn_put
.phn_num:
    add al, '0'
.phn_put:
    push rbx
    mov bl, [cur_normal_attr]
    call putchar
    pop rbx
    ret

; print_hex32: eax = value -> prints 8 hex digits, most significant first.
print_hex32:
    push rax
    push rcx
    push rdx
    mov edx, eax
    mov ecx, 8
.ph32_loop:
    mov eax, edx
    rol eax, 4          ; rotate the next nibble into bits 3:0
    mov edx, eax
    and al, 0x0F
    call print_hex_nibble
    dec ecx
    jnz .ph32_loop
    pop rdx
    pop rcx
    pop rax
    ret

; print_hex8: al = value -> prints 2 hex digits.
print_hex8:
    push rax
    push rcx
    mov cl, al
    shr al, 4
    and al, 0x0F
    call print_hex_nibble
    mov al, cl
    and al, 0x0F
    call print_hex_nibble
    pop rcx
    pop rax
    ret

; netdiag_dump_frame: prints a one-line summary of the frame currently in
; nic_rx_frame - EtherType, and for IPv4, protocol + src/dst IP, and for
; UDP, src/dst port. Only called when nic_diag_verbose is set (during the
; dhcp wait loop) so normal shell use isn't spammed by background ARP/ICMP
; traffic. This exists to answer "what is actually arriving" directly,
; instead of continuing to infer it from the send-side code.
netdiag_dump_frame:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi

    mov rsi, msg_diag_type
    mov al, [cur_normal_attr]
    call print_string_attr
    mov al, [nic_rx_frame+12]
    call print_hex8
    mov al, [nic_rx_frame+13]
    call print_hex8

    mov al, [nic_rx_frame+12]
    cmp al, 0x08
    jne .ndf_arp
    mov al, [nic_rx_frame+13]
    cmp al, 0x00
    jne .ndf_arp
    jmp .ndf_ip
.ndf_arp:
    mov al, [nic_rx_frame+12]
    cmp al, 0x08
    jne .ndf_nl
    mov al, [nic_rx_frame+13]
    cmp al, 0x06
    jne .ndf_nl
    ; ARP payload starts at offset 14. op is a big-endian word at +6/+7;
    ; spa (sender protocol address, i.e. sender's IP) is 4 bytes at +14.
    mov rsi, msg_diag_arp_op
    mov al, [cur_normal_attr]
    call print_string_attr
    mov al, [nic_rx_frame+14+6]
    call print_hex8
    mov al, [nic_rx_frame+14+7]
    call print_hex8
    mov rsi, msg_diag_arp_spa
    mov al, [cur_normal_attr]
    call print_string_attr
    lea rsi, [nic_rx_frame+14+14]
    call print_ip4
    jmp .ndf_nl
.ndf_ip:
    mov rsi, msg_diag_proto
    mov al, [cur_normal_attr]
    call print_string_attr
    mov al, [nic_rx_frame+14+9]
    call print_hex8

    mov rsi, msg_diag_src
    mov al, [cur_normal_attr]
    call print_string_attr
    lea rsi, [nic_rx_frame+14+12]
    call print_ip4

    mov rsi, msg_diag_dst
    mov al, [cur_normal_attr]
    call print_string_attr
    lea rsi, [nic_rx_frame+14+16]
    call print_ip4

    mov al, [nic_rx_frame+14+9]
    cmp al, IP_PROTO_UDP
    jne .ndf_nl

    movzx eax, byte [nic_rx_frame+14]
    and al, 0x0F
    imul eax, 4
    add eax, 14
    lea rdi, [nic_rx_frame + rax]

    mov rsi, msg_diag_sport
    mov al, [cur_normal_attr]
    call print_string_attr
    movzx eax, byte [rdi]
    call print_hex8
    movzx eax, byte [rdi+1]
    call print_hex8

    mov rsi, msg_diag_dport
    mov al, [cur_normal_attr]
    call print_string_attr
    movzx eax, byte [rdi+2]
    call print_hex8
    movzx eax, byte [rdi+3]
    call print_hex8

.ndf_nl:
    mov rsi, msg_nl
    mov al, [cur_normal_attr]
    call print_string_attr

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; netdiag_dump_tx_frame: prints a hex dump of the fully-assembled frame
; about to leave the NIC (eth header + ip header + payload), 16
; space-separated hex bytes per line, so it can be checked by hand
; against RFC 2131/RFC 791 field offsets when there's no external
; capture tool available. rsi = frame ptr, rcx = frame length in bytes.
; Only called when nic_diag_verbose is set (during the dhcp wait), so
; normal shell use isn't spammed by a dump on every packet sent.
netdiag_dump_tx_frame:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    xor ebx, ebx            ; ebx = bytes printed on the current line
.ndtf_loop:
    test rcx, rcx
    jz .ndtf_flush
    movzx eax, byte [rsi]
    call print_hex8
    mov al, ' '
    call putchar
    inc rsi
    dec rcx
    inc ebx
    cmp ebx, 16
    jne .ndtf_loop
    mov al, 10
    call putchar
    xor ebx, ebx
    jmp .ndtf_loop
.ndtf_flush:
    test ebx, ebx
    jz .ndtf_done
    mov al, 10
    call putchar
.ndtf_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; print_ip4: rsi = 4-byte IP -> prints "a.b.c.d".
print_ip4:
    push rsi
    push rdi
    lea rdi, [net_ip_str]
    call ipv4_to_str
    lea rsi, [net_ip_str]
    call print_string
    pop rdi
    pop rsi
    ret

; fs_save: writes the OS volume ([boot_device], nodes 0..OS_NODES) then
; every mounted volume back to its own device. Returns CF=0 on success,
; CF=1 if the OS volume's disk isn't there/isn't responding. A mounted
; volume that fails to write is left mounted (best effort; sync still
; reports success).
fs_save:
    push rax
    push rbx
    push rsi
    push rdi
    push r13
    push r14
    xor r14b, r14b                ; r14b = 1 once anything has actually been saved
    cmp byte [fs_disk_available], 0
    je .skip_os_volume            ; no OS disk responded this session - don't retry
                                   ; it, but still try any mounted AHCI volumes below
    ; OS volume: [boot_device] (0 = legacy ATA boot drive, 4+ = an AHCI slot
    ; fs_load fell back to), base 0, label = root node's name
    lea rsi, [node_name]
    xor rdi, rdi
    movzx eax, byte [boot_device]
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

; fs_load: reads the OS volume into nodes 0..OS_NODES. Tries device 0
; (legacy ATA primary master) first, exactly as always. If that device
; never responds at all - common on real hardware that has no PATA/IDE
; controller and only exposes its disk(s) over SATA - it then looks
; through whatever AHCI port slots (4..4+ahci_port_count-1) ahci_init
; found at boot, preferring one that already holds a valid SFFS volume,
; falling back to the first one that simply responds (a blank/new SATA
; SSD) so a fresh filesystem still has somewhere to persist to. Whichever
; device actually ends up holding the OS volume is remembered in
; [boot_device] for fs_save (and cmd_format's "don't touch the boot
; drive" check) to use afterwards. If nothing responds anywhere, falls
; back to fs_init for a fresh in-memory-only filesystem.
; Mounted volumes are never loaded here - you re-attach them after boot
; with 'dscan' + 'mount'.
; sets fs_loaded_from_disk, fs_disk_available and boot_device accordingly.
fs_load:
    push rax
    push rbx
    push rcx
    push rdi
    push rsi
    mov byte [boot_device], 0
    xor al, al                  ; device 0 (boot drive) - legacy ATA, tried first
    xor rdi, rdi                ; base 0 = OS volume
    call vol_read
    cmp rax, -1
    jne .loaded
    ; device 0 gave us nothing. If it's present but just not SFFS (blank
    ; disk, older format, ...) keep it as the boot device exactly like
    ; before - only chase AHCI slots when device 0 wasn't there at all.
    cmp byte [fs_disk_available], 0
    je .try_ahci
    call fs_init
    mov byte [fs_loaded_from_disk], 0
    jmp .done
.try_ahci:
    movzx ecx, byte [ahci_port_count]
    test ecx, ecx
    jz .no_disk                 ; no AHCI controller/ports either - genuinely nothing
    ; pass 1: any AHCI slot that already has a valid SFFS volume on it
    xor ebx, ebx
.ahci_sffs_scan:
    cmp ebx, ecx
    jae .ahci_blank_scan
    lea eax, [ebx + 4]           ; device id 4+slot
    mov byte [boot_device], al
    xor rdi, rdi
    call vol_read
    cmp rax, -1
    jne .ahci_found
    inc ebx
    jmp .ahci_sffs_scan
    ; pass 2: no AHCI slot had a ready SFFS volume yet - use the first one
    ; that at least responds (freshly flashed/blank SATA SSD) as the boot
    ; device, so a fresh in-memory filesystem has somewhere to save to.
.ahci_blank_scan:
    xor ebx, ebx
.ahci_blank_loop:
    cmp ebx, ecx
    jae .no_disk
    lea eax, [ebx + 4]
    mov byte [boot_device], al
    call disk_select_device
    mov rax, SUPER_LBA
    lea rdi, [fs_super_buf]
    call disk_read_sector
    jnc .ahci_blank_present
    inc ebx
    jmp .ahci_blank_loop
.ahci_blank_present:
    mov byte [fs_disk_available], 1
    call fs_init
    mov byte [fs_loaded_from_disk], 0
    jmp .done
.ahci_found:
    mov byte [fs_disk_available], 1
    mov qword [cur_dir], 0
    mov byte [fs_loaded_from_disk], 1
    jmp .done
.no_disk:
    mov byte [fs_disk_available], 0
    mov byte [boot_device], 0
    call fs_init
    mov byte [fs_loaded_from_disk], 0
    jmp .done
.loaded:
    mov qword [cur_dir], 0
    mov byte [fs_loaded_from_disk], 1
.done:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
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
;  RTC / CMOS CLOCK  (date, time, wig time)
; ============================================================
; The MC146818 real-time clock chip is addressed through port 0x70
; (register index, bit 7 disables NMIs while set) and 0x71 (data).
; All values come back BCD-encoded unless status register B's binary
; bit is set, and hours may be 12-hour mode - rtc_update normalizes
; everything to plain 24-hour binary before storing it.

; cmos_read: al = register index (0..0x3F) -> al = that register's value.
cmos_read:
    push rdx
    or al, 0x80                 ; set NMI-disable bit while selecting
    mov dx, 0x70
    out dx, al
    ; tiny I/O delay so the RTC latches the address before the data read
    push rax
    mov al, 0
    out 0x80, al                ; write to the unused POST port = short pause
    pop rax
    mov dx, 0x71
    in al, dx
    pop rdx
    ret

; rtc_wait_uip: waits until the RTC's Update-In-Progress flag (status A,
; bit 7) clears, so the registers read below are internally consistent.
rtc_wait_uip:
    push rax
.uip_wait:
    mov al, 0x0A
    call cmos_read
    test al, 0x80
    jnz .uip_wait
    pop rax
    ret

; bcd_to_bin: al = BCD byte -> al = binary value. Preserves other regs.
bcd_to_bin:
    push rbx
    push rcx
    push rdx
    movzx rbx, al
    mov al, bl
    shr al, 4
    movzx rcx, al
    imul rcx, 10
    mov al, bl
    and al, 0x0F
    movzx rdx, al
    add rcx, rdx
    mov rax, rcx
    pop rdx
    pop rcx
    pop rbx
    ret

; rtc_update: reads seconds/minutes/hours/day/month/year (+ century, if the
; chip provides one) into the rtc_* variables, normalized to 24-hour binary.
rtc_update:
    push rax
    push rbx
    call rtc_wait_uip
    mov al, 0x00
    call cmos_read
    mov [rtc_sec], al
    mov al, 0x02
    call cmos_read
    mov [rtc_min], al
    mov al, 0x04
    call cmos_read
    mov [rtc_hour], al
    mov al, 0x07
    call cmos_read
    mov [rtc_day], al
    mov al, 0x08
    call cmos_read
    mov [rtc_month], al
    mov al, 0x09
    call cmos_read
    mov [rtc_year], al
    mov al, 0x32
    call cmos_read
    mov [rtc_century], al
    mov al, 0x0B
    call cmos_read
    mov bl, al                     ; status register B
    ; BCD? (status B bit 2). If clear, values are already binary.
    test bl, 0x04
    jz .rtc_no_bcd
    mov al, [rtc_sec]
    call bcd_to_bin
    mov [rtc_sec], al
    mov al, [rtc_min]
    call bcd_to_bin
    mov [rtc_min], al
    mov al, [rtc_hour]
    call bcd_to_bin
    mov [rtc_hour], al
    mov al, [rtc_day]
    call bcd_to_bin
    mov [rtc_day], al
    mov al, [rtc_month]
    call bcd_to_bin
    mov [rtc_month], al
    mov al, [rtc_year]
    call bcd_to_bin
    mov [rtc_year], al
    mov al, [rtc_century]
    call bcd_to_bin
    mov [rtc_century], al
.rtc_no_bcd:
    ; 12-hour mode? (status B bit 1). If set, hour's bit 7 = PM.
    test bl, 0x02
    jz .rtc_done
    mov al, [rtc_hour]
    mov ah, al
    and al, 0x7F                  ; hour value 1..12
    test ah, 0x80                 ; PM?
    jz .rtc_am
    cmp al, 12
    jae .rtc_h12                  ; 12 PM stays 12
    add al, 12
    jmp .rtc_h12
.rtc_am:
    cmp al, 12
    jne .rtc_h12
    xor al, al                    ; 12 AM = 00
.rtc_h12:
    mov [rtc_hour], al
.rtc_done:
    pop rbx
    pop rax
    ret

; format_num2: rax = 0..99 -> two zero-padded digits written to [rdi], rdi
; advances by 2. Preserves rax/rbx/rcx/rdx.
format_num2:
    push rax
    push rbx
    push rcx
    push rdx
    xor rdx, rdx
    mov rbx, 10
    div rbx                       ; rax = tens, rdx = ones
    add al, '0'
    mov [rdi], al
    inc rdi
    mov al, dl
    add al, '0'
    mov [rdi], al
    inc rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; format_num4: rax = 0..9999 -> four zero-padded digits written to [rdi],
; rdi advances by 4. Preserves rax/rbx/rcx/rdx.
format_num4:
    push rax
    push rbx
    push rcx
    push rdx
    xor rdx, rdx
    mov rbx, 1000
    div rbx                       ; rax = thousands, rdx = remainder
    push rdx
    add al, '0'
    mov [rdi], al
    inc rdi
    pop rax
    xor rdx, rdx
    mov rbx, 100
    div rbx                       ; rax = hundreds, rdx = remainder
    push rdx
    add al, '0'
    mov [rdi], al
    inc rdi
    pop rax
    xor rdx, rdx
    mov rbx, 10
    div rbx                       ; rax = tens, rdx = ones
    add al, '0'
    mov [rdi], al
    inc rdi
    mov al, dl
    add al, '0'
    mov [rdi], al
    inc rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; format_time: writes "HH:MM:SS\0" to [rdi], rdi advances to the terminator.
; Preserves everything except rdi.
format_time:
    push rax
    call rtc_update
    movzx rax, byte [rtc_hour]
    call format_num2
    mov byte [rdi], ':'
    inc rdi
    movzx rax, byte [rtc_min]
    call format_num2
    mov byte [rdi], ':'
    inc rdi
    movzx rax, byte [rtc_sec]
    call format_num2
    mov byte [rdi], 0
    pop rax
    ret

; format_date: writes "YYYY-MM-DD\0" to [rdi], rdi advances to the
; terminator. Preserves everything except rdi.
format_date:
    push rax
    push rbx
    call rtc_update
    ; full year = century*100 + year; fall back to the 2000s when the
    ; chip has no century register (or it reports something unusable).
    movzx rax, byte [rtc_century]
    cmp al, 20
    je .fd_cent_ok
    cmp al, 21
    je .fd_cent_ok
    mov al, 20
.fd_cent_ok:
    imul rax, 100
    movzx rbx, byte [rtc_year]
    add rax, rbx
    call format_num4
    mov byte [rdi], '-'
    inc rdi
    movzx rax, byte [rtc_month]
    call format_num2
    mov byte [rdi], '-'
    inc rdi
    movzx rax, byte [rtc_day]
    call format_num2
    mov byte [rdi], 0
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
; cmd_date / cmd_time: print the current date / time from the RTC.
; ------------------------------------------------------------
cmd_date:
    lea rdi, [date_str_buf]
    call format_date
    mov rsi, date_str_buf
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, newline_str
    call print_string
    ret

cmd_time:
    lea rdi, [time_str_buf]
    call format_time
    mov rsi, time_str_buf
    mov al, [cur_normal_attr]
    call print_string_attr
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; cmd_write: write <path> <content> creates the file (or overwrites an
; existing file's content). It's meant to be used through a "~" pipe -
; "show hi ~ write file.txt" writes "hi" to file.txt - but also works
; standalone: write file.txt "some text".
; ------------------------------------------------------------
cmd_write:
    cmp byte [arg1_buf], 0
    jne .cw_have_arg
    mov rsi, msg_write_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.cw_have_arg:
    mov rax, [cur_dir]
    mov rsi, arg1_buf
    mov rdi, leaf1_buf
    call fs_resolve_path
    cmp rax, -1
    je .cw_bad_path
    mov r11, rax                  ; parent dir the file goes in
    call check_target_sys_auth
    cmp rax, 1
    je .cw_bad_path
    ; an existing FILE by that name gets its content overwritten
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2
    call fs_find_child
    cmp rax, -1
    jne .cw_overwrite
    ; no file - make sure a folder with that name isn't in the way
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .cw_exists
    mov rax, r11
    mov rsi, leaf1_buf
    mov r10, 2                    ; type file
    call fs_create_node
    cmp rax, -1
    je .cw_full
    lea rsi, [arg2_buf]
    call fs_write_file
    call maybe_auto_sync
    ret
.cw_overwrite:
    ; rax = existing file node index, replace its content
    lea rsi, [arg2_buf]
    call fs_write_file
    call maybe_auto_sync
    ret
.cw_exists:
    mov rsi, msg_exists
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.cw_full:
    cmp byte [fs_name_too_long], 1
    je .cw_toolong
    mov rsi, msg_full
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.cw_toolong:
    mov rsi, msg_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.cw_bad_path:
    mov rsi, msg_bad_path
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    ret

; ------------------------------------------------------------
; wig time: the "widget" command. Draws a live clock in the top-right
; corner of the screen that updates every second, until Esc is pressed.
; ------------------------------------------------------------

; wig_draw_clock: right-aligns "HH:MM:SS" at row 0 of the screen, writing
; straight to VGA memory so the shell's cursor and scrollback stay put.
wig_draw_clock:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    lea rdi, [wig_str_buf]
    call format_time
    lea rsi, [wig_str_buf]
    call str_len                  ; rax = 8 (always, for HH:MM:SS)
    mov rbx, 80
    sub rbx, rax                  ; rbx = starting column
    imul rbx, rbx, 2              ; column -> byte offset
    lea rdi, [VGA_BASE + rbx]
    lea rsi, [wig_str_buf]
    mov bl, ATTR_WIG
.wig_write:
    mov al, [rsi]
    cmp al, 0
    je .wig_written
    mov [rdi], al
    mov [rdi+1], bl
    add rdi, 2
    inc rsi
    jmp .wig_write
.wig_written:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; wig_clear: blanks the 8-column corner slot the widget draws in.
wig_clear:
    push rax
    push rcx
    push rdi
    lea rdi, [VGA_BASE + (0*80 + 72)*2]
    mov rcx, 8
    mov ax, 0x0720                ; space, light grey on black
.wig_clr:
    mov [rdi], ax
    add rdi, 2
    loop .wig_clr
    pop rdi
    pop rcx
    pop rax
    ret

; cmd_wig: usage "wig time". Runs the live clock widget until Esc.
cmd_wig:
    cmp byte [arg1_buf], 0
    je .wig_usage
    mov rsi, arg1_buf
    mov rdi, str_time
    call str_eq
    cmp al, 1
    jne .wig_usage
    mov byte [kill_flag], 0
    call wig_draw_clock
    call rtc_update
    mov al, [rtc_sec]
    mov [wig_last_sec], al
.wig_loop:
    call kbd_poll
    cmp byte [kill_flag], 0
    jne .wig_done
    call rtc_update
    mov al, [rtc_sec]
    cmp al, [wig_last_sec]
    je .wig_loop
    mov [wig_last_sec], al
    call wig_draw_clock
    jmp .wig_loop
.wig_done:
    mov byte [kill_flag], 0
    call wig_clear
    ret
.wig_usage:
    mov rsi, msg_wig_usage
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; cmd_shelly: prints a splash banner. The title cycles through the rainbow
; palette one character at a time.
cmd_shelly:
    mov rsi, shelly_rule
    mov al, ATTR_WIG
    call print_string_attr
    lea rsi, [shelly_title]
    call cmd_shelly_rainbow
    mov al, 0x0A
    mov bl, [cur_normal_attr]
    call putchar
    mov rsi, shelly_version
    mov al, ATTR_WIG
    call print_string_attr
    mov rsi, shelly_by
    mov al, 0x0D
    call print_string_attr
    mov rsi, shelly_cr
    mov al, ATTR_PROMPT
    call print_string_attr
    mov rsi, shelly_rule
    mov al, ATTR_WIG
    call print_string_attr
    ret

; cmd_shelly_rainbow: prints the null-terminated string in rsi, cycling the
; attribute through the rainbow palette per character.
cmd_shelly_rainbow:
    push rax
    push rbx
    push rcx
    push rsi
    xor rcx, rcx
.rs_loop:
    mov al, [rsi]
    cmp al, 0
    je .rs_done
    lea rbx, [shelly_palette]
    mov bl, [rbx + rcx]
    call putchar
    inc rsi
    inc rcx
    cmp rcx, SHELLY_PAL_LEN
    jb .rs_loop
    xor rcx, rcx
    jmp .rs_loop
.rs_done:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

%include "party.asm"
%include "tcp.asm"
%include "http.asm"
%include "browse.asm"
%include "mouse.asm"

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
    call mouse_hide
    call mouse_sel_clear
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
    call mouse_show
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

; cursor_step_left / cursor_step_right: move the hardware cursor one cell
; back/forward across cursor_row/cursor_col (wrapping at row edges), without
; touching VGA content. Used by read_line for Left/Right/Home/End so moving
; the cursor over already-echoed text doesn't erase or retype anything.
; cursor_step_left is a no-op at row 0, col 0 (nothing further left to go).
; cursor_step_right does not scroll - callers only step it across text that
; has already been drawn (and therefore already fits on screen).
cursor_step_left:
    push rax
    cmp byte [cursor_col], 0
    jne .left_dec
    cmp byte [cursor_row], 0
    je .left_out          ; already at top-left; nothing to do
    dec byte [cursor_row]
    mov byte [cursor_col], VGA_COLS-1
    jmp .left_upd
.left_dec:
    dec byte [cursor_col]
.left_upd:
    call update_cursor
.left_out:
    pop rax
    ret

cursor_step_right:
    push rax
    inc byte [cursor_col]
    cmp byte [cursor_col], VGA_COLS
    jne .right_upd
    mov byte [cursor_col], 0
    inc byte [cursor_row]
.right_upd:
    call update_cursor
    pop rax
    ret

; print_string: rsi = null terminated string, default attribute
print_string:
    push rax
    mov al, [cur_normal_attr]
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
serial_init:
    push rax
    push rdx
    mov dx, 0x3FB
    mov al, 0x80               ; DLAB = 1
    out dx, al
    mov dx, 0x3F8
    mov al, 0x01               ; divisor 1 -> 115200 baud
    out dx, al
    mov dx, 0x3F9
    xor al, al
    out dx, al
    mov dx, 0x3FB
    mov al, 0x03               ; 8N1, DLAB = 0
    out dx, al
    mov dx, 0x3FA
    mov al, 0xC7               ; FIFO on, clear, 14-byte trigger
    out dx, al
    pop rdx
    pop rax
    ret

; serial_mirror: transmit the char in al on COM1 (blocks until THR empty).
; The char is parked in cl because dx (used for the port address) overlaps dl.
serial_mirror:
    push rax
    push rcx
    push rdx
    mov cl, al
    mov dx, 0x3FD
.sm_wait:
    in al, dx
    test al, 0x20
    jz .sm_wait
    mov dx, 0x3F8
    mov al, cl
    out dx, al
    pop rdx
    pop rcx
    pop rax
    ret

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
    ; background-process capture: while a background .run is being
    ; stepped, putchar appends to that process's output ring instead of
    ; touching the screen/serial at all (like the "~" pipe capture above).
    cmp qword [bg_capture_base], 0
    je .bg_nocap
    cmp al, 0x0D
    je .bg_cap_exit              ; ignore carriage returns
    push rsi
    push rcx
    push rdx
    mov bl, al                   ; stash the char (bl is dead on this path)
    mov rsi, [bg_capture_base]
    mov rcx, [bg_capture_len_ptr]
    mov rdx, [bg_capture_start_ptr]
    mov ecx, [rcx]               ; current byte count
    mov edx, [rdx]               ; current start offset
    mov rdi, [bg_capture_max]
    cmp rcx, rdi
    jb .bg_cap_append
    ; ring full: overwrite the oldest byte and advance the start
    lea rsi, [rsi + rdx]
    mov [rsi], bl
    inc rdx
    cmp rdx, rdi
    jb .bg_cap_s_ok
    xor rdx, rdx
.bg_cap_s_ok:
    mov rsi, [bg_capture_start_ptr]
    mov [rsi], edx
    jmp .bg_cap_exit2
.bg_cap_append:
    ; len < max: write at (start + len) mod max
    mov rax, rdx
    add rax, rcx
    cmp rax, rdi
    jb .bg_cap_nowrap
    sub rax, rdi
.bg_cap_nowrap:
    mov rsi, [bg_capture_base]
    add rsi, rax
    mov [rsi], bl
    inc rcx
    mov rsi, [bg_capture_len_ptr]
    mov [rsi], ecx
.bg_cap_exit2:
    pop rdx
    pop rcx
    pop rsi
.bg_cap_exit:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.bg_nocap:
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
    push rax
    mov al, [cur_normal_attr]
    mov [rdi+1], al
    pop rax
    jmp .advance
.useattr:
    mov [rdi+1], bl
.advance:
    call mouse_sel_putchar_check
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
    jne .nl_out
    call scroll_screen
    mov byte [cursor_row], VGA_ROWS-1
.nl_out:
    mov al, 0x0A
.out:
    call update_cursor
    call serial_mirror
    call mouse_show
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
    call mouse_hide
    call scrollback_capture_row      ; archive row 0 before it's shifted away
    call mouse_sel_clear             ; the shift would otherwise invalidate the snapshot
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
    cmp byte [mouse_y], 0           ; content moved up: track the cursor up too
    je .done
    dec byte [mouse_y]
.done:
    call mouse_show
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ============================================================
;  loading spinner: a tiny |/-\ animation for operations that take a
;  visible moment (scanning drives, formatting). spinner_step draws one
;  frame at the current cursor cell and steps the cursor back onto that
;  same cell, so repeated calls animate in place instead of scrolling
;  text across the screen; spinner_clear blanks that cell again once
;  the operation is done, leaving the cursor exactly where it was.
; ============================================================
spinner_idx: db 0
spinner_frames: db '|','/','-','\'

spinner_step:
    push rax
    push rbx
    push rcx
    movzx rax, byte [spinner_idx]
    and al, 3
    movzx rcx, al
    mov al, [spinner_frames + rcx]
    mov bl, [cur_normal_attr]
    call putchar
    dec byte [cursor_col]
    call update_cursor
    inc byte [spinner_idx]
    pop rcx
    pop rbx
    pop rax
    ret

spinner_clear:
    push rax
    push rbx
    mov al, ' '
    mov bl, [cur_normal_attr]
    call putchar
    dec byte [cursor_col]
    call update_cursor
    pop rbx
    pop rax
    ret

; ============================================================
;  PS/2 KEYBOARD
; ============================================================

; get_char: blocks until a key is pressed, returns ascii in al.
; Also handles: Ctrl tracking (make/break of 0x1D, plain or E0-prefixed),
; E0-prefixed arrow/Home/End/Delete keys (Up=0x48, Down=0x50, Left=0x4B,
; Right=0x4D, Home=0x47, End=0x4F, Delete=0x53), and Ctrl+Up/Ctrl+Down (or,
; while edit_active is set, plain Up/Down with no Ctrl needed) driving the
; on-screen scrollback view. Plain Up/Down (no Ctrl, edit_active clear),
; Left, Right, Home, End, and Delete are all returned to the caller as
; sentinel bytes (KEY_UP/KEY_DOWN/KEY_LEFT/KEY_RIGHT/KEY_HOME/KEY_END/
; KEY_DELETE) instead of an ascii char, so read_line can use them for
; history and in-line cursor movement/editing. Right before returning any
; real key (ascii or sentinel) to the caller, if the view is currently
; scrolled back it snaps back to the live screen first - typing or
; navigating history always means "I'm done reviewing, back to the prompt".
get_char:
    push rbx
.wait:
    in al, 0x64
    test al, 1
    jz .wait
    test al, 0x20                  ; aux (mouse) byte waiting?
    jz .kbd_byte
    in al, 0x60
    cmp byte [mouse_ena], 0
    je .wait                       ; mouse off: just discard
    call mouse_byte
    jmp .wait
.kbd_byte:
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
    cmp bl, 0x4B                 ; extended Left
    je .ext_left
    cmp bl, 0x4D                 ; extended Right
    je .ext_right
    cmp bl, 0x47                 ; extended Home
    je .ext_home
    cmp bl, 0x4F                 ; extended End
    je .ext_end
    cmp bl, 0x53                 ; extended Delete
    je .ext_delete
    cmp bl, 0x1D                 ; right Ctrl make
    je .ext_ctrl_make
    cmp bl, 0x1C                 ; keypad Enter
    je .ext_kp_enter
    cmp bl, 0x35                 ; keypad /
    je .ext_kp_slash
    cmp bl, 0x4A                 ; keypad -
    je .ext_kp_minus
    cmp bl, 0x4E                 ; keypad +
    je .ext_kp_plus
    jmp .wait                    ; ignore any other extended key
.ext_kp_enter:
    mov al, 13
    jmp .snap_and_return
.ext_kp_slash:
    mov al, '/'
    jmp .snap_and_return
.ext_kp_minus:
    mov al, '-'
    jmp .snap_and_return
.ext_kp_plus:
    mov al, '+'
    jmp .snap_and_return
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
    cmp byte [edit_active], 0
    jne .eu_scroll                ; edit mode: plain Up always scrolls, no Ctrl needed
    cmp byte [ctrl_state], 0
    je .return_up
    cmp byte [browse_active], 0
    jne .return_up
.eu_scroll:
    call scrollback_view_up
    jmp .wait
.ext_down:
    cmp byte [edit_active], 0
    jne .ed_scroll                ; edit mode: plain Down always scrolls, no Ctrl needed
    cmp byte [ctrl_state], 0
    je .return_down
    cmp byte [browse_active], 0
    jne .return_down
.ed_scroll:
    call scrollback_view_down
    jmp .wait
.return_up:
    mov al, KEY_UP
    jmp .snap_and_return
.return_down:
    mov al, KEY_DOWN
    jmp .snap_and_return
.ext_left:
    mov al, KEY_LEFT
    jmp .snap_and_return
.ext_right:
    mov al, KEY_RIGHT
    jmp .snap_and_return
.ext_home:
    mov al, KEY_HOME
    jmp .snap_and_return
.ext_end:
    mov al, KEY_END
    jmp .snap_and_return
.ext_delete:
    mov al, KEY_DELETE
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
    cmp byte [ctrl_state], 0
    je .have_normal
    ; Ctrl held: intercept copy/paste (case-insensitive, in case Shift is
    ; also held). Ctrl+C copies the mouse selection into the clipboard and
    ; is consumed; Ctrl+V returns the KEY_PASTE sentinel for read_line.
    cmp al, 'c'
    je .ctrl_c
    cmp al, 'C'
    je .ctrl_c
    cmp al, 'v'
    je .ctrl_v
    cmp al, 'V'
    je .ctrl_v
.have_normal:
    jmp .snap_and_return
.ctrl_c:
    call clip_copy
    jmp .wait
.ctrl_v:
    mov al, KEY_PASTE
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

    call mouse_hide
    call mouse_sel_clear
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
    call mouse_show
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
; backspace/Delete, Left/Right/Home/End in-line cursor movement, Up/Down
; command history, and terminates on Enter. Buffer is null terminated.
; r8 = current line length, r9 = buffer ptr, r10 = max chars, r11 = the
; cursor's position within the line (0..r8) - everything below that
; isn't a straight end-of-line append goes through r11 instead of r8.
; read_char_or_step: like get_char but non-blocking from the shell's
; point of view: if no keyboard byte is waiting, steps the background
; processes for one quantum and returns al = 0 (never returned by
; get_char, which maps every zero table entry to "wait"). Preserves
; every register so read_line's r8-r11 line state survives a step.
read_char_or_step:
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
    in al, 0x64
    test al, 1
    jnz .rcs_get
    call bg_scheduler_tick
    xor al, al
    jmp .rcs_out
.rcs_get:
    call get_char
.rcs_out:
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

read_line:
    push rax
    push rbx
    push rdi
    push rcx
    xor r8, r8
    xor r11, r11
    mov r9, rdi
    mov r10, rcx
    mov byte [history_nav], 0
.loop:
    call read_char_or_step
    test al, al
    jz .loop
    cmp al, 0x0D
    je .enter
    cmp al, 0x08
    je .bksp
    cmp al, 0x09
    je .tab
    cmp al, KEY_UP
    je .hist_up
    cmp al, KEY_DOWN
    je .hist_down
    cmp al, KEY_PASTE
    je .paste
    cmp al, KEY_LEFT
    je .curs_left
    cmp al, KEY_RIGHT
    je .curs_right
    cmp al, KEY_HOME
    je .curs_home
    cmp al, KEY_END
    je .curs_end
    cmp al, KEY_DELETE
    je .fwd_delete
    call .insert_char
    jmp .loop

.curs_left:
    cmp r11, 0
    je .loop
    dec r11
    call cursor_step_left
    jmp .loop
.curs_right:
    cmp r11, r8
    jae .loop
    inc r11
    call cursor_step_right
    jmp .loop
.curs_home:
    cmp r11, 0
    je .loop
    dec r11
    call cursor_step_left
    jmp .curs_home
.curs_end:
    cmp r11, r8
    jae .loop
    inc r11
    call cursor_step_right
    jmp .curs_end

.bksp:
    cmp r11, 0
    je .loop
    dec r11
    call .remove_at_cursor
    call cursor_step_left
    mov rcx, 1                   ; one stale trailing cell to blank
    call .redraw_tail
    jmp .loop

.fwd_delete:
    cmp r11, r8
    jae .loop
    call .remove_at_cursor
    mov rcx, 1                   ; one stale trailing cell to blank
    call .redraw_tail
    jmp .loop

; .remove_at_cursor: deletes the buffer byte at index r11, shifting
; everything after it left by one, and decrements r8. Does not touch the
; screen or r11 itself - callers handle cursor movement/redraw. Clobbers
; rax/rdx.
.remove_at_cursor:
    push rax
    push rdx
    mov rdx, r11
.rac_loop:
    lea rax, [rdx+1]
    cmp rax, r8
    jae .rac_done
    mov al, [r9 + rax]
    mov [r9 + rdx], al
    inc rdx
    jmp .rac_loop
.rac_done:
    dec r8
    pop rdx
    pop rax
    ret

; .insert_char (in: al = character to insert at the cursor). Shifts
; buf[r11..r8-1] right by one, stores al at r9+r11, redraws the
; widened tail, and advances r11/the screen cursor past the inserted
; character. No-op if the buffer is already full. Clobbers
; rax/rbx/rcx/rdx/rsi/rdi; updates r8/r11.
.insert_char:
    cmp r8, r10
    jae .ic_full
    mov dl, al                   ; stash the typed char - the shift below uses al as scratch
    cmp r8, r11
    je .ic_no_shift
    mov rsi, r8
.ic_shift:
    dec rsi
    mov al, [r9 + rsi]
    mov [r9 + rsi + 1], al
    cmp rsi, r11
    je .ic_no_shift
    jmp .ic_shift
.ic_no_shift:
    mov al, dl
    mov [r9 + r11], al
    inc r8
    xor rcx, rcx                 ; buffer just grew - nothing stale to blank
    call .redraw_tail
    inc r11
    call cursor_step_right
.ic_full:
    ret

; .redraw_tail (in: rcx = extra blank cells to print after the tail, 0 or
; 1). Redraws buf[r11..r8-1] then rcx blanks via putchar, then walks the
; hardware cursor back left until it's on r11's screen cell again. Every
; caller above has the hardware cursor sitting exactly on r11's screen
; cell when it calls this. Preserves r8/r9/r10/r11; clobbers
; rax/rbx/rcx/rdx/rsi/rdi.
.redraw_tail:
    push rax
    push rbx
    push rdx
    push rsi
    push rdi
    mov rdx, r8
    sub rdx, r11                 ; rdx = tail length (buffer chars to draw)
    mov rdi, rdx
    add rdi, rcx                 ; rdi = total cells printed = walk-back distance
    mov rsi, r11                 ; rsi walks r11..r8-1 as a buffer index directly
.rt_buf_loop:
    cmp rsi, r8
    jae .rt_blank_loop
    mov al, [r9 + rsi]
    mov bl, [cur_normal_attr]
    call putchar
    inc rsi
    jmp .rt_buf_loop
.rt_blank_loop:
    cmp rcx, 0
    je .rt_back_loop
    mov al, ' '
    mov bl, [cur_normal_attr]
    call putchar
    dec rcx
    jmp .rt_blank_loop
.rt_back_loop:
    cmp rdi, 0
    je .rt_done
    call cursor_step_left
    dec rdi
    jmp .rt_back_loop
.rt_done:
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    pop rax
    ret

.paste:
    lea rsi, [clip_buf]
.paste_loop:
    mov al, [rsi]
    cmp al, 0
    je .loop
    cmp r8, r10
    jae .loop
    cmp al, 10                ; strip newlines / carriage returns / backspaces
    je .paste_next
    cmp al, 13
    je .paste_next
    cmp al, 8
    je .paste_next
    cmp al, ' '
    jb .paste_next            ; only paste printable characters
    cmp al, '~'
    ja .paste_next
    push rsi
    call .insert_char
    pop rsi
.paste_next:
    inc rsi
    jmp .paste_loop

.tab:
    cmp r11, r8
    jne .loop                    ; completion only supported with the cursor at end-of-line
    call complete_line
    mov r11, r8                   ; completion only ever appends, so the cursor tracks the new end
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
    call .cursor_to_end
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
    call .cursor_to_end
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

; .cursor_to_end: walks r11/the screen cursor forward to the end of the
; current line. Used before history navigation replaces the whole line,
; since the erase-and-reload below assumes the cursor starts at the end.
.cursor_to_end:
    cmp r11, r8
    jae .cte_out
    inc r11
    call cursor_step_right
    jmp .cursor_to_end
.cte_out:
    ret

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
; displayed/buffered line (cursor assumed at end-of-line - see
; .cursor_to_end above) and replaces it with the source string, leaving
; the cursor at the new end.
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
    mov bl, [cur_normal_attr]
    call putchar
    pop rbx
    inc rcx
    jmp .le_echo
.le_echo_done:
    mov r11, r8
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

; ============================================================
;  complete_line: Tab completion for the rush prompt. Called from
;  read_line when the user presses Tab.
;  - first token on the line: completes against the built-in command
;    table (completion_cmds)
;  - any later token: completes against the names of files/folders
;    directly inside cur_dir
;  A single unique match is completed in place (commands get a trailing
;  space, folders a trailing '/'); an ambiguous prefix is extended as
;  far as all candidates agree, and if the prefix is already as long as
;  the shared portion, the candidates are listed and the prompt and
;  line are reprinted.
;  Preserves r9/r10; r8 (current line length) may grow as characters
;  are completed, which is exactly what read_line expects.
; ============================================================
complete_line:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r11
    push r12
    push r13
    push r14
    push r15

    ; ---- locate the token being typed: token_start in r13 ----
    mov r12, r8                  ; scan backward from the cursor
    xor r13, r13                 ; token_start
.tk_loop:
    cmp r12, 0
    je .tk_done
    dec r12
    cmp byte [r9 + r12], ' '
    jne .tk_loop
    lea r13, [r12 + 1]
.tk_done:
    mov rbx, r8                  ; rbx = token length = r8 - r13
    sub rbx, r13

    ; ---- mode: r11 = 1 if this is not the first token ----
    xor r11, r11
    xor rcx, rcx
.mode_loop:
    cmp rcx, r13
    jae .mode_done
    cmp byte [r9 + rcx], ' '
    jne .mode_fs
    inc rcx
    jmp .mode_loop
.mode_fs:
    mov r11, 1
.mode_done:

    ; ---- gather matches into comp_matches[], count in r15 ----
    xor r15, r15
    cmp r11, 0
    jne .g_fs
.g_cmd:
    xor rdi, rdi                 ; table index
.g_cmd_loop:
    lea rax, [completion_cmds + rdi*8]
    mov rax, [rax]
    test rax, rax
    jz .g_done
    mov rsi, rax
    call .is_prefix
    cmp al, 1
    jne .g_cmd_next
    mov [comp_matches + r15*2], di
    inc r15
.g_cmd_next:
    inc rdi
    jmp .g_cmd_loop
.g_fs:
    xor rdi, rdi                 ; node index
.g_fs_loop:
    cmp rdi, MAX_NODES
    jae .g_done
    cmp byte [node_type + rdi], 0
    je .g_fs_next
    movzx rax, word [node_parent + rdi*2]
    cmp rax, [cur_dir]
    jne .g_fs_next
    imul rax, rdi, NAME_LEN
    lea rsi, [node_name + rax]
    call .is_prefix
    cmp al, 1
    jne .g_fs_next
    mov [comp_matches + r15*2], di
    inc r15
.g_fs_next:
    inc rdi
    jmp .g_fs_loop
.g_done:
    cmp r15, 0
    je .out

    ; ---- common prefix length over all matches (starts at rbx) ----
    mov rcx, rbx                 ; pos
.cc_loop:
    cmp rcx, r10
    jae .cc_end
    mov rdx, rcx
    xor r14, r14
    call .char_at                ; al = char of first match at pos
    mov r12, rax
    test r12, r12
    jz .cc_end
    mov r14, 1
.cc_inner:
    cmp r14, r15
    jae .cc_agree
    mov rdx, rcx
    call .char_at
    cmp rax, r12
    jne .cc_end
    inc r14
    jmp .cc_inner
.cc_agree:
    inc rcx
    jmp .cc_loop
.cc_end:
    ; rcx = common prefix length
    ; ---- append the unambiguous tail, chars rbx..rcx-1 ----
    mov rsi, rbx                 ; pos
.ap_loop:
    cmp rsi, rcx
    jae .ap_done
    cmp r8, r10
    jae .ap_done
    mov rdx, rsi
    xor r14, r14
    call .char_at
    mov [r9 + r8], al
    inc r8
    push rbx
    mov bl, [cur_normal_attr]
    call putchar
    pop rbx
    inc rsi
    jmp .ap_loop
.ap_done:
    cmp r15, 1
    jne .multi
    ; ---- single match: finish it off ----
    cmp r11, 0
    jne .uniq_fs
    cmp r8, r10
    jae .out
    mov al, ' '
    mov [r9 + r8], al
    inc r8
    push rbx
    mov bl, [cur_normal_attr]
    call putchar
    pop rbx
    jmp .out
.uniq_fs:
    movzx rax, word [comp_matches]
    cmp byte [node_type + rax], 1
    jne .out
    cmp r8, r10
    jae .out
    mov al, '/'
    mov [r9 + r8], al
    inc r8
    push rbx
    mov bl, [cur_normal_attr]
    call putchar
    pop rbx
    jmp .out
.multi:
    ; multiple matches: only list if the common prefix advanced nothing
    cmp rcx, rbx
    jne .out
    mov al, 0x0A
    call putchar
    xor r14, r14
.ls_loop:
    cmp r14, r15
    jae .ls_done
    call .match_ptr              ; rsi = candidate string
    call print_string
    mov al, ' '
    call putchar
    inc r14
    jmp .ls_loop
.ls_done:
    mov al, 0x0A
    call putchar
    call print_prompt
    xor rcx, rcx
.echo:
    cmp rcx, r8
    jae .out
    mov al, [r9 + rcx]
    push rbx
    mov bl, [cur_normal_attr]
    call putchar
    pop rbx
    inc rcx
    jmp .echo
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; .is_prefix: is the typed token (r9+r13, length rbx) a prefix of the
; null-terminated string in rsi? Returns al = 1/0. Clobbers only al.
.is_prefix:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdi, rsi
    mov rsi, r9
    add rsi, r13
    mov rcx, rbx
.ip_loop:
    cmp rcx, 0
    je .ip_yes
    mov al, [rsi]
    mov dl, [rdi]
    cmp al, dl
    jne .ip_no
    inc rsi
    inc rdi
    dec rcx
    jmp .ip_loop
.ip_yes:
    mov al, 1
    jmp .ip_out
.ip_no:
    xor al, al
.ip_out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; .match_ptr: r14 = match slot -> rsi = candidate string. Clobbers rax.
.match_ptr:
    movzx rax, word [comp_matches + r14*2]
    cmp r11, 0
    jne .mp_fs
    imul rax, 8
    lea rax, [completion_cmds + rax]
    mov rsi, [rax]
    ret
.mp_fs:
    imul rax, NAME_LEN
    lea rsi, [node_name + rax]
    ret

; .char_at: r14 = match slot, rdx = position -> al = char at that position.
; Clobbers rax only; returns the character zero-extended in rax so callers
; can compare/test the full register (the char in al alone would leave
; pointer bits in rax's upper bytes and break null checks).
.char_at:
    movzx rax, word [comp_matches + r14*2]
    cmp r11, 0
    jne .ca_fs
    imul rax, 8
    lea rax, [completion_cmds + rax]
    mov rax, [rax]
    add rax, rdx
    movzx rax, byte [rax]
    ret
.ca_fs:
    imul rax, NAME_LEN
    lea rax, [node_name + rax]
    add rax, rdx
    movzx rax, byte [rax]
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
cur_normal_attr: db ATTR_NORMAL      ; foreground color used for normal output; changed by 'color'

; --- keyboard/scrollback/history state ---
ctrl_state:    db 0                  ; 1 while either Ctrl key is held
edit_active:   db 0                  ; 1 while cmd_edit's editor loop owns the keyboard -
                                      ; makes plain Up/Down scroll the view instead of
                                      ; being treated as shell command history

; --- cmd_edit .ce_render scratch: the render pass streams fs_io_buf through
; putchar (which is the only thing allowed to touch cursor_row/cursor_col
; and trigger wraps), so it can't just compute the cursor's screen position
; ahead of time - it captures cursor_row/cursor_col live, the instant the
; render reaches the cursor's buffer index, into these, then restores them
; once the whole visible page has been drawn. ---
ce_cursor_captured: db 0
ce_saved_row:       db 0
ce_saved_col:       db 0
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

; --- RTC (CMOS) clock state and scratch ---
rtc_sec:     db 0
rtc_min:     db 0
rtc_hour:    db 0
rtc_day:     db 0
rtc_month:   db 0
rtc_year:    db 0
rtc_century: db 0
time_str_buf:  times 16 db 0    ; "HH:MM:SS"
date_str_buf:  times 16 db 0    ; "YYYY-MM-DD"
wig_str_buf:   times 16 db 0    ; scratch for the wig clock widget
wig_last_sec:  db 0             ; last second the widget drew (redraw gate)

banner:
    db "ShellyForever v0.1.11 -- 'help' for commands", 10, 0
build_stamp:
    db "build 20260811 -- Party v0.1.11: % && || read, multi-var vars", 10, 0

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
str_about:  db "about", 0
str_pwd:    db "current", 0
str_clear:  db "wipe", 0
str_help:   db "help", 0
str_reboot: db "rboot", 0
str_sync:   db "sync", 0
str_autosync: db "autosync", 0
str_on:     db "on", 0
str_off:    db "off", 0
auto_sync_enabled: db 1
msg_autosync_status: db "auto-sync: ", 0
msg_autosync_enabled: db "auto-sync enabled.", 10, 0
msg_autosync_disabled: db "auto-sync disabled.", 10, 0
str_run:    db "run", 0
str_run_magic1: db "[ShellyForever]", 0
str_run_magic2: db "[run 0.1]", 0
str_run_magic3: db "program = v1", 0
msg_run_usage: db "run: usage: run <file.run> [-back]", 10, 0
msg_run_badheader: db "run: error: invalid or missing RUN 0.1 header", 10, 0
msg_run_running: db "run ", 0
msg_run_toomany: db "run: too many processes running", 10, 0
str_run_procname: db "run", 0
str_run_back: db "-back", 0
msg_run_bg_running: db "run ", 0
msg_run_bg_big: db "run: script too large for background (16KB max)", 0
msg_run_bg_lexerr: db "run: background script failed to parse, line ", 0
msg_run_bg_execerr: db "run: background script error: ", 0
msg_bg_notice_pre: db "Background process ", 0
msg_bg_notice_done: db " finished.", 0
msg_bg_notice_killed: db " killed.", 0
msg_bg_notice_err: db " error", 0

; ------------------------------------------------------------
; kernel_api_table slot layout (each slot = 8 bytes, offset shown
; is the byte offset used by "call [r11+offset]" from compiled .run
; code). Slots 0x00-0x20 are the original v0.1 ABI (print/read/kill);
; 0x28 onward were added for the "party compile" native-codegen
; backend (see party.asm: party_compile_to_run) so compiled programs
; can call the SAME tested interpreter primitives (value stack,
; operators, variable table, function invocation) instead of each
; compiled program re-implementing them. One slot (0x18) holds a DATA
; pointer - everything else is a function pointer. 0xE0 (KAPI_BOOT)
; is the compiled-program runtime bootstrap: a compiled binary's
; whole entry sequence is LEA RSI,embedded-source ; CALL [KAPI_BOOT]
; ; RET - party_boot_compiled does the lex + interpreted run.
; ------------------------------------------------------------
KAPI_PRINT_STRING       equ 0x00
KAPI_PRINT_STRING_ATTR  equ 0x08
KAPI_GET_CHAR           equ 0x10
KAPI_NEWLINE_STR        equ 0x18   ; data: pointer to newline_str
KAPI_POLL_KILL          equ 0x20
KAPI_PUSH_VAL           equ 0x28
KAPI_POP_VAL            equ 0x30
KAPI_VAL_SET_INT        equ 0x38
KAPI_VAL_SET_STR        equ 0x40
KAPI_VAL_SET_BOOL_TRUE  equ 0x48
KAPI_VAL_SET_BOOL_FALSE equ 0x50
KAPI_VAL_SET_NONE       equ 0x58
KAPI_OP_BIN             equ 0x60
KAPI_OP_EQ              equ 0x68
KAPI_OP_NEQ             equ 0x70
KAPI_OP_REL             equ 0x78
KAPI_TRUTHY             equ 0x80
KAPI_PRINT_VALUE        equ 0x88
KAPI_VAR_DECLARE        equ 0x90
KAPI_VAR_ASSIGN         equ 0x98
KAPI_VAR_GET_PTR        equ 0xA0
KAPI_VAL_COPY           equ 0xA8
KAPI_INVOKE_FUNC        equ 0xB0
KAPI_FUNC_FIND          equ 0xB8
KAPI_NEG_TOP            equ 0xC0
KAPI_LEX                equ 0xC8
KAPI_COLLECT_FUNCS      equ 0xD0
KAPI_VAL_SET_FLOAT      equ 0xD8
KAPI_BOOT               equ 0xE0   ; compiled-program runtime bootstrap
KAPI_TABLE_SIZE         equ 0xF0   ; total bytes

ALIGN 8
kernel_api_table: times KAPI_TABLE_SIZE db 0
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
str_sys_name:   db "sys", 0
str_alias_sly_name: db "alias.sly", 0
str_alias_sly_content: db "ali h help", 10, "ali l list", 10, 0
str_sysconfig_name: db "sysconfig.sly", 0
str_sysconfig_content: db "mouse = off", 10, "internet = on", 10, "auto_sync = on", 10, 0
str_auth:   db "auth", 0
str_vars:   db "vars", 0
str_ali:    db "ali", 0
str_alis:   db "alis", 0
str_color:  db "color", 0
str_date:   db "date", 0
str_time:   db "time", 0
str_write:  db "write", 0
str_wig:    db "wig", 0
str_shelly: db "shelly", 0
str_netinfo: db "netinfo", 0
str_bounce:  db "bounce", 0
str_monitor: db "monitor", 0
str_dns:     db "dns", 0
str_net:     db "net", 0
str_dhcp:    db "dhcp", 0
str_tcp:     db "tcp", 0
str_take:    db "take", 0
str_give:    db "give", 0
str_browse:  db "browse", 0
str_mouse:   db "mouse", 0
str_net_ip:  db "ip", 0
str_net_gw:  db "gw", 0
str_net_dns:  db "dns", 0
str_net_on:   db "on", 0
str_net_off:  db "off", 0
str_net_reset: db "reset", 0

; shelly splash banner pieces
SHELLY_PAL_LEN equ 6
shelly_palette: db 0x0E, 0x0B, 0x0A, 0x0D, 0x09, 0x0F   ; yel, cyan, grn, mag, lblu, wht
shelly_rule:  db "  ============================================================", 10, 0
shelly_title: db "         ShellyForever OS", 0
shelly_version: db "         v0.1.11", 10, 0
shelly_by:    db "         Developed by Sourasish Das", 10, 0
shelly_cr:    db "         Copyright 2026. All rights reserved.", 10, 0
str_col_black:    db "black", 0
str_col_dblue:    db "dblue", 0
str_col_blue:     db "blue", 0
str_col_lblue:    db "lblue", 0
str_col_dgreen:   db "dgreen", 0
str_col_green:    db "green", 0
str_col_lgreen:   db "lgreen", 0
str_col_dcyan:    db "dcyan", 0
str_col_cyan:     db "cyan", 0
str_col_lcyan:    db "lcyan", 0
str_col_dred:     db "dred", 0
str_col_red:      db "red", 0
str_col_lred:     db "lred", 0
str_col_dmagenta: db "dmagenta", 0
str_col_magenta:  db "magenta", 0
str_col_lmagenta: db "lmagenta", 0
str_col_purple:   db "purple", 0
str_col_brown:    db "brown", 0
str_col_orange:   db "orange", 0
str_col_gray:     db "gray", 0
str_col_grey:     db "grey", 0
str_col_dgray:    db "dgray", 0
str_col_dgrey:    db "dgrey", 0
str_col_yellow:   db "yellow", 0
str_col_white:    db "white", 0
str_col_reset:    db "reset", 0
str_col_list:     db "list", 0

msg_color_unknown: db "color: unknown color name: ", 0
msg_color_set1:    db "color: normal text set to ", 0
msg_color_set2:    db 10, 0
msg_color_current: db "This is the current color.", 0
color_list_text:
    db "Available colors (normal-text only; prompt/error colors are fixed):", 10
    db "  black", 10
    db "  dblue    blue    lblue", 10
    db "  dgreen   green   lgreen", 10
    db "  dcyan    cyan    lcyan", 10
    db "  dred     red     lred", 10
    db "  dmagenta magenta lmagenta  purple", 10
    db "  brown    orange", 10
    db "  gray     grey", 10
    db "  dgray    dgrey", 10
    db "  yellow", 10
    db "  white", 10
    db "  reset             (back to the default green)", 10
    db "e.g. color cyan | color list | color reset", 10, 0

str_rmv_all: db "all", 0
str_force:  db "-force", 0
str_silent: db "-silent", 0
str_info:   db "-info", 0
str_test:   db "-test", 0
empty_str:  db 0
str_syscmd:    db "sys", 0        ; the "sys" command word (sys reset)
str_sys_reset: db "reset", 0
str_dscan:  db "dscan", 0
str_format: db "fmt", 0
str_mount:  db "mount", 0
str_unmount: db "unmount", 0
str_label:  db "label", 0
str_semicolon: db ";", 0
str_tilde:     db "~", 0
str_dollar:    db "$", 0

; --- Tab-completion tables (see complete_line) ---
completion_cmds:
    dq str_calc
    dq str_edit
    dq str_cf
    dq str_mkf
    dq str_mkfl
    dq str_show
    dq str_ls
    dq str_cat
    dq str_about
    dq str_pwd
    dq str_clear
    dq str_help
    dq str_reboot
    dq str_sync
    dq str_del
    dq str_rmv
    dq str_sdown
    dq str_rname
    dq str_cpy
    dq str_mov
    dq str_rr
    dq str_prs
    dq str_auth
    dq str_vars
    dq str_dscan
    dq str_format
    dq str_mount
    dq str_unmount
    dq str_label
    dq str_ali
    dq str_alis
    dq str_color
    dq str_date
    dq str_time
    dq str_write
    dq str_wig
    dq str_shelly
    dq str_syscmd
    dq 0
comp_matches: times 96 dw 0

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
msg_about_hdr1:  db "about: '", 0
msg_about_hdr2:  db "'", 10, 0
msg_about_nodeid: db "  node id:  ", 0
msg_about_type:   db "  type:     ", 0
msg_type_file:    db "file", 10, 0
msg_type_folder:  db "folder", 10, 0
msg_about_size:   db "  size:     ", 0
msg_about_bytes:  db " bytes", 10, 0
msg_about_blocks: db "  blocks:   ", 0
msg_about_blocks_singular: db " node (this file fits with no chain continuations)", 10, 0
msg_about_blocks_plural:   db " nodes (1 head + chain continuations - each ~159 bytes)", 10, 0
msg_about_items:  db "  items:    ", 0
msg_about_items_singular: db " entry", 10, 0
msg_about_items_plural:   db " entries", 10, 0
msg_shutting_down: db "Shutting down...", 10, 0
msg_empty:     db "(empty)", 10, 0
msg_synced:     db "Filesystem synced to disk.", 10, 0
msg_loaded_fs:  db "Loaded filesystem from disk.", 10, 10, 0
msg_fresh_fs:   db "No saved filesystem found - starting fresh.", 10, 10, 0
msg_no_disk:    db "No disk detected - filesystem will not persist.", 10, 10, 0
msg_sync_failed: db "error: sync failed - disk not available.", 10, 0

; --- NIC / network messages ---
msg_net_no_nic:    db "network: no NIC detected.", 10, 0
msg_net_usage:     db "net: usage: net ip|gw|dns <a.b.c.d> | net on|off|reset", 10, 0
msg_net_bad_ip:    db "network: bad IPv4 address: ", 0
msg_net_unresolved: db "network: could not resolve host.", 10, 0
msg_net_on_ok:      db "net: NIC brought up.", 10, 0
msg_net_on_fail:    db "net: NIC bring-up failed - no compatible NIC found.", 10, 0
msg_net_already_on: db "net: NIC is already up.", 10, 0
msg_net_off_ok:     db "net: NIC shut down.", 10, 0
msg_net_already_off: db "net: NIC is already down.", 10, 0
msg_net_reset_ok:   db "net: NIC reset complete.", 10, 0
msg_dhcp_start:    db "dhcp: requesting IP lease...", 10, 0
msg_dhcp_ok:       db "dhcp: lease acquired.", 10, 0
msg_dhcp_fail:     db "dhcp: no response - timed out waiting for an offer.", 10, 0
msg_dhcp_send_fail: db "dhcp: failed to transmit discover (TX error - link/chip problem).", 10, 0
msg_dhcp_rx_seen:  db "dhcp: raw frames seen on the wire while waiting: ", 0
msg_dhcp_no_frames: db "dhcp: NO raw frames arrived at all (link down? wrong port? NIC not receiving?)", 10, 0
msg_dhcp_had_frames: db "dhcp: frames arrived but no OFFER/ACK was recognized (packets blocked or parser)", 10, 0
msg_diag_type:     db "  rx: type=0x", 0
msg_diag_proto:    db " proto=0x", 0
msg_diag_src:      db " src=", 0
msg_diag_dst:      db " dst=", 0
msg_diag_sport:    db " sport=0x", 0
msg_diag_dport:    db " dport=0x", 0
msg_diag_arp_op:   db " op=0x", 0
msg_diag_arp_spa:  db " spa=", 0
msg_diag_tx:       db 10, "  tx: ", 0
msg_diag_txctx_arp: db "diag: failed frame was an ARP broadcast (42 bytes)", 10, 0
msg_diag_txctx_seg: db "diag: failed frame was a data/segment frame", 10, 0
msg_diag_pcists:   db "diag: PCI status reg (bits 8/11/12/13/14/15=parity/abort): ", 0
msg_diag_txdesc:   db "diag: failed TX descriptor raw command dword: ", 0
msg_diag_tppoll:   db "diag: TPPoll readback (bit6=NPQ still pending): ", 0
msg_diag_waitsecs: db "diag: TX wait - real seconds elapsed before giving up: ", 0
msg_diag_rawsec:   db "diag: TX wait raw start/end rtc seconds: ", 0
msg_diag_rawsec_sep: db " / ", 0
msg_diag_rawsec_ticks: db ", ticks observed: ", 0
msg_diag_chipraw:  db "diag: TxConfig HW-ID raw (captured right after reset): ", 0
msg_diag_chipname: db "diag: chip family match: ", 0
msg_chip_8168b:    db "RTL8168B/8111B", 0
msg_chip_8168c:    db "RTL8168C/8111C", 0
msg_chip_8168cp:   db "RTL8168CP/8111CP", 0
msg_chip_8168d:    db "RTL8168D/8111D", 0
msg_chip_8168dp:   db "RTL8168DP/8111DP", 0
msg_chip_unknown:  db "no match against known older-gen IDs - likely RTL8168E or later", 0
msg_ni_mac:        db "MAC : ", 0
msg_ni_drv:        db "DRV : ", 0
msg_ni_drv_8139:   db "rtl8139", 10, 0
msg_ni_drv_e1000:  db "e1000", 10, 0
msg_ni_drv_8168:   db "rtl8168/8169/8161", 10, 0
msg_ni_iobase:     db "IOB : 0x", 0
msg_ni_link:       db "LINK: ", 0
msg_ni_link_up:    db "up", 10, 0
msg_ni_link_down:  db "down", 10, 0
msg_ni_link_na:    db "n/a (not rtl8168)", 10, 0
msg_ni_ip:         db "IP  : ", 0
msg_ni_mask:       db "MASK: ", 0
msg_ni_gw:         db "GW  : ", 0
msg_ni_dns:        db "DNS : ", 0
msg_nl:            db 10, 0
msg_dns_usage:     db "dns: usage: dns <hostname>", 10, 0
msg_dns_res:       db "dns: ", 0
msg_dns_equals:    db " = ", 0
msg_dns_fail:      db "dns: resolution failed.", 10, 0
msg_bounce_usage:  db "bounce: usage: bounce <host>", 10, 0
msg_bounce_reply:  db "Reply from ", 0
msg_bounce_bytes:  db " bytes=32", 10, 0
msg_bounce_timeout: db "Request timed out.", 10, 0
msg_monitor_usage: db "monitor: usage: monitor <host>", 10, 0
msg_monitor_timeout: db "timeout", 10, 0
msg_monitor_stopped: db 10, "monitor stopped.", 10, 0
msg_tcp_usage:      db "tcp: usage: tcp <host> <port> [payload]", 10, 0
msg_tcp_badport:    db "tcp: bad port number.", 10, 0
msg_tcp_connecting: db "tcp: connecting to ", 0
msg_tcp_colon:      db ":", 0
msg_tcp_connected:  db 10, "tcp: connected.", 10, 0
msg_tcp_sent:       db "tcp: sent ", 0
msg_tcp_recv:       db "tcp: received ", 0
msg_tcp_bytes:      db " bytes.", 10, 0
msg_tcp_timeout:    db "tcp: timed out waiting for a reply.", 10, 0
msg_tcp_sendfail:   db "tcp: failed to transmit (TX error - link/chip problem).", 10, 0
msg_tcp_sendfail_noreply: db "tcp: failed to transmit (no ARP reply - peer/gateway unreachable).", 10, 0
msg_tcp_cancelled:  db 10, "tcp: cancelled.", 10, 0
msg_tcp_reset:      db "tcp: connection reset by peer.", 10, 0
msg_take_usage:     db "take: usage: take <url> <file>", 10, 0
msg_take_badurl:    db "take: bad URL format. Use http://host[:port]/path", 10, 0
msg_take_createfail: db "take: failed to create file.", 10, 0
msg_take_saved:     db "take: saved to ", 0
msg_take_getting:   db "take: getting ", 0
msg_take_from:      db " from ", 0
msg_take_badpath:   db "take: bad file path.", 10, 0
msg_take_nobody:    db "take: no body in response.", 10, 0
msg_give_usage:     db "give: usage give <url> <file>", 10, 0
msg_give_posting:   db "give: posting ", 0
msg_give_to:        db " to ", 0
msg_give_nofile:    db "give: no such file.", 10, 0
msg_give_noreply:   db "give: no reply body.", 10, 0
msg_http_unresolved: db "http: cannot resolve host.", 10, 0
msg_http_cancelled: db 10, "http: cancelled.", 10, 0
icmp_data_pad:     db "ShellyForever ping payload 0123456789abcdef", 0

; --- SFFS disk / mount messages ---
msg_dscan_header: db "Scanning for SFFS disks...", 10, 0
msg_dscan_found1: db "  device ", 0
msg_dscan_found2: db " (", 0
msg_dscan_found3: db "): SFFS volume '", 0
msg_dscan_found4: db "'", 0
msg_dscan_other2: db "): present, not SFFS", 0
msg_dscan_orig:    db " - fmt target: ", 0
msg_dscan_none:   db "No SFFS disks found.", 10, 0
msg_dev_primary:  db "primary ", 0
msg_dev_secondary: db "secondary ", 0
msg_dev_master:   db "master", 0
msg_dev_slave:    db "slave", 0
msg_dev_ahci:     db "ahci port ", 0
msg_fmt_usage:    db "fmt: use 'fmt <label>' to format a drive", 10, 0
msg_fmt_none:     db "fmt: no unformatted drive found (use 'fmt <label> -force' to reuse one)", 10, 0
msg_fmt_long:     db "fmt: label too long (max 31 characters)", 10, 0
msg_fmt_no_such:  db "fmt: no such drive: ", 0
msg_fmt_already:  db "fmt: that drive is already formatted - use -force to reformat it", 10, 0
msg_fmt_boot_drive: db "fmt: that's the boot drive - use -force to reformat it", 10, 0
msg_fmt_ok1:      db "Formatted ", 0
msg_fmt_ok2:      db " on ", 0
msg_fmt_ok3:      db ". Use 'sync' to save, then 'mount <label>'.", 0
msg_fmt_err:      db "fmt: disk error - failed to write.", 10, 0
str_disk_prefix:  db "disk", 0
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
msg_unmount_usage:  db "unmount: use 'unmount <label>' to detach a mounted drive", 10, 0
msg_unmount_ok1:    db "Unmounted ", 0
msg_unmount_ok2:    db " - drive is still on disk; 'dscan' + 'mount' re-attach it.", 0
msg_unmount_none1:  db "unmount: no drive mounted as '", 0
msg_unmount_none2:  db "'. Use 'mount' to attach one.", 10, 0
msg_unmount_busy1:  db "unmount: cannot detach ", 0
msg_unmount_busy2:  db " while inside it - 'cf /home' first", 10, 0
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
msg_write_usage: db "write: use 'write <file> <content>' - e.g. show hi ~ write file.txt", 10, 0
msg_wig_usage:   db "wig: use 'wig time' for the live clock widget (Esc to exit)", 10, 0
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
str_peek:        db "peek", 0
msg_prs_peek_notbg: db "prs: that process is not a background process", 10, 0
msg_prs_peek_usage: db "prs: usage: prs peek <pid|name> [lower|last] <N>", 10, 0

; --- auth / vars / flags messages ---
msg_auth_required: db "error: this command requires authentication. Use 'auth <command>' first.", 10, 0
msg_auth_granted:  db "Authentication granted.", 10, 0
msg_sys_usage:      db "sys: use 'auth sys reset' to factory-reset this system", 10, 0
msg_sys_reset_done: db "System reset complete. All files and variables were wiped and default system files recreated.", 10, 0
msg_vars_header:   db "Variables:", 10, 0
msg_vars_sep:     db " = ", 0
msg_vars_cleared:  db "All variables cleared.", 10, 0
msg_alias_usage:   db "error: usage: ali <name> <commands>", 10, 0
msg_alias_full:    db "error: alias table is full", 10, 0
msg_alias_too_deep: db "error: alias recursion too deep", 10, 0
msg_no_alias:      db "alis: no such alias: ", 0
msg_alis_header:   db "Aliases:", 10, 0
msg_alis_sep:      db ": ", 0
msg_aliases_cleared: db "All aliases cleared.", 10, 0
msg_mkfl_overwrite: db "mkfl: overwriting existing file ", 0
msg_mkfl_info:     db "mkfl: creating '", 0
msg_mkfl_info2:    db "' (", 0
msg_mkfl_info3:    db " bytes)", 10, 0
msg_mkfl_test_create:    db "mkfl: [test] would create '", 0
msg_mkfl_test_overwrite: db "mkfl: [test] would overwrite '", 0
msg_mkfl_test_suffix:    db " bytes) - test mode, no changes made", 10, 0
msg_mkfl_test_blocked1:  db "mkfl: [test] '", 0
msg_mkfl_test_blocked2:  db "' already exists - would fail (use -force to overwrite)", 10, 0

help_text:
    db "Commands (name args accept paths: docs/notes.txt, ../x, /home/x):", 10
    db "  cf <path>          change folder ('cf ..' up, 'cf /home' root)", 10
    db "  mkf <path>         make a folder", 10
    db '  mkfl <path> "txt"  make a file with text content', 10
    db '  show "text"        print a message (or a variable to show its value)', 10
    db "  list               list contents of current folder", 10
    db "  view <path>        print a file's content", 10
    db "  about <path>       show type/size/node-usage info for a file or folder", 10
    db "  edit <name>        open the built-in editor for a file", 10
    db "  del <path>         delete a file (requires auth)", 10
    db "  rname <path> <new> rename a file or folder (new name stays in same folder)", 10
    db "  cpy <src> <dest>   copy a file or folder (both can be paths)", 10
    db "  mov <src> <dest>   move/rename a file or folder (both can be paths)", 10
    db "  rr <script.rsh>    run a rush script file ($ = comment line)", 10
    db "  prs [kill <id>]    list processes, or kill by PID/rushrun", 10
    db "  vars               list all variables", 10
    db "  vars rmv all       clear all variables (requires auth)", 10
    db "  ali <name> <cmds>  create an alias, e.g. ali gs list ~ show", 10
    db "  alis               list all aliases", 10
    db "  rmv ali <name>     remove one alias", 10
    db "  auth <cmd> [args]  elevate privileges for one dangerous command", 10
    db "  mkfl -force        overwrite existing file (use -silent to suppress warning)", 10
    db "  mkfl -info         verbose output (filename + content length)", 10
    db "  mkfl -test         dry run - report what would happen, no changes made", 10
    db "  <name> = <value>   set a variable, e.g. a = 1", 10
    db "  rmv <name>         remove a variable", 10
    db "  rmv ali all        clear all aliases (requires auth)", 10
    db "  calc <expr>        evaluate math, e.g. calc 1 + 2 * 3", 10
    db "  current            print current path", 10
    db "  date               print the current date", 10
    db "  time               print the current time", 10
    db "  wig time           live clock widget in the top-right corner (Esc to exit)", 10
    db "  shelly             splash banner - ShellyForever OS credits", 10
    db "  write <path>       write text to a file, e.g. show hi ~ write file.txt", 10
    db "  wipe               clear the screen", 10
    db "  sync               save the filesystem (and mounted drives) to disk", 10
    db "  fmt <label>        format a drive with the SFFS format (-force reuses one)", 10
    db "  fmt <target> <lbl> format a SPECIFIC drive (see dscan's 'fmt target:')", 10
    db "  dscan              scan for SFFS drives attached to the ATA bus", 10
    db "  mount <label>      mount a formatted drive at /<label>/", 10
    db "  unmount <label>    detach a mounted drive (data stays on disk)", 10
    db "  label <old> <new>  rename a formatted drive without touching its data", 10
    db "  rboot              save to disk, then restart (requires auth)", 10
    db "  sdown              shut down (requires auth)", 10
    db "  sys reset          factory-reset: wipe all files/vars and recreate", 10
    db "                      default system files (requires auth)", 10
    db "  ;                  chain commands, e.g. show hi ; show bye", 10
    db "  ~                  pipe output, e.g. calc 1+2*3 ~ = a ; show a", 10
    db "  $                  comment line (lines starting with $ are skipped)", 10
    db "  netinfo            show NIC MAC address and IP/mask/gw/DNS", 10
    db "  net <ip|gw|dns>    change static network configuration", 10
    db "  net on|off|reset   bring NIC up / shut down / restart", 10
    db "  dhcp               obtain IP address, gateway, and DNS via DHCP", 10
    db "  dns <host>         resolve a hostname via DNS", 10
    db "  bounce <host>      send a single ICMP echo (ping)", 10
    db "  monitor <host>     ping repeatedly until Esc", 10
    db "  tcp <host> <port>  open a TCP connection and exchange data", 10
    db "  take <url> <file>  HTTP GET, save body to a file", 10
    db "  give <url> <file>  HTTP POST, send a file to a server", 10
    db "  browse <url>       text-based web browser", 10
    db "  mouse              toggle the PS/2 mouse cursor on/off", 10
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
    db 'mkfl <path> "text" [-force] [-silent] [-info] [-test]', 10
    db "  Make a file here with the given text content.", 10
    db "  -force overwrites an existing file (prints a warning).", 10
    db "  -silent suppresses that overwrite warning.", 10
    db "  -info prints the filename and content length.", 10
    db "  -test dry run: reports what would happen, makes no changes.", 10
    db '  e.g. mkfl hi.txt "hello" -force -silent', 10
    db '       mkfl hi.txt -test', 10, 0

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

help_about:
    db "about <path>", 10
    db "  Show info about a file or folder without printing its content:", 10
    db "  node id, type, and either its size in bytes + how many nodes", 10
    db "  in the volume's node table it occupies (a file over ~159 bytes", 10
    db "  needs more than one), or, for a folder, how many entries it has.", 10
    db "  e.g. about compilertest.pa      about docs", 10, 0

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
    db "rmv <name> | rmv ali <name> | rmv ali all", 10
    db "  Remove a variable, or (with 'ali') remove one alias by name.", 10
    db "  Clearing every alias at once requires auth:", 10
    db "  auth rmv ali all", 10, 0

help_vars:
    db "vars | vars rmv all", 10
    db "  List all variables, or clear all of them. Clearing requires", 10
    db "  auth: auth vars rmv all", 10, 0

help_ali:
    db "ali <name> <commands>", 10
    db "  Create (or redefine) an alias: <name> becomes shorthand for", 10
    db "  <commands>, which is stored verbatim - including any ; chains", 10
    db "  or ~ pipes - and run fresh each time the alias is invoked.", 10
    db '  e.g. ali testmath calc 5 + 5 ~ = a ; show a', 10
    db "       testmath            (running the alias prints 10)", 10, 0

help_alis:
    db "alis", 10
    db "  List all aliases and their bodies. To remove one, use", 10
    db "  'rmv ali <name>'; to clear all of them, use 'auth rmv ali all'.", 10, 0

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
    db "  vars rmv all, and rmv ali all.  e.g. auth sdown", 10, 0

help_pwd:
    db "current", 10
    db "  Print the current folder's path.", 10, 0

help_clear:
    db "wipe", 10
    db "  Clear the screen.", 10, 0

help_date:
    db "date", 10
    db "  Print the current date, read from the RTC clock chip.", 10
    db "  Format: YYYY-MM-DD (e.g. 2026-08-03).", 10, 0

help_time:
    db "time | wig time", 10
    db "  'time' prints the current time, read from the RTC clock chip.", 10
    db "  Format: HH:MM:SS, 24-hour clock (e.g. 14:30:05).", 10
    db "  'wig time' instead shows a live clock in the top-right corner", 10
    db "  of the screen that updates every second; press Esc to stop it.", 10, 0

help_write:
    db 'write <path> "<text>"', 10
    db "  Write text to a file, creating it if needed or overwriting an", 10
    db "  existing file's content. Usually used with a ~ pipe:", 10
    db "  show hi ~ write file.txt        (writes 'hi' to file.txt)", 10
    db "  calc 2 + 2 ~ write sum.txt      (writes '4' to sum.txt)", 10, 0

help_wig:
    db "wig time", 10
    db "  Show a live clock widget in the top-right corner of the", 10
    db "  screen. The time updates every second while it runs.", 10
    db "  Press Esc to stop the widget and return to the prompt.", 10, 0

help_shelly:
    db "shelly", 10
    db "  Print the ShellyForever OS splash banner: a rainbow", 10
    db "  title, the build version, the developer credit, and", 10
    db "  the copyright line.", 10, 0

help_take:
    db "take <url> <file>", 10
    db "  Download a file over HTTP/1.0 and save it locally. The", 10
    db "  URL must use the http:// scheme, e.g. take http://", 10
    db "  10.0.2.2:8080/notes.txt notes.txt. Parsed HTML headers;", 10
    db "  the body is saved as a new (or overwritten) file in the", 10
    db "  current directory. Esc cancels during the transfer.", 10, 0

help_give:
    db "give <url> <file>", 10
    db "  Read a local file and POST its content over HTTP/1.0", 10
    db "  to the given URL. The request includes Content-Type", 10
    db "  and Content-Length headers. The server's reply is", 10
    db "  printed. Esc cancels during the transfer.", 10, 0

help_browse:
    db "browse <url>", 10
    db "  Open the text-based web browser on a page. Renders", 10
    db "  HTML as plain text with [N] markers on each link.", 10
    db "  Keys: number+Enter follows a link, b/f back/forward,", 10
    db "  a adds a bookmark, l lists bookmarks, t saves the", 10
    db "  raw page to a file, j/k/space/p scroll, q quits.", 10, 0

help_mouse:
    db "mouse", 10
    db "  Toggle the PS/2 mouse cursor on or off.", 10
    db "  When on, the pointer follows the mouse and stays on", 10
    db "  top of scrolling text and full-screen redraws. Type", 10
    db "  'mouse' again to disable it.", 10
    db "  Drag with the left button to select text (reverse-video", 10
    db "  highlight); Ctrl+C copies the selection to the clipboard,", 10
    db "  Ctrl+V pastes it at the prompt or into the browse URL field.", 10
    db "  The wheel scrolls: the page in browse view, the terminal's", 10
    db "  scrollback elsewhere (same as Ctrl+Up/Ctrl+Down).", 10, 0

help_help:
    db "help | help <command>", 10
    db "  List every command, or show detailed help for just one.", 10
    db "  e.g. help calc", 10, 0

help_dscan:
    db "dscan", 10
    db "  Scan all four ATA drive slots for SFFS volumes and report", 10
    db "  which ones are formatted.", 10, 0

help_fmt:
    db "fmt <label> [-force] | fmt <target> <label> [-force]", 10
    db "  fmt <label>            formats the first unformatted drive.", 10
    db "  fmt <target> <label>   formats a SPECIFIC drive: <target> is the", 10
    db "  'disk0'/'disk1'/... shown by dscan (or an existing SFFS", 10
    db "  label, with -force, to reformat that drive in place).", 10, 0

help_mount:
    db "mount <label>", 10
    db "  Mount a formatted drive's volume under /<label>/, next to", 10
    db "  /home. Up to 2 drives can be mounted at once.", 10, 0

help_unmount:
    db "unmount <label>", 10
    db "  Detach a mounted drive's volume. The drive's data stays on", 10
    db "  disk untouched; 'dscan' + 'mount <label>' re-attach it later.", 10
    db "  Won't unmount while you're inside the volume.", 10, 0

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

help_sys:
    db "sys reset", 10
    db "  Factory-reset this system - use if something is badly wrong and", 10
    db "  you want a clean slate. Deletes every file and folder, clears all", 10
    db "  variables and aliases, then recreates the default system files", 10
    db "  (sys/, alias.sly, sysconfig) and saves to disk. Mounted external", 10
    db "  drives are not touched. This cannot be undone.", 10
    db "  Requires auth: auth sys reset", 10, 0

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


; --- scancode set 1 -> ascii tables (index = scancode, 0..0x53) ---
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
    times 0x47-0x3A db 0                           ; 0x3A-0x46 unused
    db '7','8','9','-','4','5','6','+','1','2','3','0','.'  ; 0x47-0x53 keypad

kbd_shift:
    db 0,27,'!','@','#','$','%','^','&','*'       ; 0x00-0x09
    db '(',')','_','+',8,9                         ; 0x0A-0x0F
    db 'Q','W','E','R','T','Y','U','I','O','P'    ; 0x10-0x19
    db '{','}',13,0                                ; 0x1A-0x1D
    db 'A','S','D','F','G','H','J','K','L',':'    ; 0x1E-0x27
    db 34,'~',0,'|'                                ; 0x28-0x2B
    db 'Z','X','C','V','B','N','M','<','>','?'    ; 0x2C-0x35
    db 0,'*',0,' '                                 ; 0x36-0x39
    times 0x47-0x3A db 0                           ; 0x3A-0x46 unused
    db '7','8','9','-','4','5','6','+','1','2','3','0','.'  ; 0x47-0x53 keypad

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
fmt_new_label:      times 40 db 0     ; label being applied by the current 'fmt'
sys_reset_label_tmp: times 40 db 0    ; root label preserved across 'sys reset'
orig_label_buf:      times 40 db 0    ; scratch: a device's generated "diskN" label
orig_label_num_tmp:  times 12 db 0    ; scratch: decimal digits for gen_orig_label
fs_parent_scratch: times 512 db 0     ; staging for one full parent sector (512B)
mount_label:   times MAX_MOUNTS*32 db 0     ; label of each mounted volume
mount_device:  times MAX_MOUNTS db 0        ; device id each volume came from
mount_used:    times MAX_MOUNTS db 0        ; 1 = slot in use
; type sector = 512B per volume (base 0/256/512 with VOL_NODES=256), so this
; must span the max extent of a sector write: base + 512. node indices still
; index it by node (1 byte per node); the per-volume padding holds whatever
; the sector has. 512*(1+MAX_MOUNTS) stays comfortably >= MAX_NODES either way.
node_type:    times 512 * (1 + MAX_MOUNTS) db 0
node_parent:  times MAX_NODES dw 0
node_name:    times MAX_NODES*NAME_LEN db 0
node_content: times MAX_NODES*CONTENT_LEN db 0
node_next:    times MAX_NODES dw 0xFFFF   ; 0xFFFF = end of chain (or no chain)
; node_bin_len: exact byte count for files written via fs_write_binary_file,
; recorded on the file's head node only. Lets fs_read_binary_file copy back
; the precise length instead of guessing from NUL bytes (which real binary
; content - e.g. compiled .run programs - can legitimately contain).
; NOTE: not part of the on-disk SFFS format yet, so this resets on
; remount/reboot - a freshly compiled .run works immediately, but won't
; survive a reboot until this is added to the persisted layout too.
node_bin_len: times MAX_NODES dd 0

fs_loaded_from_disk: db 0
fs_disk_available:   db 1     ; optimistic default; cleared on first ATA failure
boot_device:         db 0     ; device id holding the OS volume - normally 0
                               ; (legacy ATA primary master), but fs_load moves
                               ; this to an AHCI slot (4+) when device 0 never
                               ; responds and a SATA disk was found instead
fs_name_too_long:    db 0     ; set by fs_create_node when a name won't fit
fs_layout_ver:       db 0     ; set by vol_read: 0=v2, 1=legacy v3 (64-node), 2=v4 (256-node)

mkfl_test_flag:      db 0     ; set by cmd_mkfl when -test appears in arg2/3/4
ALIGN 8
mkfl_content_ptr:     dq 0     ; points at the effective content string for -test reporting

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

; --- RTL8139 NIC driver state ---
nic_present:     db 0             ; 1 = NIC found and rings live
nic_pci_bus:     db 0
nic_pci_dev:     db 0
nic_pci_func:    db 0
ALIGN 4
nic_io_base:     dd 0             ; BAR0 I/O port base (RTL8139)
nic_driver_type: db 0             ; 0 = rtl8139, 1 = e1000; set by nic_init
ALIGN 4
nic_mmio_base:   dd 0             ; BAR0 MMIO physical base (e1000)
nic_rx_seen:     dd 0             ; diagnostic: raw frames seen since last reset
nic_mac:         times 6 db 0
nic_ip:          db 10, 0, 2, 15  ; static config (QEMU slirp defaults)
nic_mask:        db 255, 255, 255, 0
nic_gw:          db 10, 0, 2, 2
nic_dns:         db 10, 0, 2, 3
nic_capr:        dd 0             ; software RX read pointer (ring offset)
nic_ihl:         db 0             ; IPv4 header length (bytes) of current frame
nic_ip_id:       dw 0x4200        ; IPv4 identification counter
NIC_ARP_CACHE_ENTRIES equ 4
nic_arp_cache:   times NIC_ARP_CACHE_ENTRIES*10 db 0   ; per entry: 6B MAC + 4B IP
nic_arp_next:    db 0
nic_arp_tried:   db 0             ; unused now (nic_arp_resolve tracks its own
                                   ; round counters in registers) - kept so
                                   ; existing reset-on-init writes stay valid
nic_last_fail_reason: db 0        ; set by nic_arp_resolve on CF=1: 0 = raw
                                   ; broadcast TX itself failed (hardware/
                                   ; timeout - see nic_send_raw_rtl8168 diag),
                                   ; 1 = broadcast sent fine, just never got
                                   ; an ARP reply back in time
nic_last_tx_ctx: db 0             ; 0 = data/segment frame, 1 = ARP broadcast -
                                   ; set right before every nic_send_raw call so
                                   ; a failure dump can say which frame it was
nic_tx_desc:     db 0             ; C-mode TX descriptor currently in use (0..3)
nic_bounce_target: dd 0           ; IP the bounce/monitor loop is pinging
nic_echo_id:     dw 0x1234
nic_echo_seq:    dw 1
nic_echo_got:    db 0             ; 1 = matching echo reply received
nic_echo_retry:  db 0             ; bounce retry flag
nic_echo_seq_rcv: dw 0
nic_echo_src_ip: dd 0             ; source IP of the last matching reply
nic_dns_id:      dw 1
nic_dns_query_id: dw 0
nic_dns_done:    db 0
nic_dns_retry:   db 0
nic_dns_result:  dd 0
dhcp_xid:        dd 0
dhcp_offered_ip: dd 0
dhcp_done:       db 0
dhcp_retries:    db 0
dhcp_msg_type:   db 0      ; DHCP message type (53) seen in the last offer/ack
nic_diag_verbose: db 0     ; 1 = netpoll prints a summary of every frame it sees
nic_diag_rx_count: db 0    ; caps how many "rx: ..." lines netpoll will print
                           ; per dhcp/bounce attempt - on a real LAN with
                           ; constant background broadcast traffic this was
                           ; still unbounded even after the tx dump got
                           ; throttled, and could flood the screen across a
                           ; long multi-retry wait on its own
nic_dns_seen:    db 0      ; 1 = the router sent DHCP option 6 (DNS server)
                           ; at some point this lease - if it never does,
                           ; cmd_dhcp falls back to using the gateway as
                           ; DNS, since many consumer routers proxy DNS on
                           ; their own LAN IP without advertising option 6
nic_diag_tx_dumped: db 0   ; 1 = the full tx hex dump has already fired this
                           ; dhcp session - keeps retries from re-flooding
                           ; the screen with the same packet layout
mac_broadcast:   db 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF

; --- NIC buffers (all resb, identity-mapped, so linked = physical addr) ---
ALIGN 16
nic_rx_ring:     times NIC_RX_RING_SIZE db 0    ; 8KB DMA RX ring
ALIGN 16
nic_tx_buf:      times NIC_TX_BUF_SIZE db 0     ; 2KB frame build/DMA buffer
net_build_buf:   times 4096 db 0                ; dns query / udp / icmp / tcp build area

; --- e1000 descriptor rings + RX buffers (identity-mapped; the linked
; address doubles as the physical address the chip DMAs into/out of, same
; trick as nic_rx_ring/nic_tx_buf above) ---
ALIGN 16
e1000_rx_desc:   times E1000_RX_DESC_COUNT * 16 db 0
ALIGN 16
e1000_tx_desc:   times E1000_TX_DESC_COUNT * 16 db 0
ALIGN 16
e1000_rx_bufs:   times E1000_RX_DESC_COUNT * E1000_RX_BUF_SIZE db 0
ALIGN 4
e1000_rx_idx:    dd 0             ; software head: next descriptor to check for DD
e1000_tx_idx:    dd 0             ; next TX descriptor slot to use

; e1000_dev_ids: PCI device ids (vendor 0x8086) pci_find_e1000 matches
; against, spanning the common real-hardware e1000/e1000e generations:
; 82540/82541/82544/82545/82546/82547 (PCI/PCIe PRO/1000) and 82571-82583
; (server/desktop PRO/1000 PT/PM/GT). QEMU's "e1000" model reports 0x100E.
e1000_dev_ids:
    dw 0x100E, 0x100F, 0x1004, 0x1001, 0x1010, 0x1012, 0x1013, 0x1019
    dw 0x101D, 0x101E, 0x1026, 0x1027, 0x1028, 0x1075, 0x1076, 0x1077
    dw 0x1078, 0x107C, 0x105E, 0x105F, 0x1060, 0x108B, 0x108C, 0x109A
    dw 0x10B9, 0x10D3, 0x10EA, 0x10F5, 0x150C
E1000_DEV_ID_COUNT equ ($ - e1000_dev_ids) / 2

; --- RTL8168 descriptor rings + RX buffers (identity-mapped) ---
ALIGN 256
rtl_rx_desc:     times RTL_RX_DESC_COUNT * 16 db 0
ALIGN 256
rtl_tx_desc:     times RTL_TX_DESC_COUNT * 16 db 0
ALIGN 16
rtl_rx_bufs:     times RTL_RX_DESC_COUNT * RTL_RX_BUF_SIZE db 0
ALIGN 4
rtl_rx_idx:      dd 0             ; software head: next descriptor to check for OWN=0
rtl_tx_idx:      dd 0             ; next TX descriptor slot to use
nic_hwver_raw:   dd 0             ; raw TxConfig value captured right after
                                   ; reset, before our own TCR write - used
                                   ; to identify the exact chip revision
nic_tx_wait_start:   db 0         ; CMOS seconds value when the current TX
                                   ; wait began (nic_send_raw_rtl8168)
nic_tx_wait_elapsed: db 0         ; real wall-clock seconds actually spent
                                   ; waiting before the last TX failure was
                                   ; declared - objective proof of whether the
                                   ; wait budget genuinely ran out or something
                                   ; failed fast, instead of guessing from
                                   ; how long a failure "felt" on screen
nic_tx_wait_end:     db 0         ; raw rtc_sec_now() reading at the moment
                                   ; .rtks_err fires - printed alongside
                                   ; nic_tx_wait_start so a bad elapsed
                                   ; computation can be told apart from a
                                   ; genuinely-fast failure, instead of
                                   ; trusting the subtracted value alone
nic_tx_wait_ticks:   db 0         ; number of real second-boundary ticks
                                   ; actually observed by the wait loop
                                   ; before giving up (should be ~budget+1
                                   ; on a real timeout; a low number here
                                   ; means the loop exited some other way)

; rtl_dev_ids: PCI device ids (vendor 0x10EC) pci_find_rtl8168 matches
; against - the RTL8169-compatible C+ descriptor interface shared by the
; common real-hardware gigabit Realtek chips. Deliberately doesn't include
; the 2.5GbE RTL8125, which uses a different descriptor/register layout.
rtl_dev_ids:
    dw 0x8168, 0x8169, 0x8161, 0x8136
RTL_DEV_ID_COUNT equ ($ - rtl_dev_ids) / 2

nic_rx_frame:    times 1536 db 0                ; wrap-reassembly staging
nic_rx_len:      dd 0                           ; bytes in nic_rx_frame
dec_tmp_buf:     times 8 db 0
net_ip_str:      times 20 db 0

; --- minimal polled TCP engine state (Milestone C) ---
tcp_state:     db 0          ; 0 idle, 1 syn_sent, 2 established, 3 closed
tcp_retry:     db 0          ; retransmit round count in the current phase (0..TCP_MAX_RETRIES)
tcp_wait_ticks: db 0         ; whole-seconds left in the current wait round (see TCP_ROUND_SECS)
tcp_rx_got:    db 0          ; 1 = peer payload landed in tcp_rx_buf
tcp_fin_got:   db 0          ; 1 = peer sent FIN
tcp_rst_got:   db 0          ; 1 = peer sent RST
ALIGN 4
tcp_isn:       dd 0          ; our initial sequence number (SYN)
tcp_cur_seq:   dd 0          ; seq field used by the next outgoing segment
tcp_cur_ack:   dd 0          ; ack field used by the next outgoing segment
tcp_peer_seq:  dd 0          ; peer's ISN from the SYN-ACK
tcp_last_ack:  dd 0          ; ack number from the most recent peer segment
tcp_peer_ip:   dd 0
tcp_peer_port: dw 0
tcp_my_port:   dw 0
tcp_rx_len:    dd 0
tcp_tx_len:    dd 0
tcp_rx_prev:   dd 0          ; rx length at the previous idle-check tick
tcp_err_msg:   dq 0          ; ptr to the last tcp/http error message (0 = none)
tcp_dec_buf:   times 10 db 0
tcp_rx_buf:    times TCP_PAYLOAD_MAX db 0
tcp_tx_buf:    times TCP_PAYLOAD_MAX db 0

; --- HTTP take / give buffers (Milestone D) ---
http_host_buf:   times 64 db 0
http_path_buf:   times 128 db 0
http_port:       dw 0
http_body_len:   dd 0
http_tx_big:     times HTTP_TX_MAX db 0
http_rx_buf:     times HTTP_RX_BUF_SIZE db 0

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

alias_names:  times MAX_ALIASES*ALIAS_NAME_LEN db 0
alias_bodies: times MAX_ALIASES*ALIAS_BODY_LEN db 0
alias_used:   times MAX_ALIASES db 0
ali_name_tmp: times ALIAS_NAME_LEN db 0   ; scratch: name parsed by try_handle_ali_line
ali_body_tmp: times ALIAS_BODY_LEN db 0   ; scratch: body parsed by try_handle_ali_line
alias_match_idx: db 0                     ; set by dispatch before jmp cmd_alias_invoke
alias_depth:     db 0                     ; nested alias-invocation depth (recursion guard)
alias_loading:   db 0                     ; 1 while aliases_load is restoring from alias.sly
ALIGN 8
alias_sly_buf: times MAX_ALIASES*(ALIAS_NAME_LEN+ALIAS_BODY_LEN+8) db 0   ; serialized alias.sly content
str_ali_line_prefix: db "ali ", 0
str_single_space:    db " ", 0

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

; --- process table for rush scripts ---
MAX_PROCESSES equ 2   ; was 4; trimmed to fit the kernel's BSS under 0xA0000 -
                       ; the kernel image must end before the VGA adapter window
                       ; at physical 0xA0000 (base RAM tops out at 0x9FFFF).
proc_id:       times MAX_PROCESSES dw 0
proc_name:     times MAX_PROCESSES*32 db 0
proc_state:    times MAX_PROCESSES db 0    ; 0=free, 1=running, 2=killed
proc_next_pid: dw 1
proc_cur_slot: db 0                         ; slot index of currently running script
kill_flag:     db 0                         ; set by Esc key or prs kill
rr_content_ptr: dq 0                         ; cursor into script file content

; --- background (.run -back) process support ---
; A background .run is a Party program (the interpreter path, exactly like
; 'party file.pa') run cooperatively: it executes on its OWN private stack
; (proc_bg_stack) with its OWN parked interpreter state (proc_bg_ctx), and
; yields back to the shell after BG_QUANTUM statements so the prompt stays
; responsive. Output is redirected by putchar into the process's output
; ring (proc_bg_ring) while it runs, and 'prs peek' shows the last lines.
BG_RING_CAP   equ 4096          ; bytes of captured output per process
BG_SRC_MAX    equ 16384         ; max embedded source bytes for a -back script
BG_STACK_SIZE equ 8192          ; per-process private interpreter stack
BG_QUANTUM    equ 200           ; statements a background step may run

proc_bg:          times MAX_PROCESSES db 0    ; 1 = background party process
proc_bg_rsp:      times MAX_PROCESSES dq 0    ; saved private-stack pointer (resume IP on top)
proc_bg_ring_start: times MAX_PROCESSES dd 0  ; output ring read offset
proc_bg_ring_len:   times MAX_PROCESSES dd 0  ; output ring byte count
proc_bg_ring:     times MAX_PROCESSES*BG_RING_CAP db 0
proc_bg_src:      times MAX_PROCESSES*BG_SRC_MAX db 0
proc_bg_stack:    times MAX_PROCESSES*BG_STACK_SIZE db 0
proc_bg_ctx:      times MAX_PROCESSES*PARTY_CTX_SIZE db 0  ; parked interpreter state

bg_shell_rsp:       dq 0        ; shell stack pointer parked across a background step
bg_cur_slot:        db 0        ; slot currently being stepped (read by party_bg_suspend)
bg_stmt_idx:        dd 0        ; saved token cursor for a yielded background process
bg_stop_tok:        dd 0        ; saved stop token (r14) for a yielded background process
party_bg_quantum:   dd 0        ; statements left in the current background step
party_bg_active:    db 0        ; 1 while a background process is running (interpreter checks)
bg_capture_base:    dq 0        ; putchar redirection: base of the active output ring
bg_capture_start_ptr: dq 0      ; pointer to the ring's read-offset dword
bg_capture_len_ptr: dq 0        ; pointer to the ring's byte-count dword
bg_capture_max:     dq 0        ; ring capacity
bg_notice:          times 160 db 0   ; pending "process finished/killed" line
bg_notice_pending:  db 0        ; 1 while a notice is waiting to be printed
prs_peek_buf:       times BG_RING_CAP+1 db 0   ; linearized output for 'prs peek'
sched_slot:         db 0        ; round-robin cursor for the bg scheduler

; --- large staging buffers. A file can span a whole VOL_NODES-node volume slice, so
; these are sized to hold a full file's content (EDIT_MAX). Declared at the
; very end of the file, after all code, so any growth doesn't move anything. ---
fs_next_scratch: times 512 db 0     ; staging for one full node_next sector
fs_io_buf:  times EDIT_MAX db 0     ; editor + view/read/copy staging for multi-block files
