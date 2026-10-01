import fs from 'node:fs';
import path from 'node:path';
import { z } from 'zod';

const ManifestEntrySchema = z.object({
	size: z.number(),
	status: z.enum(['pulled', 'transcribed', 'preexisting']),
	pulledAt: z.string().nullable(),
	/** Folder (relative to recordingsDir) holding the recording. */
	folder: z.string(),
	/** Corrected start for a recording the device dated wrong, local `YYYY-MM-DDTHH:MM`. */
	startedAt: z.string().optional(),
});

const ManifestSchema = z.object({
	version: z.literal(1),
	files: z.record(z.string(), ManifestEntrySchema),
});

export type ManifestEntry = z.infer<typeof ManifestEntrySchema>;
export type Manifest = z.infer<typeof ManifestSchema>;

function manifestPath(recordingsDir: string): string {
	return path.join(recordingsDir, '.tp7sync', 'manifest.json');
}

export function loadManifest(recordingsDir: string): Manifest {
	const file = manifestPath(recordingsDir);
	if (!fs.existsSync(file)) {
		return { version: 1, files: {} };
	}
	const raw: unknown = JSON.parse(fs.readFileSync(file, 'utf-8'));
	return ManifestSchema.parse(raw);
}

/**
 * Pulling and transcribing run as separate processes, so every change rereads
 * the manifest and replaces it atomically rather than saving a stale copy.
 */
export function updateManifest(recordingsDir: string, update: (manifest: Manifest) => void): void {
	const manifest = loadManifest(recordingsDir);
	update(manifest);
	const file = manifestPath(recordingsDir);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	const staging = `${file}.${process.pid}.tmp`;
	fs.writeFileSync(staging, `${JSON.stringify(manifest, null, 2)}\n`);
	fs.renameSync(staging, file);
}
