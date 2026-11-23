/* kea_ops_avx2.c: the FP32 ops with AVX2 + FMA. Every function carries a target attribute, so the file builds without
   -mavx2; the encoder uses this table only when the CPU has AVX2 and FMA. */
#include "kea_internal.h"
#if KEA_X86
#include <immintrin.h>
#include <math.h>
#include <string.h>

#define TGT KEA_AVX2

static inline int imin(int a, int b) { return a < b ? a : b; }
static _Thread_local float tls_bp[KEA_GEMM_KC * 16] __attribute__((aligned(64)));

/* C[6][16] (+)= A[6][kc] * Bp[kc][16], then *= scale[16]. ap: the 6 row pointers (A already offset to k0). */
TGT static inline void ukr(int kc, const float *const *ap, const float *b, float *c, int ldc, int accum,
                           const float *scale) {
    const float *a0 = ap[0], *a1 = ap[1], *a2 = ap[2], *a3 = ap[3], *a4 = ap[4], *a5 = ap[5];
    __m256 c00 = _mm256_setzero_ps(), c01 = c00, c10 = c00, c11 = c00, c20 = c00, c21 = c00, c30 = c00, c31 = c00,
           c40 = c00, c41 = c00, c50 = c00, c51 = c00;
    for (int k = 0; k < kc; k++) {
        __m256 b0 = _mm256_load_ps(b), b1 = _mm256_load_ps(b + 8), t;
        b += 16;
#define ROW(i)                                                                                                        \
    t = _mm256_broadcast_ss(a##i + k);                                                                                \
    c##i##0 = _mm256_fmadd_ps(t, b0, c##i##0);                                                                        \
    c##i##1 = _mm256_fmadd_ps(t, b1, c##i##1);
        ROW(0) ROW(1) ROW(2) ROW(3) ROW(4) ROW(5)
#undef ROW
    }
#define OUT(i)                                                                                                        \
    if (accum) {                                                                                                      \
        c##i##0 = _mm256_add_ps(c##i##0, _mm256_loadu_ps(c + i * ldc));                                               \
        c##i##1 = _mm256_add_ps(c##i##1, _mm256_loadu_ps(c + i * ldc + 8));                                           \
    }                                                                                                                 \
    if (scale) {                                                                                                      \
        c##i##0 = _mm256_mul_ps(c##i##0, s0);                                                                         \
        c##i##1 = _mm256_mul_ps(c##i##1, s1);                                                                         \
    }                                                                                                                 \
    _mm256_storeu_ps(c + i * ldc, c##i##0);                                                                           \
    _mm256_storeu_ps(c + i * ldc + 8, c##i##1);
    __m256 s0 = _mm256_setzero_ps(), s1 = s0;
    if (scale) { s0 = _mm256_loadu_ps(scale); s1 = _mm256_loadu_ps(scale + 8); }
    OUT(0) OUT(1) OUT(2) OUT(3) OUT(4) OUT(5)
#undef OUT
}

/* rows [m0,m1) of C[:, n0:n0+nr] (+)= A[:, k0:k0+kc] * Bp. */
TGT static void run_block(int kc, const float *A, int lda, int m0, int m1, const float *bp, float *C, int ldc, int n0,
                          int nr, int accum, const float *scale) {
    for (int i = m0; i < m1; i += 6) {
        int mr = imin(6, m1 - i);
        const float *ap[6];
        for (int r = 0; r < 6; r++) ap[r] = A + (size_t)(i + imin(r, mr - 1)) * lda;
        float *c = C + (size_t)i * ldc + n0;
        if (mr == 6 && nr == 16) {
            ukr(kc, ap, bp, c, ldc, accum, scale);
        } else {
            _Alignas(32) float tmp[6 * 16], sc[16];
            if (accum)
                for (int r = 0; r < mr; r++) memcpy(tmp + r * 16, c + (size_t)r * ldc, (size_t)nr * 4);
            if (scale) { memset(sc, 0, sizeof sc); memcpy(sc, scale, (size_t)nr * 4); }
            ukr(kc, ap, bp, tmp, 16, accum, scale ? sc : NULL);
            for (int r = 0; r < mr; r++) memcpy(c + (size_t)r * ldc, tmp + r * 16, (size_t)nr * 4);
        }
    }
}

TGT static void pack_dense(const float *B, int ldb, int transB, int k0, int kc, int n0, int nr, float *bp) {
    if (!transB) {
        if (nr == 16) {
            for (int k = 0; k < kc; k++) {
                const float *s = B + (size_t)(k0 + k) * ldb + n0;
                _mm256_store_ps(bp + k * 16, _mm256_loadu_ps(s));
                _mm256_store_ps(bp + k * 16 + 8, _mm256_loadu_ps(s + 8));
            }
        } else {
            for (int k = 0; k < kc; k++) {
                const float *s = B + (size_t)(k0 + k) * ldb + n0;
                for (int j = 0; j < 16; j++) bp[k * 16 + j] = j < nr ? s[j] : 0.f;
            }
        }
    } else {
        if (nr < 16) memset(bp, 0, (size_t)kc * 16 * 4);
        for (int j = 0; j < nr; j++) {
            const float *s = B + (size_t)(n0 + j) * ldb + k0;
            for (int k = 0; k < kc; k++) bp[k * 16 + j] = s[k];
        }
    }
}

TGT static void gemm_avx2(int m0, int m1, int n0, int n1, int K, const float *A, int lda, const float *B, int ldb,
                          int transB, float *C, int ldc, int accum) {
    float *bp = tls_bp;
    for (int pc = 0; pc < K; pc += KEA_GEMM_KC) {
        int kc = imin(KEA_GEMM_KC, K - pc), acc = accum || pc > 0;
        for (int ic = m0; ic < m1; ic += KEA_GEMM_MC) {
            int ie = imin(m1, ic + KEA_GEMM_MC);
            for (int n = n0; n < n1; n += 16) {
                int nr = imin(16, n1 - n);
                pack_dense(B, ldb, transB, pc, kc, n, nr, bp);
                run_block(kc, A + pc, lda, ic, ie, bp, C, ldc, n, nr, acc, NULL);
            }
        }
    }
}

/* ---- elementwise */

TGT static inline float hsum(__m256 v) {
    __m128 s = _mm_add_ps(_mm256_castps256_ps128(v), _mm256_extractf128_ps(v, 1));
    s = _mm_add_ps(s, _mm_movehl_ps(s, s));
    s = _mm_add_ss(s, _mm_movehdup_ps(s));
    return _mm_cvtss_f32(s);
}

TGT static inline float hmax(__m256 v) {
    __m128 s = _mm_max_ps(_mm256_castps256_ps128(v), _mm256_extractf128_ps(v, 1));
    s = _mm_max_ps(s, _mm_movehl_ps(s, s));
    s = _mm_max_ss(s, _mm_movehdup_ps(s));
    return _mm_cvtss_f32(s);
}

/* exp(x), Cephes-style polynomial, ~1 ulp on [-87, 88]. */
TGT static inline __m256 exp8(__m256 x) {
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

TGT static void glu_avx2(const float *g, float *out, int nrows) {
    const __m256 one = _mm256_set1_ps(1.f), zero = _mm256_setzero_ps();
    for (int r = 0; r < nrows; r++) {
        const float *gr = g + (size_t)r * 2 * KEA_DIM;
        float *o = out + (size_t)r * KEA_DIM;
        for (int c = 0; c < KEA_DIM; c += 8) {
            __m256 a = _mm256_loadu_ps(gr + c), bb = _mm256_loadu_ps(gr + KEA_DIM + c);
            _mm256_storeu_ps(o + c, _mm256_div_ps(a, _mm256_add_ps(one, exp8(_mm256_sub_ps(zero, bb)))));
        }
    }
}

TGT static void ln_rows_avx2(float *x, const float *y, float alpha, int r0, int r1, const float *g, const float *b,
                             float *h) {
    const __m256 va = _mm256_set1_ps(alpha);
    for (int r = r0; r < r1; r++) {
        float *xr = x + (size_t)r * KEA_DIM, *hr = h + (size_t)r * KEA_DIM;
        __m256 s0 = _mm256_setzero_ps(), s1 = s0;
        if (y) {
            const float *yr = y + (size_t)r * KEA_DIM;
            for (int i = 0; i < KEA_DIM; i += 16) {
                __m256 v0 = _mm256_fmadd_ps(va, _mm256_loadu_ps(yr + i), _mm256_loadu_ps(xr + i));
                __m256 v1 = _mm256_fmadd_ps(va, _mm256_loadu_ps(yr + i + 8), _mm256_loadu_ps(xr + i + 8));
                _mm256_storeu_ps(xr + i, v0);
                _mm256_storeu_ps(xr + i + 8, v1);
                s0 = _mm256_add_ps(s0, v0);
                s1 = _mm256_add_ps(s1, v1);
            }
        } else {
            for (int i = 0; i < KEA_DIM; i += 16) {
                s0 = _mm256_add_ps(s0, _mm256_loadu_ps(xr + i));
                s1 = _mm256_add_ps(s1, _mm256_loadu_ps(xr + i + 8));
            }
        }
        __m256 m = _mm256_set1_ps(hsum(_mm256_add_ps(s0, s1)) * (1.f / KEA_DIM));
        s0 = _mm256_setzero_ps();
        s1 = s0;
        for (int i = 0; i < KEA_DIM; i += 16) {
            __m256 d0 = _mm256_sub_ps(_mm256_loadu_ps(xr + i), m), d1 = _mm256_sub_ps(_mm256_loadu_ps(xr + i + 8), m);
            s0 = _mm256_fmadd_ps(d0, d0, s0);
            s1 = _mm256_fmadd_ps(d1, d1, s1);
        }
        __m256 rs = _mm256_set1_ps(1.f / sqrtf(hsum(_mm256_add_ps(s0, s1)) * (1.f / KEA_DIM) + 0x1.5p-17f));
        for (int i = 0; i < KEA_DIM; i += 8) {
            __m256 d = _mm256_mul_ps(_mm256_sub_ps(_mm256_loadu_ps(xr + i), m), rs);
            _mm256_storeu_ps(hr + i, _mm256_fmadd_ps(d, _mm256_loadu_ps(g + i), _mm256_loadu_ps(b + i)));
        }
    }
}

TGT static void softmax_avx2(float *S, const float *R, int T, int i0, int i1, float scale) {
    const __m256 vs = _mm256_set1_ps(scale);
    for (int i = i0; i < i1; i++) {
        float *s = S + (size_t)(i - i0) * (size_t)T;
        const float *r = R + (size_t)(i - i0) * (size_t)(2 * T - 1) + (T - 1 - i);
        int j = 0;
        __m256 mx8 = _mm256_set1_ps(-INFINITY);
        for (; j + 8 <= T; j += 8) {
            __m256 v = _mm256_mul_ps(_mm256_add_ps(_mm256_loadu_ps(s + j), _mm256_loadu_ps(r + j)), vs);
            _mm256_storeu_ps(s + j, v);
            mx8 = _mm256_max_ps(mx8, v);
        }
        float mx = hmax(mx8);
        for (; j < T; j++) {
            s[j] = (s[j] + r[j]) * scale;
            mx = s[j] > mx ? s[j] : mx;
        }
        __m256 vm = _mm256_set1_ps(mx), sum8 = _mm256_setzero_ps();
        for (j = 0; j + 8 <= T; j += 8) {
            __m256 v = exp8(_mm256_sub_ps(_mm256_loadu_ps(s + j), vm));
            _mm256_storeu_ps(s + j, v);
            sum8 = _mm256_add_ps(sum8, v);
        }
        float sum = hsum(sum8);
        for (; j < T; j++) {
            s[j] = expf(s[j] - mx);
            sum += s[j];
        }
        __m256 inv = _mm256_set1_ps(1.f / sum);
        for (j = 0; j + 8 <= T; j += 8) _mm256_storeu_ps(s + j, _mm256_mul_ps(_mm256_loadu_ps(s + j), inv));
        for (; j < T; j++) s[j] *= 1.f / sum;
    }
}

#define SFX(n) n##_avx2
#include "kea_ops.inc"
#undef SFX

const kea_ops kea_ops_avx2 = {gemm_avx2,  ln_rows_avx2, glu_avx2,    softmax_avx2,
                              conv0_avx2, dwsub_avx2,   dwconv_avx2, bias_act_avx2};
#endif
