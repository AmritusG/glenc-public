/*
 * DXVKit encoder: BC1 colour (DXT1, DXT5 colour half) and BC4 (Y, A, Co, Cg, DXT5 alpha half) block
 * encoders.
 *
 * Written from the public S3TC / RGTC block definitions and docs/spec/DXV_FORMAT.md section 8 (the
 * palettes our decoder produces; the error of a candidate is measured against exactly those).
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#include "enc_priv.h"
#include "enc_tables.h"

#include <math.h>

DXVK_INLINE int exp5(int v) { return (v << 3) | (v >> 2); }
DXVK_INLINE int exp6(int v) { return (v << 2) | (v >> 4); }

/* ---------------------------------------------------------------------------------------------- */
/* BC1                                                                                            */
/* ---------------------------------------------------------------------------------------------- */

typedef struct bc1_ctx {
    int px[16][3];
    uint32_t best_err;
    uint8_t best[8];
    int best_q[2][3];       /* endpoints of the best candidate, in the order tried */
    int best_three;
    uint8_t best_idx[16];   /* palette index per pixel, in the tried endpoint order */
} bc1_ctx;

DXVK_INLINE uint32_t pack565(const int q[3])
{
    return ((uint32_t)q[0] << 11) | ((uint32_t)q[1] << 5) | (uint32_t)q[2];
}

/*
 * Evaluates endpoints q0, q1 in the mode requested (three = three-colour, DXT1 only), ordered the way
 * the decoder needs (four-colour: c0 > c1; three-colour: c0 <= c1), with the palette the decoder will
 * build. Never uses index 3 of the three-colour palette. Keeps the best candidate.
 * Returns the squared error.
 */
static uint32_t bc1_try(bc1_ctx *c, const int q0[3], const int q1[3], int three)
{
    uint32_t p0 = pack565(q0), p1 = pack565(q1), err = 0, idx = 0;
    int pal[4][3], usable = 4, swapped = 0;
    uint8_t chosen[16];
    const int *a = q0, *b = q1;

    /* BC3 colour halves are ordered like four-colour BC1 too: the BC3 definition always decodes four
     * colours, but a decoder that applies the BC1 order rule (FFmpeg does, QUESTIONS 10) then agrees */
    if (three) {
        if (p0 > p1) {
            a = q1, b = q0, swapped = 1;
        }
        usable = 3;
    } else if (p0 < p1) {
        a = q1, b = q0, swapped = 1;
    } else if (p0 == p1) {
        usable = 1; /* three-colour (BC1 rule): only index 0 is the endpoint colour */
        three = 1;
    }
    for (int k = 0; k < 3; k++) {
        int ea = k == 1 ? exp6(a[k]) : exp5(a[k]);
        int eb = k == 1 ? exp6(b[k]) : exp5(b[k]);
        pal[0][k] = ea;
        pal[1][k] = eb;
        if (three) {
            pal[2][k] = (ea + eb) / 2;
            pal[3][k] = 0;
        } else {
            pal[2][k] = (2 * ea + eb) / 3;
            pal[3][k] = (ea + 2 * eb) / 3;
        }
    }
    for (int i = 0; i < 16; i++) {
        uint32_t be = UINT32_MAX;
        int bi = 0;
        for (int j = 0; j < usable; j++) {
            int dr = c->px[i][0] - pal[j][0], dg = c->px[i][1] - pal[j][1],
                db = c->px[i][2] - pal[j][2];
            uint32_t e = (uint32_t)(dr * dr + dg * dg + db * db);
            if (e < be) {
                be = e;
                bi = j;
            }
        }
        err += be;
        chosen[i] = (uint8_t)bi;
        idx |= (uint32_t)bi << (2 * i);
        if (err >= c->best_err)
            return err;
    }
    c->best_err = err;
    dxvk_put16(c->best, pack565(a));
    dxvk_put16(c->best + 2, pack565(b));
    dxvk_put32(c->best + 4, idx);
    /* remember the candidate in the caller's endpoint order for refits */
    for (int k = 0; k < 3; k++) {
        c->best_q[0][k] = q0[k];
        c->best_q[1][k] = q1[k];
    }
    c->best_three = three && usable == 3;
    for (int i = 0; i < 16; i++) {
        int s = chosen[i];
        if (swapped && s < 2)
            s ^= 1;
        else if (swapped && !three)
            s ^= 1; /* 2 <-> 3 */
        c->best_idx[i] = (uint8_t)s;
    }
    return err;
}

DXVK_INLINE int clamp255i(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

static void quantize(const float c[3], int q[3])
{
    q[0] = quant5[clamp255i((int)(c[0] + 0.5f))];
    q[1] = quant6[clamp255i((int)(c[1] + 0.5f))];
    q[2] = quant5[clamp255i((int)(c[2] + 0.5f))];
}

/* Least-squares endpoints for the current best indices. Returns 0 when the system is singular. */
static int bc1_refit(bc1_ctx *c, int three, int q0[3], int q1[3])
{
    /* weight of endpoint 0 per index, in units of 1/3 (four-colour) or 1/2 (three-colour) */
    static const int w4[4] = {3, 0, 2, 1}, w3[4] = {2, 0, 1, 0};
    const int *w = three ? w3 : w4;
    int unit = three ? 2 : 3;
    long aa = 0, ab = 0, bb = 0, ax[3] = {0, 0, 0}, bx[3] = {0, 0, 0};
    float e0[3], e1[3];
    long det;
    for (int i = 0; i < 16; i++) {
        int s = c->best_idx[i];
        int a = w[s], b = unit - w[s];
        aa += a * a;
        ab += a * b;
        bb += b * b;
        for (int k = 0; k < 3; k++) {
            ax[k] += a * c->px[i][k];
            bx[k] += b * c->px[i][k];
        }
    }
    det = aa * bb - ab * ab;
    if (det == 0)
        return 0;
    for (int k = 0; k < 3; k++) {
        e0[k] = (float)unit * (float)(bb * ax[k] - ab * bx[k]) / (float)det;
        e1[k] = (float)unit * (float)(aa * bx[k] - ab * ax[k]) / (float)det;
    }
    quantize(e0, q0);
    quantize(e1, q1);
    return 1;
}

/* +-1 steps on each endpoint component while the error drops. */
static void bc1_local_search(bc1_ctx *c, int three)
{
    static const int limit[3] = {31, 63, 31};
    for (int round = 0; round < 8; round++) {
        int improved = 0;
        for (int e = 0; e < 2; e++) {
            for (int k = 0; k < 3; k++) {
                for (int dir = -1; dir <= 1; dir += 2) {
                    int q[2][3];
                    uint32_t before = c->best_err;
                    memcpy(q, c->best_q, sizeof q);
                    q[e][k] += dir;
                    if (q[e][k] < 0 || q[e][k] > limit[k])
                        continue;
                    bc1_try(c, q[0], q[1], three);
                    if (c->best_err < before)
                        improved = 1;
                }
            }
        }
        if (!improved || c->best_err == 0)
            break;
    }
}

void dxvk_bc1_encode(const uint8_t px[16][4], int best, int bc3_colour, uint8_t out[8])
{
    bc1_ctx c;
    int mn[3] = {255, 255, 255}, mx[3] = {0, 0, 0};
    float mean[3] = {0, 0, 0}, cov[6] = {0, 0, 0, 0, 0, 0}, axis[3];
    int q0[3], q1[3];

    c.best_err = UINT32_MAX;
    for (int i = 0; i < 16; i++)
        for (int k = 0; k < 3; k++) {
            int v = px[i][k];
            c.px[i][k] = v;
            if (v < mn[k])
                mn[k] = v;
            if (v > mx[k])
                mx[k] = v;
            mean[k] += (float)v;
        }

    if (mn[0] == mx[0] && mn[1] == mx[1] && mn[2] == mx[2]) {
        /* single colour: the optimal-pair tables */
        int a[3], b[3];
        a[0] = solid_four5[mn[0]].e0, b[0] = solid_four5[mn[0]].e1;
        a[1] = solid_four6[mn[1]].e0, b[1] = solid_four6[mn[1]].e1;
        a[2] = solid_four5[mn[2]].e0, b[2] = solid_four5[mn[2]].e1;
        bc1_try(&c, a, b, 0);
        if (best && !bc3_colour && c.best_err) {
            a[0] = solid_three5[mn[0]].e0, b[0] = solid_three5[mn[0]].e1;
            a[1] = solid_three6[mn[1]].e0, b[1] = solid_three6[mn[1]].e1;
            a[2] = solid_three5[mn[2]].e0, b[2] = solid_three5[mn[2]].e1;
            bc1_try(&c, a, b, 1);
        }
        memcpy(out, c.best, 8);
        return;
    }

    /* principal axis by power iteration on the covariance */
    for (int k = 0; k < 3; k++)
        mean[k] *= 1.0f / 16.0f;
    for (int i = 0; i < 16; i++) {
        float d0 = (float)c.px[i][0] - mean[0], d1 = (float)c.px[i][1] - mean[1],
              d2 = (float)c.px[i][2] - mean[2];
        cov[0] += d0 * d0, cov[1] += d0 * d1, cov[2] += d0 * d2;
        cov[3] += d1 * d1, cov[4] += d1 * d2, cov[5] += d2 * d2;
    }
    axis[0] = (float)(mx[0] - mn[0]);
    axis[1] = (float)(mx[1] - mn[1]);
    axis[2] = (float)(mx[2] - mn[2]);
    for (int it = 0; it < 4; it++) {
        float x = cov[0] * axis[0] + cov[1] * axis[1] + cov[2] * axis[2];
        float y = cov[1] * axis[0] + cov[3] * axis[1] + cov[4] * axis[2];
        float z = cov[2] * axis[0] + cov[4] * axis[1] + cov[5] * axis[2];
        float m = x < 0 ? -x : x;
        if ((y < 0 ? -y : y) > m)
            m = y < 0 ? -y : y;
        if ((z < 0 ? -z : z) > m)
            m = z < 0 ? -z : z;
        if (m < 1e-6f)
            break;
        axis[0] = x / m, axis[1] = y / m, axis[2] = z / m;
    }
    {
        float lo = 1e30f, hi = -1e30f, len2;
        float e0[3], e1[3];
        len2 = axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2];
        if (len2 < 1e-12f) {
            axis[0] = axis[1] = axis[2] = 1.0f;
            len2 = 3.0f;
        }
        for (int i = 0; i < 16; i++) {
            float p = ((float)c.px[i][0] - mean[0]) * axis[0] +
                      ((float)c.px[i][1] - mean[1]) * axis[1] +
                      ((float)c.px[i][2] - mean[2]) * axis[2];
            if (p < lo)
                lo = p;
            if (p > hi)
                hi = p;
        }
        for (int k = 0; k < 3; k++) {
            e0[k] = mean[k] + axis[k] * hi / len2;
            e1[k] = mean[k] + axis[k] * lo / len2;
        }
        quantize(e0, q0);
        quantize(e1, q1);
    }
    bc1_try(&c, q0, q1, 0);

    for (int it = 0; it < (best ? 4 : 1); it++) {
        uint32_t before = c.best_err;
        if (c.best_err == 0 || !bc1_refit(&c, 0, q0, q1))
            break;
        bc1_try(&c, q0, q1, 0);
        if (c.best_err >= before)
            break;
    }
    if (best && c.best_err) {
        bc1_local_search(&c, 0);
        if (!bc3_colour) {
            /* three-colour mode (index 3 never used) from the four-colour endpoints */
            uint32_t four_err = c.best_err;
            uint8_t four_block[8];
            int a[2][3];
            memcpy(four_block, c.best, 8);
            memcpy(a, c.best_q, sizeof a);
            c.best_err = UINT32_MAX;
            bc1_try(&c, a[0], a[1], 1);
            for (int it = 0; it < 3; it++) {
                uint32_t before = c.best_err;
                if (c.best_err == 0 || !bc1_refit(&c, 1, q0, q1))
                    break;
                bc1_try(&c, q0, q1, 1);
                if (c.best_err >= before)
                    break;
            }
            if (c.best_err && c.best_three)
                bc1_local_search(&c, 1);
            if (c.best_err >= four_err)
                memcpy(c.best, four_block, 8);
        }
    }
    memcpy(out, c.best, 8);
}

/* ---------------------------------------------------------------------------------------------- */
/* BC4                                                                                            */
/* ---------------------------------------------------------------------------------------------- */

/* Squared error of endpoints (a0, a1) with nearest indices; fills *bits (48-bit indices). */
static uint32_t bc4_eval(const uint8_t v[16], int a0, int a1, uint64_t *bits, uint32_t limit)
{
    int pal[8];
    uint32_t err = 0;
    uint64_t idx = 0;
    pal[0] = a0;
    pal[1] = a1;
    if (a0 > a1) {
        for (int i = 1; i <= 6; i++)
            pal[1 + i] = ((7 - i) * a0 + i * a1) / 7;
    } else {
        for (int i = 1; i <= 4; i++)
            pal[1 + i] = ((5 - i) * a0 + i * a1) / 5;
        pal[6] = 0;
        pal[7] = 255;
    }
    for (int i = 0; i < 16; i++) {
        int be = 1 << 30, bi = 0;
        for (int j = 0; j < 8; j++) {
            int d = v[i] - pal[j];
            d *= d;
            if (d < be) {
                be = d;
                bi = j;
            }
        }
        err += (uint32_t)be;
        idx |= (uint64_t)bi << (3 * i);
        if (err > limit)
            return err;
    }
    *bits = idx;
    return err;
}

typedef struct bc4_best {
    uint32_t err;
    int a0, a1;
    uint64_t bits;
} bc4_best;

DXVK_INLINE void bc4_try(const uint8_t v[16], int a0, int a1, bc4_best *b)
{
    uint64_t bits;
    uint32_t e;
    if (a0 < 0 || a0 > 255 || a1 < 0 || a1 > 255)
        return;
    e = bc4_eval(v, a0, a1, &bits, b->err);
    if (e < b->err) {
        b->err = e;
        b->a0 = a0;
        b->a1 = a1;
        b->bits = bits;
    }
}

void dxvk_bc4_encode(const uint8_t v[16], int best, uint8_t out[8])
{
    int mn = 255, mx = 0;
    bc4_best b;
    b.err = UINT32_MAX;
    b.a0 = b.a1 = 0;
    b.bits = 0;
    for (int i = 0; i < 16; i++) {
        if (v[i] < mn)
            mn = v[i];
        if (v[i] > mx)
            mx = v[i];
    }
    if (mn == mx) {
        /* a0 = a1: six-value mode, every index 0 */
        b.a0 = b.a1 = mn;
        b.bits = 0;
    } else {
        bc4_try(v, mx, mn, &b);
        if (best && b.err) {
            int lo6 = 255, hi6 = 0;
            /* eight-value mode: endpoints pulled inwards */
            for (int d0 = 0; d0 <= 2; d0++)
                for (int d1 = 0; d1 <= 2; d1++)
                    if (mx - d0 > mn + d1)
                        bc4_try(v, mx - d0, mn + d1, &b);
            /* least-squares refit of the eight-value endpoints from the best indices */
            if (b.a0 > b.a1) {
                long aa = 0, ab = 0, bb = 0, ax = 0, bx = 0, det;
                for (int i = 0; i < 16; i++) {
                    int s = (int)((b.bits >> (3 * i)) & 7u);
                    int a = s == 0 ? 7 : s == 1 ? 0 : 8 - s, w = 7 - a;
                    aa += a * a, ab += a * w, bb += w * w;
                    ax += a * v[i], bx += w * v[i];
                }
                det = aa * bb - ab * ab;
                if (det != 0) {
                    int r0 = (int)((7.0f * (float)(bb * ax - ab * bx)) / (float)det + 0.5f);
                    int r1 = (int)((7.0f * (float)(aa * bx - ab * ax)) / (float)det + 0.5f);
                    for (int d0 = -1; d0 <= 1; d0++)
                        for (int d1 = -1; d1 <= 1; d1++)
                            if (r0 + d0 > r1 + d1)
                                bc4_try(v, r0 + d0, r1 + d1, &b);
                }
            }
            /* six-value mode when the block reaches the 0 / 255 extremes */
            if (mn <= 8 || mx >= 247) {
                for (int i = 0; i < 16; i++) {
                    if (v[i] == 0 || v[i] == 255)
                        continue;
                    if (v[i] < lo6)
                        lo6 = v[i];
                    if (v[i] > hi6)
                        hi6 = v[i];
                }
                if (lo6 > hi6)
                    lo6 = hi6 = 0;
                bc4_try(v, lo6, hi6, &b);
                if (hi6 - lo6 >= 2)
                    bc4_try(v, lo6 + 1, hi6 - 1, &b);
            }
        }
    }
    out[0] = (uint8_t)b.a0;
    out[1] = (uint8_t)b.a1;
    for (int i = 0; i < 6; i++)
        out[2 + i] = (uint8_t)(b.bits >> (8 * i));
}

/* ---------------------------------------------------------------------------------------------- */
/* BC4 with fractional targets (HQ Y, Co, Cg; W6)                                                 */
/* ---------------------------------------------------------------------------------------------- */

/* Targets are in units of 1/16 (0..4080): the exact YCoCg values of ENCODING_NOTES 5 are multiples of
 * 1/4 (Y), 1/8 (Co) and 1/16 (Cg). The error is measured against the exact palette (no truncation), the
 * way a GPU and spec 8.4 read the block, in units of 1/560 (= 1/16 x 1/35). */

#define FINE_MAX 4080

static uint64_t bc4f_eval(const uint16_t v[16], int a0, int a1, uint64_t *bits, uint64_t limit)
{
    int64_t pal[8];
    uint64_t err = 0, idx = 0;
    pal[0] = (int64_t)a0 * 560;
    pal[1] = (int64_t)a1 * 560;
    if (a0 > a1) {
        for (int i = 1; i <= 6; i++)
            pal[1 + i] = (int64_t)((7 - i) * a0 + i * a1) * 80;
    } else {
        for (int i = 1; i <= 4; i++)
            pal[1 + i] = (int64_t)((5 - i) * a0 + i * a1) * 112;
        pal[6] = 0;
        pal[7] = 255 * 560;
    }
    for (int i = 0; i < 16; i++) {
        int64_t t = (int64_t)v[i] * 35;
        uint64_t be = UINT64_MAX;
        int bi = 0;
        for (int j = 0; j < 8; j++) {
            int64_t d = t - pal[j];
            uint64_t dd = (uint64_t)(d * d);
            if (dd < be) {
                be = dd;
                bi = j;
            }
        }
        err += be;
        idx |= (uint64_t)bi << (3 * i);
        if (err > limit)
            return err;
    }
    *bits = idx;
    return err;
}

typedef struct bc4f_best {
    uint64_t err;
    int a0, a1;
    uint64_t bits;
} bc4f_best;

DXVK_INLINE void bc4f_try(const uint16_t v[16], int a0, int a1, bc4f_best *b)
{
    uint64_t bits, e;
    if (a0 < 0 || a0 > 255 || a1 < 0 || a1 > 255)
        return;
    e = bc4f_eval(v, a0, a1, &bits, b->err);
    if (e < b->err) {
        b->err = e;
        b->a0 = a0;
        b->a1 = a1;
        b->bits = bits;
    }
}

void dxvk_bc4_encode_fine(const uint16_t v[16], int best, uint8_t out[8])
{
    int mn = FINE_MAX, mx = 0, lo, hi;
    bc4f_best b;
    b.err = UINT64_MAX;
    b.a0 = b.a1 = 0;
    b.bits = 0;
    for (int i = 0; i < 16; i++) {
        if (v[i] < mn)
            mn = v[i];
        if (v[i] > mx)
            mx = v[i];
    }
    lo = mn / 16;          /* floor */
    hi = (mx + 15) / 16;   /* ceil */
    if (lo == hi) {
        /* every target the same whole number: a0 = a1, six-value mode, every index 0 */
        b.a0 = b.a1 = lo;
    } else {
        bc4f_try(v, hi, lo, &b);
        if (best && b.err) {
            /* eight-value mode: endpoints pulled inwards */
            for (int d0 = 0; d0 <= 2; d0++)
                for (int d1 = 0; d1 <= 2; d1++)
                    if (hi - d0 > lo + d1)
                        bc4f_try(v, hi - d0, lo + d1, &b);
            /* least-squares refit of the eight-value endpoints from the best indices */
            if (b.a0 > b.a1) {
                double aa = 0, ab = 0, bb = 0, ax = 0, bx = 0, det;
                for (int i = 0; i < 16; i++) {
                    int s = (int)((b.bits >> (3 * i)) & 7u);
                    int a = s == 0 ? 7 : s == 1 ? 0 : 8 - s, w = 7 - a;
                    double t = v[i] / 16.0;
                    aa += a * a, ab += a * w, bb += w * w;
                    ax += a * t, bx += w * t;
                }
                det = aa * bb - ab * ab;
                if (det != 0) {
                    int r0 = (int)floor(7.0 * (bb * ax - ab * bx) / det + 0.5);
                    int r1 = (int)floor(7.0 * (aa * bx - ab * ax) / det + 0.5);
                    for (int d0 = -1; d0 <= 1; d0++)
                        for (int d1 = -1; d1 <= 1; d1++)
                            if (r0 + d0 > r1 + d1)
                                bc4f_try(v, r0 + d0, r1 + d1, &b);
                }
            }
            /* six-value mode when the block reaches the 0 / 255 extremes */
            if (mn <= 8 * 16 || mx >= 247 * 16) {
                int lo6 = FINE_MAX, hi6 = 0;
                for (int i = 0; i < 16; i++) {
                    if (v[i] == 0 || v[i] == FINE_MAX)
                        continue;
                    if (v[i] < lo6)
                        lo6 = v[i];
                    if (v[i] > hi6)
                        hi6 = v[i];
                }
                if (lo6 > hi6)
                    lo6 = hi6 = 0;
                lo6 /= 16;
                hi6 = (hi6 + 15) / 16;
                bc4f_try(v, lo6, hi6, &b);
                if (hi6 - lo6 >= 2)
                    bc4f_try(v, lo6 + 1, hi6 - 1, &b);
            }
        }
    }
    out[0] = (uint8_t)b.a0;
    out[1] = (uint8_t)b.a1;
    for (int i = 0; i < 6; i++)
        out[2 + i] = (uint8_t)(b.bits >> (8 * i));
}
