/* kea_encoder.c: loading the weights and running the Kea-B' encoder graph.

   Graph (op for op the exported model): mel -> subsampling (conv 3x3/2 + ReLU, then twice depthwise 3x3/2 + pointwise
   + ReLU, then a 4096 -> 1024 linear) -> 24 layers of x += 0.5 FF1(LN x); x += MHSA(LN x); x += Conv(LN x);
   x += 0.5 FF2(LN x); x = LN x. Only the valid frames are computed.

   Work is split into parallel regions with as few barriers as the data dependencies allow: the per-row work that
   prepares a projection's input (residual add, LayerNorm, SiLU, GLU + depthwise conv, quantization and lookup tables)
   runs in the same region that produces that input row, and the projection itself is one region (split over output
   columns). Attention is split over query rows, so its output rows are quantized in the same region. */
#include "kea_internal.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Projection sites and the int8 quantization group of each one's input (32, 64 or 128). q, k and v share their input
   and must have the same group. This table is the only place to change it. */
enum { S_FF1A, S_FF1B, S_Q, S_K, S_V, S_O, S_PW1, S_PW2, S_FF2A, S_FF2B, S_COUNT };
static const struct {
    const char *name;
    int N, K, group;
} kea_sites[S_COUNT] = {
    {"feed_forward1_linear1", 4096, 1024, 64}, {"feed_forward1_linear2", 1024, 4096, 32},
    {"self_attn_linear_q", 1024, 1024, 64},    {"self_attn_linear_k", 1024, 1024, 64},
    {"self_attn_linear_v", 1024, 1024, 64},    {"self_attn_linear_out", 1024, 1024, 64},
    {"conv_pointwise_conv1", 2048, 1024, 64},  {"conv_pointwise_conv2", 1024, 1024, 32},
    {"feed_forward2_linear1", 4096, 1024, 64}, {"feed_forward2_linear2", 1024, 4096, 32},
};

typedef struct {
    float *ln_g[5], *ln_b[5]; /* ff1, self_att, conv, ff2, out */
    kea_int8_matrix *w[S_COUNT];
    float *u, *vb, *P, *dw9, *dwb;
} layer;

struct kea_encoder {
    kea_pool *pool;
    int threads, avx2;
    const kea_ops *ops;
    const uint8_t *blob;
    size_t blob_len;
    const char *index;
    size_t index_len;
    float *c0w, *c0b, *d1w, *d1b, *p1w, *p1b, *d2w, *d2b, *p2w, *p2b, *ow, *ob;
    layer L[KEA_LAYERS];
    float *s0, *s1a, *s1b, *s2a, *s2b;
    float *x, *h, *y, *q, *k, *v, *a, *big, *g, *cv;
    kea_qbuf q1, qa, qb; /* inputs of width 1024; two chunks of inputs of width 4096 */
    int chunk4096;
    float **tmp, **att, **glh; /* per thread */
    int att_rows;
};

/* ---------------------------------------------------------------- loading */

static int find(const kea_encoder *e, const char *name, size_t *off, size_t *len) {
    size_t nl = strlen(name);
    const char *p = e->index, *end = e->index + e->index_len;
    while (p < end) {
        const char *eol = memchr(p, '\n', (size_t)(end - p));
        if (!eol) eol = end;
        if ((size_t)(eol - p) > nl && !memcmp(p, name, nl) && p[nl] == ' ') {
            unsigned long long o, l;
            char line[128];
            size_t n = (size_t)(eol - p) < sizeof line - 1 ? (size_t)(eol - p) : sizeof line - 1;
            memcpy(line, p, n);
            line[n] = 0;
            if (sscanf(line + nl, " %llu %llu", &o, &l) == 2 && o + l <= e->blob_len && o + l >= o) {
                *off = (size_t)o;
                *len = (size_t)l;
                return 0;
            }
            return -1;
        }
        p = eol + 1;
    }
    return -1;
}

static float *getf(kea_encoder *e, const char *name, size_t count) {
    size_t off, len;
    if (find(e, name, &off, &len) || len != count * 2) return NULL;
    float *f = kea_aligned_alloc(count * sizeof(float));
    if (!f) return NULL;
    const uint8_t *p = e->blob + off;
    for (size_t j = 0; j < count; j++) f[j] = kea_half_to_float((uint16_t)(p[2 * j] | p[2 * j + 1] << 8));
    return f;
}

/* [C][1][taps] fp16 -> [tap][C] fp32 */
static float *get_taps(kea_encoder *e, const char *name, int C, int taps) {
    float *w = getf(e, name, (size_t)C * (size_t)taps);
    if (!w) return NULL;
    float *t = kea_aligned_alloc((size_t)C * (size_t)taps * sizeof(float));
    if (t)
        for (int c = 0; c < C; c++)
            for (int j = 0; j < taps; j++) t[(size_t)j * (size_t)C + (size_t)c] = w[(size_t)c * (size_t)taps + (size_t)j];
    free(w);
    return t;
}

static int get_site(kea_encoder *e, int li, int s, kea_int8_matrix **out) {
    char wn[96], sn[96];
    snprintf(wn, sizeof wn, "l%d_%s_weight", li, kea_sites[s].name);
    snprintf(sn, sizeof sn, "l%d_%s_scaled_y_0", li, kea_sites[s].name);
    size_t wo, wl, so, sl;
    int N = kea_sites[s].N, K = kea_sites[s].K;
    if (find(e, wn, &wo, &wl) || find(e, sn, &so, &sl) || wl != (size_t)N * (size_t)K / 8 || sl != (size_t)N * 2 ||
        (so & 1))
        return -1;
    uint16_t *scale = malloc((size_t)N * 2); /* copied: weight_bin need not be 2-byte aligned */
    if (!scale) return -1;
    memcpy(scale, e->blob + so, (size_t)N * 2);
    kea_bits b = {e->blob + wo, scale, N, K, kea_sites[s].group};
    *out = kea_int8_pack(&b);
    free(scale);
    return *out ? 0 : -1;
}

static float **per_thread(int n, size_t floats) {
    float **p = calloc((size_t)n, sizeof(float *));
    if (!p) return NULL;
    for (int i = 0; i < n; i++)
        if (!(p[i] = kea_aligned_alloc(floats * sizeof(float)))) return p; /* caught by the NULL check in kea_open */
    return p;
}

static int all_set(float **p, int n) {
    if (!p) return 0;
    for (int i = 0; i < n; i++)
        if (!p[i]) return 0;
    return 1;
}

kea_encoder *kea_open(const uint8_t *blob, size_t len, const char *index, size_t index_len, int threads) {
    if (kea_sites[S_Q].group != kea_sites[S_K].group || kea_sites[S_Q].group != kea_sites[S_V].group) return NULL;
    kea_encoder *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->threads = threads > 0 ? threads : 4;
    e->blob = blob;
    e->blob_len = len;
    e->index = index;
    e->index_len = index_len;
    e->avx2 = kea_int8_avx2();
    e->ops = &kea_ops_generic;
#if KEA_X86
    if (e->avx2) e->ops = &kea_ops_avx2;
#endif
    int ok = 1;
#define CHK(x)                                                                                                         \
    do {                                                                                                               \
        if (!(x)) ok = 0;                                                                                              \
    } while (0)
    CHK(e->c0w = get_taps(e, "sub_conv0_weight_0", 256, 9));
    CHK(e->c0b = getf(e, "sub_conv0_bias_0", 256));
    CHK(e->d1w = get_taps(e, "sub_dw1_weight_0", 256, 9));
    CHK(e->d1b = getf(e, "sub_dw1_bias_0", 256));
    CHK(e->p1w = getf(e, "sub_pw1_weight_0", 256 * 256));
    CHK(e->p1b = getf(e, "sub_pw1_bias_0", 256));
    CHK(e->d2w = get_taps(e, "sub_dw2_weight_0", 256, 9));
    CHK(e->d2b = getf(e, "sub_dw2_bias_0", 256));
    CHK(e->p2w = getf(e, "sub_pw2_weight_0", 256 * 256));
    CHK(e->p2b = getf(e, "sub_pw2_bias_0", 256));
    CHK(e->ob = getf(e, "sub_out_bias_0", 1024));
    float *ow = getf(e, "sub_out_weight_0", 1024 * 4096);
    CHK(ow);
    if (ow) { /* columns c*16+w -> w*256+c, to match the channel-last flatten */
        e->ow = kea_aligned_alloc(1024 * 4096 * sizeof(float));
        CHK(e->ow);
        if (e->ow)
            for (int n = 0; n < 1024; n++)
                for (int c = 0; c < 256; c++)
                    for (int w = 0; w < 16; w++)
                        e->ow[(size_t)n * 4096 + (size_t)(w * 256 + c)] = ow[(size_t)n * 4096 + (size_t)(c * 16 + w)];
        free(ow);
    }
    static const char *lnn[5] = {"feed_forward1", "self_att", "conv", "feed_forward2", "out"};
    for (int i = 0; i < KEA_LAYERS && ok; i++) {
        layer *L = &e->L[i];
        char nm[96];
        for (int j = 0; j < 5; j++) {
            snprintf(nm, sizeof nm, "l%d_norm_%s_gamma_0", i, lnn[j]);
            CHK(L->ln_g[j] = getf(e, nm, 1024));
            snprintf(nm, sizeof nm, "l%d_norm_%s_beta_0", i, lnn[j]);
            CHK(L->ln_b[j] = getf(e, nm, 1024));
        }
        snprintf(nm, sizeof nm, "add_%d_y_0", 3 * i);
        CHK(L->u = getf(e, nm, 1024));
        snprintf(nm, sizeof nm, "add_%d_y_0", 3 * i + 1);
        CHK(L->vb = getf(e, nm, 1024));
        snprintf(nm, sizeof nm, "l%d_bd_raw_y_0", i);
        CHK(L->P = getf(e, nm, 8 * 128 * 375));
        snprintf(nm, sizeof nm, "l%d_dw_weight_0", i);
        CHK(L->dw9 = get_taps(e, nm, 1024, 9));
        snprintf(nm, sizeof nm, "l%d_dw_bias_0", i);
        CHK(L->dwb = getf(e, nm, 1024));
        for (int s = 0; s < S_COUNT; s++) CHK(!get_site(e, i, s, &L->w[s]));
    }
    e->index = NULL; /* not kept */
    int T = KEA_MAX_T, L1 = (KEA_MAX_FRAMES - 1) / 2 + 1, L2 = (L1 - 1) / 2 + 1;
    size_t TD = (size_t)T * KEA_DIM * sizeof(float);
    if (ok) {
        CHK(e->s0 = kea_aligned_alloc((size_t)L1 * 64 * 256 * sizeof(float)));
        CHK(e->s1a = kea_aligned_alloc((size_t)L2 * 32 * 256 * sizeof(float)));
        CHK(e->s1b = kea_aligned_alloc((size_t)L2 * 32 * 256 * sizeof(float)));
        CHK(e->s2a = kea_aligned_alloc((size_t)T * 16 * 256 * sizeof(float)));
        CHK(e->s2b = kea_aligned_alloc((size_t)T * 16 * 256 * sizeof(float)));
        CHK(e->x = kea_aligned_alloc(TD));
        CHK(e->h = kea_aligned_alloc(TD));
        CHK(e->y = kea_aligned_alloc(TD));
        CHK(e->q = kea_aligned_alloc(TD));
        CHK(e->k = kea_aligned_alloc(TD));
        CHK(e->v = kea_aligned_alloc(TD));
        CHK(e->a = kea_aligned_alloc(TD));
        CHK(e->cv = kea_aligned_alloc(TD));
        CHK(e->big = kea_aligned_alloc(4 * TD));
        CHK(e->g = kea_aligned_alloc(2 * TD));
        e->chunk4096 = kea_int8_chunk_rows(4096);
        if (e->chunk4096 > T) e->chunk4096 = T;
        CHK(!kea_qbuf_init(&e->q1, T, 1024, e->avx2));
        CHK(!kea_qbuf_init(&e->qa, e->chunk4096, 4096, e->avx2));
        CHK(!kea_qbuf_init(&e->qb, e->chunk4096, 4096, e->avx2));
        CHK(e->pool = kea_pool_create(e->threads));
        if (e->pool) e->threads = kea_pool_threads(e->pool); /* the threads that actually started */
        e->att_rows = (T + e->threads - 1) / e->threads;
        int R = e->att_rows;
        CHK(all_set(e->tmp = per_thread(e->threads, 4096), e->threads));
        CHK(all_set(e->att = per_thread(e->threads, (size_t)R * (256 + (size_t)T + (size_t)(2 * T - 1))), e->threads));
        CHK(all_set(e->glh = per_thread(e->threads, (size_t)(R + 8) * KEA_DIM), e->threads));
    }
#undef CHK
    if (!ok) {
        kea_close(e);
        return NULL;
    }
    return e;
}

static void free_per_thread(float **p, int n) {
    if (!p) return;
    for (int i = 0; i < n; i++) free(p[i]);
    free(p);
}

void kea_close(kea_encoder *e) {
    if (!e) return;
    int nt = e->threads;
    kea_pool_destroy(e->pool);
    float **fs[] = {&e->c0w, &e->c0b, &e->d1w, &e->d1b, &e->p1w, &e->p1b, &e->d2w, &e->d2b, &e->p2w, &e->p2b,
                    &e->ow,  &e->ob,  &e->s0,  &e->s1a, &e->s1b, &e->s2a, &e->s2b, &e->x,   &e->h,   &e->y,
                    &e->q,   &e->k,   &e->v,   &e->a,   &e->cv,  &e->big, &e->g};
    for (size_t i = 0; i < sizeof fs / sizeof *fs; i++) free(*fs[i]);
    for (int i = 0; i < KEA_LAYERS; i++) {
        layer *L = &e->L[i];
        for (int j = 0; j < 5; j++) {
            free(L->ln_g[j]);
            free(L->ln_b[j]);
        }
        free(L->u);
        free(L->vb);
        free(L->P);
        free(L->dw9);
        free(L->dwb);
        for (int s = 0; s < S_COUNT; s++) kea_int8_free(L->w[s]);
    }
    kea_qbuf_free(&e->q1);
    kea_qbuf_free(&e->qa);
    kea_qbuf_free(&e->qb);
    free_per_thread(e->tmp, nt);
    free_per_thread(e->att, nt);
    free_per_thread(e->glh, nt);
    free(e);
}

/* ---------------------------------------------------------------- regions */

/* Quantizes rows r0..r1-1 of a projection input X (X points to row 0) for site s into qb (rows relative to row0, the
   first row of the chunk); act 1 applies SiLU first. */
static void prep(kea_encoder *e, int s, kea_qbuf *qb, const float *X, int ldx, int row0, int r0, int r1, int act,
                 int tid) {
    if (r0 < r1)
        kea_q_rows(qb, kea_sites[s].group, X + (size_t)r0 * (size_t)ldx, ldx, r0 - row0, r1 - row0, act, e->tmp[tid],
                   e->avx2);
}

/* This thread's share of the projections of sites s[0..n-1] (same input and N) for M rows starting at row0. */
static void project(kea_encoder *e, const layer *L, const int *s, int n, const kea_qbuf *qb, float *const *Y, int row0,
                    int M, int tid, int nt) {
    int N = kea_sites[s[0]].N;
    const kea_int8_matrix *w[3];
    float *yy[3];
    for (int i = 0; i < n; i++) {
        w[i] = L->w[s[i]];
        yy[i] = Y[i] + (size_t)row0 * (size_t)N;
    }
    kea_q_mm(w, yy, n, qb, M, N, tid, nt, e->avx2);
}

typedef struct {
    kea_encoder *e;
    const layer *L;
    int T;
    /* subsampling */
    const float *mel;
    int stride, L0, L1, L2;
    /* layernorm + prepare */
    const float *y;
    float alpha;
    const float *g1, *b1, *g2, *b2;
    float *dst1, *dst2;
    int site; /* -1: none */
    kea_qbuf *qb;
    /* projection */
    int sites[3], nsites, row0, rows;
    const kea_qbuf *pqb;
    float *Y[3];
    /* the next chunk prepared in the same region (ff down) */
    int nsite, nrow0, nrows;
    kea_qbuf *nqb;
} job;

static void t_conv0(void *c, int tid, int nt) {
    job *j = c;
    int a, b;
    kea_split(j->L1, tid, nt, &a, &b);
    if (a < b) j->e->ops->conv0(j->mel, j->stride, j->L0, j->e->c0w, j->e->c0b, j->e->s0, a, b);
}

static void t_dw1(void *c, int tid, int nt) {
    job *j = c;
    int a, b;
    kea_split(j->L2, tid, nt, &a, &b);
    if (a < b) j->e->ops->dwsub(j->e->s0, j->L1, 64, j->e->d1w, j->e->d1b, j->e->s1a, a, b);
}

static void pw_rows(kea_encoder *e, const float *in, const float *w, const float *bias, float *out, int rows, int tid,
                    int nt) {
    int a, b;
    kea_split((rows + 5) / 6, tid, nt, &a, &b);
    a *= 6;
    b = 6 * b < rows ? 6 * b : rows;
    if (a >= b) return;
    e->ops->gemm(a, b, 0, 256, 256, in, 256, w, 256, 1, out, 256, 0);
    e->ops->bias_act(out, 256, 256, bias, 1, a, b);
}

static void t_pw1(void *c, int tid, int nt) {
    job *j = c;
    pw_rows(j->e, j->e->s1a, j->e->p1w, j->e->p1b, j->e->s1b, j->L2 * 32, tid, nt);
}

static void t_dw2(void *c, int tid, int nt) {
    job *j = c;
    int a, b;
    kea_split(j->T, tid, nt, &a, &b);
    if (a < b) j->e->ops->dwsub(j->e->s1b, j->L2, 32, j->e->d2w, j->e->d2b, j->e->s2a, a, b);
}

static void t_pw2(void *c, int tid, int nt) {
    job *j = c;
    pw_rows(j->e, j->e->s2a, j->e->p2w, j->e->p2b, j->e->s2b, j->T * 16, tid, nt);
}

static void t_sub_out(void *c, int tid, int nt) {
    job *j = c;
    kea_encoder *e = j->e;
    int a, b;
    kea_split(KEA_DIM / 16, tid, nt, &a, &b);
    if (a >= b) return;
    e->ops->gemm(0, j->T, 16 * a, 16 * b, 4096, e->s2b, 4096, e->ow, 4096, 1, e->x, KEA_DIM, 0);
    e->ops->bias_act(e->x + 16 * a, KEA_DIM, 16 * (b - a), e->ob + 16 * a, 0, 0, j->T);
}

/* x (+)= alpha y; dst1 = LN1(x); optionally dst2 = LN2(dst1); prepare the last of them for site */
static void t_lnq(void *c, int tid, int nt) {
    job *j = c;
    kea_encoder *e = j->e;
    int a, b;
    kea_split(j->T, tid, nt, &a, &b);
    if (a >= b) return;
    e->ops->ln_rows(e->x, j->y, j->alpha, a, b, j->g1, j->b1, j->dst1);
    float *src = j->dst1;
    if (j->g2) {
        e->ops->ln_rows(j->dst1, NULL, 0.f, a, b, j->g2, j->b2, j->dst2);
        src = j->dst2;
    }
    if (j->site >= 0) prep(e, j->site, j->qb, src, KEA_DIM, 0, a, b, 0, tid);
}

/* projection of one chunk, plus the preparation of the next chunk's rows */
static void t_proj(void *c, int tid, int nt) {
    job *j = c;
    if (j->rows > 0) project(j->e, j->L, j->sites, j->nsites, j->pqb, j->Y, j->row0, j->rows, tid, nt);
    if (j->nrows > 0) {
        int a, b;
        kea_split(j->nrows, tid, nt, &a, &b);
        prep(j->e, j->nsite, j->nqb, j->e->big, 4096, j->nrow0, j->nrow0 + a, j->nrow0 + b, 1, tid);
    }
}

/* attention for this thread's query rows (all 8 heads), then preparation of those rows of a for the output proj */
static void t_attn(void *c, int tid, int nt) {
    job *j = c;
    kea_encoder *e = j->e;
    const kea_ops *o = e->ops;
    int T = j->T, i0, i1;
    kea_split(T, tid, nt, &i0, &i1);
    int nr = i1 - i0;
    if (nr <= 0) return;
    float *qu = e->att[tid], *qv = qu + (size_t)e->att_rows * 128, *S = qv + (size_t)e->att_rows * 128,
          *R = S + (size_t)e->att_rows * (size_t)T;
    const float scale = (float)(1.0 / sqrt(128.0));
    for (int hd = 0; hd < 8; hd++) {
        const float *u = j->L->u + hd * 128, *vb = j->L->vb + hd * 128;
        for (int i = i0; i < i1; i++) {
            const float *q = e->q + (size_t)i * KEA_DIM + hd * 128;
            for (int d = 0; d < 128; d++) {
                qu[(size_t)(i - i0) * 128 + (size_t)d] = q[d] + u[d];
                qv[(size_t)(i - i0) * 128 + (size_t)d] = q[d] + vb[d];
            }
        }
        o->gemm(0, nr, 0, T, 128, qu, 128, e->k + hd * 128, KEA_DIM, 1, S, T, 0);
        /* bd: row i needs columns [T-1-i, 2T-1-i) of qv P; per block of 24 rows only their union */
        const float *Ph = j->L->P + (size_t)hd * 128 * 375 + (KEA_MAX_T - T);
        for (int r0 = i0; r0 < i1; r0 += 24) {
            int r1 = r0 + 24 < i1 ? r0 + 24 : i1;
            o->gemm(r0 - i0, r1 - i0, T - r1, 2 * T - 1 - r0, 128, qv, 128, Ph, 375, 0, R, 2 * T - 1, 0);
        }
        o->softmax(S, R, T, i0, i1, scale);
        o->gemm(0, nr, 0, 128, T, S, T, e->v + hd * 128, KEA_DIM, 0, e->a + (size_t)i0 * KEA_DIM + hd * 128, KEA_DIM, 0);
    }
    prep(e, S_O, &e->q1, e->a, KEA_DIM, 0, i0, i1, 0, tid);
}

/* GLU (with a halo of 4 rows each side), depthwise conv, then SiLU + preparation for the second pointwise proj */
static void t_conv(void *c, int tid, int nt) {
    job *j = c;
    kea_encoder *e = j->e;
    int T = j->T, t0, t1;
    kea_split(T, tid, nt, &t0, &t1);
    if (t0 >= t1) return;
    int h0 = t0 - 4 > 0 ? t0 - 4 : 0, h1 = t1 + 4 < T ? t1 + 4 : T;
    e->ops->glu(e->g + (size_t)h0 * 2 * KEA_DIM, e->glh[tid], h1 - h0);
    e->ops->dwconv(e->glh[tid], h0, T, j->L->dw9, j->L->dwb, e->cv + (size_t)t0 * KEA_DIM, t0, t1);
    prep(e, S_PW2, &e->q1, e->cv, KEA_DIM, 0, t0, t1, 1, tid);
}

/* ---------------------------------------------------------------- the graph */

static void run_proj(kea_encoder *e, const layer *L, int s, float *Y, int T) {
    job j = {.e = e, .L = L, .T = T, .sites = {s}, .nsites = 1, .row0 = 0, .rows = T, .pqb = &e->q1, .Y = {Y},
             .nrows = 0};
    kea_pool_run(e->pool, t_proj, &j);
}

/* FF down projection from big (SiLU applied while quantizing), in chunks of rows pipelined so that each region
   projects one chunk and prepares the next. */
static void ff_down(kea_encoder *e, const layer *L, int s, int T) {
    int mc = e->chunk4096;
    kea_qbuf *buf[2] = {&e->qa, &e->qb};
    job p = {.e = e, .L = L, .T = T, .nsite = s, .nrow0 = 0, .nrows = mc < T ? mc : T, .nqb = buf[0]};
    kea_pool_run(e->pool, t_proj, &p);
    for (int c = 0, r0 = 0; r0 < T; c++, r0 += mc) {
        int n0 = r0 + mc;
        job j = {.e = e, .L = L, .T = T, .sites = {s}, .nsites = 1, .row0 = r0, .rows = T - r0 < mc ? T - r0 : mc,
                 .pqb = buf[c & 1], .Y = {e->y}, .nsite = s, .nrow0 = n0,
                 .nrows = n0 < T ? (T - n0 < mc ? T - n0 : mc) : 0, .nqb = buf[(c + 1) & 1]};
        kea_pool_run(e->pool, t_proj, &j);
    }
}

static void lnq(kea_encoder *e, int T, const float *y, float alpha, const float *g1, const float *b1, float *dst1,
                const float *g2, const float *b2, float *dst2, int site) {
    job j = {.e = e, .T = T, .y = y, .alpha = alpha, .g1 = g1, .b1 = b1, .dst1 = dst1, .g2 = g2, .b2 = b2,
             .dst2 = dst2, .site = site, .qb = &e->q1};
    kea_pool_run(e->pool, t_lnq, &j);
}

int kea_encode(kea_encoder *e, const float *mel, int stride, int L0, float *out, int *out_frames) {
    if (!e || !mel || !out || L0 < 1 || L0 > stride || L0 > KEA_MAX_FRAMES) return -1;
    int L1 = (L0 - 1) / 2 + 1, L2 = (L1 - 1) / 2 + 1, T = (L2 - 1) / 2 + 1;
    job sj = {.e = e, .T = T, .mel = mel, .stride = stride, .L0 = L0, .L1 = L1, .L2 = L2};
    kea_pool_run(e->pool, t_conv0, &sj);
    kea_pool_run(e->pool, t_dw1, &sj);
    kea_pool_run(e->pool, t_pw1, &sj);
    kea_pool_run(e->pool, t_dw2, &sj);
    kea_pool_run(e->pool, t_pw2, &sj);
    kea_pool_run(e->pool, t_sub_out, &sj);
    const layer *L0p = &e->L[0];
    lnq(e, T, NULL, 0.f, L0p->ln_g[0], L0p->ln_b[0], e->h, NULL, NULL, NULL, S_FF1A);
    for (int li = 0; li < KEA_LAYERS; li++) {
        const layer *L = &e->L[li];
        /* x += 0.5 FF1(LN x) */
        run_proj(e, L, S_FF1A, e->big, T);
        ff_down(e, L, S_FF1B, T);
        lnq(e, T, e->y, 0.5f, L->ln_g[1], L->ln_b[1], e->h, NULL, NULL, NULL, S_Q);
        /* x += MHSA(LN x) */
        job qkv = {.e = e, .L = L, .T = T, .sites = {S_Q, S_K, S_V}, .nsites = 3, .row0 = 0, .rows = T,
                   .pqb = &e->q1, .Y = {e->q, e->k, e->v}};
        kea_pool_run(e->pool, t_proj, &qkv);
        job at = {.e = e, .L = L, .T = T};
        kea_pool_run(e->pool, t_attn, &at);
        run_proj(e, L, S_O, e->y, T);
        lnq(e, T, e->y, 1.f, L->ln_g[2], L->ln_b[2], e->h, NULL, NULL, NULL, S_PW1);
        /* x += Conv(LN x) */
        run_proj(e, L, S_PW1, e->g, T);
        job cj = {.e = e, .L = L, .T = T};
        kea_pool_run(e->pool, t_conv, &cj);
        run_proj(e, L, S_PW2, e->y, T);
        lnq(e, T, e->y, 1.f, L->ln_g[3], L->ln_b[3], e->h, NULL, NULL, NULL, S_FF2A);
        /* x += 0.5 FF2(LN x); x = LN x; and the next layer's first LayerNorm */
        run_proj(e, L, S_FF2A, e->big, T);
        ff_down(e, L, S_FF2B, T);
        if (li + 1 < KEA_LAYERS)
            lnq(e, T, e->y, 0.5f, L->ln_g[4], L->ln_b[4], e->x, e->L[li + 1].ln_g[0], e->L[li + 1].ln_b[0], e->h,
                S_FF1A);
        else
            lnq(e, T, e->y, 0.5f, L->ln_g[4], L->ln_b[4], out, NULL, NULL, NULL, -1);
    }
    *out_frames = T;
    return 0;
}

#ifdef KEA_STATS
unsigned long kea_encoder_regions(const kea_encoder *e) { return kea_pool_regions(e->pool); }
#endif
