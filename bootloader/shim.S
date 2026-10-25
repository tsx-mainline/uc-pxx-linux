// SPDX-License-Identifier: GPL-2.0-or-later
// Boot stub for the UC-P10: a valid arm64 Image that the vendor U-Boot runs in place.
//
// U-Boot does not relocate this Image. It jumps to it where it loaded it, which is not 2 MiB
// aligned. So this stub does the work of a bootloader. It copies the Linux Image (stored at
// stub + 2 MiB) to LINUX_DEST (2 MiB aligned). Then it jumps to Linux with the address of our
// device tree (stored at stub + 64 KiB) in x0. Our device tree holds the memory banks and the
// kernel command line. The stub prints its progress on UART2 (115200 baud).
//
// On a boot from a slot, U-Boot passes its own device tree in x0 (the stock rk-kernel.dtb of the
// resource, with the changes of U-Boot). Its /chosen/bootargs has the androidboot.* words: the
// slot suffix, the verified boot state, the vbmeta state and more. The stub copies that string
// into the new property /chosen/u-boot,bootargs of our device tree, so the running system can
// read it (/proc/device-tree/chosen/u-boot,bootargs). The kernel ignores the property. A
// "fastboot boot" passes no device tree (x0 is 0), and then the stub adds nothing.
// docs/boot.md "What U-Boot passes to the kernel" has the details.
//
// kernel/mkimage.sh assembles this file. It defines IMAGE_SIZE, LINUX_FILE_SIZE, LINUX_DEST,
// DTB_FILE and LINUX_IMAGE. It does not define FB_BASE, see below.
// kernel/tests/test-shim-fdt.sh assembles only the device tree code (UC_PXX_SHIM_FDT_TEST).
#define DTB_OFF   0x10000
#define LINUX_OFF 0x200000
#define UB_NAME_LEN 16                  // strlen("u-boot,bootargs") + 1
#define UB_ARGS_MAX 4096                // a longer U-Boot command line is not copied
    .section .text
#ifndef UC_PXX_SHIM_FDT_TEST
    .globl _start
_start:
    b       entry                   // code0
    .long   0                       // code1
    .quad   0                       // text_offset
    .quad   IMAGE_SIZE              // image_size (stub area + Linux image_size)
    .quad   0xa                     // flags: LE, 4K pages, place anywhere
    .quad   0, 0, 0                 // reserved
    .ascii  "ARM\x64"               // magic
    .long   0                       // reserved
entry:
    mov     x19, x0                 // the device tree of U-Boot, or 0
    adr     x24, _start             // runtime base (not page aligned: no adrp below)
    ldr     x23, =0xff1a0000        // UART2
    adr     x0, m_hello
    bl      puts
    adr     x0, m_x0
    mov     x1, x19
    bl      putkv
    adr     x0, m_pc
    mov     x1, x24
    bl      putkv
    adr     x0, m_el
    mrs     x1, CurrentEL
    lsr     x1, x1, #2
    bl      putkv
    ldr     x2, =DTB_OFF
    add     x25, x24, x2            // x25 = our DTB
    adr     x0, m_dtb
    mov     x1, x25
    bl      putkv
    ldr     w1, [x25]
    rev     w1, w1
    adr     x0, m_fdtmagic
    bl      putkv
    ldr     x2, =LINUX_OFF
    add     x26, x24, x2            // x26 = Linux image in the fastboot buffer
    ldr     w1, [x26, #56]
    adr     x0, m_lmagic
    bl      putkv
    // Copy LINUX_FILE_SIZE bytes (rounded up to 64) from x26 to LINUX_DEST. The regions must not
    // overlap. kernel/mkimage.sh checks this.
    ldr     x27, =LINUX_DEST
    adr     x0, m_copy
    mov     x1, x27
    bl      putkv                   // clobbers x2..x6, so load the copy registers after it
    ldr     x5, =((LINUX_FILE_SIZE + 63) & ~63)
    mov     x3, x26
    mov     x4, x27
1:  ldp     x6, x7, [x3], #16
    ldp     x8, x9, [x3], #16
    ldp     x10, x11, [x3], #16
    ldp     x12, x13, [x3], #16
    stp     x6, x7, [x4], #16
    stp     x8, x9, [x4], #16
    stp     x10, x11, [x4], #16
    stp     x12, x13, [x4], #16
    subs    x5, x5, #64
    b.hi    1b
    dsb     sy
    ic      iallu
    dsb     sy
    isb
    ldr     w1, [x27, #56]
    adr     x0, m_lmagic2
    bl      putkv
    // Keep the command line of U-Boot in our device tree. Our device tree may grow up to the
    // Linux Image in the stub area (the copy is done, so nothing reads that area again).
    mov     x0, x25
    mov     x1, x19
#ifdef UC_PXX_SHIM_TEST_SRC
    // TEST BUILDS ONLY: a fastboot boot passes no device tree. Use the one at this address (the
    // rk-kernel.dtb of the resource in the downloaded image), to test the copy on the unit.
    cbnz    x1, 7f
    ldr     x1, =UC_PXX_SHIM_TEST_SRC
7:
#endif
    ldr     x2, =LINUX_OFF
    add     x2, x24, x2
    bl      keep_uboot_args
    mov     x1, x0
    adr     x0, m_ubargs
    bl      putkv
#ifdef FB_BASE
    // This block is off in the normal build (FB_BASE is not defined). The kernel display driver
    // (rockchip-drm) then owns the display. The block is for a simple-framebuffer boot.
    // U-Boot leaves VOPB win0 scanning its centered, y-mirrored BMP logo out of memory that Linux
    // will reuse. The block points win0 at a reserved buffer for the whole 1200x1920 panel. The
    // format is the same RGB888, with no mirror.
    ldr     x3, =FB_BASE
    ldr     x5, =FB_BYTES
3:  stp     xzr, xzr, [x3], #16
    subs    x5, x5, #16
    b.hi    3b
    dsb     sy
    // Pixel clock: U-Boot leaves dclk_vop0 gated, muxed to CPLL /1, and VPLL in slow mode. So the
    // VOP sends no frames (black panel, backlight on). The DSI line timing (1070 byte clocks per
    // 1284-pixel line) needs exactly 120 MHz: VPLL = 24 / 1 * 100 / 2 / 1 = 1200 MHz and
    // dclk_vop0 = VPLL / 10. A CRU write carries a write-enable mask in the upper 16 bits.
    ldr     x4, =0xff760000          // CRU
    ldr     w5, =0x03000000          // VPLL_CON3: slow mode while reprogramming
    str     w5, [x4, #0xcc]
    ldr     w5, =0x0fff0064          // VPLL_CON0: fbdiv 100
    str     w5, [x4, #0xc0]
    ldr     w5, =0x773f1201          // VPLL_CON1: refdiv 1, postdiv1 2, postdiv2 1
    str     w5, [x4, #0xc4]
    mov     x6, #0x100000            // bounded wait for lock
4:  ldr     w5, [x4, #0xc8]          // VPLL_CON2 bit 31 = lock
    tbnz    w5, #31, 5f
    subs    x6, x6, #1
    b.ne    4b
5:  ldr     w5, =0x03000100          // VPLL_CON3: normal mode
    str     w5, [x4, #0xcc]
    ldr     w5, =0x03ff0009          // CLKSEL_CON49: dclk_vop0_div = VPLL / 10, dclk_vop0 from the divider
    str     w5, [x4, #0x1c4]
    ldr     w5, =0x10000000          // CLKGATE_CON10 bit 12: ungate dclk_vop0
    str     w5, [x4, #0x328]
    dsb     sy
    ldr     x4, =0xff900000          // VOPB
    ldr     w5, [x4, #0x30]          // WIN0_CTRL0: keep format/rb_swap/enable, clear y-mirror (bit 22)
    and     w5, w5, #~(1 << 22)
    str     w5, [x4, #0x30]
    ldr     w5, [x4, #0x3c]          // WIN0_VIR: low 16 bits = stride in 32-bit words
    and     w5, w5, #0xffff0000
    ldr     w6, =(FB_STRIDE / 4)
    orr     w5, w5, w6
    str     w5, [x4, #0x3c]
    ldr     w5, =FB_BASE
    str     w5, [x4, #0x40]          // WIN0_YRGB_MST
    ldr     w5, =(((FB_H - 1) << 16) | (FB_W - 1))
    str     w5, [x4, #0x48]          // WIN0_ACT_INFO
    str     w5, [x4, #0x4c]          // WIN0_DSP_INFO
    ldr     w5, =FB_DSP_ST
    str     w5, [x4, #0x50]          // WIN0_DSP_ST
    mov     w5, #1
    str     w5, [x4, #0x00]          // REG_CFG_DONE
    dsb     sy
    // DSI host: the video stream restarted in the middle of a frame. A core reset makes it sync
    // again on the next vsync. Without it, the picture can sit one line out of phase. The panel
    // and PHY setup stay as U-Boot left them.
    ldr     x4, =0xff960000          // MIPI DSI0
    str     wzr, [x4, #0x04]         // PWR_UP = 0 (core reset)
    mov     x6, #0x40000
6:  subs    x6, x6, #1
    b.ne    6b
    mov     w5, #1
    str     w5, [x4, #0x04]          // PWR_UP = 1
    dsb     sy
    adr     x0, m_fb
    ldr     x1, =FB_BASE
    bl      putkv
#endif
    adr     x0, m_jump
    bl      puts
2:  ldr     w3, [x23, #0x14]
    tbz     w3, #6, 2b              // wait for TEMT
    mov     x0, x25
    mov     x1, xzr
    mov     x2, xzr
    mov     x3, xzr
    br      x27

// puts(x0 = string): clobbers x0, x2, x3
puts:
1:  ldrb    w2, [x0], #1
    cbz     w2, 3f
2:  ldr     w3, [x23, #0x14]
    tbz     w3, #5, 2b              // THRE
    str     w2, [x23]
    b       1b
3:  ret

// putkv(x0 = label, x1 = value): prints "label<16 hex digits>\r\n". Clobbers x0, x2..x6, x14
putkv:
    mov     x14, x30
    bl      puts
    mov     x4, #60
4:  lsr     x5, x1, x4
    and     x5, x5, #0xf
    cmp     x5, #10
    add     x2, x5, #'0'
    add     x5, x5, #('a' - 10)
    csel    x2, x5, x2, hs
5:  ldr     w3, [x23, #0x14]
    tbz     w3, #5, 5b
    str     w2, [x23]
    subs    x4, x4, #4
    b.pl    4b
    adr     x0, m_crlf
    bl      puts
    mov     x30, x14
    ret
#endif // UC_PXX_SHIM_FDT_TEST

// The device tree code. A flattened device tree is big-endian: each word read goes through rev.
// U-Boot starts the stub with the MMU off, so all data accesses are of the Device type and must
// be aligned. The code reads and writes words only at 4-byte aligned places of a device tree
// that starts at an 8-byte aligned address. Everything else is a byte access.

// keep_uboot_args(x0 = our device tree, x1 = the device tree of U-Boot or 0, x2 = the end of the
// room for our device tree). It copies /chosen/bootargs of the U-Boot tree into the new property
// /chosen/u-boot,bootargs of our tree. It inserts the property as the first one of /chosen, moves
// the rest of the tree back, adds the name to the strings block and fixes the header. On any
// failed check it changes nothing. Returns x0:
//   0 copied   1 no U-Boot tree (0, bad header, or it overlaps our room)
//   2 the U-Boot tree has no /chosen/bootargs string
//   3 our tree is not usable (bad header or no /chosen)
//   4 no room, or the string is longer than UB_ARGS_MAX
//   5 our tree has /chosen/u-boot,bootargs already
// It uses x0..x17 only. x17 keeps the return address.
    .globl  keep_uboot_args
keep_uboot_args:
    mov     x17, x30
    mov     x9, x0                  // x9 = our tree
    mov     x10, x1                 // x10 = the U-Boot tree
    mov     x11, x2                 // x11 = the end of our room
    cbz     x10, ub_st1
    tst     x10, #7
    b.ne    ub_st1
    tst     x9, #7
    b.ne    ub_st3
    mov     x0, x10
    bl      fdt_check
    cbnz    x0, ub_st1
    add     x3, x10, x1             // the end of the U-Boot tree
    cmp     x3, x9
    b.ls    1f
    cmp     x10, x11
    b.lo    ub_st1                  // it overlaps our room
1:  mov     x0, x10
    bl      fdt_find_chosen
    cbz     x0, ub_st2
    mov     x1, x0
    mov     x0, x10
    adr     x2, s_bootargs
    bl      fdt_find_prop
    cbz     x0, ub_st2
    mov     x12, x0                 // x12 = the bootargs property of U-Boot
    ldr     w13, [x12, #4]
    rev     w13, w13                // x13 = its length, with the NUL
    cbz     x13, ub_st2
    mov     x3, #UB_ARGS_MAX
    cmp     x13, x3
    b.hi    ub_st4
    add     x3, x12, #11
    ldrb    w3, [x3, x13]           // the last byte of the value must be NUL
    cbnz    w3, ub_st2
    mov     x0, x9
    bl      fdt_check
    cbnz    x0, ub_st3
    mov     x16, x1                 // x16 = the totalsize of our tree
    mov     x0, x9
    bl      fdt_find_chosen
    cbz     x0, ub_st3
    mov     x14, x0                 // x14 = the first token in our /chosen: insert here
    mov     x1, x0
    mov     x0, x9
    adr     x2, s_ubootargs
    bl      fdt_find_prop
    cbnz    x0, ub_st5
    add     x15, x13, #3
    and     x15, x15, #~3
    add     x15, x15, #12           // x15 = the size of the new property
    add     x0, x9, x16
    add     x0, x0, x15
    add     x0, x0, #UB_NAME_LEN
    cmp     x0, x11
    b.hi    ub_st4
    // move [x14, end of the tree) back by x15, from the end
    add     x0, x9, x16
    add     x1, x0, x15
2:  cmp     x0, x14
    b.ls    3f
    ldrb    w2, [x0, #-1]!
    strb    w2, [x1, #-1]!
    b       2b
3:  mov     w2, #3                  // FDT_PROP
    rev     w2, w2
    str     w2, [x14]
    rev     w2, w13
    str     w2, [x14, #4]           // len
    ldr     w3, [x9, #32]
    rev     w3, w3                  // x3 = size_dt_strings = the offset of the new name
    rev     w2, w3
    str     w2, [x14, #8]           // nameoff
    add     x0, x12, #12
    add     x1, x14, #12
    mov     x2, x13
4:  ldrb    w4, [x0], #1
    strb    w4, [x1], #1
    subs    x2, x2, #1
    b.ne    4b
5:  tst     x1, #3
    b.eq    6f
    strb    wzr, [x1], #1
    b       5b
6:  ldr     w4, [x9, #12]
    rev     w4, w4                  // x4 = the old off_dt_strings
    add     x0, x9, x4
    add     x0, x0, x15
    add     x0, x0, x3              // the end of the moved strings block
    adr     x1, s_ubootargs
7:  ldrb    w2, [x1], #1
    strb    w2, [x0], #1
    cbnz    w2, 7b
    add     w4, w4, w15
    rev     w2, w4
    str     w2, [x9, #12]           // off_dt_strings
    add     w3, w3, #UB_NAME_LEN
    rev     w2, w3
    str     w2, [x9, #32]           // size_dt_strings
    ldr     w2, [x9, #36]
    rev     w2, w2
    add     w2, w2, w15
    rev     w2, w2
    str     w2, [x9, #36]           // size_dt_struct
    add     x16, x16, x15
    add     x16, x16, #UB_NAME_LEN
    rev     w2, w16
    str     w2, [x9, #4]            // totalsize
    // Linux reads the tree before it turns the caches on: clean the tree to memory
    add     x1, x9, x16
    bic     x0, x9, #63
8:  dc      civac, x0
    add     x0, x0, #64
    cmp     x0, x1
    b.lo    8b
    dsb     sy
    mov     x0, #0
    b       ub_ret
ub_st1: mov x0, #1
    b       ub_ret
ub_st2: mov x0, #2
    b       ub_ret
ub_st3: mov x0, #3
    b       ub_ret
ub_st4: mov x0, #4
    b       ub_ret
ub_st5: mov x0, #5
ub_ret:
    mov     x30, x17
    ret

// fdt_check(x0 = tree): x0 = 0 when the header is usable, else 1. x1 = totalsize. Uses x1..x7.
// Usable: the magic, version 17 or later, totalsize up to 1 MiB, the struct block 4-byte
// aligned, and the order memory reservations, struct block, strings block inside totalsize.
fdt_check:
    ldr     w1, [x0]
    rev     w1, w1
    ldr     w2, =0xd00dfeed
    cmp     w1, w2
    b.ne    1f
    ldr     w1, [x0, #20]
    rev     w1, w1
    cmp     w1, #17
    b.lo    1f
    ldr     w1, [x0, #4]
    rev     w1, w1                  // totalsize
    mov     x2, #0x100000
    cmp     x1, x2
    b.hi    1f
    ldr     w2, [x0, #8]
    rev     w2, w2                  // off_dt_struct
    tst     x2, #3
    b.ne    1f
    ldr     w3, [x0, #36]
    rev     w3, w3                  // size_dt_struct
    ldr     w4, [x0, #12]
    rev     w4, w4                  // off_dt_strings
    ldr     w5, [x0, #32]
    rev     w5, w5                  // size_dt_strings
    ldr     w6, [x0, #16]
    rev     w6, w6                  // off_mem_rsvmap
    cmp     x6, x2
    b.hs    1f
    add     x7, x2, x3
    cmp     x7, x4
    b.hi    1f
    add     x7, x4, x5
    cmp     x7, x1
    b.hi    1f
    mov     x0, #0
    ret
1:  mov     x0, #1
    ret

// fdt_find_chosen(x0 = tree): x0 = the first token inside the node /chosen (a child of the
// root), or 0. Uses x1..x8.
fdt_find_chosen:
    ldr     w1, [x0, #8]
    rev     w1, w1
    add     x1, x0, x1              // x1 = the token pointer
    ldr     w2, [x0, #36]
    rev     w2, w2
    add     x2, x1, x2              // x2 = the end of the struct block
    mov     x3, #0                  // x3 = the depth
1:  cmp     x1, x2
    b.hs    9f
    ldr     w4, [x1], #4
    rev     w4, w4
    cmp     w4, #1                  // FDT_BEGIN_NODE
    b.eq    2f
    cmp     w4, #2                  // FDT_END_NODE
    b.eq    5f
    cmp     w4, #3                  // FDT_PROP
    b.eq    6f
    cmp     w4, #4                  // FDT_NOP
    b.eq    1b
    b       9f                      // FDT_END or a bad token
2:  add     x3, x3, #1
    cmp     x3, #2
    b.ne    4f
    adr     x5, s_chosen
    mov     x6, x1
3:  ldrb    w7, [x5], #1
    ldrb    w8, [x6], #1
    cmp     w7, w8
    b.ne    4f
    cbnz    w7, 3b
    add     x0, x6, #3              // the name matches: the next token
    and     x0, x0, #~3
    ret
4:  ldrb    w7, [x1], #1            // skip the name
    cbnz    w7, 4b
    add     x1, x1, #3
    and     x1, x1, #~3
    b       1b
5:  cbz     x3, 9f
    sub     x3, x3, #1
    b       1b
6:  add     x5, x1, #8
    cmp     x5, x2
    b.hi    9f
    ldr     w5, [x1]
    rev     w5, w5
    add     x1, x1, #8
    add     x1, x1, x5
    add     x1, x1, #3
    and     x1, x1, #~3
    b       1b
9:  mov     x0, #0
    ret

// fdt_find_prop(x0 = tree, x1 = the first token inside a node, x2 = a name): x0 = the
// FDT_PROP token of the property with that name, among the properties of that node, or 0.
// Uses x1, x3..x8.
fdt_find_prop:
    ldr     w3, [x0, #12]
    rev     w3, w3
    add     x3, x0, x3              // x3 = the strings block
    ldr     w4, [x0, #8]
    rev     w4, w4
    ldr     w5, [x0, #36]
    rev     w5, w5
    add     x4, x4, x5
    add     x4, x0, x4              // x4 = the end of the struct block
1:  add     x5, x1, #12
    cmp     x5, x4
    b.hi    9f
    ldr     w5, [x1]
    rev     w5, w5
    cmp     w5, #4                  // FDT_NOP
    b.ne    2f
    add     x1, x1, #4
    b       1b
2:  cmp     w5, #3                  // FDT_PROP. Any other token ends the properties
    b.ne    9f
    ldr     w5, [x1, #8]
    rev     w5, w5
    add     x5, x3, x5              // the name of this property
    mov     x6, x2
3:  ldrb    w7, [x5], #1
    ldrb    w8, [x6], #1
    cmp     w7, w8
    b.ne    4f
    cbnz    w7, 3b
    mov     x0, x1
    ret
4:  ldr     w5, [x1, #4]
    rev     w5, w5
    add     x1, x1, #12
    add     x1, x1, x5
    add     x1, x1, #3
    and     x1, x1, #~3
    b       1b
9:  mov     x0, #0
    ret

s_chosen:    .asciz "chosen"
s_bootargs:  .asciz "bootargs"
s_ubootargs: .asciz "u-boot,bootargs"
    .balign 4

#ifndef UC_PXX_SHIM_FDT_TEST
m_hello:    .asciz "\r\nUC-P10 shim: bootm entered the stub\r\n"
m_x0:       .asciz "  x0 from U-Boot 0x"
m_pc:       .asciz "  stub at        0x"
m_el:       .asciz "  EL             0x"
m_dtb:      .asciz "  our dtb at     0x"
m_fdtmagic: .asciz "  fdt magic      0x"
m_lmagic:   .asciz "  linux magic    0x"
m_copy:     .asciz "  copying to     0x"
m_lmagic2:  .asciz "  copied magic   0x"
m_ubargs:   .asciz "  u-boot args    0x"
m_fb:       .asciz "  framebuffer at 0x"
m_jump:     .asciz "UC-P10 shim: jumping to Linux\r\n"
m_crlf:     .asciz "\r\n"
    .ltorg

    .org    DTB_OFF
dtb:
    .incbin DTB_FILE
    .org    LINUX_OFF
lx_image:
    .incbin LINUX_IMAGE
#endif // UC_PXX_SHIM_FDT_TEST
