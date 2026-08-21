# tp7sync

Pulls recordings off a teenage engineering TP-7 field recorder, transcribes them, and files everything into `~/Music/recordings` — one folder per recording, holding the raw WAV, diarized transcripts, and an AI summary.

## How it works

The TP-7 has two mutually exclusive USB personalities:

- **Audio mode** (`0x2367:0x8019`, the default): a class-compliant 6-in/6-out 24-bit/96 kHz audio interface with MIDI. No file access.
- **MTP mode** (`0x2367:0x0019`): file access via MTP, which macOS does not support natively — the device never mounts in Finder.

The [tp7 CLI](https://github.com/totocaster/tp7) bridges the two: it sends a device-specific MIDI command that flips the recorder into MTP mode, speaks MTP directly (no FieldKit, no kernel extensions), performs the file operation, and closes the session. The device returns to audio mode afterwards on its own. `vendor/tp7-audio-mode-pid.patch` extends the CLI's device detection to match the audio-mode product ID, which newer firmware (1.1.11) uses; without it the CLI cannot find a device sitting in audio mode.

On top of that, tp7sync runs the ingest loop:

1. Detect the TP-7 on USB (cheap; does not disturb audio mode).
2. List `/recordings` on the device, diff against the manifest at `~/Music/recordings/.tp7sync/manifest.json`.
3. Pull each new file into `~/Music/recordings`, verifying sizes. Files modified in the last two minutes are skipped in case they are still recording.
4. Run the transcription pipeline (AssemblyAI diarization → speaker identification → clean-verbatim editing → summary → AI-generated title), which produces a `YYYY-MM-DD_HHMM-title/` folder.
5. Move the WAV into that folder and post a macOS notification.

Recordings already present locally are recorded as `preexisting` and never re-pulled. Device files are never deleted.

## Setup

```sh
brew install rust ffmpeg
./scripts/setup-tp7-cli.sh   # build + install the patched tp7 CLI
bun install
```

The transcriber reads `ASSEMBLYAI_API_KEY` and `OPENAI_API_KEY` from `src/transcriber/.env` (gitignored). Optional per-user vocabulary and speaker rosters live in `src/transcriber/transcription.config.local.ts` (also gitignored, merged over `transcription.config.defaults.ts`).

Optional settings overrides go in `~/.config/tp7sync/config.json`; see `src/config.ts` for the schema and defaults.

## Usage

```sh
bun run now         # ingest new recordings once
bun run watch       # watch for the device, ingest on attach
bun run status      # device presence + manifest summary
bun run transcribe <file> [speakers]   # transcribe any local audio file (speakers: 3 or 2-5)
```

To run the watcher at login:

```sh
./scripts/install-launchd.sh
```

Logs land in `~/Library/Logs/tp7sync.log`.

## Companion app

`companion/` is a Swift menu-bar app that layers live features over the same archive: device presence, ctrl-mode gesture handling, memo-hold dictation streamed to the cursor, and gesture-driven meeting capture — Rec arms, Play starts and toggles pause, Stop ends and hands the audio to the transcription pipeline, with the TP-7 mic and Mac system audio kept as separate tracks and +/− dropping timestamped markers. Build and run with `swift run` from `companion/`; the architecture and the device's verified control map live in `DESIGN.md`.

## Caveats

- Switching to MTP briefly takes the device offline as an audio interface. The watcher therefore only auto-ingests when the device is first plugged in, never mid-session; run `bun run now` to ingest on demand while it stays connected.
- The device takes a few seconds to re-enumerate between modes. The tp7 wrapper retries transient mode-switch errors automatically.

## Roadmap

- Safe periodic ingest while attached, gated on the audio interface being idle (CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`).
- Programmatic record control over MIDI/BLE (see [tp7-midi](https://github.com/lucidyan/tp7-midi) for the reverse-engineered CC map).
- A minimal monospace TUI for browsing recordings and transcripts.
