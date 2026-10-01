#!/usr/bin/env bun
import { loadConfig } from './config.js';
import { emit } from './events.js';
import { ingest, pull, transcribePulled } from './ingest.js';
import { loadManifest } from './manifest.js';
import { redate } from './redate.js';
import { listDevices } from './tp7.js';
import { cleanUtterance } from './transcriber/cleaning.js';
import { streamLive } from './transcriber/live.js';
import { humanizeTitle } from './transcriber/naming.js';
import { MODELS } from './transcriber/openai.js';
import { runFullPipeline } from './transcriber/pipeline.js';
import { summarizeAndTitle } from './transcriber/summarization.js';
import { parseAndValidateFile, parseSpeakersArg, validateEnvironment } from './transcriber/utils.js';

const USAGE = `tp7sync — pull recordings off a teenage engineering TP-7 and transcribe them

Usage:
  bun src/cli.ts now                          Ingest new recordings once (pull, then transcribe)
  bun src/cli.ts pull                         Pull new recordings off the device
  bun src/cli.ts transcribe-pulled            Transcribe pulled recordings
  bun src/cli.ts redate <file> <when>         Correct a recording's start ("YYYY-MM-DD HH:MM" or "HH:MM" today)
  bun src/cli.ts status                       Show device presence and ingest state
  bun src/cli.ts transcribe <file> [speakers] Transcribe one local audio file (speakers: 3 or 2-5)
  bun src/cli.ts clean <text>                 Clean one dictated utterance (fillers, punctuation)
  bun src/cli.ts draft-summary <file>         Summarize a live transcript with the fast model
  bun src/cli.ts live                         Stream 16 kHz mono PCM from stdin; print diarized turns as JSON lines
`;

const config = loadConfig();
const command = process.argv[2] ?? 'now';

switch (command) {
	case 'now': {
		validateEnvironment();
		const result = await ingest(config);
		console.log(
			`Done: ${result.pulled.length} pulled, ${result.transcribed.length} transcribed, ` +
				`${result.skipped.length} skipped, ${result.failed.length} failed.`,
		);
		process.exitCode = result.failed.length > 0 ? 1 : 0;
		break;
	}
	case 'pull': {
		const result = await pull(config);
		console.log(`Done: ${result.pulled.length} pulled, ${result.skipped.length} skipped.`);
		break;
	}
	case 'transcribe-pulled': {
		validateEnvironment();
		const result = await transcribePulled(config);
		console.log(
			`Done: ${result.transcribed.length} transcribed, ${result.failed.length} failed.`,
		);
		process.exitCode = result.failed.length > 0 ? 1 : 0;
		break;
	}
	case 'redate': {
		const file = process.argv[3];
		const when = process.argv.slice(4).join(' ');
		if (!file || !when) {
			console.error('⛔ Usage: redate <device-file-name> <YYYY-MM-DD HH:MM | HH:MM>');
			process.exit(1);
		}
		try {
			redate(config, file, when);
		} catch (error) {
			console.error(`⛔ ${error instanceof Error ? error.message : String(error)}`);
			process.exit(1);
		}
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
	case 'draft-summary': {
		validateEnvironment();
		const filePath = parseAndValidateFile(
			process.argv[3],
			'⛔ Please provide a live transcript file',
		);
		const text = await Bun.file(filePath).text();
		const transcript = text.replace(/^# Live transcript\s*/, '').trim();
		if (!transcript) {
			console.error('⛔ The live transcript has no text');
			process.exit(1);
		}
		const { title, summary } = await summarizeAndTitle(transcript, MODELS.mechanical);
		emit({ event: 'draft', title: humanizeTitle(title), summary });
		break;
	}
	case 'live': {
		validateEnvironment();
		await streamLive(Bun.stdin.stream());
		break;
	}
	default: {
		console.log(USAGE);
		process.exit(command === 'help' || command === '--help' ? 0 : 1);
	}
}
