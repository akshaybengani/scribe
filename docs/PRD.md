# Scribe product requirements

Version 0.1 · Draft · 16 Nov 2026 · Owner: Akshay Bengani · Companion: [SRS.md](SRS.md)

Scribe is a personal, privacy-first Mac app that records or imports audio of a call and turns it into text. Calls mix Hindi and English (Hinglish) or are English only. The transcript is pasted into Claude to make notes. This document says what Scribe is for, what's built, what comes next, and why each call was made. The SRS holds the testable requirements.

## 1. Problem and context

Calls in this work mix Hindi and English inside a single sentence. Most transcription tools handle one language at a time, so Hinglish comes back with wrong words, wrong script, or both. Sending the recording to a cloud service fixes some of that, but it puts private conversations on someone else's platform.

The use case is narrow and repeated:

1. A call happens, in a meeting app, a browser, or in the room.
2. The call is recorded and saved without ceremony.
3. A transcript is produced.
4. The transcript is pasted into Claude, which writes the notes.

Scribe covers steps 2 and 3, and makes step 4 a single copy action. It doesn't write the notes itself.

A model comparison shaped the design. On a 5 minute Hindi and English clip, the best local model scored 22.9% against a human-corrected reference, and the best cloud model scored 11.0%. That gap is real, but the local result is usable and it never leaves the Mac, so Scribe is local first and treats cloud models as optional second opinions.

## 2. Users and jobs to be done

### 2.1 User

One person: the owner. A developer on an Apple Silicon Mac who records calls for later reference, is comfortable installing tools with Homebrew, and reads transcripts closely enough to spot a wrong word. There are no other users, no accounts, and no roles.

### 2.2 Jobs to be done

| Job | When | Outcome |
|---|---|---|
| Capture a call | A call starts or has ended | The audio is saved with no extra step |
| Capture both sides | The call is on this Mac (Teams, Meet, a browser) | The other participants are in the recording, not only the microphone |
| Bring in audio from elsewhere | A recording exists as a file | The file becomes a library entry like any other |
| Get an accurate transcript | A recording is saved | Text in the right script, in order, with names spelled usefully, with no network needed |
| Take a second look | A transcript has doubtful passages | Another engine's version sits beside the first, one tab each |
| Hand off to Claude | A transcript is ready | One action copies it with a notes prompt |
| Find it again | Weeks later | Recordings sit in nested, colour-coded folders |
| Stay private | Always | Nothing leaves the Mac unless it's visibly flagged and you agreed |

## 3. Goals and non-goals

### 3.1 Goals

1. Produce the most accurate Hinglish and English transcripts that run on this Mac.
2. Keep every recording and transcript on the Mac by default.
3. Make capture effortless: record or import, with no save step.
4. Make the cloud an explicit, visible choice, never a default that works quietly.
5. Make pasting into Claude one action.
6. Handle recordings longer than 90 minutes.

### 3.2 Non-goals

- Writing notes, summaries, or action items inside Scribe. Claude does that.
- Accounts, sync, sharing, a backend, or telemetry.
- The App Store or any distribution beyond the owner's Mac.
- Windows, Linux, iOS, or Intel Macs.
- Live captions during a call.
- Speaker labels. The cloud prompts ask for none and diarization is off.
- Using Claude as a transcription step. It can't take audio, and a cloud merge breaks the privacy promise (see D-04).

## 4. Principles

1. **Privacy first.** Local is the default engine. No account, no backend, no telemetry. Keys live in the Keychain.
2. **Accuracy over speed.** Time to transcribe doesn't matter. Full-precision models, beam search, and no shortcuts that cost words.
3. **Nothing leaves without a visible warning.** A cloud engine shows a persistent banner, names the company, says whether audio or text goes, and asks before each send. (The home screen auto-send path doesn't ask yet. See OQ-03.)
4. **Audio is never lost.** Audio is saved while recording. A failed transcription doesn't touch it. Deleting a folder doesn't delete it.
5. **Say what's true.** Errors name the cause and the fix. Documents separate what's verified from what's only built.

## 5. User stories

Release key: **0.1** is built in the repo. **Next** is committed. **Later** is proposed.

| ID | Story | Release | Status |
|---|---|---|---|
| US-01 | After a call, the user records the microphone and finds it saved automatically, so no audio is lost to a forgotten save. | 0.1 | Built, untested |
| US-02 | On an online call, the user also records computer audio, so the other side is in the file. | 0.1 | Built, untested |
| US-03 | The user pauses and resumes a recording, so breaks aren't transcribed. | 0.1 | Built, untested |
| US-04 | The user imports an audio file from elsewhere, so old recordings are transcribed too. | 0.1 | Built, untested |
| US-05 | The user tells Scribe whether a call is Hindi + English or English only, so the right model and prompt run. | 0.1 | Verified (English path on a 30 second slice) |
| US-06 | The user gets a transcript with no network, so private calls stay on the Mac. | 0.1 | Verified |
| US-07 | The user sets names and terms once, so recurring spellings come out right. | 0.1 | Built, untested |
| US-08 | The user copies a transcript, or copies it with a notes prompt, so pasting into Claude takes one action. | 0.1 | Built, untested |
| US-09 | The user exports a transcript as text and the audio as a file. | 0.1 | Built, untested |
| US-10 | The user asks another engine for a second opinion and reads the results as tabs. | 0.1 | Built, untested |
| US-11 | The user has Claude review existing transcripts as text only, so audio never goes to Anthropic. | 0.1 | Built, untested |
| US-12 | The user sees a banner whenever a cloud engine is in play, and a confirmation before sending from the detail screen. | 0.1 | Built, untested |
| US-13 | The user organises recordings in nested, colour-coded folders, moved by menu or drag and drop. | 0.1 | Verified (logic), drag and drop untested |
| US-14 | The user deletes a folder without losing any audio. | 0.1 | Verified |
| US-15 | The user stores API keys in the Keychain and enters model names directly. | 0.1 | Built, untested |
| US-16 | The user sees a plain message and the fix when an engine isn't ready. | 0.1 | Built, untested |
| US-17 | The user transcribes a recording of 90 minutes or more without babysitting it. | Next | Planned |
| US-18 | The user is asked before any cloud send, including the automatic one after a recording. | Next | Planned |
| US-19 | The user gets a better English-only model, chosen on a measured English comparison. | Next | Planned |
| US-20 | The user sees every screen in the Graphite design, light and dark. | Next | Planned |
| US-21 | The user compares two or more opinions in one view. | Later | Planned |
| US-22 | The user opens a command palette for the main actions. | Later | Planned |

## 6. Scope by release

### 6.1 Release 0.1 (built)

- Record the microphone, with optional computer audio, to one 16 kHz mono AAC file. Pause and resume.
- Import any audio file.
- Call language per recording: Hindi + English or English only.
- Engines: Local (whisper.cpp), Gemini, ElevenLabs Scribe, and Claude as a text-only reviewer.
- One result per engine per recording, shown as tabs. "Get another opinion" runs more.
- Cloud banner, readiness checks, and a confirmation on the detail screen.
- Nested folders with nine colours. Move by menu or drag and drop.
- Copy, copy for Claude, export transcript, export audio.
- AI Models settings sheet with Keychain-held keys.
- Native SwiftUI, ad-hoc signed, sideload only.

Of its 135 SRS requirements, 20 are verified, 94 are built but untested, and 21 are planned.

### 6.2 Next

| Item | Why | SRS |
|---|---|---|
| Run the unverified paths: live microphone, live computer audio, each cloud request, drag and drop, dark mode | Most of the app has never been exercised against the real thing | KG-16 |
| Ask before every cloud send | Closes the gap between the decision and the build | FR-CLD-03, KG-01 |
| Chunking for long recordings | Recordings can exceed 90 minutes and nothing past 10 minutes 54 seconds is measured | FR-TRN-17, KG-08 |
| English model decision | The English default is unmeasured on English | NFR-PRF-06, KG-09 |
| Graphite design system, light and dark | Design canvases for every scenario screen are in progress | FR-SET-09 |
| Fix the reliability gaps: confirm recording delete, report failed writes, recover interrupted recordings | Each can cost audio or hide a failure | KG-02 to KG-05 |

### 6.3 Later

- Compare-opinions view (proposed, not built).
- Command palette (proposed, not built).
- Search across recordings and transcripts.
- Cancel and resume for running jobs.

## 7. Features

### 7.1 Capture

**Record.** One large button starts and stops. Microphone and, if you tick it, computer audio each get a waveform lane. A timer counts written audio. Stopping saves, opens the recording, and starts transcription with the engine you chose.

**Computer audio.** ScreenCaptureKit captures what the Mac plays and mixes it into the same file as the microphone. Headphones are advised so the microphone doesn't hear the speakers a second time. Scribe excludes its own playback. If computer audio can't start, the recording continues with the microphone only and says so.

**Import.** Pick any audio file. Scribe copies it into the library and leaves the original alone.

**Storage.** Each recording is one folder, `audio.m4a` plus `meta.json`, under `~/Library/Application Support/Scribe/Recordings/<id>/`. Recording files are 48 kbps AAC at 16 kHz mono, which is about 21.6 MB per hour.

### 7.2 Transcription

**Call language.** Hindi + English or English only, chosen before recording and stored with the recording.

**Local.** whisper.cpp through `whisper-cli`, using beam search (size 5), no carry-over between segments, and no voice activity detection. The Hinglish default is Oriserve Whisper-Hindi2Hinglish converted to ggml, in English speech mode so the output is Roman script. English-only calls use a separate model file, default Whisper large-v3 at full precision. Both defaults are full precision.

**Gemini.** Audio goes inline when small, through Google's Files API when large. You enter the model name. An output style switch picks Roman Hinglish or Devanagari Hindi with Latin English.

**ElevenLabs Scribe.** Audio goes as compressed M4A with diarization and audio-event tags off. English-only calls set the language to skip detection.

**Claude (text only).** Claude can't hear audio. It reads the transcripts that exist, labelled by engine and model, and returns one reviewed transcript. It needs at least one transcript first.

**Names and terms.** One field in settings feeds every prompt, so recurring names spell right.

### 7.3 Opinions

After the first transcript, "Get another opinion" runs another engine on the same audio (or Claude on the existing text). Each engine keeps one result, shown as a tab with the model name and time in its tooltip. Running an engine again replaces its tab.

### 7.4 Privacy and cloud disclosure

Local keeps audio on the Mac and needs no network. A cloud engine shows an orange banner above the whole window: "Cloud model in use", the company, and whether audio or text goes. From the detail screen, each cloud send asks first and names the company. API keys sit in the Keychain, in masked fields.

### 7.5 Library

Folders nest to any depth and have nine colours (red, orange, yellow, green, teal, blue, purple, pink, gray). A folder shows how many recordings it holds, subfolders included. Recordings and folders move by menu or drag and drop, and a folder can't move into itself. Deleting a folder moves its contents up one level and never deletes audio.

### 7.6 Output

Copy transcript. Copy for Claude (an editable notes prompt, then the transcript). Export transcript as `.txt`. Export audio. Show the audio file in Finder.

### 7.7 Settings

One sheet, "AI Models". Each engine has a Ready or Needs attention badge with the reason on hover. Local paths, model files, speech mode, names and terms, output style, and the Copy for Claude prompt live here.

## 8. Success measures

No usage numbers exist and none are invented here. Success is measured by accuracy against a reference, by speed, and by checks that can pass or fail.

### 8.1 Accuracy

One 5 minute Hindi and English clip, scored against a human-corrected reference with a rough, script-independent word error measure (words are reduced to a consonant skeleton, so Devanagari and Roman spellings compare). The measure is lenient and good for ranking, not for absolute accuracy.

| Engine or model | Result | Note |
|---|---|---|
| Gemini | 11.0% | The human started from Gemini's text, so this score is flattered |
| ElevenLabs Scribe | 16.1% | Cloud |
| Oriserve Whisper-Hindi2Hinglish (Local default for Hinglish) | 22.9% | Local |
| Whisper large-v3, full precision | 27.9% | Local, default for English-only calls |
| Qwen3-ASR | 32.2% | Not used |
| Shunya | 52% or worse | Not used |
| Whisper large-v3-turbo with voice activity detection | Failed or didn't load | Not used |
| Whisper-based Hinglish previews (Trelis) | Failed or didn't load | Not used |
| Claude Sonnet merge of the four local transcripts | 20.9% | About 80,000 tokens per merge. A 2.0 point gain over Oriserve alone, within noise. Not used. |

Read these with the limits in mind: one clip, one meeting, one reference, and a reference that leans toward Gemini. The local default trails Gemini by 11.9 points.

Success for accuracy: the local default stays the best of the local models tried, and any replacement beats 22.9% on the same clip. English-only has no number yet (OQ-01).

### 8.2 Speed

Oriserve ran at about 4 times real time on an M-series Mac with 16 GB: 2.5 minutes for 10 minutes 54 seconds. Speed is recorded, not targeted, because accuracy outranks it. A 90 minute recording projects to about 22.5 minutes by the same ratio. That is arithmetic, not a measurement.

### 8.3 Checks

| Check | Pass condition | Status |
|---|---|---|
| Local run stays offline | A record, transcribe, and export run with Local chosen opens no network connection | Not run |
| Cloud is flagged | The banner shows from the moment a cloud engine is chosen until the job ends | Built, untested |
| Cloud asks | Every cloud send, from any screen, asks first | Fails on the record and import path (OQ-03) |
| Keys stay in the Keychain | No key in `UserDefaults`, `meta.json`, or exports | Built, untested |
| No audio lost | Audio exists before transcription starts, and a failed job or deleted folder leaves it | Folder deletion verified, the rest untested |
| Hand-off | A finished transcript reaches the clipboard with the notes prompt in one action | Built, untested |
| Requirement coverage | Every SRS requirement moves from Built, untested to Verified | 20 of 135 verified |

## 9. Risks and mitigations

| Risk | Effect | Mitigation |
|---|---|---|
| Local Hinglish trails the best cloud model by 11.9 points on the one clip measured | More wrong words to fix | Second opinions as tabs. Names and terms field. Later clips to confirm the gap. |
| Evidence is one clip, one meeting, and a reference that favours Gemini | The ranking could shift on other calls | Score more clips with an independent reference before changing defaults |
| Cloud auto-send after a recording when a cloud engine is the default | Audio leaves with only a banner | Persistent banner now. A per-send confirmation on that path is Next. |
| Live microphone, computer audio, and every cloud request are unverified | A core path could fail on first use | Run each against the real thing and record the result in the SRS |
| Very long recordings are sent to an engine in one piece | Failure, truncation, or high memory use | Chunking (Next). Gemini and Claude already add a notice or hit a cap, so the end can be cut. |
| An interrupted recording isn't listed and may not play | Lost audio | Write `meta.json` at the start and recover on launch (Next) |
| Recording delete asks no question | An accidental permanent delete | Add a confirmation (Next) |
| Silent write failures | A transcript or folder list is lost without notice | Report every failed write (Next) |
| Model names are typed by hand | A typo returns an HTTP error | The error names the service and the status. Readiness check catches blank names. |
| `whisper-cli` flags change in a Homebrew update | Local transcription fails | The error shows the last 600 characters of output. Pin the version if it breaks. |
| Rebuilding with an ad-hoc signature may reset microphone or screen recording permission | Re-granting after each build | Not confirmed on this Mac. Check at the first live run. |
| Claude merge output is capped at 16,000 tokens and the stop reason isn't checked | A long merge ends early with no notice | Detect the stop reason and warn (not scheduled) |
| English default hasn't been measured on English | A weaker model may be in use | English comparison on an 18 minute call is running |

## 10. Open questions

| ID | Question | Notes |
|---|---|---|
| OQ-01 | Which local model is best for English-only calls? | distil-large-v3, medium.en, Parakeet, and large-v3 are being compared on an 18 minute English call in a separate session. Until then large-v3 stays the default. |
| OQ-02 | How are long recordings chunked, and what does chunking do to accuracy at the seams? | Needs a design and a measurement on a recording over 90 minutes. |
| OQ-03 | Does a cloud default ask before every send, or is auto-sending ruled out? | The decision says each send asks. The record and import path doesn't. |
| OQ-04 | How wide is the real gap between local and cloud once the reference is independent of Gemini? | Needs a second reference and more clips. |
| OQ-05 | Is one tab per engine enough, or do earlier runs need keeping? | Today a rerun replaces the tab. |
| OQ-06 | What does the compare-opinions view show? | Proposed. Side by side, or a word-level diff. |
| OQ-07 | What does the command palette cover? | Proposed. The Graphite design shows a Ctrl K hint in the sidebar search. |
| OQ-08 | Does the Copy for Claude prompt follow the call language? | It always says Hindi and English today. |
| OQ-09 | Do speaker labels come in later? | Today both cloud prompts say they're not needed. |
| OQ-10 | Do permissions survive a rebuild with the ad-hoc signature? | Not confirmed. |

## 11. Decision log

| ID | Decision | Reason | Date |
|---|---|---|---|
| D-01 | Local first. Local is the default engine and cloud is optional. | Private calls stay on the Mac. The local result is usable (22.9% against 11.0% for the best cloud model, on one clip). | 16 Nov 2026 |
| D-02 | Default Hinglish model is Oriserve Whisper-Hindi2Hinglish, converted to ggml, at full precision. | Best of the local models tried: 22.9% against 27.9% for large-v3, 32.2% for Qwen3-ASR, and 52% or worse for Shunya. It ran at about 4 times real time. | 16 Nov 2026 |
| D-03 | Run Hinglish in English speech mode. | The comparison settled this setting, and it gives Roman-script output. Settings also offer Hindi mode and auto-detect. | 16 Nov 2026 |
| D-04 | Claude is not a transcription step. It reviews existing transcripts as text only. | It can't take audio. Merging the four local transcripts scored 20.9%, a gain within noise, at about 80,000 tokens per merge, and a cloud call breaks the privacy promise. | 16 Nov 2026 |
| D-05 | Beam size 5, no carry-over, no voice activity detection. | Accuracy over speed. Large-v3-turbo with voice activity detection failed or didn't load in the comparison. | 16 Nov 2026 |
| D-06 | Use full-precision (f16) model files for both defaults. | Accuracy over speed, and time isn't a constraint. | 16 Nov 2026 |
| D-07 | A different model file for English-only calls, default Whisper large-v3. | English-only calls don't run through a code-switching fine-tune. The English default is provisional until OQ-01 closes. | 16 Nov 2026 |
| D-08 | Save audio automatically while recording, as 16 kHz mono AAC. | No audio lost to a forgotten save. Whisper needs 16 kHz mono anyway, and the files stay small. | 16 Nov 2026 |
| D-09 | Mix computer audio into the same single file as the microphone. | One file is simple to store and transcribe. The cost is no separate speaker tracks. | 16 Nov 2026 |
| D-10 | Deleting a folder moves its contents up and never deletes audio. | A folder is an organising tool, so removing one doesn't cost a recording. | 16 Nov 2026 |
| D-11 | A persistent cloud banner and a confirmation on each cloud send. | Nothing leaves without a visible warning. The confirmation is built on the detail screen only (OQ-03). | 16 Nov 2026 |
| D-12 | API keys live in the Keychain. | Secrets stay out of files and preferences. | 16 Nov 2026 |
| D-13 | Personal use, sideload only, no backend, no accounts, no telemetry, no App Store. | One user and a privacy promise. Nothing to host or sign in to. | 16 Nov 2026 |
| D-14 | macOS 14 or later on Apple Silicon, built with plain `swiftc` and ad-hoc signed. | Matches the owner's Mac and keeps the build to one script with no Xcode project. | 16 Nov 2026 |
| D-15 | Call `whisper-cli` as a program, supplied by Homebrew `whisper-cpp`. | Keeps whisper.cpp out of the build and lets Homebrew update it. | 16 Nov 2026 |
| D-16 | Cloud model names are typed by the user. | The names change faster than the app, and the defaults are only starting values. | 16 Nov 2026 |
| D-17 | Ship native SwiftUI first and apply the Graphite design system after. | Function came before polish. Graphite has dark as the default theme and every screen on a Claude Design canvas. | 16 Nov 2026 |
| D-18 | Notes are written in Claude, not in Scribe. | Scribe stays small, and the hand-off is one copy action. | 16 Nov 2026 |

The reasons in D-03, D-07, D-09, D-10, D-15, D-16, and D-18 are recorded from the code and its comments, not from a separate written decision. Correct them here if the intent was different.
