import Foundation

final class SessionEventsHandler: SessionEventsStreamHandler {
  private var sink: PigeonEventSink<AudioSessionEventMessage>?

  override func onListen(
    withArguments arguments: Any?,
    sink: PigeonEventSink<AudioSessionEventMessage>
  ) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(_ event: AudioSessionEventMessage) {
    if Thread.isMainThread {
      sink?.success(event)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.sink?.success(event)
      }
    }
  }
}

