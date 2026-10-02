# tp7sync

Pulls recordings off a teenage engineering TP-7 field recorder, transcribes them, and files everything into `~/Recordings` — one folder per recording, holding the audio, diarized transcripts, and an AI summary.

## How it works

The TP-7 has two mutually exclusive USB personalities:

- **Audio mode** (`0x2367:0x8019`, the default): a class-compliant 6-in/6-out 24-bit/96 kHz audio interface with MIDI. No file access.
- **MTP mode** (`0x2367:0x0019`): file access via MTP, which macOS does not support natively — the device never mounts in Finder.

The [tp7 CLI](https://github.com/totocaster/tp7) bridges the two: it sends a device-specific MIDI command that flips the recorder into MTP mode, speaks MTP directly (no FieldKit, no kernel extensions), performs the file operation, and closes the session. The device returns to audio mode afterwards on its own. `vendor/tp7-audio-mode-pid.patch` extends the CLI's device detection to match the audio-mode product ID, which newer firmware (1.1.11) uses; without it the CLI cannot find a device sitting in audio mode.

On top of that, tp7sync runs the ingest loop:

1. Detect the TP-7 on USB (cheap; does not disturb audio mode).
2. List `/recordings` and `/memo` on the device, diff against the manifest at `~/Recordings/.tp7sync/manifest.json`.
3. Pull each new file into `~/Recordings/meetings` (from `/recordings`) or `~/Recordings/memos` (from `/memo`), verifying sizes. Files modified in the last two minutes are skipped in case they are still recording. A file dated 1980 means the device's clock is unset: pull emits a `misdated` event for it, and `redate` records the right start time.
4. Run the transcription pipeline (AssemblyAI diarization → speaker identification and clean-verbatim editing → summary and title) over each pulled file, up to three at once, which produces a `YYYY-MM-DD_HHMM-title/` folder beside it. Pulled files that fail to transcribe are retried on the next run.
5. Delete the pulled WAV. The folder keeps the 16 kHz mono FLAC the pipeline transcribed, checked against the WAV's duration, as the recording's audio: AssemblyAI resamples everything to 16 kHz, so re-transcribing it loses nothing. The manifest keeps the device file name.

Recordings already present locally are recorded as `preexisting` and never re-pulled. Device files are never deleted.

## Setup

```sh
brew install rust ffmpeg
./scripts/setup-tp7-cli.sh   # build + install the patched tp7 CLI
bun install
cp src/transcriber/.env.example src/transcriber/.env
```

`src/transcriber/.env` (gitignored) holds the API keys: `ASSEMBLYAI_API_KEY` and `OPENAI_API_KEY` for transcription, and `TYPESAFE_API_KEY` for TypeSafe's Jev model. Optional per-user vocabulary and speaker rosters live in `src/transcriber/transcription.config.local.ts` (also gitignored, merged over `transcription.config.defaults.ts`).

Optional settings overrides go in `~/.config/tp7sync/config.json`; see `src/config.ts` for the schema and defaults.

## Usage

```sh
bun run now         # ingest new recordings once
bun run status      # device presence + manifest summary
bun run transcribe <file> [speakers]   # transcribe any local audio file (speakers: 3 or 2-5)
bun src/cli.ts redate <file> <when>    # correct a recording's start ("YYYY-MM-DD HH:MM", or "HH:MM" for today)
bun src/cli.ts draft-summary <live-transcript.md>   # summarize a live transcript on the fast model
```

## Event lines

Commands the companion runs print machine-readable lines among their log output: the prefix `@tp7 ` followed by one JSON object. `transcribe` and `transcribe-pulled` emit `stage` and `result` for each recording, `pull` emits `misdated`, `draft-summary` emits `draft`, and `redate` emits `redated`. `src/events.ts` defines the fields.

## Companion app

`companion/` is a Swift menu-bar app that layers live features over the same archive: device presence, ctrl-mode gesture handling, memo-hold dictation streamed to the cursor, and gesture-driven meeting capture — Rec arms, Play starts and toggles pause, Stop ends and hands the audio to the transcription pipeline, with the TP-7 mic and Mac system audio recorded as separate tracks and +/− dropping timestamped markers. The side buttons hand the moment to Claude Code: a tap writes a brief (current selection and window, or the meeting transcript so far) and opens an interactive session in Ghostty; a memo hold right after the tap adds spoken instructions. Docking the TP-7 ingests once, as soon as no capture or other app is using its audio, and the menu's Ingest Now runs the same ingest on demand. At Stop, a draft summary of the live transcript arrives within seconds and the final summary replaces it when the pipeline finishes; the menu shows the pipeline's current stage and lists recent transcripts, and the notification for a recording dated 1980 takes its real start time as a reply. Build and run with `swift run` from `companion/`; the architecture and the device's verified control map live in `DESIGN.md`.

To install it as a real app:

```sh
bun run package-app   # builds release, signs, installs /Applications/TP-7 Companion.app
```

The installed app reads the repo location from `~/.config/tp7companion/config.json` (written on first package) and needs that checkout to have `bun install` run and the transcriber's per-machine files in place. Development builds via `swift run` always use their own checkout instead.

## Caveats

- Switching to MTP briefly takes the device offline as an audio interface. Auto-ingest therefore runs only when the device is docked, never mid-session. Use Ingest Now or `bun run now` to ingest on demand while it stays connected.
- The device takes a few seconds to re-enumerate between modes. The tp7 wrapper retries transient mode-switch errors automatically.

## Roadmap

- Safe periodic ingest while attached, gated on the audio interface being idle (CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`).
- Programmatic record control over MIDI/BLE (see [tp7-midi](https://github.com/lucidyan/tp7-midi) for the reverse-engineered CC map).
- A minimal monospace TUI for browsing recordings and transcripts.
