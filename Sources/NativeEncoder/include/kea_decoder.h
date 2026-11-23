/* kea_decoder.h: one step of the TDT speech decoder (the 2-layer LSTM prediction network, its projection and the
 * joint) with the large weight matrices held as int8 per output row, so the working set (~6 MB) fits a laptop L3.
 * A decoder holds scratch buffers: use each one from one thread at a time. */
#ifndef KEA_DECODER_H
#define KEA_DECODER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kea_decoder kea_decoder;

/* All inputs FP32 row-major, copied/quantized at open; the caller may free them afterwards.
 * table0 stays FP32; whh0, w1cat, predW and outW become int8 q[n][k] with an FP32 scale per row,
 * s[n] = max_k |W[n][k]| / 127 (1 for an all-zero row), q = clamp(round-half-even(W / s), -127, 127), and
 * y[n] = s[n] * sum_k q[n][k] x[k]. w1cat has a scale per half-row instead (W_ih1 and W_hh1 rows each their own:
 * one scale over both costs W_ih1 up to 5 bits and changes transcripts), y[n] = s0[n] q0[n].h0 + s1[n] q1[n].h1.
 * Returns NULL when an input is NULL or memory runs out. */
kea_decoder *kea_decoder_open(const float *table0 /* [1025][2560] */, const float *whh0 /* [2560][640] */,
                              const float *w1cat /* [2560][1280] */, const float *bias1 /* [2560] */,
                              const float *predW /* [640][640] */, const float *predB /* [640] */,
                              const float *outW /* [1030][640] */, const float *outB /* [1030] */);

/* Same contract as NativeMath.predict: h, c are [2][640] (layer 0 then layer 1), updated in place; g [640] out.
 * 0 <= token < 1025 (1024 is blank, the start symbol). g must not overlap h or c. */
void kea_decoder_predict(kea_decoder *, int token, float *h, float *c, float *g);

/* logits [1030] = W_out relu(f + g) + b_out. */
void kea_decoder_joint(kea_decoder *, const float *f, const float *g, float *logits);

void kea_decoder_close(kea_decoder *);

#ifdef __cplusplus
}
#endif

#endif
