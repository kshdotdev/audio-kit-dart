import AVFoundation
import Foundation

/// Format math the capture chains share, with no device reads of its own.
///
/// The device property reads (`kAudioDevicePropertyNominalSampleRate` and
/// friends) stay with the capture sessions; only the arithmetic they perform
/// on what they read lives here, so it can be exercised without a HAL.
public enum CaptureFormatMath {
  /// [described] re-rated to [rate], which is the rate the delivering device
  /// actually clocks at.
  ///
  /// A tap-carrying aggregate delivers at its CLOCK device's rate — the HAL
  /// resamples the tap's stream into that clock domain (AirPods in HFP/SCO
  /// clock it at 24 kHz) — while `kAudioTapPropertyFormat` keeps reporting the
  /// tap object's own 48 kHz. Labeling IO buffers with the described rate
  /// would write half-speed content into a full-rate container: the 2x
  /// "chipmunk" recording. The delivering device's nominal rate is the truth.
  ///
  /// [described] is returned unchanged when
  /// - [rate] is not positive, which is also the shape a garbage property read
  ///   takes (and rejects NaN, which is not `> 0`);
  /// - [rate] already is the described rate, so there is nothing to re-rate;
  /// - the re-rated stream description does not describe a format
  ///   `AVAudioFormat` can represent. Defensive: a description that only
  ///   differs from an accepted one by its sample rate has not been observed
  ///   to be rejected, but a fallback costs nothing and a `nil` here would
  ///   otherwise have to fail the capture.
  ///
  /// The whole stream description is carried over, so channel count, layout,
  /// packedness, and interleaving survive the re-rate; only `mSampleRate`
  /// changes.
  public static func formatAtRate(
    _ described: AVAudioFormat,
    rate: Double
  ) -> AVAudioFormat {
    guard rate > 0, rate != described.sampleRate else { return described }
    var description = described.streamDescription.pointee
    description.mSampleRate = rate
    return AVAudioFormat(streamDescription: &description) ?? described
  }
}
