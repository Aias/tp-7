// Shared types for transcription configuration

import type { SpeakerIdentificationRequest, TranscribeParams } from 'assemblyai';

export interface CustomSpelling {
	from: string[];
	to: string;
}

/**
 * The SDK types the speaker identification request without the roster of
 * expected speakers that the API accepts.
 */
export type SpeakerIdentificationOptions = SpeakerIdentificationRequest & {
	speakers?: SpeakerProfile[];
};

// Extract only the options we want to make configurable. audio, custom_spelling
// and keyterms_prompt are handled separately; speech_understanding is restated
// to widen speaker identification past what the SDK declares.
export type ConfigurableTranscriptionOptions = Omit<
	TranscribeParams,
	'audio' | 'custom_spelling' | 'keyterms_prompt' | 'speech_understanding'
> & {
	speech_understanding?: {
		request?: { speaker_identification?: SpeakerIdentificationOptions };
	};
};

/**
 * A recurring participant. The optional description is what lets a speaker who
 * is never named aloud still be identified: it gives both the audio pass and the
 * reconciliation pass a role or subject matter to match against. Keep it to the
 * things that distinguish this person from the others you record with —
 * "backend, owns the ingest pipeline" discriminates, "senior engineer" does not.
 */
export interface SpeakerProfile {
	name: string;
	description?: string;
}

export type KnownSpeaker = string | SpeakerProfile;

export interface TranscriptionConfig {
	customSpellings: CustomSpelling[];
	keyTerms: string[];
	// Recurring participants used as hints (not a hard filter) when reconciling
	// speaker identities. Helps normalize spellings and reject names that were
	// only mentioned in passing. Open-set: speakers off this list can still be
	// identified from context.
	knownSpeakers?: KnownSpeaker[];
	transcriptionOptions: Partial<ConfigurableTranscriptionOptions>;
}
