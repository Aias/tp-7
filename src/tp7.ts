import { z } from 'zod';
import type { Config } from './config.js';

const DeviceSchema = z.object({
	serial_number: z.string().nullable(),
	product: z.string().nullable(),
	mode: z.string(),
});

const LsEntrySchema = z.object({
	kind: z.string(),
	name: z.string(),
	size: z.number(),
	modified: z.string(),
});

const LsResponseSchema = z.object({
	path: z.string(),
	entries: z.array(LsEntrySchema),
});

export type Tp7Device = z.infer<typeof DeviceSchema>;
export type RemoteFile = z.infer<typeof LsEntrySchema>;

/**
 * Errors that occur while the device re-enumerates between its USB audio and
 * MTP personalities. The switch takes several seconds, during which the device
 * is reachable over neither MIDI nor MTP; retrying after a pause succeeds.
 */
const TRANSIENT_ERROR_MARKERS = [
	'No TP-7 CoreMIDI source endpoint',
	'no TP-7 devices were found',
	'MIDI operation failed',
	'MTP operation failed',
];

const RETRY_ATTEMPTS = 5;
const RETRY_DELAY_MS = 6000;

async function run(
	config: Config,
	args: string[],
	options: { retryTransient: boolean },
	attempt = 1,
): Promise<string> {
	const proc = Bun.spawn([config.tp7Bin, ...args], { stdout: 'pipe', stderr: 'pipe' });
	const [stdout, stderr, exitCode] = await Promise.all([
		new Response(proc.stdout).text(),
		new Response(proc.stderr).text(),
		proc.exited,
	]);
	if (exitCode !== 0) {
		const transient = TRANSIENT_ERROR_MARKERS.some((marker) => stderr.includes(marker));
		if (options.retryTransient && transient && attempt < RETRY_ATTEMPTS) {
			await Bun.sleep(RETRY_DELAY_MS);
			return run(config, args, options, attempt + 1);
		}
		throw new Error(`tp7 ${args.join(' ')} failed (exit ${exitCode}): ${stderr.trim()}`);
	}
	return stdout;
}

export async function listDevices(config: Config): Promise<Tp7Device[]> {
	const stdout = await run(config, ['-j', 'devices'], { retryTransient: false });
	return z.array(DeviceSchema).parse(JSON.parse(stdout));
}

/** Lists files in a device folder, switching the device into MTP mode if needed. */
export async function listFiles(config: Config, folder: string): Promise<RemoteFile[]> {
	const stdout = await run(config, ['-a', '-j', 'ls', folder], { retryTransient: true });
	const response = LsResponseSchema.parse(JSON.parse(stdout));
	return response.entries.filter((entry) => entry.kind === 'file');
}

/** Downloads one device file into destDir, switching into MTP mode if needed. */
export async function pullFile(
	config: Config,
	remotePath: string,
	destDir: string,
): Promise<void> {
	await run(config, ['-a', '--no-progress', 'pull', remotePath, `${destDir}/`], {
		retryTransient: true,
	});
}
