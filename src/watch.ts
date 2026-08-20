import type { Config } from './config.js';
import { ingest } from './ingest.js';
import { listDevices } from './tp7.js';

/**
 * The device disappears from USB for a few seconds while it re-enumerates
 * between audio and MTP modes. Requiring consecutive absent polls before
 * treating it as unplugged keeps that flicker from retriggering ingest.
 */
const ABSENT_POLLS_BEFORE_DETACHED = 3;

export async function watch(config: Config): Promise<never> {
	console.log(
		`👀 Watching for TP-7 (poll every ${config.pollIntervalSeconds}s, ` +
			`ingest ${config.attachSettleSeconds}s after attach)...`,
	);
	let attached = false;
	let absentPolls = 0;
	for (;;) {
		const present = await devicePresent(config);
		if (present) {
			absentPolls = 0;
			if (!attached) {
				attached = true;
				console.log('🔌 TP-7 attached.');
				await Bun.sleep(config.attachSettleSeconds * 1000);
				try {
					await ingest(config);
				} catch (error) {
					console.error('Ingest failed:', error instanceof Error ? error.message : error);
				}
			}
		} else if (attached) {
			absentPolls += 1;
			if (absentPolls >= ABSENT_POLLS_BEFORE_DETACHED) {
				attached = false;
				console.log('🔌 TP-7 detached.');
			}
		}
		await Bun.sleep(config.pollIntervalSeconds * 1000);
	}
}

async function devicePresent(config: Config): Promise<boolean> {
	try {
		const devices = await listDevices(config);
		return devices.length > 0;
	} catch {
		return false;
	}
}
