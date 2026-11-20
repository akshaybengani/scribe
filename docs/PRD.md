# Scribe product requirements

Version 0.2 · Draft · 17 Nov 2026 · Owner: Akshay Bengani · Companion: [SRS.md](SRS.md)

Scribe is a personal, privacy-first Mac app that records or imports audio of a call and turns it into text. Calls mix Hindi and English (Hinglish) or are English only. The transcript is pasted into Claude to make notes. This document says what Scribe is for, what's built, what comes next, and why each call was made. The SRS holds the testable requirements.

## 1. Problem and context

Calls in this work mix Hindi and English inside a single sentence. Most transcription tools handle one language at a time, so Hinglish comes back with wrong words, wrong script, or both. Sending the recording to a cloud service fixes some of that, but it puts private conversations on someone else's platform.

The use case is narrow and repeated:

1. A call happens, in a meeting app, a browser, or in the room.
2. The call is recorded and saved without ceremony.
3. A transcript is produced.
4. Notes are written from the transcript.

Scribe covers steps 2 and 3. For step 4 it offers two ways: one copy action to paste the transcript into Claude, or meeting notes written inside Scribe by a local Ollama model or by Claude (D-37).

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
| Get meeting notes | A transcript is ready | Summary, decisions, action items with owners, and open questions sit on the recording, written locally or by Claude |
| Find it again | Weeks later | Recordings sit in nested, colour-coded folders, and a search finds any word in any transcript |
| Follow a long job | A recording runs for an hour or more | Progress shows percent, elapsed, time remaining, which part of how many, and the upload stage |
| Take everything out | You want a copy outside Scribe | Export gives the audio, every transcript as text, a combined Markdown file, and a metadata file |
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

- ~~Writing notes, summaries, or action items inside Scribe.~~ Reversed on 20 Nov 2026 (D-37): Scribe now writes meeting notes, and Copy for Claude stays.
- Accounts, sync, sharing, a backend, or telemetry.
- The App Store or any distribution beyond the owner's Mac.
- Windows, Linux, iOS, or Intel Macs.
- Live captions during a call.
- Speaker labels the provider doesn't return. Scribe shows labels only when a provider returns them (ElevenLabs Scribe today, Gemini 3.5 Transcribe next) and adds nothing otherwise.
- Windows. Mac only for now, with Windows later.
- Encryption at rest and a backup feature. Export is the way out.
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
| US-17 | The user transcribes a recording of 90 minutes or more without babysitting it. Cloud engines split it into parts of about 25 minutes. Local isn't split yet. | Next | Cloud built, untested. Local planned. |
| US-18 | The user is asked before any cloud send, including the automatic one after a recording. | Next | Planned |
| US-19 | The user gets English-only calls transcribed with large-v3-turbo (5-bit), with the English comparison numbers recorded. | Next | Default set, numbers not recorded |
| US-20 | The user sees every screen in the Graphite design, following the system light or dark setting. | 0.1 | Built, untested |
| US-21 | The user compares two or more opinions in one view. | Later | Planned |
| US-22 | The user searches every title, folder path, and transcript from a bar at the top centre of the window, focused with Cmd+K. | 0.1 | Built, untested |
| US-23 | The user watches a long job with percent, elapsed, remaining, part x of y, and the upload stage. | 0.1 | Built, untested |
| US-24 | The user sees speaker labels when a provider returns them, and nothing extra otherwise. | 0.1 | ElevenLabs and Gemini built, untested |
| US-25 | The user picks a model from each provider's own list once a key exists, audio models first, with a Refresh models button. | 0.1 | Picker and Refresh on the record screen built, untested. Settings sheet and 24 hour refresh planned. |
| US-26 | The user selects several recordings and exports everything: audio, every transcript as text, combined Markdown, and metadata JSON. | Next | Dialog and metadata JSON built, untested. Selecting several recordings doesn't open it yet. |
| US-27 | The user works from the keyboard: Space, Cmd+N, Cmd+Shift+N, Cmd+, , Cmd+E, and Cmd+K, with no menu bar icon. | 0.1 | Built, untested |
| US-28 | The user deletes a recording after a confirmation, and its audio and transcripts go together. | 0.1 | Built, untested |
| US-29 | The user writes meeting notes from a transcript with a local Ollama model, so private calls get notes without leaving the Mac. | 0.3 | Built, untested |
| US-30 | The user writes meeting notes with Claude, after seeing that the transcript text (not audio) goes to Anthropic. | 0.3 | Built, untested |
| US-31 | The user adds project files (for example a repository) as context for the notes, linked to a library folder. | Next | Planned (phase 2) |

## 6. Scope by release

### 6.1 Release 0.1 (built)

- Record the microphone, with optional computer audio, to one 16 kHz mono AAC file. Pause and resume.
- Import any audio file.
- Call language per recording: Hindi + English or English only.
- Engines: Local (whisper.cpp), Gemini, ElevenLabs Scribe, and Claude as a text-only reviewer, with an API key or through Claude Code on the user's subscription.
- One result per engine per recording, shown as tabs. "Get another opinion" runs more.
- Cloud banner, readiness checks, and a confirmation on the detail screen.
- Nested folders with nine colours. Move by menu or drag and drop.
- Copy, copy for Claude, export transcript, export audio.
- Settings sheet with Keychain-held keys.
- The Graphite design in the app, following the system light or dark setting.
- Keyboard shortcuts (Space, Cmd+N, Cmd+Shift+N, Cmd+, , Cmd+E, Cmd+K) and no menu bar icon.
- Delete a recording after a confirmation. Its audio and transcripts go together.
- Chunking for Gemini and ElevenLabs on recordings over 60 minutes (29 minutes for Gemini 3.5 Transcribe with speaker labels), with a retry on transient failures.
- Speaker labels from ElevenLabs and Gemini 3.5 Transcribe when they return them, shown as speaker blocks.
- Gemini 3.5 Transcribe through the Interactions API.
- Global search from a bar at the top centre (Cmd+K), and a find bar inside a transcript.
- A job screen with percent, stage, elapsed, time left, chunk x of y, and upload bytes.
- A model picker with a Refresh models button, loaded from each provider's list-models API.
- An export dialog that writes the audio, a text file per transcript, one combined Markdown file, and metadata.json for each recording.
- Inter and JetBrains Mono bundled under the SIL OFL.
- Native SwiftUI, signed with a stable local certificate when it exists, sideload only.

Of its 181 SRS requirements, 15 are verified, 147 are built but untested, and 19 are planned. Several verified checks predate the 17 Nov 2026 changes and need a re-run.

### 6.2 Next

| Item | Why | SRS |
|---|---|---|
| Run the unverified paths: live microphone, live computer audio, each cloud request, drag and drop, dark mode | Most of the app has never been exercised against the real thing | KG-16 |
| Ask before every cloud send | Closes the gap between the decision and the build | FR-CLD-03, KG-01 |
| Live Gemini test with your key | The Interactions API path for the default model has never sent a request | FR-TRN-19, EXT-11, KG-18 |
| Open the export dialog from a multi-selection | The dialog and writer exist, and nothing opens them from a selection | FR-EXP-11, KG-11 |
| Put the model picker in the Settings sheet, and refresh lists older than 24 hours | The picker sits on the record screen, and Settings still shows a text field | FR-MDL-05, KG-11 |
| A speaker labels switch | The setting exists with no control | FR-SPK-04 |
| Run the built paths: search, progress, chunking, export, model lists, Interactions | They were written after the last verified run | Section 6.3 of the SRS |
| Record the English comparison numbers behind large-v3-turbo (5-bit) | The default changed and the evidence isn't in these documents | NFR-PRF-06, KG-09 |
| Check the stable signing certificate across a rebuild | Permissions are expected to survive a rebuild, and nobody has checked | FR-APP-06, KG-17 |
| Fix the reliability gaps: report failed writes, recover interrupted recordings, cancel and resume jobs | Each can cost audio or hide a failure | KG-02, KG-03, KG-05 |

### 6.3 Later

- Compare-opinions view (proposed, not built).
- Local chunking for very long recordings.
- ElevenLabs live test, once there's a key.
- Windows.

## 7. Features

### 7.1 Capture

**Record.** One large button starts and stops. Microphone and, if you tick it, computer audio each get a waveform lane. A timer counts written audio. Stopping saves the recording and then asks which language the call was in, Hindi and English or English only, because people often do not know during the call. Transcription starts only when you confirm. You can also leave it for later and pick the language again from the Library.

**Computer audio.** ScreenCaptureKit captures what the Mac plays and mixes it into the same file as the microphone. Headphones are advised so the microphone doesn't hear the speakers a second time. Scribe excludes its own playback. If computer audio can't start, the recording continues with the microphone only and says so.

**Import.** Pick any audio file. Scribe copies it into the library and leaves the original alone.

**Storage.** Each recording is one folder, `audio.m4a` plus `meta.json`, under `~/Library/Application Support/Scribe/Recordings/<id>/`. Recording files are 48 kbps AAC at 16 kHz mono, which is about 21.6 MB per hour.

### 7.2 Transcription

**Call language.** Hindi + English or English only, chosen before recording and stored with the recording.

**Local.** whisper.cpp through `whisper-cli`, using beam search (size 5), no carry-over between segments, and no voice activity detection. The Hinglish default is Oriserve Whisper-Hindi2Hinglish converted to ggml, in English speech mode so the output is Roman script. English-only calls use a separate model file, default Whisper large-v3-turbo at 5-bit. The Hinglish default is full precision. Output streams as it runs, so progress can show.

**Gemini.** The default model is `gemini-3.5-transcribe`, a dedicated speech model with speaker labels and 85+ languages including Hindi and English India. It's called through Google's Interactions API, with 1 hour per request and 30 minutes with diarization, up to 8 speakers. The code uploads each part through the Files API and then calls that API, and it has never sent a live request. Other Gemini models go through generateContent, inline when small and through the Files API when large. An output style switch picks Roman Hinglish or Devanagari Hindi with Latin English.

**ElevenLabs Scribe.** The default model is `scribe_v2`. Audio goes as compressed M4A with audio-event tags off and diarization on, so a call with 2 or more speakers comes back as "Speaker 1: ..." lines. English-only calls set the language to skip detection.

**Claude (text only).** Claude can't hear audio. It reads the transcripts that exist, labelled by engine and model, and returns one reviewed transcript. It needs at least one transcript first.

**Names and terms.** One field in settings feeds every prompt, so recurring names spell right.

**Speaker labels.** Scribe shows labels only when a provider returns them, and adds nothing otherwise. ElevenLabs does today. Gemini 3.5 Transcribe does too, through its diarization mode. Local and Claude return none. When a transcript has 2 or more speakers the screen shows speaker blocks. When it has none, it shows nothing extra.

**Long recordings.** For Gemini and ElevenLabs, a recording over 60 minutes is split into parts of about 25 minutes. For Gemini 3.5 Transcribe with speaker labels the limit is 29 minutes, because Google cuts a diarized request at 30. Speaker numbers may not match between parts, and the job says so. Each cut lands at the quietest stretch within 90 seconds of the target, each part carries the last few lines of the one before it as context, and the parts are stitched in order. A part that fails on a timeout, a dropped connection, or HTTP 429 or 5xx retries up to 3 attempts in all. Local isn't split.

**Progress.** A running job tracks its stage (Preparing audio, Transcribing, Uploading, Waiting for provider, Merging parts), percent, elapsed time, estimated time remaining, speed, upload bytes, and part x of y. A single cloud request shows no percentage while the provider works, because none is honest. The job screen shows percent, a bar, the stage, elapsed time, about how long is left (or "estimating"), chunk x of y, audio length, and speed.

### 7.3 Opinions

After the first transcript, "Get another opinion" runs another engine on the same audio (or Claude, or Claude through Claude Code, on the existing text). Each engine keeps one result, shown as a tab with the model name and time in its tooltip. Running an engine again replaces its tab.

### 7.4 Privacy and cloud disclosure

Local keeps audio on the Mac and needs no network. A cloud engine shows an orange banner above the whole window: "Cloud model in use", the company, and whether audio or text goes. From the detail screen, each cloud send asks first and names the company. API keys sit in the Keychain, in masked fields.

### 7.5 Library and search

Folders nest to any depth and have nine colours (red, orange, yellow, green, teal, blue, purple, pink, gray). A folder shows how many recordings it holds, subfolders included. Recordings and folders move by menu or drag and drop, and a folder can't move into itself. Deleting a folder moves its contents up one level and never deletes audio. Deleting a recording asks first, then removes its audio and transcripts together.

Search covers every title, folder path, and transcript tab. It ignores case, diacritics, and punctuation, matches substrings, needs every word of a multi-word query, and takes a quoted phrase exactly. It doesn't transliterate, so a Roman query doesn't find Devanagari text. A title match outranks a phrase match, which outranks a term match. A bar in the title area at the top centre of the window, shaped like a browser address field, takes the query. Cmd+K focuses it, Up and Down move, Return opens a hit, and Esc closes. A transcript hit opens the recording on the matching tab with a find bar on the query. Folders whose name matches appear too.

### 7.6 Output

Copy transcript. Copy for Claude (an editable notes prompt, then the transcript). Export transcript as `.txt`. Export audio. Show the audio file in Finder.

The export dialog gives everything for each recording in its own folder named by title and date: the audio, one text file per transcript, one combined Markdown file, and a `metadata.json`. It never overwrites a file and reports each failure. Nothing opens it from a multi-selection yet. A lower-level export engine also exists (text or Markdown, one file per tab or combined, flat or mirrored folders).

### 7.7 Settings

One sheet, opened with Cmd+, . Each engine has a Ready or Needs attention badge with the reason on hover. Local paths, model files, speech mode, names and terms, output style, and the Copy for Claude prompt live here.

**Model lists.** Once a key exists, Scribe loads the provider's list-models API (Gemini, ElevenLabs, Anthropic), merges it with curated names, and sorts audio models first, then pinned picks, then newest. A name you type stays in the list. A failed refresh keeps the last good list. Lists cache for 24 hours and refresh when a key changes. A picker with a Refresh models button, a speaker labels chip, and a warning for a model that doesn't take audio sits on the record screen. The Settings sheet still shows a text field for the model name.

### 7.8 Appearance and keyboard

The app follows the system light or dark setting in the Graphite design, with the lime accent. The logo is the Caret wave: four grey sound bars ending in a lime text cursor, used as the app icon and in the app. Space plays and pauses, Cmd+N starts a recording, Cmd+Shift+N a folder, Cmd+, opens settings, Cmd+E exports the transcript, and Cmd+K opens search. There's no menu bar icon. Inter and JetBrains Mono are bundled by `build.sh` and registered at launch, with system fonts as the fallback. `build.sh` signs with a local certificate called Scribe Local Signing when it exists, so macOS keeps microphone and screen recording permission across rebuilds.

## 8. Success measures

No usage numbers exist and none are invented here. Success is measured by accuracy against a reference, by speed, and by checks that can pass or fail.

### 8.1 Accuracy

One 5 minute Hindi and English clip, scored against a human-corrected reference with a rough, script-independent word error measure (words are reduced to a consonant skeleton, so Devanagari and Roman spellings compare). The measure is lenient and good for ranking, not for absolute accuracy.

| Engine or model | Result | Note |
|---|---|---|
| Gemini | 11.0% | The human started from Gemini's text, so this score is flattered |
| ElevenLabs Scribe | 16.1% | Cloud |
| Oriserve Whisper-Hindi2Hinglish (Local default for Hinglish) | 22.9% | Local |
| Whisper large-v3, full precision | 27.9% | Local. English-only calls now default to large-v3-turbo at 5-bit instead (OQ-01). |
| Qwen3-ASR | 32.2% | Not used |
| Shunya | 52% or worse | Not used |
| Whisper large-v3-turbo with voice activity detection | Failed or didn't load | Not used |
| Whisper-based Hinglish previews (Trelis) | Failed or didn't load | Not used |
| Claude Sonnet merge of the four local transcripts | 20.9% | About 80,000 tokens per merge. A 2.0 point gain over Oriserve alone, within noise. Not used. |

Read these with the limits in mind: one clip, one meeting, one reference, and a reference that leans toward Gemini. The local default trails Gemini by 11.9 points.

Success for accuracy: the local default stays the best of the local models tried, and any replacement beats 22.9% on the same clip. English-only has no number in these documents yet (OQ-01).

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
| Requirement coverage | Every SRS requirement moves from Built, untested to Verified | 15 of 181 verified |

## 9. Risks and mitigations

| Risk | Effect | Mitigation |
|---|---|---|
| Local Hinglish trails the best cloud model by 11.9 points on the one clip measured | More wrong words to fix | Second opinions as tabs. Names and terms field. Later clips to confirm the gap. |
| Evidence is one clip, one meeting, and a reference that favours Gemini | The ranking could shift on other calls | Score more clips with an independent reference before changing defaults |
| Cloud auto-send after a recording when a cloud engine is the default | Audio leaves with only a banner | Persistent banner now. A per-send confirmation on that path is Next. |
| Live microphone, computer audio, and every cloud request are unverified | A core path could fail on first use | Run each against the real thing and record the result in the SRS |
| Local sends a very long recording to `whisper-cli` in one piece | Failure or high memory use | Cloud chunking is built. Local chunking is later. Time past 10 minutes 54 seconds isn't measured. |
| The Interactions API path for the default Gemini model has never sent a request | A Gemini job on the default model can fail on a field name | A live test with your key. The code retries once without diarization and once with another input block on a 400. |
| An interrupted recording isn't listed and may not play | Lost audio | Write `meta.json` at the start and recover on launch (Next) |
| Search, progress, chunking, export, model lists, and the Interactions path were written after the last verified run | Any of them can fail on first use | Run each and update the SRS (Next) |
| Silent write failures | A transcript or folder list is lost without notice | Report every failed write (Next) |
| Model names are typed by hand | A typo returns an HTTP error | The error names the service and the status. Readiness check catches blank names. |
| `whisper-cli` flags change in a Homebrew update | Local transcription fails | The error shows the last 600 characters of output. Pin the version if it breaks. |
| The stable signing certificate hasn't been checked across a rebuild | Permission may be re-asked after each build | Check the designated requirement is identical after a rebuild (Next). A Mac without the certificate signs ad-hoc and asks again. |
| Claude merge output is capped at 16,000 tokens and the stop reason isn't checked | A long merge ends early with no notice | Detect the stop reason and warn (not scheduled) |
| The English default (large-v3-turbo, 5-bit) has no recorded numbers here | The pick can't be checked from these documents | Record the English comparison numbers (Next) |

## 10. Open questions

| ID | Question | Notes |
|---|---|---|
| OQ-01 | What are the numbers behind large-v3-turbo (5-bit) as the English default? | The default is set, and the comparison of distil-large-v3, medium.en, Parakeet, and large-v3 on an 18 minute English call hasn't been written up here. |
| OQ-02 | What does chunking do to accuracy at the seams, and when does Local need it? | Cloud chunking is built (25 minute parts at the quietest point). It needs a measurement on a recording over 90 minutes. |
| OQ-03 | Does a cloud default ask before every send, or is auto-sending ruled out? | The decision says each send asks. The record and import path doesn't. |
| OQ-04 | How wide is the real gap between local and cloud once the reference is independent of Gemini? | Needs a second reference and more clips. |
| OQ-05 | Is one tab per engine enough, or do earlier runs need keeping? | Today a rerun replaces the tab. |
| OQ-06 | What does the compare-opinions view show? | Proposed. Side by side, or a word-level diff. |
| OQ-07 | What does choosing a search hit do? | Planned: open the recording at its first match. The search bar sits at the top centre like a browser address field. |
| OQ-08 | Does the Copy for Claude prompt follow the call language? | It always says Hindi and English today. |
| OQ-09 | Do generateContent models need a speaker labels prompt? | Their prompts still say labels aren't needed. The Interactions path asks for diarization in its request. |
| OQ-10 | Do permissions survive a rebuild with the stable certificate? | Expected, not checked. |
| OQ-11 | Does `gemini-3.5-transcribe` work on your key, and with what request? | Needs a live test with your Gemini key. |
| OQ-12 | When do ElevenLabs and Anthropic get live tests? | ElevenLabs later. No ElevenLabs or Anthropic key exists yet. |
| OQ-13 | When does Windows start? | Later. Mac only for now. |

## 11. Decision log

| ID | Decision | Reason | Date |
|---|---|---|---|
| D-01 | Local first. Local is the default engine and cloud is optional. | Private calls stay on the Mac. The local result is usable (22.9% against 11.0% for the best cloud model, on one clip). | 16 Nov 2026 |
| D-02 | Default Hinglish model is Oriserve Whisper-Hindi2Hinglish, converted to ggml, at full precision. | Best of the local models tried: 22.9% against 27.9% for large-v3, 32.2% for Qwen3-ASR, and 52% or worse for Shunya. It ran at about 4 times real time. | 16 Nov 2026 |
| D-03 | Run Hinglish in English speech mode. | The comparison settled this setting, and it gives Roman-script output. Settings also offer Hindi mode and auto-detect. | 16 Nov 2026 |
| D-04 | Claude is not a transcription step. It reviews existing transcripts as text only. | It can't take audio. Merging the four local transcripts scored 20.9%, a gain within noise, at about 80,000 tokens per merge, and a cloud call breaks the privacy promise. | 16 Nov 2026 |
| D-05 | Beam size 5, no carry-over, no voice activity detection. | Accuracy over speed. Large-v3-turbo with voice activity detection failed or didn't load in the comparison. | 16 Nov 2026 |
| D-06 | Use full-precision (f16) model files for both defaults. | Accuracy over speed, and time isn't a constraint. | 16 Nov 2026 |
| D-07 | A different model file for English-only calls. Default Whisper large-v3, changed to large-v3-turbo (5-bit) on 17 Nov 2026 (D-27). | English-only calls don't run through a code-switching fine-tune. | 16 Nov 2026 |
| D-08 | Save audio automatically while recording, as 16 kHz mono AAC. | No audio lost to a forgotten save. Whisper needs 16 kHz mono anyway, and the files stay small. | 16 Nov 2026 |
| D-09 | Mix computer audio into the same single file as the microphone. | One file is simple to store and transcribe. The cost is no separate speaker tracks. | 16 Nov 2026 |
| D-10 | Deleting a folder moves its contents up and never deletes audio. | A folder is an organising tool, so removing one doesn't cost a recording. | 16 Nov 2026 |
| D-11 | A persistent cloud banner and a confirmation on each cloud send. | Nothing leaves without a visible warning. The confirmation is built on the detail screen only (OQ-03). | 16 Nov 2026 |
| D-12 | API keys live in the Keychain. | Secrets stay out of files and preferences. | 16 Nov 2026 |
| D-13 | Personal use, sideload only, no backend, no accounts, no telemetry, no App Store. | One user and a privacy promise. Nothing to host or sign in to. | 16 Nov 2026 |
| D-14 | macOS 14 or later on Apple Silicon, built with plain `swiftc`. Signed ad-hoc, then with a stable local certificate (D-34). | Matches the owner's Mac and keeps the build to one script with no Xcode project. | 16 Nov 2026 |
| D-15 | Call `whisper-cli` as a program, supplied by Homebrew `whisper-cpp`. | Keeps whisper.cpp out of the build and lets Homebrew update it. | 16 Nov 2026 |
| D-16 | Cloud model names are typed by the user. | The names change faster than the app, and the defaults are only starting values. | 16 Nov 2026 |
| D-17 | Ship native SwiftUI first and apply the Graphite design system after. The design is now in the app (D-19). | Function came before polish. Every screen is on a Claude Design canvas. | 16 Nov 2026 |
| D-18 | Notes are written in Claude, not in Scribe. Replaced by D-37. | Scribe stays small, and the hand-off is one copy action. | 16 Nov 2026 |
| D-19 | The app follows the system light or dark setting in the Graphite design. | The decision came from the owner. The tokens already carry both themes, so there's no setting to keep. | 16 Nov 2026 |
| D-20 | Global search across all transcripts, as a bar at the top centre of the window like a browser address field, focused with Cmd+K. | Decided by the owner on 16 and 17 Nov 2026. It replaces the proposed command palette. | 17 Nov 2026 |
| D-21 | Show progress for long recordings: percent, elapsed, remaining, chunk x of y, and the upload stage. | Decided by the owner. A job can run for an hour or more, and a bare spinner says nothing about it. | 17 Nov 2026 |
| D-22 | Show speaker labels only when a provider returns them, and add nothing otherwise. | Decided by the owner. It replaces the earlier non-goal. ElevenLabs scribe_v2 and Gemini 3.5 Transcribe both return them. | 17 Nov 2026 |
| D-23 | Multi-select export gives everything: audio, every transcript as text, a combined Markdown file, and metadata JSON. | Decided by the owner. Export is the way out, since there's no backup feature (D-30). | 17 Nov 2026 |
| D-24 | Load model lists from each provider's list-models API once a key exists, audio models first, plus curated names and a Refresh models button. | Decided by the owner. Names change faster than the app. This replaces D-16. | 17 Nov 2026 |
| D-25 | The Gemini model is `gemini-3.5-transcribe`, through the Interactions API. Chunk long audio at 25 minutes. | The model allows 1 hour per request and 30 minutes with diarization, up to 8 speakers, with 85+ languages including Hindi and English India. | 17 Nov 2026 |
| D-26 | The ElevenLabs model is `scribe_v2`. | Decided by the owner. The code lists `scribe_v3` too, and `scribe_v2` is the default and the pinned pick. | 17 Nov 2026 |
| D-27 | The English-only local default is large-v3-turbo at 5-bit. The Hinglish default stays Oriserve. | Decided by the owner. The code comment calls it the pick from the English bake-off, and the numbers aren't recorded here (OQ-01). | 17 Nov 2026 |
| D-28 | Keyboard shortcuts Space, Cmd+N, Cmd+Shift+N, Cmd+, , Cmd+E, and Cmd+K. No menu bar icon. | Decided by the owner. | 17 Nov 2026 |
| D-29 | Deleting a recording deletes its audio and transcripts together, after a confirmation. | Decided by the owner. A transcript without its audio can't be checked. | 17 Nov 2026 |
| D-30 | No encryption at rest and no backup feature. Export instead. | Decided by the owner. Scribe holds private audio on one Mac, and export gives a copy. | 17 Nov 2026 |
| D-31 | Mac only for now. Windows later. | Decided by the owner. | 17 Nov 2026 |
| D-32 | Bundle Inter and JetBrains Mono under the SIL OFL. | Decided by the owner. They're the Graphite fonts. `build.sh` bundles them, untested. | 17 Nov 2026 |
| D-33 | The Caret wave logo is the app icon and appears in the app. | Decided by the owner. It replaces the first bars-and-lines mark. | 17 Nov 2026 |
| D-34 | Sign with a stable local certificate called Scribe Local Signing. | macOS ties the microphone and screen recording grants to the signing requirement, and an ad-hoc signature changes on every build. | 17 Nov 2026 |
| D-35 | Claude is used for text review only, never for audio. | It can't take audio (D-04), and audio never goes to Anthropic. | 17 Nov 2026 |
| D-37 | Scribe writes meeting notes from a transcript, with a local Ollama model (the default, nothing leaves the Mac) or Claude through Claude Code on the user's subscription, with no API key (transcript text only, confirmed each time). Notes are English, one set per recording, and regenerating replaces them. Project context, long-call splitting for local models, and Claude exploring code come in later phases. | Decided by the owner. Notes inside the app save a round trip and keep them with the call. It replaces D-18 and the notes non-goal. | 20 Nov 2026 |
| D-36 | The PRD and SRS live in the repository `docs/` folder. | Decided by the owner. | 17 Nov 2026 |

The reasons in D-03, D-07, D-09, D-10, D-15, D-16, and D-18 are recorded from the code and its comments, not from a separate written decision. Correct them here if the intent was different. For D-19 to D-33 and D-36, the owner made the decision and no separate reason was recorded, so the reason column states only what the code or the owner's notes support.

## 12. Changelog

| Date | Version | Change |
|---|---|---|
| 17 Nov 2026 | 0.2 | New scope: follow the system theme in Graphite, global search, long-job progress, speaker labels from providers that return them, multi-select export that gives everything, model lists from each provider, `gemini-3.5-transcribe` and `scribe_v2`, large-v3-turbo (5-bit) for English-only calls, keyboard shortcuts, no encryption or backup, Mac only for now, bundled fonts, the Caret wave logo, and a stable signing certificate. Stories US-22 to US-28, questions OQ-11 to OQ-13, and decisions D-19 to D-36 added. The command palette was dropped in favour of search. Recording delete now confirms. The risk list and the Next list changed to match. |
| 16 Nov 2026 | 0.1 | First version. |

## 13. Open items

- Live Gemini test with your key, then the Interactions API.
- ElevenLabs live test, later.
- Windows, later.
- Run the unverified paths and re-run the Local pipeline after the progress and English-default changes.
- Record the English comparison numbers.
- Decide how a cloud default asks before every send (OQ-03).
