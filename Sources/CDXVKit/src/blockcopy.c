/*
 * DXVKit: the DXV3 block-copy layers for DXT1 (BC1) and DXT5 (BC3) textures.
 *
 * Written from docs/spec/DXV_FORMAT.md sections 5 and 6.
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#include "dxvk_priv.h"

/* Flag reader: 2-bit flags, 16 per little-endian u32, least significant first, interleaved with the
 * bytes they own. */
typedef struct flag_reader {
    dxvk_cursor in;
    uint32_t word;
    unsigned left;
} flag_reader;

DXVK_INLINE int take_flag(flag_reader *r, unsigned *flag)
{
    if (r->left == 0) {
        if (dxvk_left(&r->in) < 4)
            return 0;
        r->word = dxvk_le32(r->in.pos);
        r->in.pos += 4;
        r->left = 16;
    }
    *flag = r->word & 3u;
    r->word >>= 2;
    r->left--;
    return 1;
}

/* Distance for a non-zero flag (spec 5.2): 1; u8 + 2; u16 + 258. */
DXVK_INLINE int flag_distance(flag_reader *r, unsigned flag, size_t *distance)
{
    if (flag == 1u) {
        *distance = 1;
        return 1;
    }
    if (flag == 2u) {
        if (dxvk_left(&r->in) < 1)
            return 0;
        *distance = (size_t)r->in.pos[0] + 2u;
        r->in.pos += 1;
        return 1;
    }
    if (dxvk_left(&r->in) < 2)
        return 0;
    *distance = (size_t)dxvk_le16(r->in.pos) + 258u;
    r->in.pos += 2;
    return 1;
}

/* One 4-byte unit (a DXT1 half or a DXT5 colour quarter): copy from `stride`-byte blocks back, or 4
 * literal bytes. `dst` is the unit inside block `index`. */
DXVK_INLINE dxvk_status unit4(flag_reader *r, uint8_t *dst, size_t index, size_t stride)
{
    unsigned flag;
    size_t d;
    if (!take_flag(r, &flag))
        return DXVK_ERR_PAYLOAD_END;
    if (flag == 0) {
        if (dxvk_left(&r->in) < 4)
            return DXVK_ERR_PAYLOAD_END;
        memcpy(dst, r->in.pos, 4);
        r->in.pos += 4;
        return DXVK_OK;
    }
    if (!flag_distance(r, flag, &d))
        return DXVK_ERR_PAYLOAD_END;
    if (d > index)
        return DXVK_ERR_BAD_DISTANCE;
    memcpy(dst, dst - d * stride, 4);
    return DXVK_OK;
}

dxvk_status dxvk_decode_dxt1(const uint8_t *payload, size_t size, uint8_t *out, size_t blocks,
                             size_t *used)
{
    flag_reader r;
    dxvk_status st;
    r.in.pos = payload;
    r.in.end = payload + size;
    r.word = 0;
    r.left = 0;

    if (size < 8)
        return DXVK_ERR_PAYLOAD_END;
    memcpy(out, payload, 8);
    r.in.pos += 8;

    for (size_t b = 1; b < blocks; b++) {
        uint8_t *dst = out + b * 8u;
        unsigned flag;
        if (!take_flag(&r, &flag))
            return DXVK_ERR_PAYLOAD_END;
        if (flag != 0) {
            size_t d;
            if (!flag_distance(&r, flag, &d))
                return DXVK_ERR_PAYLOAD_END;
            if (d > b)
                return DXVK_ERR_BAD_DISTANCE;
            memcpy(dst, dst - d * 8u, 8);
            continue;
        }
        if ((st = unit4(&r, dst, b, 8)) != DXVK_OK)
            return st;
        if ((st = unit4(&r, dst + 4, b, 8)) != DXVK_OK)
            return st;
    }
    *used = (size_t)(r.in.pos - payload);
    return DXVK_OK;
}

/* Count extension (spec 6.4): add u16 values while the one just read is 0xFFFF. */
static int extend_count(dxvk_cursor *c, size_t *count)
{
    uint32_t v;
    do {
        if (dxvk_left(c) < 2)
            return 0;
        v = dxvk_le16(c->pos);
        c->pos += 2;
        *count += v;
    } while (v == 0xFFFFu);
    return 1;
}

dxvk_status dxvk_decode_dxt5(const uint8_t *payload, size_t size, uint8_t *out, size_t blocks,
                             size_t *used)
{
    flag_reader r;
    size_t alpha_run = 0;
    size_t b = 1;
    dxvk_status st;
    r.in.pos = payload;
    r.in.end = payload + size;
    r.word = 0;
    r.left = 0;

    if (size < 16)
        return DXVK_ERR_PAYLOAD_END;
    memcpy(out, payload, 16);
    r.in.pos += 16;

    while (b < blocks) {
        uint8_t *dst = out + b * 16u;
        unsigned flag;

        /* alpha half (bytes 0..7) */
        if (alpha_run > 0) {
            alpha_run--;
            memcpy(dst, dst - 16, 8);
        } else {
            if (!take_flag(&r, &flag))
                return DXVK_ERR_PAYLOAD_END;
            switch (flag) {
            case 0: { /* block run: n whole blocks equal to their previous block */
                size_t n;
                if (dxvk_left(&r.in) < 1)
                    return DXVK_ERR_PAYLOAD_END;
                n = (size_t)r.in.pos[0] + 1u;
                r.in.pos += 1;
                if (n == 256u && !extend_count(&r.in, &n))
                    return DXVK_ERR_PAYLOAD_END;
                if (n > blocks - b)
                    n = blocks - b;
                for (size_t k = 0; k < n; k++, b++)
                    memcpy(out + b * 16u, out + (b - 1u) * 16u, 16);
                continue;
            }
            case 1: /* alpha run */
                if (dxvk_left(&r.in) < 1)
                    return DXVK_ERR_PAYLOAD_END;
                alpha_run = r.in.pos[0];
                r.in.pos += 1;
                if (alpha_run == 255u && !extend_count(&r.in, &alpha_run))
                    return DXVK_ERR_PAYLOAD_END;
                memcpy(dst, dst - 16, 8);
                break;
            case 2: { /* alpha half from u16 + 2 blocks back */
                size_t d;
                if (dxvk_left(&r.in) < 2)
                    return DXVK_ERR_PAYLOAD_END;
                d = (size_t)dxvk_le16(r.in.pos) + 2u;
                r.in.pos += 2;
                if (d > b)
                    return DXVK_ERR_BAD_DISTANCE;
                memcpy(dst, dst - d * 16u, 8);
                break;
            }
            default: /* 8 literal bytes */
                if (dxvk_left(&r.in) < 8)
                    return DXVK_ERR_PAYLOAD_END;
                memcpy(dst, r.in.pos, 8);
                r.in.pos += 8;
                break;
            }
        }

        /* colour half (bytes 8..15) */
        if (!take_flag(&r, &flag))
            return DXVK_ERR_PAYLOAD_END;
        if (flag != 0) {
            size_t d;
            if (!flag_distance(&r, flag, &d))
                return DXVK_ERR_PAYLOAD_END;
            if (d > b)
                return DXVK_ERR_BAD_DISTANCE;
            memcpy(dst + 8, dst + 8 - d * 16u, 8);
        } else {
            if ((st = unit4(&r, dst + 8, b, 16)) != DXVK_OK)
                return st;
            if ((st = unit4(&r, dst + 12, b, 16)) != DXVK_OK)
                return st;
        }
        b++;
    }
    *used = (size_t)(r.in.pos - payload);
    return DXVK_OK;
}
