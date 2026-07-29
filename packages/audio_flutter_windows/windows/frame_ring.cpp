#include "frame_ring.h"

#include <utility>

namespace audio_flutter_windows {

void FrameRing::Configure(size_t capacity, OverflowPolicy policy) {
  capacity_ = capacity > 0 ? capacity : 1;
  policy_ = policy;
  Clear();
}

FrameRing::Admission FrameRing::Add(CapturedFrame frame) {
  if (frames_.size() >= capacity_) {
    switch (policy_) {
      case OverflowPolicy::kDropOldest:
        frames_.pop_front();
        ++drops_before_head_;
        break;
      case OverflowPolicy::kDropNewest:
        ++drops_before_next_add_;
        return Admission::kDiscarded;
      case OverflowPolicy::kFailCapture:
        return Admission::kOverflowed;
    }
    frame.dropped_frames_before += drops_before_next_add_;
    drops_before_next_add_ = 0;
    frames_.push_back(std::move(frame));
    return Admission::kDisplacedOldest;
  }

  frame.dropped_frames_before += drops_before_next_add_;
  drops_before_next_add_ = 0;
  frames_.push_back(std::move(frame));
  return Admission::kAccepted;
}

void FrameRing::Take(size_t max_frames, std::vector<CapturedFrame>* out) {
  if (out == nullptr || max_frames == 0 || frames_.empty()) {
    return;
  }
  const size_t count = max_frames < frames_.size() ? max_frames : frames_.size();
  for (size_t index = 0; index < count; ++index) {
    CapturedFrame frame = std::move(frames_.front());
    frames_.pop_front();
    if (index == 0 && drops_before_head_ > 0) {
      frame.dropped_frames_before += drops_before_head_;
      drops_before_head_ = 0;
    }
    out->push_back(std::move(frame));
  }
}

void FrameRing::Clear() {
  frames_.clear();
  drops_before_head_ = 0;
  drops_before_next_add_ = 0;
}

}  // namespace audio_flutter_windows
