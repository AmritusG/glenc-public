/*
 * DXVKit: QuickTime (.mov) demuxer for DXV tracks.
 *
 * Written from Apple's QuickTime File Format documentation (atoms, sample description, stts, stsz,
 * stsc, stco / co64) and docs/spec/DXV_FORMAT.md section 2.
 *
 * MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.
 */
#if !defined(_WIN32) && !defined(_FILE_OFFSET_BITS)
#define _FILE_OFFSET_BITS 64
#endif
#if !defined(_WIN32) && !defined(_POSIX_C_SOURCE) && !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif
#include "dxvk_priv.h"

#include <stdio.h>
#include <stdlib.h>
#if !defined(_WIN32)
#include <sys/types.h>
#endif

#define FOURCC(a, b, c, d)                                                                         \
    (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))

#define MAX_MOOV_BYTES (64u << 20)
#define MAX_SAMPLES (1u << 24)

struct dxvk_mov {
    dxvk_reader reader;
    dxvk_mov_info info;
    uint64_t *offsets;
    uint32_t *sizes;
};

/* ---------------------------------------------------------------------------------------------- */
/* Readers                                                                                        */
/* ---------------------------------------------------------------------------------------------- */

typedef struct memory_source {
    const uint8_t *data;
    size_t size;
} memory_source;

static size_t memory_read_at(void *user, uint64_t offset, void *buffer, size_t size)
{
    const memory_source *m = (const memory_source *)user;
    if (offset >= m->size)
        return 0;
    if (size > m->size - (size_t)offset)
        size = m->size - (size_t)offset;
    memcpy(buffer, m->data + offset, size);
    return size;
}

static void memory_close(void *user) { free(user); }

static int file_seek(FILE *f, uint64_t offset)
{
#if defined(_WIN32)
    return _fseeki64(f, (__int64)offset, SEEK_SET);
#else
    return fseeko(f, (off_t)offset, SEEK_SET);
#endif
}

static size_t file_read_at(void *user, uint64_t offset, void *buffer, size_t size)
{
    FILE *f = (FILE *)user;
    if (file_seek(f, offset) != 0)
        return 0;
    return fread(buffer, 1, size, f);
}

static void file_close(void *user) { fclose((FILE *)user); }

/* ---------------------------------------------------------------------------------------------- */
/* Atoms in memory                                                                                */
/* ---------------------------------------------------------------------------------------------- */

typedef struct span {
    const uint8_t *p;
    size_t n;
} span;

/* Iterates the atoms in `parent`; *it is the position of the next atom (start at 0). Returns 1 with
 * type and body (payload after the header), 0 at the end, -1 on a malformed atom. */
static int next_atom(span parent, size_t *it, uint32_t *type, span *body)
{
    size_t pos = *it, left, header = 8;
    uint64_t size;
    if (pos >= parent.n)
        return 0;
    left = parent.n - pos;
    if (left < 8)
        return -1;
    size = dxvk_be32(parent.p + pos);
    *type = dxvk_be32(parent.p + pos + 4);
    if (size == 1) {
        if (left < 16)
            return -1;
        size = dxvk_be64(parent.p + pos + 8);
        header = 16;
    } else if (size == 0) {
        size = left;
    }
    if (size < header || size > left)
        return -1;
    body->p = parent.p + pos + header;
    body->n = (size_t)size - header;
    *it = pos + (size_t)size;
    return 1;
}

/* First child atom of a type. Returns 1 found, 0 absent, -1 malformed. */
static int find_atom(span parent, uint32_t type, span *body)
{
    size_t it = 0;
    uint32_t t;
    int r;
    while ((r = next_atom(parent, &it, &t, body)) == 1)
        if (t == type)
            return 1;
    return r;
}

static int find_path(span parent, const uint32_t *path, int depth, span *body)
{
    span cur = parent;
    for (int i = 0; i < depth; i++) {
        int r = find_atom(cur, path[i], &cur);
        if (r != 1)
            return r;
    }
    *body = cur;
    return 1;
}

/* ---------------------------------------------------------------------------------------------- */
/* Track parsing                                                                                  */
/* ---------------------------------------------------------------------------------------------- */

typedef struct track_tables {
    span stsd, stts, stsz, stsc, stco;
    int co64;
    span mdhd, tkhd;
} track_tables;

static int is_dxv_fourcc(uint32_t f, dxvk_generation *gen)
{
    /* the FourCCs Arena 7.28 loads; the generation is only a hint, packets decide (spec 2.2) */
    if (f == FOURCC('D', 'X', 'D', '3') || f == FOURCC('D', 'X', 'D', '4')) {
        *gen = DXVK_GEN_DXV3;
        return 1;
    }
    if (f == FOURCC('D', 'X', 'D', 'I')) {
        *gen = DXVK_GEN_LEGACY;
        return 1;
    }
    return 0;
}

/* Returns 1 when the trak is a DXV track (tables filled), 0 when it is some other track, or a negative
 * dxvk_status for a malformed DXV track. */
static int read_track(span trak, track_tables *t, dxvk_mov_info *info)
{
    static const uint32_t stbl_path[] = {FOURCC('m', 'd', 'i', 'a'), FOURCC('m', 'i', 'n', 'f'),
                                         FOURCC('s', 't', 'b', 'l')};
    static const uint32_t mdhd_path[] = {FOURCC('m', 'd', 'i', 'a'), FOURCC('m', 'd', 'h', 'd')};
    span stbl, entry;
    uint32_t entries, entry_size, fourcc;
    dxvk_generation gen;

    if (find_path(trak, stbl_path, 3, &stbl) != 1)
        return 0;
    if (find_atom(stbl, FOURCC('s', 't', 's', 'd'), &t->stsd) != 1 || t->stsd.n < 16)
        return 0;
    entries = dxvk_be32(t->stsd.p + 4);
    entry.p = t->stsd.p + 8;
    entry.n = t->stsd.n - 8;
    entry_size = dxvk_be32(entry.p);
    fourcc = dxvk_be32(entry.p + 4);
    if (entries < 1 || !is_dxv_fourcc(fourcc, &gen))
        return 0;
    /* a DXV track from here on: everything must be well formed */
    if (entry_size < 86 || entry_size > entry.n)
        return -(int)DXVK_ERR_MOV_CORRUPT;
    info->generation = gen;
    info->fourcc = fourcc;
    info->width = dxvk_be16(entry.p + 32);
    info->height = dxvk_be16(entry.p + 34);

    if (find_atom(stbl, FOURCC('s', 't', 's', 'z'), &t->stsz) != 1 ||
        find_atom(stbl, FOURCC('s', 't', 's', 'c'), &t->stsc) != 1)
        return -(int)DXVK_ERR_MOV_CORRUPT;
    t->co64 = 0;
    if (find_atom(stbl, FOURCC('s', 't', 'c', 'o'), &t->stco) != 1) {
        if (find_atom(stbl, FOURCC('c', 'o', '6', '4'), &t->stco) != 1)
            return -(int)DXVK_ERR_MOV_CORRUPT;
        t->co64 = 1;
    }
    if (find_atom(stbl, FOURCC('s', 't', 't', 's'), &t->stts) != 1)
        t->stts.n = 0;
    if (find_path(trak, mdhd_path, 2, &t->mdhd) != 1)
        t->mdhd.n = 0;
    if (find_atom(trak, FOURCC('t', 'k', 'h', 'd'), &t->tkhd) != 1)
        t->tkhd.n = 0;
    return 1;
}

static void read_timing(const track_tables *t, dxvk_mov_info *info)
{
    const uint8_t *m = t->mdhd.p;
    if (t->mdhd.n >= 24 && m[0] == 0) {
        info->timescale = dxvk_be32(m + 12);
        info->duration = dxvk_be32(m + 16);
    } else if (t->mdhd.n >= 36 && m[0] == 1) {
        info->timescale = dxvk_be32(m + 20);
        info->duration = dxvk_be64(m + 24);
    }
    if (t->tkhd.n >= 16 && t->tkhd.p[0] == 0)
        info->track_id = dxvk_be32(t->tkhd.p + 12);
    else if (t->tkhd.n >= 24 && t->tkhd.p[0] == 1)
        info->track_id = dxvk_be32(t->tkhd.p + 20);
    if (t->stts.n >= 16 && dxvk_be32(t->stts.p + 4) >= 1)
        info->frame_duration = dxvk_be32(t->stts.p + 12);
    if (info->timescale && info->frame_duration)
        info->frame_rate = (double)info->timescale / (double)info->frame_duration;
}

/* Builds per-sample offsets and sizes from stsz, stsc and stco / co64. */
static dxvk_status build_samples(dxvk_mov *mov, const track_tables *t, uint64_t file_size)
{
    uint32_t uniform, count, chunks, runs;
    size_t entry_bytes = t->co64 ? 8u : 4u;
    uint32_t sample = 0;

    if (t->stsz.n < 12 || t->stsc.n < 8 || t->stco.n < 8)
        return DXVK_ERR_MOV_CORRUPT;
    uniform = dxvk_be32(t->stsz.p + 4);
    count = dxvk_be32(t->stsz.p + 8);
    if (count == 0 || count > MAX_SAMPLES)
        return DXVK_ERR_MOV_CORRUPT;
    if (uniform == 0 && (t->stsz.n - 12) / 4u < count)
        return DXVK_ERR_MOV_CORRUPT;
    if (uniform != 0 && (uint64_t)uniform * count > file_size)
        return DXVK_ERR_MOV_CORRUPT;
    runs = dxvk_be32(t->stsc.p + 4);
    if (runs == 0 || (t->stsc.n - 8) / 12u < runs)
        return DXVK_ERR_MOV_CORRUPT;
    chunks = dxvk_be32(t->stco.p + 4);
    if (chunks == 0 || (t->stco.n - 8) / entry_bytes < chunks)
        return DXVK_ERR_MOV_CORRUPT;

    mov->offsets = (uint64_t *)malloc((size_t)count * sizeof *mov->offsets);
    mov->sizes = (uint32_t *)malloc((size_t)count * sizeof *mov->sizes);
    if (!mov->offsets || !mov->sizes)
        return DXVK_ERR_OUT_OF_MEMORY;
    for (uint32_t i = 0; i < count; i++)
        mov->sizes[i] = uniform ? uniform : dxvk_be32(t->stsz.p + 12 + 4u * (size_t)i);

    for (uint32_t r = 0; r < runs && sample < count; r++) {
        const uint8_t *e = t->stsc.p + 8 + 12u * (size_t)r;
        uint32_t first = dxvk_be32(e), per_chunk = dxvk_be32(e + 4);
        uint32_t last = r + 1 < runs ? dxvk_be32(e + 12) : chunks + 1u; /* exclusive */
        if (first == 0 || (r == 0 && first != 1) || last <= first || last > chunks + 1u ||
            per_chunk == 0)
            return DXVK_ERR_MOV_CORRUPT;
        for (uint32_t c = first; c < last && sample < count; c++) {
            const uint8_t *o = t->stco.p + 8 + entry_bytes * (size_t)(c - 1u);
            uint64_t off = t->co64 ? dxvk_be64(o) : dxvk_be32(o);
            for (uint32_t k = 0; k < per_chunk && sample < count; k++, sample++) {
                uint32_t sz = mov->sizes[sample];
                if (off > file_size || sz > file_size - off)
                    return DXVK_ERR_MOV_CORRUPT;
                mov->offsets[sample] = off;
                off += sz;
                if (sz > mov->info.max_packet_size)
                    mov->info.max_packet_size = sz;
            }
        }
    }
    if (sample != count)
        return DXVK_ERR_MOV_CORRUPT;
    mov->info.frame_count = count;
    return DXVK_OK;
}

static int printable_type(const uint8_t *p)
{
    for (int i = 0; i < 4; i++)
        if (p[i] < 0x20 || p[i] > 0x7E)
            return 0;
    return 1;
}

static dxvk_status parse_file(dxvk_mov *mov)
{
    const dxvk_reader *rd = &mov->reader;
    uint64_t pos = 0, moov_size = 0, moov_pos = 0;
    uint8_t h[16];
    uint8_t *moov;
    span moov_span, trak;
    size_t it = 0;
    uint32_t type;
    int found = 0, r;
    dxvk_status st = DXVK_ERR_NO_DXV_TRACK;

    /* top level: find moov */
    while (pos + 8 <= rd->size) {
        uint64_t size;
        size_t header = 8;
        if (rd->read_at(rd->user, pos, h, 8) != 8)
            return DXVK_ERR_IO;
        if (pos == 0 && !printable_type(h + 4))
            return DXVK_ERR_NOT_MOV;
        size = dxvk_be32(h);
        type = dxvk_be32(h + 4);
        if (size == 1) {
            if (pos + 16 > rd->size || rd->read_at(rd->user, pos + 8, h + 8, 8) != 8)
                return DXVK_ERR_NOT_MOV;
            size = dxvk_be64(h + 8);
            header = 16;
        } else if (size == 0) {
            size = rd->size - pos;
        }
        if (size < header || size > rd->size - pos)
            return pos == 0 ? DXVK_ERR_NOT_MOV : DXVK_ERR_MOV_CORRUPT;
        if (type == FOURCC('m', 'o', 'o', 'v')) {
            moov_pos = pos + header;
            moov_size = size - header;
            found = 1;
            break;
        }
        pos += size;
    }
    if (!found)
        return DXVK_ERR_NOT_MOV;
    if (moov_size > MAX_MOOV_BYTES)
        return DXVK_ERR_MOV_CORRUPT;
    moov = (uint8_t *)malloc(moov_size ? (size_t)moov_size : 1u);
    if (!moov)
        return DXVK_ERR_OUT_OF_MEMORY;
    if (rd->read_at(rd->user, moov_pos, moov, (size_t)moov_size) != (size_t)moov_size) {
        free(moov);
        return DXVK_ERR_IO;
    }
    moov_span.p = moov;
    moov_span.n = (size_t)moov_size;

    while ((r = next_atom(moov_span, &it, &type, &trak)) == 1) {
        track_tables t;
        int k;
        if (type != FOURCC('t', 'r', 'a', 'k'))
            continue;
        memset(&t, 0, sizeof t);
        k = read_track(trak, &t, &mov->info);
        if (k == 0)
            continue;
        if (k < 0) {
            st = (dxvk_status)-k;
            break;
        }
        read_timing(&t, &mov->info);
        st = build_samples(mov, &t, rd->size);
        if (st == DXVK_OK && (mov->info.width == 0 || mov->info.height == 0))
            st = DXVK_ERR_MOV_CORRUPT;
        break;
    }
    if (r < 0 && st == DXVK_ERR_NO_DXV_TRACK)
        st = DXVK_ERR_MOV_CORRUPT;
    free(moov);
    return st;
}

/* ---------------------------------------------------------------------------------------------- */
/* Public API                                                                                     */
/* ---------------------------------------------------------------------------------------------- */

dxvk_status dxvk_mov_open_reader(const dxvk_reader *reader, dxvk_mov **out)
{
    dxvk_mov *mov;
    dxvk_status st;
    if (!out || !reader || !reader->read_at) {
        if (reader && reader->close)
            reader->close(reader->user);
        return DXVK_ERR_ARGUMENT;
    }
    *out = NULL;
    mov = (dxvk_mov *)calloc(1, sizeof *mov);
    if (!mov) {
        if (reader->close)
            reader->close(reader->user);
        return DXVK_ERR_OUT_OF_MEMORY;
    }
    mov->reader = *reader;
    st = parse_file(mov);
    if (st != DXVK_OK) {
        dxvk_mov_close(mov);
        return st;
    }
    *out = mov;
    return DXVK_OK;
}

dxvk_status dxvk_mov_open_memory(const void *data, size_t size, dxvk_mov **out)
{
    dxvk_reader rd;
    memory_source *m;
    if (!out || (!data && size))
        return DXVK_ERR_ARGUMENT;
    m = (memory_source *)malloc(sizeof *m);
    if (!m)
        return DXVK_ERR_OUT_OF_MEMORY;
    m->data = (const uint8_t *)data;
    m->size = size;
    rd.read_at = memory_read_at;
    rd.size = size;
    rd.user = m;
    rd.close = memory_close;
    return dxvk_mov_open_reader(&rd, out);
}

dxvk_status dxvk_mov_open_file(const char *path, dxvk_mov **out)
{
    dxvk_reader rd;
    FILE *f;
    long long end;
    if (!out || !path)
        return DXVK_ERR_ARGUMENT;
    f = fopen(path, "rb");
    if (!f)
        return DXVK_ERR_IO;
#if defined(_WIN32)
    if (_fseeki64(f, 0, SEEK_END) != 0 || (end = _ftelli64(f)) < 0) {
#else
    if (fseeko(f, 0, SEEK_END) != 0 || (end = (long long)ftello(f)) < 0) {
#endif
        fclose(f);
        return DXVK_ERR_IO;
    }
    rd.read_at = file_read_at;
    rd.size = (uint64_t)end;
    rd.user = f;
    rd.close = file_close;
    return dxvk_mov_open_reader(&rd, out);
}

void dxvk_mov_close(dxvk_mov *mov)
{
    if (!mov)
        return;
    if (mov->reader.close)
        mov->reader.close(mov->reader.user);
    free(mov->offsets);
    free(mov->sizes);
    free(mov);
}

const dxvk_mov_info *dxvk_mov_get_info(const dxvk_mov *mov) { return mov ? &mov->info : NULL; }

dxvk_status dxvk_mov_packet_location(const dxvk_mov *mov, uint32_t index, uint64_t *offset,
                                     uint32_t *size)
{
    if (!mov)
        return DXVK_ERR_ARGUMENT;
    if (index >= mov->info.frame_count)
        return DXVK_ERR_RANGE;
    if (offset)
        *offset = mov->offsets[index];
    if (size)
        *size = mov->sizes[index];
    return DXVK_OK;
}

dxvk_status dxvk_mov_read_packet(dxvk_mov *mov, uint32_t index, void *buffer, size_t capacity,
                                 size_t *size)
{
    uint32_t n;
    if (!mov || (!buffer && capacity))
        return DXVK_ERR_ARGUMENT;
    if (index >= mov->info.frame_count)
        return DXVK_ERR_RANGE;
    n = mov->sizes[index];
    if (size)
        *size = n;
    if (capacity < n)
        return DXVK_ERR_BUFFER_TOO_SMALL;
    if (n && mov->reader.read_at(mov->reader.user, mov->offsets[index], buffer, n) != n)
        return DXVK_ERR_IO;
    return DXVK_OK;
}
