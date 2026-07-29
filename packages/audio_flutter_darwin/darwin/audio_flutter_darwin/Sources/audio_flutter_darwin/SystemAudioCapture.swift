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
    private let holdsActivity = OSAllocatedUnfairLock(initialState: false)
    private let renderCycles = OSAllocatedUnfairLock(initialState: Int64(0))
    /// Serial queue the HAL delivers default-output-device notifications on.
    /// Separate from `ioQueue`/`workerQueue`, which a rebuild drains.
    private let deviceListenerQueue = DispatchQueue(
      label: "audio_flutter.system_capture.device_listener",
      qos: .userInitiated
    )
    private var tapId = AudioObjectID(kAudioObjectUnknown)
    private var aggregateId = AudioObjectID(kAudioObjectUnknown)
    private var aggregateUid: String?
    private var clockDeviceUid: String?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
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
      installOutputDeviceListenerLocked()
      setActivityHold(true)
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
            self.healthEvent(
              phase: .running,
              receivingAudio: true,
              statistics: currentStatistics
            )
          )
          return
        }

        // Electron/Chromium helper processes may become tappable after start.
        // Rebuild once using a fresh PID translation before declaring failure.
        self.events.emit(
          self.healthEvent(
            phase: .interrupted,
            message: "System capture is silent; rebuilding its process tap once.",
            receivingAudio: false,
            statistics: currentStatistics
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
            self.healthEvent(
              phase: .running,
              message: audioAdvanced ? nil : "System tap is alive but currently silent.",
              receivingAudio: audioAdvanced,
              statistics: finalStatistics
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

    /// One health event carrying the full statistics snapshot. Built only where
    /// health is already emitted, so widening the payload does not raise the
    /// event rate.
    private func healthEvent(
      phase: AudioSessionPhaseMessage,
      code: String? = nil,
      message: String? = nil,
      receivingAudio: Bool,
      statistics: CaptureStatistics
    ) -> AudioSessionEventMessage {
      AudioSessionEventMessage(
        sessionId: sessionId,
        phase: phase,
        code: code,
        message: message,
        receivingAudio: receivingAudio,
        callbackCount: statistics.callbackCount,
        peakAmplitude: statistics.peakAmplitude,
        rms: statistics.rms,
        nonZeroFramePercent: statistics.nonZeroFramePercent,
        renderCycles: renderCycles.withLock { $0 },
        firstAudioAtMillis: statistics.firstAudioAtMillis
      )
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
        removeOutputDeviceListenerLocked()
        recorder?.close()
        recorder = nil
        setActivityHold(false)
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

      // Adapted from Control Center (MIT © 2026 Samuel Alev): a tap-only
      // aggregate supplies no clock of its own, and was observed never to be
      // clocked on macOS 26 with a USB output device — the aggregate's
      // `kAudioDevicePropertyDeviceIsRunning` stayed 0 and the IO proc never
      // fired, with the capture grant in place. Anchoring the aggregate to the
      // current default output device as both main sub-device and explicit
      // clock device gives the HAL real hardware to clock from. The output
      // device is a clock source only; the tap still carries the whole-system
      // mix regardless of output routing.
      let clockDeviceUid = Self.defaultOutputDeviceUid()
      let uid = Self.aggregateUidPrefix + UUID().uuidString
      var aggregate = AudioObjectID(kAudioObjectUnknown)
      status = AudioHardwareCreateAggregateDevice(
        Self.aggregateDescription(
          aggregateUid: uid,
          tapUid: description.uuid.uuidString,
          clockDeviceUid: clockDeviceUid
        ) as CFDictionary,
        &aggregate
      )
      if status != noErr, clockDeviceUid != nil {
        // A composition the HAL rejects must not cost the session its capture:
        // retry as the unclocked tap-only aggregate.
        status = AudioHardwareCreateAggregateDevice(
          Self.aggregateDescription(
            aggregateUid: uid,
            tapUid: description.uuid.uuidString,
            clockDeviceUid: nil
          ) as CFDictionary,
          &aggregate
        )
      }
      guard status == noErr else {
        unwindLocked()
        throw PigeonError(
          code: "AggregateCreateFailed",
          message: "AudioHardwareCreateAggregateDevice failed (\(status)).",
          details: nil
        )
      }
      aggregateId = aggregate
      aggregateUid = uid
      self.clockDeviceUid = clockDeviceUid
      // Registered before any failure path can run, so the orphan sweeper never
      // destroys a device this process is still building on.
      Self.liveAggregateUids.withLock { _ = $0.insert(uid) }

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
        self.renderCycles.withLock { $0 += 1 }
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
        removeOutputDeviceListenerLocked()
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
      setActivityHold(false)
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
      if let uid = aggregateUid {
        Self.liveAggregateUids.withLock { _ = $0.remove(uid) }
        aggregateUid = nil
      }
      clockDeviceUid = nil
      if tapId != AudioObjectID(kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(tapId)
        tapId = AudioObjectID(kAudioObjectUnknown)
      }
    }

    /// Watches the default output device the aggregate is clocked from.
    ///
    /// The aggregate anchors to whichever device was default when the chain was
    /// built, so switching output (speakers to AirPods, HDMI unplugged) leaves
    /// it clocked by a device the user no longer routes to — and by a device
    /// that may vanish outright, which stops the IO proc silently. The listener
    /// rebuilds the chain against the new default; the rebuild reports itself
    /// through the frame stream as an `AudioDiscontinuityReason.sourceRestart`.
    private func installOutputDeviceListenerLocked() {
      guard outputDeviceListener == nil else { return }
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleDefaultOutputDeviceChange()
      }
      let status = AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        deviceListenerQueue,
        block
      )
      guard status == noErr else { return }
      outputDeviceListener = block
    }

    private func removeOutputDeviceListenerLocked() {
      guard let block = outputDeviceListener else { return }
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        deviceListenerQueue,
        block
      )
      outputDeviceListener = nil
    }

    /// Runs on `deviceListenerQueue` and returns immediately: teardown removes
    /// this listener while it holds `lifecycle`, so a listener block that
    /// waited for `lifecycle` could deadlock against its own removal.
    private func handleDefaultOutputDeviceChange() {
      guard running.withLock({ $0 }) else { return }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.rebuildForOutputDeviceChange()
      }
    }

    /// A tap-only aggregate (no clock device) is unaffected by the switch, and
    /// a notification that resolves to the same device is a no-op, so neither
    /// rebuilds.
    private func rebuildForOutputDeviceChange() {
      guard running.withLock({ $0 }) else { return }
      lifecycle.lock()
      let previousUid = clockDeviceUid
      lifecycle.unlock()
      guard let previousUid else { return }
      let currentUid = Self.defaultOutputDeviceUid()
      guard currentUid != previousUid else { return }
      events.emit(
        healthEvent(
          phase: .interrupted,
          code: "DefaultOutputDeviceChanged",
          message:
            "The default output device changed; rebuilding the capture chain "
            + "against the new clock device.",
          receivingAudio: false,
          statistics: assembler.statistics()
        )
      )
      _ = rebuild()
    }

    /// Holds the process-wide App Nap assertion while this session captures.
    /// Idempotent, so repeated stops and `deinit` cannot unbalance the refcount.
    private func setActivityHold(_ held: Bool) {
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

    /// UID prefix of every aggregate device this plugin creates.
    ///
    /// The name stays human-readable for anything that shows device names; the
    /// UID is what `cleanupOrphanedAggregateDevices()` matches on, so it must
    /// be unmistakably ours and must never change casually — a released build
    /// that used the old prefix leaks devices this one would no longer
    /// recognise.
    static let aggregateUidPrefix = "audio-flutter.tap."

    /// UIDs of aggregates a live session in this process still owns. The
    /// orphan sweeper skips them; everything else carrying the prefix was
    /// leaked by a process that died before it could unwind.
    private static let liveAggregateUids = OSAllocatedUnfairLock(
      initialState: Set<String>()
    )

    /// The private aggregate device that exposes the tap as an input stream.
    ///
    /// `clockDeviceUid` anchors the aggregate to real output hardware; `nil`
    /// builds the tap-only aggregate, which has no clock source of its own.
    static func aggregateDescription(
      aggregateUid: String,
      tapUid: String,
      clockDeviceUid: String?
    ) -> [String: Any] {
      var tap: [String: Any] = [kAudioSubTapUIDKey as String: tapUid]
      var description: [String: Any] = [
        kAudioAggregateDeviceNameKey as String: "audio_flutter aggregate",
        kAudioAggregateDeviceUIDKey as String: aggregateUid,
        kAudioAggregateDeviceIsPrivateKey as String: true,
        kAudioAggregateDeviceTapAutoStartKey as String: true,
      ]
      guard let clockDeviceUid else {
        description[kAudioAggregateDeviceTapListKey as String] = [tap]
        return description
      }
      // The tap and the clock device are separate timing domains, so the tap
      // sub-entry compensates for drift between them.
      tap[kAudioSubTapDriftCompensationKey as String] = true
      description[kAudioAggregateDeviceIsStackedKey as String] = false
      description[kAudioAggregateDeviceMainSubDeviceKey as String] =
        clockDeviceUid
      description[kAudioAggregateDeviceClockDeviceKey as String] =
        clockDeviceUid
      description[kAudioAggregateDeviceSubDeviceListKey as String] = [
        [kAudioSubDeviceUIDKey as String: clockDeviceUid]
      ]
      description[kAudioAggregateDeviceTapListKey as String] = [tap]
      return description
    }

    /// UID of the current default output device, resolved when the aggregate is
    /// created so it follows the user's live output selection.
    ///
    /// `nil` when the machine reports no default output (every output device
    /// unplugged, headless CI), in which case the caller falls back to the
    /// tap-only aggregate rather than failing the capture.
    static func defaultOutputDeviceUid() -> String? {
      var deviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var device = AudioDeviceID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      guard
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &deviceAddress,
          0,
          nil,
          &size,
          &device
        ) == noErr,
        device != AudioDeviceID(kAudioObjectUnknown)
      else { return nil }
      return deviceUid(device)
    }

    static func deviceUid(_ device: AudioDeviceID) -> String? {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var value: Unmanaged<CFString>?
      var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      guard
        AudioObjectGetPropertyData(
          device,
          &address,
          0,
          nil,
          &size,
          &value
        ) == noErr,
        let value
      else { return nil }
      return value.takeRetainedValue() as String
    }

    /// Destroys aggregate devices this plugin created and never unwound,
    /// returning how many were reclaimed.
    ///
    /// macOS reclaims a private aggregate when its creating process exits
    /// cleanly, but a `kill -9`, a crash, or a debugger stop can leave it in
    /// the device tree. Only devices whose UID carries
    /// `aggregateUidPrefix` are touched, and never one a live session in this
    /// process still owns, so this is safe to call at app start — which is the
    /// point of calling it: an app that never calls it accumulates leaked
    /// devices across crashes.
    static func cleanupOrphanedAggregateDevices() -> Int64 {
      let live = liveAggregateUids.withLock { $0 }
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
        ) == noErr,
        size > 0
      else { return 0 }
      var devices = [AudioDeviceID](
        repeating: AudioDeviceID(kAudioObjectUnknown),
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
      else { return 0 }

      var destroyed: Int64 = 0
      for device in devices {
        guard
          let uid = deviceUid(device),
          uid.hasPrefix(aggregateUidPrefix),
          !live.contains(uid)
        else { continue }
        if AudioHardwareDestroyAggregateDevice(device) == noErr {
          destroyed += 1
        }
      }
      return destroyed
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

    /// Advisory only — this can report an optimistic `true`.
    ///
    /// The `kTCCServiceAudioCapture` grant is documented by Control Center
    /// (MIT © 2026 Samuel Alev) as enforced at delivery rather than at
    /// creation: an unauthorized tap still creates, still reports a valid
    /// format, and is simply fed silence. Tap creation therefore proves the API
    /// is reachable, not that audio will arrive. The authoritative signal is
    /// capture health — a running session whose non-zero frame count never
    /// advances, reported by `start()`'s watchdog as `receivingAudio: false`
    /// and then as `SystemCaptureDead`.
    ///
    /// Gating this on observed non-silent frames needs validation against an
    /// actually-denied grant on current macOS before the behaviour changes;
    /// until then the contract is documented as advisory rather than rewritten.
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
