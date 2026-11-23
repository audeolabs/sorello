/* kea_int8.c: projections with 1-bit weights and int8 activations (the arithmetic is stated in kea.h).

   AVX2 path, chosen at run time from CPUID: for each group of 4 activations a 16-entry table T[e] = sum_j +-q_j
   (exact, in [-508, 508]) is split into two byte planes, lo = T & 15 and hi' = (T >> 4) + 32 in [0, 63]. A step covers
   8 inputs (two sets of 4, A and B) for 32 weight rows: the 16-byte table of A (or B) is broadcast to both 128-bit
   lanes and one vpshufb looks it up for rows 0-15 (lane 0) and 16-31 (lane 1), the weight nibbles being the indices.
   Per step and token: 4 table broadcasts (loads), 4 vpshufb, 4 vpaddb for 256 multiply-adds. Byte sums: lo for up to
   8 steps (<= 240), hi' for 2 (<= 252); they are widened with vpmaddubsw against constant byte pairs into int16 sums
   of 16 hi' + lo for the even and odd rows, which start at -1024 * GS (GS = steps per group: 4, 8 or 16) to cancel
   the +32 offset, so at the end of a group they hold the exact dot products (|d| <= 508 * 2 * GS); vpmaddwd splits
   them into int32 per row and each group is scaled into FP32. Tiles are 3 tokens x 32 rows.

   Portable path: the same quantization and integer dot products in plain C. */
#include "kea_internal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#if KEA_X86
#include <immintrin.h>
#define I8INLINE static inline __attribute__((always_inline)) KEA_AVX2
#endif

#define I8_MR 3                 /* tokens per tile */
#define I8_TABLE_BUDGET 3145728 /* bytes of tables per chunk of rows */

struct kea_int8_matrix {
    int N, K, Np, S, group;
    float *ws;  /* [Np + 16] */
    uint8_t *P; /* [Np / 32][S][32]: byte s of the 32 rows of each block */
};

int kea_int8_matrix_k(const kea_int8_matrix *w) { return w->K; }

int kea_int8_avx2(void) {
#if KEA_X86
    static int v = -1; /* the same for the whole process */
    if (v < 0) v = __builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma");
    return v;
#else
    return 0;
#endif
}

int kea_int8_uses_avx2(void) { return kea_int8_avx2(); }

kea_int8_matrix *kea_int8_pack(const kea_bits *W) {
    int N = W->N, K = W->K, G = W->group;
    if (N < 1 || K < 64 || K > 4096 || (G != 32 && G != 64 && G != 128) || K % G || K % 64) return NULL;
    kea_int8_matrix *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->N = N;
    p->K = K;
    p->Np = (N + 31) / 32 * 32;
    p->S = K / 8;
    p->group = G;
    p->ws = kea_aligned_alloc(sizeof(float) * (size_t)(p->Np + 32));
    p->P = kea_aligned_alloc((size_t)p->Np * (size_t)p->S);
    if (!p->ws || !p->P) {
        kea_int8_free(p);
        return NULL;
    }
    for (int n = 0; n < p->Np + 32; n++) p->ws[n] = n < N ? kea_half_to_float(W->scale_f16[n]) : 0.f;
    for (int n = 0; n < p->Np; n++)
        for (int s = 0; s < p->S; s++)
            p->P[((size_t)(n / 32) * (size_t)p->S + (size_t)s) * 32 + (size_t)(n % 32)] =
                n < N ? W->bits[(size_t)n * (size_t)(K / 8) + (size_t)s] : 0;
    return p;
}

void kea_int8_free(kea_int8_matrix *p) {
    if (!p) return;
    free(p->ws);
    free(p->P);
    free(p);
}

int kea_int8_chunk_rows(int K) {
    int mc = (int)(I8_TABLE_BUDGET / ((size_t)K * 8));
    mc -= mc % (2 * I8_MR);
    return mc < 2 * I8_MR ? 2 * I8_MR : mc;
}

int kea_qbuf_init(kea_qbuf *b, int cap, int K, int avx2) {
    memset(b, 0, sizeof *b);
    b->cap = cap;
    b->K = K;
    b->q = kea_aligned_alloc((size_t)cap * (size_t)K);
    b->gs = kea_aligned_alloc((size_t)cap * (size_t)(K / 32) * sizeof(float));
    b->tab = avx2 ? kea_aligned_alloc((size_t)cap * (size_t)K * 8) : NULL;
    return b->q && b->gs && (b->tab || !avx2) ? 0 : -1;
}

void kea_qbuf_free(kea_qbuf *b) {
    free(b->q);
    free(b->gs);
    free(b->tab);
    memset(b, 0, sizeof *b);
}

/* ---------------------------------------------------------------- portable path */

static float quant_span_c(const float *x, int n, int8_t *q) {
    float amax = 0;
    for (int k = 0; k < n; k++) {
        float a = fabsf(x[k]);
        amax = a > amax ? a : amax;
    }
    if (!(amax > 0)) {
        memset(q, 0, (size_t)n);
        return 0;
    }
    float inv = 127.0f / amax;
    for (int k = 0; k < n; k++) {
        float r = rintf(x[k] * inv);
        q[k] = (int8_t)(r > 127.f ? 127.f : r < -127.f ? -127.f : r);
    }
    return amax / 127.0f;
}

static void q_rows_c(kea_qbuf *b, int G, const float *X, int ldx, int r0, int r1, int act, float *tmp) {
    int K = b->K, gstride = K / 32;
    for (int r = r0; r < r1; r++) {
        const float *x = X + (size_t)(r - r0) * (size_t)ldx;
        if (act) {
            for (int k = 0; k < K; k++) tmp[k] = x[k] / (1.f + expf(-x[k]));
            x = tmp;
        }
        for (int g = 0; g < K / G; g++)
            b->gs[(size_t)r * (size_t)gstride + (size_t)g] = quant_span_c(x + g * G, G, b->q + (size_t)r * (size_t)K + g * G);
    }
}

static void mm_rows_c(const kea_int8_matrix *w, float *Y, const kea_qbuf *b, int G, int M, int ldy, int n0, int n1) {
    int K = w->K, ng = K / G, gstride = K / 32;
    int8_t sign[4096];
    for (int n = n0; n < n1; n++) {
        const uint8_t *P = w->P + (size_t)(n / 32) * (size_t)w->S * 32 + (size_t)(n % 32);
        for (int k = 0; k < K; k++) sign[k] = (P[(size_t)(k >> 3) * 32] >> (k & 7) & 1) ? 1 : -1;
        for (int m = 0; m < M; m++) {
            const int8_t *q = b->q + (size_t)m * (size_t)K;
            const float *gs = b->gs + (size_t)m * (size_t)gstride;
            float y = 0;
            for (int g = 0; g < ng; g++) {
                int32_t d = 0;
                for (int k = g * G; k < (g + 1) * G; k++) d += q[k] * sign[k];
                y += gs[g] * (float)d;
            }
            Y[(size_t)m * (size_t)ldy + (size_t)n] = y * w->ws[n];
        }
    }
}

/* ---------------------------------------------------------------- AVX2 path */
#if KEA_X86
I8INLINE float hmax8(__m256 v) {
    __m128 a = _mm_max_ps(_mm256_castps256_ps128(v), _mm256_extractf128_ps(v, 1));
    a = _mm_max_ps(a, _mm_movehl_ps(a, a));
    a = _mm_max_ss(a, _mm_shuffle_ps(a, a, 1));
    return _mm_cvtss_f32(a);
}

/* exp(x), Cephes-style polynomial, ~1 ulp on [-87, 88] */
I8INLINE __m256 exp8(__m256 x) {
    x = _mm256_min_ps(_mm256_max_ps(x, _mm256_set1_ps(-87.3f)), _mm256_set1_ps(88.3f));
    __m256 n = _mm256_round_ps(_mm256_mul_ps(x, _mm256_set1_ps(1.44269504088896341f)),
                               _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
    __m256 r = _mm256_fnmadd_ps(n, _mm256_set1_ps(0.693359375f), x);
    r = _mm256_fnmadd_ps(n, _mm256_set1_ps(-2.12194440e-4f), r);
    __m256 p = _mm256_set1_ps(1.9875691500E-4f);
    p = _mm256_fmadd_ps(p, r, _mm256_set1_ps(1.3981999507E-3f));
    p = _mm256_fmadd_ps(p, r, _mm256_set1_ps(8.3334519073E-3f));
    p = _mm256_fmadd_ps(p, r, _mm256_set1_ps(4.1665795894E-2f));
    p = _mm256_fmadd_ps(p, r, _mm256_set1_ps(1.6666665459E-1f));
    p = _mm256_fmadd_ps(p, r, _mm256_set1_ps(5.0000001201E-1f));
    p = _mm256_fmadd_ps(p, _mm256_mul_ps(r, r), _mm256_add_ps(r, _mm256_set1_ps(1.f)));
    __m256i e = _mm256_slli_epi32(_mm256_add_epi32(_mm256_cvtps_epi32(n), _mm256_set1_epi32(127)), 23);
    return _mm256_mul_ps(p, _mm256_castsi256_ps(e));
}

/* same arithmetic as quant_span_c; n % 32 == 0 */
I8INLINE float quant_span_avx2(const float *x, int n, int8_t *q) {
    const __m256 absmask = _mm256_castsi256_ps(_mm256_set1_epi32(0x7fffffff));
    __m256 mx = _mm256_setzero_ps();
    for (int k = 0; k < n; k += 8) mx = _mm256_max_ps(mx, _mm256_and_ps(_mm256_loadu_ps(x + k), absmask));
    float amax = hmax8(mx);
    if (!(amax > 0.0f)) {
        memset(q, 0, (size_t)n);
        return 0;
    }
    const __m256 vinv = _mm256_set1_ps(127.0f / amax);
    const __m256i perm = _mm256_setr_epi32(0, 4, 1, 5, 2, 6, 3, 7);
    const __m256i lim = _mm256_set1_epi8(127), nlim = _mm256_set1_epi8(-127);
    for (int k = 0; k < n; k += 32) {
        __m256i a = _mm256_cvtps_epi32(_mm256_mul_ps(_mm256_loadu_ps(x + k), vinv));
        __m256i b = _mm256_cvtps_epi32(_mm256_mul_ps(_mm256_loadu_ps(x + k + 8), vinv));
        __m256i c = _mm256_cvtps_epi32(_mm256_mul_ps(_mm256_loadu_ps(x + k + 16), vinv));
        __m256i d = _mm256_cvtps_epi32(_mm256_mul_ps(_mm256_loadu_ps(x + k + 24), vinv));
        __m256i v = _mm256_permutevar8x32_epi32(
            _mm256_packs_epi16(_mm256_packs_epi32(a, b), _mm256_packs_epi32(c, d)), perm);
        _mm256_storeu_si256((__m256i *)(void *)(q + k), _mm256_max_epi8(_mm256_min_epi8(v, lim), nlim));
    }
    return amax / 127.0f;
}

/* Tables for one row: [K / 8][lo 32 | hi' 32]; lane 0 = the 4 inputs at 8s, lane 1 = those at 8s + 4. */
KEA_AVX2 static void build_tables(const int8_t *q, int K, uint8_t *tab) {
    const __m256i ctrl = _mm256_setr_epi8(0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 4, 5, 6, 7, 4, 5, 6, 7, 4, 5,
                                          6, 7, 4, 5, 6, 7);
    __m256i B[4];
    for (int k = 0; k < 4; k++) {
        uint8_t b[32];
        for (int L = 0; L < 2; L++)
            for (int d = 0; d < 4; d++)
                for (int j = 0; j < 4; j++) b[L * 16 + d * 4 + j] = (uint8_t)(((4 * k + d) >> j) & 1);
        B[k] = _mm256_loadu_si256((const __m256i *)(const void *)b);
    }
    const __m256i ones16 = _mm256_set1_epi16(1), m15 = _mm256_set1_epi32(15), off32 = _mm256_set1_epi32(32);
    for (int s = 0; s < K / 8; s++) {
        int64_t q8;
        memcpy(&q8, q + 8 * s, 8);
        __m256i qs = _mm256_shuffle_epi8(_mm256_set1_epi64x(q8), ctrl);
        __m256i T[4], h[4], l[4];
        for (int k = 0; k < 4; k++) T[k] = _mm256_madd_epi16(_mm256_maddubs_epi16(B[k], qs), ones16);
        __m256i sum = _mm256_shuffle_epi32(T[3], 0xff); /* entry 15 = sum of the 4 */
        for (int k = 0; k < 4; k++) {
            T[k] = _mm256_sub_epi32(_mm256_slli_epi32(T[k], 1), sum);
            h[k] = _mm256_add_epi32(_mm256_srai_epi32(T[k], 4), off32);
            l[k] = _mm256_and_si256(T[k], m15);
        }
        _mm256_store_si256((__m256i *)(void *)(tab + (size_t)s * 64),
                           _mm256_packs_epi16(_mm256_packs_epi32(l[0], l[1]), _mm256_packs_epi32(l[2], l[3])));
        _mm256_store_si256((__m256i *)(void *)(tab + (size_t)s * 64 + 32),
                           _mm256_packs_epi16(_mm256_packs_epi32(h[0], h[1]), _mm256_packs_epi32(h[2], h[3])));
    }
}

KEA_AVX2 static void q_rows_avx2(kea_qbuf *b, int G, const float *X, int ldx, int r0, int r1, int act, float *tmp) {
    int K = b->K, gstride = K / 32;
    const __m256 one = _mm256_set1_ps(1.f), zero = _mm256_setzero_ps();
    for (int r = r0; r < r1; r++) {
        const float *x = X + (size_t)(r - r0) * (size_t)ldx;
        if (act) {
            for (int k = 0; k < K; k += 8) {
                __m256 v = _mm256_loadu_ps(x + k);
                _mm256_store_ps(tmp + k, _mm256_div_ps(v, _mm256_add_ps(one, exp8(_mm256_sub_ps(zero, v)))));
            }
            x = tmp;
        }
        int8_t *q = b->q + (size_t)r * (size_t)K;
        for (int g = 0; g < K / G; g++) b->gs[(size_t)r * (size_t)gstride + (size_t)g] = quant_span_avx2(x + g * G, G, q + g * G);
        build_tables(q, K, b->tab + (size_t)r * (size_t)K * 8);
    }
}

/* rows 4j (lane 0: of rows 0-15, lane 1: of rows 16-31) etc.: f0 rows 4j, f1 rows 4j+2, f2 rows 4j+1, f3 rows 4j+3 */
I8INLINE void store32(__m256 f0, __m256 f1, __m256 f2, __m256 f3, const float *ws, int nvalid, float *y) {
    for (int L = 0; L < 2; L++) {
        __m128 r0 = L ? _mm256_extractf128_ps(f0, 1) : _mm256_castps256_ps128(f0);
        __m128 r1 = L ? _mm256_extractf128_ps(f2, 1) : _mm256_castps256_ps128(f2);
        __m128 r2 = L ? _mm256_extractf128_ps(f1, 1) : _mm256_castps256_ps128(f1);
        __m128 r3 = L ? _mm256_extractf128_ps(f3, 1) : _mm256_castps256_ps128(f3);
        _MM_TRANSPOSE4_PS(r0, r1, r2, r3); /* r_j = rows 16L + 4j .. 16L + 4j + 3 */
        __m128 r[4] = {r0, r1, r2, r3};
        for (int j = 0; j < 4; j++) {
            int n = 16 * L + 4 * j;
            if (n >= nvalid) return;
            __m128 o = _mm_mul_ps(r[j], _mm_loadu_ps(ws + n));
            if (nvalid >= n + 4) _mm_storeu_ps(y + n, o);
            else _mm_maskstore_ps(y + n, _mm_cmpgt_epi32(_mm_set1_epi32(nvalid - n), _mm_setr_epi32(0, 1, 2, 3)), o);
        }
    }
}

static const int8_t i8_c16e[32] __attribute__((aligned(32))) = {16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0,
                                                                16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0};
static const int8_t i8_c16o[32] __attribute__((aligned(32))) = {0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16,
                                                                0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16};
static const int8_t i8_c1e[32] __attribute__((aligned(32))) = {1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0,
                                                               1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0};
static const int8_t i8_c1o[32] __attribute__((aligned(32))) = {0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
                                                               0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1};
static const int16_t i8_w1e[16] __attribute__((aligned(32))) = {1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0};
static const int16_t i8_w1o[16] __attribute__((aligned(32))) = {0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1};
#define I8C(a) _mm256_load_si256((const __m256i *)(const void *)(a))
#define I8B(a) _mm256_broadcastsi128_si256(_mm_load_si128((const __m128i *)(const void *)(a)))

/* MR tokens x 32 rows; GS = steps of 8 inputs per group (4, 8 or 16). facc: [MR][32] FP32 accumulators, kept in memory
   so the integer accumulators keep the registers. */
I8INLINE void lut_tile(const int MR, const int GS, const uint8_t *tab, size_t tstride, const uint8_t *P, int S,
                       const float *gs, int gstride, const float *ws, int nvalid, float *y, int ldy, float *facc) {
    const int LO = GS < 8 ? GS : 8;
    const __m256i m15 = _mm256_set1_epi8(15);
    for (int i = 0; i < MR * 32; i += 8) _mm256_store_ps(facc + i, _mm256_setzero_ps());
    for (int c0 = 0; c0 < S; c0 += GS) {
        __m256i ae[I8_MR], ao[I8_MR];
        for (int i = 0; i < MR; i++) ae[i] = ao[i] = _mm256_set1_epi16((short)(-1024 * GS));
        for (int l0 = c0; l0 < c0 + GS; l0 += LO) {
            __m256i lo[I8_MR];
            for (int i = 0; i < MR; i++) lo[i] = _mm256_setzero_si256();
            for (int h0 = l0; h0 < l0 + LO; h0 += 2) {
                __m256i hi[I8_MR];
                for (int i = 0; i < MR; i++) hi[i] = _mm256_setzero_si256();
#pragma GCC unroll 2
                for (int s = h0; s < h0 + 2; s++) {
                    __m256i v = I8C(P + (size_t)s * 32);
                    __m256i ia = _mm256_and_si256(v, m15), ib = _mm256_and_si256(_mm256_srli_epi16(v, 4), m15);
                    for (int i = 0; i < MR; i++) {
                        const uint8_t *t = tab + (size_t)i * tstride + (size_t)s * 64;
                        lo[i] = _mm256_add_epi8(lo[i], _mm256_shuffle_epi8(I8B(t), ia));
                        hi[i] = _mm256_add_epi8(hi[i], _mm256_shuffle_epi8(I8B(t + 32), ia));
                        lo[i] = _mm256_add_epi8(lo[i], _mm256_shuffle_epi8(I8B(t + 16), ib));
                        hi[i] = _mm256_add_epi8(hi[i], _mm256_shuffle_epi8(I8B(t + 48), ib));
                    }
                }
                for (int i = 0; i < MR; i++) {
                    ae[i] = _mm256_add_epi16(ae[i], _mm256_maddubs_epi16(hi[i], I8C(i8_c16e)));
                    ao[i] = _mm256_add_epi16(ao[i], _mm256_maddubs_epi16(hi[i], I8C(i8_c16o)));
                }
            }
            for (int i = 0; i < MR; i++) {
                ae[i] = _mm256_add_epi16(ae[i], _mm256_maddubs_epi16(lo[i], I8C(i8_c1e)));
                ao[i] = _mm256_add_epi16(ao[i], _mm256_maddubs_epi16(lo[i], I8C(i8_c1o)));
            }
        }
        for (int i = 0; i < MR; i++) {
            __m256 sc = _mm256_broadcast_ss(gs + (size_t)i * (size_t)gstride + (size_t)(c0 / GS));
            float *f = facc + i * 32;
            __m256i v[4] = {_mm256_madd_epi16(ae[i], I8C(i8_w1e)), _mm256_madd_epi16(ae[i], I8C(i8_w1o)),
                            _mm256_madd_epi16(ao[i], I8C(i8_w1e)), _mm256_madd_epi16(ao[i], I8C(i8_w1o))};
            for (int u = 0; u < 4; u++)
                _mm256_store_ps(f + 8 * u, _mm256_fmadd_ps(_mm256_cvtepi32_ps(v[u]), sc, _mm256_load_ps(f + 8 * u)));
        }
    }
    for (int i = 0; i < MR; i++) {
        const float *f = facc + i * 32;
        store32(_mm256_load_ps(f), _mm256_load_ps(f + 8), _mm256_load_ps(f + 16), _mm256_load_ps(f + 24), ws, nvalid,
                y + (size_t)i * (size_t)ldy);
    }
}

KEA_AVX2 static void tile(int mr, int GS, const uint8_t *tab, size_t ts, const uint8_t *P, int S, const float *gs,
                          int gstride, const float *ws, int nvalid, float *y, int ldy, float *facc) {
#define TILE(m, g) lut_tile(m, g, tab, ts, P, S, gs, gstride, ws, nvalid, y, ldy, facc)
    if (GS == 4) {
        if (mr >= 3) TILE(3, 4);
        else if (mr == 2) TILE(2, 4);
        else TILE(1, 4);
    } else if (GS == 8) {
        if (mr >= 3) TILE(3, 8);
        else if (mr == 2) TILE(2, 8);
        else TILE(1, 8);
    } else {
        if (mr >= 3) TILE(3, 16);
        else if (mr == 2) TILE(2, 16);
        else TILE(1, 16);
    }
#undef TILE
}

static void mm_blocks_avx2(const kea_int8_matrix *w, float *Y, const kea_qbuf *b, int G, int M, int ldy, int b0,
                           int b1) {
    float facc[I8_MR * 32] __attribute__((aligned(32)));
    size_t ts = (size_t)w->K * 8;
    int gstride = w->K / 32;
    for (int m0 = 0; m0 < M; m0 += I8_MR) {
        int mr = M - m0 < I8_MR ? M - m0 : I8_MR;
        for (int bk = b0; bk < b1; bk++)
            tile(mr, G / 8, b->tab + (size_t)m0 * ts, ts, w->P + (size_t)bk * (size_t)w->S * 32, w->S,
                 b->gs + (size_t)m0 * (size_t)gstride, gstride, w->ws + 32 * bk, w->N - 32 * bk,
                 Y + (size_t)m0 * (size_t)ldy + 32 * (size_t)bk, ldy, facc);
    }
}
#endif

/* ---------------------------------------------------------------- phases and the test entry points */

void kea_q_rows(kea_qbuf *b, int G, const float *X, int ldx, int r0, int r1, int act, float *tmp, int avx2) {
    b->G = G;
    b->ng = b->K / G;
#if KEA_X86
    if (avx2) {
        q_rows_avx2(b, G, X, ldx, r0, r1, act, tmp);
        return;
    }
#endif
    (void)avx2;
    q_rows_c(b, G, X, ldx, r0, r1, act, tmp);
}

/* The nw matrices' 32-row blocks (or rows, on the portable path) are concatenated and split evenly over threads. */
void kea_q_mm(const kea_int8_matrix *const *w, float *const *Y, int nw, const kea_qbuf *b, int M, int ldy, int tid,
              int nt, int avx2) {
    int total = 0;
    for (int i = 0; i < nw; i++) total += avx2 ? w[i]->Np / 32 : w[i]->N;
    int a, z;
    kea_split(total, tid, nt, &a, &z);
    int base = 0;
    for (int i = 0; i < nw; i++) {
        int cnt = avx2 ? w[i]->Np / 32 : w[i]->N;
        int lo = a > base ? a - base : 0, hi = z - base < cnt ? z - base : cnt;
        if (lo < hi) {
#if KEA_X86
            if (avx2) mm_blocks_avx2(w[i], Y[i], b, w[i]->group, M, ldy, lo, hi);
            else
#endif
                mm_rows_c(w[i], Y[i], b, w[i]->group, M, ldy, lo, hi);
        }
        base += cnt;
    }
}

typedef struct {
    const float *X;
    int ldx, ldy, M, avx2;
    const kea_int8_matrix *w;
    float *Y;
    kea_qbuf *b;
    float *tmp;
} proj_job;

static void proj_prep_task(void *c, int tid, int nt) {
    proj_job *j = c;
    int r0, r1;
    kea_split(j->M, tid, nt, &r0, &r1);
    if (r0 < r1)
        kea_q_rows(j->b, j->w->group, j->X + (size_t)r0 * (size_t)j->ldx, j->ldx, r0, r1, 0, NULL, j->avx2);
}

static void proj_mm_task(void *c, int tid, int nt) {
    proj_job *j = c;
    kea_q_mm(&j->w, &j->Y, 1, j->b, j->M, j->ldy, tid, nt, j->avx2);
}

static void proj_run(const float *X, int M, int ldx, const kea_int8_matrix *w, float *Y, int ldy, kea_pool *pool,
                     int avx2) {
    if (!w || !pool || M < 1) return;
    int K = w->K, mc = avx2 ? kea_int8_chunk_rows(K) : M;
    if (mc > M) mc = M;
    if (mc < 1) return;
    kea_qbuf b = {mc, K, w->group, K / w->group, NULL, NULL, NULL};
    b.q = kea_pool_scratch(pool, 0, (size_t)mc * (size_t)K);
    b.gs = kea_pool_scratch(pool, 1, (size_t)mc * (size_t)(K / 32) * sizeof(float));
    if (avx2) b.tab = kea_pool_scratch(pool, 2, (size_t)mc * (size_t)K * 8);
    if (!b.q || !b.gs || (avx2 && !b.tab)) return;
    for (int m0 = 0; m0 < M; m0 += mc) {
        proj_job j = {X + (size_t)m0 * (size_t)ldx, ldx, ldy, M - m0 < mc ? M - m0 : mc, avx2, w,
                      Y + (size_t)m0 * (size_t)ldy, &b, NULL};
        kea_pool_run(pool, proj_prep_task, &j);
        kea_pool_run(pool, proj_mm_task, &j);
    }
}

void kea_int8_proj(const float *X, int M, int ldx, const kea_int8_matrix *w, float *Y, int ldy, kea_pool *pool) {
    proj_run(X, M, ldx, w, Y, ldy, pool, kea_int8_avx2());
}

void kea_int8_proj_portable(const float *X, int M, int ldx, const kea_int8_matrix *w, float *Y, int ldy,
                            kea_pool *pool) {
    proj_run(X, M, ldx, w, Y, ldy, pool, 0);
}
