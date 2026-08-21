@preconcurrency import AVFoundation
import ScreenCaptureKit

/// Captures Mac system audio (the far side of a call) via ScreenCaptureKit.
/// Requires the Screen Recording permission; the first start prompts for it.
/// Sendability is hand-verified: start/stop run from the owning session and
/// the sample handler touches only `onBuffer`.
final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
	private var stream: SCStream?
	private let queue = DispatchQueue(label: "tp7companion.system-audio")
	/// Set on start, read on the sample-handler queue.
	private nonisolated(unsafe) var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

	func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
		self.onBuffer = onBuffer
		let content = try await SCShareableContent.excludingDesktopWindows(
			false, onScreenWindowsOnly: false)
		guard let display = content.displays.first else {
			throw CaptureError.noDisplay
		}
		let filter = SCContentFilter(display: display, excludingWindows: [])
		let configuration = SCStreamConfiguration()
		configuration.capturesAudio = true
		configuration.excludesCurrentProcessAudio = true
		// Audio is the only consumed output; keep the mandatory video leg tiny.
		configuration.width = 2
		configuration.height = 2
		configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
		let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
		try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
		try await stream.startCapture()
		self.stream = stream
		Log.d("system audio: capture started")
	}

	func stop() async {
		try? await stream?.stopCapture()
		stream = nil
		onBuffer = nil
	}

	nonisolated func stream(
		_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
		of type: SCStreamOutputType
	) {
		guard type == .audio, sampleBuffer.isValid,
			let buffer = Self.pcmBuffer(from: sampleBuffer)
		else { return }
		onBuffer?(buffer)
	}

	private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
		guard
			let description = CMSampleBufferGetFormatDescription(sampleBuffer),
			let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
				description)
		else { return nil }
		var streamDescription = basicDescription.pointee
		guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
			return nil
		}
		let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
		guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
		else { return nil }
		buffer.frameLength = frames
		let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
			sampleBuffer, at: 0, frameCount: Int32(frames),
			into: buffer.mutableAudioBufferList)
		return status == noErr ? buffer : nil
	}

	enum CaptureError: Error {
		case noDisplay
	}
}
