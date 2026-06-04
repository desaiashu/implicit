/* swearcore — C ABI for the Swift shell.
 *
 * Hand-maintained to mirror src/ffi.rs. The Swift package links the static
 * library (libswearcore.a) built by `cargo build --release` and imports this
 * header via a module map (see ../../macos-app/README.md).
 */
#ifndef SWEARCORE_H
#define SWEARCORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SwearEngine SwearEngine;

typedef struct SwearConfig {
  uint32_t sample_rate;       /* device rate, e.g. 48000                       */
  uint32_t channels;          /* interleaved channel count                     */
  float    delay_ms;          /* broadcast delay, e.g. 800.0                   */
  float    fade_ms;           /* censor edge crossfade, e.g. 6.0               */
  uint32_t mode;              /* 0 = mute, 1 = bleep                           */
  uint32_t max_block_frames;  /* largest IOProc block you will pass            */
  uint32_t ms_per_char;       /* word-length estimate, ms per letter           */
  uint32_t latency_margin_ms; /* detector-latency reach-back                   */
  uint32_t postroll_ms;       /* tail kept after the word                      */
  float    sensitivity;       /* 0.0 cautious .. 1.0 most sensitive            */
} SwearConfig;

/* Lifecycle. */
SwearEngine *swear_engine_new(const SwearConfig *cfg);
void         swear_engine_free(SwearEngine *engine);

/* Real-time path: call once per IOProc block. input/output each hold
 * frames*channels interleaved f32 samples. */
void swear_engine_process(SwearEngine *engine, const float *input,
                          float *output, uint32_t frames);

/* Controls. */
void     swear_engine_set_mode(SwearEngine *engine, uint32_t mode);
void     swear_engine_set_ms_per_char(const SwearEngine *engine, uint32_t ms);
void     swear_engine_set_latency_margin_ms(const SwearEngine *engine, uint32_t ms);
void     swear_engine_set_postroll_ms(const SwearEngine *engine, uint32_t ms);
void     swear_engine_force_censor(SwearEngine *engine, uint64_t start_frame,
                                   uint64_t end_frame);
uint32_t swear_engine_active_censors(const SwearEngine *engine);

/* Static, NUL-terminated; valid for the process lifetime. */
const char *swear_core_version(void);

#ifdef __cplusplus
}
#endif

#endif /* SWEARCORE_H */
