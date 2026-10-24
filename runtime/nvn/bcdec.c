// BC1-BC7 block decoder (runtime/nvn/bcdec.h), written from the format descriptions (Khronos Data Format
// Specification, "S3TC", "RGTC", "BPTC"). Bit layouts and tables below are the format's own.
#include "bcdec.h"

#include <stdlib.h>
#include <string.h>

unsigned bcdec_texel_bytes(BcKind k) {
    switch (k) {
    case BCDEC_BC4U: case BCDEC_BC4S: return 1;
    case BCDEC_BC5U: case BCDEC_BC5S: return 2;
    case BCDEC_BC6U: case BCDEC_BC6S: return 8;
    case BCDEC_NONE: return 0;
    default: return 4;
    }
}

unsigned bcdec_block_bytes(BcKind k) { return k == BCDEC_BC1 || k == BCDEC_BC4U || k == BCDEC_BC4S ? 8 : 16; }

// ------------------------------------------------------------------ BC1-BC3 (S3TC)
static void rgb565(uint16_t c, uint8_t *o) {
    unsigned r = c >> 11 & 31, g = c >> 5 & 63, b = c & 31;
    o[0] = (uint8_t)(r << 3 | r >> 2), o[1] = (uint8_t)(g << 2 | g >> 4), o[2] = (uint8_t)(b << 3 | b >> 2), o[3] = 255;
}

// The colour half of a block; punch: BC1's 3-colour + transparent mode when color0 <= color1 (BC2 / BC3 always use 4)
static void color_block(const uint8_t *b, uint8_t *out, size_t pitch, bool punch) {
    uint16_t c0 = (uint16_t)(b[0] | b[1] << 8), c1 = (uint16_t)(b[2] | b[3] << 8);
    uint8_t p[4][4];
    rgb565(c0, p[0]);
    rgb565(c1, p[1]);
    if (c0 > c1 || !punch) {
        for (int i = 0; i < 3; i++) {
            p[2][i] = (uint8_t)((2 * p[0][i] + p[1][i] + 1) / 3);
            p[3][i] = (uint8_t)((p[0][i] + 2 * p[1][i] + 1) / 3);
        }
        p[2][3] = p[3][3] = 255;
    } else {
        for (int i = 0; i < 3; i++) p[2][i] = (uint8_t)((p[0][i] + p[1][i]) / 2);
        p[2][3] = 255;
        memset(p[3], 0, 4);
    }
    uint32_t idx = (uint32_t)b[4] | (uint32_t)b[5] << 8 | (uint32_t)b[6] << 16 | (uint32_t)b[7] << 24;
    for (int i = 0; i < 16; i++) memcpy(out + (i >> 2) * pitch + (i & 3) * 4, p[idx >> (2 * i) & 3], 4);
}

// ------------------------------------------------------------------ BC4 / BC5 (RGTC), and BC3's alpha
// One channel: texel i's value at out[(i/4) * pitch + (i%4) * step]
static void channel_unorm(const uint8_t *b, uint8_t *out, size_t pitch, unsigned step) {
    unsigned a0 = b[0], a1 = b[1];
    uint8_t p[8] = {(uint8_t)a0, (uint8_t)a1};
    if (a0 > a1)
        for (unsigned i = 1; i < 7; i++) p[i + 1] = (uint8_t)(((7 - i) * a0 + i * a1 + 3) / 7);
    else {
        for (unsigned i = 1; i < 5; i++) p[i + 1] = (uint8_t)(((5 - i) * a0 + i * a1 + 2) / 5);
        p[6] = 0, p[7] = 255;
    }
    uint64_t bits = 0;
    for (int i = 0; i < 6; i++) bits |= (uint64_t)b[2 + i] << (8 * i);
    for (int i = 0; i < 16; i++) out[(i >> 2) * pitch + (i & 3) * step] = p[bits >> (3 * i) & 7];
}

static void channel_snorm(const uint8_t *b, uint8_t *out, size_t pitch, unsigned step) {
    int a0 = (int8_t)b[0], a1 = (int8_t)b[1];
    if (a0 < -127) a0 = -127;  // (-128 and -127 are both -1.0)
    if (a1 < -127) a1 = -127;
    int p[8] = {a0, a1};
    if (a0 > a1)
        for (int i = 1; i < 7; i++) p[i + 1] = ((7 - i) * a0 + i * a1) / 7;
    else {
        for (int i = 1; i < 5; i++) p[i + 1] = ((5 - i) * a0 + i * a1) / 5;
        p[6] = -127, p[7] = 127;
    }
    uint64_t bits = 0;
    for (int i = 0; i < 6; i++) bits |= (uint64_t)b[2 + i] << (8 * i);
    for (int i = 0; i < 16; i++) out[(i >> 2) * pitch + (i & 3) * step] = (uint8_t)(int8_t)p[bits >> (3 * i) & 7];
}

// ------------------------------------------------------------------ BPTC tables (BC6H uses the 2-subset ones)
// 2-subset partitions: bit i = the subset of texel i
static const uint16_t P2[64] = {
    0xCCCC, 0x8888, 0xEEEE, 0xECC8, 0xC880, 0xFEEC, 0xFEC8, 0xEC80, 0xC800, 0xFFEC, 0xFE80, 0xE800, 0xFFE8, 0xFF00,
    0xFFF0, 0xF000, 0xF710, 0x008E, 0x7100, 0x08CE, 0x008C, 0x7310, 0x3100, 0x8CCE, 0x088C, 0x3110, 0x6666, 0x366C,
    0x17E8, 0x0FF0, 0x718E, 0x399C, 0xAAAA, 0xF0F0, 0x5A5A, 0x33CC, 0x3C3C, 0x55AA, 0x9696, 0xA55A, 0x73CE, 0x13C8,
    0x324C, 0x3BDC, 0x6996, 0xC33C, 0x9966, 0x0660, 0x0272, 0x04E4, 0x4E40, 0x2720, 0xC936, 0x936C, 0x39C6, 0x639C,
    0x9336, 0x9CC6, 0x817E, 0xE718, 0xCCF0, 0x0FCC, 0x7744, 0xEE22};
// 3-subset partitions: texel i's subset
static const uint8_t P3[64][16] = {
    {0, 0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 1, 2, 2, 2, 2}, {0, 0, 0, 1, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 2, 1},
    {0, 0, 0, 0, 2, 0, 0, 1, 2, 2, 1, 1, 2, 2, 1, 1}, {0, 2, 2, 2, 0, 0, 2, 2, 0, 0, 1, 1, 0, 1, 1, 1},
    {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2}, {0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 2, 2, 0, 0, 2, 2},
    {0, 0, 2, 2, 0, 0, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1}, {0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1},
    {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2}, {0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2},
    {0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2}, {0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2},
    {0, 1, 1, 2, 0, 1, 1, 2, 0, 1, 1, 2, 0, 1, 1, 2}, {0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 2},
    {0, 0, 1, 1, 0, 1, 1, 2, 1, 1, 2, 2, 1, 2, 2, 2}, {0, 0, 1, 1, 2, 0, 0, 1, 2, 2, 0, 0, 2, 2, 2, 0},
    {0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 2, 1, 1, 2, 2}, {0, 1, 1, 1, 0, 0, 1, 1, 2, 0, 0, 1, 2, 2, 0, 0},
    {0, 0, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2}, {0, 0, 2, 2, 0, 0, 2, 2, 0, 0, 2, 2, 1, 1, 1, 1},
    {0, 1, 1, 1, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2}, {0, 0, 0, 1, 0, 0, 0, 1, 2, 2, 2, 1, 2, 2, 2, 1},
    {0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 2, 2, 0, 1, 2, 2}, {0, 0, 0, 0, 1, 1, 0, 0, 2, 2, 1, 0, 2, 2, 1, 0},
    {0, 1, 2, 2, 0, 1, 2, 2, 0, 0, 1, 1, 0, 0, 0, 0}, {0, 0, 1, 2, 0, 0, 1, 2, 1, 1, 2, 2, 2, 2, 2, 2},
    {0, 1, 1, 0, 1, 2, 2, 1, 1, 2, 2, 1, 0, 1, 1, 0}, {0, 0, 0, 0, 0, 1, 1, 0, 1, 2, 2, 1, 1, 2, 2, 1},
    {0, 0, 2, 2, 1, 1, 0, 2, 1, 1, 0, 2, 0, 0, 2, 2}, {0, 1, 1, 0, 0, 1, 1, 0, 2, 0, 0, 2, 2, 2, 2, 2},
    {0, 0, 1, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 0, 1, 1}, {0, 0, 0, 0, 2, 0, 0, 0, 2, 2, 1, 1, 2, 2, 2, 1},
    {0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 2, 2, 2}, {0, 2, 2, 2, 0, 0, 2, 2, 0, 0, 1, 2, 0, 0, 1, 1},
    {0, 0, 1, 1, 0, 0, 1, 2, 0, 0, 2, 2, 0, 2, 2, 2}, {0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0},
    {0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 0, 0, 0, 0}, {0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0},
    {0, 1, 2, 0, 2, 0, 1, 2, 1, 2, 0, 1, 0, 1, 2, 0}, {0, 0, 1, 1, 2, 2, 0, 0, 1, 1, 2, 2, 0, 0, 1, 1},
    {0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 0, 0, 0, 0, 1, 1}, {0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2},
    {0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 2, 1, 2, 1, 2, 1}, {0, 0, 2, 2, 1, 1, 2, 2, 0, 0, 2, 2, 1, 1, 2, 2},
    {0, 0, 2, 2, 0, 0, 1, 1, 0, 0, 2, 2, 0, 0, 1, 1}, {0, 2, 2, 0, 1, 2, 2, 1, 0, 2, 2, 0, 1, 2, 2, 1},
    {0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 0, 1, 0, 1}, {0, 0, 0, 0, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1},
    {0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2}, {0, 2, 2, 2, 0, 1, 1, 1, 0, 2, 2, 2, 0, 1, 1, 1},
    {0, 0, 0, 2, 1, 1, 1, 2, 0, 0, 0, 2, 1, 1, 1, 2}, {0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2},
    {0, 2, 2, 2, 0, 1, 1, 1, 0, 1, 1, 1, 0, 2, 2, 2}, {0, 0, 0, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0, 0, 2},
    {0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 2, 2}, {0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 1, 2},
    {0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 2, 2, 2, 2, 2, 2}, {0, 0, 2, 2, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 2, 2},
    {0, 0, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2, 0, 0, 2, 2}, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2},
    {0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1}, {0, 2, 2, 2, 1, 2, 2, 2, 0, 2, 2, 2, 1, 2, 2, 2},
    {0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2}, {0, 1, 1, 1, 2, 0, 1, 1, 2, 2, 0, 1, 2, 2, 2, 0}};
// Anchor texels (their index has one bit less): subset 1 of the 2-subset partitions, subsets 1 and 2 of the 3-subset
static const uint8_t A2[64] = {15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 2,  8,  2,  2,  8,
                               8,  15, 2,  8,  2,  2,  8,  8,  2,  2,  15, 15, 6,  8,  2,  8,  15, 15, 2,  8,  2,  2,
                               2,  15, 15, 6,  6,  2,  6,  8,  15, 15, 2,  2,  15, 15, 15, 15, 15, 2,  2,  15};
static const uint8_t A3a[64] = {3, 3,  15, 15, 8, 3,  15, 15, 8,  8,  6,  6,  6,  5,  3,  3,  3,  3,  8,  15, 3, 3,
                                6, 10, 5,  8,  8, 6,  8,  5,  15, 15, 8,  15, 3,  5,  6,  10, 8,  15, 15, 3,  15, 5,
                                15, 15, 15, 15, 3, 15, 5,  5,  5,  8,  5,  10, 5,  10, 8,  13, 15, 12, 3,  3};
static const uint8_t A3b[64] = {15, 8,  8,  3,  15, 15, 3,  8,  15, 15, 15, 15, 15, 15, 15, 8,  15, 8,  15, 3,  15, 8,
                                15, 8,  3,  15, 6,  10, 15, 15, 10, 8,  15, 3,  15, 10, 10, 8,  9,  10, 6,  15, 8,  15,
                                3,  6,  6,  8,  15, 3,  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3,  15, 15, 8};
static const uint8_t W2[4] = {0, 21, 43, 64};
static const uint8_t W3[8] = {0, 9, 18, 27, 37, 46, 55, 64};
static const uint8_t W4[16] = {0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64};

static const uint8_t *weights(unsigned bits) { return bits == 2 ? W2 : bits == 3 ? W3 : W4; }

typedef struct { const uint8_t *b; unsigned pos; } Bits;
static unsigned take(Bits *s, unsigned n) {  // n <= 16, LSB first
    unsigned v = 0;
    for (unsigned i = 0; i < n; i++, s->pos++) v |= (unsigned)(s->b[s->pos >> 3] >> (s->pos & 7) & 1) << i;
    return v;
}

static unsigned subset_of(unsigned ns, unsigned part, unsigned i) {
    return ns == 1 ? 0 : ns == 2 ? (unsigned)(P2[part] >> i & 1) : P3[part][i];
}
static bool is_anchor(unsigned ns, unsigned part, unsigned i) {
    if (i == 0) return true;
    if (ns == 2) return i == A2[part];
    if (ns == 3) return i == A3a[part] || i == A3b[part];
    return false;
}

// ------------------------------------------------------------------ BC7
typedef struct { uint8_t ns, pb, rb, isb, cb, ab, epb, spb, ib, ib2; } Bc7Mode;
static const Bc7Mode BC7_MODES[8] = {
    {3, 4, 0, 0, 4, 0, 1, 0, 3, 0}, {2, 6, 0, 0, 6, 0, 0, 1, 3, 0}, {3, 6, 0, 0, 5, 0, 0, 0, 2, 0},
    {2, 6, 0, 0, 7, 0, 1, 0, 2, 0}, {1, 0, 2, 1, 5, 6, 0, 0, 2, 3}, {1, 0, 2, 0, 7, 8, 0, 0, 2, 2},
    {1, 0, 0, 0, 7, 7, 1, 0, 4, 0}, {2, 6, 0, 0, 5, 5, 1, 0, 2, 0}};

static uint8_t expand_bits(unsigned v, unsigned n) {  // n-bit value to 8 bits (MSBs repeated below)
    v <<= 8 - n;
    return (uint8_t)(v | v >> n);
}

static void bc7_block(const uint8_t *blk, uint8_t *out, size_t pitch) {
    unsigned mode = 0;
    while (mode < 8 && !(blk[0] >> mode & 1)) mode++;
    if (mode == 8) {  // (reserved: transparent black)
        for (int y = 0; y < 4; y++) memset(out + y * pitch, 0, 16);
        return;
    }
    const Bc7Mode *m = &BC7_MODES[mode];
    Bits s = {blk, mode + 1};
    unsigned part = take(&s, m->pb), rot = take(&s, m->rb), isb = take(&s, m->isb);
    unsigned ne = m->ns * 2u;
    uint8_t ep[6][4];  // endpoints (two per subset), RGBA
    unsigned raw[6][4] = {{0}};
    for (unsigned c = 0; c < 3; c++)
        for (unsigned e = 0; e < ne; e++) raw[e][c] = take(&s, m->cb);
    for (unsigned e = 0; e < ne; e++) raw[e][3] = m->ab ? take(&s, m->ab) : 255;
    unsigned cbits = m->cb, abits = m->ab;
    if (m->epb || m->spb) {
        unsigned p[6];
        if (m->epb) for (unsigned e = 0; e < ne; e++) p[e] = take(&s, 1);
        else for (unsigned k = 0; k < m->ns; k++) p[2 * k] = p[2 * k + 1] = take(&s, 1);
        for (unsigned e = 0; e < ne; e++) {
            for (unsigned c = 0; c < 3; c++) raw[e][c] = raw[e][c] << 1 | p[e];
            if (m->ab) raw[e][3] = raw[e][3] << 1 | p[e];
        }
        cbits++;
        if (m->ab) abits++;
    }
    for (unsigned e = 0; e < ne; e++) {
        for (unsigned c = 0; c < 3; c++) ep[e][c] = expand_bits(raw[e][c], cbits);
        ep[e][3] = m->ab ? expand_bits(raw[e][3], abits) : 255;
    }
    // indices: the primary set (every texel; anchors one bit less), then the secondary (modes 4, 5)
    unsigned idx[16], idx2[16];
    for (unsigned i = 0; i < 16; i++) idx[i] = take(&s, m->ib - (is_anchor(m->ns, part, i) ? 1 : 0));
    if (m->ib2)
        for (unsigned i = 0; i < 16; i++) idx2[i] = take(&s, m->ib2 - (i == 0 ? 1 : 0));
    // which set the colour / the alpha use (mode 4's index selection bit swaps them)
    unsigned cb_ib = m->ib, ab_ib = m->ib2 ? m->ib2 : m->ib;
    const unsigned *ci = idx, *ai = m->ib2 ? idx2 : idx;
    if (isb) { cb_ib = m->ib2, ab_ib = m->ib; ci = idx2, ai = idx; }
    const uint8_t *cw = weights(cb_ib), *aw = weights(ab_ib);
    for (unsigned i = 0; i < 16; i++) {
        unsigned k = subset_of(m->ns, part, i);
        const uint8_t *e0 = ep[2 * k], *e1 = ep[2 * k + 1];
        uint8_t t[4];
        unsigned w = cw[ci[i]], wa = aw[ai[i]];
        for (unsigned c = 0; c < 3; c++) t[c] = (uint8_t)((e0[c] * (64 - w) + e1[c] * w + 32) >> 6);
        t[3] = (uint8_t)((e0[3] * (64 - wa) + e1[3] * wa + 32) >> 6);
        if (rot) { uint8_t x = t[3]; t[3] = t[rot - 1]; t[rot - 1] = x; }
        memcpy(out + (i >> 2) * pitch + (i & 3) * 4, t, 4);
    }
}

// ------------------------------------------------------------------ BC6H
// Endpoint values: w (subset 0 start), x (subset 0 end), y (subset 1 start), z (subset 1 end), channels r g b.
enum { RW, GW, BW, RX, GX, BX, RY, GY, BY, RZ, GZ, BZ };
// A mode's endpoint bits after its mode bits: runs of {field, first bit, count}, in stream order. count < 0: the
// run is stored reversed (its highest bit first).
typedef struct { int8_t f, lo, n; } Run;
typedef struct {
    uint8_t mode_bits, epb, dr, dg, db;  // endpoint bits, delta bits per channel
    bool transformed, two;
    Run runs[24];
} Bc6Mode;

#define R(f, lo, n) {f, lo, n}
static const Bc6Mode BC6_MODES[14] = {
    // 1: 10.5.5.5
    {2, 10, 5, 5, 5, true, true, {R(GY,4,1), R(BY,4,1), R(BZ,4,1), R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,5),
     R(GZ,4,1), R(GY,0,4), R(GX,0,5), R(BZ,0,1), R(GZ,0,4), R(BX,0,5), R(BZ,1,1), R(BY,0,4), R(RY,0,5), R(BZ,2,1),
     R(RZ,0,5), R(BZ,3,1)}},
    // 2: 7.6.6.6
    {2, 7, 6, 6, 6, true, true, {R(GY,5,1), R(GZ,4,1), R(GZ,5,1), R(RW,0,7), R(BZ,0,1), R(BZ,1,1), R(BY,4,1),
     R(GW,0,7), R(BY,5,1), R(BZ,2,1), R(GY,4,1), R(BW,0,7), R(BZ,3,1), R(BZ,5,1), R(BZ,4,1), R(RX,0,6), R(GY,0,4),
     R(GX,0,6), R(GZ,0,4), R(BX,0,6), R(BY,0,4), R(RY,0,6), R(RZ,0,6)}},
    // 3: 11.5.4.4
    {5, 11, 5, 4, 4, true, true, {R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,5), R(RW,10,1), R(GY,0,4), R(GX,0,4),
     R(GW,10,1), R(BZ,0,1), R(GZ,0,4), R(BX,0,4), R(BW,10,1), R(BZ,1,1), R(BY,0,4), R(RY,0,5), R(BZ,2,1), R(RZ,0,5),
     R(BZ,3,1)}},
    // 4: 11.4.5.4
    {5, 11, 4, 5, 4, true, true, {R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,4), R(RW,10,1), R(GZ,4,1), R(GY,0,4),
     R(GX,0,5), R(GW,10,1), R(GZ,0,4), R(BX,0,4), R(BW,10,1), R(BZ,1,1), R(BY,0,4), R(RY,0,4), R(BZ,0,1), R(BZ,2,1),
     R(RZ,0,4), R(GY,4,1), R(BZ,3,1)}},
    // 5: 11.4.4.5
    {5, 11, 4, 4, 5, true, true, {R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,4), R(RW,10,1), R(BY,4,1), R(GY,0,4),
     R(GX,0,4), R(GW,10,1), R(BZ,0,1), R(GZ,0,4), R(BX,0,5), R(BW,10,1), R(BY,0,4), R(RY,0,4), R(BZ,1,1), R(BZ,2,1),
     R(RZ,0,4), R(BZ,4,1), R(BZ,3,1)}},
    // 6: 9.5.5.5
    {5, 9, 5, 5, 5, true, true, {R(RW,0,9), R(BY,4,1), R(GW,0,9), R(GY,4,1), R(BW,0,9), R(BZ,4,1), R(RX,0,5),
     R(GZ,4,1), R(GY,0,4), R(GX,0,5), R(BZ,0,1), R(GZ,0,4), R(BX,0,5), R(BZ,1,1), R(BY,0,4), R(RY,0,5), R(BZ,2,1),
     R(RZ,0,5), R(BZ,3,1)}},
    // 7: 8.6.5.5
    {5, 8, 6, 5, 5, true, true, {R(RW,0,8), R(GZ,4,1), R(BY,4,1), R(GW,0,8), R(BZ,2,1), R(GY,4,1), R(BW,0,8),
     R(BZ,3,1), R(BZ,4,1), R(RX,0,6), R(GY,0,4), R(GX,0,5), R(BZ,0,1), R(GZ,0,4), R(BX,0,5), R(BZ,1,1), R(BY,0,4),
     R(RY,0,6), R(RZ,0,6)}},
    // 8: 8.5.6.5
    {5, 8, 5, 6, 5, true, true, {R(RW,0,8), R(BZ,0,1), R(BY,4,1), R(GW,0,8), R(GY,5,1), R(GY,4,1), R(BW,0,8),
     R(GZ,5,1), R(BZ,4,1), R(RX,0,5), R(GZ,4,1), R(GY,0,4), R(GX,0,6), R(GZ,0,4), R(BX,0,5), R(BZ,1,1), R(BY,0,4),
     R(RY,0,5), R(BZ,2,1), R(RZ,0,5), R(BZ,3,1)}},
    // 9: 8.5.5.6
    {5, 8, 5, 5, 6, true, true, {R(RW,0,8), R(BZ,1,1), R(BY,4,1), R(GW,0,8), R(BY,5,1), R(GY,4,1), R(BW,0,8),
     R(BZ,5,1), R(BZ,4,1), R(RX,0,5), R(GZ,4,1), R(GY,0,4), R(GX,0,5), R(BZ,0,1), R(GZ,0,4), R(BX,0,6), R(BY,0,4),
     R(RY,0,5), R(BZ,2,1), R(RZ,0,5), R(BZ,3,1)}},
    // 10: 6.6.6.6 (endpoints as they are)
    {5, 6, 6, 6, 6, false, true, {R(RW,0,6), R(GZ,4,1), R(BZ,0,1), R(BZ,1,1), R(BY,4,1), R(GW,0,6), R(GY,5,1),
     R(BY,5,1), R(BZ,2,1), R(GY,4,1), R(BW,0,6), R(GZ,5,1), R(BZ,3,1), R(BZ,5,1), R(BZ,4,1), R(RX,0,6), R(GY,0,4),
     R(GX,0,6), R(GZ,0,4), R(BX,0,6), R(BY,0,4), R(RY,0,6), R(RZ,0,6)}},
    // 11: 10.10 (one subset, endpoints as they are)
    {5, 10, 10, 10, 10, false, false, {R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,10), R(GX,0,10), R(BX,0,10)}},
    // 12: 11.9
    {5, 11, 9, 9, 9, true, false, {R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,9), R(RW,10,1), R(GX,0,9), R(GW,10,1),
     R(BX,0,9), R(BW,10,1)}},
    // 13: 12.8 (the high bits reversed)
    {5, 12, 8, 8, 8, true, false, {R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,8), R(RW,10,-2), R(GX,0,8),
     R(GW,10,-2), R(BX,0,8), R(BW,10,-2)}},
    // 14: 16.4 (the high bits reversed)
    {5, 16, 4, 4, 4, true, false, {R(RW,0,10), R(GW,0,10), R(BW,0,10), R(RX,0,4), R(RW,10,-6), R(GX,0,4),
     R(GW,10,-6), R(BX,0,4), R(BW,10,-6)}},
};
#undef R

static int bc6_mode_index(unsigned m5) {  // the 5 low bits of the block -> BC6_MODES index, -1: reserved
    if ((m5 & 3) == 0) return 0;
    if ((m5 & 3) == 1) return 1;
    switch (m5) {
    case 0x02: return 2; case 0x06: return 3; case 0x0A: return 4; case 0x0E: return 5; case 0x12: return 6;
    case 0x16: return 7; case 0x1A: return 8; case 0x1E: return 9; case 0x03: return 10; case 0x07: return 11;
    case 0x0B: return 12; case 0x0F: return 13;
    default: return -1;
    }
}

static int sext(int v, unsigned bits) { return (int)((unsigned)v << (32 - bits)) >> (32 - bits); }

static int bc6_unquantize(int v, unsigned bits, bool sgn) {
    if (!sgn) {
        if (bits >= 15) return v;
        if (v == 0) return 0;
        if (v == (1 << bits) - 1) return 0xFFFF;
        return ((v << 16) + 0x8000) >> bits;
    }
    if (bits >= 16) return v;
    bool neg = v < 0;
    if (neg) v = -v;
    int u;
    if (v == 0) u = 0;
    else if (v >= (1 << (bits - 1)) - 1) u = 0x7FFF;
    else u = ((v << 15) + 0x4000) >> (bits - 1);
    return neg ? -u : u;
}

static uint16_t bc6_finish(int c, bool sgn) {  // interpolated value -> half float bits
    if (!sgn) return (uint16_t)((c * 31) >> 6);
    if (c < 0) return (uint16_t)(0x8000 | (((-c) * 31) >> 5));
    return (uint16_t)((c * 31) >> 5);
}

static void bc6_block(const uint8_t *blk, uint8_t *out, size_t pitch, bool sgn) {
    unsigned m5 = blk[0] & 0x1F;
    int mi = bc6_mode_index(m5);
    if (mi < 0) {  // (reserved modes decode to black)
        for (int y = 0; y < 4; y++) {
            uint16_t *row = (uint16_t *)(out + y * pitch);
            for (int x = 0; x < 4; x++) row[4 * x] = row[4 * x + 1] = row[4 * x + 2] = 0, row[4 * x + 3] = 0x3C00;
        }
        return;
    }
    const Bc6Mode *m = &BC6_MODES[mi];
    Bits s = {blk, m->mode_bits};
    int e[12] = {0};
    for (const Run *r = m->runs; r->n; r++) {
        unsigned n = (unsigned)(r->n < 0 ? -r->n : r->n), v = take(&s, n);
        if (r->n < 0) {  // reversed: the first bit read is the run's highest
            unsigned rv = 0;
            for (unsigned i = 0; i < n; i++) rv |= (v >> i & 1) << (n - 1 - i);
            v = rv;
        }
        e[r->f] |= (int)(v << r->lo);
    }
    unsigned part = m->two ? take(&s, 5) : 0;
    unsigned ne = m->two ? 4 : 2, epb = m->epb;
    const unsigned dbits[3] = {m->dr, m->dg, m->db};
    // endpoints: signed formats sign-extend the base; transformed modes store the others as deltas from it
    for (unsigned c = 0; c < 3; c++) {
        if (sgn) e[RW + c] = sext(e[RW + c], epb);
        for (unsigned k = 1; k < ne; k++) {
            int *v = &e[3 * k + c];
            if (m->transformed) {
                *v = (e[RW + c] + sext(*v, dbits[c])) & ((1 << epb) - 1);
                if (sgn) *v = sext(*v, epb);
            } else if (sgn) *v = sext(*v, epb);
        }
    }
    int u[12];
    for (unsigned i = 0; i < 3 * ne; i++) u[i] = bc6_unquantize(e[i], epb, sgn);
    unsigned ib = m->two ? 3 : 4;
    const uint8_t *w = weights(ib);
    for (unsigned i = 0; i < 16; i++) {
        unsigned k = m->two ? (unsigned)(P2[part] >> i & 1) : 0;
        unsigned idx = take(&s, ib - (is_anchor(m->two ? 2 : 1, part, i) ? 1 : 0));
        uint16_t *t = (uint16_t *)(out + (i >> 2) * pitch + (i & 3) * 8);
        for (unsigned c = 0; c < 3; c++) {
            int a = u[6 * k + c], b = u[6 * k + 3 + c];
            t[c] = bc6_finish((a * (64 - w[idx]) + b * w[idx] + 32) >> 6, sgn);
        }
        t[3] = 0x3C00;  // (1.0)
    }
}

// ------------------------------------------------------------------ entry points
void bcdec_block(BcKind k, const uint8_t *b, uint8_t *out, size_t pitch) {
    switch (k) {
    case BCDEC_BC1: color_block(b, out, pitch, true); break;
    case BCDEC_BC2:
        color_block(b + 8, out, pitch, false);
        for (int i = 0; i < 16; i++) {
            unsigned a = b[i >> 1] >> ((i & 1) * 4) & 15;
            out[(i >> 2) * pitch + (i & 3) * 4 + 3] = (uint8_t)(a * 17);
        }
        break;
    case BCDEC_BC3:
        color_block(b + 8, out, pitch, false);
        channel_unorm(b, out + 3, pitch, 4);
        break;
    case BCDEC_BC4U: channel_unorm(b, out, pitch, 1); break;
    case BCDEC_BC4S: channel_snorm(b, out, pitch, 1); break;
    case BCDEC_BC5U: channel_unorm(b, out, pitch, 2), channel_unorm(b + 8, out + 1, pitch, 2); break;
    case BCDEC_BC5S: channel_snorm(b, out, pitch, 2), channel_snorm(b + 8, out + 1, pitch, 2); break;
    case BCDEC_BC6U: bc6_block(b, out, pitch, false); break;
    case BCDEC_BC6S: bc6_block(b, out, pitch, true); break;
    case BCDEC_BC7: bc7_block(b, out, pitch); break;
    case BCDEC_NONE: break;
    }
}

uint8_t *bcdec_image(BcKind k, const uint8_t *src, uint32_t wb, uint32_t hb, uint32_t d, size_t src_row) {
    unsigned tb = bcdec_texel_bytes(k), bb = bcdec_block_bytes(k);
    if (!tb) return NULL;
    size_t row = (size_t)wb * 4 * tb, slice = row * hb * 4;
    uint8_t *out = malloc(slice * (d ? d : 1));
    if (!out) return NULL;
    for (uint32_t z = 0; z < (d ? d : 1); z++)
        for (uint32_t y = 0; y < hb; y++) {
            const uint8_t *s = src + ((size_t)z * hb + y) * src_row;
            uint8_t *o = out + z * slice + (size_t)y * 4 * row;
            for (uint32_t x = 0; x < wb; x++) bcdec_block(k, s + (size_t)x * bb, o + (size_t)x * 4 * tb, row);
        }
    return out;
}
