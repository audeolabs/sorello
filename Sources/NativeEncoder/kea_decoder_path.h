/* kea_decoder_path.h: test hooks. Names and selects the arithmetic path a decoder uses, so a test can run the portable
 * path on a machine that also has the AVX2 one, and lists the decoder's memory, so a benchmark can flush exactly it
 * from the caches. Not part of the decoder's API. */
#ifndef KEA_DECODER_PATH_H
#define KEA_DECODER_PATH_H

#include "kea_decoder.h"

enum { KEA_PATH_PORTABLE = 0, KEA_PATH_AVX2 = 1 };

/* With path < 0, returns the path in use. Otherwise selects it (AVX2 only where the CPU has AVX2 and FMA) and
 * returns the path now in use. */
int kea_decoder_use_path(kea_decoder *, int path);

/* Fills up to `max` (base, bytes) pairs of the decoder's buffers; returns how many there are. */
int kea_decoder_regions(const kea_decoder *, const void **base, unsigned long *bytes, int max);

#endif
