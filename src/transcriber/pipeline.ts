import fs from 'node:fs';
import path from 'node:path';
import { z } from 'zod';
import { createOutputFolder, type SpeakerHint } from './utils.js';
import { convertToFlac } from './audio.js';
import { transcribe, type TranscriptionResult } from './transcription.js';
import { summarize } from './summarization.js';
import { cleanTranscript, renderTranscript } from './cleaning.js';
import { renameOutputFolder, getOutputFilenames } from './naming.js';
import { refineSpeakerIdentification, logSpeakerIdentification } from './speaker-identification.js';
import { getKnownSpeakers } from './transcription.config.loader.js';

export interface TranscriptionOptions {
	inputPath: string;
	speakers?: SpeakerHint;
	outputDir?: string;
}

export interface CleaningOptions {
	transcriptPath: string;
	transcriptData?: TranscriptionResult;
}

export interface SummarizationOptions {
	transcript: string;
	outputDir: string;
	originalFilename: string;
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

	const audioPath = await convertToFlac(inputPath, outputDir);

	// Transcribe and get sentences/paragraphs
	const result = await transcribe(audioPath, speakers);

	// Save the complete output to JSON
	const jsonPath = path.join(outputDir, 'transcript-raw.json');
	fs.writeFileSync(jsonPath, JSON.stringify(result, null, 2));
	console.log(`✅ Raw transcript saved → ${jsonPath}`);

	return { outputDir, transcriptionOutput: result, transcriptPath: jsonPath };
}

// Schema for the complete transcription output
const TranscriptionResultSchema = z.object({
	transcript: z.any(),
	sentences: z.any(),
	paragraphs: z.any(),
});

/**
 * Run only the cleaning step on an existing transcript
 */
export async function runCleaningOnly(options: CleaningOptions): Promise<string> {
	const { transcriptPath } = options;
	let transcriptionOutput: TranscriptionResult;

	// Check if we have transcript data provided or need to load it
	if (options.transcriptData) {
		transcriptionOutput = options.transcriptData;
	} else {
		// Load transcript from JSON file
		console.log(`📖 Reading transcript JSON from ${transcriptPath}...`);
		const jsonContent = fs.readFileSync(transcriptPath, 'utf-8');

		try {
			const parsed = JSON.parse(jsonContent) as unknown;
			// Validate the parsed JSON has the required structure
			const validated = TranscriptionResultSchema.parse(parsed);
			transcriptionOutput = validated as TranscriptionResult; // We're trusting our own output schema here.
		} catch (error) {
			if (error instanceof z.ZodError) {
				console.error('❌ Invalid transcript JSON structure:', error.message);
				throw new Error(`Invalid transcript file: ${transcriptPath}`, { cause: error });
			}
			throw error;
		}
	}

	// Resolving speaker names and editing the passages are independent — names are
	// applied when the transcript is rendered — so both run at once.
	const [speakerMap, groups] = await Promise.all([
		getKnownSpeakers().then((knownSpeakers) =>
			refineSpeakerIdentification(transcriptionOutput.transcript, knownSpeakers),
		),
		cleanTranscript(transcriptionOutput),
	]);
	logSpeakerIdentification(speakerMap);

	return renderTranscript(groups, speakerMap);
}

/**
 * Summarize the transcript, title the output folder from the summary, and
 * save the summary and transcript together in it.
 */
export async function runSummarizationOnly(options: SummarizationOptions): Promise<{
	summaryPath: string;
	summary: string;
}> {
	const { transcript, originalFilename } = options;
	const summary = await summarize(transcript);

	console.log('💾 Writing summary...');
	fs.writeFileSync(
		path.join(options.outputDir, 'summary.md'),
		`## Summary\n\n${summary}\n\n---\n\n## Transcript\n\n${transcript}\n`,
	);

	const outputDir = await renameOutputFolder(options.outputDir, summary, originalFilename);
	const summaryPath = path.join(outputDir, getOutputFilenames(path.basename(outputDir)).final);
	fs.renameSync(path.join(outputDir, 'summary.md'), summaryPath);

	console.log(`✅ Summary saved → ${summaryPath}`);
	return { summaryPath, summary };
}

/**
 * Run the full pipeline (backward compatibility)
 */
export async function runFullPipeline(options: TranscriptionOptions): Promise<void> {
	const { inputPath, speakers } = options;

	// Step 1: Transcribe
	const { outputDir, transcriptionOutput, transcriptPath } = await runTranscriptionOnly({
		inputPath,
		speakers,
	});

	// Step 2: Resolve speaker names and clean
	const cleanedText = await runCleaningOnly({
		transcriptPath,
		transcriptData: transcriptionOutput,
	});

	// Step 3: Summarize with folder renaming
	try {
		const { summaryPath, summary } = await runSummarizationOnly({
			transcript: cleanedText,
			outputDir,
			originalFilename: inputPath,
		});

		// Rename the raw transcript to match the folder name
		const finalOutputDir = path.dirname(summaryPath);
		const currentRawPath = path.join(finalOutputDir, path.basename(transcriptPath));
		const newRawPath = path.join(
			finalOutputDir,
			getOutputFilenames(path.basename(finalOutputDir)).raw,
		);
		if (fs.existsSync(currentRawPath)) {
			fs.renameSync(currentRawPath, newRawPath);
		}

		// Print results
		console.log(`\n📄 Raw transcript saved → ${newRawPath}`);
		console.log(`📝 Transcript saved → ${summaryPath}`);
		console.log('\n---\n');
		console.log('## Summary\n\n' + summary + '\n');
		console.log('---\n');
		console.log(cleanedText);
	} catch (error) {
		console.error(
			'\n⚠️  Summarization failed:',
			error instanceof Error ? error.message : String(error),
		);

		// Still rename folder with basic naming if summary failed
		const { extractDateTimeFromFilename, getCurrentDate } = await import('./naming.js');
		const dateTime = extractDateTimeFromFilename(inputPath) ?? getCurrentDate();
		const newFolderName = `${dateTime}-untitled`;
		const newPath = path.join(path.dirname(outputDir), newFolderName);

		if (outputDir !== newPath && fs.existsSync(outputDir)) {
			fs.renameSync(outputDir, newPath);
		}
		if (fs.existsSync(newPath)) {
			const filenames = getOutputFilenames(newFolderName);
			const currentRawPath = path.join(newPath, path.basename(transcriptPath));
			if (fs.existsSync(currentRawPath)) {
				fs.renameSync(currentRawPath, path.join(newPath, filenames.raw));
			}
			const finalPath = path.join(newPath, filenames.final);
			fs.writeFileSync(finalPath, `## Transcript\n\n${cleanedText}\n`);
			console.log(`\n📝 Transcript saved → ${finalPath}`);
		}
		console.log('\n---\n');
		console.log('## Transcript\n');
		console.log(cleanedText);
	}
}
