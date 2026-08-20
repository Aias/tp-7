import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { z } from 'zod';

const ConfigSchema = z.object({
	/** Where pulled recordings and their transcript folders live. */
	recordingsDir: z.string(),
	/** Path to the tp7 CLI binary (built by scripts/setup-tp7-cli.sh). */
	tp7Bin: z.string(),
	/** Folders on the device to ingest from. */
	deviceFolders: z.array(z.string()),
	/** Seconds between device-presence polls in watch mode. */
	pollIntervalSeconds: z.number().positive(),
	/** Seconds to wait after the device appears before ingesting. */
	attachSettleSeconds: z.number().nonnegative(),
	/** Skip device files modified more recently than this — they may still be recording. */
	minFileAgeSeconds: z.number().nonnegative(),
	/** Run the transcription pipeline after pulling. */
	transcribe: z.boolean(),
});

export type Config = z.infer<typeof ConfigSchema>;

const CONFIG_PATH = path.join(os.homedir(), '.config', 'tp7sync', 'config.json');

const defaults: Config = {
	recordingsDir: path.join(os.homedir(), 'Music', 'recordings'),
	tp7Bin: 'tp7',
	deviceFolders: ['/recordings', '/memo'],
	pollIntervalSeconds: 15,
	attachSettleSeconds: 20,
	minFileAgeSeconds: 120,
	transcribe: true,
};

export function loadConfig(): Config {
	if (!fs.existsSync(CONFIG_PATH)) {
		return defaults;
	}
	const raw: unknown = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf-8'));
	const overrides = ConfigSchema.partial().parse(raw);
	return { ...defaults, ...overrides };
}
