/* kea.h: public interface of the Kea-B' speech encoder on the CPU.

   The encoder is a 24-layer FastConformer whose 240 projections have 1-bit weights (+1/-1 with an fp16 scale per
   output row). Projection inputs are quantized to int8 per token and per group of 32 to 128 inputs; the integer dot
   products are exact and are rescaled in FP32. Everything else runs in FP32.

   One encoder runs one kea_encode at a time; separate encoders are independent (each has its own threads and
   scratch memory). */
#ifndef KEA_H
#define KEA_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum { KEA_DIM = 1024, KEA_MAX_FRAMES = 1501, KEA_MAX_T = 188, KEA_MEL_BINS = 128 };

typedef struct kea_encoder kea_encoder;

/* weight_bin: the encoder weights file, which must stay mapped until kea_close. index: text with one line
   "<tensor name> <offset> <bytes>" per tensor (offsets into weight_bin). threads <= 0 means 4.
   Returns NULL if a tensor is missing or malformed, or memory runs out. */
kea_encoder *kea_open(const uint8_t *weight_bin, size_t len, const char *index, size_t index_len, int threads);

/* mel: [128][mel_stride] log-mel features, channel-major; valid_l0 valid frames (1..1501, <= mel_stride).
   Computes only the valid output frames: T = L3 with L(k+1) = (L(k) - 1) / 2 + 1 (T <= 188).
   out: [T][1024] (room for 188 x 1024 floats). Returns 0 on success, -1 on bad arguments. */
int kea_encode(kea_encoder *e, const float *mel, int mel_stride, int valid_l0, float *out, int *out_frames);

void kea_close(kea_encoder *e);

/* ---- The projection kernel on its own, for tests.

   Arithmetic, for X [M][K] and a matrix W with N rows, groups of G inputs (G = 32, 64 or 128; K a multiple of 64 and
   of G, at most 4096):
     for each row m and group g: amax = max |x| over the group (float); if amax == 0 the group's q are 0;
       inv = 127.0f / amax; q_k = clamp(round_half_even(x_k * inv), -127, 127) (float multiply); s_g = amax / 127.0f
     d_g = sum over the group of q_k * w_k (w = +1 for bit 1, -1 for bit 0), an exact integer
     Y[m][n] = scale[n] * sum_g s_g * d_g, in FP32 (the order of that sum is not specified).
   With inputs whose every group has max |x| = 127 * 2^e for a small integer e and x = integer * 2^e, every value
   above is exact (|sum| < 2^24 / 2^-e), so any summation order gives the same float result. */
typedef struct kea_pool kea_pool;
kea_pool *kea_pool_create(int threads); /* threads <= 0 means 4 */
void kea_pool_destroy(kea_pool *pool);

typedef struct {
    const uint8_t *bits;       /* [N][K / 8], row-major, LSB first: bit 1 = +1, bit 0 = -1 */
    const uint16_t *scale_f16; /* [N] */
    int N, K, group;           /* group: 32, 64 or 128 */
} kea_bits;

typedef struct kea_int8_matrix kea_int8_matrix;
kea_int8_matrix *kea_int8_pack(const kea_bits *w); /* copies what it needs; NULL if the shape is unsupported */
void kea_int8_free(kea_int8_matrix *w);
/* Y[m * ldy + n] for m < M, n < N; X[m * ldx + k] for k < K. kea_int8_proj uses AVX2 when the CPU has it;
   kea_int8_proj_portable always runs the portable C path. */
void kea_int8_proj(const float *X, int M, int ldx, const kea_int8_matrix *w, float *Y, int ldy, kea_pool *pool);
void kea_int8_proj_portable(const float *X, int M, int ldx, const kea_int8_matrix *w, float *Y, int ldy,
                            kea_pool *pool);
int kea_int8_uses_avx2(void);

#ifdef __cplusplus
}
#endif
#endif
