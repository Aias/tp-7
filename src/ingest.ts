import fs from 'node:fs';
import path from 'node:path';
import type { Config } from './config.js';
import { loadManifest, saveManifest, type Manifest } from './manifest.js';
import { listDevices, listFiles, pullFile, type RemoteFile } from './tp7.js';
import { runFullPipeline } from './transcriber/pipeline.js';

const AUDIO_EXTENSIONS = new Set(['.wav', '.mp3']);

/**
 * Recordings and their transcript folders share a filename prefix:
 * `2026-08-11_150648_000.wav` belongs to `2026-08-11_1506-<title>/`.
 */
const GROUP_PREFIX_LENGTH = '2026-08-11_1506'.length;

export interface IngestResult {
	pulled: string[];
	transcribed: string[];
	skipped: string[];
}

export async function ingest(config: Config): Promise<IngestResult> {
	const result: IngestResult = { pulled: [], transcribed: [], skipped: [] };
	const devices = await listDevices(config);
	if (devices.length === 0) {
		console.log('No TP-7 connected.');
		return result;
	}

	fs.mkdirSync(config.recordingsDir, { recursive: true });
	const releaseLock = acquireLock(config.recordingsDir);
	try {
		const manifest = loadManifest(config.recordingsDir);
		for (const folder of config.deviceFolders) {
			const files = await listFiles(config, folder);
			for (const file of files) {
				await ingestFile(config, manifest, folder, file, result);
			}
		}
		return result;
	} finally {
		releaseLock();
	}
}

async function ingestFile(
	config: Config,
	manifest: Manifest,
	deviceFolder: string,
	file: RemoteFile,
	result: IngestResult,
): Promise<void> {
	if (!AUDIO_EXTENSIONS.has(path.extname(file.name).toLowerCase())) {
		return;
	}
	const known = manifest.files[file.name];
	if (known && known.size === file.size) {
		return;
	}
	if (secondsSince(file.modified) < config.minFileAgeSeconds) {
		console.log(`⏳ Skipping ${file.name} — modified too recently, may still be recording.`);
		result.skipped.push(file.name);
		return;
	}
	if (existsLocally(config.recordingsDir, file.name)) {
		manifest.files[file.name] = {
			size: file.size,
			status: 'preexisting',
			pulledAt: null,
			folder: findGroupFolder(config.recordingsDir, file.name),
		};
		saveManifest(config.recordingsDir, manifest);
		return;
	}

	console.log(`⬇️  Pulling ${file.name} (${formatSize(file.size)})...`);
	await pullFile(config, `${deviceFolder}/${file.name}`, config.recordingsDir);
	const localPath = path.join(config.recordingsDir, file.name);
	const localSize = fs.statSync(localPath).size;
	if (localSize !== file.size) {
		throw new Error(
			`Size mismatch for ${file.name}: device ${file.size}, local ${localSize}`,
		);
	}
	manifest.files[file.name] = {
		size: file.size,
		status: 'pulled',
		pulledAt: new Date().toISOString(),
		folder: null,
	};
	saveManifest(config.recordingsDir, manifest);
	result.pulled.push(file.name);

	if (!config.transcribe) {
		return;
	}
	console.log(`📝 Transcribing ${file.name}...`);
	await runFullPipeline({ inputPath: localPath });
	const folder = groupRecording(config.recordingsDir, file.name);
	manifest.files[file.name] = {
		size: file.size,
		status: 'transcribed',
		pulledAt: manifest.files[file.name]?.pulledAt ?? null,
		folder,
	};
	saveManifest(config.recordingsDir, manifest);
	result.transcribed.push(file.name);
	notify('TP-7 recording transcribed', folder ?? file.name);
}

/**
 * Moves a pulled recording into the transcript folder the pipeline created for
 * it, so the raw audio, transcripts, and summary live together.
 */
function groupRecording(recordingsDir: string, fileName: string): string | null {
	const folder = findGroupFolder(recordingsDir, fileName);
	if (!folder) {
		console.warn(`⚠️  No transcript folder found for ${fileName}; leaving it at top level.`);
		return null;
	}
	fs.renameSync(path.join(recordingsDir, fileName), path.join(recordingsDir, folder, fileName));
	return folder;
}

function findGroupFolder(recordingsDir: string, fileName: string): string | null {
	const prefix = fileName.slice(0, GROUP_PREFIX_LENGTH);
	const matches = fs
		.readdirSync(recordingsDir, { withFileTypes: true })
		.filter((entry) => entry.isDirectory() && entry.name.startsWith(prefix))
		.map((entry) => entry.name);
	return matches.length === 1 ? (matches[0] ?? null) : null;
}

function existsLocally(recordingsDir: string, fileName: string): boolean {
	if (fs.existsSync(path.join(recordingsDir, fileName))) {
		return true;
	}
	const folder = findGroupFolder(recordingsDir, fileName);
	return folder !== null;
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

function acquireLock(recordingsDir: string): () => void {
	const lockDir = path.join(recordingsDir, '.tp7sync');
	fs.mkdirSync(lockDir, { recursive: true });
	const lockFile = path.join(lockDir, 'lock');
	try {
		fs.writeFileSync(lockFile, String(process.pid), { flag: 'wx' });
	} catch {
		const holder = Number(fs.readFileSync(lockFile, 'utf-8'));
		if (!Number.isNaN(holder) && isProcessAlive(holder)) {
			throw new Error(`Another ingest is running (pid ${holder}).`);
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
