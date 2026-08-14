; ============================================================
;  ZIP.ASM  --  stored-mode (uncompressed) .zip pack / unpack
; ============================================================
; Scope decision (locked in up front, per this project's own
; convention of deciding before coding): this implements the ZIP
; container FORMAT only, using compression method 0 ("stored" - raw
; bytes, no compression math). Real DEFLATE compression/decompression
; is NOT implemented; it's a much larger, separate undertaking. The
; files this produces are still ordinary, valid .zip files - any
; unzip tool on any OS opens them fine, since "stored" is a normal,
; standard part of the format, not a proprietary shortcut. unpack
; extracts foreign archives too, as long as every entry in them also
; uses method 0; a DEFLATE'd entry is a clean, explicit refusal
; rather than garbage output.
;
; Commands added (kernel.asm wires these into dispatch + help text):
;   pack <folder>      writes <folder>.zip into the current directory
;   unpack <file.zip>   extracts into the current directory
;
; Depends on kernel.asm's fs_* API (fs_resolve_path, fs_find_child,
; fs_create_node, fs_read_binary_file, fs_write_binary_file,
; fs_file_len), the node_type/node_name/node_parent tables, and the
; shared str_len/str_copy/str_append/str_eq/int_to_str/print_string*
; helpers - the same primitives cmd_cpy/cmd_mkfl/take/give already
; use. Reuses fs_io_buf (EDIT_MAX bytes) as a one-file-at-a-time
; staging buffer while packing, the same way cmd_cat/edit do.
;
; A whole packed archive - or a whole archive being unpacked - is
; staged in zip_buf, a single EDIT_MAX (20480-byte) buffer, mirroring
; the same per-file size cap every other file operation in this OS
; already has (mkfl/edit/cat/take/give). A folder that packs to more
; than that, or a .zip bigger than that, is a clean "too big" error,
; not a silent truncation. ZIP_MAX_ENTRIES (64) is a similar soft
; cap on file COUNT per archive, mostly there so the fixed
; central-directory-descriptor table has a size at all.
;
; Known gaps / deferred (see phases.txt / CHANGELOG for the writeup):
;   - No compression (see scope decision above).
;   - No empty-folder entries: pack only emits entries for files: an
;     empty subfolder isn't represented in the archive at all (a
;     folder that contains no files anywhere in its subtree produces
;     no entries and therefore doesn't come back on unpack). Matches
;     the behavior of most real zip tools when run without an
;     explicit "add empty dirs" flag.
;   - Timestamps are a fixed placeholder (1980-01-01, 00:00:00) rather
;     than the file's real modification time - the RTC driver behind
;     `date`/`time` was left unwired here to keep this change scoped
;     to the container format itself; a later pass could feed it in.
;   - No -force flag: `pack` refuses if `<folder>.zip` already exists
;     in the current directory, and `unpack` overwrites a same-named
;     FILE in place but refuses if a same-named FOLDER is in the way.
;   - Not tested in a real boot/QEMU environment - only nasm
;     syntax-checked standalone (no boot tree available here). Smoke
;     test before relying on this: pack a folder with a nested
;     subfolder and a couple of files, unpack it into an empty
;     folder elsewhere, and diff the result; also try unpacking a
;     .zip produced by a real desktop unzip tool (stored mode only)
;     to check real-world compatibility.
; ============================================================

ZIP_MAX_ENTRIES equ 64              ; max files in one archive (soft cap)
ZIP_NAME_MAX    equ 128             ; max bytes for one entry's full relative path
ZIP_PATH_MAX    equ 96              ; max bytes for the walk's path-prefix scratch
ZIP_LFH_SIZE    equ 30              ; local file header size
ZIP_CDH_SIZE    equ 46              ; central directory file header size
ZIP_EOCD_SIZE   equ 22              ; end-of-central-directory record size

; ------------------------------------------------------------
; cmd_pack: `pack <folder>` -> writes <folder>.zip into cur_dir
; ------------------------------------------------------------
cmd_pack:
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
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .not_found
    cmp byte [node_type + rax], 1
    je .is_folder
    mov rsi, msg_pack_not_folder
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.is_folder:
    mov r12, rax                     ; source folder node

    ; output name = "<leaf>.zip"
    mov rsi, leaf1_buf
    mov rdi, zip_out_name
    call str_copy
    mov rdi, zip_out_name
    mov rsi, str_dot_zip
    call str_append

    mov rax, [cur_dir]
    mov rsi, zip_out_name
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .already_exists

    mov dword [zip_cursor], 0
    mov dword [zip_entry_count], 0
    mov byte [zip_path_buf], 0
    mov dword [zip_path_len], 0

    mov rax, r12
    call zip_walk_folder
    cmp al, 1
    je .ret                          ; specific error already printed

    call zip_write_central_dir
    cmp al, 1
    je .ret

    mov rax, [cur_dir]
    mov rsi, zip_out_name
    mov r10, 2                       ; file
    call fs_create_node
    cmp rax, -1
    je .create_failed
    mov r9, rax
    mov eax, [zip_cursor]
    mov rcx, rax
    mov rsi, zip_buf
    mov rax, r9
    call fs_write_binary_file
    jc .write_failed

    mov rsi, msg_pack_ok
    call print_string
    mov eax, [zip_entry_count]
    mov rdi, calc_out_buf
    call int_to_str
    mov rsi, calc_out_buf
    call print_string
    mov rsi, msg_pack_ok2
    call print_string
    mov rsi, zip_out_name
    call print_string
    mov rsi, newline_str
    call print_string
    call maybe_auto_sync
.ret:
    ret
.already_exists:
    mov rsi, msg_pack_exists
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, zip_out_name
    call print_string
    mov rsi, newline_str
    call print_string
    ret
.create_failed:
    mov rsi, msg_pack_create_failed
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.write_failed:
    mov rsi, msg_pack_write_failed
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

; zip_walk_folder: rax = folder node index. Recursively visits every
; child of that folder: a file gets appended as a zip entry (named
; using zip_path_buf as its relative-path prefix); a subfolder
; recurses with the prefix extended by "<name>/". zip_path_buf /
; zip_path_len are shared depth-first-search state - restored to the
; length seen on entry before each sibling is handled, so one
; sibling's subtree can't leak its prefix into the next. Returns
; al=0 on success, al=1 if an error was hit (message already
; printed by whichever helper hit it).
zip_walk_folder:
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
    mov r14, rax                     ; this folder's node index
    mov r13d, [zip_path_len]         ; prefix length on entry
    xor r12, r12                     ; scan cursor over all nodes
.loop:
    cmp r12, MAX_NODES
    jae .done_ok
    cmp byte [node_type + r12], 0
    je .next
    movzx rax, word [node_parent + r12*2]
    cmp rax, r14
    jne .next
    mov dword [zip_path_len], r13d   ; restore prefix before this child
    cmp byte [node_type + r12], 2
    je .handle_file
    mov rax, r12
    call zip_path_push
    cmp al, 1
    je .fail
    mov rax, r12
    call zip_walk_folder
    cmp al, 1
    je .fail
    jmp .next
.handle_file:
    mov rax, r12
    call zip_add_entry
    cmp al, 1
    je .fail
.next:
    inc r12
    jmp .loop
.done_ok:
    mov dword [zip_path_len], r13d
    xor al, al
    jmp .out
.fail:
    mov al, 1
.out:
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

; zip_path_push: rax = folder node index. Appends "<name>/" onto
; zip_path_buf at the current zip_path_len, bounds-checked against
; ZIP_PATH_MAX. Returns al=0 and an updated zip_path_len on success;
; al=1 (message already printed) if it wouldn't fit.
zip_path_push:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, rax
    imul rbx, NAME_LEN
    lea rsi, [node_name + rbx]
    call str_len                     ; rax = name length
    mov rdx, rax
    mov ecx, [zip_path_len]
    mov rax, rcx
    add rax, rdx
    add rax, 2                       ; '/' + NUL
    cmp rax, ZIP_PATH_MAX
    ja .toolong
    lea rdi, [zip_path_buf + rcx]
    call str_copy                    ; copies name + NUL onto the prefix
    lea rdi, [zip_path_buf + rcx]
    add rdi, rdx                     ; -> the NUL str_copy just wrote
    mov byte [rdi], '/'
    inc rdi
    mov byte [rdi], 0
    mov eax, ecx
    add eax, edx
    inc eax
    mov [zip_path_len], eax
    xor al, al
    jmp .out
.toolong:
    mov rsi, msg_pack_path_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    mov al, 1
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; zip_add_entry: rax = file node index. Appends this file to zip_buf
; as a stored local file header + name + data at the current
; zip_cursor, using zip_path_buf as the entry's path prefix, and
; records a central-directory descriptor for it. Returns al=0 on
; success, al=1 on error (message already printed): too many
; entries, a name too long to fit ZIP_NAME_MAX, or the archive would
; grow past EDIT_MAX bytes.
zip_add_entry:
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
    mov r12, rax                     ; file node index
    mov eax, [zip_entry_count]
    cmp eax, ZIP_MAX_ENTRIES
    jae .too_many
    mov r13, rax                     ; this entry's slot index

    mov rax, r13
    imul rax, ZIP_NAME_MAX
    lea r8, [zip_names_buf + rax]    ; r8 = this slot's name buffer
    mov rsi, zip_path_buf
    mov rdi, r8
    call str_copy                    ; slot = "<prefix>" ("" or ".../")
    mov rdi, r8
    mov rbx, r12
    imul rbx, NAME_LEN
    lea rsi, [node_name + rbx]
    call str_append                  ; slot = "<prefix><filename>"

    mov rsi, r8
    call str_len
    cmp rax, ZIP_NAME_MAX
    jae .name_too_long
    mov r9, rax                      ; r9 = full entry name length

    mov rax, r12
    call fs_file_len
    mov r10, rax                     ; r10 = file length

    mov eax, [zip_cursor]
    add rax, ZIP_LFH_SIZE
    add rax, r9
    add rax, r10
    cmp rax, EDIT_MAX
    ja .too_big

    mov rax, r12
    mov rdi, fs_io_buf
    call fs_read_binary_file

    mov rsi, fs_io_buf
    mov rcx, r10
    call zip_crc32                   ; eax = crc32

    mov ebx, [zip_cursor]
    lea rdi, [zip_buf + rbx]
    mov dword [rdi], 0x04034B50
    mov word  [rdi+4], 20
    mov word  [rdi+6], 0
    mov word  [rdi+8], 0
    mov word  [rdi+10], 0            ; DOS time (fixed placeholder)
    mov word  [rdi+12], 0x0021       ; DOS date 1980-01-01 (fixed placeholder)
    mov [rdi+14], eax                ; crc32
    mov [rdi+18], r10d               ; compressed size == uncompressed (stored)
    mov [rdi+22], r10d               ; uncompressed size
    mov word  [rdi+26], r9w
    mov word  [rdi+28], 0

    mov [zip_entry_crc + r13*4], eax
    mov [zip_entry_size + r13*4], r10d
    mov [zip_entry_off + r13*4], ebx
    mov [zip_entry_namelen + r13*4], r9d

    lea rdi, [rdi + ZIP_LFH_SIZE]
    mov rsi, r8
    mov rcx, r9
    cld
    rep movsb                        ; entry name
    mov rsi, fs_io_buf
    mov rcx, r10
    rep movsb                        ; file data

    inc dword [zip_entry_count]
    mov eax, ebx
    add eax, ZIP_LFH_SIZE
    add eax, r9d
    add eax, r10d
    mov [zip_cursor], eax

    xor al, al
    jmp .out
.too_many:
    mov rsi, msg_pack_too_many
    mov al, ATTR_ERROR
    call print_string_attr
    mov al, 1
    jmp .out
.name_too_long:
    mov rsi, msg_pack_name_too_long
    mov al, ATTR_ERROR
    call print_string_attr
    mov al, 1
    jmp .out
.too_big:
    mov rsi, msg_pack_too_big
    mov al, ATTR_ERROR
    call print_string_attr
    mov al, 1
.out:
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

; zip_write_central_dir: writes one 46-byte central-directory header
; + name per recorded entry, then the End Of Central Directory
; record, continuing at the current zip_cursor. Returns al=0 on
; success, al=1 if it would overflow EDIT_MAX (message printed).
zip_write_central_dir:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    push r12
    push r13
    mov r12d, [zip_cursor]           ; central directory start offset
    xor r13, r13                     ; entry index
.loop:
    mov eax, [zip_entry_count]
    cmp r13, rax
    jae .entries_done

    mov r9d, [zip_entry_namelen + r13*4]
    mov eax, [zip_cursor]
    add rax, ZIP_CDH_SIZE
    add rax, r9
    cmp rax, EDIT_MAX
    ja .too_big

    mov ebx, [zip_cursor]
    lea rdi, [zip_buf + rbx]
    mov dword [rdi], 0x02014B50
    mov word  [rdi+4], 20
    mov word  [rdi+6], 20
    mov word  [rdi+8], 0
    mov word  [rdi+10], 0
    mov word  [rdi+12], 0
    mov word  [rdi+14], 0x0021
    mov eax, [zip_entry_crc + r13*4]
    mov [rdi+16], eax
    mov eax, [zip_entry_size + r13*4]
    mov [rdi+20], eax
    mov [rdi+24], eax
    mov word  [rdi+28], r9w
    mov word  [rdi+30], 0
    mov word  [rdi+32], 0
    mov word  [rdi+34], 0
    mov word  [rdi+36], 0
    mov dword [rdi+38], 0
    mov eax, [zip_entry_off + r13*4]
    mov [rdi+42], eax

    lea rdi, [rdi + ZIP_CDH_SIZE]
    mov rax, r13
    imul rax, ZIP_NAME_MAX
    lea rsi, [zip_names_buf + rax]
    mov rcx, r9
    cld
    rep movsb

    mov eax, ebx
    add eax, ZIP_CDH_SIZE
    add eax, r9d
    mov [zip_cursor], eax

    inc r13
    jmp .loop
.entries_done:
    mov eax, [zip_cursor]
    add rax, ZIP_EOCD_SIZE
    cmp rax, EDIT_MAX
    ja .too_big

    mov r10d, [zip_cursor]           ; central directory size
    sub r10d, r12d
    mov ebx, [zip_cursor]
    lea rdi, [zip_buf + rbx]
    mov dword [rdi], 0x06054B50
    mov word  [rdi+4], 0
    mov word  [rdi+6], 0
    mov eax, [zip_entry_count]
    mov word  [rdi+8], ax
    mov word  [rdi+10], ax
    mov [rdi+12], r10d
    mov [rdi+16], r12d
    mov word  [rdi+20], 0

    mov eax, ebx
    add eax, ZIP_EOCD_SIZE
    mov [zip_cursor], eax
    xor al, al
    jmp .out
.too_big:
    mov rsi, msg_pack_too_big
    mov al, ATTR_ERROR
    call print_string_attr
    mov al, 1
.out:
    pop r13
    pop r12
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; cmd_unpack: `unpack <file.zip>` -> extracts into cur_dir
; ------------------------------------------------------------
cmd_unpack:
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
    mov rsi, leaf1_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .not_found
    cmp byte [node_type + rax], 2
    je .is_file
    mov rsi, msg_unpack_not_file
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.is_file:
    mov r12, rax                     ; zip file node
    call fs_file_len
    cmp rax, ZIP_EOCD_SIZE
    jb .bad_zip
    cmp rax, EDIT_MAX
    ja .too_big
    mov [zip_unpack_len], eax
    mov rax, r12
    mov rdi, zip_buf
    call fs_read_binary_file

    call zip_find_eocd
    cmp al, 1
    je .bad_zip

    call zip_unpack_validate
    cmp al, 1
    je .ret

    mov dword [zip_extracted], 0
    call zip_unpack_extract
    cmp al, 1
    je .ret

    mov rsi, msg_unpack_ok
    call print_string
    mov eax, [zip_extracted]
    mov rdi, calc_out_buf
    call int_to_str
    mov rsi, calc_out_buf
    call print_string
    mov rsi, msg_unpack_ok2
    call print_string
    mov rsi, arg1_buf
    call print_string
    mov rsi, newline_str
    call print_string
    call maybe_auto_sync
.ret:
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
.bad_zip:
    mov rsi, msg_unpack_bad
    mov al, ATTR_ERROR
    call print_string_attr
    ret
.too_big:
    mov rsi, msg_unpack_too_big
    mov al, ATTR_ERROR
    call print_string_attr
    ret

; zip_find_eocd: scans zip_buf backward from zip_unpack_len-22 for the
; End Of Central Directory signature (tolerates a short/no archive
; comment - this OS never writes one, but real-world tools sometimes
; do). On success stores the entry count in zip_unpack_total and the
; central directory's offset in zip_unpack_cdoff, returns al=0.
; Returns al=1 if no EOCD record is found anywhere in the buffer.
zip_find_eocd:
    push rbx
    push rsi
    mov eax, [zip_unpack_len]
    sub eax, ZIP_EOCD_SIZE
    jl .not_found
    movsxd rbx, eax
.scan:
    cmp rbx, 0
    jl .not_found
    lea rsi, [zip_buf + rbx]
    mov eax, [rsi]
    cmp eax, 0x06054B50
    je .found
    dec rbx
    jmp .scan
.found:
    lea rsi, [zip_buf + rbx]
    movzx eax, word [rsi+10]
    mov [zip_unpack_total], eax
    mov eax, [rsi+16]
    mov [zip_unpack_cdoff], eax
    xor al, al
    jmp .out
.not_found:
    mov al, 1
.out:
    pop rsi
    pop rbx
    ret

; zip_unpack_validate: walks the central directory (zip_unpack_total
; entries starting at zip_unpack_cdoff), checking each header's
; signature and that its compression method is 0 (stored). Runs
; before anything is extracted, so an archive containing even one
; compressed entry is rejected cleanly with nothing written, rather
; than extracting partway. Returns al=0 if every entry is stored and
; well-formed, al=1 otherwise (message already printed).
zip_unpack_validate:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r12
    push r13
    mov r12d, [zip_unpack_cdoff]
    mov r13d, [zip_unpack_total]
    xor rbx, rbx
.loop:
    cmp rbx, r13
    jae .ok
    mov eax, r12d
    add eax, ZIP_CDH_SIZE
    cmp eax, [zip_unpack_len]
    ja .bad
    lea rsi, [zip_buf + r12]
    mov eax, [rsi]
    cmp eax, 0x02014B50
    jne .bad
    movzx rax, word [rsi+10]
    test rax, rax
    jnz .unsupported
    movzx r8, word [rsi+28]
    movzx r9, word [rsi+30]
    movzx r10, word [rsi+32]
    mov eax, r12d
    add eax, ZIP_CDH_SIZE
    add eax, r8d
    add eax, r9d
    add eax, r10d
    cmp eax, [zip_unpack_len]
    ja .bad
    mov r12d, eax
    inc rbx
    jmp .loop
.ok:
    xor al, al
    jmp .out
.bad:
    mov rsi, msg_unpack_bad
    mov al, ATTR_ERROR
    call print_string_attr
    mov al, 1
    jmp .out
.unsupported:
    mov rsi, msg_unpack_compressed
    mov al, ATTR_ERROR
    call print_string_attr
    mov al, 1
.out:
    pop r13
    pop r12
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; zip_resolve_create_parent: rax = base dir node index, rsi = a
; relative path whose interior separators are '/' (e.g.
; "docs/sub/file.txt"; no leading or trailing slash). Walks it left
; to right, creating any missing FOLDER components as it goes (an
; existing folder of the right name is reused; an existing FILE of
; that name is a hard collision, not silently replaced). Copies the
; final path component - the leaf name - into zip_leaf_buf. Returns
; rax = the resulting parent folder's node index, or -1 on a name
; collision or a full filesystem (message NOT printed here - the
; caller knows which entry this was for and prints accordingly).
zip_resolve_create_parent:
    push rbx
    push rcx
    push rdx
    push rdi
    push r10
    push r12
    mov rbx, rax                     ; rbx = current dir
    mov r12, rsi                     ; r12 = path cursor
.next_comp:
    mov rdi, zip_comp_buf
.copy_loop:
    mov al, [r12]
    cmp al, 0
    je .comp_done
    cmp al, '/'
    je .comp_done
    mov [rdi], al
    inc r12
    inc rdi
    jmp .copy_loop
.comp_done:
    mov byte [rdi], 0
    cmp byte [r12], '/'
    jne .is_leaf
    inc r12                          ; skip the '/'
    mov rax, rbx
    mov rsi, zip_comp_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    je .create_folder
    cmp byte [node_type + rax], 1
    je .have_folder
    jmp .fail                        ; a file is where a folder needs to go
.create_folder:
    mov rax, rbx
    mov rsi, zip_comp_buf
    mov r10, 1
    call fs_create_node
    cmp rax, -1
    je .fail
.have_folder:
    mov rbx, rax
    jmp .next_comp
.is_leaf:
    mov rsi, zip_comp_buf
    mov rdi, zip_leaf_buf
    call str_copy
    mov rax, rbx
    jmp .out
.fail:
    mov rax, -1
.out:
    pop r12
    pop r10
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; zip_unpack_extract: walks the (already-validated, all-stored)
; central directory, recreating folders under cur_dir as needed and
; writing each file's content, then verifies each file's CRC-32
; against the value recorded in its header. A CRC mismatch is
; reported and that one file is skipped (not counted in
; zip_extracted) rather than aborting the whole unpack - by this
; point the headers are already known well-formed, so a mismatch
; means the DATA bytes are corrupt, which is a per-file concern.
; Returns al=0 unless a destination folder/file genuinely couldn't be
; created (name collision or full filesystem), in which case al=1
; and a message is printed.
zip_unpack_extract:
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
    mov r12d, [zip_unpack_cdoff]
    mov r13d, [zip_unpack_total]
    xor r14, r14                     ; entries processed
.loop:
    cmp r14, r13
    jae .done_ok
    lea rsi, [zip_buf + r12]
    movzx r8, word [rsi+28]          ; filename length
    movzx r9, word [rsi+30]          ; extra length
    movzx r10, word [rsi+32]         ; comment length
    mov eax, 46
    add eax, r8d
    add eax, r9d
    add eax, r10d
    mov [zip_tmp_advance], eax       ; distance to the NEXT cd record

    mov eax, [rsi+16]
    mov [zip_tmp_crc], eax
    mov eax, [rsi+24]
    mov [zip_tmp_size], eax
    mov eax, [rsi+42]
    mov [zip_tmp_localoff], eax

    cmp r8, ZIP_NAME_MAX
    jae .fail
    lea rsi, [rsi + 46]
    mov rdi, zip_entryname_buf
    mov rcx, r8
    cld
    rep movsb
    mov byte [rdi], 0

    ; locate the file data via the LOCAL header (its own filename/
    ; extra lengths can differ from the central directory's copy)
    mov eax, [zip_tmp_localoff]
    lea rsi, [zip_buf + rax]
    movzx rbx, word [rsi+26]
    movzx rcx, word [rsi+28]
    add rax, 30
    add rax, rbx
    add rax, rcx
    mov [zip_tmp_dataoff], eax

    mov rax, [cur_dir]
    mov rsi, zip_entryname_buf
    call zip_resolve_create_parent
    cmp rax, -1
    je .fail
    mov r15, rax                     ; destination parent folder

    mov rax, r15
    mov rsi, zip_leaf_buf
    mov r10, -1
    call fs_find_child
    cmp rax, -1
    jne .maybe_reuse
    mov rax, r15
    mov rsi, zip_leaf_buf
    mov r10, 2
    call fs_create_node
    cmp rax, -1
    je .fail
    jmp .have_node
.maybe_reuse:
    cmp byte [node_type + rax], 2
    jne .fail                        ; a same-named folder is in the way
.have_node:
    mov rbx, rax                     ; destination file node
    mov eax, [zip_tmp_dataoff]
    lea rsi, [zip_buf + rax]
    mov ecx, [zip_tmp_size]
    mov rax, rbx
    call fs_write_binary_file

    mov eax, [zip_tmp_dataoff]
    lea rsi, [zip_buf + rax]
    mov ecx, [zip_tmp_size]
    call zip_crc32
    cmp eax, [zip_tmp_crc]
    jne .crc_mismatch
    inc dword [zip_extracted]
    jmp .advance
.crc_mismatch:
    mov rsi, msg_unpack_crc_warn
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, zip_entryname_buf
    call print_string
    mov rsi, newline_str
    call print_string
.advance:
    mov eax, [zip_tmp_advance]
    add r12, rax
    inc r14
    jmp .loop
.done_ok:
    xor al, al
    jmp .out
.fail:
    mov rsi, msg_unpack_create_failed
    mov al, ATTR_ERROR
    call print_string_attr
    mov rsi, zip_entryname_buf
    call print_string
    mov rsi, newline_str
    call print_string
    mov al, 1
.out:
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

; zip_crc32: rsi = buffer, rcx = length. Returns eax = CRC-32 (the
; standard PKZIP/zlib/gzip polynomial 0xEDB88320, reflected,
; init/final XOR 0xFFFFFFFF), byte-at-a-time via zip_crc32_table.
zip_crc32:
    push rbx
    push rcx
    push rdx
    push rsi
    mov eax, 0xFFFFFFFF
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
    xor eax, 0xFFFFFFFF
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; data
; ------------------------------------------------------------
str_pack:    db "pack", 0
str_unpack:  db "unpack", 0
str_dot_zip: db ".zip", 0

msg_pack_not_folder:      db "pack: not a folder: ", 0
msg_pack_exists:           db "pack: already exists (del it first): ", 0
msg_pack_too_many:         db "pack: too many files in this folder (max 64)", 10, 0
msg_pack_name_too_long:    db "pack: a relative path is too long to pack", 10, 0
msg_pack_path_too_long:    db "pack: folder nesting is too deep to pack", 10, 0
msg_pack_too_big:          db "pack: archive would exceed the 40 KB file cap", 10, 0
msg_pack_create_failed:    db "pack: could not create the output file (filesystem full?)", 10, 0
msg_pack_write_failed:     db "pack: could not write the output file (filesystem full?)", 10, 0
msg_pack_ok:                db "pack: packed ", 0
msg_pack_ok2:               db " file(s) into ", 0

msg_unpack_not_file:       db "unpack: not a file: ", 0
msg_unpack_bad:             db "unpack: not a valid stored .zip file (or truncated)", 10, 0
msg_unpack_too_big:         db "unpack: file exceeds the 40 KB read cap", 10, 0
msg_unpack_compressed:      db "unpack: archive contains a compressed entry (DEFLATE) - only stored (uncompressed) .zip files are supported", 10, 0
msg_unpack_crc_warn:        db "unpack: CRC mismatch, skipped: ", 0
msg_unpack_create_failed:   db "unpack: could not create: ", 0
msg_unpack_ok:               db "unpack: extracted ", 0
msg_unpack_ok2:              db " file(s) from ", 0

; --- packing state ---
zip_out_name:        times NAME_LEN+8 db 0   ; "<folder>.zip"
zip_cursor:           dd 0
zip_path_buf:         times ZIP_PATH_MAX db 0
zip_path_len:         dd 0
zip_entry_count:      dd 0
zip_entry_crc:        times ZIP_MAX_ENTRIES dd 0
zip_entry_size:       times ZIP_MAX_ENTRIES dd 0
zip_entry_off:         times ZIP_MAX_ENTRIES dd 0
zip_entry_namelen:    times ZIP_MAX_ENTRIES dd 0
zip_names_buf:         times ZIP_MAX_ENTRIES*ZIP_NAME_MAX db 0

; --- unpacking state ---
zip_unpack_len:        dd 0
zip_unpack_total:      dd 0
zip_unpack_cdoff:      dd 0
zip_extracted:          dd 0
zip_entryname_buf:     times ZIP_NAME_MAX db 0
zip_comp_buf:           times NAME_LEN+1 db 0
zip_leaf_buf:           times NAME_LEN+1 db 0
zip_tmp_crc:             dd 0
zip_tmp_size:            dd 0
zip_tmp_localoff:        dd 0
zip_tmp_dataoff:         dd 0
zip_tmp_advance:         dd 0

; --- shared staging buffer: one whole archive, packing or unpacking ---
zip_buf: times EDIT_MAX db 0

; --- standard CRC-32 lookup table (poly 0xEDB88320, reflected) ---
zip_crc32_table:
    dd 0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA, 0x076DC419, 0x706AF48F, 0xE963A535, 0x9E6495A3
    dd 0x0EDB8832, 0x79DCB8A4, 0xE0D5E91E, 0x97D2D988, 0x09B64C2B, 0x7EB17CBD, 0xE7B82D07, 0x90BF1D91
    dd 0x1DB71064, 0x6AB020F2, 0xF3B97148, 0x84BE41DE, 0x1ADAD47D, 0x6DDDE4EB, 0xF4D4B551, 0x83D385C7
    dd 0x136C9856, 0x646BA8C0, 0xFD62F97A, 0x8A65C9EC, 0x14015C4F, 0x63066CD9, 0xFA0F3D63, 0x8D080DF5
    dd 0x3B6E20C8, 0x4C69105E, 0xD56041E4, 0xA2677172, 0x3C03E4D1, 0x4B04D447, 0xD20D85FD, 0xA50AB56B
    dd 0x35B5A8FA, 0x42B2986C, 0xDBBBC9D6, 0xACBCF940, 0x32D86CE3, 0x45DF5C75, 0xDCD60DCF, 0xABD13D59
    dd 0x26D930AC, 0x51DE003A, 0xC8D75180, 0xBFD06116, 0x21B4F4B5, 0x56B3C423, 0xCFBA9599, 0xB8BDA50F
    dd 0x2802B89E, 0x5F058808, 0xC60CD9B2, 0xB10BE924, 0x2F6F7C87, 0x58684C11, 0xC1611DAB, 0xB6662D3D
    dd 0x76DC4190, 0x01DB7106, 0x98D220BC, 0xEFD5102A, 0x71B18589, 0x06B6B51F, 0x9FBFE4A5, 0xE8B8D433
    dd 0x7807C9A2, 0x0F00F934, 0x9609A88E, 0xE10E9818, 0x7F6A0DBB, 0x086D3D2D, 0x91646C97, 0xE6635C01
    dd 0x6B6B51F4, 0x1C6C6162, 0x856530D8, 0xF262004E, 0x6C0695ED, 0x1B01A57B, 0x8208F4C1, 0xF50FC457
    dd 0x65B0D9C6, 0x12B7E950, 0x8BBEB8EA, 0xFCB9887C, 0x62DD1DDF, 0x15DA2D49, 0x8CD37CF3, 0xFBD44C65
    dd 0x4DB26158, 0x3AB551CE, 0xA3BC0074, 0xD4BB30E2, 0x4ADFA541, 0x3DD895D7, 0xA4D1C46D, 0xD3D6F4FB
    dd 0x4369E96A, 0x346ED9FC, 0xAD678846, 0xDA60B8D0, 0x44042D73, 0x33031DE5, 0xAA0A4C5F, 0xDD0D7CC9
    dd 0x5005713C, 0x270241AA, 0xBE0B1010, 0xC90C2086, 0x5768B525, 0x206F85B3, 0xB966D409, 0xCE61E49F
    dd 0x5EDEF90E, 0x29D9C998, 0xB0D09822, 0xC7D7A8B4, 0x59B33D17, 0x2EB40D81, 0xB7BD5C3B, 0xC0BA6CAD
    dd 0xEDB88320, 0x9ABFB3B6, 0x03B6E20C, 0x74B1D29A, 0xEAD54739, 0x9DD277AF, 0x04DB2615, 0x73DC1683
    dd 0xE3630B12, 0x94643B84, 0x0D6D6A3E, 0x7A6A5AA8, 0xE40ECF0B, 0x9309FF9D, 0x0A00AE27, 0x7D079EB1
    dd 0xF00F9344, 0x8708A3D2, 0x1E01F268, 0x6906C2FE, 0xF762575D, 0x806567CB, 0x196C3671, 0x6E6B06E7
    dd 0xFED41B76, 0x89D32BE0, 0x10DA7A5A, 0x67DD4ACC, 0xF9B9DF6F, 0x8EBEEFF9, 0x17B7BE43, 0x60B08ED5
    dd 0xD6D6A3E8, 0xA1D1937E, 0x38D8C2C4, 0x4FDFF252, 0xD1BB67F1, 0xA6BC5767, 0x3FB506DD, 0x48B2364B
    dd 0xD80D2BDA, 0xAF0A1B4C, 0x36034AF6, 0x41047A60, 0xDF60EFC3, 0xA867DF55, 0x316E8EEF, 0x4669BE79
    dd 0xCB61B38C, 0xBC66831A, 0x256FD2A0, 0x5268E236, 0xCC0C7795, 0xBB0B4703, 0x220216B9, 0x5505262F
    dd 0xC5BA3BBE, 0xB2BD0B28, 0x2BB45A92, 0x5CB36A04, 0xC2D7FFA7, 0xB5D0CF31, 0x2CD99E8B, 0x5BDEAE1D
    dd 0x9B64C2B0, 0xEC63F226, 0x756AA39C, 0x026D930A, 0x9C0906A9, 0xEB0E363F, 0x72076785, 0x05005713
    dd 0x95BF4A82, 0xE2B87A14, 0x7BB12BAE, 0x0CB61B38, 0x92D28E9B, 0xE5D5BE0D, 0x7CDCEFB7, 0x0BDBDF21
    dd 0x86D3D2D4, 0xF1D4E242, 0x68DDB3F8, 0x1FDA836E, 0x81BE16CD, 0xF6B9265B, 0x6FB077E1, 0x18B74777
    dd 0x88085AE6, 0xFF0F6A70, 0x66063BCA, 0x11010B5C, 0x8F659EFF, 0xF862AE69, 0x616BFFD3, 0x166CCF45
    dd 0xA00AE278, 0xD70DD2EE, 0x4E048354, 0x3903B3C2, 0xA7672661, 0xD06016F7, 0x4969474D, 0x3E6E77DB
    dd 0xAED16A4A, 0xD9D65ADC, 0x40DF0B66, 0x37D83BF0, 0xA9BCAE53, 0xDEBB9EC5, 0x47B2CF7F, 0x30B5FFE9
    dd 0xBDBDF21C, 0xCABAC28A, 0x53B39330, 0x24B4A3A6, 0xBAD03605, 0xCDD70693, 0x54DE5729, 0x23D967BF
    dd 0xB3667A2E, 0xC4614AB8, 0x5D681B02, 0x2A6F2B94, 0xB40BBE37, 0xC30C8EA1, 0x5A05DF1B, 0x2D02EF8D
