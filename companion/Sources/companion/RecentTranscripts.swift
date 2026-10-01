import Foundation

/// The archive's finished transcripts, found by walking the titled folders
/// the pipeline files under `meetings/` and `memos/`.
enum RecentTranscripts {
	struct Entry {
		let url: URL
		let title: String
	}

	/// The most recently modified transcripts across both areas, newest first.
	static func latest(limit: Int) -> [Entry] {
		let manager = FileManager.default
		var found: [(entry: Entry, modified: Date)] = []
		for root in [Paths.meetingsDir, Paths.memosDir] {
			let folders =
				(try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
			for folder in folders {
				guard let parsed = TranscriptFolder(name: folder.lastPathComponent) else {
					continue
				}
				let files =
					(try? manager.contentsOfDirectory(
						at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
				for file in files where file.lastPathComponent.hasSuffix("-transcript.md") {
					let modified =
						(try? file.resourceValues(forKeys: [.contentModificationDateKey])
							.contentModificationDate) ?? .distantPast
					found.append((Entry(url: file, title: parsed.menuTitle), modified))
				}
			}
		}
		return found.sorted { $0.modified > $1.modified }.prefix(limit).map(\.entry)
	}
}
