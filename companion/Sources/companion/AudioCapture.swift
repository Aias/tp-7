import Accelerate
@preconcurrency import AVFoundation
import CoreAudio
import Synchronization

/// Captures audio from the TP-7's input over USB, pinned to that specific
/// device (AVFoundation has no API for input-device selection, so the
/// device is set on the input node's underlying audio unit). Buffers are
/// delivered converted to the requested format; channel 0 is also archived
/// as mono FLAC when an archive URL is given. The peak level of channel 0
/// is tracked for the whole capture.
///
/// A hardware change elsewhere on the Mac, such as screen mirroring taking
/// over the default output, stops the engine and drops the pinned device;
/// capture re-pins the device and resumes.
final class AudioCapture: NSObject {
	private struct Level {
		var peak: Float = 0
		var frames = 0
	}

	private let engine = AVAudioEngine()
	private var device = AudioDeviceID(kAudioObjectUnknown)
	private var outputFormat: AVAudioFormat?
	private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
	private var converter: AVAudioConverter?
	private var archive: (file: AVAudioFile, url: URL)?
	private var archiveConverter: AVAudioConverter?
	private var running = false
	/// Written from the audio tap and read from the main actor.
	private let level = Mutex(Level())
	/// Only touched from the audio tap, which runs serially.
	private nonisolated(unsafe) var bufferCount = 0

	/// With THRU off the TP-7 sends the Mac digital silence (about −91 dBFS),
	/// so a channel that never rises above this carries no live mic.
	static let silenceFloorDecibels: Float = -80

	/// The highest sample magnitude on channel 0 since `start`, in dBFS, or
	/// nil until audio has arrived.
	var peakDecibels: Float? {
		level.withLock { $0.frames > 0 ? 20 * log10($0.peak) : nil }
	}

	/// Whether audio arrived and channel 0 never rose above the silence floor.
	var isSilent: Bool {
		peakDecibels.map { $0 < Self.silenceFloorDecibels } ?? false
	}

	/// Finds the TP-7's CoreAudio device id by name prefix.
	static func findTP7Device() -> AudioDeviceID? {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDevices,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain)
		var size: UInt32 = 0
		guard
			AudioObjectGetPropertyDataSize(
				AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
		else { return nil }
		let count = Int(size) / MemoryLayout<AudioDeviceID>.size
		var devices = [AudioDeviceID](repeating: 0, count: count)
		guard
			AudioObjectGetPropertyData(
				AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
				== noErr
		else { return nil }
		for device in devices {
			var nameAddress = AudioObjectPropertyAddress(
				mSelector: kAudioObjectPropertyName,
				mScope: kAudioObjectPropertyScopeGlobal,
				mElement: kAudioObjectPropertyElementMain)
			var name: Unmanaged<CFString>?
			var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
			guard
				AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name)
					== noErr,
				let deviceName = name?.takeRetainedValue() as String?
			else { continue }
			if deviceName.hasPrefix("TP-7") {
				return device
			}
		}
		return nil
	}

	/// Whether any process is running audio through the device. A failed
	/// query reads as running, so callers err toward leaving it alone.
	static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain)
		var running: UInt32 = 0
		var size = UInt32(MemoryLayout<UInt32>.size)
		guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr
		else { return true }
		return running != 0
	}

	/// The system default input device — the meeting fallback when the TP-7
	/// isn't wired (BLE carries gestures but no audio).
	static func defaultInputDevice() -> AudioDeviceID? {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultInputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain)
		var device = AudioDeviceID(kAudioObjectUnknown)
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		guard
			AudioObjectGetPropertyData(
				AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
				== noErr,
			device != kAudioObjectUnknown
		else { return nil }
		return device
	}

	/// Opens an archive for writing: mono, 48 kHz, 16-bit FLAC. The TP-7's mic
	/// lives on channel 0 and its other five channels carry no signal.
	/// AVAudioFile only writes 16-bit when its processing format is Int16;
	/// with the Float32 default the FLAC comes out 24-bit.
	static func openArchive(at url: URL) throws -> AVAudioFile {
		try AVAudioFile(
			forWriting: url,
			settings: [
				AVFormatIDKey: kAudioFormatFLAC,
				AVSampleRateKey: 48_000.0,
				AVNumberOfChannelsKey: 1,
				AVLinearPCMBitDepthKey: 16,
			],
			commonFormat: .pcmFormatInt16, interleaved: false)
	}

	/// Converts one tap buffer. The converter keeps its sample-rate state
	/// across calls, so each stream needs a converter of its own.
	static func convert(
		_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter
	) throws -> AVAudioPCMBuffer {
		let format = converter.outputFormat
		let ratio = format.sampleRate / converter.inputFormat.sampleRate
		let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
		guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
			throw CaptureError.bufferUnavailable
		}
		nonisolated(unsafe) var consumed = false
		var error: NSError?
		converter.convert(to: converted, error: &error) { _, outStatus in
			if consumed {
				outStatus.pointee = .noDataNow
				return nil
			}
			consumed = true
			outStatus.pointee = .haveData
			return buffer
		}
		if let error {
			throw error
		}
		return converted
	}

	/// Starts capture from the given device, delivering buffers converted to
	/// `outputFormat` and, when `archiveURL` is set, archiving channel 0 there.
	func start(
		device: AudioDeviceID,
		outputFormat: AVAudioFormat,
		archiveURL: URL?,
		onBuffer: @escaping (AVAudioPCMBuffer) -> Void
	) throws {
		self.device = device
		self.outputFormat = outputFormat
		self.onBuffer = onBuffer
		archive = try archiveURL.map { (file: try Self.openArchive(at: $0), url: $0) }
		bufferCount = 0
		level.withLock { $0 = Level() }
		running = true
		do {
			try connect()
		} catch {
			stop()
			throw error
		}
		NotificationCenter.default.addObserver(
			self, selector: #selector(engineConfigurationChanged),
			name: .AVAudioEngineConfigurationChange, object: engine)
		Log.d("capture: engine started")
	}

	/// Pins the engine's input to the capture device, builds the converters
	/// for its hardware format, installs the tap, and starts the engine.
	private func connect() throws {
		var deviceID = device
		guard let audioUnit = engine.inputNode.audioUnit else {
			throw CaptureError.noInputUnit
		}
		let status = AudioUnitSetProperty(
			audioUnit, kAudioOutputUnitProperty_CurrentDevice,
			kAudioUnitScope_Global, 0, &deviceID,
			UInt32(MemoryLayout<AudioDeviceID>.size))
		guard status == noErr else {
			throw CaptureError.deviceSelectionFailed(status)
		}

		let hardwareFormat = engine.inputNode.inputFormat(forBus: 0)
		guard
			let outputFormat,
			let converter = AVAudioConverter(from: hardwareFormat, to: outputFormat)
		else {
			throw CaptureError.converterUnavailable
		}
		Log.d(
			"capture: device \(device), hw format \(hardwareFormat.sampleRate)Hz "
				+ "\(hardwareFormat.channelCount)ch, target \(outputFormat.sampleRate)Hz "
				+ "\(outputFormat.channelCount)ch")
		// The default many-to-one channel mapping silently zeroes the signal;
		// take channel 0 — where the TP-7's mic lives (verified: the mic
		// occupies the first stereo pair, channels 2-5 are silent), and the
		// primary channel of any ordinary mic.
		converter.channelMap = [0]
		self.converter = converter
		archiveConverter = try archive.map { archive in
			guard
				let archiveConverter = AVAudioConverter(
					from: hardwareFormat, to: archive.file.processingFormat)
			else {
				throw CaptureError.converterUnavailable
			}
			archiveConverter.channelMap = [0]
			return archiveConverter
		}

		engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) {
			[weak self] buffer, _ in
			guard let self else { return }
			self.bufferCount += 1
			if self.bufferCount == 1 || self.bufferCount % 100 == 0 {
				Log.d("capture: buffer #\(self.bufferCount), \(buffer.frameLength) frames")
			}
			self.measure(buffer)
			if let archive = self.archive, let archiveConverter = self.archiveConverter {
				do {
					try archive.file.write(from: Self.convert(buffer, with: archiveConverter))
				} catch {
					if self.bufferCount == 1 {
						Log.d("capture: archive write failed: \(error)")
					}
				}
			}
			guard let converter = self.converter else { return }
			do {
				let converted = try Self.convert(buffer, with: converter)
				if converted.frameLength > 0 {
					self.onBuffer?(converted)
				}
			} catch {
				if self.bufferCount == 1 {
					Log.d("capture: conversion failed: \(error)")
				}
			}
		}
		try engine.start()
	}

	/// Posted on an engine thread once the engine has stopped itself; the
	/// reconnect runs on the main thread, where start and stop run.
	@objc private func engineConfigurationChanged(_ notification: Notification) {
		performSelector(onMainThread: #selector(reconnect), with: nil, waitUntilDone: false)
	}

	@objc private func reconnect() {
		guard running, !engine.isRunning else { return }
		Log.d("capture: audio configuration changed, reconnecting")
		engine.inputNode.removeTap(onBus: 0)
		do {
			try connect()
		} catch {
			Log.d("capture: reconnect failed: \(error)")
		}
	}

	/// Folds the buffer's channel 0 into the running peak.
	private func measure(_ buffer: AVAudioPCMBuffer) {
		guard let samples = buffer.floatChannelData?[0] else { return }
		let frames = Int(buffer.frameLength)
		let peak = vDSP.maximumMagnitude(UnsafeBufferPointer(start: samples, count: frames))
		level.withLock {
			$0.peak = max($0.peak, peak)
			$0.frames += frames
		}
	}

	/// Stops the engine and closes the archive, deleting it when it holds no
	/// audio: FLAC writing leaves a header-only file unless a full block
	/// (about 96 ms) was written. Safe to call when capture never started or
	/// has already stopped.
	func stop() {
		guard running else { return }
		running = false
		NotificationCenter.default.removeObserver(
			self, name: .AVAudioEngineConfigurationChange, object: engine)
		engine.inputNode.removeTap(onBus: 0)
		engine.stop()
		converter = nil
		onBuffer = nil
		archiveConverter = nil
		if let url = archive?.url {
			archive = nil
			if (try? AVAudioFile(forReading: url)) == nil {
				try? FileManager.default.removeItem(at: url)
			}
		}
		if let peak = peakDecibels {
			Log.d("capture: stopped, channel 0 peak \(String(format: "%.1f", peak)) dBFS")
		}
	}

	enum CaptureError: Error {
		case noInputUnit
		case deviceSelectionFailed(OSStatus)
		case converterUnavailable
		case bufferUnavailable
	}
}
