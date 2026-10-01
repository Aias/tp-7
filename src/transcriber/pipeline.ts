import fs from 'node:fs';
import path from 'node:path';
import { emit } from '../events.js';
import { createOutputFolder, timed, type SpeakerHint } from './utils.js';
import { convertToFlac } from './audio.js';
import { transcribe, type TranscriptionResult } from './transcription.js';
import { summarizeAndTitle } from './summarization.js';
import { cleanTranscript, renderTranscript } from './cleaning.js';
import { renameOutputFolder, getOutputFilenames, humanizeTitle } from './naming.js';
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
	/**
	 * The recording's corrected start, local `YYYY-MM-DDTHH:MM`. Read when the
	 * folder is named, so a correction made while the recording transcribes
	 * still applies.
	 */
	getStartedAt?: () => string | undefined;
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

	const name = path.basename(inputPath);
	emit({ event: 'stage', stage: 'converting', input: inputPath });
	const audioPath = await timed(`Conversion of ${name}`, () =>
		convertToFlac(inputPath, outputDir),
	);

	// Transcribe and get sentences/paragraphs
	emit({ event: 'stage', stage: 'transcribing', input: inputPath });
	const result = await timed(`Transcription of ${name}`, () => transcribe(audioPath, speakers));

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
async function cleanAndSummarize(transcriptionOutput: TranscriptionResult, inputPath: string) {
	const name = path.basename(inputPath);
	emit({ event: 'stage', stage: 'cleaning', input: inputPath });
	const knownSpeakers = await getKnownSpeakers();
	const cleaning = timed(`Cleaning of ${name}`, () => cleanTranscript(transcriptionOutput));
	const reconciliation = timed(`Speaker reconciliation of ${name}`, () =>
		refineSpeakerIdentification(transcriptionOutput.transcript, knownSpeakers),
	);
	const summary = reconciliation
		.then((speakerMap) => {
			emit({ event: 'stage', stage: 'summarizing', input: inputPath });
			return timed(`Summary of ${name}`, () =>
				summarizeAndTitle(
					renderUtterances(transcriptionOutput.transcript, speakerMap),
					MODELS.judgment,
				),
			);
		})
		.catch((error: unknown) => {
			console.error(
				'\n⚠️  Summarization failed:',
				error instanceof Error ? error.message : String(error),
			);
			return null;
		});

	const [groups, speakerMap, summarized] = await Promise.all([cleaning, reconciliation, summary]);
	logSpeakerIdentification(speakerMap);
	return { cleanedText: renderTranscript(groups, speakerMap), summarized };
}

export interface PipelineResult {
	/** Absolute path of the recording's titled folder. */
	folder: string;
	/** Absolute path of the final transcript inside it. */
	transcript: string;
	/** Null when there was no speech or summarization failed. */
	title: string | null;
	summary: string | null;
	speech: boolean;
}

const hasSpeech = ({ transcript }: TranscriptionResult) =>
	Boolean(transcript.words?.length) || Boolean(transcript.text?.trim());

const firstParagraph = (text: string) => text.split(/\n\s*\n/, 1)[0] ?? text;

function reportResult(input: string, result: PipelineResult): PipelineResult {
	emit({
		event: 'result',
		input,
		...result,
		summary: result.summary === null ? null : firstParagraph(result.summary),
	});
	return result;
}

function fileTranscript(
	outputDir: string,
	rawPath: string,
	options: TranscriptionOptions,
	title: string,
	markdown: string,
) {
	const folder = renameOutputFolder(outputDir, title, options.inputPath, options.getStartedAt?.());
	const filenames = getOutputFilenames(path.basename(folder));
	const newRawPath = path.join(folder, filenames.raw);
	fs.renameSync(path.join(folder, path.basename(rawPath)), newRawPath);
	const transcript = path.join(folder, filenames.final);
	fs.writeFileSync(transcript, markdown);
	console.log(`\n📄 Raw transcript saved → ${newRawPath}`);
	console.log(`📝 Transcript saved → ${transcript}`);
	return { folder, transcript };
}

/**
 * Run the full pipeline: transcribe, edit, summarize, then file the transcript
 * and its raw JSON in a folder named for the recording's time and title.
 */
export async function runFullPipeline(options: TranscriptionOptions): Promise<PipelineResult> {
	const { speakers } = options;
	const inputPath = path.resolve(options.inputPath);

	const { outputDir, transcriptionOutput, transcriptPath } = await runTranscriptionOnly({
		inputPath,
		speakers,
	});

	if (!hasSpeech(transcriptionOutput)) {
		console.log('🔇 No speech detected.');
		const { folder, transcript } = fileTranscript(
			outputDir,
			transcriptPath,
			options,
			'no-speech',
			'## Transcript\n\nNo speech was detected in this recording.\n',
		);
		return reportResult(inputPath, {
			folder,
			transcript,
			title: null,
			summary: null,
			speech: false,
		});
	}

	const { cleanedText, summarized } = await cleanAndSummarize(transcriptionOutput, inputPath);

	const { folder, transcript } = fileTranscript(
		outputDir,
		transcriptPath,
		options,
		summarized?.title ?? 'untitled',
		summarized
			? `## Summary\n\n${summarized.summary}\n\n---\n\n## Transcript\n\n${cleanedText}\n`
			: `## Transcript\n\n${cleanedText}\n`,
	);

	console.log('\n---\n');
	if (summarized) {
		console.log('## Summary\n\n' + summarized.summary + '\n');
		console.log('---\n');
	} else {
		console.log('## Transcript\n');
	}
	console.log(cleanedText);

	return reportResult(inputPath, {
		folder,
		transcript,
		title: summarized ? humanizeTitle(summarized.title) : null,
		summary: summarized?.summary ?? null,
		speech: true,
	});
}
