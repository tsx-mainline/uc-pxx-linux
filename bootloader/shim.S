// SPDX-License-Identifier: GPL-2.0-or-later
// Boot stub for the UC-P10: a valid arm64 Image that the vendor U-Boot runs in place.
//
// U-Boot does not relocate this Image. It jumps to it where it loaded it, which is not 2 MiB
// aligned. U-Boot also passes no device tree (x0 is 0). So this stub does the work of a bootloader.
// It copies the Linux Image (stored at stub + 2 MiB) to LINUX_DEST (2 MiB aligned). Then it jumps
// to Linux with the address of the device tree (stored at stub + 64 KiB) in x0. The device tree
// holds the memory banks and the kernel command line. The stub prints its progress on UART2
// (115200 baud).
//
// kernel/mkimage.sh assembles this file. It defines IMAGE_SIZE, LINUX_FILE_SIZE, LINUX_DEST,
// DTB_FILE and LINUX_IMAGE. It does not define FB_BASE, see below.
#define DTB_OFF   0x10000
#define LINUX_OFF 0x200000
    .section .text
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
    mov     x19, x0                 // what U-Boot passed (for the log only)
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

m_hello:    .asciz "\r\nUC-P10 shim: bootm entered the stub\r\n"
m_x0:       .asciz "  x0 from U-Boot 0x"
m_pc:       .asciz "  stub at        0x"
m_el:       .asciz "  EL             0x"
m_dtb:      .asciz "  our dtb at     0x"
m_fdtmagic: .asciz "  fdt magic      0x"
m_lmagic:   .asciz "  linux magic    0x"
m_copy:     .asciz "  copying to     0x"
m_lmagic2:  .asciz "  copied magic   0x"
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
