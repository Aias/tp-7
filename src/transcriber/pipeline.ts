import fs from 'node:fs';
import path from 'node:path';
import { createOutputFolder, timed, type SpeakerHint } from './utils.js';
import { convertToFlac } from './audio.js';
import { transcribe, type TranscriptionResult } from './transcription.js';
import { summarizeAndTitle } from './summarization.js';
import { cleanTranscript, renderTranscript } from './cleaning.js';
import { renameOutputFolder, getOutputFilenames } from './naming.js';
import {
	refineSpeakerIdentification,
	logSpeakerIdentification,
	renderUtterances,
} from './speaker-identification.js';
import { getKnownSpeakers } from './transcription.config.loader.js';
import { MODELS } from './openai.js';

export interface TranscriptionOptions {
	inputPath: string;
	speakers?: SpeakerHint;
	outputDir?: string;
}

/**
 * Run only the transcription step
 */
export async function runTranscriptionOnly(options: TranscriptionOptions): Promise<{
	outputDir: string;
	transcriptionOutput: TranscriptionResult;
	transcriptPath: string;
}> {
	const { inputPath, speakers } = options;

	// Create output folder if not provided
	const outputDir = options.outputDir || createOutputFolder(inputPath);
	console.log(`📁 Output folder: ${outputDir}`);

	const audioPath = await timed('Conversion', () => convertToFlac(inputPath, outputDir));

	// Transcribe and get sentences/paragraphs
	const result = await timed('Transcription', () => transcribe(audioPath, speakers));

	// Save the complete output to JSON
	const jsonPath = path.join(outputDir, 'transcript-raw.json');
	fs.writeFileSync(jsonPath, JSON.stringify(result, null, 2));
	console.log(`✅ Raw transcript saved → ${jsonPath}`);

	return { outputDir, transcriptionOutput: result, transcriptPath: jsonPath };
}

/**
 * Edit the transcript, resolve speaker names, and summarize it. The summary
 * reads the transcript as AssemblyAI heard it, under the resolved names, so it
 * starts as soon as the names are known and runs alongside the editing.
 */
async function cleanAndSummarize(transcriptionOutput: TranscriptionResult) {
	const knownSpeakers = await getKnownSpeakers();
	const cleaning = timed('Cleaning', () => cleanTranscript(transcriptionOutput));
	const reconciliation = timed('Speaker reconciliation', () =>
		refineSpeakerIdentification(transcriptionOutput.transcript, knownSpeakers),
	);
	const summary = reconciliation
		.then((speakerMap) =>
			timed('Summary', () =>
				summarizeAndTitle(
					renderUtterances(transcriptionOutput.transcript, speakerMap),
					MODELS.judgment,
				),
			),
		)
		.catch((error: unknown) => {
			console.error(
				'\n⚠️  Summarization failed:',
				error instanceof Error ? error.message : String(error),
			);
			return null;
		});

	const [groups, speakerMap, summarized] = await Promise.all([cleaning, reconciliation, summary]);
	logSpeakerIdentification(speakerMap);
	return { transcript: renderTranscript(groups, speakerMap), summarized };
}

/**
 * Run the full pipeline: transcribe, edit, summarize, then file the transcript
 * and its raw JSON in a folder named for the recording's time and title.
 */
export async function runFullPipeline(options: TranscriptionOptions): Promise<void> {
	const { inputPath, speakers } = options;

	const { outputDir, transcriptionOutput, transcriptPath } = await runTranscriptionOnly({
		inputPath,
		speakers,
	});

	const { transcript, summarized } = await cleanAndSummarize(transcriptionOutput);

	const folder = renameOutputFolder(outputDir, summarized?.title ?? 'untitled', inputPath);
	const filenames = getOutputFilenames(path.basename(folder));
	const rawPath = path.join(folder, filenames.raw);
	fs.renameSync(path.join(folder, path.basename(transcriptPath)), rawPath);
	const finalPath = path.join(folder, filenames.final);
	fs.writeFileSync(
		finalPath,
		summarized
			? `## Summary\n\n${summarized.summary}\n\n---\n\n## Transcript\n\n${transcript}\n`
			: `## Transcript\n\n${transcript}\n`,
	);

	console.log(`\n📄 Raw transcript saved → ${rawPath}`);
	console.log(`📝 Transcript saved → ${finalPath}`);
	console.log('\n---\n');
	if (summarized) {
		console.log('## Summary\n\n' + summarized.summary + '\n');
		console.log('---\n');
		console.log(transcript);
	} else {
		console.log('## Transcript\n');
		console.log(transcript);
	}
}
