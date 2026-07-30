// Adapted from Control Center's `packages/cc_natives/native/aec_ffi.cc`.
// Copyright (c) 2026 Samuel Alev. Licensed under the MIT License. See NOTICE.
//
// Builds against webrtc-audio-processing v2.1 (BSD-3-Clause); see NOTICE for
// that project's attribution. No WebRTC source is vendored into this
// repository — `tool/build_native.sh` fetches it at a pinned revision.
//
// Adaptation notes: the C ABI is preserved symbol-for-symbol, because the Dart
// side (`lib/src/bindings.dart`) is written against exactly these six symbols
// and a divergence here would be invisible until a native call corrupted
// memory. Comments are rewritten for Audio Kit's terminology (near = mic,
// far = loopback reference) and the "them"/Whisper framing of the original is
// generalized: any downstream recognizer degrades on speaker bleed.
//
// A thin C ABI over WebRTC's AEC3 `AudioProcessing` module.
//
// Audio Kit captures the microphone ("near") and a system loopback ("far") as
// two independent 16 kHz mono streams. The mic also picks up whatever plays out
// of the speakers, which a recognizer downstream transcribes as a degraded
// duplicate of the far side. Here the loopback is fed as the AEC far-end
// reference and subtracted from the mic at the signal level. Pure in-process
// DSP: it never touches OS audio routing (unlike macOS Voice-Processing I/O,
// which ducks playback and breaks a system tap — the reason software AEC is the
// only workable option on the desktop capture path).
//
// Contract: mono PCM16, exactly one ~10 ms block per call (160 samples @16 kHz,
// i.e. AudioProcessing::GetFrameSize(16000)). All calls for one handle must come
// from the same thread (the Dart main isolate); the instance is stateful.

#include <cstdint>
#include <vector>

#include "api/audio/audio_processing.h"
#include "api/scoped_refptr.h"

namespace {

struct AecInstance {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream_config;
  // Scratch destination for the reverse (render) stream — AEC3 requires a dest
  // buffer but the processed render output is discarded.
  std::vector<int16_t> reverse_out;
};

}  // namespace

extern "C" {

// Creates an AEC instance for [sample_rate_hz] / [num_channels]. Enables AEC3
// (mobile_mode off) + the high-pass filter; deliberately leaves AGC and noise
// suppression off so the user's own voice stays natural for the recognizer.
// Returns an opaque handle, or null on failure.
void* aec_create(int sample_rate_hz, int num_channels) {
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  config.echo_canceller.mobile_mode = false;  // full AEC3
  config.high_pass_filter.enabled = true;
  config.gain_controller1.enabled = false;
  config.gain_controller2.enabled = false;
  config.noise_suppression.enabled = false;

  auto apm = webrtc::AudioProcessingBuilder().SetConfig(config).Create();
  if (!apm) {
    return nullptr;
  }

  const size_t frame =
      static_cast<size_t>(webrtc::AudioProcessing::GetFrameSize(sample_rate_hz));
  auto* inst = new AecInstance{
      apm,
      webrtc::StreamConfig(sample_rate_hz, static_cast<size_t>(num_channels)),
      std::vector<int16_t>(frame * static_cast<size_t>(num_channels), 0),
  };
  return inst;
}

// Feeds one far-end (loopback/render) block of [frames] mono samples. AEC3
// buffers this as the reference it later subtracts from the mic.
void aec_process_reverse(void* handle, const int16_t* ref, int frames) {
  (void)frames;  // size comes from the instance's StreamConfig
  auto* inst = static_cast<AecInstance*>(handle);
  if (inst == nullptr || ref == nullptr) {
    return;
  }
  inst->apm->ProcessReverseStream(ref, inst->stream_config, inst->stream_config,
                                  inst->reverse_out.data());
}

// Cleans one near-end (mic/capture) block: reads [cap], writes the echo-removed
// result into [out] ([cap] and [out] may differ; both hold [frames] samples).
// [stream_delay_ms] is the caller's estimate of how far the far-end reference
// LEADS this capture block (ProcessReverseStream -> corresponding echo in
// ProcessStream). The Dart side measures it per session by cross-correlating the
// two independent captures and feeds it here; AEC3 still refines it internally,
// but a correct external hint is what lets its estimator lock when the two
// streams have an unknown, hardware-specific offset.
void aec_process_capture(void* handle, const int16_t* cap, int16_t* out,
                         int frames, int stream_delay_ms) {
  (void)frames;
  auto* inst = static_cast<AecInstance*>(handle);
  if (inst == nullptr || cap == nullptr || out == nullptr) {
    return;
  }
  if (stream_delay_ms < 0) {
    stream_delay_ms = 0;
  }
  inst->apm->set_stream_delay_ms(stream_delay_ms);
  inst->apm->ProcessStream(cap, inst->stream_config, inst->stream_config, out);
}

// Reads AEC3's current echo metrics. [erle] (echo return loss enhancement, dB)
// is the key signal: > 0 means AEC3 is actively removing echo; ~0 / unavailable
// means it is not. [erl] is the echo return loss, [residual] the residual-echo
// likelihood (0..1), and [delay_ms] AEC3's own internal delay estimate.
// Unavailable metrics are written as sentinels (doubles: -1000.0; delay: -1) so
// the Dart side can map them to null. Any out pointer may be non-null; all are
// written.
void aec_get_metrics(void* handle, double* erl, double* erle, double* residual,
                     int* delay_ms) {
  if (erl) *erl = -1000.0;
  if (erle) *erle = -1000.0;
  if (residual) *residual = -1000.0;
  if (delay_ms) *delay_ms = -1;
  auto* inst = static_cast<AecInstance*>(handle);
  if (inst == nullptr) {
    return;
  }
  webrtc::AudioProcessingStats stats = inst->apm->GetStatistics();
  if (erl && stats.echo_return_loss.has_value()) {
    *erl = *stats.echo_return_loss;
  }
  if (erle && stats.echo_return_loss_enhancement.has_value()) {
    *erle = *stats.echo_return_loss_enhancement;
  }
  if (residual && stats.residual_echo_likelihood.has_value()) {
    *residual = *stats.residual_echo_likelihood;
  }
  if (delay_ms && stats.delay_ms.has_value()) {
    *delay_ms = *stats.delay_ms;
  }
}

// Destroys the instance created by aec_create.
void aec_destroy(void* handle) {
  delete static_cast<AecInstance*>(handle);
}

// Static version string for FFI smoke tests; do not free.
const char* aec_version(void) {
  return "webrtc-audio-processing-2.1+aec3";
}

}  // extern "C"
