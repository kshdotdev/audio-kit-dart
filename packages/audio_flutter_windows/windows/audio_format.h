#ifndef FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_AUDIO_FORMAT_H_
#define FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_AUDIO_FORMAT_H_

// Sample decoding and rate conversion for the WASAPI capture path.
//
// The mix-format decode, the mono down-mix and the phase-continuous linear
// resampler are derived from Control Center's `system_audio_capture` Windows
// plugin (MIT (c) 2026 Samuel Alev); see the package NOTICE. The output type
// differs: audio_kit carries float32 across the platform boundary, so nothing
// here converts to int16.

#include <windows.h>

#include <mmreg.h>

#include <cstddef>
#include <cstdint>
#include <vector>

namespace audio_flutter_windows {

// True when the mix format describes IEEE float samples. WASAPI shared-mode
// mix formats are almost always WAVE_FORMAT_EXTENSIBLE wrapping
// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT.
bool IsFloatFormat(const WAVEFORMATEX* format);

// True when the mix format describes integer PCM samples.
bool IsPcmFormat(const WAVEFORMATEX* format);

// Reads interleaved frame `frame` from `data`, averaging every channel into one
// mono sample in [-1, 1]. Handles 32-bit float and 8/16/24/32-bit integer PCM;
// any other width contributes silence rather than reading past the sample.
float ReadMonoSample(const BYTE* data, UINT32 frame, WORD channels,
                     WORD bits_per_sample, bool is_float);

// Writes `sample` into `out` at `frame` for every channel, converting from
// float32 to the destination mix format. Mirrors ReadMonoSample in reverse for
// the render path.
void WriteMonoSample(BYTE* out, UINT32 frame, WORD channels,
                     WORD bits_per_sample, bool is_float, float sample);

// Linear-interpolation resampler between arbitrary source and target rates.
//
// Why linear and not nearest-neighbour: nearest-neighbour decimation from
// 48 kHz to 16 kHz drops two of every three samples with no anti-aliasing,
// which folds high-frequency content into the speech band and degrades
// downstream ASR. Linear interpolation is a weak low-pass that at least
// averages neighbouring samples, is monotonic in phase, and is cheap enough for
// the capture thread. A polyphase windowed-sinc filter is the documented next
// step; linear is the correct minimum.
//
// The fractional cursor is carried across calls so packet seams do not reset
// the phase and click.
class LinearResampler {
 public:
  // `source_rate` and `target_rate` are in Hz; both must be positive.
  void Reset(double source_rate, double target_rate);

  // Appends resampled mono samples for `input` to `out`.
  void Process(const std::vector<float>& input, std::vector<float>* out);

 private:
  double step_ = 1.0;
  // Read cursor in source samples, relative to the first element of the current
  // input block.
  double position_ = 0.0;
  bool have_previous_ = false;
  float previous_sample_ = 0.0f;
};

}  // namespace audio_flutter_windows

#endif  // FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_AUDIO_FORMAT_H_
