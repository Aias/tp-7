import fs from 'node:fs';
import path from 'node:path';
import type { Config } from './config.js';
import { loadManifest, updateManifest, type ManifestEntry } from './manifest.js';
import { listDevices, listFiles, pullFile, type RemoteFile } from './tp7.js';
import { processWithPool } from './transcriber/concurrency.js';
import { runFullPipeline } from './transcriber/pipeline.js';

const AUDIO_EXTENSIONS = new Set(['.wav', '.mp3']);

const TRANSCRIBE_CONCURRENCY = 3;

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
 * Transcribes every pulled recording, a few at a time, including ones a new
 * pull adds while this runs. A second run while one is in progress leaves the
 * work to it.
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
			const batch = pendingRecordings(config.recordingsDir, attempted);
			if (batch.length === 0) {
				return result;
			}
			for (const [name] of batch) {
				attempted.add(name);
			}
			await processWithPool(
				batch,
				async ([name, entry]) => {
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
				},
				{ concurrency: TRANSCRIBE_CONCURRENCY },
			);
		}
	} finally {
		releaseLock();
	}
}

function pendingRecordings(
	recordingsDir: string,
	attempted: Set<string>,
): [string, ManifestEntry][] {
	return Object.entries(loadManifest(recordingsDir).files).filter(
		([name, entry]) => entry.status === 'pulled' && !attempted.has(name),
	);
}

async function transcribeRecording(config: Config, name: string, folder: string): Promise<void> {
	const inputPath = path.join(config.recordingsDir, folder, name);
	console.log(`📝 Transcribing ${name}...`);
	const result = await runFullPipeline({ inputPath });
	fs.renameSync(inputPath, path.join(result.folder, name));
	updateManifest(config.recordingsDir, (manifest) => {
		const entry = manifest.files[name];
		if (entry) {
			entry.status = 'transcribed';
			entry.folder = path.relative(config.recordingsDir, result.folder);
		}
	});
	notify('TP-7 recording transcribed', path.basename(result.folder));
}

/**
 * The folder (relative to recordingsDir) already holding a recording, if any.
 * A recording's transcript folder is the one beside it holding a file named
 * for its stem, such as the `<stem>.16k.flac` the pipeline leaves behind.
 */
function findLocal(recordingsDir: string, localFolder: string, fileName: string): string | null {
	const dir = path.join(recordingsDir, localFolder);
	const stem = path.parse(fileName).name;
	if (fs.existsSync(path.join(dir, fileName)) || fs.existsSync(path.join(dir, `${stem}.flac`))) {
		return localFolder;
	}
	const holder = fs
		.readdirSync(dir, { withFileTypes: true })
		.find(
			(entry) =>
				entry.isDirectory() &&
				fs.readdirSync(path.join(dir, entry.name)).some((name) => name.startsWith(stem)),
		);
	return holder ? path.join(localFolder, holder.name) : null;
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
