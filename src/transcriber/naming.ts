import path from 'node:path';
import fs from 'node:fs';

export function extractDateTimeFromFilename(filename: string): string | null {
	// Extract date and time (hours + minutes only) from filename patterns like:
	// 2025-06-04_140234_000.wav → 2025-06-04_1402
	// 2025-06-04-recording.mp3 → 2025-06-04
	// 20250604_meeting.wav → 2025-06-04

	const basename = path.basename(filename);

	// Pattern 1: YYYY-MM-DD_HHMMSS (TP-7 format) - extract date + hours/minutes only
	const match1 = basename.match(/(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})\d{2}/);
	if (match1) {
		return `${match1[1]}-${match1[2]}-${match1[3]}_${match1[4]}${match1[5]}`;
	}

	// Pattern 2: YYYY-MM-DD (date only)
	const match2 = basename.match(/(\d{4})-(\d{2})-(\d{2})/);
	if (match2) {
		return `${match2[1]}-${match2[2]}-${match2[3]}`;
	}

	// Pattern 3: YYYYMMDD (compact date)
	const match3 = basename.match(/(\d{4})(\d{2})(\d{2})/);
	if (match3) {
		return `${match3[1]}-${match3[2]}-${match3[3]}`;
	}

	return null;
}

export function getCurrentDate(): string {
	const now = new Date();
	const year = now.getFullYear();
	const month = String(now.getMonth() + 1).padStart(2, '0');
	const day = String(now.getDate()).padStart(2, '0');
	return `${year}-${month}-${day}`;
}

/** The folder title as a person would write it: "virtual-try-on" becomes "Virtual try on". */
export function humanizeTitle(title: string): string {
	const text = title.replace(/-/g, ' ');
	return text.charAt(0).toUpperCase() + text.slice(1);
}

/** `YYYY-MM-DDTHH:MM` as the `YYYY-MM-DD_HHMM` that starts a folder name. */
export function formatFolderPrefix(startedAt: string): string {
	return startedAt.replace('T', '_').replace(':', '');
}

/** `name`, or `name-2`, `name-3`, … when an earlier recording already took it. */
export function availablePath(parentDir: string, name: string): string {
	let candidate = path.join(parentDir, name);
	for (let suffix = 2; fs.existsSync(candidate); suffix++) {
		candidate = path.join(parentDir, `${name}-${suffix}`);
	}
	return candidate;
}

export function renameOutputFolder(
	currentPath: string,
	title: string,
	originalFilename: string,
	startedAt?: string,
): string {
	// A corrected start wins over the filename, whose clock may be unset
	const dateTime = startedAt
		? formatFolderPrefix(startedAt)
		: (extractDateTimeFromFilename(originalFilename) ?? getCurrentDate());

	const newPath = availablePath(path.dirname(currentPath), `${dateTime}-${title}`);
	fs.renameSync(currentPath, newPath);
	console.log(`📁 Renamed output folder to: ${path.basename(newPath)}`);

	return newPath;
}

export function getOutputFilenames(folderName: string): {
	raw: string;
	final: string;
} {
	return {
		raw: `${folderName}-transcript-raw.json`,
		final: `${folderName}-transcript.md`,
	};
}
