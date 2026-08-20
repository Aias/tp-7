import AppKit
import ApplicationServices

/// Streams text into the focused field of whatever app is frontmost by
/// synthesizing keyboard events. Live hypotheses are reconciled with what
/// was already typed: on each update the common prefix is kept, the stale
/// tail is deleted with backspaces, and the new tail is typed.
///
/// CGEvent unicode typing silently truncates at 20 UTF-16 units per event,
/// so text is emitted in chunks.
@MainActor
final class TextInserter {
	private var inserted = ""

	static var accessibilityGranted: Bool {
		AXIsProcessTrusted()
	}

	static func requestAccessibility() {
		// kAXTrustedCheckOptionPrompt by raw value; the CF global constant is
		// not concurrency-safe to reference under Swift 6.
		let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
		AXIsProcessTrustedWithOptions(options)
	}

	func beginUtterance() {
		inserted = ""
		Log.d("inserter: accessibility granted: \(Self.accessibilityGranted)")
	}

	/// Revisions deleting more than this many typed characters are deferred
	/// to finalization, where they apply once instead of thrashing live.
	private static let maxLiveRewrite = 12

	/// Replaces the current utterance's text with `text`, minimally.
	/// Non-final updates skip large rewrites; the finalized text applies
	/// them in one pass.
	func update(to text: String, isFinal: Bool) {
		let common = inserted.commonPrefix(with: text)
		let deletions = inserted.dropFirst(common.count)
		if !isFinal && deletions.utf16.count > Self.maxLiveRewrite {
			return
		}
		let additions = String(text.dropFirst(common.count))
		if !deletions.isEmpty {
			sendBackspaces(count: deletions.utf16.count)
		}
		if !additions.isEmpty {
			type(additions)
		}
		inserted = text
	}

	func endUtterance() {
		inserted = ""
	}

	private func sendBackspaces(count: Int) {
		guard let source = CGEventSource(stateID: .hidSystemState) else { return }
		for _ in 0..<count {
			let down = CGEvent(
				keyboardEventSource: source, virtualKey: 0x33, keyDown: true)
			let up = CGEvent(
				keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
			down?.post(tap: .cghidEventTap)
			up?.post(tap: .cghidEventTap)
		}
	}

	private func type(_ text: String) {
		guard let source = CGEventSource(stateID: .hidSystemState) else { return }
		let units = Array(text.utf16)
		var index = 0
		while index < units.count {
			let chunk = Array(units[index..<min(index + 20, units.count)])
			let down = CGEvent(
				keyboardEventSource: source, virtualKey: 0, keyDown: true)
			down?.keyboardSetUnicodeString(
				stringLength: chunk.count, unicodeString: chunk)
			down?.post(tap: .cghidEventTap)
			let up = CGEvent(
				keyboardEventSource: source, virtualKey: 0, keyDown: false)
			up?.post(tap: .cghidEventTap)
			index += 20
		}
	}
}
