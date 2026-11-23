/* kea_ops.c: shared helpers and the portable FP32 ops (plain C the compiler vectorizes). */
#include "kea_internal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static inline int imin(int a, int b) { return a < b ? a : b; }

void *kea_aligned_alloc(size_t bytes) {
    void *p = NULL;
    if (posix_memalign(&p, 64, bytes ? (bytes + 63) & ~(size_t)63 : 64)) return NULL;
    return p;
}

float kea_half_to_float(uint16_t h) {
    uint32_t s = (uint32_t)(h & 0x8000u) << 16, e = (h >> 10) & 0x1fu, m = h & 0x3ffu, f;
    if (e == 0) {
        float v = ldexpf((float)m, -24);
        return s ? -v : v;
    }
    f = e == 31 ? (s | 0x7f800000u | (m << 13)) : (s | ((e + 112) << 23) | (m << 13));
    float r;
    memcpy(&r, &f, 4);
    return r;
}

/* ---- GEMM: 6 x 16 tiles over packed 16-column panels of B */

static void ukr_gen(int kc, const float *const *ap, const float *b, float *c, int ldc, int accum, const float *scale,
                    int mr, int nr) {
    float acc[6][16];
    memset(acc, 0, sizeof acc);
    for (int k = 0; k < kc; k++) {
        const float *bk = b + k * 16;
        for (int i = 0; i < 6; i++) {
            float a = ap[i][k];
            for (int j = 0; j < 16; j++) acc[i][j] += a * bk[j];
        }
    }
    for (int i = 0; i < mr; i++)
        for (int j = 0; j < nr; j++) {
            float v = acc[i][j];
            if (accum) v += c[(size_t)i * (size_t)ldc + (size_t)j];
            if (scale) v *= scale[j];
            c[(size_t)i * (size_t)ldc + (size_t)j] = v;
        }
}

static void block_gen(int kc, const float *A, int lda, int m0, int m1, const float *bp, float *C, int ldc, int n0,
                      int nr, int accum, const float *scale) {
    for (int i = m0; i < m1; i += 6) {
        int mr = imin(6, m1 - i);
        const float *ap[6];
        for (int r = 0; r < 6; r++) ap[r] = A + (size_t)(i + imin(r, mr - 1)) * (size_t)lda;
        ukr_gen(kc, ap, bp, C + (size_t)i * (size_t)ldc + (size_t)n0, ldc, accum, scale, mr, nr);
    }
}

static _Thread_local float tls_bp_gen[KEA_GEMM_KC * 16] __attribute__((aligned(64)));

static void gemm_gen(int m0, int m1, int n0, int n1, int K, const float *A, int lda, const float *B, int ldb,
                     int transB, float *C, int ldc, int accum) {
    float *bp = tls_bp_gen;
    for (int pc = 0; pc < K; pc += KEA_GEMM_KC) {
        int kc = imin(KEA_GEMM_KC, K - pc), acc = accum || pc > 0;
        for (int ic = m0; ic < m1; ic += KEA_GEMM_MC) {
            int ie = imin(m1, ic + KEA_GEMM_MC);
            for (int n = n0; n < n1; n += 16) {
                int nr = imin(16, n1 - n);
                for (int k = 0; k < kc; k++)
                    for (int j = 0; j < 16; j++)
                        bp[k * 16 + j] = j >= nr ? 0.f
                                         : transB ? B[(size_t)(n + j) * (size_t)ldb + (size_t)(pc + k)]
                                                  : B[(size_t)(pc + k) * (size_t)ldb + (size_t)(n + j)];
                block_gen(kc, A + pc, lda, ic, ie, bp, C, ldc, n, nr, acc, NULL);
            }
        }
    }
}

/* ---- elementwise */

static void ln_rows_gen(float *x, const float *y, float alpha, int r0, int r1, const float *g, const float *b,
                        float *h) {
    for (int r = r0; r < r1; r++) {
        float *xr = x + (size_t)r * KEA_DIM, *hr = h + (size_t)r * KEA_DIM;
        if (y)
            for (int i = 0; i < KEA_DIM; i++) xr[i] += alpha * y[(size_t)r * KEA_DIM + (size_t)i];
        float s = 0;
        for (int i = 0; i < KEA_DIM; i++) s += xr[i];
        float m = s / KEA_DIM, v = 0;
        for (int i = 0; i < KEA_DIM; i++) v += (xr[i] - m) * (xr[i] - m);
        float rs = 1.f / sqrtf(v / KEA_DIM + 0x1.5p-17f);
        for (int i = 0; i < KEA_DIM; i++) hr[i] = (xr[i] - m) * rs * g[i] + b[i];
    }
}

static void glu_gen(const float *g, float *out, int nrows) {
    for (int r = 0; r < nrows; r++) {
        const float *gr = g + (size_t)r * 2 * KEA_DIM;
        for (int c = 0; c < KEA_DIM; c++) out[(size_t)r * KEA_DIM + (size_t)c] = gr[c] / (1.f + expf(-gr[KEA_DIM + c]));
    }
}

static void softmax_gen(float *S, const float *R, int T, int i0, int i1, float scale) {
    for (int i = i0; i < i1; i++) {
        float *s = S + (size_t)(i - i0) * (size_t)T;
        const float *r = R + (size_t)(i - i0) * (size_t)(2 * T - 1) + (T - 1 - i);
        float mx = -INFINITY;
        for (int j = 0; j < T; j++) {
            s[j] = (s[j] + r[j]) * scale;
            mx = s[j] > mx ? s[j] : mx;
        }
        float sum = 0;
        for (int j = 0; j < T; j++) {
            s[j] = expf(s[j] - mx);
            sum += s[j];
        }
        float inv = 1.f / sum;
        for (int j = 0; j < T; j++) s[j] *= inv;
    }
}

#define SFX(n) n##_gen
#define TGT
#include "kea_ops.inc"
#undef SFX
#undef TGT

const kea_ops kea_ops_generic = {gemm_gen,  ln_rows_gen, glu_gen,     softmax_gen,
                                 conv0_gen, dwsub_gen,   dwconv_gen, bias_act_gen};
