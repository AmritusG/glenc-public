/*
 * DXVKit: the DXV3 High Quality layer (YCG6, YG10): plane sections, opcode streams (stored, fill,
 * FSE / tANS) and block reconstruction from opcodes.
 *
 * Written from docs/spec/DXV_FORMAT.md section 7 and the public FSE descriptions (Yann Collet's FSE
 * documentation, RFC 8878 section 4.1) for the table-driven decoding idea.
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#include "dxvk_priv.h"

#define TABLE_LOG 10u
#define TABLE_SIZE (1u << TABLE_LOG)
#define SPREAD_STEP 641u
#define OPCODE_LIMIT 18u

/* ---------------------------------------------------------------------------------------------- */
/* Opcode sources                                                                                 */
/* ---------------------------------------------------------------------------------------------- */

typedef struct fse_state_entry {
    uint16_t baseline;
    uint8_t symbol;
    uint8_t bits;
} fse_state_entry;

enum { OPS_STORED, OPS_FILL, OPS_FSE };

typedef struct opcode_source {
    int mode;
    uint32_t count;           /* opcodes in the stream */
    uint32_t taken;           /* opcodes handed out so far */
    const uint8_t *stored;    /* OPS_STORED: the opcodes */
    uint8_t fill;             /* OPS_FILL: the opcode */
    /* OPS_FSE */
    const uint8_t *area;
    size_t area_bytes;
    uint64_t bit_pos;         /* bits not yet consumed: the next bit read is bit_pos - 1 */
    uint32_t state;
    fse_state_entry table[TABLE_SIZE];
} opcode_source;

/* Reads n (0..16) bits ending just below bit_pos, most significant first. */
DXVK_INLINE int fse_bits(opcode_source *s, unsigned n, uint32_t *value)
{
    size_t byte;
    unsigned shift;
    uint32_t v;
    if (s->bit_pos < n)
        return 0;
    s->bit_pos -= n;
    byte = (size_t)(s->bit_pos >> 3);
    shift = (unsigned)(s->bit_pos & 7u);
    if (DXVK_LIKELY(byte + 4u <= s->area_bytes)) {
        v = dxvk_le32(s->area + byte);
    } else {
        v = 0;
        for (size_t i = 0; i < 4u && byte + i < s->area_bytes; i++)
            v |= (uint32_t)s->area[byte + i] << (8u * i);
    }
    *value = (v >> shift) & ((1u << n) - 1u);
    return 1;
}

/* Frequency table (spec 7.3.1) + decoding table (7.3.2) + bitstream setup (7.3.3). */
static dxvk_status fse_setup(opcode_source *s, const uint8_t *p, const uint8_t *end,
                             const uint8_t **stream_end)
{
    uint16_t counts[256];
    uint16_t next[256];
    uint8_t symbol_at[TABLE_SIZE];
    uint64_t acc;
    unsigned have, width = TABLE_LOG;
    unsigned symbols = 0, remaining = TABLE_SIZE;
    const uint8_t *q = p;
    uint64_t length_bits, area_bytes;

    if ((size_t)(end - q) < 4)
        return DXVK_ERR_FSE_TABLE;
    acc = dxvk_le32(q) >> 2;
    have = 30;
    q += 4;
    while (remaining > 0) {
        unsigned c;
        if (symbols == 256)
            return DXVK_ERR_FSE_TABLE;
        if (have < width) {
            if ((size_t)(end - q) < 2)
                return DXVK_ERR_FSE_TABLE;
            acc |= (uint64_t)dxvk_le16(q) << have;
            have += 16;
            q += 2;
        }
        c = (unsigned)(acc & ((1u << width) - 1u));
        acc >>= width;
        have -= width;
        if (c > remaining)
            return DXVK_ERR_FSE_TABLE;
        counts[symbols++] = (uint16_t)c;
        remaining -= c;
        if (remaining < (1u << (width - 1u)))
            width--;
    }

    /* spread */
    {
        unsigned pos = 0;
        for (unsigned sym = 0; sym < symbols; sym++) {
            for (unsigned k = 0; k < counts[sym]; k++) {
                symbol_at[pos] = (uint8_t)sym;
                pos = (pos + SPREAD_STEP) & (TABLE_SIZE - 1u);
            }
            next[sym] = counts[sym];
        }
    }
    for (unsigned state = 0; state < TABLE_SIZE; state++) {
        unsigned sym = symbol_at[state];
        unsigned x = next[sym]++;
        unsigned log2x = 0, bits;
        while ((x >> (log2x + 1u)) != 0)
            log2x++;
        bits = TABLE_LOG - log2x;
        s->table[state].symbol = (uint8_t)sym;
        s->table[state].bits = (uint8_t)bits;
        s->table[state].baseline = (uint16_t)((x << bits) - TABLE_SIZE);
    }

    /* bitstream area: starts at the u32 bit length, ceil(L / 8) bytes */
    if ((size_t)(end - q) < 4)
        return DXVK_ERR_FSE_STREAM;
    length_bits = dxvk_le32(q);
    area_bytes = (length_bits + 7u) >> 3;
    if (area_bytes <= 4u || area_bytes > (uint64_t)(end - q))
        return DXVK_ERR_FSE_STREAM;
    s->area = q;
    s->area_bytes = (size_t)area_bytes;
    s->bit_pos = length_bits;
    if (!fse_bits(s, TABLE_LOG, &s->state))
        return DXVK_ERR_FSE_STREAM;
    *stream_end = q + area_bytes;
    return DXVK_OK;
}

/* Sets up the opcode stream starting at p (spec 7.3). */
static dxvk_status opcodes_setup(opcode_source *s, uint32_t count, const uint8_t *p,
                                 const uint8_t *end, const uint8_t **stream_end)
{
    s->count = count;
    s->taken = 0;
    if (p >= end)
        return DXVK_ERR_PAYLOAD_END;
    switch (p[0] & 3u) {
    case 0:
        if ((size_t)(end - p) - 1u < count)
            return DXVK_ERR_PAYLOAD_END;
        s->mode = OPS_STORED;
        s->stored = p + 1;
        *stream_end = p + 1 + count;
        return DXVK_OK;
    case 1:
        if ((size_t)(end - p) < 2u)
            return DXVK_ERR_PAYLOAD_END;
        s->mode = OPS_FILL;
        s->fill = p[1];
        *stream_end = p + 2;
        return DXVK_OK;
    default:
        s->mode = OPS_FSE;
        return fse_setup(s, p, end, stream_end);
    }
}

DXVK_INLINE dxvk_status next_opcode(opcode_source *s, unsigned *op)
{
    if (s->taken >= s->count)
        return DXVK_ERR_HQ_OPCODES_USED_UP;
    s->taken++;
    if (s->mode == OPS_STORED) {
        *op = s->stored[s->taken - 1u];
    } else if (s->mode == OPS_FILL) {
        *op = s->fill;
    } else {
        const fse_state_entry *e = &s->table[s->state];
        uint32_t bits;
        *op = e->symbol;
        if (!fse_bits(s, e->bits, &bits))
            return DXVK_ERR_FSE_STREAM;
        s->state = e->baseline + bits;
    }
    return DXVK_OK;
}

/* ---------------------------------------------------------------------------------------------- */
/* Sections                                                                                       */
/* ---------------------------------------------------------------------------------------------- */

#define SLOT_FULL_E 0x10000u
#define SLOT_FULL_I 0x1000000u

typedef struct channel {
    opcode_source ops;
    uint8_t *base;            /* this channel's bytes of block 0 */
    size_t repeat;
    uint32_t used;            /* opcodes needed by the texture */
    uint32_t dict_e[256];     /* value | SLOT_FULL_E when occupied */
    uint32_t dict_i[256];     /* value | SLOT_FULL_I when occupied */
    uint32_t histogram[OPCODE_LIMIT];
} channel;

typedef struct section {
    int channels;             /* 1 or 2 */
    size_t blocks;            /* blocks per channel */
    size_t stride;            /* bytes per block position: 8 or 16 */
    dxvk_cursor literals;
    const uint8_t *end;       /* end of the section (after its last opcode stream) */
    size_t dangling_literals; /* literal bytes the unused opcodes would have read */
    channel ch[2];
    dxvk_status status;
} section;

DXVK_INLINE unsigned slot_of(uint32_t v) { return (uint32_t)(v * 2654435761u) >> 24; }

DXVK_INLINE void insert_e(channel *c, const uint8_t *blk)
{
    uint32_t e = dxvk_le16(blk);
    c->dict_e[slot_of(e)] = e | SLOT_FULL_E;
}

DXVK_INLINE void insert_i(channel *c, const uint8_t *blk)
{
    uint32_t i = dxvk_le24(blk + 2);
    c->dict_i[slot_of(i)] = i | SLOT_FULL_I;
}

DXVK_INLINE void put_e(uint8_t *dst, uint32_t e)
{
    dst[0] = (uint8_t)e;
    dst[1] = (uint8_t)(e >> 8);
}

DXVK_INLINE void put3(uint8_t *dst, uint32_t g)
{
    dst[0] = (uint8_t)g;
    dst[1] = (uint8_t)(g >> 8);
    dst[2] = (uint8_t)(g >> 16);
}

/* Literal bytes each opcode reads before any count extension (spec 7.4.3). */
static const uint8_t literal_bytes[OPCODE_LIMIT] = {1, 0, 2, 8, 6, 6, 4, 4, 7, 5, 5, 3, 3, 6, 4, 4, 2, 2};

#define LOOKUP_E(var, slot)                                                                        \
    do {                                                                                           \
        uint32_t v_ = c->dict_e[(slot)];                                                           \
        if (!(v_ & SLOT_FULL_E))                                                                   \
            return DXVK_ERR_HQ_EMPTY_SLOT;                                                         \
        (var) = v_ & 0xFFFFu;                                                                      \
    } while (0)

#define LOOKUP_I(var, slot)                                                                        \
    do {                                                                                           \
        uint32_t v_ = c->dict_i[(slot)];                                                           \
        if (!(v_ & SLOT_FULL_I))                                                                   \
            return DXVK_ERR_HQ_EMPTY_SLOT;                                                         \
        (var) = v_ & 0xFFFFFFu;                                                                    \
    } while (0)

#define BACK_REF(ptr, u16)                                                                         \
    do {                                                                                           \
        size_t d_ = (size_t)(u16) + 1u;                                                            \
        if (d_ > index)                                                                            \
            return DXVK_ERR_BAD_DISTANCE;                                                          \
        (ptr) = dst - d_ * stride;                                                                 \
    } while (0)

/* Reconstructs block `index` (>= 1) of one channel (spec 7.4.3). */
DXVK_INLINE dxvk_status reconstruct(channel *c, dxvk_cursor *lit, size_t index, size_t stride)
{
    uint8_t *dst = c->base + index * stride;
    const uint8_t *prev = dst - stride;
    const uint8_t *l, *r;
    unsigned op;
    uint32_t e, g1, g2;
    dxvk_status st;

    if (c->repeat > 0) {
        c->repeat--;
        memcpy(dst, prev, 8);
        return DXVK_OK;
    }
    if ((st = next_opcode(&c->ops, &op)) != DXVK_OK)
        return st;
    if (op >= OPCODE_LIMIT)
        return DXVK_ERR_HQ_BAD_OPCODE;
    if (dxvk_left(lit) < literal_bytes[op])
        return DXVK_ERR_HQ_LITERALS;
    c->histogram[op]++;
    l = lit->pos;
    lit->pos += literal_bytes[op];

    switch (op) {
    case 0: {
        size_t count = l[0];
        if (count == 255u) {
            uint32_t v;
            do {
                if (dxvk_left(lit) < 2)
                    return DXVK_ERR_HQ_LITERALS;
                v = dxvk_le16(lit->pos);
                lit->pos += 2;
                count += v;
            } while (v == 0xFFFFu);
        }
        memcpy(dst, prev, 8);
        c->repeat = count + 3u;
        return DXVK_OK;
    }
    case 1:
        memcpy(dst, prev, 8);
        return DXVK_OK;
    case 2:
        BACK_REF(r, dxvk_le16(l));
        memcpy(dst, r, 8);
        insert_e(c, dst);
        insert_i(c, dst);
        return DXVK_OK;
    case 3:
        memcpy(dst, l, 8);
        insert_e(c, dst);
        insert_i(c, dst);
        return DXVK_OK;
    case 4:
        LOOKUP_I(g1, l[0]);
        memcpy(dst, l + 1, 2);
        put3(dst + 2, g1);
        memcpy(dst + 5, l + 3, 3);
        insert_e(c, dst);
        return DXVK_OK;
    case 5:
        LOOKUP_I(g2, l[0]);
        memcpy(dst, l + 1, 5);
        put3(dst + 5, g2);
        insert_e(c, dst);
        insert_i(c, dst);
        return DXVK_OK;
    case 6:
        LOOKUP_I(g1, l[0]);
        LOOKUP_I(g2, l[1]);
        memcpy(dst, l + 2, 2);
        put3(dst + 2, g1);
        put3(dst + 5, g2);
        insert_e(c, dst);
        return DXVK_OK;
    case 7:
        BACK_REF(r, dxvk_le16(l));
        memcpy(dst, l + 2, 2);
        memcpy(dst + 2, r + 2, 6);
        insert_e(c, dst);
        insert_i(c, dst);
        return DXVK_OK;
    case 8:
        LOOKUP_E(e, l[0]);
        put_e(dst, e);
        memcpy(dst + 2, l + 1, 6);
        insert_i(c, dst);
        return DXVK_OK;
    case 9:
        LOOKUP_E(e, l[0]);
        LOOKUP_I(g1, l[1]);
        put_e(dst, e);
        put3(dst + 2, g1);
        memcpy(dst + 5, l + 2, 3);
        insert_i(c, dst);
        return DXVK_OK;
    case 10:
        LOOKUP_E(e, l[0]);
        LOOKUP_I(g2, l[1]);
        put_e(dst, e);
        memcpy(dst + 2, l + 2, 3);
        put3(dst + 5, g2);
        insert_i(c, dst);
        return DXVK_OK;
    case 11:
        LOOKUP_E(e, l[0]);
        LOOKUP_I(g1, l[1]);
        LOOKUP_I(g2, l[2]);
        put_e(dst, e);
        put3(dst + 2, g1);
        put3(dst + 5, g2);
        return DXVK_OK;
    case 12:
        LOOKUP_E(e, l[0]);
        BACK_REF(r, dxvk_le16(l + 1));
        put_e(dst, e);
        memcpy(dst + 2, r + 2, 6);
        insert_i(c, dst);
        return DXVK_OK;
    case 13:
        memcpy(dst, prev, 2);
        memcpy(dst + 2, l, 6);
        insert_i(c, dst);
        return DXVK_OK;
    case 14:
        LOOKUP_I(g1, l[0]);
        memcpy(dst, prev, 2);
        put3(dst + 2, g1);
        memcpy(dst + 5, l + 1, 3);
        insert_i(c, dst);
        return DXVK_OK;
    case 15:
        LOOKUP_I(g2, l[0]);
        memcpy(dst, prev, 2);
        memcpy(dst + 2, l + 1, 3);
        put3(dst + 5, g2);
        insert_i(c, dst);
        return DXVK_OK;
    case 16:
        LOOKUP_I(g1, l[0]);
        LOOKUP_I(g2, l[1]);
        memcpy(dst, prev, 2);
        put3(dst + 2, g1);
        put3(dst + 5, g2);
        return DXVK_OK;
    default: /* 17 */
        BACK_REF(r, dxvk_le16(l));
        memcpy(dst, prev, 2);
        memcpy(dst + 2, r + 2, 6);
        insert_i(c, dst);
        return DXVK_OK;
    }
}

/* Reads a section's header and locates its opcode streams (spec 7.2). Does not touch the planes. */
static dxvk_status section_locate(section *s, const uint8_t *start, const uint8_t *payload_end)
{
    size_t header = s->channels == 1 ? 8u : 12u;
    size_t avail = (size_t)(payload_end - start);
    uint32_t op_offset;
    const uint8_t *p;
    dxvk_status st;

    if (avail < header)
        return DXVK_ERR_PAYLOAD_END;
    op_offset = dxvk_le32(start);
    if (op_offset < header || op_offset > avail)
        return DXVK_ERR_HQ_SECTION;
    s->literals.pos = start + header;
    s->literals.end = start + op_offset;
    p = start + op_offset;
    for (int i = 0; i < s->channels; i++) {
        uint32_t count = dxvk_le32(start + 4 + 4 * i);
        if (count > s->blocks)
            return DXVK_ERR_HQ_OPCODE_COUNT;
        st = opcodes_setup(&s->ch[i].ops, count, p, payload_end, &p);
        if (st != DXVK_OK)
            return st;
    }
    s->end = p;
    return DXVK_OK;
}

static dxvk_status section_decode(section *s)
{
    dxvk_cursor *lit = &s->literals;
    size_t first = 8u * (size_t)s->channels;

    for (int i = 0; i < s->channels; i++) {
        channel *c = &s->ch[i];
        memset(c->dict_e, 0, sizeof c->dict_e);
        memset(c->dict_i, 0, sizeof c->dict_i);
        memset(c->histogram, 0, sizeof c->histogram);
        c->repeat = 0;
    }
    if (dxvk_left(lit) < first)
        return DXVK_ERR_HQ_LITERALS;
    for (int i = 0; i < s->channels; i++) {
        memcpy(s->ch[i].base, lit->pos + 8 * i, 8);
        insert_e(&s->ch[i], s->ch[i].base);
        insert_i(&s->ch[i], s->ch[i].base);
    }
    lit->pos += first;

    if (s->channels == 1) {
        channel *c = &s->ch[0];
        for (size_t b = 1; b < s->blocks; b++) {
            dxvk_status st = reconstruct(c, lit, b, s->stride);
            if (DXVK_UNLIKELY(st != DXVK_OK))
                return st;
        }
    } else {
        for (size_t b = 1; b < s->blocks; b++) {
            dxvk_status st = reconstruct(&s->ch[0], lit, b, s->stride);
            if (DXVK_UNLIKELY(st != DXVK_OK))
                return st;
            st = reconstruct(&s->ch[1], lit, b, s->stride);
            if (DXVK_UNLIKELY(st != DXVK_OK))
                return st;
        }
    }

    /* Decode (and discard) opcodes the texture did not need, so a malformed tail is still caught. */
    s->dangling_literals = 0;
    for (int i = 0; i < s->channels; i++) {
        opcode_source *o = &s->ch[i].ops;
        s->ch[i].used = o->taken;
        while (o->taken < o->count) {
            unsigned op;
            dxvk_status st = next_opcode(o, &op);
            if (st != DXVK_OK)
                return st;
            if (op < OPCODE_LIMIT)
                s->dangling_literals += literal_bytes[op];
        }
    }
    return DXVK_OK;
}

static void section_job(void *arg, int index)
{
    section *sections = (section *)arg;
    sections[index].status = section_decode(&sections[index]);
}

dxvk_status dxvk_decode_hq(const uint8_t *payload, size_t size, const dxvk_frame_layout *layout,
                           uint8_t *plane0, uint8_t *plane1, const dxvk_jobs *jobs,
                           dxvk_consumption *consumption)
{
    section sec[2];
    const uint8_t *end = payload + size;
    dxvk_status st;
    int alpha = layout->variant == DXVK_VARIANT_YG10;

    /* section 1: Y (one channel) or Y + A (two channels) */
    sec[0].channels = alpha ? 2 : 1;
    sec[0].blocks = (size_t)layout->blocks_x[0] * layout->blocks_y[0];
    sec[0].stride = alpha ? 16u : 8u;
    sec[0].ch[0].base = plane0;
    sec[0].ch[1].base = plane0 + 8;
    /* section 2: Co + Cg */
    sec[1].channels = 2;
    sec[1].blocks = (size_t)layout->blocks_x[1] * layout->blocks_y[1];
    sec[1].stride = 16u;
    sec[1].ch[0].base = plane1;
    sec[1].ch[1].base = plane1 + 8;

    if ((st = section_locate(&sec[0], payload, end)) != DXVK_OK)
        return st;
    if ((st = section_locate(&sec[1], sec[0].end, end)) != DXVK_OK)
        return st;

    if (jobs && jobs->run) {
        jobs->run(jobs->user, section_job, sec, 2);
    } else {
        section_job(sec, 0);
        if (sec[0].status == DXVK_OK)
            section_job(sec, 1);
    }
    if (sec[0].status != DXVK_OK)
        return sec[0].status;
    if (sec[1].status != DXVK_OK)
        return sec[1].status;

    if (consumption) {
        consumption->payload_unused = (size_t)(end - sec[1].end);
        consumption->fse_bits_left_min = UINT32_MAX;
        for (int s = 0; s < 2; s++) {
            consumption->literals_unused += dxvk_left(&sec[s].literals);
            consumption->literals_dangling += sec[s].dangling_literals;
            for (int i = 0; i < sec[s].channels; i++) {
                const channel *c = &sec[s].ch[i];
                consumption->opcodes_unused += c->ops.count - c->used;
                for (unsigned k = 0; k < OPCODE_LIMIT; k++)
                    consumption->opcode_histogram[k] += c->histogram[k];
                if (c->ops.mode == OPS_FSE) {
                    uint32_t left = (uint32_t)c->ops.bit_pos;
                    consumption->fse_streams++;
                    if (left < consumption->fse_bits_left_min)
                        consumption->fse_bits_left_min = left;
                    if (left > consumption->fse_bits_left_max)
                        consumption->fse_bits_left_max = left;
                }
            }
        }
        if (consumption->fse_streams == 0)
            consumption->fse_bits_left_min = 0;
    }
    return DXVK_OK;
}
