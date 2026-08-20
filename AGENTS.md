# Agent Instructions

tp7sync ingests recordings from a teenage engineering TP-7 over MTP and transcribes them. Read `README.md` first — it documents the device's dual USB personality (audio vs MTP mode), which constrains everything here.

- Runtime is Bun; typecheck with `bun run typecheck` (tsgo, strict + `noUncheckedIndexedAccess`).
- `companion/` is the Swift menu-bar app (SwiftPM, Swift 6 language mode); build with `swift build` from that directory, run with `swift run`. DESIGN.md holds its architecture.
- `src/transcriber/` is the transcription pipeline (AssemblyAI + OpenAI). `src/transcriber/.env` and `src/transcriber/transcription.config.local.ts` are gitignored per-machine files — never commit them.
- Device access goes through the `tp7` CLI wrapper in `src/tp7.ts`. Every `-a` command flips the device out of audio mode and back; treat mode switches as disruptive (they drop the mic mid-meeting) and keep them rare and explicit.
- The manifest at `<recordingsDir>/.tp7sync/manifest.json` is the source of truth for what has been ingested. Device files are never deleted.
- `vendor/tp7-audio-mode-pid.patch` patches the upstream tp7 CLI (pinned in `scripts/setup-tp7-cli.sh`); if upstream merges audio-mode PID support, drop the patch and unpin.
