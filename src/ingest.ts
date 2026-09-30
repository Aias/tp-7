import fs from 'node:fs';
import path from 'node:path';
import type { Config } from './config.js';
import { loadManifest, updateManifest, type ManifestEntry } from './manifest.js';
import { listDevices, listFiles, pullFile, type RemoteFile } from './tp7.js';
import { runFullPipeline } from './transcriber/pipeline.js';

const AUDIO_EXTENSIONS = new Set(['.wav', '.mp3']);

/**
 * Recordings and their transcript folders share a filename prefix:
 * `2026-08-11_150648_000.wav` belongs to `2026-08-11_1506-<title>/`.
 */
const GROUP_PREFIX_LENGTH = '2026-08-11_1506'.length;

/** The device names recordings from its clock, which restarts at 1980-01-01 when unset. */
const UNSET_CLOCK_PREFIX = '1980-';

export interface PullResult {
	pulled: string[];
	skipped: string[];
}

export interface TranscribeResult {
	transcribed: string[];
	failed: string[];
}

export async function ingest(config: Config): Promise<PullResult & TranscribeResult> {
	const pulled = await pull(config);
	const transcribed = await transcribePulled(config);
	return { ...pulled, ...transcribed };
}

/**
 * Copies new device recordings into their local folders. This is the only
 * phase that needs the device, which leaves audio mode while it runs.
 */
export async function pull(config: Config): Promise<PullResult> {
	const result: PullResult = { pulled: [], skipped: [] };
	const devices = await listDevices(config);
	if (devices.length === 0) {
		console.log('No TP-7 connected.');
		return result;
	}
	const releaseLock = acquireLock(config.recordingsDir, 'pull');
	if (!releaseLock) {
		throw new Error('Another pull is running.');
	}
	try {
		for (const [deviceFolder, localFolder] of Object.entries(config.deviceFolders)) {
			fs.mkdirSync(path.join(config.recordingsDir, localFolder), { recursive: true });
			const files = await listFiles(config, deviceFolder);
			for (const file of files) {
				await pullNewFile(config, deviceFolder, localFolder, file, result);
			}
		}
	} finally {
		releaseLock();
	}
	const misdated = result.pulled.filter((name) => name.startsWith(UNSET_CLOCK_PREFIX));
	if (misdated.length > 0) {
		console.warn(`⚠️  TP-7 clock is unset: ${misdated.join(', ')}`);
		notify('TP-7 clock is unset', misdated.join(', '));
	}
	return result;
}

async function pullNewFile(
	config: Config,
	deviceFolder: string,
	localFolder: string,
	file: RemoteFile,
	result: PullResult,
): Promise<void> {
	if (!AUDIO_EXTENSIONS.has(path.extname(file.name).toLowerCase())) {
		return;
	}
	const known = loadManifest(config.recordingsDir).files[file.name];
	if (known && known.size === file.size) {
		return;
	}
	if (secondsSince(file.modified) < config.minFileAgeSeconds) {
		console.log(`⏳ Skipping ${file.name} — modified too recently, may still be recording.`);
		result.skipped.push(file.name);
		return;
	}
	const existing = findLocal(config.recordingsDir, localFolder, file.name);
	if (existing) {
		updateManifest(config.recordingsDir, (manifest) => {
			manifest.files[file.name] = {
				size: file.size,
				status: 'preexisting',
				pulledAt: null,
				folder: existing,
			};
		});
		return;
	}

	console.log(`⬇️  Pulling ${file.name} (${formatSize(file.size)})...`);
	const localDir = path.join(config.recordingsDir, localFolder);
	await pullFile(config, `${deviceFolder}/${file.name}`, localDir);
	const localSize = fs.statSync(path.join(localDir, file.name)).size;
	if (localSize !== file.size) {
		throw new Error(
			`Size mismatch for ${file.name}: device ${file.size}, local ${localSize}`,
		);
	}
	updateManifest(config.recordingsDir, (manifest) => {
		manifest.files[file.name] = {
			size: file.size,
			status: 'pulled',
			pulledAt: new Date().toISOString(),
			folder: localFolder,
		};
	});
	result.pulled.push(file.name);
}

/**
 * Transcribes every pulled recording, including ones a new pull adds while
 * this runs. A second run while one is in progress leaves the work to it.
 */
export async function transcribePulled(config: Config): Promise<TranscribeResult> {
	const result: TranscribeResult = { transcribed: [], failed: [] };
	if (!config.transcribe) {
		return result;
	}
	const releaseLock = acquireLock(config.recordingsDir, 'transcribe');
	if (!releaseLock) {
		console.log('Transcription is already running.');
		return result;
	}
	try {
		const attempted = new Set<string>();
		for (;;) {
			const next = nextPulled(config.recordingsDir, attempted);
			if (!next) {
				return result;
			}
			const [name, entry] = next;
			attempted.add(name);
			try {
				await transcribeRecording(config, name, entry.folder);
				result.transcribed.push(name);
			} catch (error) {
				console.error(
					`❌ Transcribing ${name} failed:`,
					error instanceof Error ? error.message : error,
				);
				result.failed.push(name);
			}
		}
	} finally {
		releaseLock();
	}
}

function nextPulled(
	recordingsDir: string,
	attempted: Set<string>,
): [string, ManifestEntry] | undefined {
	return Object.entries(loadManifest(recordingsDir).files).find(
		([name, entry]) => entry.status === 'pulled' && !attempted.has(name),
	);
}

async function transcribeRecording(config: Config, name: string, folder: string): Promise<void> {
	const dir = path.join(config.recordingsDir, folder);
	console.log(`📝 Transcribing ${name}...`);
	await runFullPipeline({ inputPath: path.join(dir, name) });
	const group = groupRecording(dir, name);
	updateManifest(config.recordingsDir, (manifest) => {
		const entry = manifest.files[name];
		if (entry) {
			entry.status = 'transcribed';
			entry.folder = group ? path.join(folder, group) : folder;
		}
	});
	notify('TP-7 recording transcribed', group ?? name);
}

/**
 * Moves a pulled recording into the transcript folder the pipeline created for
 * it, so the raw audio, transcripts, and summary live together.
 */
function groupRecording(dir: string, fileName: string): string | null {
	const folder = findGroupFolder(dir, fileName);
	if (!folder) {
		console.warn(`⚠️  No transcript folder found for ${fileName}; leaving it flat.`);
		return null;
	}
	fs.renameSync(path.join(dir, fileName), path.join(dir, folder, fileName));
	return folder;
}

function findGroupFolder(dir: string, fileName: string): string | null {
	const prefix = fileName.slice(0, GROUP_PREFIX_LENGTH);
	const matches = fs
		.readdirSync(dir, { withFileTypes: true })
		.filter((entry) => entry.isDirectory() && entry.name.startsWith(prefix))
		.map((entry) => entry.name);
	return matches.length === 1 ? (matches[0] ?? null) : null;
}

/** The folder (relative to recordingsDir) already holding a recording, if any. */
function findLocal(recordingsDir: string, localFolder: string, fileName: string): string | null {
	const dir = path.join(recordingsDir, localFolder);
	if (fs.existsSync(path.join(dir, fileName))) {
		return localFolder;
	}
	const group = findGroupFolder(dir, fileName);
	return group ? path.join(localFolder, group) : null;
}

/** Parses the device's compact timestamps (`20260811T151458`, device-local time). */
function secondsSince(modified: string): number {
	const match = modified.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})$/);
	if (!match) {
		return Number.POSITIVE_INFINITY;
	}
	const [, year, month, day, hour, minute, second] = match;
	const date = new Date(
		Number(year),
		Number(month) - 1,
		Number(day),
		Number(hour),
		Number(minute),
		Number(second),
	);
	return (Date.now() - date.getTime()) / 1000;
}

/** Returns a release function, or null when a live process holds the lock. */
function acquireLock(recordingsDir: string, name: string): (() => void) | null {
	const lockDir = path.join(recordingsDir, '.tp7sync');
	fs.mkdirSync(lockDir, { recursive: true });
	const lockFile = path.join(lockDir, `${name}.lock`);
	try {
		fs.writeFileSync(lockFile, String(process.pid), { flag: 'wx' });
	} catch {
		const holder = Number(fs.readFileSync(lockFile, 'utf-8'));
		if (!Number.isNaN(holder) && isProcessAlive(holder)) {
			return null;
		}
		fs.writeFileSync(lockFile, String(process.pid));
	}
	return () => fs.rmSync(lockFile, { force: true });
}

function isProcessAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

function notify(title: string, message: string): void {
	Bun.spawnSync([
		'osascript',
		'-e',
		`display notification ${JSON.stringify(message)} with title ${JSON.stringify(title)}`,
	]);
}

function formatSize(bytes: number): string {
	const megabytes = bytes / (1024 * 1024);
	return megabytes >= 1024 ? `${(megabytes / 1024).toFixed(1)}G` : `${Math.round(megabytes)}M`;
}
