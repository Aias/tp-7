import AppKit
import ApplicationServices

/// What the user was doing when a capture started: the frontmost app, its
/// focused window, and — when the window exposes its document — the file
/// and git branch behind it. Stamped onto every memo and meeting so the
/// archive can answer "what was I working on when I said this". Agent
/// requests also take the selected text and the clipboard, which anchor
/// the request to a passage.
struct CaptureContext {
	let app: String?
	let window: String?
	let selection: String?
	let clipboard: String?
	let document: URL?
	let branch: String?

	private static let maxTextLength = 4000

	/// `forRequest` also reads the selected text (where the app exposes it
	/// through accessibility; web views mostly don't) and the clipboard.
	@MainActor
	static func current(forRequest: Bool = false) async -> CaptureContext {
		guard let frontmost = NSWorkspace.shared.frontmostApplication else {
			return CaptureContext(
				app: nil, window: nil, selection: nil, clipboard: nil, document: nil, branch: nil)
		}
		let element = AXUIElementCreateApplication(frontmost.processIdentifier)
		enableWebAccessibility(element)
		let window = focusedWindow(of: element)
		let selection = forRequest ? trimmed(axSelection(in: element)) : nil
		let clipboard = forRequest ? trimmed(NSPasteboard.general.string(forType: .string)) : nil
		let document = window.flatMap { attribute($0, kAXDocumentAttribute) as? String }
			.flatMap(URL.init(string:))
			.flatMap { $0.isFileURL ? $0 : nil }
		var branch: String?
		if let document {
			branch = await Subprocess.run([
				"git", "-C", document.deletingLastPathComponent().path,
				"rev-parse", "--abbrev-ref", "HEAD",
			])?.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return CaptureContext(
			app: frontmost.localizedName,
			window: window.flatMap { attribute($0, kAXTitleAttribute) as? String },
			selection: selection,
			clipboard: clipboard,
			document: document,
			branch: branch.flatMap { $0.isEmpty ? nil : $0 })
	}

	var markdownLines: [String] {
		var lines: [String] = []
		if let app { lines.append("- app: \(app)") }
		if let window, !window.isEmpty { lines.append("- window: \(window)") }
		if let document { lines.append("- document: \(document.path)") }
		if let branch { lines.append("- branch: \(branch)") }
		return lines
	}

	/// One-line form for the memo journal heading.
	var summary: String? {
		guard let app else { return nil }
		if let window, !window.isEmpty { return "\(app) — \(window)" }
		return app
	}

	/// Chromium and Electron only build their accessibility tree once an
	/// assistive client announces itself.
	private static func enableWebAccessibility(_ app: AXUIElement) {
		AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
		AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
	}

	/// The selection from the focused element or the nearest ancestor that
	/// exposes one.
	private static func axSelection(in app: AXUIElement) -> String? {
		var element = focusedElement(of: app)
		var depth = 0
		while let current = element, depth < 8 {
			if let text = attribute(current, kAXSelectedTextAttribute) as? String, !text.isEmpty {
				return text
			}
			element = self.element(attribute(current, kAXParentAttribute))
			depth += 1
		}
		return nil
	}

	private static func trimmed(_ text: String?) -> String? {
		text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.flatMap { $0.isEmpty ? nil : String($0.prefix(maxTextLength)) }
	}

	private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
		element(attribute(app, kAXFocusedWindowAttribute))
	}

	private static func focusedElement(of app: AXUIElement) -> AXUIElement? {
		element(attribute(app, kAXFocusedUIElementAttribute))
	}

	private static func element(_ value: AnyObject?) -> AXUIElement? {
		guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
		return unsafeDowncast(value, to: AXUIElement.self)
	}

	private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
		var value: AnyObject?
		guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
		else { return nil }
		return value
	}
}
