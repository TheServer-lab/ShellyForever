; ============================================================
;  ShellyForever  --  layout.inc
;  Shared physical-memory / disk-layout constants for the two-stage boot
;  process. %include'd by boot.asm, stage2.asm, and kernel.asm so the
;  three separately-assembled binaries can never drift out of sync the
;  way KERNEL_SECTORS/FS_LBA_START used to (see boot.asm's old comments,
;  pre-relocation, in git history: "the two are not shared constants, so
;  nothing else will catch a drift between them" - this file is the fix
;  for that, not just for the ceiling bug).
; ============================================================

; ---- disk layout (LBA, 512B sectors; LBA 0 is the MBR = boot.asm) ----
STAGE2_LBA        equ 1                       ; stage2.bin starts right after the MBR

; stage2.bin is the splash + relocator + real->protected->long-mode
; transition ONLY - not the whole OS anymore, so it has nothing like the
; old ~1216-sector conventional-memory ceiling to worry about. It still
; loads flat into conventional memory at 0x8000 in real mode (BIOS video/
; keyboard calls are needed for the splash and for the disk reads that
; relocate the real kernel), so it must still stay clear of the 0xA0000
; VGA window - but that is enormous headroom compared to what's actually
; here. Measured build is ~129 sectors (the 320x200 splash image, at
; 64768 bytes/~127 sectors, is almost all of that - the loader code
; itself is under 1000 bytes). 256 leaves roughly 2x margin, i.e. room
; for the splash image to grow a fair amount, or the loader code to grow
; a lot, without touching this constant again. If stage2 ever needs to
; grow past ~1200 sectors (a much bigger splash image, say), the same
; "load above 1MB" fix applies to it too, but that is not a realistic
; concern for a splash screen + loader.
STAGE2_SECTORS    equ 256

KERNEL_BODY_LBA     equ STAGE2_LBA + STAGE2_SECTORS
; kernel_body.bin is the actual OS (everything that used to be kernel.asm
; after splash.asm's %include - party/tcp/http/crypto/tls/https/browse/
; mouse/zip/install and all). It is loaded and relocated above 1MB in
; chunks by stage2 (see stage2.asm's relocate_kernel_body), so it is NOT
; bounded by conventional memory at all - the only real ceiling left is
; expand_identity_map's 4GB identity map (kernel_entry runs long before
; that map is even needed to be complete for the kernel's own code/data,
; since KERNEL_HIGH_BASE below sits inside splash_pm32's boot-time 0-64MB
; temporary map). With the real party/tcp/http/crypto/tls/https/browse/
; mouse/zip/install modules (not the placeholder stubs used to test-
; assemble this rewrite) the build was previously measured around ~1400
; sectors including Phase 5 (crypto/TLS/HTTPS). 2200 leaves meaningful
; margin above that for further growth without touching this file again
; for a while - VERIFY against a real full build before shipping and bump
; if needed. If it does need to grow, just bump this constant - there is
; no hidden physical wall to hit anymore, only disk capacity and
; FS_LBA_START below (which is derived from this, not hand-maintained, so
; it can never drift out of sync the way it used to).
KERNEL_BODY_SECTORS equ 2200

; ---- filesystem region: starts safely after the kernel body, wherever
; that ends up being. Derived, not hand-copied, so bumping
; KERNEL_BODY_SECTORS above can never silently leave FS_LBA_START
; pointing into the kernel the way the old manually-synced constants
; could (see boot.asm's pre-relocation comments). +64 sectors slack on
; top of that for a little extra safety margin. ----
FS_LBA_START equ KERNEL_BODY_LBA + KERNEL_BODY_SECTORS + 64

; ---- real-mode physical memory layout ----
STAGE2_LOAD_SEG   equ 0x0000
STAGE2_LOAD_OFF   equ 0x8000          ; same spot the old flat kernel used to load;
                                       ; still fine now that stage2 is small.

; The kernel body's new home. 2MB, chosen because splash_pm32's temporary
; boot-time identity map already covers 0-64MB with 2MB pages, so
; far-jumping straight here works correctly even before
; expand_identity_map (kernel_entry's first call) extends that map to a
; full 0-4GB map. Comfortably clear of every low-memory fixed address
; still in use: real-mode IVT/BDA (0-0x500), the long-mode page tables
; (0x1000-0x6FFF, built by splash_pm32/expand_identity_map), stage2's own
; code/data (0x8000 upward), the relocation staging buffer below, and the
; boot-time stack (0x9F000, set in both splash_lm64 and kernel_entry).
KERNEL_HIGH_BASE  equ 0x00200000

; ---- relocation staging buffer: stage2 reads each disk chunk here (still
; real mode, still comfortably under 1MB), then INT 15h/AH=87h moves it up
; to KERNEL_HIGH_BASE+offset. This one buffer is reused every iteration -
; only the source LBA (advancing through the disk) and the destination
; offset (advancing through KERNEL_HIGH_BASE) change between chunks, so
; there's no seg:off-growth arithmetic needed here the way boot.asm's old
; single flat read into a growing >64K buffer needed dap_set_buf. ----
STAGE_BUF         equ 0x00040000      ; 256KB mark - far clear of stage2 itself
                                       ; (measured ~20KB) and everything else below 1MB
CHUNK_SECTORS     equ 64              ; 32KB per chunk
CHUNK_BYTES       equ CHUNK_SECTORS * 512
CHUNK_WORDS       equ CHUNK_BYTES / 2 ; INT 15h/AH=87h counts in words; max legal
                                       ; value is 8000h (32K words = 64KB) - 4000h
                                       ; keeps a healthy margin below that ceiling
                                       ; for older/pickier BIOSes.
