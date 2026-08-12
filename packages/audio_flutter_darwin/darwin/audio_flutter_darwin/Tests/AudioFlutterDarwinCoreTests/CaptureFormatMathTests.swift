import AVFoundation
import XCTest

@testable import AudioFlutterDarwinCore

/// The re-rate math that decides what rate IO buffers are labeled with.
///
/// Mislabeling is what produced the 2x "chipmunk" recording: a 24 kHz stream
/// carried in a 48 kHz container.
final class CaptureFormatMathTests: XCTestCase {
  private func standardFormat(
    rate: Double = 48000,
    channels: AVAudioChannelCount = 2
  ) -> AVAudioFormat {
    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: rate,
        channels: channels
      )
    else {
      preconditionFailure("The standard float format is always constructible.")
    }
    return format
  }

  func testRerateProducesTheRequestedRate() {
    let described = standardFormat(rate: 48000)

    let rerated = CaptureFormatMath.formatAtRate(described, rate: 24000)

    XCTAssertEqual(rerated.sampleRate, 24000)
  }

  func testRerateKeepsEverythingButTheRate() {
    var interleaved = AudioStreamBasicDescription(
      mSampleRate: 48000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 16,
      mReserved: 0
    )
    guard let described = AVAudioFormat(streamDescription: &interleaved) else {
      return XCTFail("Interleaved Int16 is a representable format.")
    }

    let rerated = CaptureFormatMath.formatAtRate(described, rate: 16000)

    XCTAssertEqual(rerated.sampleRate, 16000)
    XCTAssertEqual(rerated.channelCount, described.channelCount)
    XCTAssertEqual(rerated.commonFormat, described.commonFormat)
    XCTAssertEqual(rerated.isInterleaved, described.isInterleaved)
    XCTAssertEqual(
      rerated.streamDescription.pointee.mFormatFlags,
      described.streamDescription.pointee.mFormatFlags
    )
    XCTAssertEqual(
      rerated.streamDescription.pointee.mBytesPerFrame,
      described.streamDescription.pointee.mBytesPerFrame
    )
  }

  /// Guard 1: a rate that is not positive is what a failed or garbage property
  /// read looks like, and must never relabel the stream.
  func testNonPositiveRateKeepsTheDescribedFormat() {
    let described = standardFormat(rate: 48000)

    for rate in [0.0, -1.0, -48000.0, Double.nan] {
      let result = CaptureFormatMath.formatAtRate(described, rate: rate)
      XCTAssertTrue(
        result === described,
        "rate \(rate) must return the described format unchanged"
      )
    }
  }

  /// Guard 2: the common case — the device already clocks at the described
  /// rate — allocates nothing and hands back the same format object.
  func testMatchingRateKeepsTheDescribedFormat() {
    let described = standardFormat(rate: 48000)

    let result = CaptureFormatMath.formatAtRate(described, rate: 48000)

    XCTAssertTrue(result === described)
  }

  /// Guard 3: the `?? described` fallback. A description that differs from an
  /// accepted one only by its sample rate has not been observed to be rejected
  /// by `AVAudioFormat` on current macOS, so this pins the contract the
  /// fallback exists for — a re-rate never returns a format at the wrong rate,
  /// and never returns nothing.
  func testRerateNeverProducesAMismatchedFormat() {
    let described = standardFormat(rate: 48000)

    for rate in [8000.0, 16000.0, 24000.0, 44100.0, 96000.0, 192000.0] {
      let result = CaptureFormatMath.formatAtRate(described, rate: rate)
      XCTAssertTrue(
        result.sampleRate == rate || result === described,
        "rate \(rate) produced neither the requested rate nor the fallback"
      )
    }
  }

  /// The `kAudioTapPropertyFormat` versus aggregate-clock disagreement the
  /// re-rate exists to resolve, in the shape it shipped as a bug: a tap
  /// describing 48 kHz while an HFP/SCO clock delivers 24 kHz.
  func testTapDescribedRateLosesToTheAggregateClockRate() {
    let tapDescribed = standardFormat(rate: 48000)

    let delivered = CaptureFormatMath.formatAtRate(tapDescribed, rate: 24000)

    XCTAssertEqual(delivered.sampleRate, 24000)
    XCTAssertEqual(delivered.channelCount, 2)
  }
}
