export type PipelineStage = 'converting' | 'transcribing' | 'cleaning' | 'summarizing';

type Tp7Event =
	| { event: 'stage'; stage: PipelineStage; input: string }
	| {
			event: 'result';
			input: string;
			folder: string;
			transcript: string;
			title: string | null;
			summary: string | null;
			speech: boolean;
	  }
	| { event: 'draft'; title: string; summary: string };

/** Prints a line the companion parses; every other output line is log text. */
export function emit(event: Tp7Event): void {
	console.log(`@tp7 ${JSON.stringify(event)}`);
}
