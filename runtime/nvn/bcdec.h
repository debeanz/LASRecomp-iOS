// BC1-BC7 (DXT / RGTC / BPTC) decoder to plain texels, for GPUs that can't sample them: most iPhones
// (MTLDevice.supportsBCTextureCompression is NO before Apple's M-series chips). runtime/nvn/metal.m decodes a BC texture's
// blocks when it uploads them and allocates the Metal texture in the decoded format instead (bcdec_pixel_format).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    BCDEC_NONE = 0,
    BCDEC_BC1,   // RGBA8 (1-bit alpha: punch-through when color0 <= color1)
    BCDEC_BC2,   // RGBA8 (explicit 4-bit alpha)
    BCDEC_BC3,   // RGBA8 (interpolated alpha)
    BCDEC_BC4U,  // R8 unorm
    BCDEC_BC4S,  // R8 snorm (int8 texels)
    BCDEC_BC5U,  // RG8 unorm
    BCDEC_BC5S,  // RG8 snorm
    BCDEC_BC6U,  // RGBA16F, unsigned half floats (alpha 1)
    BCDEC_BC6S,  // RGBA16F, signed half floats (alpha 1)
    BCDEC_BC7,   // RGBA8
} BcKind;

// Bytes per decoded texel (4, 1, 2 or 8); 0 for BCDEC_NONE.
unsigned bcdec_texel_bytes(BcKind k);
// Bytes per block of the compressed format (8 for BC1 / BC4, 16 for the rest).
unsigned bcdec_block_bytes(BcKind k);

// One 4x4 block into texels at out (rows `pitch` bytes apart).
void bcdec_block(BcKind k, const uint8_t *block, uint8_t *out, size_t pitch);

// wb x hb blocks of each of d slices, block rows `src_row` bytes apart (slices src_row * hb apart), into texels:
// (4 wb) x (4 hb) x d, tightly packed (rows 4 * wb * bcdec_texel_bytes apart). Returns NULL when out of memory.
uint8_t *bcdec_image(BcKind k, const uint8_t *src, uint32_t wb, uint32_t hb, uint32_t d, size_t src_row);
