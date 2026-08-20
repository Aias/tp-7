# Creative pass — unexplored territory

Divergent ideas beyond DESIGN.md's committed scope. Nothing here is planned; everything here is possible with the primitives we've verified (gesture events over USB/BLE, live mic streaming, MTP file access, SysEx round-trips, the archive). Each thread notes the cheapest probe that would prove it.

## 1. The device navigates its own archive

The TP-7 records the audio; it should also be the transport control for *reviewing* it. In the search GUI, the wheel jogs through a recording tape-style, the rocker shuttles at variable speed, side buttons jump between speaker turns or search hits — a Descript-style linked transcript/audio view where the physical reel is the scrubber. The muscle memory of a tape deck, pointed at your own words.
*Cheapest probe: wheel CC deltas → seek commands in a toy AVAudioPlayer + highlighted transcript.*

## 2. Live annotation — markers as a first-class gesture

During a Mac-recorded meeting, the unused buttons become annotation keys: **+** drops a "highlight" marker, **−** drops an "action item" marker, each anchored to the timestamp. The post-meeting pipeline weights marked moments in the summary; action-marked segments become drafted tickets. This is the cheapest possible "note-taking during a meeting without a keyboard" — one thumb press, zero context switch.
*Cheapest probe: log CC25/26 timestamps during capture; render as anchors in the transcript markdown.*

The device has its own native cue-marker system too (128 slots, MIDI-triggerable with the MIDI-CUE setting, cue-rec mode that records from one marker to the next). Whether cues persist into the WAV is unknown — but bench inspection of already-pulled recordings found the TP-7 writes an `acid` metadata chunk (tempo/time-signature) into every file, so it does embed structured metadata a Mac app can read.

## 3. The agent walkie-talkie

Close the loop the inspiration video opened: memo-hold talks to a coding agent (Claude Code/opencode session), **stop** interrupts it, **play** speaks its latest response back — through the TP-7's own speaker, since the device is also a USB audio *output*. The TP-7 becomes a physical push-to-talk handset for AI pair programming: eyes on code, thumb on the talk button, agent voice in the room instead of another window. The wheel scrubs back through session history.
*Cheapest probe: memo dictation → `claude -p` → say(1) routed to the TP-7 output device.*

## 4. The listening log — one archive for everything heard

The pipeline already transcribed a web video on day one. Generalize the input: podcast episodes, YouTube URLs (yt-dlp), phone calls recorded on the TP-7, voice memos, meetings — one archive, one search, one interface to "everything I've said or heard." Speaker enrollment (the known-speakers roster already in the pipeline config) auto-names recurring colleagues across all of it.
*Cheapest probe: `tp7sync transcribe <url>` — yt-dlp fetch then the existing pipeline.*

## 5. Ambient, physical presence

- Menu bar shows a live VU meter while capturing — recording state at a glance, no screen real estate.
- The TP-7's speaker as the notification channel: a soft chirp when a transcript lands, the device (not the Mac) acknowledging — calm-tech feedback from the object you spoke into.
- The motorized reel has no free-spin API — it only moves with real tape transport (MOTOR setting: play / play+rec / off). A Mac *can* spin it via the CC18 rocker-emulation, but that scrubs the actual playhead — usable as a deliberate "agent is done, tape rewinding" flourish, not an idle animation.

## 6. Capture inversions

- **Device-records-Mac — confirmed, first-class**: the manual documents a per-track input matrix (settings → SOURCE → Digital/Manual): each stereo track independently records nothing / internal mic / analog / **USB digital input**. So for meetings the roles can flip entirely — the Mac routes call audio into the TP-7, and the device records *you on track 1 (mic)* and *the call on track 2 (USB)* into one on-device multitrack WAV, cleanly separated, surviving any Mac crash. 48 kHz allows up to 6 stereo tracks. Remaining bench detail: which USB channel pair maps to which track.
- **Phone calls**: officially undocumented, but the same Digital-source mechanism should record an iPhone's call audio over USB-C (the untested link is iOS routing call audio to USB accessories). Files flow through the same ingest.

## 7. Voice annotation — quotes are anchors, not content

The unifying principle: for anything with a digital source of truth, the voice never carries the quote — it carries only the commentary, and the quote is captured *digitally* at the moment of speaking. Reading a document aloud is both cumbersome and wrong (the document already exists); reconciliation is solved by construction when the anchor is grabbed from the source. Three escalating forms:

- **Selection-anchored comments.** Select a passage anywhere — PR diff, PDF, spec, web page — then memo-hold and speak. The app snapshots the selection, the app identity, and the document identifier alongside the spoken note. The quote is exact because it never went through speech. Output adapts per source: for a PR, drafted review comments anchored to file and line; for a PDF, exportable highlight+note pairs; for anything, a quote+commentary record for red-cliff-record.
- **Review sessions.** A deliberate mode for reading a document end-to-end with the TP-7 as the annotation remote: the wheel scrolls the document, memo-hold speaks a comment anchored to the current selection or viewport, +/− grade severity. Lean-back reading with hands off the keyboard; the session ends as a structured review — for code, a ready-to-post GitHub review draft.
- **Physical books — the only case where the voice carries the quote.** Read the passage aloud plus your thought; an LLM splits quote from commentary. Then *reconcile*: when the book's text is findable (user's ebook library, Gutenberg, publisher sample), fuzzy-match the spoken quote against the canonical text and replace the transcription with the exact passage, page-referenced. The spoken quote is a pointer to be resolved, not the final record — confidence-gated, keeping the transcribed version flagged as approximate when no match exists. This is the barnsworthburning / commonplace-book input method: the friction of transcribing passages by hand disappears, and the entries stay canonical.

*Cheapest probes: (a) AX-selection grab + memo transcript → one merged annotation record; (b) fuzzy quote-matching prompt against a known ebook text.*

## 8. Modal dictation — gestures select the transform

One button, several grammars, distinguished by gesture (all measurable from press/release timing): plain hold = verbatim prose; double-tap-then-hold = "instruction mode" where an LLM reformats the utterance (bullet list, email reply, commit message, ticket description); a side-button chord = code dictation. Dictation stops being one feature and becomes a family of voice→text transforms selected by thumb.

The first transform worth building is **cleanup**: the live stream types fillers and stutters verbatim ("um", restarts), while the batch pipeline's clean-verbatim editing never touches inserted text. A post-dictation cleanup pass — on release, replace the typed utterance with a cleaned version (the deferred-rewrite machinery in the inserter already applies exactly this kind of one-shot correction) — closes that gap, and its gesture selection (clean by default vs verbatim on a modifier, or vice versa) is the natural seed of the whole modal system.
*Cheapest probe: two gesture patterns routed to two prompts; for cleanup, one LLM pass over the finished utterance re-applied via the inserter.*

## 9. Work-context correlation — "what was I doing when I said this"

Every capture gets stamped with ambient context at the moment of recording. The archive then answers both directions — "what was I thinking during that refactor" and "what was I working on when I recorded this." Interstitial journaling with zero ceremony: press, speak, forget; the context files itself.

The context sources are all cheap, and the interesting ones integrate with tools already in use:

- **Frontmost app + window title** (NSWorkspace + AX) — window titles usually carry the active file or page.
- **Active agent session** — Claude Code/Conductor expose hooks: a SessionStart/PostToolUse hook maintains a small state file (`current workspace, branch, task summary`) that the companion reads at capture time. The archive then knows not just "you were in the tp-7 workspace" but "the agent was mid-way through the ingest refactor."
- **Editor state** — Cursor/VS Code active file via extension or AppleScript.
- **Calendar event** (EventKit) — doubles as the ingestion-naming signal.
- **Git branch** of the active workspace.

The digest features compound on this: the end-of-day recap can narrate "morning in baghdad-v3 on the transcriber port (4 memos), afternoon in meetings (2 recordings, 3 action markers)" — a work journal assembled from context stamps nobody wrote.
*Cheapest probe: capture `frontmost app + branch + calendar event` at dictation start; store in the archive row. Hooks come later.*

## Meeting capture, inverted — investigation

The manual settles the core question: recording the Mac's audio on-device is an officially documented, first-class workflow, not a hack.

**What the manual proves** (pages 23, 28, 30–31, 52, and the THRU setting):

- SOURCE=Digital: "Record 1–3 digital stereo tracks, from a USB host, such as a computer." SOURCE=Manual: any per-track combination of nothing / internal mic / analog / digital. Even Auto combines: "If you've connected either an analog or digital input, those will be used along with the internal microphone."
- "Computer recording: TP-7 connected to computer/laptop via USB-C" is one of the manual's four official recording examples.
- The routing matrix (p. 52) shows all inputs — mic, line, 6 USB channels — routable to tape record, USB out, speaker, and jacks. THRU explicitly sends "inputs to USB outputs" when connected to a computer, so the Mac can *listen to the mic live* while the device records.

**The architecture this enables.** During a call, the TP-7 becomes the conference handset: Zoom's mic *and* speaker device. You hear the call through the TP-7 (speaker or its headphone jack); it hears you through its mic; and it records both — you on the mic track, the call on the digital track — into one on-device multitrack WAV. The Mac meanwhile live-listens over THRU for the real-time transcript and a signal-derived recording indicator. Properties that fall out:

- Crash-proof: the official copy is on the device; the Mac is an optional observer.
- Echo-proof by construction: the two sides never mix until transcription time.
- **No mode flip for meetings**: the device stays in normal mode, using its own transport exactly as today (Rec arms → Play starts → Stop ends — the grammar the user already knows, on the hardware itself). Ctrl mode narrows to a deliberate "command posture" for dictation and control-surface sessions, which reframes the dock-posture question entirely.
- Markers during meetings become *on-device cues* (hold rec + plus) rather than CC events — readable at ingest if cue persistence pans out (bench item 3).

**Costs**: no CC gestures during meetings (no live Mac-side marker keys), the user must accept the TP-7 as their call audio device, and live-transcript quality depends on the THRU mix. **Status: declined as the meeting default** — the call audio stays on the Mac and ctrl mode stays the docked posture (DESIGN.md), keeping the buttons free as a control surface. Documented here because the capability is real and might suit a future scenario (field interviews through the device, capture-integrity-critical sessions).

**Bench protocol** (needs the device docked, ~15 minutes):
1. Set SOURCE=Manual. Arm a 2-track recording: track 1 = mic, track 2 = digital. Play a distinctive stereo file from the Mac to the TP-7 output while speaking. Stop, pull the file, inspect channels — confirms the channel-pair→track mapping.
2. With THRU on, record the TP-7 input on the Mac (ffmpeg, as validated) while the device itself records — confirms simultaneous live-listen.
3. Check whether Zoom/system output to "TP-7" reaches the speaker with main out disconnected (the p. 52 mix rule suggests yes).
4. Add cues during the test recording; pull and dump RIFF chunks for cue persistence.

## From the Mac MIDI-automation and voice-computing worlds

- **Zero-code prototype, available today**: BetterTouchTool natively supports MIDI CC triggers with device filters, injects live CC values into actions (wheel → scroll amount), runs shell scripts as actions (memo → transcription pipeline), and organizes everything into per-app trigger groups. The whole control-surface concept can be validated in an afternoon before any Swift exists. Keyboard Maestro's "CC increases/decreases" trigger conditions handle the wheel with zero scripting if BTT's encoder handling feels bad. Hammerspoon's `hs.midi` is the scripted middle ground.
- **Stream Deck's Smart Profiles are the architecture model for control profiles**: profiles are *data* (bundle ID → layout manifest), a frontmost-app watcher swaps them automatically, plugins run out-of-process behind a WebSocket with declarative manifests. Per-app behavior should never be code paths.
- **Talon Voice's mode discipline transfers directly**: command mode and prose mode are *separate physical gestures*, never inferred from speech — one gesture dictates, another instructs, each with its own listening behavior. Talon users already bind foot pedals as push-to-talk hardware; the TP-7's transport buttons are a nicer version of that pedal. Add the "hold-to-talk, double-tap to latch" pattern for long dictation.
- **superwhisper's mode system is the reference for dictation transforms**: a mode = STT engine + AI prompt + opt-in context feeds (active app, focused-field text, recent clipboard, current selection). Wispr Flow's most-loved features on top: app-aware tone matching and "Command Mode" — speak an instruction and the *selected text* gets transformed, voice acting on text rather than producing it.
- **The gap we'd occupy**: voice→agent bridges exist in software (ChatGPT desktop voice, Raycast AI dictation feeding extensions), but nothing open-source pairs a *hardware* push-to-talk surface with an agent loop. The TP-7 walkie-talkie thread (§3) is genuinely unclaimed territory.

## From the hardware-AI-recorder ecosystem (PLAUD, Limitless, Granola, Otter, Fireflies)

Surveyed for a companion-app feature mine; ranked by novelty × usefulness here:

- **Calendar-aware ingestion naming** — match a recording's timestamps against calendar events at ingest: auto-name ("Design sync w/ Alex"), tag attendees, and feed attendee names to the transcriber as vocabulary hints. Uniquely valuable for a device that produces anonymous timestamp files. (PLAUD's best feature.)
- **Persistent speaker voice-prints** — name a diarized speaker once; recognize their voice across all future recordings, making "conversations with Sarah" a queryable dimension. (Limitless's killer feature; feasible locally.)
- **Archive-wide chat** — "what did I say about the manifest design last week" answered with the moment, its audio, and a deep link. Table stakes in cloud tools, novel as a local-first capability.
- **Template-driven summaries per recording type** — classify each capture (meeting / memo / sketch) and run a type-appropriate, user-editable prompt template; the template output, not the transcript, is the artifact people read.
- **Granola's provenance blending** — if sparse typed notes exist for a meeting, "enhance" them from the transcript while visually separating human text from AI additions. Best UX idea in the category.
- **MCP server over the archive** — expose transcripts, manifest, and search to any AI assistant. Near-free given the existing manifest; turns the archive into infrastructure other agents can query.
- **Digest at the dock** — the TP-7's rhythm is batch (record all day → dock): a "here's what you captured" recap after each sync fits the hardware better than real-time notifications. Daily/weekly digests compound it.
- **Soundbites** — select a transcript range, export the trimmed audio clip + caption. Doubly apt for a field recorder whose captures are sometimes creative material, not speech.
- **Anti-features the market hates** (design against): subscription walls in front of your own recordings, cloud-only storage without plain-file export, auto-joining bots, auto-shared summaries (Otter is facing a class action over consent). Local-first, files-on-disk, explicit-action — the positioning writes itself.
- Notable OSS prior art: **Hyprnote** (local-first macOS AI notepad — on-device Whisper + local LLM + Granola-style enhancement; worth reading for capture plumbing), Speakr, Scriberr, Omi.

## From the hardware deep-dive (manual + firmware changelog + RIFF inspection)

- **VOX-style auto recording exists on-device** (record menu → AUTO: start/pause on an input threshold) — unattended capture without any companion involvement.
- **Memo wake**: the memo button records even when the device is powered off. The untethered capture story is stronger than assumed.
- **`library` is the music-player side** — files loaded over MTP for playback; the device also stores arbitrary non-audio files as a plain drive (invisible on-device). The archive could even sync curated audio *to* the device.
- **Time/date sync exists over USB** (field kit does it; protocol undocumented) — worth sniffing and replicating so device timestamps never drift.
- **BLE audio file transfer** to TE's phone app exists — a proprietary but proven wireless pull path if ever reverse-engineered.
- **Custom 4-char device name**, advertised over BLE — cheap machine-readable identity for multi-device setups.
- Speaker routing question (does Mac USB audio reach the internal speaker without THRU/armed recording?) is the load-bearing unknown for the walkie-talkie thread (§3) — top of the bench list.

### Bench-test list (documentation is silent)

1. Mac USB audio → internal speaker, without THRU or armed recording (gates §3's spoken agent responses).
2. USB channel-pair → track mapping when recording Digital source (locks in §6's inverted meeting capture).
3. Cue persistence: set cues on-device, pull the file, dump RIFF chunks for a `cue ` chunk (gates §2's marker interop).
4. Wheel motion under CC18 sweeps (the §5 "tape rewind flourish").
5. iPhone call audio routing into a Digital-source recording.
6. MTP tree with the separate-memo-folder setting enabled.

## 10. A teenage engineering hub, eventually

The TX-6 mixer and OP-1 field speak the same BLE-MIDI patterns (community event maps exist). The companion's device layer — CoreMIDI listening, SysEx identity, gesture routing — generalizes to a TE-device hub if more hardware arrives. Not a goal; a door left open by clean architecture.
