import AVFoundation
import Foundation
import os

final class PcmPlaybackSession {
  let sessionId: Int64
  let format: PcmFormatMessage

  private let events: SessionEventsHandler
  private let maxBufferedFrames: Int64
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let lifecycle = NSLock()
  private let condition = NSCondition()
  private var pendingFrames: Int64 = 0
  private var running = false
  private var aborted = false
  private var playerAttached = false
  private let avFormat: AVAudioFormat

  init(
    sessionId: Int64,
    request: PlaybackRequestMessage,
    events: SessionEventsHandler
  ) throws {
    self.sessionId = sessionId
    format = request.inputFormat
    self.events = events
    maxBufferedFrames = max(
      request.maxBufferedDurationMicros * request.inputFormat.sampleRate / 1_000_000,
      1
    )
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(request.inputFormat.sampleRate),
        channels: AVAudioChannelCount(request.inputFormat.channelCount),
        interleaved: false
      )
    else {
      throw PigeonError(
        code: "InvalidPlaybackFormat",
        message: "Could not construct the requested playback format",
        details: nil
      )
    }
    avFormat = format
  }

  func start() throws {
    lifecycle.lock()
    defer { lifecycle.unlock() }
    condition.lock()
    let isRunning = running
    let isAborted = aborted
    condition.unlock()
    guard !isRunning else { return }
    guard !isAborted else {
      throw PigeonError(
        code: "PlaybackAborted",
        message: "An aborted playback session cannot be restarted",
        details: nil
      )
    }
    engine.attach(player)
    playerAttached = true
    engine.connect(player, to: engine.mainMixerNode, format: avFormat)
    engine.prepare()
    do {
      try engine.start()
    } catch {
      engine.stop()
      engine.detach(player)
      playerAttached = false
      throw error
    }
    player.play()
    condition.lock()
    running = true
    condition.unlock()
    events.emit(
      AudioSessionEventMessage(sessionId: sessionId, phase: .running)
    )
  }

  /// Called from a background host-api queue. It waits for the player's
  /// bounded scheduling window, providing real backpressure to synthesized or
  /// offline sources without blocking Flutter's platform thread.
  func enqueue(_ frames: [AudioFrameMessage]) throws {
    condition.lock()
    let acceptsFrames = running && !aborted
    condition.unlock()
    guard acceptsFrames else {
      throw PigeonError(
        code: "PlaybackNotRunning",
        message: "Playback session is not running",
        details: nil
      )
    }
    for frame in frames {
      guard frame.float32Samples.data.count.isMultiple(
        of: MemoryLayout<Float>.size
      ) else {
        throw PigeonError(
          code: "InvalidPlaybackFrame",
          message: "PCM byte length is not aligned to float32 samples",
          details: nil
        )
      }
      let samples = AudioTypedData.decode(frame.float32Samples)
      let channels = Int(format.channelCount)
      guard
        channels > 0,
        !samples.isEmpty,
        samples.count.isMultiple(of: channels)
      else {
        throw PigeonError(
          code: "InvalidPlaybackFrame",
          message: "PCM frame does not match the playback channel count",
          details: nil
        )
      }
      let frameCount = samples.count / channels
      guard Int64(frameCount) <= maxBufferedFrames else {
        throw PigeonError(
          code: "PlaybackFrameTooLarge",
          message: "One PCM frame exceeds the bounded playback window",
          details: nil
        )
      }

      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: avFormat,
          frameCapacity: AVAudioFrameCount(frameCount)
        ),
        let channelData = buffer.floatChannelData
      else {
        throw PigeonError(
          code: "PlaybackBufferUnavailable",
          message: "Could not allocate a PCM playback buffer",
          details: nil
        )
      }
      buffer.frameLength = AVAudioFrameCount(frameCount)
      for index in 0..<frameCount {
        for channel in 0..<channels {
          channelData[channel][index] = samples[index * channels + channel]
        }
      }

      condition.lock()
      while running && !aborted
        && pendingFrames + Int64(frameCount) > maxBufferedFrames
      {
        condition.wait()
      }
      if aborted || !running {
        let wasAborted = aborted
        condition.unlock()
        throw PigeonError(
          code: wasAborted ? "PlaybackAborted" : "PlaybackNotRunning",
          message: wasAborted ? "Playback was aborted" : "Playback was stopped",
          details: nil
        )
      }
      pendingFrames += Int64(frameCount)
      condition.unlock()

      lifecycle.lock()
      condition.lock()
      let canSchedule = running && !aborted
      let wasAborted = aborted
      if !canSchedule {
        pendingFrames = max(pendingFrames - Int64(frameCount), 0)
        condition.broadcast()
      }
      condition.unlock()
      guard canSchedule else {
        lifecycle.unlock()
        throw PigeonError(
          code: wasAborted ? "PlaybackAborted" : "PlaybackNotRunning",
          message: wasAborted ? "Playback was aborted" : "Playback was stopped",
          details: nil
        )
      }
      player.scheduleBuffer(buffer) { [weak self] in
        guard let self else { return }
        self.condition.lock()
        self.pendingFrames = max(
          self.pendingFrames - Int64(frameCount),
          0
        )
        self.condition.broadcast()
        self.condition.unlock()
      }
      lifecycle.unlock()
    }
  }

  func finish() {
    condition.lock()
    while !aborted && pendingFrames > 0 {
      condition.wait()
    }
    let shouldStop = !aborted
    condition.unlock()
    if shouldStop {
      stop()
    }
  }

  func abort() {
    lifecycle.lock()
    defer { lifecycle.unlock() }
    condition.lock()
    aborted = true
    pendingFrames = 0
    condition.broadcast()
    condition.unlock()
    stopEngineLocked()
  }

  private func stop() {
    lifecycle.lock()
    defer { lifecycle.unlock() }
    stopEngineLocked()
  }

  private func stopEngineLocked() {
    condition.lock()
    let wasRunning = running
    running = false
    condition.broadcast()
    condition.unlock()
    guard wasRunning || playerAttached else { return }
    player.stop()
    engine.stop()
    if playerAttached {
      engine.detach(player)
      playerAttached = false
    }
    events.emit(
      AudioSessionEventMessage(sessionId: sessionId, phase: .stopped)
    )
  }

  deinit {
    abort()
  }
}
