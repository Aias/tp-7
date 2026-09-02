#!/usr/bin/env bun
import { loadConfig } from './config.js';
import { ingest } from './ingest.js';
import { loadManifest } from './manifest.js';
import { listDevices } from './tp7.js';
import { cleanUtterance } from './transcriber/cleaning.js';
import { runFullPipeline } from './transcriber/pipeline.js';
import { parseAndValidateFile, parseSpeakersArg, validateEnvironment } from './transcriber/utils.js';
import { watch } from './watch.js';

const USAGE = `tp7sync — pull recordings off a teenage engineering TP-7 and transcribe them

Usage:
  bun src/cli.ts now                          Ingest new recordings once
  bun src/cli.ts watch                        Watch for the device and ingest on attach
  bun src/cli.ts status                       Show device presence and ingest state
  bun src/cli.ts transcribe <file> [speakers] Transcribe one local audio file (speakers: 3 or 2-5)
  bun src/cli.ts clean <text>                 Clean one dictated utterance (fillers, punctuation)
`;

const config = loadConfig();
const command = process.argv[2] ?? 'now';

switch (command) {
	case 'now': {
		validateEnvironment();
		const result = await ingest(config);
		console.log(
			`Done: ${result.pulled.length} pulled, ${result.transcribed.length} transcribed, ` +
				`${result.skipped.length} skipped.`,
		);
		break;
	}
	case 'watch': {
		validateEnvironment();
		await watch(config);
		break;
	}
	case 'status': {
		const devices = await listDevices(config).catch(() => []);
		if (devices.length === 0) {
			console.log('Device: not connected');
		} else {
			for (const device of devices) {
				console.log(`Device: ${device.product ?? 'TP-7'} (${device.serial_number ?? 'unknown'}), ${device.mode} mode`);
			}
		}
		const manifest = loadManifest(config.recordingsDir);
		const entries = Object.entries(manifest.files);
		const transcribed = entries.filter(([, entry]) => entry.status === 'transcribed').length;
		const pulled = entries.filter(([, entry]) => entry.status === 'pulled').length;
		console.log(
			`Manifest: ${entries.length} recordings tracked ` +
				`(${transcribed} transcribed, ${pulled} pulled but not transcribed).`,
		);
		break;
	}
	case 'transcribe': {
		validateEnvironment();
		const inputPath = parseAndValidateFile(process.argv[3], '⛔ Please provide an audio file path');
		const speakers = parseSpeakersArg(process.argv[4]);
		await runFullPipeline({ inputPath, speakers });
		break;
	}
	case 'clean': {
		validateEnvironment();
		const text = process.argv[3]?.trim();
		if (!text) {
			console.error('⛔ Please provide the text to clean');
			process.exit(1);
		}
		process.stdout.write(await cleanUtterance(text));
		break;
	}
	default: {
		console.log(USAGE);
		process.exit(command === 'help' || command === '--help' ? 0 : 1);
	}
}
