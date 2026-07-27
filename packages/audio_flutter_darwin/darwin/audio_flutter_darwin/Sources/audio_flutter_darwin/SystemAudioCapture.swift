import AVFoundation
import Foundation
import os

#if os(macOS)
  import CoreAudio
  import FlutterMacOS

  /// Core Audio process-tap capture for macOS 14.4 and newer.
  @available(macOS 14.4, *)
  final class SystemAudioCaptureSession: NativeCaptureSession {
    let sessionId: Int64
    let format: PcmFormatMessage
    let mailbox: FrameMailbox

    private let request: CaptureRequestMessage
    private let events: SessionEventsHandler
    private let ioQueue = DispatchQueue(
      label: "audio_flutter.system_capture",
      qos: .userInitiated
    )
    private let workerQueue = DispatchQueue(
      label: "audio_flutter.system_capture.worker",
      qos: .userInitiated
    )
    private let workRing: CaptureWorkRing
    private let lifecycle = NSLock()
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let failureScheduled = OSAllocatedUnfairLock(initialState: false)
    private var tapId = AudioObjectID(kAudioObjectUnknown)
    private var aggregateId = AudioObjectID(kAudioObjectUnknown)
    private var ioProcId: AudioDeviceIOProcID?
    private var assembler: CaptureFrameAssembler
    private var converter: PersistentAudioConverter?
    private var recorder: RawAudioRecorder?
    private var watchdog: Task<Void, Never>?

    init(
      sessionId: Int64,
      request: CaptureRequestMessage,
      events: SessionEventsHandler
    ) {
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
      let mailbox = FrameMailbox(
        capacity: capacity,
        overflowPolicy: request.overflowPolicy
      )
      self.mailbox = mailbox
      assembler = CaptureFrameAssembler(
        sessionId: sessionId,
        sampleRate: Int(request.outputFormat.sampleRate),
        channelCount: Int(request.outputFormat.channelCount),
        frameDurationMicros: request.frameDurationMicros,
        mailbox: mailbox
      )
    }

    func start() throws {
      lifecycle.lock()
      defer { lifecycle.unlock() }
      guard !running.withLock({ $0 }) else { return }
      running.withLock { $0 = true }
      do {
        try startChainLocked()
      } catch {
        running.withLock { $0 = false }
        workRing.finish(discardBuffered: true)
        workerQueue.sync {}
        unwindLocked()
        throw error
      }
      events.emit(
        AudioSessionEventMessage(
          sessionId: sessionId,
          phase: .running,
          receivingAudio: false,
          callbackCount: 0
        )
      )
      let initialStatistics = assembler.statistics()
      let initialCallbacks = initialStatistics.callbackCount
      let initialNonZero = initialStatistics.nonZeroFrameCount
      watchdog = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let self, self.running.withLock({ $0 }) else { return }
        let currentStatistics = self.assembler.statistics()
        if currentStatistics.nonZeroFrameCount > initialNonZero {
          self.events.emit(
            AudioSessionEventMessage(
              sessionId: self.sessionId,
              phase: .running,
              receivingAudio: true,
              callbackCount: currentStatistics.callbackCount
            )
          )
          return
        }

        // Electron/Chromium helper processes may become tappable after start.
        // Rebuild once using a fresh PID translation before declaring failure.
        self.events.emit(
          AudioSessionEventMessage(
            sessionId: self.sessionId,
            phase: .interrupted,
            message: "System capture is silent; rebuilding its process tap once.",
            receivingAudio: false,
            callbackCount: currentStatistics.callbackCount
          )
        )
        guard self.rebuild() else { return }
        let rebuiltStatistics = self.assembler.statistics()
        let rebuiltCallbacks = rebuiltStatistics.callbackCount
        let rebuiltNonZero = rebuiltStatistics.nonZeroFrameCount
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard self.running.withLock({ $0 }) else { return }
        let finalStatistics = self.assembler.statistics()
        let callbacksAdvanced = finalStatistics.callbackCount > rebuiltCallbacks
        let audioAdvanced = finalStatistics.nonZeroFrameCount > rebuiltNonZero
        if callbacksAdvanced {
          self.events.emit(
            AudioSessionEventMessage(
              sessionId: self.sessionId,
              phase: .running,
              message: audioAdvanced ? nil : "System tap is alive but currently silent.",
              receivingAudio: audioAdvanced,
              callbackCount: finalStatistics.callbackCount
            )
          )
        } else {
          self.fail(
            code: "SystemCaptureDead",
            message:
              "System audio delivered no callbacks after a one-shot rebuild "
              + "(initial callbacks: \(initialCallbacks))."
          )
        }
      }
    }

    private func rebuild() -> Bool {
      lifecycle.lock()
      defer { lifecycle.unlock() }
      guard running.withLock({ $0 }) else { return false }
      teardownChainLocked()
      assembler.markSourceRestart()
      do {
        try startChainLocked()
        return true
      } catch {
        running.withLock { $0 = false }
        workRing.finish(discardBuffered: true)
        workerQueue.sync {}
        recorder?.close()
        recorder = nil
        mailbox.finish(discardBuffered: true)
        events.emit(
          AudioSessionEventMessage(
            sessionId: sessionId,
            phase: .failed,
            code: "SystemCaptureRebuildFailed",
            message: error.localizedDescription,
            receivingAudio: false
          )
        )
        return false
      }
    }

    private func startChainLocked() throws {
      let description: CATapDescription
      if request.processIds.isEmpty {
        let ownProcess = Self.translatePid(getpid())
        let excluded =
          ownProcess == AudioObjectID(kAudioObjectUnknown) ? [] : [ownProcess]
        description = CATapDescription(
          stereoGlobalTapButExcludeProcesses: excluded
        )
      } else {
        let objects = request.processIds.compactMap { value -> AudioObjectID? in
          guard let pid = pid_t(exactly: value) else { return nil }
          let object = Self.translatePid(pid)
          return object == AudioObjectID(kAudioObjectUnknown) ? nil : object
        }
        guard !objects.isEmpty else {
          throw PigeonError(
            code: "NoTappableProcess",
            message:
              "None of the selected processes currently owns a Core Audio "
              + "process object.",
            details: nil
          )
        }
        description = CATapDescription(stereoMixdownOfProcesses: objects)
      }
      description.name = "audio_flutter system capture"
      description.isPrivate = true
      description.muteBehavior = .unmuted

      var tap = AudioObjectID(kAudioObjectUnknown)
      var status = AudioHardwareCreateProcessTap(description, &tap)
      guard status == noErr else {
        throw PigeonError(
          code: "TapCreateFailed",
          message: "AudioHardwareCreateProcessTap failed (\(status)).",
          details: nil
        )
      }
      tapId = tap

      let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey as String: "audio_flutter aggregate",
        kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey as String: true,
        kAudioAggregateDeviceTapAutoStartKey as String: true,
        kAudioAggregateDeviceTapListKey as String: [
          [kAudioSubTapUIDKey as String: description.uuid.uuidString]
        ],
      ]
      var aggregate = AudioObjectID(kAudioObjectUnknown)
      status = AudioHardwareCreateAggregateDevice(
        aggregateDescription as CFDictionary,
        &aggregate
      )
      guard status == noErr else {
        unwindLocked()
        throw PigeonError(
          code: "AggregateCreateFailed",
          message: "AudioHardwareCreateAggregateDevice failed (\(status)).",
          details: nil
        )
      }
      aggregateId = aggregate

      guard let inputFormat = Self.tapFormat(tapId) else {
        unwindLocked()
        throw PigeonError(
          code: "TapFormatUnavailable",
          message: "Could not read the process tap format.",
          details: nil
        )
      }
      guard
        let converter = PersistentAudioConverter(
          inputFormat: inputFormat,
          sampleRate: Double(request.outputFormat.sampleRate),
          channelCount: AVAudioChannelCount(request.outputFormat.channelCount)
        )
      else {
        unwindLocked()
        throw PigeonError(
          code: "ConverterUnavailable",
          message: "Could not convert the process tap format.",
          details: nil
        )
      }
      self.converter = converter
      if recorder == nil, let path = request.rawRecordingPath {
        recorder = try RawAudioRecorder(path: path, inputFormat: inputFormat)
      }

      var proc: AudioDeviceIOProcID?
      status = AudioDeviceCreateIOProcIDWithBlock(
        &proc,
        aggregateId,
        ioQueue
      ) { [weak self] now, inputData, inputTime, _, _ in
        guard let self, self.running.withLock({ $0 }) else { return }
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            bufferListNoCopy: inputData,
            deallocator: nil
          ),
          buffer.frameLength > 0,
          let copy = AudioBufferCopy.copy(buffer)
        else { return }
        let inputFlags = inputTime.pointee.mFlags
        let nowFlags = now.pointee.mFlags
        let hostTime: UInt64?
        if inputFlags.contains(.hostTimeValid) {
          hostTime = inputTime.pointee.mHostTime
        } else if nowFlags.contains(.hostTimeValid) {
          hostTime = now.pointee.mHostTime
        } else {
          hostTime = nil
        }
        self.enqueue(
          copy,
          timestampMicros: MonotonicClock.microseconds(hostTime: hostTime)
        )
      }
      guard status == noErr, let proc else {
        unwindLocked()
        throw PigeonError(
          code: "IOProcCreateFailed",
          message: "AudioDeviceCreateIOProcIDWithBlock failed (\(status)).",
          details: nil
        )
      }
      ioProcId = proc
      status = AudioDeviceStart(aggregateId, proc)
      guard status == noErr else {
        unwindLocked()
        throw PigeonError(
          code: "DeviceStartFailed",
          message: "AudioDeviceStart failed (\(status)).",
          details: nil
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
        teardownChainLocked(
          discardPendingWork: discardBuffered,
          finishWork: true
        )
      } else {
        workRing.finish(discardBuffered: discardBuffered)
        workerQueue.sync {}
      }
      recorder?.close()
      recorder = nil
      running.withLock { $0 = false }
      let failed = failureScheduled.withLock { $0 }
      lifecycle.unlock()
      mailbox.finish(discardBuffered: discardBuffered || failed)
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

    private func fail(code: String, message: String) {
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
      // The IO callback runs on `ioQueue`, while teardown drains that same
      // queue. Dispatch lifecycle work elsewhere to avoid self-deadlock.
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.stop(discardBuffered: true)
      }
    }

    private func teardownChainLocked(
      discardPendingWork: Bool = false,
      finishWork: Bool = false
    ) {
      if let proc = ioProcId {
        AudioDeviceStop(aggregateId, proc)
        ioQueue.sync {}
      }
      if finishWork {
        workRing.finish(discardBuffered: discardPendingWork)
      }
      workerQueue.sync {}
      unwindLocked()
      converter = nil
    }

    private func unwindLocked() {
      if let proc = ioProcId {
        AudioDeviceDestroyIOProcID(aggregateId, proc)
        ioProcId = nil
      }
      if aggregateId != AudioObjectID(kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(aggregateId)
        aggregateId = AudioObjectID(kAudioObjectUnknown)
      }
      if tapId != AudioObjectID(kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(tapId)
        tapId = AudioObjectID(kAudioObjectUnknown)
      }
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
          message: "The bounded system-audio conversion queue overflowed."
        )
      }
    }

    private func drainWork() {
      while let work = workRing.takeNext() {
        var resetConverter = false
        if work.droppedDurationMicrosBefore > 0 {
          assembler.noteDropped(
            durationMicros: work.droppedDurationMicrosBefore,
            startTimestampMicros: work.droppedStartTimestampMicros
          )
          resetConverter = true
        }
        if assembler.prepareInput(timestampMicros: work.timestampMicros) {
          resetConverter = true
        }
        if resetConverter {
          converter?.reset()
        }
        do {
          try recorder?.write(work.buffer)
        } catch {
          fail(
            code: "RecordingWriteFailed",
            message: error.localizedDescription
          )
          return
        }
        guard
          let samples = converter?.convert(work.buffer),
          !samples.isEmpty
        else { continue }
        if !assembler.push(
          samples,
          timestampMicros: work.timestampMicros
        ) {
          fail(
            code: "CaptureMailboxOverflow",
            message: "The bounded system-audio mailbox overflowed."
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

    static func translatePid(_ pid: pid_t) -> AudioObjectID {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var mutablePid = pid
      var object = AudioObjectID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioObjectID>.size)
      let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        &mutablePid,
        &size,
        &object
      )
      return status == noErr ? object : AudioObjectID(kAudioObjectUnknown)
    }

    static func tapFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var description = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      guard
        AudioObjectGetPropertyData(
          tap,
          &address,
          0,
          nil,
          &size,
          &description
        ) == noErr
      else { return nil }
      return AVAudioFormat(streamDescription: &description)
    }

    static func listProcesses() -> [AudioProcessMessage] {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
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
        ) == noErr,
        size > 0
      else { return [] }
      var objects = [AudioObjectID](
        repeating: AudioObjectID(kAudioObjectUnknown),
        count: Int(size) / MemoryLayout<AudioObjectID>.size
      )
      guard
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          &size,
          &objects
        ) == noErr
      else { return [] }

      return objects.compactMap { object in
        var pidAddress = AudioObjectPropertyAddress(
          mSelector: kAudioProcessPropertyPID,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        guard
          AudioObjectGetPropertyData(
            object,
            &pidAddress,
            0,
            nil,
            &pidSize,
            &pid
          ) == noErr
        else { return nil }

        var bundleAddress = AudioObjectPropertyAddress(
          mSelector: kAudioProcessPropertyBundleID,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        var bundleReference: Unmanaged<CFString>?
        var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let bundleStatus = AudioObjectGetPropertyData(
          object,
          &bundleAddress,
          0,
          nil,
          &bundleSize,
          &bundleReference
        )
        let bundle =
          bundleStatus == noErr
          ? (bundleReference?.takeRetainedValue() as String? ?? "")
          : ""

        var runningAddress = AudioObjectPropertyAddress(
          mSelector: kAudioProcessPropertyIsRunningOutput,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(
          object,
          &runningAddress,
          0,
          nil,
          &runningSize,
          &isRunning
        )
        return AudioProcessMessage(
          processId: Int64(pid),
          bundleId: bundle,
          isProducingAudio: isRunning != 0
        )
      }
    }

    static func preflightPermission() -> Bool {
      let ownProcess = translatePid(getpid())
      let excluded =
        ownProcess == AudioObjectID(kAudioObjectUnknown) ? [] : [ownProcess]
      let description = CATapDescription(
        stereoGlobalTapButExcludeProcesses: excluded
      )
      description.name = "audio_flutter permission preflight"
      description.isPrivate = true
      var tap = AudioObjectID(kAudioObjectUnknown)
      let status = AudioHardwareCreateProcessTap(description, &tap)
      if status == noErr {
        AudioHardwareDestroyProcessTap(tap)
        return true
      }
      return false
    }
  }
#endif
