import path from 'node:path';
import ffmpeg from 'fluent-ffmpeg';
import ffmpegPath from 'ffmpeg-static';

function resolveFfmpegPath(): string {
	if (!ffmpegPath) {
		throw new Error('ffmpeg-static has no ffmpeg binary for this platform');
	}
	return ffmpegPath;
}

const FFMPEG_PATH = resolveFfmpegPath();
ffmpeg.setFfmpegPath(FFMPEG_PATH);

// A FLAC that decodes to a different length than its source is a failed encode.
const MAX_DURATION_DRIFT_SECONDS = 0.1;

/**
 * Downmix to the 16 kHz mono signal AssemblyAI resamples to internally, encoded
 * as FLAC. Lossless, so the model sees the same audio it would from an
 * equivalent WAV, at roughly half the bytes — and upload, not processing,
 * dominates turnaround. It is also the audio the archive keeps once the source
 * is deleted, so it must match the source's duration.
 */
export async function convertToFlac(inputPath: string, outputDir: string): Promise<string> {
	console.log('🎵 Converting audio to 16kHz mono FLAC...');
	const baseName = path.basename(inputPath, path.extname(inputPath));
	const flacPath = path.join(outputDir, `${baseName}.16k.flac`);

	await new Promise<void>((resolve, reject) =>
		ffmpeg(inputPath)
			.audioFrequency(16_000)
			.audioChannels(1)
			// FLAC otherwise inherits the source's bit depth, which for a 24-bit
			// field recording is larger than the 16-bit WAV it replaces.
			.outputOptions(['-sample_fmt', 's16'])
			.format('flac')
			.on('error', reject)
			.on('end', () => resolve())
			.save(flacPath),
	);

	const [inputDuration, flacDuration] = await Promise.all([
		readDuration(inputPath),
		readDuration(flacPath),
	]);
	if (Math.abs(inputDuration - flacDuration) > MAX_DURATION_DRIFT_SECONDS) {
		throw new Error(
			`${path.basename(flacPath)} is ${flacDuration}s long, the source ${inputDuration}s`,
		);
	}
	return flacPath;
}

async function readDuration(filePath: string): Promise<number> {
	const proc = Bun.spawn([FFMPEG_PATH, '-hide_banner', '-i', filePath], {
		stdout: 'ignore',
		stderr: 'pipe',
	});
	const stderr = await new Response(proc.stderr).text();
	await proc.exited;
	const match = stderr.match(/Duration: (\d+):(\d{2}):(\d{2}(?:\.\d+)?)/);
	if (!match) {
		throw new Error(`Could not read the duration of ${filePath}`);
	}
	return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}
