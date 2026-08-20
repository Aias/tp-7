# TP-7 companion — design document

The TP-7 as a first-class Mac peripheral: a capture device, a dictation device, and a control surface. Everything it ever records — long recordings, quick memos, live meeting audio — is automatically backed up, transcribed, and searchable, without opening a terminal.

## Device capabilities (verified on hardware, firmware 1.1.11)

The TP-7 exposes three independent channels over one USB-C cable, plus Bluetooth:

| Channel | What it carries | Constraints |
|---|---|---|
| **USB audio** | Class-compliant 6-in/6-out, 24-bit/96 kHz interface. Live mic feed capturable via CoreAudio/ffmpeg. | Always on in normal mode. Dropped while in MTP mode. |
| **MIDI** | Bidirectional. TE SysEx protocol (greet → identity string, mode-switch → MTP). With device setting MIDI=`ctrl`: every physical control emits CC events. | `ctrl` mode (gesture events) and command mode (remote transport control) are mutually exclusive. No unsolicited state — recording status is inferred from gestures. Off by default. |
| **MTP** | File access to `/recordings` (and `/memo` with the separate-memo-folder firmware setting). | macOS has no native MTP. Device must re-enumerate out of audio mode; only one MTP session at a time. |
| **BLE MIDI** | Same MIDI channel wirelessly (device setting Bluetooth=ACCEPT; Mac pairs via Audio MIDI Setup's Bluetooth panel, source appears as "TP-7 Bluetooth"). Verified: all ctrl-mode gestures, hold timing, and SysEx round-trip. | MIDI only — no audio path over Bluetooth. macOS BLE-MIDI pairing is manual UI; auto-reconnect behavior unverified. |

### Control map (MIDI=ctrl, channel 1)

Buttons send press=127/release=0, so hold-duration is detectable.

All rows bench-verified on this device over both USB and BLE.

| Control | Message |
|---|---|
| Rec / Play / Stop | CC 22 / 23 / 24 |
| Memo (M) | CC 27 — distinct from Rec; hold duration measurable from press/release timing |
| Up / Down side buttons | CC 20 / 21 |
| − / + buttons | CC 25 / 26 |
| Mode button | CC 28 (absent from the official chart) |
| Wheel | CC 30, relative two's-complement deltas, ~60 Hz while turning |
| Rocker | Pitch bend, 14-bit ±8192, snaps to 0 at center |

In ctrl mode the controls are fully decoupled from the device's own transport: no on-screen feedback, and a memo hold emits CC 27 without recording anything on-device. The SysEx MTP mode-switch still works with MIDI=ctrl, so gesture observation and file ingest coexist without touching settings.

### SysEx protocol (works in normal mode, any MIDI setting yet to confirm)

TE envelope `f0 00 20 76 19 40 <flags> <req> <cmd> <payload> f7`:
- **Greet** (`cmd 0x01`) → identity: `mode:normal;product:TP-7;sw_version:1.1.11;serial:…`. Verified locally. The `mode:` field stays `normal` during recording — greet polling is *not* a recording detector.
- **MTP mode switch** (`cmd 0x04`, payload `01 03`) → device re-enumerates as MTP. This is what the patched tp7 CLI (and our working ingest) uses.

## Prior art

- **totocaster/tp7** (Rust CLI, MIT) — direct MTP + the SysEx handshake, no FieldKit. We run it with a 3-line patch (`vendor/tp7-audio-mode-pid.patch`) because firmware 1.1.11 uses PID `0x8019` in audio mode. Powers today's working ingest.
- **PacoZhou1/tp7-vibe-deck** (Swift) — closest existing thing to this design: CoreMIDI gesture listening + concurrent TP-7 audio capture, memo-hold dictation with Accessibility text injection, wheel scrolling. Includes empirical MIDI protocol docs and reconnect-recovery logic worth studying.
- **armynante/TP-7-VoiceSync** (Swift menu bar app) — memo auto-sync → WhisperKit/ElevenLabs → Apple Notes/S3. Detection via polling FieldKit's container folder (fragile; requires FieldKit + manual connect). Useful for its MenuBarExtra structure, WhisperKit model-download flow, and debounce-until-file-stable pattern; its god-object architecture is the anti-pattern.
- **lucidyan/tp7-midi** (web) — the reverse-engineered MIDI spec our control map is built on.
- **mellson/tp7-util** — documents the multitrack WAV layout: up to 12 interleaved channels as stereo pairs. Memos and normal recordings are plain stereo; a robust pipeline extracts the first stereo pair when channels > 2.
- The opencode-plugin demo video (transcribed in this repo's exploration): wheel→scroll, side buttons→session switching, memo-hold→dictate-into-agent, stop→interrupt, play→speak response. Not public, but proves the interaction model.

## Architecture

One **Swift menu bar app** is the nucleus (working name: the companion). It owns device presence, MIDI listening, audio capture, live transcription, text insertion, and the archive database. The **existing TypeScript pipeline in this repo** (`src/`) remains the batch worker for high-accuracy diarized transcripts — invoked by the app, eventually portable to Swift if we care to consolidate.

```
                    ┌─────────────────────────────────────────┐
                    │  companion (Swift, menu bar)            │
  TP-7 ────USB────► │  DeviceMonitor (HAL UID + CoreMIDI)     │
   │                │  GestureListener (ctrl-mode CCs)        │
   │ audio          │  AudioCapture (AVAudioEngine, AUHAL)    │
   ├───────────────►│    ├─► 96kHz archive WAV                │
   │ MIDI           │    └─► 16kHz mono → SpeechTranscriber   │
   ├───────────────►│  Inserter (pasteboard + Cmd-V CGEvent)  │
   │ MTP (on switch)│  Ingestor (SysEx switch → tp7 pull)     │
   └───────────────►│  Archive (GRDB: SQLite + FTS5)          │
                    │  Search window (SwiftUI)                │
                    └────────────┬────────────────────────────┘
                                 │ spawns for batch diarization/summary
                    ┌────────────▼────────────────────────────┐
                    │  tp7sync pipeline (Bun/TS, this repo)   │
                    │  AssemblyAI + OpenAI → dated folders    │
                    └─────────────────────────────────────────┘
```

### Platform choices (from research, with receipts)

- **Menu bar**: AppDelegate-managed `NSStatusItem` with template SF Symbols per state and timer-driven frame swaps for a recording pulse — not `MenuBarExtra` (no NSStatusItem access, `.menu` style stalls timers, Tahoe regression makes hosted SwiftUI animation laggy). Settings = self-owned `NSWindow` with activation-policy flip (the `openSettings` path broke on macOS 26).
- **Live transcription**: Apple's **SpeechTranscriber/SpeechAnalyzer** (macOS 26, on-device, free, volatile+final results with audio time ranges, consumes arbitrary buffers — designed for exactly our "feed it a specific USB device" case). Fallback/alternative: WhisperKit. Cloud realtime (AssemblyAI Universal-Streaming, ~$0.15/hr, ~300 ms) only if on-device accuracy disappoints.
- **Second pass** (speaker diarization + summaries): keep the existing AssemblyAI/OpenAI pipeline; local alternative worth evaluating: **FluidAudio** (CoreML pyannote diarization, Apache-2.0).
- **Audio capture**: input-only `AVAudioEngine`, device pinned via `kAudioOutputUnitProperty_CurrentDevice` (no AVFoundation API exists for this), tap at hardware format, fork to archive-WAV + a long-lived `AVAudioConverter` down to 16 kHz mono for the transcriber. Persist the TP-7's device UID; re-arm on reappearance. Mic TCC permission is required even for external interfaces.
- **Text insertion**: the VoiceInk pattern — transient-tagged pasteboard write + synthesized Cmd-V via CGEvent, guarded clipboard restore. AX `setValue` insertion is unreliable on Electron/web views; raw CGEvent typing truncates at 20 UTF-16 units per event. Needs Accessibility permission. Consequence: **Developer-ID notarized direct distribution, no sandbox, no App Store** — which also frees file and device access.
- **Archive**: **GRDB + SQLite FTS5**, external-content table over *segments* (utterance rows with transcript id, time range, speaker) via `synchronize(withTable:)`, porter tokenizer, bm25 ranking, snippet highlighting. Optional semantic layer later: `NLContextualEmbedding` + brute-force cosine (small enough at this scale); skip sqlite-vec.
- **File ingest**: SysEx mode-switch + MTP pull, as tp7sync does today (shell out to the patched `tp7` CLI initially; native Swift MTP is a later option, not a requirement).

### App states

```
idle ──plug──► attached (indicator shows device; auto-ingest new files once)
attached ──CC22 press──► recording (menu bar pulses; on stop: wait for file? or capture live)
attached ──CC27 hold──► dictating (live transcribe → insert at cursor → archive memo)
attached ──user/menu──► meeting (capture USB audio live → rolling transcript → batch pass after)
any ──device gone──► idle (debounced; BLE may keep gestures alive)
```

The wheel/rocker/side buttons stay free for a pluggable "control profiles" layer (scroll the frontmost app, drive opencode/Claude sessions, media keys…) — same architecture as the demo video, deferred until the core loop ships.

## What already works (validated this session)

- Patched tp7 CLI: audio→MTP switch, ls, pull at ~22 MB/s, return to audio mode — scripted, no device buttons.
- Full ingest → AssemblyAI/OpenAI pipeline → dated folder grouping in `~/Music/recordings` (`bun run now|watch|status|transcribe`, launchd installer).
- Greet SysEx round-trip from the shell; identity parse; `mode:` polling (negative result: not a recording detector).
- ffmpeg capture from the TP-7 as a CoreAudio input device.

## Operating postures

The ctrl-mode trade (controls decouple from the tape) resolves into two postures with one transition:

- **At the desk (ctrl mode): the Mac is the recorder.** The docked posture requires two device settings: MIDI=`ctrl` (gestures) and **THRU=on** — without THRU the mic never reaches the USB outputs and the Mac captures digital silence (bench-verified at −91 dB). With both set, capture lands directly in the archive and all gestures drive the Mac. The mic occupies USB channels 0/1; channels 2–5 are silent.
- **Away (normal mode): the device is the recorder.** Memos and recordings land on internal storage; the next dock auto-ingests them. The separate-`/memo`-folder firmware setting keeps memos apart from long recordings.
- **Wireless (ctrl mode over BLE):** the full control surface works from across the room, but no audio path exists — a remote trigger for Mac-mic capture only.

The dock/undock mode flip is currently a one-toggle on-device step; the menu bar always shows which posture is active. Whether the TE SysEx mode command can flip the MIDI setting remotely (making docking fully automatic) is a Phase 0 investigation.

## Dictation

Memo hold (CC 27 press) starts capture from the TP-7 mic over USB; release ends it. Text streams to the cursor as live hypotheses — words appear immediately and may self-correct — via the pasteboard insertion path. Every dictation is also archived: audio to a memos area of `~/Music/recordings`, with the batch pipeline producing the durable transcript, so the archive copy's quality never depends on the live engine. No Mac-only dictation fallback (global hotkey / Mac mic without the TP-7): the TP-7 is the dictation device; this also keeps the Input Monitoring permission out of the app.

## Meetings

The Mac mirrors the TP-7's own transport grammar, driven by ctrl-mode gestures: **Rec arms, Play starts, Stop ends, Play toggles pause** while capturing. Capture is the TP-7 mic; when meeting audio is playing on the Mac (Zoom/Meet), system audio is captured via ScreenCaptureKit as a **separate track** — mixed only at transcription time, so speaker bleed into the room mic can't echo or double voices. The official output is the post-meeting artifact: full recording plus the AssemblyAI/OpenAI pipeline transcript, kicked off at Stop and ready minutes later. A live rolling transcript view is a later addition — the streaming pipeline exists for dictation, so the design keeps the door open, but no meeting UI depends on it.

## Phase 0 — remaining bench unknowns (blocking design details, not the direction)

1. ~~Does MIDI=ctrl decouple the buttons when no host is connected?~~ **Bench-answered: yes, ctrl is sticky standalone** — the buttons stay decoupled even unplugged, so the setting cannot simply stay on. The dock/undock flip is manual (hold MODE → MIDI). Mitigation the app must ship: the companion knows the device was in ctrl (gestures were flowing) and notices the USB detach — **push a notification on undock**: "TP-7 unplugged while in ctrl mode — flip MIDI off to record on the go." Remote flipping is off the table with known commands: TE's updater JS exposes only greet/echo/DFU (commands 1/2/3/5, plus `PRODUCT_SPECIFIC` 127), and the installed FieldKit binary contains only greet + the MTP switch. The unexplored avenue is the `PRODUCT_SPECIFIC` space, likely used by TE's iOS app (live transcription, BLE file transfer imply a richer control channel); sniffing that app's traffic is a possible future project.
2. ~~Does memo-wake survive ctrl mode?~~ **Bench-answered: yes.** With MIDI=ctrl set and the device powered off, holding memo wakes it (screen even shows ctrl mode) and the memo records anyway — memo-wake is a separate firmware path that bypasses the ctrl decoupling. So "power it off when you leave" is a real fallback: quick captures survive a forgotten mode flip. Bench-confirmed boundary: while *awake* in ctrl mode, memo does not record even standalone — the decoupling applies whenever the device is awake in ctrl, connected or not. Powered-off memo-wake is the only bypass.
3. ~~Does the `/memo` separate-folder setting change the MTP tree as expected?~~ **Bench-answered: yes** — enabling it creates `/memo` at the MTP root, same timestamp naming; memos land there and `/recordings` keeps long-form only. tp7sync watches both folders.
4. ~~Does macOS auto-reconnect BLE MIDI?~~ **Bench-answered: no** — the connection requires a manual reconnect (Audio MIDI Setup's Bluetooth panel) each session; once connected, the link is fully functional (SysEx round-trip verified over the air). Bench observation: the TP-7 appears to advertise only while its BLE menu is open ("accept" is a pairing mode); established connections survive leaving the menu. Design commitment: the app speaks BLE-MIDI directly via CoreBluetooth (standard MIDI service `03B80E5A-…`, the pattern lucidyan's web app proves over Web Bluetooth), background-scanning and connecting the moment the device advertises — reducing the wireless ritual to "open the BLE menu on the device," with zero Mac-side steps. Verify during the build whether a bonded TP-7 keeps low-rate advertising outside the menu, which would remove even that step.

## Build phases

1. **Shell** — Swift menu bar app: device presence (HAL UID watch), status icon states, greet-based identity display, "ingest now" menu action that shells to the existing pipeline. Replaces the CLI-only UX immediately.
2. **Gestures** — CoreMIDI listener for ctrl-mode CCs; recording indicator inferred from Rec/Memo presses; gesture log in the archive DB.
3. **Dictation** — memo-hold → AVAudioEngine capture → SpeechTranscriber live → insert at cursor; memo audio + transcript archived to `recordings/memos/` and the DB.
4. **Meetings** — live rolling transcript from the USB feed during meetings; batch diarization/summary pass afterwards through the existing pipeline; both linked in the DB.
5. **Search** — GRDB/FTS5 archive over everything ever captured; SwiftUI search window (bm25 + snippets, click-to-seek into audio); TUI equivalent optional.
6. **Control profiles** — wheel/rocker/button mappings to app actions (scrolling, agent sessions, media). Plugin-shaped.

## Settled decisions

- Dictation streams live hypotheses (self-correcting) rather than waiting for finalized text; archive quality comes from the batch pipeline, not the live engine.
- Meeting capture is gesture-driven (arm/start/stop/pause mirroring the device's own grammar), not calendar- or app-triggered.
- The Mac is the recorder, full stop. The inverted architecture (device records the call via its USB-digital track input; see IDEAS.md) was considered and declined: it requires the TP-7 as the call's speaker/mic, and normal mode repurposes the buttons away from the control surface. Ctrl mode is the standing posture whenever the device is docked; normal mode exists for untethered capture only.
- The AssemblyAI/OpenAI pipeline stays as the official transcript path — state of the art over on-device. Local engines (SpeechTranscriber, FluidAudio) serve the live/latency layer only.
- Device retention: recordings are auto-deleted from the TP-7 once pulled, size-verified, transcribed, and archived — the archive is the single source of truth and the device stays empty. (tp7sync does not delete yet; this is destination behavior.)
- Search archive is standalone (SQLite/FTS5, owned by this app); red-cliff-record integration is a later export once the shape settles.
- Priorities: dictation and meetings are the destination; the shell and gesture layers exist to support them.
