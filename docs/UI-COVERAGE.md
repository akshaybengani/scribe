# UI coverage: design board to SwiftUI view

The design is the spec (119 boards: 59 screens, each in dark and light, plus the cover). This file maps every screen board to the view that implements it, or says why it is not built. Light and dark are not separate code: every colour is a dynamic Graphite token in `Sources/Theme.swift` that follows the system appearance.

Board prefixes: `rec-` Record and import, `lib-` Library and folders, `txt-` Transcripts and opinions, `set-` Settings and states, `logo-` logo options, `dir-` design directions.

Status: **Done** (implemented), **Native** (done with the standard macOS control, not the drawn one), **Skipped** (not real behaviour or not possible, reason given).

## Record and import (`rec-*`)

| Board | Status | View |
|---|---|---|
| Main: idle, local ready | Done | `RecordView` (`RecordViews.swift`), `ModelChooser`, `CaptureLane`, `LaneWell` |
| 02 record cloud, key missing, cloud banner, Switch to local | Done | `RecordView` pill "Needs API key", `WarningBanner`, offline `NoticeBanner` |
| 03 recording live | Done, partly | `RecordView` (setup locked note, state pill, lanes, timer, stop). Skipped: dB readouts, Mute, Add marker, because the recorder exposes none of them |
| 04 recording paused | Done | `RecordView` (Paused pill, Resume, "Nothing is captured while paused") |
| 05 microphone only | Done | `RecordView` (microphone-only pill and the "Computer audio is off" note). Add marker skipped as in 03 |
| 06 computer audio permission | Done | `PermissionCard` with steps and Open System Settings |
| 07 microphone denied | Done | `PermissionCard`, "Microphone off" pill |
| 08 import empty | Done | `ImportView` drop zone |
| 09 import drag over | Done | `ImportView` ("Release to choose this file") |
| 10 import file chosen | Done | `ImportView` file card: length, model, Start transcription |
| 11 recording saved | Done | `SavedRecordingView` (steps from the live job progress) |
| 12 first-run setup | Done | `SetupView`, `SetupItems` |
| 13 local model missing | Done | `RecordView` notice banner with Fix in AI Models, model card shows the path |

## Library and folders (`lib-*`)

| Board | Status | View |
|---|---|---|
| Main, Library, 11 folder overview | Done | `LibraryView` (breadcrumb, stats, subfolder cards, table), `SidebarView` tree |
| 02 first run, 03 empty folder | Done | `LibraryView.emptyState` |
| 04 folder menu | Native | `SidebarView.folderMenu` context menu |
| 05 recording menu | Native | `LibraryView.row` context menu (Open, Export, Move to…, Delete) |
| 06 new folder | Done | `FolderDialog` (create) |
| 07 rename and recolor | Done | `FolderDialog` (edit: stays-in-place note, Use Move to to change, live count) |
| 08 delete folder | Done | `DeleteFolderDialog` with before and after tree |
| 09 drag and drop | Native | System drag preview, `dropDestination` highlight on the tree row, "Moved to" toast |
| 10 move to | Done | `MoveRecordingDialog` (tree picker, Current location, Move here) |
| Multi-select (new, not a board) | Done | `LibraryView` Select, checkboxes, Cmd/Shift click, selection bar |

## Transcripts and opinions (`txt-*`)

| Board | Status | View |
|---|---|---|
| Main recording detail | Done | `DetailView`, `PlayerBar`, `TranscriptPane`, `TranscriptBody` |
| 02 find in transcript | Done | `FindBar`, `FindState`, highlighted matches, Cmd+F, Cmd+G |
| 03 transcribing | Done | `TranscribingView` (percent, bar, elapsed, time left, chunk, upload) |
| 04 opinion running | Done | tab with live percent in `DetailView.tabsRow` |
| 05 opinion menu | Done | `OpinionList` popover (what each engine sends) |
| 06 confirm Google, 07 confirm Anthropic | Done | `CloudConfirmDialog` (plus the speaker-label limit warning) |
| 07b Claude result | Done, partly | note above the transcript on the Claude tab. The "resolved N differences" count is not stored, so it is not shown |
| 08 compare opinions | Skipped | Marked Proposed in the design and FR-OPN-07 is Planned. Needs a diff and merge feature that does not exist |
| 09 export menu | Done | `DetailView.exportMenu`, `ExportDialog` (everything), save panels |
| 10 delete confirm | Done | `DeleteRecordingDialog` |
| 11 transcript error | Done | `JobErrorPanel` with Retry, AI Models, Dismiss |
| 12 reading mode | Done, partly | A−, A+ and Reading view in `DetailView.readingControls`. Timestamps skipped: transcripts carry no segment times |
| Speaker blocks (new) | Done | `TranscriptBody` shows blocks only when the text has two or more speakers |

## Settings and states (`set-*`)

| Board | Status | View |
|---|---|---|
| Main AI Models | Done | `ModelsOverviewPage` |
| 02 local model | Done | `LocalModelPage` (Found / Not found tags) |
| 03 cloud provider | Done, partly | `CloudProviderPage` (banner, Empty and Saved key states, `ModelPicker`). The Rejected key state is shown as a job error on the recording (`JobErrorPanel`), because the app does not remember a rejection |
| 04 output | Done | `OutputPage` (style sample, template, speaker labels, Saved as you type) |
| 05 storage and privacy | Done | `StoragePage` (disk used, what leaves this Mac, delete all with DELETE) |
| 06 key rejected | Done | `JobErrorPanel` (key rejected) |
| 07 whisper missing | Done | `JobErrorPanel` (brew install command, Copy, Retry, Open AI Models) |
| 08 model missing | Done | `JobErrorPanel` (Choose model file, Retry) |
| 09 offline cloud | Done | `RecordView` offline banner, `NetworkStatus` (NWPathMonitor), job error "You are offline" |
| 10 transcription failed | Done | `JobErrorPanel` (Retry, Keep the recording) |
| 11 toasts | Done, partly | `ToastView` with Show in Finder action. Undo on folder delete skipped: the store cannot restore a folder with its id |
| 12 command palette | Done | `GlobalSearch` in `SearchBar.swift` (Recordings, Folders, In transcripts) |
| 13 shortcuts and About | Done, partly | `ShortcutsDialog`, `AboutDialog`. Only shortcuts that exist are listed (the design's P, M, C, T and arrow keys are proposals) |

## Not screens

| Board | Status | Note |
|---|---|---|
| `logo-*` (five logo options) | Skipped | Options, not UI. The approved "Caret wave" is `CaretWaveBars`, `CaretWaveCaret`, `LogoMark` in `Theme.swift` |
| `dir-*` (design directions) | Skipped | Alternatives that were not chosen. Direction A (Graphite console) is what is built |
| `Main.dc.html` cover | Skipped | Index of the boards |

## Where the logo appears

Sidebar header (`SidebarView`), About (`AboutDialog`), first-run and empty states use `LogoMark`. The Dock and app icon is `assets/branding/AppIcon.icns`, copied into the bundle by `build.sh`.
