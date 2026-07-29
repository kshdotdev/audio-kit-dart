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
  private let running = OSAllocatedUnfairLock(initialState: false)
  private let failureScheduled = OSAllocatedUnfairLock(initialState: false)
  #if os(macOS)
    private let holdsActivity = OSAllocatedUnfairLock(initialState: false)
  #endif
  private var assembler: CaptureFrameAssembler?
  private var converter: PersistentAudioConverter?
  private var recorder: RawAudioRecorder?
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
    let inputFormat = input.outputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
      [weak self] buffer, time in
      guard let self, self.running.withLock({ $0 }) else { return }
      guard let copy = AudioBufferCopy.copy(buffer) else { return }
      let timestampMicros =
        time.isHostTimeValid
        ? MonotonicClock.microseconds(hostTime: time.hostTime)
        : MonotonicClock.microseconds()
      self.enqueue(copy, timestampMicros: timestampMicros)
    }
    running.withLock { $0 = true }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      running.withLock { $0 = false }
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
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard let self, self.running.withLock({ $0 }), let assembler = self.assembler
      else { return }
      let statistics = assembler.statistics()
      self.events.emit(
        AudioSessionEventMessage(
          sessionId: self.sessionId,
          phase: .running,
          message: statistics.nonZeroFrameCount > 0
            ? nil
            : "Microphone is active but has not produced non-zero audio",
          receivingAudio: statistics.nonZeroFrameCount > 0,
          callbackCount: statistics.callbackCount
        )
      )
    }
  }

  func stop(discardBuffered: Bool = false) {
    lifecycle.lock()
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
    events.emit(
      AudioSessionEventMessage(
        sessionId: sessionId,
        phase: .failed,
        code: code,
        message: message,
        receivingAudio: false
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
