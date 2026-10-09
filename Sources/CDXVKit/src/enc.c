/*
 * DXVKit encoder: the encoder object, RGBA -> block planes (with the forward YCoCg transform for the
 * HQ variants), DXV3 packet headers and dispatch to the packers.
 *
 * Written from docs/spec/DXV_FORMAT.md sections 2.3, 3, 8 and docs/spec/ENCODING_NOTES.md.
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#include "enc_priv.h"

#include <stdlib.h>

#define DXV3_HEADER 12u
#define TAG_DXT1 0x44585431u
#define TAG_DXT5 0x44585435u
#define TAG_YCG6 0x59434736u
#define TAG_YG10 0x59473130u
#define MAX_BANDS 64

static int is_dxv3(dxvk_variant v)
{
    return v == DXVK_VARIANT_DXT1 || v == DXVK_VARIANT_DXT5 || v == DXVK_VARIANT_YCG6 ||
           v == DXVK_VARIANT_YG10;
}

static size_t total_blocks(const dxvk_frame_layout *l, int plane)
{
    return (size_t)l->blocks_x[plane] * l->blocks_y[plane];
}

size_t dxvk_encode_bound(dxvk_variant variant, uint32_t width, uint32_t height)
{
    dxvk_frame_layout l;
    size_t n, packed;
    if (!is_dxv3(variant) || dxvk_layout(variant, width, height, &l) != DXVK_OK)
        return 0;
    n = total_blocks(&l, 0);
    switch (variant) {
    case DXVK_VARIANT_DXT1: packed = 8u + 12u * n + 16u; break;
    case DXVK_VARIANT_DXT5: packed = 16u + 24u * n + 32u; break;
    default:
        packed = dxvk_hq_section_bound(variant == DXVK_VARIANT_YG10 ? 2 : 1, n) +
                 dxvk_hq_section_bound(2, total_blocks(&l, 1));
        break;
    }
    if (packed < l.bytes[0])
        packed = l.bytes[0]; /* stored payloads */
    return DXV3_HEADER + packed;
}

static unsigned table_bits(size_t blocks, int best)
{
    unsigned bits = 10, cap = best ? 20u : 16u;
    while (bits < cap && ((size_t)1 << (bits - 1u)) < blocks)
        bits++;
    return bits;
}

static int alloc_table(match_table *t, unsigned bits)
{
    t->bits = bits;
    t->slot = (uint32_t *)calloc((size_t)1 << bits, sizeof *t->slot);
    return t->slot != NULL;
}

static int alloc_section(hq_section *s, int channels, size_t blocks, size_t stride, int best,
                         int stored_only)
{
    s->channels = channels;
    s->blocks = blocks;
    s->stride = stride;
    s->best = best;
    s->stored_only = stored_only;
    s->literal_cap = 8u * (size_t)channels * blocks + 16u;
    s->literals = (uint8_t *)malloc(s->literal_cap);
    s->out_cap = dxvk_hq_section_bound(channels, blocks);
    s->out = (uint8_t *)malloc(s->out_cap);
    if (!s->literals || !s->out)
        return 0;
    for (int ch = 0; ch < channels; ch++) {
        hq_channel *h = &s->ch[ch];
        unsigned bits = table_bits(blocks, best);
        h->ops = (uint8_t *)malloc(blocks);
        h->stream_cap = 32u + 2u * blocks;
        h->stream = (uint8_t *)malloc(h->stream_cap);
        if (!h->ops || !h->stream || !alloc_table(&h->whole, bits) || !alloc_table(&h->index6, bits))
            return 0;
    }
    return 1;
}

void dxvk_encoder_destroy(dxvk_encoder *e)
{
    if (!e)
        return;
    free(e->plane[0]);
    free(e->plane[1]);
    for (int i = 0; i < 5; i++)
        free(e->bt[i].slot);
    for (int s = 0; s < 2; s++) {
        free(e->sec[s].literals);
        free(e->sec[s].out);
        for (int ch = 0; ch < 2; ch++) {
            free(e->sec[s].ch[ch].ops);
            free(e->sec[s].ch[ch].stream);
            free(e->sec[s].ch[ch].whole.slot);
            free(e->sec[s].ch[ch].index6.slot);
        }
    }
    free(e);
}

dxvk_status dxvk_encoder_create(dxvk_variant variant, uint32_t width, uint32_t height,
                                const dxvk_encode_options *options, dxvk_encoder **out)
{
    dxvk_encoder *e;
    dxvk_status st;
    int best, ok = 1;
    if (!out)
        return DXVK_ERR_ARGUMENT;
    *out = NULL;
    if (!is_dxv3(variant))
        return DXVK_ERR_ARGUMENT;
    if (options && ((options->flags & ~(DXVK_ENC_PREMULTIPLIED_INPUT | DXVK_ENC_STORED_PAYLOAD)) ||
                    (unsigned)options->effort > DXVK_EFFORT_BEST ||
                    (unsigned)options->opcodes > DXVK_OPCODES_STORED))
        return DXVK_ERR_ARGUMENT;
    if (options && (options->flags & DXVK_ENC_STORED_PAYLOAD) &&
        (variant == DXVK_VARIANT_YCG6 || variant == DXVK_VARIANT_YG10))
        return DXVK_ERR_UNSUPPORTED;
    e = (dxvk_encoder *)calloc(1, sizeof *e);
    if (!e)
        return DXVK_ERR_OUT_OF_MEMORY;
    if ((st = dxvk_layout(variant, width, height, &e->layout)) != DXVK_OK) {
        free(e);
        return st;
    }
    e->variant = variant;
    if (options)
        e->opt = *options;
    if (e->opt.jobs && e->opt.jobs->run) {
        e->jobs = *e->opt.jobs;
        e->have_jobs = 1;
    }
    best = e->opt.effort == DXVK_EFFORT_BEST;
    for (int i = 0; i < e->layout.plane_count; i++) {
        e->plane[i] = (uint8_t *)malloc(e->layout.bytes[i]);
        ok = ok && e->plane[i];
    }
    if (variant == DXVK_VARIANT_DXT1 || variant == DXVK_VARIANT_DXT5) {
        unsigned bits = table_bits(total_blocks(&e->layout, 0), best);
        int tables = variant == DXVK_VARIANT_DXT1 ? 3 : 4;
        for (int i = 0; i < tables; i++)
            ok = ok && alloc_table(&e->bt[i], bits);
    } else {
        int stored_only = e->opt.opcodes == DXVK_OPCODES_STORED;
        int alpha = variant == DXVK_VARIANT_YG10;
        ok = ok && alloc_section(&e->sec[0], alpha ? 2 : 1, total_blocks(&e->layout, 0),
                                 alpha ? 16u : 8u, best, stored_only);
        ok = ok && alloc_section(&e->sec[1], 2, total_blocks(&e->layout, 1), 16u, best, stored_only);
    }
    if (!ok) {
        dxvk_encoder_destroy(e);
        return DXVK_ERR_OUT_OF_MEMORY;
    }
    *out = e;
    return DXVK_OK;
}

const dxvk_frame_layout *dxvk_encoder_layout(const dxvk_encoder *e) { return e ? &e->layout : NULL; }

const void *dxvk_encoder_plane(const dxvk_encoder *e, int plane)
{
    if (!e || !e->have_planes || plane < 0 || plane >= e->layout.plane_count)
        return NULL;
    return e->plane[plane];
}

/* ---------------------------------------------------------------------------------------------- */
/* RGBA -> block planes                                                                           */
/* ---------------------------------------------------------------------------------------------- */

typedef struct compress_job {
    const dxvk_encoder *e;
    const uint8_t *rgba;
    size_t stride;
    uint8_t *plane[2];
    uint32_t units;   /* block rows (BC1 / BC3) or chroma block rows (HQ) */
    int bands;
} compress_job;

/* Pixel (x, y) of the padded texture: the display picture extended by edge replication. */
DXVK_INLINE const uint8_t *pixel(const compress_job *j, uint32_t x, uint32_t y)
{
    const dxvk_frame_layout *l = &j->e->layout;
    if (x >= l->display_width)
        x = l->display_width - 1u;
    if (y >= l->display_height)
        y = l->display_height - 1u;
    return j->rgba + (size_t)y * j->stride + (size_t)x * 4u;
}

static void rows_bc(const compress_job *j, uint32_t begin, uint32_t end)
{
    const dxvk_encoder *e = j->e;
    const dxvk_frame_layout *l = &e->layout;
    int bc3 = e->variant == DXVK_VARIANT_DXT5, best = e->opt.effort == DXVK_EFFORT_BEST;
    size_t block_bytes = bc3 ? 16u : 8u;
    uint8_t px[16][4], alpha[16];
    for (uint32_t by = begin; by < end; by++) {
        for (uint32_t bx = 0; bx < l->blocks_x[0]; bx++) {
            uint8_t *dst = j->plane[0] + ((size_t)by * l->blocks_x[0] + bx) * block_bytes;
            for (uint32_t y = 0; y < 4; y++)
                for (uint32_t x = 0; x < 4; x++)
                    memcpy(px[y * 4u + x], pixel(j, bx * 4u + x, by * 4u + y), 4);
            if (bc3) {
                for (int i = 0; i < 16; i++)
                    alpha[i] = px[i][3];
                dxvk_bc4_encode(alpha, best, dst);
                dxvk_bc1_encode((const uint8_t(*)[4])px, best, 1, dst + 8);
            } else {
                dxvk_bc1_encode((const uint8_t(*)[4])px, best, 0, dst);
            }
        }
    }
}

static void rows_hq(const compress_job *j, uint32_t begin, uint32_t end)
{
    const dxvk_encoder *e = j->e;
    const dxvk_frame_layout *l = &e->layout;
    int ya = e->variant == DXVK_VARIANT_YG10, best = e->opt.effort == DXVK_EFFORT_BEST;
    size_t y_bytes = ya ? 16u : 8u;
    uint16_t yv[8][8], blk16[16], co[16], cg[16];
    uint8_t av[8][8], blk[16];

    for (uint32_t cy = begin; cy < end; cy++) {
        for (uint32_t cx = 0; cx < l->blocks_x[1]; cx++) {
            /* Forward YCoCg over the 8 x 8 pixels of one chroma block, exact and unrounded, in units
             * of 1/16 (ENCODING_NOTES 5): Y = (R + 2G + B) / 4; Co, Cg = the 2 x 2 box average of
             * (R - B) / 2 and (2G - R - B) / 4, + 127.5. Co and Cg span exactly 0..255. */
            for (uint32_t sy = 0; sy < 4; sy++) {
                for (uint32_t sx = 0; sx < 4; sx++) {
                    int sum_co = 0, sum_cg = 0;
                    for (uint32_t k = 0; k < 4; k++) {
                        uint32_t x = sx * 2u + (k & 1u), y = sy * 2u + (k >> 1);
                        const uint8_t *p = pixel(j, cx * 8u + x, cy * 8u + y);
                        int r = p[0], g = p[1], b = p[2];
                        yv[y][x] = (uint16_t)(4 * (r + 2 * g + b));
                        av[y][x] = p[3];
                        sum_co += r - b;          /* 2 co per pixel, 4 pixels: 8 co */
                        sum_cg += 2 * g - r - b;  /* 4 cg per pixel, 4 pixels: 16 cg */
                    }
                    co[sy * 4u + sx] = (uint16_t)(2 * sum_co + 2040); /* 16 (sum / 8 + 127.5) */
                    cg[sy * 4u + sx] = (uint16_t)(sum_cg + 2040);     /* 16 (sum / 16 + 127.5) */
                }
            }
            for (uint32_t sub = 0; sub < 4; sub++) {
                uint32_t ox = (sub & 1u) * 4u, oy = (sub >> 1) * 4u;
                uint32_t bx = cx * 2u + (sub & 1u), by = cy * 2u + (sub >> 1);
                uint8_t *dst = j->plane[0] + ((size_t)by * l->blocks_x[0] + bx) * y_bytes;
                for (uint32_t y = 0; y < 4; y++)
                    for (uint32_t x = 0; x < 4; x++)
                        blk16[y * 4u + x] = yv[oy + y][ox + x];
                dxvk_bc4_encode_fine(blk16, best, dst);
                if (ya) {
                    for (uint32_t y = 0; y < 4; y++)
                        for (uint32_t x = 0; x < 4; x++)
                            blk[y * 4u + x] = av[oy + y][ox + x];
                    dxvk_bc4_encode(blk, best, dst + 8);
                }
            }
            {
                uint8_t *dst = j->plane[1] + ((size_t)cy * l->blocks_x[1] + cx) * 16u;
                dxvk_bc4_encode_fine(co, best, dst);
                dxvk_bc4_encode_fine(cg, best, dst + 8);
            }
        }
    }
}

static void compress_band(void *arg, int band)
{
    const compress_job *j = (const compress_job *)arg;
    uint32_t begin = (uint32_t)((uint64_t)j->units * (uint32_t)band / (uint32_t)j->bands);
    uint32_t end = (uint32_t)((uint64_t)j->units * (uint32_t)(band + 1) / (uint32_t)j->bands);
    if (j->e->layout.plane_count == 2)
        rows_hq(j, begin, end);
    else
        rows_bc(j, begin, end);
}

dxvk_status dxvk_encoder_compress(dxvk_encoder *e, const uint8_t *rgba, size_t stride,
                                  void *const planes[2], const size_t plane_capacity[2])
{
    compress_job j;
    if (!e || !rgba || !planes || !plane_capacity)
        return DXVK_ERR_ARGUMENT;
    if (stride / 4u < e->layout.display_width)
        return DXVK_ERR_ARGUMENT;
    for (int i = 0; i < e->layout.plane_count; i++) {
        if (!planes[i])
            return DXVK_ERR_ARGUMENT;
        if (plane_capacity[i] < e->layout.bytes[i])
            return DXVK_ERR_BUFFER_TOO_SMALL;
    }
    j.e = e;
    j.rgba = rgba;
    j.stride = stride;
    j.plane[0] = (uint8_t *)planes[0];
    j.plane[1] = e->layout.plane_count == 2 ? (uint8_t *)planes[1] : NULL;
    j.units = e->layout.plane_count == 2 ? e->layout.blocks_y[1] : e->layout.blocks_y[0];
    if (e->have_jobs && j.units > 1u) {
        j.bands = j.units < (uint32_t)MAX_BANDS ? (int)j.units : MAX_BANDS;
        e->jobs.run(e->jobs.user, compress_band, &j, j.bands);
    } else {
        j.bands = 1;
        compress_band(&j, 0);
    }
    return DXVK_OK;
}

/* ---------------------------------------------------------------------------------------------- */
/* Packets                                                                                        */
/* ---------------------------------------------------------------------------------------------- */

dxvk_status dxvk_encoder_pack(dxvk_encoder *e, const void *const planes[2], void *packet,
                              size_t capacity, size_t *packet_size)
{
    uint8_t *out = (uint8_t *)packet;
    const uint8_t *p0, *p1;
    size_t payload = 0;
    uint32_t tag;
    int stored;
    dxvk_status st;
    if (!e || !planes || !packet || !packet_size || !planes[0] ||
        (e->layout.plane_count == 2 && !planes[1]))
        return DXVK_ERR_ARGUMENT;
    if (capacity < DXV3_HEADER)
        return DXVK_ERR_BUFFER_TOO_SMALL;
    p0 = (const uint8_t *)planes[0];
    p1 = (const uint8_t *)planes[1];
    stored = (e->opt.flags & DXVK_ENC_STORED_PAYLOAD) != 0;
    switch (e->variant) {
    case DXVK_VARIANT_DXT1: tag = TAG_DXT1; break;
    case DXVK_VARIANT_DXT5: tag = TAG_DXT5; break;
    case DXVK_VARIANT_YCG6: tag = TAG_YCG6; break;
    default: tag = TAG_YG10; break;
    }
    if (stored) {
        if (capacity - DXV3_HEADER < e->layout.bytes[0])
            return DXVK_ERR_BUFFER_TOO_SMALL;
        memcpy(out + DXV3_HEADER, p0, e->layout.bytes[0]);
        payload = e->layout.bytes[0];
        st = DXVK_OK;
    } else if (e->variant == DXVK_VARIANT_DXT1) {
        st = dxvk_pack_dxt1(e, p0, out + DXV3_HEADER, capacity - DXV3_HEADER, &payload);
    } else if (e->variant == DXVK_VARIANT_DXT5) {
        st = dxvk_pack_dxt5(e, p0, out + DXV3_HEADER, capacity - DXV3_HEADER, &payload);
    } else {
        st = dxvk_pack_hq(e, p0, p1, out + DXV3_HEADER, capacity - DXV3_HEADER, &payload);
    }
    if (st != DXVK_OK)
        return st;
    if (payload > 0xFFFFFFFFu)
        return DXVK_ERR_ARGUMENT;
    dxvk_put32(out, tag);  /* the FourCC's bytes reversed (spec 3.1) */
    out[4] = 4;            /* format version 3 + 1 */
    out[5] = 0;
    out[6] = (uint8_t)stored;
    out[7] = 0;
    dxvk_put32(out + 8, (uint32_t)payload);
    *packet_size = DXV3_HEADER + payload;
    return DXVK_OK;
}

dxvk_status dxvk_encoder_encode(dxvk_encoder *e, const uint8_t *rgba, size_t stride, void *packet,
                                size_t capacity, size_t *packet_size)
{
    dxvk_status st;
    void *planes[2];
    const void *cplanes[2];
    if (!e)
        return DXVK_ERR_ARGUMENT;
    planes[0] = e->plane[0];
    planes[1] = e->plane[1];
    st = dxvk_encoder_compress(e, rgba, stride, planes, e->layout.bytes);
    if (st != DXVK_OK)
        return st;
    e->have_planes = 1;
    cplanes[0] = e->plane[0];
    cplanes[1] = e->plane[1];
    return dxvk_encoder_pack(e, cplanes, packet, capacity, packet_size);
}
