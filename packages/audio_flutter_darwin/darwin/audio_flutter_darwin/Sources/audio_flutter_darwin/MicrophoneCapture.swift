import AVFoundation
import Foundation
import os

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import AudioToolbox
  import CoreAudio
  import FlutterMacOS
#endif

final class MicrophoneCaptureSession: NativeCaptureSession {
  let sessionId: Int64
  let format: PcmFormatMessage
  let mailbox: FrameMailbox

  private let request: CaptureRequestMessage
  private let events: SessionEventsHandler
  private let engine = AVAudioEngine()
  private let workerQueue = DispatchQueue(
    label: "audio_flutter.microphone.worker",
    qos: .userInitiated
  )
  private let workRing: CaptureWorkRing
  private let lifecycle = NSLock()
  private let running = CompatibleUnfairLock(initialState: false)
  private let failureScheduled = CompatibleUnfairLock(initialState: false)
  #if os(macOS)
    private let holdsActivity = CompatibleUnfairLock(initialState: false)
  #endif
  private let renderCycles = CompatibleUnfairLock(initialState: Int64(0))
  /// Serial queue every tap reinstall runs on, so a burst of configuration
  /// changes cannot reinstall concurrently and the posting thread is never
  /// blocked by the rebuild it triggered.
  private let reconfigureQueue = DispatchQueue(
    label: "audio_flutter.microphone.reconfigure",
    qos: .userInitiated
  )
  /// Bumped by every completed tap reinstall. The delivery watchdog reads it to
  /// tell "this chain was just rebuilt" from "this chain is dead".
  private let tapGeneration = CompatibleUnfairLock(initialState: Int64(0))
  private var assembler: CaptureFrameAssembler?
  private var converter: PersistentAudioConverter?
  private var recorder: RawAudioRecorder?
  /// Hardware format the open `recorder` file was created for. A WAV file
  /// carries one format, so a mid-capture hardware transition ends it.
  private var recorderFormat: AVAudioFormat?
  private var configurationObserver: NSObjectProtocol?
  private var watchdog: Task<Void, Never>?

  init(
    sessionId: Int64,
    request: CaptureRequestMessage,
    events: SessionEventsHandler
  ) throws {
    self.sessionId = sessionId
    self.request = request
    self.events = events
    format = request.outputFormat
    workRing = CaptureWorkRing(
      maximumDurationMicros: request.maxBufferedDurationMicros,
      // Source-native recording must never silently omit callback audio.
      overflowPolicy: request.rawRecordingPath == nil
        ? request.overflowPolicy
        : .failCapture
    )

    let frameDuration = max(request.frameDurationMicros, 1)
    let capacity = max(
      Int(request.maxBufferedDurationMicros / frameDuration),
      1
    )
    mailbox = FrameMailbox(capacity: capacity, overflowPolicy: request.overflowPolicy)

    #if os(macOS)
      if let uid = request.inputDeviceId, !uid.isEmpty,
        !AudioInputDeviceSelection.apply(uid: uid, to: engine)
      {
        throw PigeonError(
          code: "InputDeviceUnavailable",
          message: "The selected audio input device is unavailable.",
          details: nil
        )
      }
    #elseif os(iOS)
      if let uid = request.inputDeviceId, !uid.isEmpty {
        let session = AVAudioSession.sharedInstance()
        guard
          let input = session.availableInputs?.first(where: { $0.uid == uid })
        else {
          throw PigeonError(
            code: "InputDeviceUnavailable",
            message: "The selected audio input device is unavailable.",
            details: nil
          )
        }
        try session.setPreferredInput(input)
      }
    #endif
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard
      let converter = PersistentAudioConverter(
        inputFormat: inputFormat,
        sampleRate: Double(request.outputFormat.sampleRate),
        channelCount: AVAudioChannelCount(request.outputFormat.channelCount)
      )
    else {
      throw PigeonError(
        code: "ConverterUnavailable",
        message: "Could not convert microphone format \(inputFormat)",
        details: nil
      )
    }
    self.converter = converter
    assembler = CaptureFrameAssembler(
      sessionId: sessionId,
      sampleRate: Int(request.outputFormat.sampleRate),
      channelCount: Int(request.outputFormat.channelCount),
      frameDurationMicros: request.frameDurationMicros,
      mailbox: mailbox
    )
    if let path = request.rawRecordingPath {
      recorder = try RawAudioRecorder(path: path, inputFormat: inputFormat)
      recorderFormat = inputFormat
    }
  }

  func start() throws {
    lifecycle.lock()
    defer { lifecycle.unlock() }
    guard !running.withLock({ $0 }) else { return }
    #if os(iOS)
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.defaultToSpeaker, .allowBluetoothHFP]
      )
      try audioSession.setActive(true)
    #endif

    let input = engine.inputNode
    // Selecting the input device during prepare (and a Bluetooth HFP
    // transition) can change the node's format after the prepare-time
    // converter was built; a stale-rate converter passes 24 kHz buffers
    // through labeled 48 kHz — the 2x "chipmunk" recording. Read the format
    // once here and rebuild the converter from that same read, so the
    // converter and the tap can never disagree.
    let liveFormat = input.outputFormat(forBus: 0)
    guard
      liveFormat.sampleRate > 0,
      liveFormat.channelCount > 0,
      let liveConverter = PersistentAudioConverter(
        inputFormat: liveFormat,
        sampleRate: Double(request.outputFormat.sampleRate),
        channelCount: AVAudioChannelCount(request.outputFormat.channelCount)
      )
    else {
      throw PigeonError(
        code: "ConverterUnavailable",
        message: "Could not convert microphone format \(liveFormat)",
        details: nil
      )
    }
    converter = liveConverter
    if closeRecorderIfFormatChangedLocked(to: liveFormat),
      let path = request.rawRecordingPath
    {
      // Unlike a mid-capture change, nothing has been written yet: reopening
      // at the live format keeps the source-native recording instead of
      // ending it before it began.
      recorder = try RawAudioRecorder(path: path, inputFormat: liveFormat)
      recorderFormat = liveFormat
    }
    installTapLocked(format: liveFormat)
    // Registered before start so the configuration change that engine.start()
    // itself provokes is delivered instead of racing the registration.
    observeConfigurationChangesLocked()
    running.withLock { $0 = true }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      running.withLock { $0 = false }
      removeConfigurationObserverLocked()
      input.removeTap(onBus: 0)
      engine.stop()
      workRing.finish(discardBuffered: true)
      workerQueue.sync {}
      mailbox.finish(discardBuffered: true)
      #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
          false,
          options: .notifyOthersOnDeactivation
        )
      #endif
      throw error
    }
    setActivityHold(true)
    events.emit(
      AudioSessionEventMessage(
        sessionId: sessionId,
        phase: .running,
        receivingAudio: false,
        callbackCount: 0
      )
    )
    watchdog = Task { [weak self] in
      await self?.superviseDelivery()
    }
  }

  /// Installs the capture tap for `format` on the input bus.
  ///
  /// Called with `lifecycle` held from both the initial start and every
  /// reinstall, so the callback body exists once and both paths count render
  /// cycles the same way.
  private func installTapLocked(format: AVAudioFormat) {
    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
      [weak self] buffer, time in
      guard let self, self.running.withLock({ $0 }) else { return }
      self.renderCycles.withLock { $0 += 1 }
      guard let copy = AudioBufferCopy.copy(buffer) else { return }
      let timestampMicros =
        time.isHostTimeValid
        ? MonotonicClock.microseconds(hostTime: time.hostTime)
        : MonotonicClock.microseconds()
      self.enqueue(copy, timestampMicros: timestampMicros)
    }
  }

  private static let supervisionWindowNanos: UInt64 = 2_000_000_000

  /// Consecutive silent windows tolerated while the input node keeps reporting
  /// no usable format, so a device that never returns still ends the session
  /// instead of supervising forever.
  private static let maximumUnusableFormatWindows = 5

  /// Supervises input-tap delivery and repairs a tap that never attached.
  ///
  /// `AVAudioEngine.start()` succeeds even when `installTap` lost a race with a
  /// hardware format transition — the HAL logs a format mismatch and refuses
  /// the tap, the engine reports no error, and the session records zero frames.
  /// A started engine therefore proves nothing; one delivered buffer does.
  ///
  /// Silence is health, never failure: a muted or very quiet microphone is
  /// legitimate, so only the total absence of buffers is fatal, and only
  /// through one of two exhaustion conditions:
  ///
  /// - A rebuild that actually happened, followed by another silent window.
  ///   The chain was repaired against a freshly read format and still delivers
  ///   nothing, so it is dead (`MicrophoneCaptureDead`).
  /// - `maximumUnusableFormatWindows` consecutive windows in which the input
  ///   node never presented a usable format, so no rebuild could even be
  ///   attempted. The device is gone rather than broken
  ///   (`MicrophoneInputFormatUnavailable`).
  ///
  /// A rebuild skipped for want of a usable format therefore costs nothing
  /// from the single-rebuild budget — nothing was repaired, so nothing was
  /// proven — and a configuration-change recovery that rebuilds the tap inside
  /// a window restarts supervision outright, clearing both counters. Neither
  /// can fail a session that is merely mid-transition, which is exactly the
  /// state a Bluetooth headset moving between its call and media profiles
  /// spends several windows in.
  private func superviseDelivery() async {
    var rebuilt = false
    var reportedSilence = false
    var reportedMissingFormat = false
    var unusableFormatWindows = 0
    var generation = tapGeneration.withLock { $0 }
    while !Task.isCancelled, running.withLock({ $0 }) {
      try? await Task.sleep(nanoseconds: Self.supervisionWindowNanos)
      guard !Task.isCancelled, running.withLock({ $0 }) else { return }
      let statistics = assembler?.statistics()
      if renderCycles.withLock({ $0 }) > 0 {
        let receiving = (statistics?.nonZeroFrameCount ?? 0) > 0
        events.emit(
          healthEvent(
            phase: .running,
            message: receiving
              ? nil : "Microphone is active but has not produced non-zero audio",
            receivingAudio: receiving,
            statistics: statistics
          )
        )
        return
      }
      let current = tapGeneration.withLock { $0 }
      if current != generation {
        // The tap was rebuilt inside this window by a configuration-change
        // recovery. Judge the new chain on a window of its own rather than on
        // the dead one it replaced.
        generation = current
        unusableFormatWindows = 0
        continue
      }
      if rebuilt {
        fail(
          code: "MicrophoneCaptureDead",
          message:
            "The microphone input tap never delivered a buffer, including "
            + "after a rebuild against the current hardware format."
        )
        return
      }
      if !reportedSilence {
        reportedSilence = true
        events.emit(
          healthEvent(
            phase: .interrupted,
            code: "MicrophoneTapSilent",
            message:
              "The microphone tap has delivered no audio; rebuilding it "
              + "against the current hardware format.",
            receivingAudio: false,
            statistics: statistics
          )
        )
      }
      switch reinstallTap() {
      case .failed:
        // The rebuild already failed the session.
        return
      case .reinstalled:
        rebuilt = true
        unusableFormatWindows = 0
        generation = tapGeneration.withLock { $0 }
      case .skipped:
        // Nothing was torn down or rebuilt: the input node reports no usable
        // format yet, or the session is stopping. The one rebuild is still
        // owed, so the budget stays intact and only the bounded wait advances.
        unusableFormatWindows += 1
        if unusableFormatWindows >= Self.maximumUnusableFormatWindows {
          fail(
            code: "MicrophoneInputFormatUnavailable",
            message:
              "The microphone input device never presented a usable format, "
              + "so the capture tap could not be rebuilt."
          )
          return
        }
        if !reportedMissingFormat {
          reportedMissingFormat = true
          events.emit(
            healthEvent(
              phase: .interrupted,
              code: "MicrophoneAwaitingInputFormat",
              message:
                "The microphone input device reports no usable format yet; "
                + "waiting for the hardware transition to settle.",
              receivingAudio: false,
              statistics: statistics
            )
          )
        }
      }
    }
  }

  /// One health event carrying the current statistics snapshot. Built only
  /// where health is already emitted, so widening the payload does not raise
  /// the event rate.
  private func healthEvent(
    phase: AudioSessionPhaseMessage,
    code: String? = nil,
    message: String? = nil,
    receivingAudio: Bool,
    statistics: CaptureStatistics?
  ) -> AudioSessionEventMessage {
    AudioSessionEventMessage(
      sessionId: sessionId,
      phase: phase,
      code: code,
      message: message,
      receivingAudio: receivingAudio,
      callbackCount: statistics?.callbackCount,
      peakAmplitude: statistics?.peakAmplitude,
      rms: statistics?.rms,
      nonZeroFramePercent: statistics?.nonZeroFramePercent,
      renderCycles: renderCycles.withLock { $0 },
      firstAudioAtMillis: statistics.flatMap { $0.firstAudioAtMillis }
    )
  }

  private enum TapReinstallOutcome {
    /// The tap was reinstalled against a freshly read hardware format.
    case reinstalled
    /// Nothing was changed: the session is stopping, or the input node reports
    /// no usable format yet and the existing tap is the better of the two.
    case skipped
    /// The reinstall could not complete and the session has been failed.
    case failed
  }

  /// Reacts to `AVAudioEngineConfigurationChange` for this engine.
  ///
  /// Runs on whichever thread AVAudioEngine posted from and returns
  /// immediately: the rebuild takes `lifecycle`, which teardown also holds.
  private func handleConfigurationChange() {
    guard running.withLock({ $0 }) else { return }
    reconfigureQueue.async { [weak self] in
      guard let self, self.running.withLock({ $0 }) else { return }
      guard case .reinstalled = self.reinstallTap() else { return }
      self.events.emit(
        self.healthEvent(
          phase: .interrupted,
          code: "MicrophoneInputFormatChanged",
          message:
            "The microphone hardware configuration changed; the input tap was "
            + "reinstalled against the new format.",
          receivingAudio: false,
          statistics: self.assembler?.statistics()
        )
      )
    }
  }

  /// Rebuilds the tap and its converter against the format the input node
  /// reports right now.
  ///
  /// A hardware transition (a Bluetooth headset moving between its 24 kHz
  /// call profile and the 48 kHz built-in input) leaves the engine stopped and
  /// the old tap detached or mismatched, so the format is re-read, the
  /// converter rebuilt for it, and the engine restarted. The format is read
  /// before anything is torn down: a node reporting no format yet is
  /// mid-transition, and the tap already installed is worth more than none.
  ///
  /// Must be called without `lifecycle` held.
  private func reinstallTap() -> TapReinstallOutcome {
    lifecycle.lock()
    guard running.withLock({ $0 }) else {
      lifecycle.unlock()
      return .skipped
    }
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      lifecycle.unlock()
      return .skipped
    }
    guard
      let converter = PersistentAudioConverter(
        inputFormat: inputFormat,
        sampleRate: Double(request.outputFormat.sampleRate),
        channelCount: AVAudioChannelCount(request.outputFormat.channelCount)
      )
    else {
      lifecycle.unlock()
      fail(
        code: "ConverterUnavailable",
        message: "Could not convert microphone format \(inputFormat)"
      )
      return .failed
    }

    input.removeTap(onBus: 0)
    // No callback can enqueue past this point, so draining the worker leaves
    // the converter, recorder, and assembler free to be swapped.
    workerQueue.sync {}
    self.converter = converter
    // The host-time clock survives the rebuild, so the next buffer reports the
    // gap as a source restart instead of being spliced onto pre-change audio.
    assembler?.markSourceRestart()
    let recordingEnded = closeRecorderIfFormatChangedLocked(to: inputFormat)
    installTapLocked(format: inputFormat)
    var startError: Error?
    if !engine.isRunning {
      engine.prepare()
      do {
        try engine.start()
      } catch {
        startError = error
      }
    }
    tapGeneration.withLock { $0 += 1 }
    lifecycle.unlock()

    if let startError {
      fail(
        code: "MicrophoneEngineRestartFailed",
        message:
          "The audio engine could not restart after a microphone "
          + "configuration change: \(startError.localizedDescription)"
      )
      return .failed
    }
    if recordingEnded {
      events.emit(
        healthEvent(
          phase: .interrupted,
          code: "MicrophoneRecordingFormatChanged",
          message:
            "Source-native recording stopped: the microphone hardware format "
            + "changed mid-capture and a single file cannot carry both.",
          receivingAudio: false,
          statistics: assembler?.statistics()
        )
      )
    }
    return .reinstalled
  }

  /// Ends source-native recording when the hardware format no longer matches
  /// the open file, returning whether it did.
  ///
  /// Writing a mismatched buffer to an `AVAudioFile` is an error, and failing
  /// the whole session over an auxiliary recording would cost the capture far
  /// more than the truncated file does.
  private func closeRecorderIfFormatChangedLocked(
    to inputFormat: AVAudioFormat
  ) -> Bool {
    guard recorder != nil, let recorderFormat else { return false }
    guard
      recorderFormat.sampleRate != inputFormat.sampleRate
        || recorderFormat.channelCount != inputFormat.channelCount
        || recorderFormat.commonFormat != inputFormat.commonFormat
        || recorderFormat.isInterleaved != inputFormat.isInterleaved
    else { return false }
    recorder?.close()
    recorder = nil
    self.recorderFormat = nil
    return true
  }

  private func observeConfigurationChangesLocked() {
    guard configurationObserver == nil else { return }
    configurationObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      self?.handleConfigurationChange()
    }
  }

  private func removeConfigurationObserverLocked() {
    guard let observer = configurationObserver else { return }
    NotificationCenter.default.removeObserver(observer)
    configurationObserver = nil
  }

  func stop(discardBuffered: Bool = false) {
    lifecycle.lock()
    removeConfigurationObserverLocked()
    let wasRunning = running.withLock { $0 }
    if discardBuffered {
      running.withLock { $0 = false }
    }
    if wasRunning {
      watchdog?.cancel()
      watchdog = nil
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    workRing.finish(discardBuffered: discardBuffered)
    workerQueue.sync {}
    recorder?.close()
    recorder = nil
    recorderFormat = nil
    running.withLock { $0 = false }
    setActivityHold(false)
    let failed = failureScheduled.withLock { $0 }
    mailbox.finish(discardBuffered: discardBuffered || failed)
    #if os(iOS)
      if wasRunning {
        try? AVAudioSession.sharedInstance().setActive(
          false,
          options: .notifyOthersOnDeactivation
        )
      }
    #endif
    lifecycle.unlock()
    if wasRunning, !discardBuffered, !failed {
      emitTrailingDropHealth()
    }
    if wasRunning, !failed {
      events.emit(
        AudioSessionEventMessage(
          sessionId: sessionId,
          phase: .stopped,
          receivingAudio: false
        )
      )
    }
  }

  func fail(code: String, message: String) {
    guard running.withLock({ $0 }) else { return }
    let shouldSchedule = failureScheduled.withLock { scheduled in
      guard !scheduled else { return false }
      scheduled = true
      return true
    }
    guard shouldSchedule else { return }
    workRing.finish(discardBuffered: true)
    // The failure event is the one a host will debug from, so it carries the
    // full statistics snapshot — renderCycles separates a tap that never
    // attached from one whose buffers died downstream.
    events.emit(
      healthEvent(
        phase: .failed,
        code: code,
        message: message,
        receivingAudio: false,
        statistics: assembler?.statistics()
      )
    )
    // Failure can originate on `workerQueue`. Teardown waits for that queue to
    // drain, so hand it to an independent lifecycle executor.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.stop(discardBuffered: true)
    }
  }

  /// Holds the process-wide App Nap assertion while this session captures.
  /// Idempotent, so repeated stops and `deinit` cannot unbalance the refcount.
  /// No-op on iOS, which has no App Nap.
  private func setActivityHold(_ held: Bool) {
    #if os(macOS)
      let changed = holdsActivity.withLock { current -> Bool in
        guard current != held else { return false }
        current = held
        return true
      }
      guard changed else { return }
      if held {
        CaptureActivity.shared.acquire()
      } else {
        CaptureActivity.shared.release()
      }
    #endif
  }

  deinit {
    stop(discardBuffered: true)
  }

  private func enqueue(
    _ buffer: AVAudioPCMBuffer,
    timestampMicros: Int64
  ) {
    let result = workRing.enqueue(
      CaptureWorkItem(buffer: buffer, timestampMicros: timestampMicros),
      schedulePump: {
        self.workerQueue.async { [weak self] in
          self?.drainWork()
        }
      }
    )
    switch result {
    case .accepted:
      break
    case .droppedNewest, .closed:
      break
    case .failed:
      fail(
        code: "CaptureWorkerOverflow",
        message: "The bounded microphone conversion queue overflowed."
      )
    }
  }

  private func drainWork() {
    while let work = workRing.takeNext() {
      var resetConverter = false
      if work.droppedDurationMicrosBefore > 0 {
        assembler?.noteDropped(
          durationMicros: work.droppedDurationMicrosBefore,
          startTimestampMicros: work.droppedStartTimestampMicros
        )
        resetConverter = true
      }
      if assembler?.prepareInput(timestampMicros: work.timestampMicros) == true {
        resetConverter = true
      }
      if resetConverter {
        converter?.reset()
      }
      do {
        try recorder?.write(work.buffer)
      } catch {
        fail(code: "RecordingWriteFailed", message: error.localizedDescription)
        return
      }
      guard
        let converted = converter?.convert(work.buffer),
        !converted.isEmpty
      else { continue }
      if assembler?.push(
        converted,
        timestampMicros: work.timestampMicros
      ) == false {
        fail(
          code: "CaptureMailboxOverflow",
          message: "The bounded microphone mailbox overflowed."
        )
        return
      }
    }
  }

  private func emitTrailingDropHealth() {
    let nativeDuration = workRing.trailingDroppedDurationMicros()
    let dartFrames = mailbox.trailingDroppedFrameCount()
    guard nativeDuration > 0 || dartFrames > 0 else { return }
    events.emit(
      AudioSessionEventMessage(
        sessionId: sessionId,
        phase: .interrupted,
        code: "CaptureTrailingAudioDropped",
        message:
          "Capture ended after dropping \(nativeDuration) microseconds "
          + "before conversion and \(dartFrames) converted frames.",
        receivingAudio: false
      )
    )
  }
}

#if os(macOS)
  enum AudioInputDeviceSelection {
    static func apply(uid: String?, to engine: AVAudioEngine) -> Bool {
      guard let uid, !uid.isEmpty, let device = deviceId(for: uid) else { return false }
      guard let unit = engine.inputNode.audioUnit else { return false }
      var value = device
      let status = AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &value,
        UInt32(MemoryLayout<AudioDeviceID>.size)
      )
      return status == noErr
    }

    static func listDevices() -> [AudioInputDeviceMessage] {
      let defaultDevice = defaultInputDevice()
      return deviceIds().compactMap { device in
        guard hasInputStreams(device),
          let uid = stringProperty(
            device,
            selector: kAudioDevicePropertyDeviceUID
          ),
          let label = stringProperty(
            device,
            selector: kAudioObjectPropertyName
          )
        else { return nil }
        return AudioInputDeviceMessage(
          id: uid,
          label: label,
          isDefault: device == defaultDevice
        )
      }
    }

    private static func deviceId(for uid: String) -> AudioDeviceID? {
      deviceIds().first {
        stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid
      }
    }

    private static func deviceIds() -> [AudioDeviceID] {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var size: UInt32 = 0
      guard
        AudioObjectGetPropertyDataSize(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          &size
        ) == noErr
      else { return [] }
      var devices = [AudioDeviceID](
        repeating: 0,
        count: Int(size) / MemoryLayout<AudioDeviceID>.size
      )
      guard
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          &size,
          &devices
        ) == noErr
      else { return [] }
      return devices
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var device = AudioDeviceID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      guard
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          &size,
          &device
        ) == noErr,
        device != AudioDeviceID(kAudioObjectUnknown)
      else { return nil }
      return device
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
      )
      var size: UInt32 = 0
      return AudioObjectGetPropertyDataSize(
        device,
        &address,
        0,
        nil,
        &size
      ) == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func stringProperty(
      _ device: AudioDeviceID,
      selector: AudioObjectPropertySelector
    ) -> String? {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var value: Unmanaged<CFString>?
      var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      let status = AudioObjectGetPropertyData(
        device,
        &address,
        0,
        nil,
        &size,
        &value
      )
      guard status == noErr, let value else { return nil }
      return value.takeRetainedValue() as String
    }
  }
#endif

enum AudioInputDevices {
  static func list() -> [AudioInputDeviceMessage] {
    #if os(macOS)
      return AudioInputDeviceSelection.listDevices()
    #elseif os(iOS)
      let session = AVAudioSession.sharedInstance()
      let inputs = session.availableInputs ?? []
      let selectedUid =
        session.preferredInput?.uid ?? session.currentRoute.inputs.first?.uid
      return inputs.map { input in
        AudioInputDeviceMessage(
          id: input.uid,
          label: input.portName,
          isDefault: input.uid == selectedUid
        )
      }
    #endif
  }
}
