/*
 * DXVKit encoder: the DXV3 High Quality layer (YCG6, YG10): opcode choice over BC4 blocks with the
 * decoder's two dictionaries, plane sections, and the opcode-stream codings (stored, fill, FSE / tANS).
 *
 * Written from docs/spec/DXV_FORMAT.md section 7, docs/spec/ENCODING_NOTES.md section 7 and the public
 * FSE descriptions (Yann Collet's FSE documentation, RFC 8878 section 4.1). The tANS encoder is derived
 * from the decoding table of spec 7.3.2.
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#include "enc_priv.h"

#define TABLE_LOG 10u
#define TABLE_SIZE (1u << TABLE_LOG)
#define SPREAD_STEP 641u
#define MAX_BACK 65536u          /* u16 + 1 */
#define SLOT_FULL_E 0x10000u
#define SLOT_FULL_I 0x1000000u

/* Literal bytes each opcode reads before any count extension (spec 7.4.3). */
static const uint8_t literal_bytes[HQ_OPCODES] = {1, 0, 2, 8, 6, 6, 4, 4, 7, 5, 5, 3, 3, 6, 4, 4, 2, 2};
/* Dictionary inserts per opcode: 1 = E, 2 = I (spec 7.4.3). */
static const uint8_t inserts[HQ_OPCODES] = {0, 0, 3, 3, 1, 3, 1, 3, 2, 2, 2, 0, 2, 2, 2, 2, 0, 2};
/* Opcode for (endpoint source, index source): endpoints = previous block's / dictionary / literal;
 * indices = back-reference / two dictionary groups / dictionary + literal / literal + dictionary /
 * literal. */
static const uint8_t combo[3][5] = {{17, 16, 14, 15, 13}, {12, 11, 9, 10, 8}, {7, 6, 4, 5, 3}};
/* 16 x log2(1 + i / 16), rounded. */
static const uint8_t log2_frac[16] = {0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};

/* Opcode cost prior for the first pass, in 1/16 bit: a flat 4 bits, a little less for the opcodes
 * that typically dominate (repeat-previous, run, previous-endpoint forms). */
static const uint16_t cost_prior[HQ_OPCODES] = {72, 40, 72, 64, 72, 72, 72, 72, 72,
                                                72, 72, 72, 72, 56, 64, 64, 64, 64};

DXVK_INLINE unsigned floor_log2(uint32_t x)
{
    unsigned l = 0;
    while (x >> (l + 1u))
        l++;
    return l;
}

/* 16 x log2(x), x >= 1, within about 1/16. */
static uint32_t log2_16(uint32_t x)
{
    unsigned l = floor_log2(x);
    uint32_t m = l >= 4u ? (x >> (l - 4u)) & 15u : (x << (4u - l)) & 15u;
    return 16u * l + log2_frac[m];
}

DXVK_INLINE unsigned slot_of(uint32_t v) { return (uint32_t)(v * 2654435761u) >> 24; }

/* ---------------------------------------------------------------------------------------------- */
/* Opcode choice (one pass over a section)                                                        */
/* ---------------------------------------------------------------------------------------------- */

typedef struct channel_state {
    uint32_t dict_e[256];
    uint32_t dict_i[256];
    size_t repeat;
    uint32_t hist[HQ_OPCODES];
    uint32_t cost[HQ_OPCODES];
} channel_state;

DXVK_INLINE uint64_t block_key(const uint8_t *blk) { return dxvk_le64(blk); }
DXVK_INLINE uint64_t index_key(const uint8_t *blk) { return dxvk_le64(blk) >> 16; }

DXVK_INLINE void insert_e(channel_state *c, const uint8_t *blk)
{
    uint32_t e = dxvk_le16(blk);
    c->dict_e[slot_of(e)] = e | SLOT_FULL_E;
}

DXVK_INLINE void insert_i(channel_state *c, const uint8_t *blk)
{
    uint32_t i = dxvk_le24(blk + 2);
    c->dict_i[slot_of(i)] = i | SLOT_FULL_I;
}

/* Nearest earlier block of this channel with the same key (bytes `offset`.. of the block), as a
 * distance 1..MAX_BACK, or 0. */
DXVK_INLINE size_t find_back(const match_table *t, uint64_t key, const uint8_t *base, size_t stride,
                             size_t b, size_t offset)
{
    uint32_t j = t->slot[match_hash(t, key)];
    size_t d;
    if (j == 0 || j - 1u >= b)
        return 0;
    d = b - (j - 1u);
    if (d > MAX_BACK)
        return 0;
    if (memcmp(base + (size_t)(j - 1u) * stride + offset, base + b * stride + offset,
               8u - offset) != 0)
        return 0;
    return d;
}

DXVK_INLINE void remember(hq_channel *h, const uint8_t *blk, size_t b)
{
    h->whole.slot[match_hash(&h->whole, block_key(blk))] = (uint32_t)(b + 1u);
    h->index6.slot[match_hash(&h->index6, index_key(blk))] = (uint32_t)(b + 1u);
}

DXVK_INLINE uint8_t *put3(uint8_t *p, const uint8_t *src)
{
    p[0] = src[0];
    p[1] = src[1];
    p[2] = src[2];
    return p + 3;
}

/* Literal bytes of opcode 0's count (count = blocks covered - 4). */
static uint8_t *put_run_count(uint8_t *p, size_t count)
{
    if (count < 255u) {
        *p++ = (uint8_t)count;
        return p;
    }
    *p++ = 255;
    count -= 255u;
    while (count >= 0xFFFFu) {
        dxvk_put16(p, 0xFFFFu);
        p += 2;
        count -= 0xFFFFu;
    }
    dxvk_put16(p, (uint32_t)count);
    return p + 2;
}

/* Chooses and emits the opcode for block b (>= 1) of one channel; returns the new literal end. */
static uint8_t *code_block(hq_section *s, int ch, channel_state *c, size_t b, uint8_t *lit)
{
    hq_channel *h = &s->ch[ch];
    const uint8_t *base = s->src + 8u * (size_t)ch;
    const uint8_t *cur = base + b * s->stride, *prev = cur - s->stride;
    uint32_t e, i1, i2, best_cost = UINT32_MAX;
    unsigned es, i1s, i2s, op = 3;
    int e_prev, e_hit, i1_hit, i2_hit;
    size_t dw, di;

    if (c->repeat > 0) {
        c->repeat--;
        remember(h, cur, b);
        return lit;
    }

    if (memcmp(cur, prev, 8) == 0) {
        /* identical to the previous block: a run (opcode 0, >= 4 blocks) or opcode 1 */
        size_t n = 1;
        while (b + n < s->blocks && memcmp(cur + n * s->stride, prev, 8) == 0)
            n++;
        if (n >= 4u && 128u + c->cost[0] <= (uint32_t)n * c->cost[1]) {
            lit = put_run_count(lit, n - 4u);
            h->ops[h->op_count++] = 0;
            c->hist[0]++;
            c->repeat = n - 1u;
        } else {
            h->ops[h->op_count++] = 1;
            c->hist[1]++;
        }
        remember(h, cur, b);
        return lit;
    }

    e = dxvk_le16(cur);
    i1 = dxvk_le24(cur + 2);
    i2 = dxvk_le24(cur + 5);
    es = slot_of(e);
    i1s = slot_of(i1);
    i2s = slot_of(i2);
    e_prev = e == dxvk_le16(prev);
    e_hit = c->dict_e[es] == (e | SLOT_FULL_E);
    i1_hit = c->dict_i[i1s] == (i1 | SLOT_FULL_I);
    i2_hit = c->dict_i[i2s] == (i2 | SLOT_FULL_I);
    dw = find_back(&h->whole, block_key(cur), base, s->stride, b, 0);
    di = find_back(&h->index6, index_key(cur), base, s->stride, b, 2);

    if (dw) {
        best_cost = 2u * 128u + c->cost[2];
        op = 2;
    }
    for (int esrc = 0; esrc < 3; esrc++) {
        if ((esrc == 0 && !e_prev) || (esrc == 1 && !e_hit))
            continue;
        for (int isrc = 0; isrc < 5; isrc++) {
            unsigned o = combo[esrc][isrc];
            uint32_t cost;
            if ((isrc == 0 && !di) || (isrc == 1 && !(i1_hit && i2_hit)) || (isrc == 2 && !i1_hit) ||
                (isrc == 3 && !i2_hit))
                continue;
            cost = 128u * literal_bytes[o] + c->cost[o];
            if (cost < best_cost) {
                best_cost = cost;
                op = o;
            }
        }
    }

    /* literals in the decoder's read order (spec 7.4.3) */
    switch (op) {
    case 2: dxvk_put16(lit, (uint32_t)(dw - 1u)), lit += 2; break;
    case 3: memcpy(lit, cur, 8), lit += 8; break;
    case 4: *lit++ = (uint8_t)i1s, memcpy(lit, cur, 2), lit = put3(lit + 2, cur + 5); break;
    case 5: *lit++ = (uint8_t)i2s, memcpy(lit, cur, 5), lit += 5; break;
    case 6: *lit++ = (uint8_t)i1s, *lit++ = (uint8_t)i2s, memcpy(lit, cur, 2), lit += 2; break;
    case 7: dxvk_put16(lit, (uint32_t)(di - 1u)), memcpy(lit + 2, cur, 2), lit += 4; break;
    case 8: *lit++ = (uint8_t)es, memcpy(lit, cur + 2, 6), lit += 6; break;
    case 9: *lit++ = (uint8_t)es, *lit++ = (uint8_t)i1s, lit = put3(lit, cur + 5); break;
    case 10: *lit++ = (uint8_t)es, *lit++ = (uint8_t)i2s, lit = put3(lit, cur + 2); break;
    case 11: *lit++ = (uint8_t)es, *lit++ = (uint8_t)i1s, *lit++ = (uint8_t)i2s; break;
    case 12: *lit++ = (uint8_t)es, dxvk_put16(lit, (uint32_t)(di - 1u)), lit += 2; break;
    case 13: memcpy(lit, cur + 2, 6), lit += 6; break;
    case 14: *lit++ = (uint8_t)i1s, lit = put3(lit, cur + 5); break;
    case 15: *lit++ = (uint8_t)i2s, lit = put3(lit, cur + 2); break;
    case 16: *lit++ = (uint8_t)i1s, *lit++ = (uint8_t)i2s; break;
    default: dxvk_put16(lit, (uint32_t)(di - 1u)), lit += 2; break; /* 17 */
    }
    h->ops[h->op_count++] = (uint8_t)op;
    c->hist[op]++;
    if (inserts[op] & 1u)
        insert_e(c, cur);
    if (inserts[op] & 2u)
        insert_i(c, cur);
    remember(h, cur, b);
    return lit;
}

/* One pass: chooses every opcode of the section with the given per-channel costs. */
static size_t section_pass(hq_section *s, channel_state *cs)
{
    uint8_t *lit = s->literals;
    for (int ch = 0; ch < s->channels; ch++) {
        hq_channel *h = &s->ch[ch];
        channel_state *c = &cs[ch];
        memset(c->dict_e, 0, sizeof c->dict_e);
        memset(c->dict_i, 0, sizeof c->dict_i);
        memset(c->hist, 0, sizeof c->hist);
        c->repeat = 0;
        h->op_count = 0;
        memset(h->whole.slot, 0, ((size_t)1 << h->whole.bits) * sizeof *h->whole.slot);
        memset(h->index6.slot, 0, ((size_t)1 << h->index6.bits) * sizeof *h->index6.slot);
    }
    /* block 0 of each channel: literal, insert E and I */
    for (int ch = 0; ch < s->channels; ch++) {
        const uint8_t *blk = s->src + 8u * (size_t)ch;
        memcpy(lit, blk, 8);
        lit += 8;
        insert_e(&cs[ch], blk);
        insert_i(&cs[ch], blk);
        remember(&s->ch[ch], blk, 0);
    }
    for (size_t b = 1; b < s->blocks; b++)
        for (int ch = 0; ch < s->channels; ch++)
            lit = code_block(s, ch, &cs[ch], b, lit);
    return (size_t)(lit - s->literals);
}

/* ---------------------------------------------------------------------------------------------- */
/* Opcode streams                                                                                 */
/* ---------------------------------------------------------------------------------------------- */

typedef struct bit_writer {
    uint8_t *out;
    size_t pos;
    uint64_t acc;
    unsigned have;
} bit_writer;

DXVK_INLINE void put_bits(bit_writer *w, uint32_t v, unsigned n)
{
    w->acc |= (uint64_t)v << w->have;
    w->have += n;
    while (w->have >= 8u) {
        w->out[w->pos++] = (uint8_t)w->acc;
        w->acc >>= 8;
        w->have -= 8u;
    }
}

DXVK_INLINE void flush_bits(bit_writer *w)
{
    if (w->have > 0u)
        w->out[w->pos++] = (uint8_t)w->acc;
    w->acc = 0;
    w->have = 0;
}

/* Counts summing to exactly 1024, every used opcode at least 1 (at least two used opcodes). */
static void normalise(const uint32_t hist[HQ_OPCODES], uint32_t total, unsigned symbols,
                      uint32_t norm[HQ_OPCODES])
{
    uint32_t sum = 0;
    for (unsigned s = 0; s < symbols; s++) {
        norm[s] = 0;
        if (hist[s]) {
            norm[s] = (uint32_t)(((uint64_t)hist[s] * TABLE_SIZE + total / 2u) / total);
            if (norm[s] == 0)
                norm[s] = 1;
            if (norm[s] > TABLE_SIZE - 1u)
                norm[s] = TABLE_SIZE - 1u;
        }
        sum += norm[s];
    }
    /* take from the symbol that loses least (smallest hist / norm), give to the one that gains most */
    while (sum > TABLE_SIZE) {
        unsigned pick = symbols;
        for (unsigned s = 0; s < symbols; s++)
            if (norm[s] > 1u && (pick == symbols || (uint64_t)hist[s] * norm[pick] <
                                                        (uint64_t)hist[pick] * norm[s]))
                pick = s;
        norm[pick]--;
        sum--;
    }
    while (sum < TABLE_SIZE) {
        unsigned pick = symbols;
        for (unsigned s = 0; s < symbols; s++)
            if (hist[s] && (pick == symbols || (uint64_t)hist[s] * norm[pick] >
                                                   (uint64_t)hist[pick] * norm[s]))
                pick = s;
        norm[pick]++;
        sum++;
    }
}

/*
 * FSE-codes `count` opcodes into out (spec 7.3.1 - 7.3.3). Returns the stream length, or 0 when the
 * opcodes use fewer than two values (a single-value table cannot be written: use fill).
 * out must hold 32 + 2 x count bytes.
 */
static size_t fse_write(const uint8_t *ops, uint32_t count, uint8_t *out)
{
    uint32_t hist[HQ_OPCODES], norm[HQ_OPCODES], start[HQ_OPCODES], next[HQ_OPCODES];
    uint16_t state_for[TABLE_SIZE];
    uint8_t symbol_at[TABLE_SIZE];
    unsigned symbols = 0, used = 0, width = TABLE_LOG;
    uint32_t remaining = TABLE_SIZE, v, total_bits = 0, length_bits;
    size_t table_bytes, tbits;
    bit_writer w;

    memset(hist, 0, sizeof hist);
    for (uint32_t i = 0; i < count; i++)
        hist[ops[i]]++;
    for (unsigned s = 0; s < HQ_OPCODES; s++)
        if (hist[s]) {
            symbols = s + 1u;
            used++;
        }
    if (used < 2)
        return 0;
    normalise(hist, count, symbols, norm);

    /* frequency table: selector 2 in bits 0..1, then the counts, LSB first */
    w.out = out;
    w.pos = 0;
    w.acc = 0;
    w.have = 0;
    put_bits(&w, 2, 2);
    tbits = 2;
    for (unsigned s = 0; s < symbols && remaining > 0; s++) {
        put_bits(&w, norm[s], width);
        tbits += width;
        remaining -= norm[s];
        if (remaining < (1u << (width - 1u)))
            width--;
    }
    flush_bits(&w);
    table_bytes = 4u + 2u * (((tbits > 32u ? tbits - 32u : 0u) + 15u) / 16u);
    while (w.pos < table_bytes)
        out[w.pos++] = 0;

    /* the decoder's state table (spread step 641), inverted: state for (symbol, x) */
    {
        unsigned pos = 0, acc = 0;
        for (unsigned s = 0; s < symbols; s++) {
            start[s] = acc;
            acc += norm[s];
            next[s] = norm[s];
            for (uint32_t k = 0; k < norm[s]; k++) {
                symbol_at[pos] = (uint8_t)s;
                pos = (pos + SPREAD_STEP) & (TABLE_SIZE - 1u);
            }
        }
        for (unsigned t = 0; t < TABLE_SIZE; t++) {
            unsigned s = symbol_at[t];
            uint32_t x = next[s]++;
            state_for[start[s] + x - norm[s]] = (uint16_t)t;
        }
    }

    /* bitstream: u32 bit length, then the transitions of the last opcode first, the initial state
     * last (the decoder reads from the top down) */
    w.out = out + table_bytes;
    w.pos = 4;
    v = TABLE_SIZE - 1u;
    for (uint32_t i = count; i-- > 0;) {
        unsigned s = ops[i], k, nb;
        uint32_t c = norm[s], y = v + TABLE_SIZE, x;
        k = TABLE_LOG - floor_log2(c);
        nb = (y >> k) < c ? k - 1u : k;
        x = y >> nb;
        put_bits(&w, y & ((1u << nb) - 1u), nb);
        total_bits += nb;
        v = state_for[start[s] + x - c];
    }
    put_bits(&w, v, TABLE_LOG);
    total_bits += TABLE_LOG;
    flush_bits(&w);
    length_bits = 32u + total_bits;
    dxvk_put32(out + table_bytes, length_bits);
    return table_bytes + (length_bits + 7u) / 8u;
}

/* Writes the cheapest coding of one channel's opcodes at out; returns its length. */
static size_t write_opcodes(const hq_section *s, const hq_channel *h, uint8_t *out)
{
    uint32_t n = h->op_count;
    int single = 1;
    size_t fse = 0;
    for (uint32_t i = 1; i < n; i++)
        if (h->ops[i] != h->ops[0]) {
            single = 0;
            break;
        }
    if (single && n > 1u) {
        out[0] = 0x01;
        out[1] = h->ops[0];
        return 2;
    }
    if (!s->stored_only)
        fse = fse_write(h->ops, n, h->stream);
    if (fse && fse < 1u + n) {
        memcpy(out, h->stream, fse);
        return fse;
    }
    out[0] = 0x00;
    memcpy(out + 1, h->ops, n);
    return 1u + n;
}

/* Per-channel opcode costs (1/16 bit) from a histogram. */
static void costs_from(const uint32_t hist[HQ_OPCODES], uint32_t cost[HQ_OPCODES])
{
    uint32_t total = 0;
    for (unsigned k = 0; k < HQ_OPCODES; k++)
        total += hist[k];
    for (unsigned k = 0; k < HQ_OPCODES; k++)
        cost[k] = log2_16(2u * total + HQ_OPCODES) - log2_16(2u * hist[k] + 1u);
}

size_t dxvk_hq_section_bound(int channels, size_t blocks)
{
    /* header + literals (<= 8 per block and channel) + stored opcode streams */
    return 12u + (size_t)channels * (9u * blocks + 2u);
}

static dxvk_status section_encode(hq_section *s)
{
    channel_state cs[2];
    size_t lit_bytes, header = s->channels == 1 ? 8u : 12u, pos;
    for (int ch = 0; ch < s->channels; ch++)
        for (unsigned k = 0; k < HQ_OPCODES; k++)
            cs[ch].cost[k] = cost_prior[k];
    lit_bytes = section_pass(s, cs);
    if (s->best) {
        for (int ch = 0; ch < s->channels; ch++)
            costs_from(cs[ch].hist, cs[ch].cost);
        lit_bytes = section_pass(s, cs);
    }
    if (header + lit_bytes > s->out_cap)
        return DXVK_ERR_BUFFER_TOO_SMALL;
    dxvk_put32(s->out, (uint32_t)(header + lit_bytes));
    for (int ch = 0; ch < s->channels; ch++)
        dxvk_put32(s->out + 4 + 4 * ch, s->ch[ch].op_count);
    memcpy(s->out + header, s->literals, lit_bytes);
    pos = header + lit_bytes;
    for (int ch = 0; ch < s->channels; ch++)
        pos += write_opcodes(s, &s->ch[ch], s->out + pos);
    s->out_size = pos;
    return DXVK_OK;
}

static void section_job(void *arg, int index)
{
    hq_section *sec = (hq_section *)arg;
    sec[index].status = section_encode(&sec[index]);
}

dxvk_status dxvk_pack_hq(dxvk_encoder *e, const uint8_t *plane0, const uint8_t *plane1,
                         uint8_t *out, size_t cap, size_t *size)
{
    hq_section *sec = e->sec;
    sec[0].src = plane0;
    sec[1].src = plane1;
    if (e->have_jobs) {
        e->jobs.run(e->jobs.user, section_job, sec, 2);
    } else {
        section_job(sec, 0);
        section_job(sec, 1);
    }
    if (sec[0].status != DXVK_OK)
        return sec[0].status;
    if (sec[1].status != DXVK_OK)
        return sec[1].status;
    if (cap < sec[0].out_size + sec[1].out_size)
        return DXVK_ERR_BUFFER_TOO_SMALL;
    memcpy(out, sec[0].out, sec[0].out_size);
    memcpy(out + sec[0].out_size, sec[1].out, sec[1].out_size);
    *size = sec[0].out_size + sec[1].out_size;
    return DXVK_OK;
}
