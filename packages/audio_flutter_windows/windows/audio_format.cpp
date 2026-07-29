#include "audio_format.h"

#include <ksmedia.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace audio_flutter_windows {

bool IsFloatFormat(const WAVEFORMATEX* format) {
  if (format == nullptr) {
    return false;
  }
  if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    return true;
  }
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto* extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    return ::IsEqualGUID(extensible->SubFormat,
                         KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) != 0;
  }
  return false;
}

bool IsPcmFormat(const WAVEFORMATEX* format) {
  if (format == nullptr) {
    return false;
  }
  if (format->wFormatTag == WAVE_FORMAT_PCM) {
    return true;
  }
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto* extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    return ::IsEqualGUID(extensible->SubFormat, KSDATAFORMAT_SUBTYPE_PCM) != 0;
  }
  return false;
}

float ReadMonoSample(const BYTE* data, UINT32 frame, WORD channels,
                     WORD bits_per_sample, bool is_float) {
  if (data == nullptr || channels == 0 || bits_per_sample == 0) {
    return 0.0f;
  }
  const size_t bytes_per_sample = bits_per_sample / 8;
  const size_t frame_stride = bytes_per_sample * channels;
  const BYTE* frame_ptr = data + static_cast<size_t>(frame) * frame_stride;

  double sum = 0.0;
  for (WORD channel = 0; channel < channels; ++channel) {
    const BYTE* sample_ptr = frame_ptr + channel * bytes_per_sample;
    double value = 0.0;
    if (is_float) {
      // 32-bit is the only float width WASAPI shared mode produces.
      float sample = 0.0f;
      std::memcpy(&sample, sample_ptr, sizeof(float));
      value = static_cast<double>(sample);
    } else {
      switch (bits_per_sample) {
        case 16: {
          int16_t sample = 0;
          std::memcpy(&sample, sample_ptr, sizeof(int16_t));
          value = static_cast<double>(sample) / 32768.0;
          break;
        }
        case 32: {
          int32_t sample = 0;
          std::memcpy(&sample, sample_ptr, sizeof(int32_t));
          value = static_cast<double>(sample) / 2147483648.0;
          break;
        }
        case 24: {
          // Little-endian packed 24-bit signed.
          int32_t sample = static_cast<int32_t>(sample_ptr[0]) |
                           (static_cast<int32_t>(sample_ptr[1]) << 8) |
                           (static_cast<int32_t>(sample_ptr[2]) << 16);
          if ((sample & 0x00800000) != 0) {
            sample |= ~0x00FFFFFF;  // sign-extend
          }
          value = static_cast<double>(sample) / 8388608.0;
          break;
        }
        case 8: {
          // 8-bit PCM is unsigned, centered at 128.
          value = (static_cast<double>(sample_ptr[0]) - 128.0) / 128.0;
          break;
        }
        default:
          value = 0.0;
          break;
      }
    }
    sum += value;
  }
  return static_cast<float>(sum / static_cast<double>(channels));
}

void WriteMonoSample(BYTE* out, UINT32 frame, WORD channels,
                     WORD bits_per_sample, bool is_float, float sample) {
  if (out == nullptr || channels == 0 || bits_per_sample == 0) {
    return;
  }
  const size_t bytes_per_sample = bits_per_sample / 8;
  const size_t frame_stride = bytes_per_sample * channels;
  BYTE* frame_ptr = out + static_cast<size_t>(frame) * frame_stride;

  const float clamped = std::max(-1.0f, std::min(1.0f, sample));
  for (WORD channel = 0; channel < channels; ++channel) {
    BYTE* sample_ptr = frame_ptr + channel * bytes_per_sample;
    if (is_float) {
      std::memcpy(sample_ptr, &clamped, sizeof(float));
      continue;
    }
    switch (bits_per_sample) {
      case 16: {
        // 32767, not 32768, so +1.0 cannot overflow to negative.
        const auto value =
            static_cast<int16_t>(std::lround(clamped * 32767.0f));
        std::memcpy(sample_ptr, &value, sizeof(int16_t));
        break;
      }
      case 32: {
        const auto value = static_cast<int32_t>(
            std::llround(static_cast<double>(clamped) * 2147483647.0));
        std::memcpy(sample_ptr, &value, sizeof(int32_t));
        break;
      }
      case 24: {
        const auto value =
            static_cast<int32_t>(std::lround(clamped * 8388607.0f));
        sample_ptr[0] = static_cast<BYTE>(value & 0xFF);
        sample_ptr[1] = static_cast<BYTE>((value >> 8) & 0xFF);
        sample_ptr[2] = static_cast<BYTE>((value >> 16) & 0xFF);
        break;
      }
      case 8: {
        const auto value =
            static_cast<int32_t>(std::lround(clamped * 127.0f)) + 128;
        sample_ptr[0] = static_cast<BYTE>(std::max(0, std::min(255, value)));
        break;
      }
      default:
        break;
    }
  }
}

void LinearResampler::Reset(double source_rate, double target_rate) {
  const double source = source_rate > 0 ? source_rate : 1.0;
  const double target = target_rate > 0 ? target_rate : 1.0;
  step_ = source / target;
  position_ = 0.0;
  have_previous_ = false;
  previous_sample_ = 0.0f;
}

void LinearResampler::Process(const std::vector<float>& input,
                              std::vector<float>* out) {
  if (input.empty() || out == nullptr) {
    return;
  }

  // Conceptually the input is [previous_sample_, input...]; `position_` is
  // measured in source samples relative to input[0], so position -1 addresses
  // the carried sample.
  const auto count = static_cast<long long>(input.size());
  while (true) {
    const double floor_position = std::floor(position_);
    const auto index0 = static_cast<long long>(floor_position);
    const double fraction = position_ - floor_position;
    const long long index1 = index0 + 1;
    if (index1 >= count) {
      break;  // Need more input before the next output sample exists.
    }

    float sample0;
    if (index0 < 0) {
      sample0 = have_previous_ ? previous_sample_ : input[0];
    } else {
      sample0 = input[static_cast<size_t>(index0)];
    }
    const float sample1 = input[static_cast<size_t>(index1)];
    out->push_back(sample0 +
                   static_cast<float>(fraction) * (sample1 - sample0));
    position_ += step_;
  }

  // Re-base the cursor onto the next block and remember the final sample so
  // interpolation stays continuous across the seam.
  position_ -= static_cast<double>(count);
  previous_sample_ = input[input.size() - 1];
  have_previous_ = true;
}

}  // namespace audio_flutter_windows
