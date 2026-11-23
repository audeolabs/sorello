/* kea_decoder.c: the TDT decoder step with int8 per-row weights. Each matrix product is
 * y[n] = s[n] * sum_k q[n][k] * x[k] (+ bias[n]) in FP32 ([W_ih1 | W_hh1] has a scale per half-row), the int8 values widened to float in registers. An AVX2+FMA
 * path is chosen at open when the CPU has it; the portable C path serves every other machine, and the two differ only
 * by summation order and FMA rounding. Single-threaded; no global state. */
#include "kea_decoder.h"
#include "kea_decoder_path.h"

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
#define KEA_X86 1
#endif

/* Products and sums are rounded one by one, as written (the portable path, the cell), whatever the compiler's default. */
#pragma STDC FP_CONTRACT OFF

enum { H = 640, G = 4 * H, VOCAB = 1025, OUTPUTS = 1030 };

/* int8 q[rows][cols] with one FP32 scale per row and part: the row's columns split into `parts` equal parts of `width`
 * (a multiple of 16) columns, so [W_ih1 | W_hh1] keeps a scale per original matrix row. */
typedef struct {
    int8_t *q; /* [rows][cols] */
    float *s;  /* [rows][parts] */
    int rows, cols, parts, width;
} qmatrix;

struct kea_decoder {
    float *table0; /* [VOCAB][G], FP32 */
    qmatrix whh0, w1cat, pred, out;
    float *bias1, *predB, *outB;
    float *gates; /* [G] scratch */
    float *z;     /* [H] scratch */
    int path;
};

static void *alloc64(size_t bytes) {
    size_t rounded = (bytes + 63) & ~(size_t)63;
    return aligned_alloc(64, rounded ? rounded : 64);
}

static float *copy_floats(const float *source, size_t count) {
    float *p = alloc64(count * sizeof(float));
    if (p) memcpy(p, source, count * sizeof(float));
    return p;
}

/* Round half to even of a value with |v| well below 2^23, independent of the rounding mode. */
static float round_half_even(float v) {
    float a = fabsf(v), r = floorf(a), d = a - r; /* exact for a >= 0 */
    if (d > 0.5f || (d == 0.5f && fmodf(r, 2.0f) != 0.0f)) r += 1.0f;
    return v < 0 ? -r : r;
}

static int quantize(qmatrix *m, const float *w, int rows, int cols, int parts) {
    m->rows = rows;
    m->cols = cols;
    m->parts = parts;
    m->width = cols / parts;
    m->q = alloc64((size_t)rows * cols);
    m->s = alloc64((size_t)rows * parts * sizeof(float));
    if (!m->q || !m->s) return 0;
    for (int n = 0; n < rows; n++)
        for (int p = 0; p < parts; p++) {
            const float *row = w + (size_t)n * cols + (size_t)p * m->width;
            float peak = 0;
            for (int k = 0; k < m->width; k++) peak = fmaxf(peak, fabsf(row[k]));
            float s = peak > 0 ? peak / 127.0f : 1.0f;
            m->s[n * parts + p] = s;
            int8_t *q = m->q + (size_t)n * cols + (size_t)p * m->width;
            for (int k = 0; k < m->width; k++) {
                float r = round_half_even(row[k] / s);
                q[k] = (int8_t)(r > 127.0f ? 127.0f : r < -127.0f ? -127.0f : r);
            }
        }
    return 1;
}

/* y[n] = bias[n] + (s[n][0] * part0 + s[n][1] * part1 ...), each part a dot product of `width` terms. */
static float combine(const qmatrix *m, int n, const float *sums, const float *bias) {
    float v = m->s[n * m->parts] * sums[0];
    for (int p = 1; p < m->parts; p++) v += m->s[n * m->parts + p] * sums[p];
    return bias ? bias[n] + v : v;
}

/* Clang may reorder this sum into vector lanes (4 lanes x 4 interleaved = 16 running sums, as the AVX2 path keeps);
 * without the hint it does not widen int8 to float in vectors and the loop runs scalar. */
#if defined(__clang__)
#define KEA_VECTOR_SUM _Pragma("clang loop vectorize(enable) interleave_count(4)")
#else
#define KEA_VECTOR_SUM
#endif

static float dot_portable(const int8_t *q, const float *x, int n) {
    float sum = 0;
    KEA_VECTOR_SUM
    for (int k = 0; k < n; k++) sum += (float)q[k] * x[k];
    return sum;
}

/* Portable: any C compiler, any CPU. */
static void gemv_portable(const qmatrix *m, const float *x, const float *bias, float *y) {
    for (int n = 0; n < m->rows; n++) {
        float sums[2];
        for (int p = 0; p < m->parts; p++)
            sums[p] = dot_portable(m->q + (size_t)n * m->cols + (size_t)p * m->width, x + (size_t)p * m->width, m->width);
        y[n] = combine(m, n, sums, bias);
    }
}

#ifdef KEA_X86
__attribute__((target("avx2,fma"))) static inline __m256 widen8(const int8_t *p) {
    return _mm256_cvtepi32_ps(_mm256_cvtepi8_epi32(_mm_loadl_epi64((const __m128i *)p)));
}

__attribute__((target("avx2,fma"))) static inline float fold(__m256 a, __m256 b) {
    __m256 t = _mm256_add_ps(a, b);
    __m128 u = _mm_add_ps(_mm256_castps256_ps128(t), _mm256_extractf128_ps(t, 1));
    __m128 v = _mm_add_ps(u, _mm_movehl_ps(u, u));
    return _mm_cvtss_f32(_mm_add_ss(v, _mm_movehdup_ps(v)));
}

/* Four rows at a time, two accumulators each (eight independent FMA chains); x is read once per four rows. Rows
 * come in multiples of four for every matrix here except W_out (1030), whose last two rows take the single-row loop. */
__attribute__((target("avx2,fma"))) static void gemv_avx2(const qmatrix *m, const float *x, const float *bias,
                                                         float *y) {
    const int cols = m->cols, width = m->width;
    int n = 0;
    for (; n + 4 <= m->rows; n += 4) {
        float sums[4][2];
        for (int p = 0; p < m->parts; p++) {
            const int8_t *q0 = m->q + (size_t)n * cols + (size_t)p * width, *q1 = q0 + cols, *q2 = q1 + cols,
                         *q3 = q2 + cols;
            const float *xp = x + (size_t)p * width;
            __m256 a0 = _mm256_setzero_ps(), b0 = a0, a1 = a0, b1 = a0, a2 = a0, b2 = a0, a3 = a0, b3 = a0;
            /* The block of four rows is contiguous and each step uses 64 of its bytes: fetch the same line of the
             * block two blocks ahead (no fault past the end: prefetches never fault). */
            const char *ahead = (const char *)(m->q + (size_t)(n + 8) * cols) + (size_t)p * width * 4;
            for (int k = 0; k < width; k += 16) {
                _mm_prefetch(ahead + 4 * k, _MM_HINT_T0);
                __m256 x0 = _mm256_loadu_ps(xp + k), x1 = _mm256_loadu_ps(xp + k + 8);
                a0 = _mm256_fmadd_ps(widen8(q0 + k), x0, a0);
                b0 = _mm256_fmadd_ps(widen8(q0 + k + 8), x1, b0);
                a1 = _mm256_fmadd_ps(widen8(q1 + k), x0, a1);
                b1 = _mm256_fmadd_ps(widen8(q1 + k + 8), x1, b1);
                a2 = _mm256_fmadd_ps(widen8(q2 + k), x0, a2);
                b2 = _mm256_fmadd_ps(widen8(q2 + k + 8), x1, b2);
                a3 = _mm256_fmadd_ps(widen8(q3 + k), x0, a3);
                b3 = _mm256_fmadd_ps(widen8(q3 + k + 8), x1, b3);
            }
            sums[0][p] = fold(a0, b0);
            sums[1][p] = fold(a1, b1);
            sums[2][p] = fold(a2, b2);
            sums[3][p] = fold(a3, b3);
        }
        for (int r = 0; r < 4; r++) y[n + r] = combine(m, n + r, sums[r], bias);
    }
    for (; n < m->rows; n++) {
        float sums[2];
        for (int p = 0; p < m->parts; p++) {
            const int8_t *q = m->q + (size_t)n * cols + (size_t)p * width;
            const float *xp = x + (size_t)p * width;
            __m256 a = _mm256_setzero_ps(), b = a;
            for (int k = 0; k < width; k += 16) {
                a = _mm256_fmadd_ps(widen8(q + k), _mm256_loadu_ps(xp + k), a);
                b = _mm256_fmadd_ps(widen8(q + k + 8), _mm256_loadu_ps(xp + k + 8), b);
            }
            sums[p] = fold(a, b);
        }
        y[n] = combine(m, n, sums, bias);
    }
}

static int cpu_has_avx2_fma(void) {
    __builtin_cpu_init();
    return __builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma");
}
#else
static int cpu_has_avx2_fma(void) { return 0; }
#endif

/* y = W x (+ bias), bias may be NULL. */
static void gemv(const kea_decoder *d, const qmatrix *m, const float *x, const float *bias, float *y) {
#ifdef KEA_X86
    if (d->path == KEA_PATH_AVX2) {
        gemv_avx2(m, x, bias, y);
        return;
    }
#else
    (void)d;
#endif
    gemv_portable(m, x, bias, y);
}

static float sigmoid(float x) { return 1.0f / (1.0f + expf(-x)); }

/* One LSTM cell update in place (PyTorch gate order i, f, g, o), as NativeMath.cell. */
static void cell(const float *gates, float *h, float *c) {
    for (int k = 0; k < H; k++) {
        float i = sigmoid(gates[k]), f = sigmoid(gates[H + k]);
        float g = tanhf(gates[2 * H + k]), o = sigmoid(gates[3 * H + k]);
        float cn = f * c[k] + i * g;
        c[k] = cn;
        h[k] = o * tanhf(cn);
    }
}

kea_decoder *kea_decoder_open(const float *table0, const float *whh0, const float *w1cat, const float *bias1,
                              const float *predW, const float *predB, const float *outW, const float *outB) {
    if (!table0 || !whh0 || !w1cat || !bias1 || !predW || !predB || !outW || !outB) return NULL;
    kea_decoder *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->table0 = copy_floats(table0, (size_t)VOCAB * G);
    d->bias1 = copy_floats(bias1, G);
    d->predB = copy_floats(predB, H);
    d->outB = copy_floats(outB, OUTPUTS);
    d->gates = alloc64(G * sizeof(float));
    d->z = alloc64(H * sizeof(float));
    int ok = d->table0 && d->bias1 && d->predB && d->outB && d->gates && d->z;
    ok = ok && quantize(&d->whh0, whh0, G, H, 1);
    ok = ok && quantize(&d->w1cat, w1cat, G, 2 * H, 2);
    ok = ok && quantize(&d->pred, predW, H, H, 1);
    ok = ok && quantize(&d->out, outW, OUTPUTS, H, 1);
    if (!ok) {
        kea_decoder_close(d);
        return NULL;
    }
    d->path = cpu_has_avx2_fma() ? KEA_PATH_AVX2 : KEA_PATH_PORTABLE;
    return d;
}

void kea_decoder_predict(kea_decoder *d, int token, float *h, float *c, float *g) {
    float *gates = d->gates;
    /* Layer 0: gates = table0[token] + W_hh0 h0. */
    gemv(d, &d->whh0, h, d->table0 + (size_t)token * G, gates);
    cell(gates, h, c);
    /* Layer 1: gates = [W_ih1 | W_hh1] [h0'; h1] + bias1; h holds [h0'; h1] contiguously. */
    gemv(d, &d->w1cat, h, d->bias1, gates);
    cell(gates, h + H, c + H);
    /* g = W_pred h_top + b_pred. */
    gemv(d, &d->pred, h + H, d->predB, g);
}

void kea_decoder_joint(kea_decoder *d, const float *f, const float *g, float *logits) {
    float *z = d->z;
    for (int k = 0; k < H; k++) {
        float v = f[k] + g[k];
        z[k] = v > 0 ? v : 0;
    }
    gemv(d, &d->out, z, d->outB, logits);
}

static void free_matrix(qmatrix *m) {
    free(m->q);
    free(m->s);
}

void kea_decoder_close(kea_decoder *d) {
    if (!d) return;
    free(d->table0);
    free(d->bias1);
    free(d->predB);
    free(d->outB);
    free(d->gates);
    free(d->z);
    free_matrix(&d->whh0);
    free_matrix(&d->w1cat);
    free_matrix(&d->pred);
    free_matrix(&d->out);
    free(d);
}

int kea_decoder_use_path(kea_decoder *d, int path) {
    if (path == KEA_PATH_PORTABLE) d->path = KEA_PATH_PORTABLE;
    else if (path == KEA_PATH_AVX2 && cpu_has_avx2_fma()) d->path = KEA_PATH_AVX2;
    return d->path;
}

int kea_decoder_regions(const kea_decoder *d, const void **base, unsigned long *bytes, int max) {
    const void *b[] = {d->table0, d->bias1, d->predB, d->outB, d->gates, d->z, d->whh0.q, d->whh0.s, d->w1cat.q,
                       d->w1cat.s, d->pred.q, d->pred.s, d->out.q, d->out.s};
    const qmatrix *m[] = {&d->whh0, &d->w1cat, &d->pred, &d->out};
    unsigned long n[14] = {(unsigned long)VOCAB * G * 4, G * 4, H * 4, OUTPUTS * 4, G * 4, H * 4};
    for (int i = 0; i < 4; i++) {
        n[6 + 2 * i] = (unsigned long)m[i]->rows * m[i]->cols;
        n[7 + 2 * i] = (unsigned long)m[i]->rows * m[i]->parts * 4;
    }
    for (int i = 0; i < 14 && i < max; i++) base[i] = b[i], bytes[i] = n[i];
    return 14;
}
