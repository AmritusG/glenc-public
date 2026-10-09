/*
 * DXVKit encoder: the DXV3 block-copy layers for DXT1 (BC1) and DXT5 (BC3).
 *
 * Written from docs/spec/DXV_FORMAT.md sections 5 and 6 and docs/spec/ENCODING_NOTES.md section 6.
 * The packer emits exactly what the decoder reads, in the decoder's order.
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#include "enc_priv.h"

#define MAX_DISTANCE 65793u      /* u16 + 258 */
#define MAX_ALPHA_DISTANCE 65537u /* u16 + 2 */

/* Output with 2-bit flags packed 16 per u32, the word placed where the decoder reads its first flag. */
typedef struct flag_writer {
    uint8_t *out;
    size_t pos, cap;
    size_t word_pos;
    unsigned used;               /* flags in the current word; 16 = full (or none yet) */
} flag_writer;

DXVK_INLINE void put_flag(flag_writer *w, unsigned flag)
{
    if (w->used == 16u) {
        w->word_pos = w->pos;
        memset(w->out + w->pos, 0, 4);
        w->pos += 4;
        w->used = 0;
    }
    w->out[w->word_pos + w->used / 4u] |= (uint8_t)(flag << (2u * (w->used & 3u)));
    w->used++;
}

DXVK_INLINE void put_byte(flag_writer *w, uint32_t v) { w->out[w->pos++] = (uint8_t)v; }

DXVK_INLINE void put_u16(flag_writer *w, uint32_t v)
{
    dxvk_put16(w->out + w->pos, v);
    w->pos += 2;
}

DXVK_INLINE void put_bytes(flag_writer *w, const uint8_t *p, size_t n)
{
    memcpy(w->out + w->pos, p, n);
    w->pos += n;
}

/* Count extension (spec 6.4): u16 values while each is 0xFFFF; `rest` = count beyond the first byte. */
static void put_extension(flag_writer *w, size_t rest)
{
    while (rest >= 0xFFFFu) {
        put_u16(w, 0xFFFFu);
        rest -= 0xFFFFu;
    }
    put_u16(w, (uint32_t)rest);
}

DXVK_INLINE size_t extension_bytes(size_t rest) { return 2u * (rest / 0xFFFFu + 1u); }

/* Cost in bits of a distance code (flag included), or 0 for "not codable". */
DXVK_INLINE unsigned distance_bits(size_t d)
{
    if (d == 1)
        return 2;
    if (d >= 2 && d <= 257)
        return 10;
    if (d >= 258 && d <= MAX_DISTANCE)
        return 18;
    return 0;
}

DXVK_INLINE void put_distance(flag_writer *w, size_t d)
{
    if (d == 1) {
        put_flag(w, 1);
    } else if (d <= 257) {
        put_flag(w, 2);
        put_byte(w, (uint32_t)(d - 2));
    } else {
        put_flag(w, 3);
        put_u16(w, (uint32_t)(d - 258));
    }
}

DXVK_INLINE uint64_t load(const uint8_t *p, size_t n)
{
    return n == 8 ? dxvk_le64(p) : n == 4 ? (uint64_t)dxvk_le32(p) : 0;
}

/* Nearest earlier block (< b) whose `n` bytes at `offset` equal block b's, as a distance (0 = none). */
DXVK_INLINE size_t find(const match_table *t, const uint8_t *blocks, size_t stride, size_t b,
                        size_t offset, size_t n)
{
    const uint8_t *cur = blocks + b * stride + offset;
    uint32_t j = t->slot[match_hash(t, load(cur, n))];
    if (j == 0 || j - 1u >= b)
        return 0;
    if (memcmp(blocks + (size_t)(j - 1u) * stride + offset, cur, n) != 0)
        return 0;
    return b - (j - 1u);
}

DXVK_INLINE void remember(match_table *t, const uint8_t *blocks, size_t stride, size_t b,
                          size_t offset, size_t n)
{
    t->slot[match_hash(t, load(blocks + b * stride + offset, n))] = (uint32_t)(b + 1u);
}

static void clear_tables(match_table *t, int count)
{
    for (int i = 0; i < count; i++)
        memset(t[i].slot, 0, ((size_t)1 << t[i].bits) * sizeof *t[i].slot);
}

/*
 * One 4-byte unit (DXT1 half, DXT5 colour quarter) or one 8-byte part (DXT5 colour half): the bits of
 * its cheapest coding and the distance (0 = literal).
 */
DXVK_INLINE unsigned unit_cost(const match_table *t, const uint8_t *blocks, size_t stride, size_t b,
                               size_t offset, size_t n, size_t *dist)
{
    size_t d;
    if (memcmp(blocks + b * stride + offset, blocks + (b - 1u) * stride + offset, n) == 0) {
        *dist = 1;
        return 2;
    }
    d = find(t, blocks, stride, b, offset, n);
    if (d && distance_bits(d)) {
        *dist = d;
        return distance_bits(d);
    }
    *dist = 0;
    return 2u + 8u * (unsigned)n;
}

DXVK_INLINE void put_unit(flag_writer *w, const uint8_t *src, size_t n, size_t dist)
{
    if (dist) {
        put_distance(w, dist);
    } else {
        put_flag(w, 0);
        put_bytes(w, src, n);
    }
}

dxvk_status dxvk_pack_dxt1(dxvk_encoder *e, const uint8_t *blocks, uint8_t *out, size_t cap,
                           size_t *size)
{
    size_t count = (size_t)e->layout.blocks_x[0] * e->layout.blocks_y[0];
    match_table *whole = &e->bt[0], *half0 = &e->bt[1], *half1 = &e->bt[2];
    flag_writer w;

    if (cap < 8)
        return DXVK_ERR_BUFFER_TOO_SMALL;
    clear_tables(e->bt, 3);
    w.out = out;
    w.pos = 0;
    w.cap = cap;
    w.word_pos = 0;
    w.used = 16;
    put_bytes(&w, blocks, 8);
    remember(whole, blocks, 8, 0, 0, 8);
    remember(half0, blocks, 8, 0, 0, 4);
    remember(half1, blocks, 8, 0, 4, 4);

    for (size_t b = 1; b < count; b++) {
        const uint8_t *cur = blocks + b * 8u;
        size_t dw = 0, d0, d1;
        unsigned whole_bits = 0, split_bits;
        /* worst case per block: a new flag word, 8 literal bytes */
        if (w.cap - w.pos < 16)
            return DXVK_ERR_BUFFER_TOO_SMALL;
        if (memcmp(cur, cur - 8, 8) == 0) {
            dw = 1;
            whole_bits = 2;
        } else {
            dw = find(whole, blocks, 8, b, 0, 8);
            whole_bits = dw ? distance_bits(dw) : 0;
        }
        if (whole_bits == 2) {
            put_flag(&w, 1);
        } else {
            split_bits = 2u + unit_cost(half0, blocks, 8, b, 0, 4, &d0) +
                         unit_cost(half1, blocks, 8, b, 4, 4, &d1);
            if (whole_bits && whole_bits <= split_bits) {
                put_distance(&w, dw);
            } else {
                put_flag(&w, 0);
                put_unit(&w, cur, 4, d0);
                put_unit(&w, cur + 4, 4, d1);
            }
        }
        remember(whole, blocks, 8, b, 0, 8);
        remember(half0, blocks, 8, b, 0, 4);
        remember(half1, blocks, 8, b, 4, 4);
    }
    *size = w.pos;
    return DXVK_OK;
}

/* Number of blocks from b on (at most `limit`) that each equal their predecessor in `n` bytes at
 * `offset`. */
DXVK_INLINE size_t repeats(const uint8_t *blocks, size_t stride, size_t b, size_t count,
                           size_t offset, size_t n)
{
    size_t k = b;
    while (k < count &&
           memcmp(blocks + k * stride + offset, blocks + (k - 1u) * stride + offset, n) == 0)
        k++;
    return k - b;
}

/* Whole-block run length that makes a block run cheaper than continuing an alpha run through it. */
#define BEST_RUN_CUT 11u

dxvk_status dxvk_pack_dxt5(dxvk_encoder *e, const uint8_t *blocks, uint8_t *out, size_t cap,
                           size_t *size)
{
    size_t count = (size_t)e->layout.blocks_x[0] * e->layout.blocks_y[0];
    match_table *alpha = &e->bt[0], *colour = &e->bt[1], *q0 = &e->bt[2], *q1 = &e->bt[3];
    int best = e->opt.effort == DXVK_EFFORT_BEST;
    size_t alpha_run = 0, b = 1;
    flag_writer w;

    if (cap < 16)
        return DXVK_ERR_BUFFER_TOO_SMALL;
    clear_tables(e->bt, 4);
    w.out = out;
    w.pos = 0;
    w.cap = cap;
    w.word_pos = 0;
    w.used = 16;
    put_bytes(&w, blocks, 16);
    remember(alpha, blocks, 16, 0, 0, 8);
    remember(colour, blocks, 16, 0, 8, 8);
    remember(q0, blocks, 16, 0, 8, 4);
    remember(q1, blocks, 16, 0, 12, 4);

    while (b < count) {
        const uint8_t *cur = blocks + b * 16u;
        size_t dc, dq0, dq1;
        unsigned colour_bits, split_bits;
        /* worst case per block: two flag words, 8 + 8 literal bytes, a u16 */
        if (w.cap - w.pos < 32)
            return DXVK_ERR_BUFFER_TOO_SMALL;

        if (alpha_run > 0) {
            alpha_run--; /* alpha half = the previous block's (equal by construction) */
        } else {
            size_t n = repeats(blocks, 16, b, count, 0, 16);
            if (n > 0) {
                /* block run: n whole blocks equal to their predecessor; no colour flags */
                if (w.cap - w.pos < 8 + extension_bytes(n))
                    return DXVK_ERR_BUFFER_TOO_SMALL;
                put_flag(&w, 0);
                if (n <= 255) {
                    put_byte(&w, (uint32_t)(n - 1u));
                } else {
                    put_byte(&w, 255);
                    put_extension(&w, n - 256u);
                }
                for (size_t k = 0; k < n; k++, b++) {
                    remember(alpha, blocks, 16, b, 0, 8);
                    remember(colour, blocks, 16, b, 8, 8);
                    remember(q0, blocks, 16, b, 8, 4);
                    remember(q1, blocks, 16, b, 12, 4);
                }
                continue;
            }
            if (memcmp(cur, cur - 16, 8) == 0) {
                /* alpha run: this block and the next r copy the previous alpha half */
                size_t r = 0, k = b + 1;
                while (k < count && memcmp(blocks + k * 16u, blocks + (k - 1u) * 16u, 8) == 0) {
                    if (best && repeats(blocks, 16, k, count, 0, 16) >= BEST_RUN_CUT)
                        break;
                    r++;
                    k++;
                }
                if (w.cap - w.pos < 8 + extension_bytes(r))
                    return DXVK_ERR_BUFFER_TOO_SMALL;
                put_flag(&w, 1);
                if (r < 255) {
                    put_byte(&w, (uint32_t)r);
                } else {
                    put_byte(&w, 255);
                    put_extension(&w, r - 255u);
                }
                alpha_run = r;
            } else {
                size_t d = find(alpha, blocks, 16, b, 0, 8);
                if (d >= 2 && d <= MAX_ALPHA_DISTANCE) {
                    put_flag(&w, 2);
                    put_u16(&w, (uint32_t)(d - 2u));
                } else {
                    put_flag(&w, 3);
                    put_bytes(&w, cur, 8);
                }
            }
        }

        /* colour half: whole half by distance, or two quarters */
        colour_bits = unit_cost(colour, blocks, 16, b, 8, 8, &dc);
        if (colour_bits == 2) {
            put_flag(&w, 1);
        } else {
            split_bits = 2u + unit_cost(q0, blocks, 16, b, 8, 4, &dq0) +
                         unit_cost(q1, blocks, 16, b, 12, 4, &dq1);
            if (dc && colour_bits <= split_bits) {
                put_distance(&w, dc);
            } else {
                put_flag(&w, 0);
                put_unit(&w, cur + 8, 4, dq0);
                put_unit(&w, cur + 12, 4, dq1);
            }
        }
        remember(alpha, blocks, 16, b, 0, 8);
        remember(colour, blocks, 16, b, 8, 8);
        remember(q0, blocks, 16, b, 8, 4);
        remember(q1, blocks, 16, b, 12, 4);
        b++;
    }
    *size = w.pos;
    return DXVK_OK;
}
