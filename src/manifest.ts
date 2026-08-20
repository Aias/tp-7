import fs from 'node:fs';
import path from 'node:path';
import { z } from 'zod';

const ManifestEntrySchema = z.object({
	size: z.number(),
	status: z.enum(['pulled', 'transcribed', 'preexisting']),
	pulledAt: z.string().nullable(),
	/** Folder (relative to recordingsDir) the recording was grouped into. */
	folder: z.string().nullable(),
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

export function saveManifest(recordingsDir: string, manifest: Manifest): void {
	const file = manifestPath(recordingsDir);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, `${JSON.stringify(manifest, null, 2)}\n`);
}
