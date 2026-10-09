/*
 * DXVKit: QuickTime (.mov) writer for one DXV3 ('DXD3') video track.
 *
 * Written from Apple's QuickTime File Format documentation (ftyp, wide, mdat, moov, mvhd, tkhd, mdia,
 * mdhd, hdlr, minf, vmhd, dinf / dref, stbl, stsd, stts, stsc, stsz, stco / co64) and the sample-entry
 * fields of docs/spec/DXV_FORMAT.md section 2.2 / docs/spec/ENCODING_NOTES.md section 1.
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#if !defined(_WIN32) && !defined(_FILE_OFFSET_BITS)
#define _FILE_OFFSET_BITS 64
#endif
#include "enc_priv.h"

#include <stdio.h>
#include <stdlib.h>
#if !defined(_WIN32)
#include <sys/types.h>
#endif

#define FTYP_BYTES 20u
#define SAMPLE_ENTRY_BYTES 86u

struct dxvk_mov_writer {
    dxvk_sink sink;
    uint32_t width, height, timescale, frame_duration;
    uint64_t wide_pos, data_pos, pos;  /* pos = end of the media data so far */
    uint32_t *sizes;
    uint64_t *offsets;
    uint32_t count, cap;
    int have_variant, finished, failed;
    dxvk_variant variant;
};

static int file_seek(FILE *f, uint64_t offset)
{
#if defined(_WIN32)
    return _fseeki64(f, (__int64)offset, SEEK_SET);
#else
    return fseeko(f, (off_t)offset, SEEK_SET);
#endif
}

static size_t file_write_at(void *user, uint64_t offset, const void *data, size_t size)
{
    FILE *f = (FILE *)user;
    if (file_seek(f, offset) != 0)
        return 0;
    return fwrite(data, 1, size, f);
}

static void file_close(void *user) { fclose((FILE *)user); }

static int write_at(dxvk_mov_writer *w, uint64_t offset, const void *data, size_t size)
{
    if (w->sink.write_at(w->sink.user, offset, data, size) != size) {
        w->failed = 1;
        return 0;
    }
    return 1;
}

/* ---------------------------------------------------------------------------------------------- */
/* Atom builder                                                                                   */
/* ---------------------------------------------------------------------------------------------- */

typedef struct buf {
    uint8_t *p;
    size_t n, cap;
    int oom;
} buf;

static uint8_t *grow(buf *b, size_t n)
{
    if (b->oom)
        return NULL;
    if (b->cap - b->n < n) {
        size_t cap = b->cap ? b->cap : 4096;
        uint8_t *p;
        while (cap - b->n < n)
            cap *= 2;
        p = (uint8_t *)realloc(b->p, cap);
        if (!p) {
            b->oom = 1;
            return NULL;
        }
        b->p = p;
        b->cap = cap;
    }
    b->n += n;
    return b->p + b->n - n;
}

static void u8(buf *b, uint32_t v)
{
    uint8_t *p = grow(b, 1);
    if (p)
        p[0] = (uint8_t)v;
}
static void u16(buf *b, uint32_t v)
{
    uint8_t *p = grow(b, 2);
    if (p)
        dxvk_put_be16(p, v);
}
static void u32(buf *b, uint32_t v)
{
    uint8_t *p = grow(b, 4);
    if (p)
        dxvk_put_be32(p, v);
}
static void u64(buf *b, uint64_t v)
{
    u32(b, (uint32_t)(v >> 32));
    u32(b, (uint32_t)v);
}
static void zeros(buf *b, size_t n)
{
    uint8_t *p = grow(b, n);
    if (p)
        memset(p, 0, n);
}
static void fourcc(buf *b, const char *s) { u32(b, dxvk_be32((const uint8_t *)s)); }

/* Opens an atom; returns its start for close_atom. */
static size_t open_atom(buf *b, const char *type)
{
    size_t at = b->n;
    u32(b, 0);
    fourcc(b, type);
    return at;
}

static void close_atom(buf *b, size_t at)
{
    if (!b->oom)
        dxvk_put_be32(b->p + at, (uint32_t)(b->n - at));
}

static void matrix(buf *b)
{
    static const uint32_t m[9] = {0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000};
    for (int i = 0; i < 9; i++)
        u32(b, m[i]);
}

static void handler(buf *b, const char *component, const char *subtype)
{
    size_t a = open_atom(b, "hdlr");
    u32(b, 0);          /* version, flags */
    fourcc(b, component);
    fourcc(b, subtype);
    u32(b, 0);          /* manufacturer */
    u32(b, 0);          /* flags */
    u32(b, 0);          /* flags mask */
    u8(b, 0);           /* name: empty Pascal string */
    close_atom(b, a);
}

static void build_moov(const dxvk_mov_writer *w, buf *b, int co64)
{
    uint64_t duration = (uint64_t)w->count * w->frame_duration;
    size_t moov, trak, mdia, minf, dinf, dref, stbl, a;

    moov = open_atom(b, "moov");

    a = open_atom(b, "mvhd");
    u32(b, 0);                         /* version 0, flags */
    u32(b, 0);                         /* creation time */
    u32(b, 0);                         /* modification time */
    u32(b, w->timescale);
    u32(b, (uint32_t)duration);
    u32(b, 0x00010000);                /* preferred rate 1.0 */
    u16(b, 0x0100);                    /* preferred volume 1.0 */
    zeros(b, 10);
    matrix(b);
    zeros(b, 24);                      /* preview, poster, selection, current time */
    u32(b, 2);                         /* next track id */
    close_atom(b, a);

    trak = open_atom(b, "trak");
    a = open_atom(b, "tkhd");
    u32(b, 0x0000000F);                /* version 0; enabled, in movie, in preview, in poster */
    u32(b, 0);
    u32(b, 0);
    u32(b, 1);                         /* track id */
    u32(b, 0);
    u32(b, (uint32_t)duration);
    zeros(b, 8);
    u16(b, 0);                         /* layer */
    u16(b, 0);                         /* alternate group */
    u16(b, 0);                         /* volume (video) */
    u16(b, 0);
    matrix(b);
    u32(b, w->width << 16);            /* display size, 16.16 */
    u32(b, w->height << 16);
    close_atom(b, a);

    mdia = open_atom(b, "mdia");
    a = open_atom(b, "mdhd");
    u32(b, 0);
    u32(b, 0);
    u32(b, 0);
    u32(b, w->timescale);
    u32(b, (uint32_t)duration);
    u16(b, 0x55C4);                    /* language "und" */
    u16(b, 0);                         /* quality */
    close_atom(b, a);
    handler(b, "mhlr", "vide");

    minf = open_atom(b, "minf");
    a = open_atom(b, "vmhd");
    u32(b, 0x00000001);                /* version 0, flags 1 */
    u16(b, 0x0040);                    /* graphics mode: dither copy */
    u16(b, 0x8000);
    u16(b, 0x8000);
    u16(b, 0x8000);
    close_atom(b, a);
    handler(b, "dhlr", "alis");
    dinf = open_atom(b, "dinf");
    dref = open_atom(b, "dref");
    u32(b, 0);
    u32(b, 1);
    a = open_atom(b, "alis");
    u32(b, 0x00000001);                /* self reference: the media is in this file */
    close_atom(b, a);
    close_atom(b, dref);
    close_atom(b, dinf);

    stbl = open_atom(b, "stbl");
    a = open_atom(b, "stsd");
    u32(b, 0);
    u32(b, 1);
    /* the 86-byte sample entry as Resolume writes it (spec 2.2) */
    u32(b, SAMPLE_ENTRY_BYTES);
    fourcc(b, "DXD3");
    zeros(b, 6);
    u16(b, 1);                         /* data reference index */
    u16(b, 0);                         /* version */
    u16(b, 0);                         /* revision */
    fourcc(b, "FFMP");                 /* vendor */
    u32(b, 512);                       /* temporal quality */
    u32(b, 512);                       /* spatial quality */
    u16(b, w->width);
    u16(b, w->height);
    u32(b, 0x00480000);                /* 72 dpi */
    u32(b, 0x00480000);
    u32(b, 0);                         /* data size */
    u16(b, 1);                         /* frame count */
    zeros(b, 32);                      /* compressor name: empty */
    u16(b, 24);                        /* depth (24 also with alpha) */
    u16(b, 0xFFFF);                    /* colour table id -1 */
    close_atom(b, a);

    a = open_atom(b, "stts");
    u32(b, 0);
    u32(b, 1);
    u32(b, w->count);
    u32(b, w->frame_duration);
    close_atom(b, a);

    a = open_atom(b, "stsc");
    u32(b, 0);
    u32(b, 1);
    u32(b, 1);                         /* first chunk */
    u32(b, 1);                         /* samples per chunk */
    u32(b, 1);                         /* sample description */
    close_atom(b, a);

    a = open_atom(b, "stsz");
    u32(b, 0);
    u32(b, 0);                         /* sizes vary */
    u32(b, w->count);
    for (uint32_t i = 0; i < w->count; i++)
        u32(b, w->sizes[i]);
    close_atom(b, a);

    a = open_atom(b, co64 ? "co64" : "stco");
    u32(b, 0);
    u32(b, w->count);
    for (uint32_t i = 0; i < w->count; i++) {
        if (co64)
            u64(b, w->offsets[i]);
        else
            u32(b, (uint32_t)w->offsets[i]);
    }
    close_atom(b, a);

    close_atom(b, stbl);
    close_atom(b, minf);
    close_atom(b, mdia);
    close_atom(b, trak);
    close_atom(b, moov);
}

/* ---------------------------------------------------------------------------------------------- */
/* Public API                                                                                     */
/* ---------------------------------------------------------------------------------------------- */

dxvk_status dxvk_mov_writer_open_sink(const dxvk_sink *sink, uint32_t width, uint32_t height,
                                      uint32_t timescale, uint32_t frame_duration,
                                      dxvk_mov_writer **out)
{
    dxvk_mov_writer *w;
    uint8_t head[FTYP_BYTES + 16];
    if (!out || !sink || !sink->write_at || width == 0 || height == 0 ||
        width > DXVK_MAX_DIMENSION || height > DXVK_MAX_DIMENSION || timescale == 0 ||
        frame_duration == 0) {
        if (sink && sink->close)
            sink->close(sink->user);
        return DXVK_ERR_ARGUMENT;
    }
    *out = NULL;
    w = (dxvk_mov_writer *)calloc(1, sizeof *w);
    if (!w) {
        if (sink->close)
            sink->close(sink->user);
        return DXVK_ERR_OUT_OF_MEMORY;
    }
    w->sink = *sink;
    w->width = width;
    w->height = height;
    w->timescale = timescale;
    w->frame_duration = frame_duration;

    /* ftyp 'qt  ', a 'wide' atom (room for a 64-bit mdat header), the mdat header */
    dxvk_put_be32(head, FTYP_BYTES);
    memcpy(head + 4, "ftypqt  ", 8);
    dxvk_put_be32(head + 12, 0x00000200);
    memcpy(head + 16, "qt  ", 4);
    dxvk_put_be32(head + 20, 8);
    memcpy(head + 24, "wide", 4);
    dxvk_put_be32(head + 28, 8);
    memcpy(head + 32, "mdat", 4);
    w->wide_pos = FTYP_BYTES;
    w->data_pos = FTYP_BYTES + 16u;
    w->pos = w->data_pos;
    if (!write_at(w, 0, head, sizeof head)) {
        dxvk_mov_writer_close(w);
        return DXVK_ERR_IO;
    }
    *out = w;
    return DXVK_OK;
}

dxvk_status dxvk_mov_writer_open_file(const char *path, uint32_t width, uint32_t height,
                                      uint32_t timescale, uint32_t frame_duration,
                                      dxvk_mov_writer **out)
{
    dxvk_sink sink;
    FILE *f;
    if (!path || !out)
        return DXVK_ERR_ARGUMENT;
    f = fopen(path, "wb");
    if (!f)
        return DXVK_ERR_IO;
    sink.write_at = file_write_at;
    sink.user = f;
    sink.close = file_close;
    return dxvk_mov_writer_open_sink(&sink, width, height, timescale, frame_duration, out);
}

dxvk_status dxvk_mov_writer_add(dxvk_mov_writer *w, const void *packet, size_t size)
{
    dxvk_variant v;
    if (!w || !packet || w->finished || w->failed || size > 0xFFFFFFFFu)
        return DXVK_ERR_ARGUMENT;
    if (dxvk_packet_variant(DXVK_GEN_DXV3, packet, size, &v, NULL) != DXVK_OK)
        return DXVK_ERR_ARGUMENT;
    if (w->have_variant && v != w->variant)
        return DXVK_ERR_ARGUMENT;
    if (w->count == UINT32_MAX)
        return DXVK_ERR_RANGE;
    if (w->count == w->cap) {
        uint32_t cap = w->cap ? w->cap * 2u : 256u;
        uint32_t *sizes = (uint32_t *)realloc(w->sizes, (size_t)cap * sizeof *sizes);
        uint64_t *offsets;
        if (!sizes)
            return DXVK_ERR_OUT_OF_MEMORY;
        w->sizes = sizes;
        offsets = (uint64_t *)realloc(w->offsets, (size_t)cap * sizeof *offsets);
        if (!offsets)
            return DXVK_ERR_OUT_OF_MEMORY;
        w->offsets = offsets;
        w->cap = cap;
    }
    if (!write_at(w, w->pos, packet, size))
        return DXVK_ERR_IO;
    w->variant = v;
    w->have_variant = 1;
    w->sizes[w->count] = (uint32_t)size;
    w->offsets[w->count] = w->pos;
    w->count++;
    w->pos += size;
    return DXVK_OK;
}

dxvk_status dxvk_mov_writer_finish(dxvk_mov_writer *w)
{
    buf b;
    uint64_t mdat = w ? w->pos - (w->data_pos - 8u) : 0;
    uint8_t h[16];
    int co64;
    if (!w || w->finished || w->failed || w->count == 0)
        return DXVK_ERR_ARGUMENT;
    if ((uint64_t)w->count * w->frame_duration > 0xFFFFFFFFu)
        return DXVK_ERR_RANGE; /* version-0 durations */
    co64 = w->offsets[w->count - 1u] > 0xFFFFFFFFu;
    memset(&b, 0, sizeof b);
    build_moov(w, &b, co64);
    if (b.oom) {
        free(b.p);
        return DXVK_ERR_OUT_OF_MEMORY;
    }
    if (!write_at(w, w->pos, b.p, b.n)) {
        free(b.p);
        return DXVK_ERR_IO;
    }
    free(b.p);
    if (mdat <= 0xFFFFFFFFu) {
        dxvk_put_be32(h, (uint32_t)mdat);
        memcpy(h + 4, "mdat", 4);
        if (!write_at(w, w->data_pos - 8u, h, 8))
            return DXVK_ERR_IO;
    } else {
        /* 64-bit mdat header over the 'wide' atom and the 32-bit header */
        dxvk_put_be32(h, 1);
        memcpy(h + 4, "mdat", 4);
        dxvk_put_be32(h + 8, (uint32_t)((mdat + 8u) >> 32));
        dxvk_put_be32(h + 12, (uint32_t)(mdat + 8u));
        if (!write_at(w, w->wide_pos, h, 16))
            return DXVK_ERR_IO;
    }
    w->finished = 1;
    return DXVK_OK;
}

void dxvk_mov_writer_close(dxvk_mov_writer *w)
{
    if (!w)
        return;
    if (w->sink.close)
        w->sink.close(w->sink.user);
    free(w->sizes);
    free(w->offsets);
    free(w);
}
