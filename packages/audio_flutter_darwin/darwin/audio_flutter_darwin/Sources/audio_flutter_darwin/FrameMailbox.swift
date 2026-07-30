import Foundation

/// A small bounded native ring. Capture callbacks never wait for Dart; Dart
/// pulls batches and every overflow is either reported or fails the session.
final class FrameMailbox {
  private let condition = NSCondition()
  private let capacity: Int
  private let overflowPolicy: CaptureOverflowPolicyMessage
  private var frames: [AudioFrameMessage] = []
  private var pendingDroppedFrames: Int64 = 0
  private var ended = false
  private var failed = false

  init(capacity: Int, overflowPolicy: CaptureOverflowPolicyMessage) {
    self.capacity = max(capacity, 1)
    self.overflowPolicy = overflowPolicy
  }

  /// Returns false when failCapture overflowed.
  func push(_ incomingFrame: AudioFrameMessage) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard !ended, !failed else { return false }
    var frame = incomingFrame

    if frames.count >= capacity {
      switch overflowPolicy {
      case .dropOldest:
        let dropped = frames.removeFirst()
        let droppedRange = 1 + dropped.droppedFramesBefore
        if frames.isEmpty {
          pendingDroppedFrames += droppedRange
        } else {
          // The gap occurred before the new oldest frame, not before the
          // incoming tail frame.
          frames[0].droppedFramesBefore += droppedRange
        }
      case .dropNewest:
        pendingDroppedFrames += 1 + frame.droppedFramesBefore
        return true
      case .failCapture:
        failed = true
        ended = true
        frames.removeAll(keepingCapacity: false)
        condition.broadcast()
        return false
      }
    }

    if pendingDroppedFrames > 0 {
      frame.droppedFramesBefore += pendingDroppedFrames
      pendingDroppedFrames = 0
    }
    frames.append(frame)
    condition.signal()
    return true
  }

  func read(maxFrames: Int, timeout: TimeInterval) -> AudioFrameBatchMessage {
    condition.lock()
    defer { condition.unlock() }

    if frames.isEmpty, !ended {
      _ = condition.wait(until: Date().addingTimeInterval(max(timeout, 0)))
    }
    let count = min(max(maxFrames, 1), frames.count)
    let result = Array(frames.prefix(count))
    if count > 0 {
      frames.removeFirst(count)
    }
    return AudioFrameBatchMessage(frames: result, endOfStream: ended && frames.isEmpty)
  }

  func finish(discardBuffered: Bool = false) {
    condition.lock()
    ended = true
    if discardBuffered {
      frames.removeAll(keepingCapacity: false)
    }
    condition.broadcast()
    condition.unlock()
  }

  /// Drop-newest gaps with no following frame are reported through the
  /// session health stream at graceful end-of-stream.
  func trailingDroppedFrameCount() -> Int64 {
    condition.lock()
    defer { condition.unlock() }
    return pendingDroppedFrames
  }
}

/// Rechunks converted interleaved PCM into a stable frame duration.
final class CaptureFrameAssembler {
  private let sessionId: Int64
  private let sampleRate: Int
  private let channelCount: Int
  private let samplesPerFrame: Int
  private let frameDurationMicros: Int64
  private let mailbox: FrameMailbox
  private var pending: [Float] = []
  private var sequence: Int64 = 0
  private var sampleOffset: Int64 = 0
  private var anchorTimestampMicros: Int64?
  private var pendingDroppedFrames: Int64 = 0
  private var pendingDiscontinuityReason: DiscontinuityReasonMessage?
  private var sourceRestartPending = false
  private var lastEmittedEndTimestampMicros: Int64?
  private let statisticsLock = NSLock()
  private var callbackCount: Int64 = 0
  private var nonZeroFrameCount: Int64 = 0
  private var sampleCount: Int64 = 0
  private var peakAmplitude: Float = 0
  private var sumSquares: Double = 0
  private var firstAudioAtMicros: Int64?
  private let createdAtMicros = MonotonicClock.microseconds()

  init(
    sessionId: Int64,
    sampleRate: Int,
    channelCount: Int,
    frameDurationMicros: Int64,
    mailbox: FrameMailbox
  ) {
    self.sessionId = sessionId
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.mailbox = mailbox
    self.frameDurationMicros = max(frameDurationMicros, 1)
    let frames = max(
      Int((Double(sampleRate) * Double(frameDurationMicros) / 1_000_000).rounded()),
      1
    )
    samplesPerFrame = frames * channelCount
  }

  /// Returns false if the capture must fail because the mailbox overflowed.
  func push(_ samples: [Float], timestampMicros: Int64? = nil) -> Bool {
    // One pass over the buffer feeds every level statistic; the health stream
    // reads them at its own low rate.
    var peak: Float = 0
    var squares: Double = 0
    for sample in samples {
      let magnitude = abs(sample)
      if magnitude > peak { peak = magnitude }
      squares += Double(sample) * Double(sample)
    }
    statisticsLock.lock()
    callbackCount += 1
    sampleCount += Int64(samples.count)
    sumSquares += squares
    if peak > peakAmplitude { peakAmplitude = peak }
    if peak > 0 {
      nonZeroFrameCount += 1
      if firstAudioAtMicros == nil {
        firstAudioAtMicros = MonotonicClock.microseconds() - createdAtMicros
      }
    }
    statisticsLock.unlock()
    if anchorTimestampMicros == nil {
      anchorTimestampMicros = timestampMicros ?? MonotonicClock.microseconds()
    }
    pending.append(contentsOf: samples)
    while pending.count >= samplesPerFrame {
      let payload = Array(pending.prefix(samplesPerFrame))
      pending.removeFirst(samplesPerFrame)
      let timestampMicros =
        (anchorTimestampMicros ?? MonotonicClock.microseconds())
        + sampleOffset * 1_000_000 / Int64(sampleRate)
      let frame = AudioFrameMessage(
        sessionId: sessionId,
        sequence: sequence,
        sampleOffset: sampleOffset,
        timestampMicros: timestampMicros,
        float32Samples: AudioTypedData.encode(payload),
        droppedFramesBefore: pendingDroppedFrames,
        discontinuityReason: pendingDiscontinuityReason
      )
      guard mailbox.push(frame) else { return false }
      pendingDroppedFrames = 0
      pendingDiscontinuityReason = nil
      lastEmittedEndTimestampMicros =
        timestampMicros
        + Int64(samplesPerFrame / channelCount) * 1_000_000
        / Int64(sampleRate)
      sequence += 1
      sampleOffset += Int64(samplesPerFrame / channelCount)
    }
    return true
  }

  /// Reconciles the nominal PCM timeline with each absolute host-time callback
  /// before conversion. Small clock drift adjusts future timestamps without
  /// moving backwards; a real callback gap becomes an explicit discontinuity.
  ///
  /// Returns true when the converter's filter history must be reset.
  func prepareInput(timestampMicros: Int64) -> Bool {
    guard let anchorTimestampMicros else {
      sourceRestartPending = false
      return false
    }
    let pendingSampleFrames = Int64(pending.count / channelCount)
    let expectedTimestampMicros =
      anchorTimestampMicros
      + (sampleOffset + pendingSampleFrames) * 1_000_000
      / Int64(sampleRate)
    let driftMicros = timestampMicros - expectedTimestampMicros

    if sourceRestartPending {
      sourceRestartPending = false
      noteDropped(
        durationMicros: max(driftMicros, 1),
        startTimestampMicros: expectedTimestampMicros,
        reason: .sourceRestart
      )
      return true
    }

    let gapThresholdMicros = max(frameDurationMicros / 2, 10_000)
    if driftMicros > gapThresholdMicros {
      noteDropped(
        durationMicros: driftMicros,
        startTimestampMicros: expectedTimestampMicros
      )
      return true
    }

    var correctedAnchor = anchorTimestampMicros + driftMicros
    if let lastEmittedEndTimestampMicros {
      let minimumAnchor =
        lastEmittedEndTimestampMicros
        - sampleOffset * 1_000_000 / Int64(sampleRate)
      correctedAnchor = max(correctedAnchor, minimumAnchor)
    }
    self.anchorTimestampMicros = correctedAnchor
    return false
  }

  /// The host-time clock survives a native capture-chain rebuild, so sequence
  /// and clock ID continue while the next callback carries a restart gap.
  func markSourceRestart() {
    sourceRestartPending = true
  }

  /// Advances the source timeline across work discarded before conversion.
  ///
  /// Any partial rechunking state immediately before the gap cannot be joined
  /// to post-gap audio without hiding a discontinuity, so it becomes part of
  /// the reported dropped range as well.
  func noteDropped(
    durationMicros: Int64,
    startTimestampMicros: Int64?,
    reason: DiscontinuityReasonMessage = .droppedFrames
  ) {
    guard durationMicros > 0 else { return }
    // A restart explains the whole gap it opens, so it outranks a plain drop
    // reported for the same pending range.
    if pendingDiscontinuityReason == nil || reason == .sourceRestart {
      pendingDiscontinuityReason = reason
    }
    if anchorTimestampMicros == nil {
      anchorTimestampMicros =
        startTimestampMicros ?? MonotonicClock.microseconds()
    }
    let pendingSampleFrames = Int64(pending.count / channelCount)
    pending.removeAll(keepingCapacity: true)
    let droppedSampleFrames = max(
      Int64(
        (Double(durationMicros) * Double(sampleRate) / 1_000_000).rounded()
      ),
      1
    )
    let totalDroppedSampleFrames = pendingSampleFrames + droppedSampleFrames
    let outputSampleFrames = max(samplesPerFrame / channelCount, 1)
    let droppedOutputFrames = max(
      (totalDroppedSampleFrames + Int64(outputSampleFrames) - 1)
        / Int64(outputSampleFrames),
      1
    )
    sequence += droppedOutputFrames
    sampleOffset += totalDroppedSampleFrames
    pendingDroppedFrames += droppedOutputFrames
  }

  func statistics() -> CaptureStatistics {
    statisticsLock.lock()
    defer { statisticsLock.unlock() }
    return CaptureStatistics(
      callbackCount: callbackCount,
      nonZeroFrameCount: nonZeroFrameCount,
      peakAmplitude: Double(peakAmplitude),
      rms: sampleCount > 0 ? (sumSquares / Double(sampleCount)).squareRoot() : 0,
      nonZeroFramePercent: callbackCount > 0
        ? Double(nonZeroFrameCount) * 100 / Double(callbackCount)
        : 0,
      firstAudioAtMillis: firstAudioAtMicros.map { $0 / 1_000 }
    )
  }
}

/// Level and liveness statistics accumulated by a `CaptureFrameAssembler`.
///
/// Read at the health stream's low rate, never per frame. `renderCycles` is
/// not here: it counts hardware callbacks, including buffers dropped before
/// they ever reached the assembler, so each capture session owns that counter.
struct CaptureStatistics {
  /// Converted buffers pushed into the assembler.
  let callbackCount: Int64
  /// Pushed buffers that carried at least one non-zero sample.
  let nonZeroFrameCount: Int64
  /// Largest absolute sample seen, 0...1 nominal.
  let peakAmplitude: Double
  /// Root mean square over every sample pushed so far.
  let rms: Double
  /// `nonZeroFrameCount` as a percentage of `callbackCount`.
  let nonZeroFramePercent: Double
  /// Milliseconds from assembler creation to the first non-zero buffer.
  let firstAudioAtMillis: Int64?
}
