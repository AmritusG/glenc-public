/*
 * DXVKit: block streams to RGBA8 (CPU path).
 *
 * BC1 / BC3 per the public S3TC definitions with the integer conventions of docs/spec/DXV_FORMAT.md
 * 8.1 / 8.2; YCG6 / YG10 per section 8.4 (exact BC4 palettes, chroma midpoint 127.5, out-of-gamut
 * folding: what Resolume Arena 7.28 shows).
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#include "dxvk_priv.h"

/* 16 RGBA pixels of a BC1 colour block. four_colour forces the four-colour palette (BC3). */
static void bc1_block(const uint8_t *blk, int four_colour, uint8_t out[16][4])
{
    uint32_t c0 = dxvk_le16(blk), c1 = dxvk_le16(blk + 2), idx = dxvk_le32(blk + 4);
    uint8_t pal[4][4];
    uint32_t r0 = c0 >> 11, g0 = (c0 >> 5) & 63u, b0 = c0 & 31u;
    uint32_t r1 = c1 >> 11, g1 = (c1 >> 5) & 63u, b1 = c1 & 31u;
    pal[0][0] = (uint8_t)((r0 << 3) | (r0 >> 2));
    pal[0][1] = (uint8_t)((g0 << 2) | (g0 >> 4));
    pal[0][2] = (uint8_t)((b0 << 3) | (b0 >> 2));
    pal[1][0] = (uint8_t)((r1 << 3) | (r1 >> 2));
    pal[1][1] = (uint8_t)((g1 << 2) | (g1 >> 4));
    pal[1][2] = (uint8_t)((b1 << 3) | (b1 >> 2));
    pal[0][3] = pal[1][3] = pal[2][3] = pal[3][3] = 255;
    if (four_colour || c0 > c1) {
        for (int k = 0; k < 3; k++) {
            pal[2][k] = (uint8_t)((2u * pal[0][k] + pal[1][k]) / 3u);
            pal[3][k] = (uint8_t)((pal[0][k] + 2u * pal[1][k]) / 3u);
        }
    } else {
        for (int k = 0; k < 3; k++) {
            pal[2][k] = (uint8_t)((pal[0][k] + pal[1][k]) / 2u);
            pal[3][k] = 0;
        }
    }
    for (int i = 0; i < 16; i++, idx >>= 2)
        memcpy(out[i], pal[idx & 3u], 4);
}

/* 16 values of a BC4 block (also the BC3 alpha half). */
static void bc4_block(const uint8_t *blk, uint8_t out[16])
{
    uint32_t a0 = blk[0], a1 = blk[1];
    uint64_t idx = (uint64_t)dxvk_le24(blk + 2) | ((uint64_t)dxvk_le24(blk + 5) << 24);
    uint8_t pal[8];
    pal[0] = (uint8_t)a0;
    pal[1] = (uint8_t)a1;
    if (a0 > a1) {
        for (uint32_t i = 1; i <= 6; i++)
            pal[1 + i] = (uint8_t)(((7u - i) * a0 + i * a1) / 7u);
    } else {
        for (uint32_t i = 1; i <= 4; i++)
            pal[1 + i] = (uint8_t)(((5u - i) * a0 + i * a1) / 5u);
        pal[6] = 0;
        pal[7] = 255;
    }
    for (int i = 0; i < 16; i++, idx >>= 3)
        out[i] = pal[idx & 7u];
}

/* 16 values of a BC4 block with the exact (untruncated) palette, in units of 1/35: eight-value entries
 * are sevenths, six-value entries fifths, so every palette value is a whole number of 35ths. */
static void bc4_block_exact(const uint8_t *blk, uint16_t out[16])
{
    uint32_t a0 = blk[0], a1 = blk[1];
    uint64_t idx = (uint64_t)dxvk_le24(blk + 2) | ((uint64_t)dxvk_le24(blk + 5) << 24);
    uint16_t pal[8];
    pal[0] = (uint16_t)(a0 * 35u);
    pal[1] = (uint16_t)(a1 * 35u);
    if (a0 > a1) {
        for (uint32_t i = 1; i <= 6; i++)
            pal[1 + i] = (uint16_t)(((7u - i) * a0 + i * a1) * 5u);
    } else {
        for (uint32_t i = 1; i <= 4; i++)
            pal[1 + i] = (uint16_t)(((5u - i) * a0 + i * a1) * 7u);
        pal[6] = 0;
        pal[7] = 255u * 35u;
    }
    for (int i = 0; i < 16; i++, idx >>= 3)
        out[i] = pal[idx & 7u];
}

DXVK_INLINE uint8_t premul(uint32_t c, uint32_t a) { return (uint8_t)((c * a + 127u) / 255u); }

typedef struct rgba_job {
    const dxvk_frame_layout *layout;
    const uint8_t *plane[2];
    uint8_t *rgba;
    size_t stride;
    int premultiply;
    uint32_t units;      /* rows of tiles: 4-pixel block rows (BC1/BC3) or 8-pixel rows (HQ) */
    int bands;
} rgba_job;

static void rows_bc(const rgba_job *j, uint32_t row_begin, uint32_t row_end)
{
    const dxvk_frame_layout *l = j->layout;
    int bc3 = l->format[0] == DXVK_BLOCKS_BC3;
    size_t block_bytes = bc3 ? 16u : 8u;
    uint8_t px[16][4], alpha[16];

    for (uint32_t by = row_begin; by < row_end; by++) {
        uint32_t y0 = by * 4u, rows = l->display_height - y0;
        if (rows > 4u)
            rows = 4u;
        for (uint32_t bx = 0; bx < l->blocks_x[0]; bx++) {
            const uint8_t *blk = j->plane[0] + ((size_t)by * l->blocks_x[0] + bx) * block_bytes;
            uint32_t x0 = bx * 4u, cols = l->display_width - x0;
            if (x0 >= l->display_width)
                break;
            if (cols > 4u)
                cols = 4u;
            if (bc3) {
                bc4_block(blk, alpha);
                bc1_block(blk + 8, 1, px);
                for (int i = 0; i < 16; i++) {
                    px[i][3] = alpha[i];
                    if (j->premultiply) {
                        px[i][0] = premul(px[i][0], alpha[i]);
                        px[i][1] = premul(px[i][1], alpha[i]);
                        px[i][2] = premul(px[i][2], alpha[i]);
                    }
                }
            } else {
                bc1_block(blk, 0, px); /* opaque: alpha already 255, index 3 black */
            }
            for (uint32_t y = 0; y < rows; y++)
                memcpy(j->rgba + (size_t)(y0 + y) * j->stride + (size_t)x0 * 4u, px[y * 4u],
                       (size_t)cols * 4u);
        }
    }
}

/* Fixed point for the HQ path: units of 1/70 (the 1/35 palette values doubled, so that the chroma
 * midpoint 127.5 is a whole number). */
#define HQ_ONE 70
#define HQ_MAX (255 * HQ_ONE)
#define HQ_MID (255 * HQ_ONE / 2) /* 127.5 */

/* round to nearest (halves up) and clamp: units of 1/70 -> 0..255 */
DXVK_INLINE uint8_t hq_round(int v)
{
    return (uint8_t)(v <= 0 ? 0 : v >= HQ_MAX ? 255 : (v + HQ_ONE / 2) / HQ_ONE);
}

/* YCoCg -> RGB with Resolume Arena's convention (spec 8.4): chroma midpoint 127.5, out-of-gamut R / B
 * overflow carried into the other channel, then rounding. Y, co, cg in units of 1/70. */
DXVK_INLINE void hq_rgb(int y, int co, int cg, uint8_t *dst)
{
    int t = y - cg, r = t + co, g = y + cg, b = t - co;
    if (r < 0) {
        b += r;
        r = 0;
    }
    if (b < 0) {
        r += b;
        b = 0;
    }
    if (r > HQ_MAX) {
        b += r - HQ_MAX;
        r = HQ_MAX;
    }
    if (b > HQ_MAX) {
        r += b - HQ_MAX;
        b = HQ_MAX;
    }
    dst[0] = hq_round(r);
    dst[1] = hq_round(g);
    dst[2] = hq_round(b);
}

static void rows_hq(const rgba_job *j, uint32_t row_begin, uint32_t row_end)
{
    const dxvk_frame_layout *l = j->layout;
    int ya = l->format[0] == DXVK_BLOCKS_BC5;
    size_t y_bytes = ya ? 16u : 8u;
    uint16_t co[16], cg[16], yv[16], av[16];

    for (uint32_t cy = row_begin; cy < row_end; cy++) {
        for (uint32_t cx = 0; cx < l->blocks_x[1]; cx++) {
            const uint8_t *cblk = j->plane[1] + ((size_t)cy * l->blocks_x[1] + cx) * 16u;
            if (cx * 8u >= l->display_width)
                break;
            bc4_block_exact(cblk, co);
            bc4_block_exact(cblk + 8, cg);
            for (uint32_t sub = 0; sub < 4; sub++) {
                uint32_t bx = cx * 2u + (sub & 1u), by = cy * 2u + (sub >> 1);
                uint32_t x0 = bx * 4u, y0 = by * 4u, cols, rows;
                const uint8_t *yblk;
                if (x0 >= l->display_width || y0 >= l->display_height)
                    continue;
                cols = l->display_width - x0;
                rows = l->display_height - y0;
                if (cols > 4u)
                    cols = 4u;
                if (rows > 4u)
                    rows = 4u;
                yblk = j->plane[0] + ((size_t)by * l->blocks_x[0] + bx) * y_bytes;
                bc4_block_exact(yblk, yv);
                if (ya)
                    bc4_block_exact(yblk + 8, av);
                for (uint32_t y = 0; y < rows; y++) {
                    uint8_t *dst = j->rgba + (size_t)(y0 + y) * j->stride + (size_t)x0 * 4u;
                    /* chroma sample of pixel (x0 + x, y0 + y) inside this chroma block: nearest */
                    uint32_t crow = ((by & 1u) * 4u + y) / 2u;
                    for (uint32_t x = 0; x < cols; x++, dst += 4) {
                        uint32_t ci = crow * 4u + ((bx & 1u) * 4u + x) / 2u;
                        uint8_t a = ya ? hq_round(2 * av[y * 4u + x]) : 255;
                        hq_rgb(2 * yv[y * 4u + x], 2 * co[ci] - HQ_MID, 2 * cg[ci] - HQ_MID, dst);
                        if (j->premultiply && ya) {
                            dst[0] = premul(dst[0], a);
                            dst[1] = premul(dst[1], a);
                            dst[2] = premul(dst[2], a);
                        }
                        dst[3] = a;
                    }
                }
            }
        }
    }
}

static void rgba_band(void *arg, int band)
{
    const rgba_job *j = (const rgba_job *)arg;
    uint32_t begin = (uint32_t)((uint64_t)j->units * (uint32_t)band / (uint32_t)j->bands);
    uint32_t end = (uint32_t)((uint64_t)j->units * (uint32_t)(band + 1) / (uint32_t)j->bands);
    if (j->layout->plane_count == 2)
        rows_hq(j, begin, end);
    else
        rows_bc(j, begin, end);
}

dxvk_status dxvk_blocks_to_rgba(const dxvk_frame_layout *layout, const void *const planes[2],
                                const dxvk_options *options, uint8_t *rgba, size_t stride)
{
    rgba_job j;
    dxvk_frame_layout check;
    if (!layout || !planes || !rgba || !planes[0])
        return DXVK_ERR_ARGUMENT;
    /* recompute the geometry: only variant and display size are taken from the caller */
    if (dxvk_layout(layout->variant, layout->display_width, layout->display_height, &check) !=
        DXVK_OK)
        return DXVK_ERR_ARGUMENT;
    layout = &check;
    if (layout->plane_count == 2 && !planes[1])
        return DXVK_ERR_ARGUMENT;
    if (stride / 4u < layout->display_width)
        return DXVK_ERR_ARGUMENT;

    j.layout = layout;
    j.plane[0] = (const uint8_t *)planes[0];
    j.plane[1] = layout->plane_count == 2 ? (const uint8_t *)planes[1] : NULL;
    j.rgba = rgba;
    j.stride = stride;
    j.premultiply = options && (options->flags & DXVK_OPT_PREMULTIPLY) &&
                    dxvk_variant_has_alpha(layout->variant);
    /* only the rows that hold display pixels */
    j.units = layout->plane_count == 2 ? (layout->display_height + 7u) / 8u
                                       : (layout->display_height + 3u) / 4u;
    if (options && options->jobs && options->jobs->run) {
        j.bands = j.units < 32u ? (int)j.units : 32;
        options->jobs->run(options->jobs->user, rgba_band, &j, j.bands);
    } else {
        j.bands = 1;
        rgba_band(&j, 0);
    }
    return DXVK_OK;
}
