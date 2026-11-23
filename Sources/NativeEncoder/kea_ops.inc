/* kea_ops.inc: plain loops for the convolution ops, compiled twice: by kea_ops.c (baseline ISA) and kea_ops_avx2.c
   (AVX2 + FMA), with SFX(name) and TGT defined by the includer. */

/* conv 3x3 stride 2 pad 1, 1 -> 256 channels, + bias, ReLU. mel [128][stride] (time = column, F valid frames);
   out [L1][64][256] channel-last. */
TGT static void SFX(conv0)(const float *mel, int stride, int F, const float *w9, const float *b, float *out, int i0,
                           int i1) {
    for (int i = i0; i < i1; i++)
        for (int j = 0; j < 64; j++) {
            float acc[256];
            for (int o = 0; o < 256; o++) acc[o] = b[o];
            for (int dy = 0; dy < 3; dy++) {
                int y = 2 * i + dy - 1;
                if (y < 0 || y >= F) continue;
                for (int dx = 0; dx < 3; dx++) {
                    int x = 2 * j + dx - 1;
                    if (x < 0 || x >= 128) continue;
                    float v = mel[(size_t)x * (size_t)stride + (size_t)y];
                    const float *w = w9 + (dy * 3 + dx) * 256;
                    for (int o = 0; o < 256; o++) acc[o] += w[o] * v;
                }
            }
            float *op = out + ((size_t)i * 64 + (size_t)j) * 256;
            for (int o = 0; o < 256; o++) op[o] = acc[o] > 0.f ? acc[o] : 0.f;
        }
}

/* depthwise 3x3 stride 2 pad 1 over [H][W][256] -> [Ho][Wo][256], + bias. */
TGT static void SFX(dwsub)(const float *in, int H, int W, const float *w9, const float *b, float *out, int i0, int i1) {
    int Wo = (W - 1) / 2 + 1;
    for (int i = i0; i < i1; i++)
        for (int j = 0; j < Wo; j++) {
            float acc[256];
            for (int c = 0; c < 256; c++) acc[c] = b[c];
            for (int dy = 0; dy < 3; dy++) {
                int y = 2 * i + dy - 1;
                if (y < 0 || y >= H) continue;
                for (int dx = 0; dx < 3; dx++) {
                    int x = 2 * j + dx - 1;
                    if (x < 0 || x >= W) continue;
                    const float *ip = in + ((size_t)y * (size_t)W + (size_t)x) * 256;
                    const float *w = w9 + (dy * 3 + dx) * 256;
                    for (int c = 0; c < 256; c++) acc[c] += w[c] * ip[c];
                }
            }
            float *op = out + ((size_t)i * (size_t)Wo + (size_t)j) * 256;
            for (int c = 0; c < 256; c++) op[c] = acc[c];
        }
}

/* depthwise conv over time, k = 9, pad 4, + bias. g holds rows gbase.. of [T][1024]; out holds rows t0..t1-1. */
TGT static void SFX(dwconv)(const float *g, int gbase, int T, const float *w9, const float *b, float *out, int t0,
                            int t1) {
    for (int t = t0; t < t1; t++) {
        float *op = out + (size_t)(t - t0) * 1024;
        for (int c = 0; c < 1024; c++) op[c] = b[c];
        for (int j = 0; j < 9; j++) {
            int s = t + j - 4;
            if (s < 0 || s >= T) continue;
            const float *gp = g + (size_t)(s - gbase) * 1024, *w = w9 + j * 1024;
            for (int c = 0; c < 1024; c++) op[c] += gp[c] * w[c];
        }
    }
}

TGT static void SFX(bias_act)(float *x, int ld, int n, const float *b, int relu, int r0, int r1) {
    for (int r = r0; r < r1; r++) {
        float *p = x + (size_t)r * (size_t)ld;
        if (relu)
            for (int i = 0; i < n; i++) {
                float v = p[i] + b[i];
                p[i] = v > 0.f ? v : 0.f;
            }
        else
            for (int i = 0; i < n; i++) p[i] += b[i];
    }
}
