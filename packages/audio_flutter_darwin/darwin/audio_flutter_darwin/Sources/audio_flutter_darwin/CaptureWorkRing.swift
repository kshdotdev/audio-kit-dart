import AVFoundation
import Foundation

/// Callback-owned audio copied into the bounded pre-conversion queue.
///
/// A gap belongs immediately before this item. Keeping the gap on the next
/// accepted item preserves its chronological position for both drop policies.
struct CaptureWorkItem {
  let buffer: AVAudioPCMBuffer
  let timestampMicros: Int64
  let durationMicros: Int64
  var droppedDurationMicrosBefore: Int64 = 0
  var droppedStartTimestampMicros: Int64?

  init(buffer: AVAudioPCMBuffer, timestampMicros: Int64) {
    self.buffer = buffer
    self.timestampMicros = timestampMicros
    durationMicros = max(
      Int64(
        (Double(buffer.frameLength) / buffer.format.sampleRate
          * 1_000_000).rounded()
      ),
      1
    )
  }
}

enum CaptureWorkEnqueueResult {
  case accepted
  case droppedNewest
  case failed
  case closed
}

/// A duration- and count-bounded, nonblocking ring between real-time audio
/// callbacks and recording/conversion work.
///
/// `takeNext` keeps the pump marked as scheduled until it observes an empty
/// ring. This closes the producer/consumer race without scheduling one block
/// per audio callback.
final class CaptureWorkRing {
  private let lock = NSLock()
  private let maximumDurationMicros: Int64
  private let overflowPolicy: CaptureOverflowPolicyMessage
  private var storage: [CaptureWorkItem?]
  private var head = 0
  private var count = 0
  private var bufferedDurationMicros: Int64 = 0
  private var pendingDroppedDurationMicros: Int64 = 0
  private var pendingDroppedStartTimestampMicros: Int64?
  private var accepting = true
  private var pumpScheduled = false

  init(
    maximumDurationMicros: Int64,
    overflowPolicy: CaptureOverflowPolicyMessage,
    maximumItemCount: Int = 2_048
  ) {
    self.maximumDurationMicros = max(maximumDurationMicros, 1)
    self.overflowPolicy = overflowPolicy
    storage = [CaptureWorkItem?](
      repeating: nil,
      count: max(maximumItemCount, 1)
    )
  }

  func enqueue(
    _ incomingItem: CaptureWorkItem,
    schedulePump: () -> Void
  ) -> CaptureWorkEnqueueResult {
    lock.lock()
    defer { lock.unlock() }
    guard accepting else { return .closed }
    var item = incomingItem

    if wouldOverflow(adding: item) {
      switch overflowPolicy {
      case .dropNewest:
        accumulatePendingGap(
          durationMicros: item.durationMicros,
          startTimestampMicros: item.timestampMicros
        )
        return .droppedNewest
      case .failCapture:
        accepting = false
        removeAll()
        return .failed
      case .dropOldest:
        var removedDurationMicros: Int64 = 0
        var removedStartTimestampMicros: Int64?
        while count > 0, wouldOverflow(adding: item) {
          guard let removed = removeFirst() else { break }
          if removedStartTimestampMicros == nil {
            removedStartTimestampMicros =
              removed.droppedStartTimestampMicros ?? removed.timestampMicros
          }
          removedDurationMicros = clampedAdd(
            removedDurationMicros,
            clampedAdd(
              removed.droppedDurationMicrosBefore,
              removed.durationMicros
            )
          )
        }
        if count > 0 {
          let index = head
          if var next = storage[index] {
            next.droppedDurationMicrosBefore = clampedAdd(
              next.droppedDurationMicrosBefore,
              removedDurationMicros
            )
            next.droppedStartTimestampMicros =
              next.droppedStartTimestampMicros
              ?? removedStartTimestampMicros
            storage[index] = next
          }
        } else {
          accumulatePendingGap(
            durationMicros: removedDurationMicros,
            startTimestampMicros: removedStartTimestampMicros
          )
        }
      }
    }

    if pendingDroppedDurationMicros > 0 {
      item.droppedDurationMicrosBefore = clampedAdd(
        item.droppedDurationMicrosBefore,
        pendingDroppedDurationMicros
      )
      item.droppedStartTimestampMicros =
        item.droppedStartTimestampMicros
        ?? pendingDroppedStartTimestampMicros
      pendingDroppedDurationMicros = 0
      pendingDroppedStartTimestampMicros = nil
    }
    append(item)
    let shouldSchedule = !pumpScheduled
    pumpScheduled = true
    // Schedule before releasing the ring lock. A concurrent graceful finish
    // can therefore never observe accepted work whose pump has not yet been
    // submitted to the serial worker queue.
    if shouldSchedule {
      schedulePump()
    }
    return .accepted
  }

  /// Called only by the serial conversion worker.
  func takeNext() -> CaptureWorkItem? {
    lock.lock()
    defer { lock.unlock() }
    guard let item = removeFirst() else {
      pumpScheduled = false
      return nil
    }
    return item
  }

  /// Stops future callbacks from enqueueing. A graceful finish leaves accepted
  /// items available to the already-scheduled pump; abort removes them now.
  func finish(discardBuffered: Bool) {
    lock.lock()
    accepting = false
    if discardBuffered {
      removeAll()
    }
    lock.unlock()
  }

  /// Duration dropped after the last accepted item. It cannot be attached to a
  /// later frame when the source ends, so sessions surface it as a health
  /// event during graceful stop.
  func trailingDroppedDurationMicros() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return pendingDroppedDurationMicros
  }

  private func wouldOverflow(adding item: CaptureWorkItem) -> Bool {
    guard count > 0 else {
      // One callback may be larger than the requested duration, but memory is
      // still bounded to that single item plus the currently-processing item.
      return false
    }
    return count >= storage.count
      || bufferedDurationMicros
        > maximumDurationMicros - min(item.durationMicros, maximumDurationMicros)
  }

  private func append(_ item: CaptureWorkItem) {
    let index = (head + count) % storage.count
    storage[index] = item
    count += 1
    bufferedDurationMicros = clampedAdd(
      bufferedDurationMicros,
      item.durationMicros
    )
  }

  @discardableResult
  private func removeFirst() -> CaptureWorkItem? {
    guard count > 0, let item = storage[head] else { return nil }
    storage[head] = nil
    head = (head + 1) % storage.count
    count -= 1
    bufferedDurationMicros = max(
      bufferedDurationMicros - item.durationMicros,
      0
    )
    return item
  }

  private func removeAll() {
    storage = [CaptureWorkItem?](repeating: nil, count: storage.count)
    head = 0
    count = 0
    bufferedDurationMicros = 0
    pendingDroppedDurationMicros = 0
    pendingDroppedStartTimestampMicros = nil
  }

  private func accumulatePendingGap(
    durationMicros: Int64,
    startTimestampMicros: Int64?
  ) {
    guard durationMicros > 0 else { return }
    if pendingDroppedStartTimestampMicros == nil {
      pendingDroppedStartTimestampMicros = startTimestampMicros
    }
    pendingDroppedDurationMicros = clampedAdd(
      pendingDroppedDurationMicros,
      durationMicros
    )
  }

  private func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : value
  }
}
