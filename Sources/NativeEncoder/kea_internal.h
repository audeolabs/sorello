/* kea_internal.h: declarations shared by the encoder's source files (not part of the public interface). */
#ifndef KEA_INTERNAL_H
#define KEA_INTERNAL_H
#include "kea.h"

#define KEA_LAYERS 24
#define KEA_GEMM_KC 128 /* FP32 GEMM blocking */
#define KEA_GEMM_MC 192

#if defined(__x86_64__)
#define KEA_X86 1
#define KEA_AVX2 __attribute__((target("avx2,fma")))
#else
#define KEA_X86 0
#endif

void *kea_aligned_alloc(size_t bytes); /* 64-byte aligned, free() it */
float kea_half_to_float(uint16_t h);

/* ---- thread pool */
typedef void (*kea_task_fn)(void *ctx, int tid, int nthreads);
void kea_pool_run(kea_pool *pool, kea_task_fn fn, void *ctx); /* fn on every thread (tid 0 = caller), then returns */
int kea_pool_threads(const kea_pool *pool);
void *kea_pool_scratch(kea_pool *pool, int slot, size_t bytes); /* caller thread only, outside kea_pool_run */
#ifdef KEA_STATS
unsigned long kea_pool_regions(const kea_pool *pool);
#endif

static inline void kea_split(int n, int tid, int nt, int *a, int *b) {
    *a = (int)((long)n * tid / nt);
    *b = (int)((long)n * (tid + 1) / nt);
}

/* ---- int8 projections, in two phases so the encoder can fuse them with other per-row work.
   A kea_qbuf holds the quantized rows of one projection input (and, on the AVX2 path, their lookup tables). */
typedef struct {
    int cap, K, G, ng;
    int8_t *q;    /* [cap][K] */
    float *gs;    /* [cap][K / 32] group scales */
    uint8_t *tab; /* [cap][K * 8] (AVX2 path only) */
} kea_qbuf;

int kea_int8_avx2(void); /* chosen once from CPUID */
int kea_qbuf_init(kea_qbuf *b, int cap, int K, int avx2);
void kea_qbuf_free(kea_qbuf *b);
/* Rows per table chunk for inputs of width K (tables stay within a few MB, a multiple of the tile height). */
int kea_int8_chunk_rows(int K);
/* Quantizes rows r0..r1-1 into b (rows of b relative to the chunk); X points to row r0. act 1: SiLU first.
   tmp: K floats of per-thread scratch. G: group size. */
void kea_q_rows(kea_qbuf *b, int G, const float *X, int ldx, int r0, int r1, int act, float *tmp, int avx2);
/* This thread's share of the output columns of nw matrices (same K) for the M rows held in b. */
void kea_q_mm(const kea_int8_matrix *const *w, float *const *Y, int nw, const kea_qbuf *b, int M, int ldy, int tid,
              int nt, int avx2);
int kea_int8_matrix_k(const kea_int8_matrix *w);

/* ---- FP32 ops (one table per ISA) */
typedef struct {
    /* C[m][n] (+)= sum_k A[m*lda+k] * B(k, n), m in [m0,m1), n in [n0,n1); B(k,n) = transB ? B[n*ldb+k] : B[k*ldb+n] */
    void (*gemm)(int m0, int m1, int n0, int n1, int K, const float *A, int lda, const float *B, int ldb, int transB,
                 float *C, int ldc, int accum);
    /* rows [r0,r1) of [*][1024]: if y, x += alpha * y; h = LayerNorm(x) * g + b (h may be x) */
    void (*ln_rows)(float *x, const float *y, float alpha, int r0, int r1, const float *g, const float *b, float *h);
    void (*glu)(const float *g, float *out, int nrows); /* g [n][2048] -> out [n][1024] */
    /* rows i0..i1-1 of softmax_j((S[i][j] + R[i][j + T - 1 - i]) * scale); S, R point to row i0, ld T and 2T - 1 */
    void (*softmax)(float *S, const float *R, int T, int i0, int i1, float scale);
    /* conv 3x3/2 pad 1, 1 -> 256 ch, + bias, ReLU, reading mel [128][stride] (F valid frames); out [L1][64][256] */
    void (*conv0)(const float *mel, int stride, int F, const float *w9, const float *b, float *out, int i0, int i1);
    /* depthwise 3x3/2 pad 1 over [H][W][256] -> [Ho][Wo][256], + bias */
    void (*dwsub)(const float *in, int H, int W, const float *w9, const float *b, float *out, int i0, int i1);
    /* depthwise conv over time, k 9 pad 4, + bias: g holds rows gbase.. of [T][1024], out holds rows t0..t1-1 */
    void (*dwconv)(const float *g, int gbase, int T, const float *w9, const float *b, float *out, int t0, int t1);
    void (*bias_act)(float *x, int ld, int n, const float *b, int relu, int r0, int r1);
} kea_ops;

extern const kea_ops kea_ops_generic;
#if KEA_X86
extern const kea_ops kea_ops_avx2;
#endif

#endif
