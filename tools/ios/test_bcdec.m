// runtime/nvn/bcdec.c against the GPU's own BC decoding (a Mac with Apple Silicon samples BC1-BC7 natively): random
// blocks of every format, read back texel by texel through a compute kernel, compared with the decoder's output.
// Exit 0 when every format matches within the formats' rounding freedom (or no GPU here samples BC: skipped).
// Build: clang -O1 -fobjc-arc -framework Metal -framework Foundation -Iruntime/nvn tools/ios/test_bcdec.m runtime/nvn/bcdec.c
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bcdec.h"

enum { W = 256, H = 256, BW = W / 4, BH = H / 4 };

static const char *kernel_src =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void rd(texture2d<float, access::read> t [[texture(0)]], device float4 *o [[buffer(0)]],\n"
    "               uint2 g [[thread_position_in_grid]]) { o[g.y * 256 + g.x] = t.read(g); }\n";

static float half_to_float(uint16_t h) {
    uint32_t s = h >> 15, e = h >> 10 & 31, m = h & 1023;
    float v = e == 0 ? ldexpf((float)m, -24) : e == 31 ? (m ? NAN : INFINITY) : ldexpf((float)(m | 1024), (int)e - 25);
    return s ? -v : v;
}

static uint32_t rng = 12345;
static uint8_t rnd8(void) { rng = rng * 1664525u + 1013904223u; return (uint8_t)(rng >> 24); }

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev || !dev.supportsBCTextureCompression) {
            printf("bcdec: no GPU here samples BC textures - skipped\n");
            return 0;
        }
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kernel_src) options:nil error:&err];
        id<MTLComputePipelineState> pipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"rd"] error:&err];
        if (!pipe) { printf("bcdec: kernel: %s\n", err.localizedDescription.UTF8String); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        struct { BcKind k; MTLPixelFormat pf; const char *name; float tol; } cases[] = {
            {BCDEC_BC1, MTLPixelFormatBC1_RGBA, "BC1", 3}, {BCDEC_BC2, MTLPixelFormatBC2_RGBA, "BC2", 3},
            {BCDEC_BC3, MTLPixelFormatBC3_RGBA, "BC3", 3}, {BCDEC_BC4U, MTLPixelFormatBC4_RUnorm, "BC4", 2},
            {BCDEC_BC4S, MTLPixelFormatBC4_RSnorm, "BC4 snorm", 2}, {BCDEC_BC5U, MTLPixelFormatBC5_RGUnorm, "BC5", 2},
            {BCDEC_BC5S, MTLPixelFormatBC5_RGSnorm, "BC5 snorm", 2}, {BCDEC_BC7, MTLPixelFormatBC7_RGBAUnorm, "BC7", 1},
            {BCDEC_BC6U, MTLPixelFormatBC6H_RGBUfloat, "BC6H ufloat", 0.01f},
            {BCDEC_BC6S, MTLPixelFormatBC6H_RGBFloat, "BC6H sfloat", 0.01f},
        };
        int failed = 0;
        for (size_t c = 0; c < sizeof cases / sizeof *cases; c++) {
            unsigned bb = bcdec_block_bytes(cases[c].k), tb = bcdec_texel_bytes(cases[c].k);
            size_t n = (size_t)BW * BH * bb;
            uint8_t *blocks = malloc(n);
            for (size_t i = 0; i < n; i++) blocks[i] = rnd8();
            for (size_t b = 0; b < (size_t)BW * BH; b++) {  // (no reserved modes: the hardware's output for them varies)
                uint8_t *p = blocks + b * bb;
                if (cases[c].k == BCDEC_BC7) while (!p[0]) p[0] = rnd8();
                if (cases[c].k == BCDEC_BC6U || cases[c].k == BCDEC_BC6S)
                    while ((p[0] & 0x13) == 0x13) p[0] = rnd8();  // (0x13 / 0x17 / 0x1B / 0x1F)
            }
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:cases[c].pf width:W height:H mipmapped:NO];
            d.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:d];
            [tex replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:blocks bytesPerRow:BW * bb];
            id<MTLBuffer> out = [dev newBufferWithLength:W * H * 16 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:pipe];
            [e setTexture:tex atIndex:0];
            [e setBuffer:out offset:0 atIndex:0];
            [e dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [e endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            const float *gpu = out.contents;
            uint8_t *mine = bcdec_image(cases[c].k, blocks, BW, BH, 1, BW * bb);
            int channels = tb == 1 ? 1 : tb == 2 ? 2 : cases[c].k == BCDEC_BC6U || cases[c].k == BCDEC_BC6S ? 3 : 4;
            long bad = 0;
            float worst = 0;
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                    for (int ch = 0; ch < channels; ch++) {
                        float g = gpu[(y * W + x) * 4 + ch], m, diff;
                        const uint8_t *t = mine + ((size_t)y * W + x) * tb;
                        if (tb == 8) {  // half floats: relative
                            m = half_to_float(((const uint16_t *)t)[ch]);
                            diff = fabsf(g - m) / fmaxf(fabsf(g), 1e-3f);
                        } else if (cases[c].k == BCDEC_BC4S || cases[c].k == BCDEC_BC5S) {
                            m = (float)(int8_t)t[ch];
                            diff = fabsf(g * 127 - m);
                        } else {
                            m = t[ch];
                            diff = fabsf(g * 255 - m);
                        }
                        if (diff > worst) worst = diff;
                        if (diff > cases[c].tol) {
                            if (bad < 3)
                                printf("  %s texel %d,%d ch %d: gpu %.4f, bcdec %.4f\n", cases[c].name, x, y, ch, g, m);
                            bad++;
                        }
                    }
            long total = (long)W * H * channels;
            bool ok = bad <= total / 1000;  // (a few texels of rounding freedom at most)
            printf("bcdec %-12s %s  %ld of %ld values beyond tolerance (worst %.3f)\n", cases[c].name, ok ? "ok  " : "FAIL",
                   bad, total, worst);
            failed += !ok;
            free(mine);
            free(blocks);
        }
        return failed ? 1 : 0;
    }
}
