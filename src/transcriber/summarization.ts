import { z } from 'zod';
import { zodResponseFormat } from 'openai/helpers/zod';
import { MODELS, openai } from './openai.js';

const SYSTEM_PROMPT = `You are an executive-level summarizer.

Summarize the transcript the user provides, then title it.

Summary format, strictly:
Paragraph 1 (≤60 words): overall purpose and key themes.
Paragraph 2 (≤60 words): main conclusions or insights.
If actions/decisions are present, add a blank line and list them as bullet points.
Quote exact product and feature names as they appear.
Do not introduce new information or interpretations.

Title rules: a 3-5 word descriptive title for the recording.
- Use lowercase with hyphens between words
- Focus on the main topic or purpose
- Avoid generic terms like "meeting", "call", "discussion"
- Be specific about the subject matter`;

// The summary comes first so the title is written with it in view.
const SummarySchema = z.object({
	summary: z.string().describe('The summary, in the format given'),
	title: z.string().describe('The title, lowercase with hyphens between words'),
});

export interface Summary {
	summary: string;
	/** Kebab-case, ready for a folder name. */
	title: string;
}

type Model = (typeof MODELS)[keyof typeof MODELS];

/**
 * Summarize and title in a single pass. Even a day-long recording fits the
 * context window, and map-reduce over segments loses the cross-segment threads
 * a summary is for.
 */
export async function summarizeAndTitle(transcript: string, model: Model): Promise<Summary> {
	console.log('🤖 Summarizing with AI...');

	const response = await openai.chat.completions.parse({
		model,
		reasoning_effort: model === MODELS.judgment ? 'medium' : 'none',
		service_tier: 'fast',
		messages: [
			{ role: 'system', content: SYSTEM_PROMPT },
			{ role: 'user', content: transcript },
		],
		response_format: zodResponseFormat(SummarySchema, 'summary'),
	});

	const parsed = response.choices[0]?.message.parsed;
	const summary = parsed?.summary.trim();
	if (!parsed || !summary) {
		throw new Error('The summary came back empty');
	}
	return { summary, title: toFolderTitle(parsed.title) };
}

function toFolderTitle(title: string): string {
	return (
		title
			.toLowerCase()
			.replace(/\s+/g, '-')
			.replace(/[^a-z0-9-]/g, '') || 'untitled'
	);
}
