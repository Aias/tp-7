import { z } from 'zod';
import { zodResponseFormat } from 'openai/helpers/zod';
import { formatTimestamp } from './utils.js';
import { type TranscriptionResult } from './transcription.js';
import { getVocabulary } from './transcription.config.loader.js';
import { formatSpeakerName, type SpeakerMap } from './speaker-identification.js';
import { processWithPool } from './concurrency.js';
import { MODELS, openai } from './openai.js';

// Sentences per request. Large enough that a meeting is tens of requests rather
// than hundreds; small enough that a failure costs one passage, not the file.
const SENTENCES_PER_REQUEST = 40;
const CONCURRENCY = 10;

// Trailing characters of the preceding request carried in as context, so a
// passage that opens mid-thought still resolves.
const CONTEXT_CHARS = 500;

const EDITOR_ROLE = `You are a transcription editor working on speech-to-text output. You cannot hear the audio, so you must never guess at what was said.`;

const EDIT_RULES = `Apply exactly these edits:

1. Delete non-lexical fillers: "um", "uh", "er", "mm", and "like", "you know", "I mean" where they carry no meaning. Keep "like" when it introduces a comparison ("like a sports car") or means "such as".
2. Delete stutters, false starts, and immediate repetitions that carry no meaning ("I— I think", "the the").
3. Add or correct punctuation, capitalization, and sentence boundaries.
4. Correct a word only when it is a misrecognition of a term on the vocabulary list below. Leave every other word exactly as transcribed, even where it reads oddly — an odd transcription is evidence, a plausible substitute is invention.
5. Preserve the wording otherwise. Do not expand contractions, repair grammar, reorder clauses, paraphrase, summarize, add content, or drop content.
6. Split a passage into paragraphs at natural pauses when it runs longer than about three sentences.`;

const makeVocabularyBlock = (vocabulary: string[]) =>
	`Vocabulary — the correct spelling of every term below must be preserved exactly:
${vocabulary.join(', ')}`;

const makePassageSystemPrompt = (vocabulary: string[]) =>
	`${EDITOR_ROLE}

${EDIT_RULES}

Return only the edited passage. No commentary, no code fences.

${makeVocabularyBlock(vocabulary)}`;

const makeTurnsSystemPrompt = (vocabulary: string[]) =>
	`${EDITOR_ROLE}

You receive consecutive speaker turns from one conversation, each tagged with an id and a speaker label. The labels are context only. Conversational speech is full of fillers and false starts, so expect most turns to need edits: apply every edit below to every turn, however short, as if each turn were a passage of its own.

${EDIT_RULES}

Keep every turn separate: never move text from one turn to another, merge turns, split a turn, or reorder turns. Return the edited text of every turn under its id.

${makeVocabularyBlock(vocabulary)}`;

const makePassageUserPrompt = (text: string) =>
	`Passage to edit:
"""
${text}
"""`;

const makeTurnsUserPrompt = (context: string, turns: Turn[]) => {
	const body = `Turns to edit:
${turns.map((turn) => `<turn id="${turn.id}" speaker="${turn.speaker}">\n${turn.text}\n</turn>`).join('\n')}`;
	return context
		? `Preceding turns, for context only — do not edit or return them:
"""
…${context}
"""

${body}`
		: body;
};

const CleanedTurnsSchema = z.object({
	turns: z.array(
		z.object({
			id: z.number().int().describe('The id of the turn, copied from the input'),
			text: z
				.string()
				.describe('That turn with every edit applied: fillers, stutters, and repetitions removed'),
		}),
	),
});

const FILLER = /\b(?:um+|uh+|erm?|mm+|hmm+|you know|i mean|like)\b/i;
const REPEATED_WORD = /\b([\w']+)\W+\1\b/i;

export interface CleanedGroup {
	speaker: string;
	start: number;
	text: string;
}

interface Turn extends CleanedGroup {
	id: number;
	sentenceCount: number;
}

function splitTurns(
	sentences: { speaker: string | null; start: number; text: string }[],
	maxSentences: number,
): Turn[] {
	const first = sentences[0];
	if (!first) return [];

	const turns: Turn[] = [];
	let speaker = first.speaker ?? 'A';
	let start = first.start;
	let chunk: string[] = [];

	const flush = () => {
		if (chunk.length > 0) {
			turns.push({
				id: turns.length,
				speaker,
				start,
				text: chunk.join(' '),
				sentenceCount: chunk.length,
			});
			chunk = [];
		}
	};

	for (const sentence of sentences) {
		// A sentence with no speaker continues the current one.
		const sentenceSpeaker = sentence.speaker ?? speaker;

		if (sentenceSpeaker !== speaker || chunk.length >= maxSentences) {
			flush();
			speaker = sentenceSpeaker;
			start = sentence.start;
		}

		chunk.push(sentence.text.trim());
	}
	flush();

	return turns;
}

function packTurns(turns: Turn[], maxSentences: number): Turn[][] {
	const requests: Turn[][] = [];
	let sentenceCount = 0;
	for (const turn of turns) {
		const request = requests.at(-1);
		if (request && sentenceCount + turn.sentenceCount <= maxSentences) {
			request.push(turn);
			sentenceCount += turn.sentenceCount;
		} else {
			requests.push([turn]);
			sentenceCount = turn.sentenceCount;
		}
	}
	return requests;
}

/**
 * Edited text by turn id. A turn the model dropped or returned empty is
 * absent, so the caller keeps its original text.
 */
async function cleanTurns(
	turns: Turn[],
	context: string,
	systemPrompt: string,
): Promise<Map<number, string>> {
	const response = await openai.chat.completions.parse({
		model: MODELS.mechanical,
		reasoning_effort: 'none',
		service_tier: 'fast',
		messages: [
			{ role: 'system', content: systemPrompt },
			{ role: 'user', content: makeTurnsUserPrompt(context, turns) },
		],
		response_format: zodResponseFormat(CleanedTurnsSchema, 'cleaned_turns'),
	});

	const edited = new Map<number, string>();
	for (const { id, text } of response.choices[0]?.message.parsed?.turns ?? []) {
		const trimmed = text.trim();
		if (trimmed && !edited.has(id)) edited.set(id, trimmed);
	}
	return edited;
}

async function cleanPassage(text: string, systemPrompt: string): Promise<string> {
	const response = await openai.chat.completions.create({
		model: MODELS.mechanical,
		reasoning_effort: 'none',
		service_tier: 'fast',
		messages: [
			{ role: 'system', content: systemPrompt },
			{ role: 'user', content: makePassageUserPrompt(text) },
		],
	});

	const cleaned = response.choices[0]?.message.content?.trim();
	if (!cleaned) return text;

	return cleaned
		.replace(/^"""\n?/, '')
		.replace(/\n?"""$/, '')
		.trim();
}

/**
 * Cleans one dictated utterance destined for a text field: the same edits as
 * a transcript passage, flattened to a single line so the inserter never
 * types a newline into a field where Return might submit. Text with no
 * filler words or repeated words is returned as given, without a model call.
 */
export async function cleanUtterance(text: string): Promise<string> {
	if (!FILLER.test(text) && !REPEATED_WORD.test(text)) return text;

	const systemPrompt = makePassageSystemPrompt(await getVocabulary());
	const cleaned = await cleanPassage(text, systemPrompt);
	return cleaned.replace(/\s*\n+\s*/g, ' ');
}

/**
 * Edit the transcript several speaker turns at a time. Speaker names are
 * applied later by `renderTranscript`, so this runs without waiting on speaker
 * identification.
 */
export async function cleanTranscript(
	transcriptionResult: TranscriptionResult,
): Promise<CleanedGroup[]> {
	console.log('🧹 Cleaning transcript with AI...');
	const sentences = transcriptionResult.sentences?.sentences;

	if (!sentences || sentences.length === 0) {
		console.log('  No sentence data found');
		const text = transcriptionResult.transcript.text;
		return text ? [{ speaker: 'A', start: 0, text }] : [];
	}

	console.log(`  Found ${sentences.length} sentences to clean`);

	const systemPrompt = makeTurnsSystemPrompt(await getVocabulary());
	const turns = splitTurns(sentences, SENTENCES_PER_REQUEST);
	const requests = packTurns(turns, SENTENCES_PER_REQUEST);
	console.log(
		`  Packed ${turns.length} turns into ${requests.length} requests (parallel, concurrency=${CONCURRENCY})`,
	);

	const groups = await processWithPool(
		requests,
		async (request, index) => {
			const previous = requests[index - 1];
			const context = previous
				? previous
						.map((turn) => `Speaker ${turn.speaker}: ${turn.text}`)
						.join('\n')
						.slice(-CONTEXT_CHARS)
				: '';
			const edited = await cleanTurns(request, context, systemPrompt);
			const missing = request.filter((turn) => !edited.has(turn.id)).length;
			if (missing > 0) {
				console.warn(
					`  ⚠️ Request ${index + 1} returned no text for ${missing} of ${request.length} turns`,
				);
			}
			return request.map(
				(turn): CleanedGroup => ({
					speaker: turn.speaker,
					start: turn.start,
					text: edited.get(turn.id) ?? turn.text,
				}),
			);
		},
		{
			concurrency: CONCURRENCY,
			fallback: (request) =>
				request.map(
					(turn): CleanedGroup => ({ speaker: turn.speaker, start: turn.start, text: turn.text }),
				),
			onProgress: (completed, total) => {
				if (completed % 10 === 0 || completed === total) {
					console.log(`    Cleaned ${completed}/${total} requests`);
				}
			},
		},
	);
	return groups.flat();
}

export function renderTranscript(groups: CleanedGroup[], speakerMap: SpeakerMap): string {
	// Distinct diarization labels can resolve to one person, so adjacent blocks
	// are joined under a single heading rather than repeating the name.
	const blocks: { speaker: string; start: number; text: string }[] = [];
	for (const group of groups) {
		const speaker = formatSpeakerName(group.speaker, speakerMap);
		const previous = blocks.at(-1);
		if (previous?.speaker === speaker) {
			previous.text += ` ${group.text}`;
		} else {
			blocks.push({ speaker, start: group.start, text: group.text });
		}
	}

	return blocks
		.map((block) => `[${formatTimestamp(block.start)}] **${block.speaker}**: ${block.text}`)
		.join('\n\n');
}
