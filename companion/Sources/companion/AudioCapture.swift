@preconcurrency import AVFoundation
import CoreAudio

/// Captures audio from the TP-7's input over USB, pinned to that specific
/// device (AVFoundation has no API for input-device selection, so the
/// device is set on the input node's underlying audio unit). Buffers are
/// delivered converted to the requested format; the raw hardware-format
/// stream is also written to a file for the archive.
final class AudioCapture {
	private let engine = AVAudioEngine()
	private var converter: AVAudioConverter?
	private var archiveFile: AVAudioFile?
	/// Only touched from the audio tap, which runs serially.
	private nonisolated(unsafe) var bufferCount = 0

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

	/// Starts capture from the given device, delivering buffers converted to
	/// `outputFormat` and, when `archiveURL` is set, archiving the raw
	/// hardware-format stream there.
	func start(
		device: AudioDeviceID,
		outputFormat: AVAudioFormat,
		archiveURL: URL?,
		onBuffer: @escaping (AVAudioPCMBuffer) -> Void
	) throws {
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
		Log.d(
			"capture: device \(device), hw format \(hardwareFormat.sampleRate)Hz "
				+ "\(hardwareFormat.channelCount)ch, target \(outputFormat.sampleRate)Hz "
				+ "\(outputFormat.channelCount)ch")
		guard let converter = AVAudioConverter(from: hardwareFormat, to: outputFormat) else {
			throw CaptureError.converterUnavailable
		}
		// The default many-to-one channel mapping silently zeroes the signal;
		// take channel 0 — where the TP-7's mic lives (verified: the mic
		// occupies the first stereo pair, channels 2-5 are silent), and the
		// primary channel of any ordinary mic.
		converter.channelMap = [0]
		self.converter = converter
		// AVAudioFile requires interleaved file settings; write() converts
		// from the deinterleaved tap buffers.
		archiveFile = try archiveURL.map { url in
			try AVAudioFile(
				forWriting: url,
				settings: [
					AVFormatIDKey: kAudioFormatLinearPCM,
					AVSampleRateKey: hardwareFormat.sampleRate,
					AVNumberOfChannelsKey: hardwareFormat.channelCount,
					AVLinearPCMBitDepthKey: 24,
				])
		}
		bufferCount = 0

		engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) {
			[weak self] buffer, _ in
			guard let self else { return }
			self.bufferCount += 1
			if self.bufferCount == 1 || self.bufferCount % 100 == 0 {
				Log.d("capture: buffer #\(self.bufferCount), \(buffer.frameLength) frames")
			}
			do {
				try self.archiveFile?.write(from: buffer)
			} catch {
				if self.bufferCount == 1 {
					Log.d("capture: archive write failed: \(error)")
				}
			}
			let ratio = outputFormat.sampleRate / hardwareFormat.sampleRate
			let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
			guard
				let converted = AVAudioPCMBuffer(
					pcmFormat: outputFormat, frameCapacity: capacity)
			else { return }
			nonisolated(unsafe) var consumed = false
			var error: NSError?
			self.converter?.convert(to: converted, error: &error) { _, outStatus in
				if consumed {
					outStatus.pointee = .noDataNow
					return nil
				}
				consumed = true
				outStatus.pointee = .haveData
				return buffer
			}
			if let error {
				if self.bufferCount == 1 {
					Log.d("capture: conversion failed: \(error)")
				}
			} else if converted.frameLength > 0 {
				onBuffer(converted)
			}
		}
		try engine.start()
		Log.d("capture: engine started")
	}

	func stop() {
		engine.inputNode.removeTap(onBus: 0)
		engine.stop()
		converter = nil
		archiveFile = nil
	}

	enum CaptureError: Error {
		case noInputUnit
		case deviceSelectionFailed(OSStatus)
		case converterUnavailable
	}
}
