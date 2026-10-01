import Foundation

/// A machine-readable line the pipeline CLI prints on stdout: the literal
/// prefix `@tp7 ` followed by one JSON object. Every other line the CLI
/// prints is human log output.
enum PipelineEvent: Sendable {
	enum Stage: String, Sendable, Decodable {
		case converting
		case transcribing
		case cleaning
		case summarizing
	}

	case stage(Stage, input: URL)
	case result(PipelineResult)
	case misdated(file: String)
	case draft(title: String, summary: String)
	/// `folder` is nil while the recording is not yet transcribed.
	case redated(file: String, folder: URL?)

	private static let prefix = "@tp7 "

	/// Parses one output line; nil for log lines and for event lines this
	/// build can't read (a newer pipeline's event kinds).
	static func parse(_ line: String) -> PipelineEvent? {
		guard line.hasPrefix(prefix) else { return nil }
		let json = Data(line.dropFirst(prefix.count).utf8)
		do {
			return try JSONDecoder().decode(PipelineEvent.self, from: json)
		} catch {
			Log.d("pipeline: unreadable event \(line): \(error)")
			return nil
		}
	}
}

/// Receives the stage a pipeline job has reached; nil once it finishes a
/// recording.
typealias StageReport = @MainActor (PipelineEvent.Stage?) -> Void

/// The outcome of one recording's pipeline run. `title` and `summary` are
/// nil when the recording had no speech.
struct PipelineResult: Sendable, Decodable {
	let input: URL
	let folder: URL
	let transcript: URL
	let title: String?
	let summary: String?
	let speech: Bool

	private enum CodingKeys: String, CodingKey {
		case input, folder, transcript, title, summary, speech
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		input = try container.decodePath(forKey: .input)
		folder = try container.decodePath(forKey: .folder)
		transcript = try container.decodePath(forKey: .transcript)
		title = try container.decodeIfPresent(String.self, forKey: .title)
		summary = try container.decodeIfPresent(String.self, forKey: .summary)
		speech = try container.decode(Bool.self, forKey: .speech)
	}
}

extension PipelineEvent: Decodable {
	private enum Kind: String, Decodable {
		case stage, result, misdated, draft, redated
	}

	private enum CodingKeys: String, CodingKey {
		case event, stage, input, file, folder, title, summary
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		switch try container.decode(Kind.self, forKey: .event) {
		case .stage:
			self = .stage(
				try container.decode(Stage.self, forKey: .stage),
				input: try container.decodePath(forKey: .input))
		case .result:
			self = .result(try PipelineResult(from: decoder))
		case .misdated:
			self = .misdated(file: try container.decode(String.self, forKey: .file))
		case .draft:
			self = .draft(
				title: try container.decode(String.self, forKey: .title),
				summary: try container.decode(String.self, forKey: .summary))
		case .redated:
			self = .redated(
				file: try container.decode(String.self, forKey: .file),
				folder: try container.decodeIfPresent(String.self, forKey: .folder)
					.map { URL(fileURLWithPath: $0) })
		}
	}
}

extension KeyedDecodingContainer {
	/// Paths arrive as plain absolute strings, which `URL`'s own decoding
	/// would read as scheme-less URLs.
	fileprivate func decodePath(forKey key: Key) throws -> URL {
		URL(fileURLWithPath: try decode(String.self, forKey: key))
	}
}
