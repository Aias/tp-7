import { AssemblyAI, type StreamingTranscriber, type StreamingWord } from 'assemblyai';
import { getVocabulary } from './transcription.config.loader.js';

const assemblyai = new AssemblyAI({ apiKey: process.env.ASSEMBLYAI_API_KEY! });

const SAMPLE_RATE = 16_000;
const BYTES_PER_SECOND = SAMPLE_RATE * 2;
// The streaming API accepts 50–1000 ms of audio per message.
const CHUNK_BYTES = BYTES_PER_SECOND / 10;
const MIN_CHUNK_BYTES = BYTES_PER_SECOND / 20;
const MAX_KEYTERMS = 100;
const RECONNECT_BACKOFF_MS = 10_000;

interface LiveTurn {
	order: number;
	start: number;
	end: number;
	speaker: string | null;
	text: string;
}

const speakerOf = (label: string | undefined) =>
	label && label !== 'UNKNOWN' && label !== 'PENDING' ? label : null;

/**
 * Streams 16 kHz mono PCM from `input` to AssemblyAI with diarization and
 * writes each finished turn to stdout as a JSON line, times in seconds of
 * streamed audio. A turn that spans speakers is written as one line per
 * speaker. A dropped session reconnects on the next audio, offset by the audio
 * already streamed. SIGUSR1 ends the current turn immediately.
 */
export async function streamLive(input: ReadableStream<Uint8Array>): Promise<void> {
	const keyterms = (await getVocabulary()).slice(0, MAX_KEYTERMS);
	let session: StreamingTranscriber | undefined;
	let streamedBytes = 0;
	let nextOrder = 0;
	let retryAt = 0;

	const emit = (turn: LiveTurn) => process.stdout.write(`${JSON.stringify(turn)}\n`);

	const connect = async () => {
		const offset = streamedBytes / BYTES_PER_SECOND;
		const transcriber = assemblyai.streaming.transcriber({
			speechModel: 'assemblyai-stt-3-7-realtime',
			sampleRate: SAMPLE_RATE,
			encoding: 'pcm_s16le',
			speakerLabels: true,
			...(keyterms.length > 0 && { keytermsPrompt: keyterms }),
		});
		transcriber.on('turn', (event) => {
			if (!event.end_of_turn) return;
			const runs: { speaker: string | null; words: StreamingWord[] }[] = [];
			for (const word of event.words) {
				const speaker = speakerOf(word.speaker);
				const run = runs.at(-1);
				if (run && (!speaker || !run.speaker || speaker === run.speaker)) {
					run.speaker ??= speaker;
					run.words.push(word);
				} else {
					runs.push({ speaker, words: [word] });
				}
			}
			for (const { speaker, words } of runs) {
				emit({
					order: nextOrder++,
					start: offset + (words[0]?.start ?? 0) / 1000,
					end: offset + (words.at(-1)?.end ?? 0) / 1000,
					speaker,
					text: words.map((word) => word.text).join(' '),
				});
			}
		});
		transcriber.on('error', (error) => console.error(`live: ${error.message}`));
		transcriber.on('close', (code, reason) => {
			console.error(`live: session closed (${code} ${reason})`);
			if (session === transcriber) session = undefined;
		});
		await transcriber.connect();
		session = transcriber;
	};

	const report = (error: unknown) =>
		console.error(`live: ${error instanceof Error ? error.message : String(error)}`);

	const send = async (chunk: Uint8Array) => {
		try {
			if (!session && Date.now() >= retryAt) await connect();
			session?.sendAudio(chunk.slice().buffer);
		} catch (error) {
			retryAt = Date.now() + RECONNECT_BACKOFF_MS;
			report(error);
		}
		streamedBytes += chunk.length;
	};

	process.on('SIGUSR1', () => {
		try {
			session?.forceEndpoint();
		} catch (error) {
			report(error);
		}
	});

	let pending = new Uint8Array(0);
	for await (const data of input) {
		const joined = new Uint8Array(pending.length + data.length);
		joined.set(pending);
		joined.set(data, pending.length);
		pending = joined;
		while (pending.length >= CHUNK_BYTES) {
			await send(pending.subarray(0, CHUNK_BYTES));
			pending = pending.subarray(CHUNK_BYTES);
		}
	}
	if (pending.length >= MIN_CHUNK_BYTES) await send(pending);
	await session?.close();
}
