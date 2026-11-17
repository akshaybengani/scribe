# Scribe software requirements specification

Version 0.2 · Draft · 17 Nov 2026 · Owner: Akshay Bengani · Format: IEEE 830 style · Companion: [PRD.md](PRD.md)

This document specifies what Scribe does and what it is required to do next. It was written from the source in `Sources/*.swift`, `build.sh`, `setup/*.sh`, and `docs/design/GRAPHITE.md`, and updated on 17 Nov 2026 for the new scope (see section 8). A requirement marked Verified or Built, untested describes code that exists. A requirement marked Planned describes code that doesn't exist yet. The status column is the only place that distinction is made, so read it before relying on a row.

## 1. Introduction

### 1.1 Purpose

This SRS defines the functional, non-functional, and external interface requirements of Scribe, a personal macOS app that turns recorded or imported audio into text. It is the reference for building, testing, and changing the app. The PRD holds the reasons behind the requirements.

### 1.2 Scope

Scribe records the microphone (optionally with computer audio) or imports an audio file, saves the audio automatically, transcribes it, and lets you search, copy, or export the transcripts. Calls are either Hindi and English mixed (Hinglish) or English only. Transcription runs on the Mac by default. Cloud engines are optional and always disclosed.

In scope: recording, import, transcription, long-recording chunking and progress, opinions from other engines, speaker labels from providers that return them, model lists, folders, global search, settings, export, appearance and shortcuts, error handling, local storage, and the interfaces to external tools and services.

Out of scope: summarising or extracting notes (you paste the transcript into Claude for that), accounts, sync, a backend, telemetry, distribution through the App Store, platforms other than macOS (Windows is later), live captions, encryption at rest, a backup feature (export is the way out), and speaker labels from a provider that doesn't return them.

### 1.3 Definitions, acronyms, and abbreviations

| Term | Meaning |
|---|---|
| Hinglish | Speech that mixes Hindi and English within a call. Called "Hindi + English" in the app. |
| Call language | A per-recording choice: Hindi + English (`mixed`) or English only (`english`). |
| Engine | A source of transcripts: Local, Gemini, ElevenLabs, or Claude. The code calls it a provider. |
| Local | whisper.cpp run through `whisper-cli` on this Mac. |
| Cloud engine | Any engine other than Local. Gemini and ElevenLabs receive audio. Claude receives transcript text only. |
| Opinion | A transcript from an engine other than the first one used on a recording. |
| Result | One stored transcript with its engine, model name, text, duration, and date. |
| Recording | One library entry: an audio file, metadata, and zero or more results. |
| Library | All recordings and folders under `~/Library/Application Support/Scribe/Recordings/`. |
| Chunk (part) | One piece of a long recording, sent to a cloud engine as its own request. |
| Diarization | Labelling who is speaking. Scribe shows labels only when a provider returns them. |
| Model list | The models a provider's list-models API returns once a key exists, merged with curated names. |
| Interactions API | The Google API that Gemini 3.5 Transcribe is called through. Not built yet. |
| ggml | The model file format whisper.cpp reads. |
| f16, q5_0 | Full 16-bit precision, and a 5-bit quantised file, for ggml model files. |
| WER | Word error rate. In this project, a rough script-independent measure (see the PRD), not a standard WER. |
| TCC | The macOS permission system for microphone and screen recording. |
| SCK | ScreenCaptureKit, the macOS framework that captures computer audio. |
| AAC, ADTS | The audio codec used for stored files, and the raw AAC container Gemini receives. |
| OFL | The SIL Open Font License that covers Inter and JetBrains Mono. |

### 1.4 References

- PRD: [docs/PRD.md](PRD.md)
- Design system: [docs/design/GRAPHITE.md](design/GRAPHITE.md)
- Build and signing: `build.sh`, `assets/README.md`
- Model and engine setup: `setup/download-models.sh`, `setup/hinglish-models.sh`, `setup/english-models.sh`
- Comparison runs: `setup/bakeoff*.sh`, `setup/english-bakeoff.sh`. The scoring scripts aren't published because they need a private reference transcript.

### 1.5 Overview

Section 2 describes the product and its environment. Section 3 lists the requirements with unique IDs: EXT (external interfaces), FR (functional), NFR (non-functional), and CON (design constraints). Section 4 defines the data model. Section 5 covers state and error handling. Section 6 traces each requirement to source and gives its verification status. Section 7 lists known gaps. Section 8 is the changelog and section 9 lists open items.

Status values used throughout:

- **Verified**: exercised and checked in a build session.
- **Built, untested**: the code exists and compiles into the app, but nobody has exercised it, or it changed after it was last verified.
- **Planned**: not built.

## 2. Overall description

### 2.1 Product perspective

Scribe is a standalone single-window macOS app. It has no server component. It shells out to two programs (`whisper-cli` and `afconvert`), uses system frameworks for audio and permissions, and optionally calls three REST APIs for transcription and the same three for model lists. Setup scripts, which run outside the app, are the only part that downloads models.

```
Record:      microphone (plus computer audio through ScreenCaptureKit) → mixer → AAC writer → Recordings/<id>/audio.m4a
Import:      audio file → copy → Recordings/<id>/audio.<ext>
Local:       audio → afconvert (WAV) → whisper-cli → Local result
Gemini:      audio → afconvert (ADTS AAC, in parts when long) → Gemini API → Gemini result
ElevenLabs:  audio → afconvert (M4A, in parts when long) → ElevenLabs API → ElevenLabs result
Claude:      existing results (text only) → Anthropic API → Claude result
Search:      titles, folder paths, every transcript tab → in-memory index → ranked hits
Export:      selected recordings → destination folder (text, Markdown, audio)
```

### 2.2 Product functions

1. Record the microphone, optionally with computer audio, to one file.
2. Import an existing audio file.
3. Transcribe with the engine you choose, for the call language you choose, with progress for long jobs.
4. Split very long recordings into parts for cloud engines and stitch the text back together.
5. Keep one result per engine on each recording, shown as tabs.
6. Ask another engine for a further opinion, including a text-only review by Claude.
7. Show speaker labels when a provider returns them.
8. Organise recordings in nested, colour-coded folders.
9. Search every title, folder path, and transcript.
10. Copy a transcript, copy it with a notes prompt for Claude, or export one or many recordings with their audio.
11. Configure engines, model names, API keys, and the notes prompt, with model lists loaded from each provider.

### 2.3 User characteristics

One user: the owner, a developer who records calls on a Mac and pastes transcripts into Claude. The user is comfortable with Homebrew and the command line and installs models once. There is no multi-user model, no sign-in, and no roles.

### 2.4 Constraints

See section 3.4 (CON).

### 2.5 Assumptions and dependencies

- Homebrew supplies `whisper-cpp`, so `whisper-cli` sits at `/opt/homebrew/bin/whisper-cli` or `/usr/local/bin/whisper-cli`.
- The ggml model files already exist in `~/Library/Application Support/Scribe/Models/`. The app doesn't download models.
- Models read by `whisper-cli` accept 16 kHz mono 16-bit WAV.
- You enter Gemini, ElevenLabs, and Anthropic API keys yourself. A model name is chosen from the provider's list or typed. The app doesn't validate either until a request is sent.
- Speed matters less than accuracy. Any local transcription can take as long as it needs.
- Recordings can exceed 90 minutes.
- The user allows the microphone, and for computer audio, Screen & System Audio Recording, in System Settings.
- Recordings and transcripts are private. Nothing leaves the Mac unless you choose a cloud engine.
- Provider limits for Gemini 3.5 Transcribe (1 hour per request, 30 minutes with diarization, up to 8 speakers, 85+ languages including Hindi and English India) come from the owner's reading of Google's documentation, not from a live request.

### 2.6 Operating environment

| Item | Requirement |
|---|---|
| Operating system | macOS 14.0 or later (`LSMinimumSystemVersion` 14.0) |
| Hardware | Apple Silicon (the build targets `arm64-apple-macos14.0`). Speeds in this SRS were measured on an M-series Mac with 16 GB of memory. |
| Tools | `whisper-cli` from Homebrew `whisper-cpp`; `/usr/bin/afconvert` (ships with macOS) |
| Models | ggml files in `~/Library/Application Support/Scribe/Models/` |
| Permissions | Microphone always. Screen & System Audio Recording only for computer audio. |
| Network | Not needed for Local. Needed for cloud engines, model lists (only once a key exists), and the setup scripts. |
| Window | Default 1180 by 760 points, minimum 940 by 660, position remembered, no menu bar icon |
| Appearance | Follows the system light or dark setting |
| Distribution | Built with `build.sh`, signed with the local certificate "Scribe Local Signing" when it exists and ad-hoc otherwise, installed to `/Applications` (or `~/Applications` if that isn't writable). Sideload only. |

## 3. Specific requirements

### 3.1 External interface requirements

#### 3.1.1 User interface

The UI is native SwiftUI in the Graphite design (`Sources/Theme.swift`, tokens from `docs/design/GRAPHITE.md`). A sidebar holds the library tree. The detail area shows the home screen (record or import), or the selected recording. A Settings sheet holds engines and keys. Colours follow the system light or dark setting. Inter and JetBrains Mono are bundled and registered at launch, with system fonts as the fallback (FR-APP-05). Interface requirements appear in the FR and NFR-USA groups.

#### 3.1.2 External interfaces

| ID | Interface | Contract | Status |
|---|---|---|---|
| EXT-01 | `whisper-cli` (whisper.cpp) | The app runs the configured executable with `-m <model> -f <wav> -l <lang> -bs 5 -mc 0 -sns --prompt <text> -otxt -of <base> -pp`. Exit status 0 means success. The transcript is read from `<base>.txt`. Output is streamed line by line so progress lines (`progress = N%` and segment timestamps) reach the progress model. The last 600 characters of non-progress output are kept for error messages. `<lang>` is `en` for English-only calls, otherwise the Settings speech mode (`en`, `hi`, or `auto`). The earlier run that verified this interface didn't use `-pp` or streaming, so it needs a re-run. | Built, untested |
| EXT-02 | `afconvert` | `/usr/bin/afconvert` converts any readable audio to (a) 16 kHz mono 16-bit WAV (`-f WAVE -d LEI16@16000 -c 1`) for Local and for chunking and (b) 16 kHz mono AAC at 32 kbps for uploads (`-f adts` for Gemini, `-f m4af` for ElevenLabs; `-d aac@16000 -b 32000 -c 1`). A non-zero exit becomes a plain-language error. | Verified |
| EXT-03 | ScreenCaptureKit | `SCShareableContent` picks the first display. `SCContentFilter` covers the display with no excluded applications. `SCStreamConfiguration` sets audio capture on, 48 kHz, 2 channels, current-process audio excluded, a 2 by 2 pixel video surface, and 1 frame per second. Audio sample buffers are converted to 48 kHz stereo float and scheduled on an `AVAudioPlayerNode`. Permission uses `CGPreflightScreenCaptureAccess` and `CGRequestScreenCaptureAccess`. | Built, untested |
| EXT-04 | AVFoundation | `AVAudioEngine` captures the microphone after `AVCaptureDevice.requestAccess(for: .audio)`. `AVAudioFile` writes AAC and reads durations. `AVAudioPlayer` plays back stored audio. | Built, untested |
| EXT-05 | Gemini REST API (generateContent) | `POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent` with header `x-goog-api-key`. The body has one text part (the prompt) and one audio part with MIME type `audio/aac`: inline base64 when the compressed part is 15,000,000 bytes or smaller, otherwise a `file_uri` from the Files API (`POST /upload/v1beta/files`, resumable, then `GET /v1beta/<name>` every 2 seconds, up to 150 times, until the state is `ACTIVE`). The transcript is the joined `text` parts of the first candidate. A `finishReason` of `MAX_TOKENS` appends a notice. Request timeout is 1,800 seconds. It serves every Gemini model except `gemini-3.5-transcribe`. | Built, untested |
| EXT-06 | ElevenLabs REST API | `POST https://api.elevenlabs.io/v1/speech-to-text`, multipart form, header `xi-api-key`. Fields: `model_id`, `language_code` (`eng`, only for English-only calls), `tag_audio_events` (`false`), `diarize` (`true` when speaker labels are on, which is the default), and `file` (`audio.m4a`, `audio/mp4`). The transcript is the response `text`, or one "Speaker N: text" line per turn built from `words[].speaker_id` when at least 2 speakers appear. Request timeout is 1,800 seconds. | Built, untested |
| EXT-07 | Anthropic REST API | `POST https://api.anthropic.com/v1/messages` with headers `x-api-key` and `anthropic-version: 2023-06-01`. One user message holds the review prompt and every existing transcript. `max_tokens` is 16,000. The transcript is the joined `text` blocks of the response. Request timeout is 900 seconds. No audio is ever sent. | Built, untested |
| EXT-08 | macOS Keychain | Generic password items, service `com.akshaybengani.scribe`, accounts `gemini`, `elevenlabs`, and `claude`. Writing an empty value deletes the item. | Built, untested |
| EXT-09 | macOS UI services | `NSOpenPanel` (audio files, model files), `NSSavePanel` (exports), `NSPasteboard` (copy), `NSWorkspace` (reveal in Finder), the main menu, a local key monitor for Space, and SwiftUI drag and drop with plain-string payloads `r:<recording id>` and `f:<folder id>`. | Built, untested |
| EXT-10 | Setup scripts (outside the app) | `setup/download-models.sh` and its siblings install `whisper-cpp` with Homebrew, download model files from Hugging Face, and convert Whisper fine-tunes to ggml with whisper.cpp's converter. They are the only network use outside the cloud engines and model lists. The app never runs them. | Verified |
| EXT-11 | Gemini Interactions API | Gemini 3.5 Transcribe (`gemini-3.5-transcribe`, but not a `-live` id) is called through the Interactions API. The part is uploaded through the Files API first, then `POST https://generativelanguage.googleapis.com/v1beta/interactions` with `x-goog-api-key`. The body names `models/<id>`, one `file` input with the file URI, and `generation_config.transcription_config` with `language_codes` (`en-IN` for English-only calls, auto-detect otherwise), a verbatim mode with speaker diarization when speaker labels are on, and `custom_vocabulary` (up to 100 terms from the names-and-terms field) only when diarization is off. A 400 retries once without diarization and tells the other parts to skip it, and a second 400 retries with an `audio` input block. The job fails unless the response status is `completed`. Limits per the owner's reading of Google's docs: 1 hour per request, 30 minutes with diarization, up to 8 speakers, 85+ languages including Hindi and English India. Timeout is 1,800 seconds. | Built, untested |
| EXT-12 | Provider list-models APIs | `GET https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000` with `x-goog-api-key`. `GET https://api.elevenlabs.io/v1/models` with `xi-api-key`. `GET https://api.anthropic.com/v1/models?limit=1000` with `x-api-key` and `anthropic-version: 2023-06-01`. Gemini and Anthropic paginate (up to 20 pages). Each call has a 30 second timeout. Retired Anthropic models are never requested. | Built, untested |

### 3.2 Functional requirements

#### 3.2.1 Recording (FR-REC)

| ID | Requirement | Status |
|---|---|---|
| FR-REC-01 | Scribe shall record the microphone from the home screen with one start control and one stop control. | Built, untested |
| FR-REC-02 | Before the first recording, Scribe shall request microphone access. If access is denied, Scribe shall not record and shall show a message naming System Settings > Privacy & Security > Microphone. | Built, untested |
| FR-REC-03 | Scribe shall write the recording as one 16 kHz mono AAC file at 48 kbps to `Recordings/<id>/audio.m4a`, during the recording and with no save step. | Verified |
| FR-REC-04 | Scribe shall offer a setting to also record computer audio (Teams, Meet, browser calls, everything the Mac plays) and shall remember it between launches. | Built, untested |
| FR-REC-05 | When computer audio is on, Scribe shall mix it with the microphone into the same single file. | Built, untested |
| FR-REC-06 | When computer audio is on and Screen & System Audio Recording access is missing, Scribe shall request it, shall not start recording, and shall tell you to allow Scribe in System Settings and then quit and reopen the app. | Built, untested |
| FR-REC-07 | If computer audio can't start after access is granted, Scribe shall keep recording the microphone only and shall say so. If computer audio stops during a recording, Scribe shall show the reason. | Built, untested |
| FR-REC-08 | Scribe shall never play the microphone back through the speakers, and shall exclude its own playback from computer audio. | Built, untested |
| FR-REC-09 | Scribe shall pause and resume a recording. Paused audio shall not be written, and the elapsed time shall count only written audio. | Built, untested |
| FR-REC-10 | While recording, Scribe shall show the elapsed time and one level waveform per active source (microphone, and computer audio when on), updated about every 0.05 seconds, with the most recent 600 samples kept. | Built, untested |
| FR-REC-11 | Scribe shall let you pick the call language (Hindi + English, or English only) before recording and shall disable the choice while a recording runs. | Built, untested |
| FR-REC-12 | On stop, Scribe shall create a recording titled "Recording" followed by the local date and time, with the recorded duration, the chosen call language, and the currently selected folder. It shall select the new recording and start transcription with the chosen engine. | Built, untested |
| FR-REC-13 | If recording can't start, Scribe shall delete the empty recording folder it created and shall show the reason. | Built, untested |
| FR-REC-14 | Scribe shall record without a length cap, so a recording can exceed 90 minutes. | Built, untested |

#### 3.2.2 Import (FR-IMP)

| ID | Requirement | Status |
|---|---|---|
| FR-IMP-01 | Scribe shall import one audio file at a time, chosen in a file panel limited to audio types. | Built, untested |
| FR-IMP-02 | Scribe shall copy the file into the library as `audio.<extension>` and leave the original untouched. A file with no extension is stored as `audio.m4a`. | Built, untested |
| FR-IMP-03 | Scribe shall title the recording with the file name (without extension) and read its duration. If the duration can't be read, it shall store 0. | Built, untested |
| FR-IMP-04 | Scribe shall store the call language and selected folder chosen on the home screen, select the new recording, and start transcription with the chosen engine. | Built, untested |
| FR-IMP-05 | If the copy fails, Scribe shall show "Could not import that file" and the system's reason. | Built, untested |
| FR-IMP-06 | If a file imports but `afconvert` can't read it, the transcription shall fail with "Could not read this audio file" and no result shall be stored. | Built, untested |

#### 3.2.3 Transcription (FR-TRN)

| ID | Requirement | Status |
|---|---|---|
| FR-TRN-01 | Scribe shall let you choose the engine for new recordings among Local, Gemini, and ElevenLabs, shall remember the choice, and shall default to Local. Claude shall not appear in that list. | Built, untested |
| FR-TRN-02 | The home screen shall show whether the chosen engine is ready, and shall give the reason when it isn't. | Built, untested |
| FR-TRN-03 | Local transcription shall convert the audio to 16 kHz mono WAV, run `whisper-cli` with beam size 5, no context carry-over between segments, non-speech tokens suppressed, no voice activity detection, and progress output on, and shall remove temporary files afterwards. | Built, untested |
| FR-TRN-04 | For Hindi + English calls, Local shall use the Hinglish model file (default Oriserve Whisper-Hindi2Hinglish converted to ggml, `ggml-oriserve-f16.bin`), the speech mode from Settings (default English mode), and a Roman-script Hinglish prompt. | Built, untested |
| FR-TRN-05 | For English-only calls, Local shall use the separate English model file (default Whisper large-v3-turbo, 5-bit, `ggml-large-v3-turbo-q5_0.bin`), language `en`, and an English prompt. The earlier 30 second English check used large-v3 at full precision. | Built, untested |
| FR-TRN-06 | Scribe shall append your names-and-terms hint to the Local prompt and to every cloud prompt. | Built, untested |
| FR-TRN-07 | Gemini transcription shall compress the audio to ADTS AAC, send each part inline (generateContent models, 15,000,000 bytes or smaller) or through the Files API, use the model name you chose (default `gemini-3.5-transcribe`, which goes through the Interactions API, EXT-11), and follow the output style setting (Roman or Devanagari) on the generateContent path. | Built, untested |
| FR-TRN-08 | If Gemini stops at its output limit, Scribe shall append a notice that the end of the transcript is missing. | Built, untested |
| FR-TRN-09 | ElevenLabs transcription shall upload compressed M4A with audio-event tags off, diarization on while speaker labels are on, and language set to English only for English-only calls. The default model is `scribe_v2`. | Built, untested |
| FR-TRN-10 | Scribe shall clean every transcript before storing it by dropping blank lines and consecutive duplicate lines (the repeat loops Whisper sometimes makes). | Verified |
| FR-TRN-11 | Transcription shall run in the background. The window shall stay usable, and the recording shall show that it is working (see FR-PRG). | Built, untested |
| FR-TRN-12 | Scribe shall allow one running job per recording and engine, and shall allow jobs for different engines on the same recording at the same time. | Built, untested |
| FR-TRN-13 | On completion, Scribe shall store a result with the engine, model name, text, elapsed seconds, and date in the recording's `meta.json`. | Built, untested |
| FR-TRN-14 | A recording with no result shall offer "Transcribe with" the chosen engine. | Built, untested |
| FR-TRN-15 | Local transcription shall have no time limit. Cloud requests shall time out after 1,800 seconds (Gemini, ElevenLabs) or 900 seconds (Claude). | Built, untested |
| FR-TRN-16 | Scribe shall check readiness before any job starts and shall report a missing `whisper-cli`, a missing model file, a blank API key, or a blank model name as an error on the recording. | Built, untested |
| FR-TRN-17 | For Gemini and ElevenLabs, a recording longer than 60 minutes (29 minutes for Gemini 3.5 Transcribe with speaker labels, FR-TRN-20) shall be converted to WAV, split into parts of about 25 minutes, and each part sent as its own request. Each cut shall fall at the quietest 0.4 second stretch within 90 seconds either side of the target, and the last part shall be at least 60 seconds. | Built, untested |
| FR-TRN-18 | Scribe shall let you cancel a running job. | Planned |
| FR-TRN-19 | Gemini 3.5 Transcribe shall be called through the Interactions API (EXT-11), and an id ending `-live` shall be refused with a message to choose `gemini-3.5-transcribe`. | Built, untested |
| FR-TRN-20 | When Gemini 3.5 Transcribe runs with speaker labels, a recording longer than 29 minutes shall be chunked into parts of about 25 minutes, so no request reaches the 30 minute diarization limit. The job shall note that speaker numbers may not match between parts. | Built, untested |
| FR-TRN-21 | Each part after the first shall be sent with the last 4 lines (at most 600 characters) of the previous part as context, and the parts shall be stitched in order into one cleaned transcript. | Built, untested |
| FR-TRN-22 | A part that fails with a transient error (timeout, dropped connection, HTTP 429 or 5xx) shall be retried up to 3 attempts in all, waiting 6 then 12 seconds. A part that still fails shall fail the job with "Part x of y failed" and the reason. | Built, untested |
| FR-TRN-23 | Local transcription shall split very long recordings. Today Local sends the whole recording to `whisper-cli`. | Planned |

#### 3.2.4 Progress (FR-PRG)

| ID | Requirement | Status |
|---|---|---|
| FR-PRG-01 | Scribe shall track a running job's stage: Preparing audio, Transcribing, Uploading, Waiting for provider, or Merging parts. | Built, untested |
| FR-PRG-02 | For Local, Scribe shall read `whisper-cli` progress output (percent lines and segment timestamps) and derive the fraction of audio done, the speed as a multiple of real time, and the estimated time remaining. The fraction shall never go backwards. | Built, untested |
| FR-PRG-03 | For a chunked cloud job, Scribe shall report "Part x of y", the fraction by audio completed, and a remaining-time estimate from the rate of the parts already finished. | Built, untested |
| FR-PRG-04 | For an upload, Scribe shall report bytes sent of bytes total, then switch to Waiting for provider. While a single request waits on the provider, Scribe shall show no percentage. | Built, untested |
| FR-PRG-05 | Elapsed time and the countdown shall refresh about once a second. | Built, untested |
| FR-PRG-06 | The recording screen shall show the stage, percent, a progress bar, "about x left" (or "estimating time left"), elapsed time, chunk x of y, audio length, speed, and upload bytes, with a sweeping bar when no fraction is known. | Built, untested |

#### 3.2.5 Speaker labels (FR-SPK)

| ID | Requirement | Status |
|---|---|---|
| FR-SPK-01 | Scribe shall show speaker labels only when a provider returns them, and shall add nothing extra otherwise. | Built, untested |
| FR-SPK-02 | When ElevenLabs returns at least 2 distinct speakers, the transcript shall have one "Speaker N: text" line per turn, numbered in order of first appearance, with consecutive words by one speaker merged. Otherwise it shall be the plain text. | Built, untested |
| FR-SPK-03 | Gemini 3.5 Transcribe shall return diarized transcripts (up to 8 speakers), as "Speaker N: text" lines. | Built, untested |
| FR-SPK-04 | Settings shall offer a speaker labels switch. The setting (`speakerLabels`, default on) exists, but no control does. | Planned |
| FR-SPK-05 | Local and Claude shall add no speaker labels. | Built, untested |
| FR-SPK-06 | The transcript view shall show speaker blocks only when the text has 2 or more speakers, and nothing extra otherwise. | Built, untested |
| FR-SPK-07 | The model picker shall mark models that label speakers, with their limit in minutes, and shall warn when a recording is longer than that limit. | Built, untested |

#### 3.2.6 Models (FR-MDL)

| ID | Requirement | Status |
|---|---|---|
| FR-MDL-01 | Once a provider's API key exists, Scribe shall load that provider's model list (EXT-12). | Built, untested |
| FR-MDL-02 | Scribe shall merge the list with curated names, remove duplicates, and sort audio-capable models first, then pinned picks, then newest. A name you typed that no list knows shall stay in the options. | Built, untested |
| FR-MDL-03 | Audio support shall be set by the provider where known: ElevenLabs ids starting `scribe` (not realtime or live), Gemini by a name heuristic (the API has no modality field), and Claude never. | Built, untested |
| FR-MDL-04 | Scribe shall cache each list with its fetch time, and shall refresh a list when its key changes, after the typing pauses for 900 ms. A failed refresh shall keep the previous list and show the reason, with a rejected key named as such. | Built, untested |
| FR-MDL-05 | Scribe shall refresh any list older than 24 hours. The function exists, but nothing calls it yet. | Planned |
| FR-MDL-06 | A Refresh models button shall sit beside the model picker, show loading and error state, and be disabled until a key exists. | Built, untested |
| FR-MDL-07 | A picker shall show each provider's models, audio models first, with notes and a speaker labels chip, and shall warn when the chosen Gemini or ElevenLabs model doesn't take audio. It sits on the record screen. The Settings sheet still shows a plain text field for the model name. | Built, untested |
| FR-MDL-08 | Fresh installs shall default to `gemini-3.5-transcribe`, `scribe_v2`, and `claude-sonnet-5-5`. A stored `gemini-2.5-flash` or `scribe_v1` that matches an earlier default shall move to the new default once. | Built, untested |

#### 3.2.7 Folders and library (FR-FLD)

| ID | Requirement | Status |
|---|---|---|
| FR-FLD-01 | Scribe shall create folders at the top level or inside any folder, to any depth, each with a name and one of nine colours: red, orange, yellow, green, teal, blue, purple, pink, gray. | Verified |
| FR-FLD-02 | Scribe shall rename and recolour a folder. A blank name shall not save. | Built, untested |
| FR-FLD-03 | Scribe shall ask for confirmation before deleting a folder. Deleting a folder shall move its subfolders and recordings up one level and shall never delete audio. | Verified |
| FR-FLD-04 | Scribe shall move a folder by menu, and shall refuse to move a folder into itself or one of its own subfolders. | Verified |
| FR-FLD-05 | Scribe shall move a recording by menu to any folder or to the top level. | Verified |
| FR-FLD-06 | Scribe shall move recordings and folders by drag and drop onto a folder, or onto the empty list area for the top level. | Built, untested |
| FR-FLD-07 | Each folder shall show the number of recordings inside it, including its subfolders. | Verified |
| FR-FLD-08 | A folder's display path shall read "Parent / Child", and the top level shall read "Library". | Verified |
| FR-FLD-09 | The selected folder shall be where new recordings and imports go, and the home screen shall show where. | Built, untested |
| FR-FLD-10 | The tree shall list folders first, sorted by name ignoring case, then recordings, newest first. Each recording row shall show title, date, duration, and result count. | Built, untested |
| FR-FLD-11 | Scribe shall store folders in `folders.json` and each recording in its own `meta.json`, with atomic writes. | Built, untested |
| FR-FLD-12 | Scribe shall let you rename a recording in place from its detail screen. | Built, untested |
| FR-FLD-13 | Deleting a recording shall remove its audio and its transcripts together from disk, and shall not offer a backup. | Built, untested |
| FR-FLD-14 | Scribe shall ask for confirmation before deleting a recording, saying it can't be undone. | Built, untested |

#### 3.2.8 Search (FR-SCH)

| ID | Requirement | Status |
|---|---|---|
| FR-SCH-01 | Scribe shall index every recording's title, folder path, and every transcript tab, and keep the index in step with the library without a manual refresh. | Built, untested |
| FR-SCH-02 | Matching shall ignore case, diacritics, and punctuation, and shall match substrings, so "meet" finds "meeting". Several words shall all be required. A quoted phrase shall match exactly. Hindi in Devanagari, Roman Hinglish, and English shall behave alike. | Built, untested |
| FR-SCH-03 | Search shall not transliterate: a Roman query shall not find Devanagari text, or the reverse. | Built, untested |
| FR-SCH-04 | Results shall rank a title match above a whole-phrase match above a term match, show a one-line snippet with the matches marked, the folder path, and every tab that matches, and return at most 100 hits after an 80 ms pause in typing. | Built, untested |
| FR-SCH-05 | A search bar shall sit in the title bar area like a browser address field, with a results panel under it that also lists folders whose name matches. | Built, untested |
| FR-SCH-06 | Cmd+K shall focus the search bar. Up and Down shall move through results, Return shall open one, and Esc shall clear and close. | Built, untested |
| FR-SCH-07 | Choosing a transcript hit shall open the recording on the matching tab with the find bar on the query. | Built, untested |
| FR-SCH-08 | The recording screen shall have a find bar that finds a query inside the shown transcript. | Built, untested |

#### 3.2.9 Playback (FR-PLY)

| ID | Requirement | Status |
|---|---|---|
| FR-PLY-01 | The detail screen shall play, pause, and stop the stored audio and show current time and total length. | Built, untested |
| FR-PLY-02 | The detail screen shall provide a slider to seek to any point. | Built, untested |

#### 3.2.10 Opinions (FR-OPN)

| ID | Requirement | Status |
|---|---|---|
| FR-OPN-01 | The detail screen shall offer "Get another opinion" listing Local, Gemini, ElevenLabs, and Claude. Cloud engines shall be marked, Claude shall be marked as reading text only, and an engine that already has a result shall read "run again". | Built, untested |
| FR-OPN-02 | Scribe shall keep one result per engine on a recording and show each as a tab. Running an engine again shall replace that engine's result. | Built, untested |
| FR-OPN-03 | A tab shall show the engine name and a cloud icon for cloud engines. Its tooltip shall show the model name and elapsed seconds. | Built, untested |
| FR-OPN-04 | Claude shall be unavailable until the recording has at least one result. | Built, untested |
| FR-OPN-05 | Claude shall receive every existing result, labelled by engine and model, and shall return one reviewed transcript. Claude shall never receive audio and shall never be offered as the first transcription step. | Built, untested |
| FR-OPN-06 | Before a cloud engine is started from the detail screen, Scribe shall show a confirmation that names the company and says whether audio or transcript text will be sent. | Built, untested |
| FR-OPN-07 | Scribe shall show a side-by-side compare view of the results for one recording. | Planned |

#### 3.2.11 Cloud disclosure (FR-CLD)

| ID | Requirement | Status |
|---|---|---|
| FR-CLD-01 | While a cloud engine is chosen as the default, or a cloud job is running, Scribe shall show a persistent banner naming each provider and saying whether audio or transcript text goes to a third-party platform. | Built, untested |
| FR-CLD-02 | The home screen shall state whether the chosen engine keeps audio on this Mac. | Built, untested |
| FR-CLD-03 | Every cloud send shall ask for confirmation, including the automatic send after a recording or import when a cloud engine is the default. | Planned |

#### 3.2.12 Settings (FR-SET)

| ID | Requirement | Status |
|---|---|---|
| FR-SET-01 | A Settings sheet shall list every engine with a "Ready" or "Needs attention" badge, and the reason on hover. | Built, untested |
| FR-SET-02 | Local settings shall hold the `whisper-cli` path (auto-detected at `/opt/homebrew/bin` then `/usr/local/bin`), the Hinglish model path, the English model path, a file chooser for each model, and a speech mode: English mode (default), Hindi mode, or auto-detect. | Built, untested |
| FR-SET-03 | Each cloud engine shall have a masked API key field and a model name field. | Built, untested |
| FR-SET-04 | A names-and-terms field shall feed FR-TRN-06. | Built, untested |
| FR-SET-05 | An output style setting shall choose Roman script Hinglish or Devanagari Hindi with Latin English for Gemini. | Built, untested |
| FR-SET-06 | An editable "Copy for Claude" prompt shall be prepended to the transcript, with a reset to the default. | Built, untested |
| FR-SET-07 | A storage section shall show the library path and reveal it in Finder. | Built, untested |
| FR-SET-08 | Scribe shall persist non-secret settings in `UserDefaults` and the window frame between launches. | Built, untested |
| FR-SET-09 | Scribe shall apply the Graphite design system to every screen and follow the system light or dark setting, with no forced appearance. | Built, untested |

#### 3.2.13 Export (FR-EXP)

| ID | Requirement | Status |
|---|---|---|
| FR-EXP-01 | "Copy transcript" shall put the shown tab's text on the clipboard. | Built, untested |
| FR-EXP-02 | "Copy for Claude" shall put the notes prompt followed by the shown tab's text on the clipboard. | Built, untested |
| FR-EXP-03 | "Export transcript" (Cmd+E) shall save the shown tab as a plain text file named "Title (Tab).txt". | Built, untested |
| FR-EXP-04 | "Export audio" shall save a copy of the stored audio, keeping its extension. | Built, untested |
| FR-EXP-05 | A button shall reveal the stored audio file in Finder. | Built, untested |
| FR-EXP-06 | Transcript text shall be selectable on screen. | Built, untested |
| FR-EXP-07 | The "Copy for Claude" prompt shall match the call language of the recording. | Planned |
| FR-EXP-08 | An export engine shall write selected recordings to a chosen folder: the preferred engine's tab (falling back to another and noting it), one file per tab, or one combined file per recording; optional audio; one flat folder or the library's folder tree; plain text or Markdown; and an option for one document holding every recording. It shall never overwrite an existing file, shall report errors and warnings per recording, and shall be cancellable. | Built, untested |
| FR-EXP-09 | An export dialog shall write everything for each selected recording into its own folder, named by title and date, never overwriting: the audio, one text file per transcript, one combined Markdown file, and `metadata.json`. The dialog and its writer exist. | Built, untested |
| FR-EXP-10 | `metadata.json` shall hold the recording's id, title, created date, duration in seconds, language, folder path, audio file name, each transcript's file, engine, model, seconds, and date, and the export time. | Built, untested |
| FR-EXP-11 | Selecting several recordings in the library shall open the export dialog. Nothing opens it from a selection yet. | Planned |

#### 3.2.14 Appearance, shortcuts, and branding (FR-APP)

| ID | Requirement | Status |
|---|---|---|
| FR-APP-01 | Space shall play and pause the open recording, unless a text field is being edited or a dialog or search is open. | Built, untested |
| FR-APP-02 | The main menu shall provide Cmd+N (new recording), Cmd+Shift+N (new folder), Cmd+, (Settings), Cmd+E (export transcript), and Cmd+K (search). Cmd+R shall start and stop recording on the home screen. | Built, untested |
| FR-APP-03 | Scribe shall add no menu bar icon. | Built, untested |
| FR-APP-04 | The Caret wave logo shall be the app icon (`AppIcon.icns`) and appear in the app. | Built, untested |
| FR-APP-05 | Inter and JetBrains Mono shall be bundled under the SIL Open Font License: `build.sh` copies them into `Contents/Resources/Fonts` and the app registers them at launch, with system fonts as the fallback. | Built, untested |
| FR-APP-06 | `build.sh` shall sign with the stable local certificate "Scribe Local Signing" when it exists, so macOS keeps the microphone and screen recording grants across rebuilds, and fall back to ad-hoc signing otherwise. | Built, untested |

#### 3.2.15 Errors (FR-ERR)

| ID | Requirement | Status |
|---|---|---|
| FR-ERR-01 | A failed or blocked job shall show an error row on its recording naming the engine and the reason, with a Dismiss button and, when the cause is a setting, a Settings button. | Built, untested |
| FR-ERR-02 | A `whisper-cli` failure shall include the last 600 characters of its output. A cloud HTTP failure shall name the service, the status code, and the first 400 characters of the response. | Built, untested |
| FR-ERR-03 | A failure in one engine shall not remove or change results from other engines. | Built, untested |
| FR-ERR-04 | Starting a job again shall clear that engine's earlier error. | Built, untested |
| FR-ERR-05 | Permission and recording problems shall show as messages on the home screen. | Built, untested |
| FR-ERR-06 | A failed save, export, or write shall tell you. | Planned |

### 3.3 Non-functional requirements

#### 3.3.1 Privacy (NFR-PRV)

| ID | Requirement | Status |
|---|---|---|
| NFR-PRV-01 | With Local chosen and no API key entered, Scribe shall make no network connection while recording, importing, transcribing, searching, or exporting. | Built, untested |
| NFR-PRV-02 | Scribe shall have no accounts, no backend, no analytics, and no telemetry. | Built, untested |
| NFR-PRV-03 | Audio and transcripts shall be stored only on this Mac, under `~/Library/Application Support/Scribe/`. They are not encrypted and not backed up by Scribe. Export is the way to copy them out. | Built, untested |
| NFR-PRV-04 | Audio shall be sent to a third party only to Gemini or ElevenLabs, and only after you chose that engine. Transcript text shall be sent only to Anthropic, and only for a Claude review. | Built, untested |
| NFR-PRV-05 | Nothing shall leave the Mac without a visible warning (FR-CLD-01) and a per-send confirmation (FR-CLD-03). | Planned |
| NFR-PRV-06 | Temporary conversion and chunk files shall be deleted when a job ends, whether it passes or fails. | Built, untested |
| NFR-PRV-07 | The app shall hold no model downloader. Model downloads shall happen only in the setup scripts. | Verified |
| NFR-PRV-08 | The microphone usage description shall state that Scribe records your voice so it can be transcribed. | Built, untested |
| NFR-PRV-09 | Model list requests shall go only to the provider's own host, only after that provider's key exists, with the key in a header. | Built, untested |

#### 3.3.2 Performance (NFR-PRF)

| ID | Requirement | Status |
|---|---|---|
| NFR-PRF-01 | Accuracy comes before speed. Local transcription shall use beam size 5 and no voice activity detection, even though that costs time. | Verified |
| NFR-PRF-02 | With the default Hinglish model on an M-series Mac with 16 GB of memory, Local transcription ran at about 4 times real time: 2.5 minutes for 10 minutes 54 seconds of audio. | Verified |
| NFR-PRF-03 | A 90 minute recording shall finish Local transcription without failing. By the measured ratio in NFR-PRF-02 it projects to about 22.5 minutes. That figure is arithmetic, not a measurement, and memory use beyond 10 minutes 54 seconds is not known. | Planned |
| NFR-PRF-04 | Recording, playback, searching, and browsing the library shall stay responsive while a transcription runs. | Built, untested |
| NFR-PRF-05 | Stored audio shall be small speech-quality AAC: 48 kbps at 16 kHz mono, which is about 21.6 MB per hour by calculation. Upload copies shall be 32 kbps, which the code comment puts at about 14 MB per hour. | Verified |
| NFR-PRF-06 | The English-only default (large-v3-turbo, 5-bit) shall be backed by measured accuracy and speed on an English call. The pick comes from the English comparison, and its numbers aren't in these documents yet. | Planned |
| NFR-PRF-07 | A search shall return within the 80 ms pause plus the time to scan the index, off the main thread. No timing has been taken. | Planned |

#### 3.3.3 Reliability (NFR-REL)

| ID | Requirement | Status |
|---|---|---|
| NFR-REL-01 | Audio shall be on disk before transcription starts, so a failed transcription never loses the recording. | Built, untested |
| NFR-REL-02 | `meta.json` and `folders.json` shall be written atomically. | Built, untested |
| NFR-REL-03 | Recordings saved before the language and folder options existed shall still load: both fields are optional, and a missing language reads as Hindi + English. | Built, untested |
| NFR-REL-04 | Deleting a folder shall never delete audio. | Verified |
| NFR-REL-05 | A recording interrupted by a crash or power loss shall be recoverable, with its audio playable. | Planned |
| NFR-REL-06 | A running transcription shall survive quitting the app, or resume on relaunch. | Planned |
| NFR-REL-07 | A failed model list refresh shall leave the previous list and the typed model name usable. | Built, untested |

#### 3.3.4 Usability (NFR-USA)

| ID | Requirement | Status |
|---|---|---|
| NFR-USA-01 | A call shall go from record to transcript on screen with one start action and one stop action, with no save dialog. | Built, untested |
| NFR-USA-02 | Error and status text shall use plain language and name the fix (for example, "brew install whisper-cpp"). | Built, untested |
| NFR-USA-03 | The main screens shall render in light mode at the minimum window size. The earlier UI snapshots predate the Graphite redesign. | Built, untested |
| NFR-USA-04 | The main screens shall render in dark mode. | Built, untested |
| NFR-USA-05 | The app shall provide Quit, Hide, Minimize, Close, and standard text-editing shortcuts, plus those in FR-APP-02. | Built, untested |
| NFR-USA-06 | The app shall quit when its last window closes, and reopen its window when you click the Dock icon. | Built, untested |

#### 3.3.5 Accessibility (NFR-ACC)

| ID | Requirement | Status |
|---|---|---|
| NFR-ACC-01 | The waveform shall have an accessibility label, the cloud banner shall read as one element, and each folder colour button shall have a name. | Built, untested |
| NFR-ACC-02 | Status shall never rely on colour alone: warnings and readiness shall pair colour with an icon or text. | Built, untested |
| NFR-ACC-03 | Every icon-only control shall have an accessibility label, not only a tooltip. Several do (record, play, pause, delete), and the rest haven't been audited. | Planned |
| NFR-ACC-04 | Graphite focus rings (2 px, 2 px offset) and contrast tokens shall be applied. The tokens are in the code, and the rings haven't been checked. | Planned |
| NFR-ACC-05 | A full VoiceOver and keyboard-only pass shall be run. | Planned |

#### 3.3.6 Security of keys (NFR-SEC)

| ID | Requirement | Status |
|---|---|---|
| NFR-SEC-01 | API keys shall live only in the macOS Keychain, never in `UserDefaults`, `meta.json`, logs, or exports. The model list cache holds model names only. | Built, untested |
| NFR-SEC-02 | The settings field for a key shall be masked. | Built, untested |
| NFR-SEC-03 | A key shall be sent only in the header of requests to its own provider, over HTTPS, never in a URL. | Built, untested |
| NFR-SEC-04 | Clearing a key field shall delete its Keychain item. | Built, untested |
| NFR-SEC-05 | A failed Keychain write shall tell you. | Planned |

### 3.4 Design constraints (CON)

| ID | Constraint |
|---|---|
| CON-01 | Personal use, sideload only. No App Store, no distribution to other people. |
| CON-02 | macOS 14 or later on Apple Silicon. Mac only for now. Windows is later. |
| CON-03 | Built with plain `swiftc` through `build.sh`. No Xcode project and no third-party Swift packages. |
| CON-04 | Bundle identifier `com.akshaybengani.scribe`, version 0.1. Signed with the local certificate "Scribe Local Signing" when present, ad-hoc otherwise. The private key is never exported or committed. |
| CON-05 | No backend, accounts, or telemetry. |
| CON-06 | Homebrew supplies `whisper-cpp`. The app calls `whisper-cli` as a child process. |
| CON-07 | Notes are written outside the app. Scribe produces text, not notes. |
| CON-08 | Writing in the app and its docs follows the owner's writing standards. |
| CON-09 | No encryption at rest and no backup feature. Export is the way out. |
| CON-10 | Claude is used for text review only, never for audio. |
| CON-11 | Inter and JetBrains Mono are the UI fonts, bundled under the SIL OFL (FR-APP-05). |

## 4. Data model

Everything is JSON on disk, written with ISO 8601 dates, pretty printing, and sorted keys. Non-secret settings use `UserDefaults`. Secrets use the Keychain. The recording and folder shapes didn't change in this update.

### 4.1 Storage layout

```
~/Library/Application Support/Scribe/
  Models/                       ggml model files (placed by the setup scripts)
  Recordings/
    folders.json                the folder list
    <recording id>/
      audio.m4a                 or audio.<ext> for an import
      meta.json                 one Recording
```

Ids are `UUID().uuidString`. A recording appears in the library only if its folder holds a readable `meta.json`.

### 4.2 Types

| Type | Fields | Notes |
|---|---|---|
| `ProviderKind` | `local`, `gemini`, `elevenlabs`, `claude` | Claude can't hear audio (`hearsAudio` is false). Everything but `local` is a cloud engine. |
| `CallLanguage` | `mixed`, `english` | `mixed` is shown as "Hindi + English". |
| `FolderColor` | `red`, `orange`, `yellow`, `green`, `teal`, `blue`, `purple`, `pink`, `gray` | Nine values. |
| `Folder` | `id`, `name`, `color`, `parentID` (optional), `created` | A nil `parentID` is the top level. Depth is unlimited. |
| `TranscriptResult` | `id` (UUID), `provider`, `modelName`, `text`, `seconds`, `date` | `modelName` for Local is the model file name without its extension. A transcript with speaker labels holds "Speaker N: text" lines in `text`. |
| `Recording` | `id`, `title`, `created`, `duration`, `audioFile`, `results`, `language` (optional), `folderID` (optional) | A nil `language` reads as `mixed`. A nil `folderID` is the top level. |
| `ModelInfo` (cached) | `id`, `displayName`, `supportsAudio`, `note`, `released` (optional) | Held in `UserDefaults`, not in the library. |
| `JobProgress` (in memory) | `stage`, `fraction`, `stageFraction`, `elapsed`, `audioSeconds`, `remaining`, `speed`, `bytesSent`, `bytesTotal`, `part`, `parts` | Exists only while a job runs. Never stored. |

### 4.3 `meta.json`

The values are illustrative.

```json
{
  "audioFile" : "audio.m4a",
  "created" : "2026-11-17T09:30:00Z",
  "duration" : 654.2,
  "folderID" : "5C0F3A52-0000-0000-0000-000000000001",
  "id" : "8D2E7B11-0000-0000-0000-000000000002",
  "language" : "mixed",
  "results" : [
    {
      "date" : "2026-11-17T09:43:10Z",
      "id" : "A1B2C3D4-0000-0000-0000-000000000003",
      "modelName" : "ggml-oriserve-f16",
      "provider" : "local",
      "seconds" : 156,
      "text" : "Aaj ka update, the build is green."
    }
  ],
  "title" : "Recording 17 Nov 2026 at 09:30"
}
```

### 4.4 `folders.json`

```json
[
  {
    "color" : "teal",
    "created" : "2026-11-17T09:00:00Z",
    "id" : "5C0F3A52-0000-0000-0000-000000000001",
    "name" : "Daily standups"
  },
  {
    "color" : "blue",
    "created" : "2026-11-17T09:01:00Z",
    "id" : "5C0F3A52-0000-0000-0000-000000000004",
    "name" : "Platform team",
    "parentID" : "5C0F3A52-0000-0000-0000-000000000001"
  }
]
```

### 4.5 Settings in `UserDefaults`

| Key | Default |
|---|---|
| `primary` | `local` |
| `captureSystemAudio` | off |
| `callLanguage` | `mixed` |
| `whisperPath` | `/opt/homebrew/bin/whisper-cli`, or `/usr/local/bin/whisper-cli` if that is the one present |
| `localModelPath` | `~/Library/Application Support/Scribe/Models/ggml-oriserve-f16.bin` |
| `englishModelPath` | `~/Library/Application Support/Scribe/Models/ggml-large-v3-turbo-q5_0.bin` |
| `language` | `en` (speech mode for the Hinglish model; also `hi`, `auto`) |
| `hint` | empty |
| `style` | `roman` (also `devanagari`) |
| `template` | the default "Copy for Claude" prompt |
| `geminiModel` | `gemini-3.5-transcribe` |
| `elevenModel` | `scribe_v2` |
| `claudeModel` | `claude-sonnet-5-5` |
| `speakerLabels` | on |
| `modelCache.<provider>` | none until a list is fetched (models and fetch time as JSON) |

Keychain accounts: `gemini`, `elevenlabs`, `claude`.

## 5. State and error handling

### 5.1 Recording states

| State | Entered by | Leaves to |
|---|---|---|
| Idle | Launch, or after saving | Recording |
| Recording | Start, once permission and the audio engine succeed | Paused, Saved |
| Paused | Pause | Recording |
| Saved | Stop: the file is closed, the library entry is created, transcription starts | Idle |
| Start failed | Denied permission, no input device, or an engine error | Idle (the empty folder is removed) |

### 5.2 Job states

A job is keyed by recording and engine.

| State | Meaning |
|---|---|
| Not ready | A readiness check failed. An error row shows the reason. No job starts. |
| Running | The job holds a start time and a progress snapshot (FR-PRG). Chunked cloud jobs move through the parts in order. |
| Done | A result replaces any earlier result for that engine. The job and its progress clear. |
| Failed | An error row shows the message. Earlier results are kept. The job and its progress clear. |

Jobs live in memory. Quitting the app ends them (KG-02).

### 5.3 Errors

| Situation | Handling |
|---|---|
| Microphone denied | Home screen message with the System Settings path. No recording. |
| Screen recording denied | Home screen message. No recording. Quit and reopen after allowing. |
| Computer audio fails to start | Recording continues with the microphone only. A message says so. |
| Computer audio stops mid-recording | A message with the system's reason. |
| No input device | "No microphone input is available." |
| `whisper-cli` missing, model file missing | Readiness error with the path and, for `whisper-cli`, `brew install whisper-cpp`. |
| Blank key or model name | "No <engine> API key yet. Add it in AI Models." or the model name equivalent. |
| `afconvert` fails | "Could not read this audio file" or "Could not compress this audio file", plus the tool output. |
| `whisper-cli` exits non-zero or writes no text | "whisper-cli failed" with the last 600 characters, or "whisper-cli produced no transcript." |
| Cloud HTTP error | "<Service> returned <status>: <first 400 characters>". A part of a long job retries on 429, 5xx, timeouts, and dropped connections, then fails with "Part x of y failed". |
| Cloud response without text | "<Service> returned no transcript." |
| Gemini output limit | Transcript stored with an end-missing notice. |
| Gemini file processing never finishes | After 150 polls: "Gemini could not process the audio file." |
| Claude called with no results | "Claude needs at least one existing transcript to review." |
| Import copy fails | "Could not import that file" plus the reason. |
| Model list refresh fails | The previous list stays. A message says the provider rejected the key (HTTP 401 or 403), returned another status, or sent a list Scribe couldn't read. |
| Export item fails | The export carries on. The result lists each recording's errors and warnings and a summary such as "Exported 4 of 5 recordings. 1 failed." |

Errors are held in memory per recording and engine. They clear on the next start or on Dismiss.

## 6. Traceability and verification status

### 6.1 Requirement to source

| Requirements | Source | Verification basis |
|---|---|---|
| FR-REC-01 to FR-REC-14 | `Sources/Audio.swift` (`Recorder`, `AACWriter`, `SystemAudioCapture`, `Meter`, `WaveformView`); `Sources/RecordViews.swift` (`RecordView`) | `AACWriter` and conversion checked on synthetic audio. No live microphone or system audio run. |
| FR-IMP-01 to FR-IMP-06 | `Sources/Model.swift` (`importAudio`); `Sources/RecordViews.swift` (`ImportView`) | Not exercised through the file panel |
| FR-TRN-01, FR-TRN-02 | `Sources/RecordViews.swift` (`ModelChooser`); `Sources/Settings.swift` (`primary`, `issue`) | Not exercised since the redesign |
| FR-TRN-03 to FR-TRN-05, EXT-01 | `Sources/Providers.swift` (`LocalTranscriber`, `Shell.runStreaming`) | Pipeline run end to end on a real clip, and the English path on a 30 second slice, before `-pp` and the new English default |
| FR-TRN-10, EXT-02 | `Sources/Providers.swift` (`tidy`, `AudioPrep`) | Run on a real clip and synthetic audio |
| FR-TRN-06 to FR-TRN-09 | `Sources/Providers.swift` (`Prompts`, `GeminiTranscriber`, `ElevenLabsTranscriber`) | No key in the build session, so no request sent |
| FR-TRN-11 to FR-TRN-16 | `Sources/Providers.swift` (`JobRunner`, `Engine`); `Sources/Settings.swift`; `Sources/Model.swift` | Not exercised through the app UI |
| FR-TRN-17, FR-TRN-20 to FR-TRN-22 | `Sources/Chunker.swift`; `Sources/Providers.swift` (`CloudRunner`, `GeminiTranscriber.chunkThreshold`) | The code comment says boundary choice was tested with synthetic audio. No test is in the repository. |
| FR-TRN-19, EXT-11 | `Sources/Providers.swift` (`GeminiTranscriber`, `GeminiInteractions`) | The code comment says the request builder and parser were tested with canned JSON. No live request, and no test in the repository. |
| FR-TRN-18, FR-TRN-23 | None | Planned |
| FR-PRG-01 to FR-PRG-06 | `Sources/Progress.swift`; `Sources/Providers.swift`; `Sources/TranscriptViews.swift` (`TranscribingView`, `MiniProgress`) | Not exercised against a real job |
| FR-SPK-01 to FR-SPK-03, FR-SPK-05 to FR-SPK-07 | `Sources/Progress.swift` (`SpeakerFormat`); `Sources/Providers.swift`; `Sources/TranscriptViews.swift`; `Sources/ModelPickers.swift` (`SpeakerSupport`) | No ElevenLabs or Gemini live request |
| FR-SPK-04 | None (`SpeakerLabelsSetting` has no control) | Planned |
| FR-MDL-01 to FR-MDL-04, FR-MDL-08, EXT-12 | `Sources/ModelCatalog.swift`; `Sources/Settings.swift` | Not run against a provider |
| FR-MDL-05 | `Sources/Settings.swift` (`refreshStaleModels` has no caller) | Planned |
| FR-MDL-06, FR-MDL-07 | `Sources/ModelPickers.swift` (`ModelPicker`); `Sources/RecordViews.swift` | Not exercised. The Settings sheet still has a text field. |
| FR-FLD-01, FR-FLD-03 to FR-FLD-05, FR-FLD-07, FR-FLD-08 | `Sources/Model.swift` (`RecordingStore`) | 15 folder logic checks (the store is unchanged since) |
| FR-FLD-02, FR-FLD-06, FR-FLD-09 to FR-FLD-14 | `Sources/Library.swift`; `Sources/Model.swift`; `Sources/Dialogs.swift` (`DeleteRecordingDialog`, `DeleteFolderDialog`) | Drag and drop and dialogs not exercised |
| FR-SCH-01 to FR-SCH-04 | `Sources/Search.swift` (`SearchService`, `SearchModel`) | Not exercised |
| FR-SCH-05 to FR-SCH-08 | `Sources/SearchBar.swift` (`GlobalSearch`); `Sources/TranscriptViews.swift` (`FindBar`); `Sources/main.swift` | Not exercised |
| FR-PLY-01, FR-PLY-02 | `Sources/Audio.swift` (`Player`); `Sources/DetailView.swift` (`PlayerBar`) | Not exercised |
| FR-OPN-01 to FR-OPN-06 | `Sources/Dialogs.swift` (`CloudConfirmDialog`); `Sources/DetailView.swift` (`OpinionList`); `Sources/Providers.swift`; `Sources/Model.swift` | Claude request not sent |
| FR-OPN-07 | None | Proposed in design, not built |
| FR-CLD-01, FR-CLD-02 | `Sources/Views.swift` (`ContentView`); `Sources/RecordViews.swift`; `Sources/Theme.swift` (`WarningBanner`) | Not exercised with a live cloud job |
| FR-CLD-03, NFR-PRV-05 | None (see KG-01) | Planned |
| FR-SET-01 to FR-SET-09 | `Sources/SettingsView.swift`; `Sources/Settings.swift`; `Sources/Theme.swift`; `Sources/main.swift` | Not exercised since the redesign |
| FR-EXP-01 to FR-EXP-06 | `Sources/DetailView.swift` | Not exercised |
| FR-EXP-08 | `Sources/Export.swift` (`Exporter`, `ExportModel`) | Not exercised. No UI calls it. |
| FR-EXP-09, FR-EXP-10 | `Sources/ExportFlow.swift` (`FullExporter`, `ExportDialog`); `Sources/Dialogs.swift` | Not exercised. Nothing opens the dialog from a selection yet. |
| FR-EXP-07, FR-EXP-11 | None | Planned |
| FR-APP-01 to FR-APP-04 | `Sources/DetailView.swift`; `Sources/RecordViews.swift`; `Sources/main.swift`; `Sources/Theme.swift` (`LogoMark`); `assets/branding/` | Not exercised |
| FR-APP-05 | `Sources/Theme.swift` (`GFont`); `build.sh`; `assets/fonts/` | Not exercised |
| FR-APP-06 | `build.sh`; `assets/README.md` | Not run with the certificate in a session |
| FR-ERR-01 to FR-ERR-05 | `Sources/Providers.swift`; `Sources/TranscriptViews.swift` (`JobErrorPanel`); `Sources/RecordViews.swift`; `Sources/Audio.swift` | Local failure paths only from the pipeline run |
| FR-ERR-06, NFR-SEC-05, NFR-ACC-03 to NFR-ACC-05 | None | Planned |
| NFR-PRV-01 to NFR-PRV-04, NFR-PRV-06 to NFR-PRV-09 | `Sources/Providers.swift`; `Sources/ModelCatalog.swift`; `build.sh`; `setup/*.sh` | Read from code. No network trace taken. |
| NFR-PRF-01, NFR-PRF-02, NFR-PRF-05 | `Sources/Providers.swift`; `Sources/Audio.swift` | Timing from the model comparison on a 10 minute 54 second clip |
| NFR-PRF-03, NFR-PRF-06, NFR-PRF-07 | None | Planned |
| NFR-REL-01 to NFR-REL-04, NFR-REL-07 | `Sources/Model.swift`; `Sources/Settings.swift` | Folder checks cover REL-04 |
| NFR-REL-05, NFR-REL-06 | None | Planned (KG-02, KG-03) |
| NFR-USA-01 to NFR-USA-06 | `Sources/Views.swift`; `Sources/RecordViews.swift`; `Sources/DetailView.swift`; `Sources/Theme.swift`; `Sources/main.swift` | Snapshots predate the redesign |
| NFR-ACC-01, NFR-ACC-02 | `Sources/Audio.swift`; `Sources/RecordViews.swift`; `Sources/DetailView.swift`; `Sources/Library.swift` | Not audited |
| NFR-SEC-01 to NFR-SEC-04 | `Sources/Settings.swift` (`Keychain`); `Sources/SettingsView.swift`; `Sources/Providers.swift` | Not exercised against the real Keychain |
| EXT-03, EXT-04 | `Sources/Audio.swift` | Not exercised live |
| EXT-05 to EXT-07 | `Sources/Providers.swift` | No keys in the build session |
| EXT-08, EXT-09 | `Sources/Settings.swift`; `Sources/RecordViews.swift`; `Sources/DetailView.swift`; `Sources/Library.swift`; `Sources/main.swift` | Not exercised |
| EXT-10 | `setup/*.sh` | Model files are present on the Mac |
| CON-01 to CON-11 | `build.sh`; `Sources/main.swift`; `assets/README.md` | Read from code |

### 6.2 Verification summary

| Group | Requirements | Verified | Built, untested | Planned |
|---|---|---|---|---|
| EXT external interfaces | 12 | 2 | 10 | 0 |
| FR-REC recording | 14 | 1 | 13 | 0 |
| FR-IMP import | 6 | 0 | 6 | 0 |
| FR-TRN transcription | 23 | 1 | 20 | 2 |
| FR-PRG progress | 6 | 0 | 6 | 0 |
| FR-SPK speaker labels | 7 | 0 | 6 | 1 |
| FR-MDL model lists | 8 | 0 | 7 | 1 |
| FR-FLD folders and library | 14 | 6 | 8 | 0 |
| FR-SCH search | 8 | 0 | 8 | 0 |
| FR-PLY playback | 2 | 0 | 2 | 0 |
| FR-OPN opinions | 7 | 0 | 6 | 1 |
| FR-CLD cloud disclosure | 3 | 0 | 2 | 1 |
| FR-SET settings | 9 | 0 | 9 | 0 |
| FR-EXP export | 11 | 0 | 9 | 2 |
| FR-APP appearance and shortcuts | 6 | 0 | 6 | 0 |
| FR-ERR errors | 6 | 0 | 5 | 1 |
| NFR-PRV privacy | 9 | 1 | 7 | 1 |
| NFR-PRF performance | 7 | 3 | 1 | 3 |
| NFR-REL reliability | 7 | 1 | 4 | 2 |
| NFR-USA usability | 6 | 0 | 6 | 0 |
| NFR-ACC accessibility | 5 | 0 | 2 | 3 |
| NFR-SEC security of keys | 5 | 0 | 4 | 1 |
| Total | 181 | 15 | 147 | 19 |

The 11 design constraints (CON) carry no status because they describe the build, not behaviour. Of the 181 requirements, 15 are verified, 147 are built but untested, and 19 are planned.

### 6.3 Evidence from the build sessions

Verified:

- The local pipeline end to end on a real clip.
- The audio writer and format conversion on synthetic audio.
- 15 folder logic checks.
- The English-only path on a 30 second slice (with large-v3 at full precision).
- UI snapshots in light mode (of the earlier UI).

Not verified:

- Live microphone recording.
- Live computer audio capture.
- Every Gemini, ElevenLabs, and Claude request, and every model list request.
- Drag and drop.
- Dark mode snapshots.
- Anything changed after those runs: `-pp` progress streaming, the new English default, chunking, search, export, model lists, and the Graphite redesign. They count as Built, untested until someone runs them.

UI snapshots show that screens render. They aren't counted as verification of any interaction.

## 7. Known gaps

| ID | Gap | Affects |
|---|---|---|
| KG-01 | Choosing a cloud engine as the default sends audio automatically after a recording or import. Only the persistent banner warns you. The per-send confirmation exists only on the detail screen. This differs from the decision that each cloud send asks. | FR-CLD-03, NFR-PRV-05 |
| KG-02 | Jobs live in memory. There is no cancel button, and quitting mid-transcription loses the job without resuming it. | FR-TRN-18, NFR-REL-06 |
| KG-03 | `meta.json` is written on stop, and AAC data is finalised when the file is released. A crash mid-recording can leave an audio file that isn't listed and may not play. | NFR-REL-05 |
| KG-04 | Closed on 17 Nov 2026: deleting a recording now asks for confirmation. | FR-FLD-14 |
| KG-05 | Several writes use `try?` and fail silently: transcript export (single), audio export, `meta.json`, `folders.json`, and Keychain writes. A `meta.json` that doesn't decode is skipped, so the recording vanishes from the list. If `folders.json` doesn't decode, the folder list loads empty and the next folder change overwrites the file. The batch export engine does report per-recording errors. | FR-ERR-06, NFR-SEC-05 |
| KG-06 | The default "Copy for Claude" prompt says the transcript mixes Hindi and English, even for an English-only call. | FR-EXP-07 |
| KG-07 | Claude's reply is capped at 16,000 tokens and the stop reason isn't checked, so a long merge can end early with no notice. Gemini shows a notice at its limit, but the transcript is still cut. | FR-OPN-05, FR-TRN-08 |
| KG-08 | Chunking exists for Gemini and ElevenLabs only. Local sends the whole recording to `whisper-cli`. Local timing beyond 10 minutes 54 seconds isn't measured, and memory use is unknown. | FR-TRN-23, NFR-PRF-03 |
| KG-09 | The English-only default changed to large-v3-turbo (5-bit). The code comment calls it the pick from the English comparison, but the numbers aren't recorded here, and the earlier 30 second check used large-v3 at full precision. | NFR-PRF-06, FR-TRN-05 |
| KG-10 | The accuracy numbers come from one 5 minute clip from one meeting. The reference was corrected by a human who started from Gemini's text, so Gemini's score is flattered. | PRD success measures |
| KG-11 | Not wired yet: selecting several recordings doesn't open the export dialog, the Settings sheet still has a text field for model names (the picker and Refresh models sit on the record screen), the speaker labels switch has no control, nothing refreshes a model list older than 24 hours, and there's no compare-opinions view. | FR-EXP-11, FR-MDL-05, FR-SPK-04, FR-OPN-07 |
| KG-12 | No accessibility audit. Some icon-only buttons have labels and others have tooltips only. | NFR-ACC-03, NFR-ACC-05 |
| KG-13 | After an import, the file is copied in full, so large files double on disk until you delete one. A file `AVAudioPlayer` can't read gets a duration of 0. | FR-IMP-02, FR-IMP-03 |
| KG-14 | When computer audio can't start, the app reuses its permission-denied flag, so the permission message can show even when the cause is something else. | FR-REC-07 |
| KG-15 | Running an engine again replaces its earlier result. There is no history of earlier runs. | FR-OPN-02 |
| KG-16 | Live microphone recording, live computer audio, every cloud request, drag and drop, and dark mode snapshots are unverified. | Section 6.3 |
| KG-17 | The stable signing certificate keeps permissions across rebuilds in theory. It hasn't been checked in a session, and a Mac without the certificate falls back to ad-hoc signing, which asks again after each rebuild. | FR-APP-06, CON-04 |
| KG-18 | The Interactions API path for `gemini-3.5-transcribe` is built but has never sent a request. Its field names come from Google's docs as the owner read them, and the code carries a fallback input block for a 400. A live test with your Gemini key will show whether the default model works. | FR-TRN-19, EXT-11 |
| KG-19 | Closed on 17 Nov 2026 in code, untested: with diarization on, Gemini 3.5 Transcribe chunks at 29 minutes. Speaker numbers may not match between parts, and the job says so. | FR-TRN-20 |
| KG-20 | Closed on 17 Nov 2026 in code, untested: `build.sh` bundles Inter and JetBrains Mono and the app registers them at launch. | FR-APP-05, CON-11 |
| KG-21 | `refreshStaleModels` exists and has no caller, so a list refreshes only when its key changes. | FR-MDL-05 |
| KG-22 | The generateContent prompts still say "Speaker labels are not needed", so a Gemini model on that path returns none. The Interactions path sets diarization in its request instead. | FR-SPK-03 |
| KG-23 | No tests are committed. The progress, chunking, search, and model list code comments describe tests that aren't in the repository. | Section 6 |

## 8. Changelog

| Date | Version | Change |
|---|---|---|
| 17 Nov 2026 | 0.2 | New scope. Added groups FR-PRG (progress), FR-SPK (speaker labels), FR-MDL (model lists), FR-SCH (search), and FR-APP (shortcuts, branding, signing, fonts). Added FR-TRN-19 to FR-TRN-23, FR-SPK-06, FR-SPK-07, FR-SCH-08, FR-EXP-08 to FR-EXP-11, EXT-11, EXT-12, NFR-PRV-09, NFR-PRF-07, NFR-REL-07, and CON-09 to CON-11. Replaced FR-FLD-15 (search) with FR-SCH and FR-OPN-08 (command palette) with the search bar and Cmd+K. Closed KG-04. Changed FR-TRN-05 and the English default to large-v3-turbo (5-bit), FR-TRN-09 (diarization on by default), FR-FLD-13 and FR-FLD-14 (delete with confirmation), FR-SET-09 (Graphite built, follows system appearance), and the default models (`gemini-3.5-transcribe`, `scribe_v2`). Moved EXT-01, FR-TRN-03, FR-TRN-04, FR-TRN-05, and NFR-USA-03 from Verified to Built, untested because the code changed after they were checked. Added KG-18 to KG-23. The source was changing while this was written, so each status reflects the files on 17 Nov 2026 and needs a re-check after the next build. |
| 16 Nov 2026 | 0.1 | First version, from the code in the repository. |

## 9. Open items

- Live Gemini test with your key: the Interactions API request (FR-TRN-19) and diarization (FR-SPK-03) are built and have never run.
- ElevenLabs live test, later, once there's a key. Claude review needs an Anthropic key too.
- Windows, later.
- Run the unverified paths in KG-16, then re-run the Local pipeline for `-pp` progress and the new English default.
- Record the English comparison numbers behind the large-v3-turbo choice.
- Decide how a cloud default asks before every send (OQ-03 in the PRD).
- Wire the export dialog to a multi-selection (FR-EXP-11), the model picker into the Settings sheet, the speaker labels switch, and the 24 hour model list refresh.
