import fs from 'node:fs';
import path from 'node:path';
import type { Config } from './config.js';
import { emit } from './events.js';
import { loadManifest, updateManifest } from './manifest.js';
import {
	availablePath,
	formatFolderPrefix,
	getCurrentDate,
	getOutputFilenames,
} from './transcriber/naming.js';

const WHEN = /^(?:(\d{4}-\d{2}-\d{2}) )?(\d{1,2}):(\d{2})$/;
const TITLED_FOLDER = /^\d{4}-\d{2}-\d{2}_\d{4}(-.+)$/;

const pad = (value: number) => String(value).padStart(2, '0');

function formatStartedAt(date: Date): string {
	return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/** `YYYY-MM-DD HH:MM`, or `HH:MM` for today, as local `YYYY-MM-DDTHH:MM`. */
function parseStartedAt(when: string): string {
	const match = when.trim().match(WHEN);
	if (!match) {
		throw new Error(`Expected "YYYY-MM-DD HH:MM" or "HH:MM", got "${when}"`);
	}
	const [, date = getCurrentDate(), hour = '', minute = ''] = match;
	const startedAt = `${date}T${hour.padStart(2, '0')}:${minute}`;
	const parsed = new Date(startedAt);
	if (Number.isNaN(parsed.getTime()) || formatStartedAt(parsed) !== startedAt) {
		throw new Error(`"${when}" is not a valid date and time`);
	}
	return startedAt;
}

function renameTitledFolder(recordingsDir: string, folder: string, startedAt: string): string {
	const oldName = path.basename(folder);
	const titleSuffix = oldName.match(TITLED_FOLDER)?.[1];
	const newPrefix = formatFolderPrefix(startedAt);
	if (titleSuffix === undefined || oldName.startsWith(`${newPrefix}-`)) {
		return folder;
	}
	const parent = path.dirname(folder);
	const newPath = availablePath(path.join(recordingsDir, parent), `${newPrefix}${titleSuffix}`);
	fs.renameSync(path.join(recordingsDir, folder), newPath);

	const newName = path.basename(newPath);
	const before = getOutputFilenames(oldName);
	const after = getOutputFilenames(newName);
	const move = (from: string, to: string) => {
		if (fs.existsSync(path.join(newPath, from))) {
			fs.renameSync(path.join(newPath, from), path.join(newPath, to));
		}
	};
	move(before.raw, after.raw);
	move(before.final, after.final);
	return path.join(parent, newName);
}

/**
 * Corrects when a device recording started, for a device whose clock was
 * unset. A recording already filed in a titled folder moves to the corrected
 * date. One not yet transcribed is filed under the corrected date when the
 * pipeline names its folder.
 */
export function redate(config: Config, file: string, when: string): void {
	const startedAt = parseStartedAt(when);
	const entry = loadManifest(config.recordingsDir).files[file];
	if (!entry) {
		throw new Error(`${file} is not in the manifest`);
	}
	const folder = renameTitledFolder(config.recordingsDir, entry.folder, startedAt);
	updateManifest(config.recordingsDir, (manifest) => {
		const current = manifest.files[file];
		if (current) {
			current.startedAt = startedAt;
			current.folder = folder;
		}
	});
	const filed = TITLED_FOLDER.test(path.basename(folder));
	console.log(`🕐 ${file} started ${startedAt.replace('T', ' ')}${filed ? ` (${folder})` : ''}`);
	emit({
		event: 'redated',
		file,
		folder: filed ? path.resolve(config.recordingsDir, folder) : null,
	});
}
