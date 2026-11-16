# Scribe Graphite design spec

Source look: direction A, "Graphite console", drawn on a Claude Design canvas. This file turns that look
into tokens and rules so several canvases built in parallel stay identical. Dark is the default theme. Light is the
same layout with the light tokens.

## Tokens (use as CSS custom properties, never raw hex inside screens)

| Token | Dark | Light | Use |
|---|---|---|---|
| `--bg` | `#0D0E11` | `#F5F6F8` | window background, wells (waveform, inputs inside cards) |
| `--sidebar` | `#111317` | `#EDEFF2` | sidebar |
| `--surface` | `#16181D` | `#FFFFFF` | cards, panels |
| `--surface-2` | `#1C1F25` | `#F1F3F6` | raised rows, buttons, hover |
| `--surface-3` | `#262B33` | `#E3E7EC` | selected segment, pressed |
| `--border` | `#272B33` | `#DDE1E7` | card and divider lines |
| `--border-strong` | `#333944` | `#C7CDD6` | buttons, inputs |
| `--text` | `#ECEEF1` | `#14171C` | primary text |
| `--text-2` | `#A0A7B2` | `#4A525E` | secondary text |
| `--text-3` | `#8A929E` | `#5F6875` | captions, labels |
| `--accent` | `#C6F135` | `#C6F135` | primary fill (record, primary button, selected ring) |
| `--on-accent` | `#0D0E11` | `#14171C` | text and icons on the accent fill |
| `--accent-soft` | `#1C2410` | `#EEF8CC` | selected card background, status pill background |
| `--accent-text` | `#C6F135` | `#456000` | accent used as text or icon (light theme needs the dark olive for contrast) |
| `--focus` | `#C6F135` | `#456000` | 2px focus outline, 2px offset |
| `--blue` | `#6EA8FE` | `#1F5FD1` | computer audio lane, links, info |
| `--bar` | `#6B7585` | `#9AA3B0` | idle waveform bars |
| `--warn-bg` | `#2E1A08` | `#FFF1DE` | cloud warning banner |
| `--warn-border` | `#B8661B` | `#D98324` | cloud warning border |
| `--warn-text` | `#FFE2BF` | `#5C3300` | cloud warning text |
| `--warn-icon` | `#FFA94D` | `#B25E00` | cloud warning icon |
| `--danger` | `#FF6B6B` | `#C62828` | errors, destructive text |
| `--danger-soft` | `#2A1214` | `#FDECEC` | error backgrounds |
| `--success` | `#5FD38D` | `#1B7F43` | ready, saved |
| `--scrim` | `rgba(0,0,0,0.6)` | `rgba(20,23,28,0.35)` | modal backdrop |

Folder colours (a 9px square swatch with radius 3, never a folder icon), dark / light:
red `#FF6B6B` / `#D64545`, orange `#FFA94D` / `#C9700F`, yellow `#FFD43B` / `#A67C00`, green `#5FD38D` / `#1B7F43`,
teal `#3CC9C0` / `#0F8A83`, blue `#6EA8FE` / `#1F5FD1`, purple `#B197FC` / `#6F4BD8`, pink `#F783AC` / `#C2255C`,
gray `#8A929E` / `#5F6875`. Expose them as `--f-red` ... `--f-gray`.

## Type, shape, spacing

- Fonts: Inter 400/500/600/700 for UI; JetBrains Mono 400/500 for timers, shortcuts, paths, counts. Load both with one Google Fonts link in `<helmet>`.
- Timer 68px mono 500, letter-spacing -0.03em. Page title 20px 600, letter-spacing -0.02em. Section label 12px 600 uppercase, letter-spacing 0.06em, `--text-3`. Body 14px. Captions 12 to 13px.
- Radii: 8 buttons and inputs, 10 inner panels and radio cards, 14 cards, 999 pills. Modals 16. Spacing on a 4px grid. Cards have 20px padding.
- Icons: inline stroke SVG on a 24 grid, stroke 2, round caps and joins, `aria-hidden="true"`. No emoji. Never rely on colour alone: pair status colour with an icon or label.
- Sizes: app window 1280x800 (the shell is the board itself, no OS chrome). Sidebar 248px. Modals 480px wide centred over a `--scrim`. Menus 8px radius, 1px `--border-strong`, shadow `0 12px 32px rgba(0,0,0,0.35)` (lighter in light theme).
- Waveform lane: 72px tall well in `--bg` with 1px `--border`, 3px bars with 3px gaps, newest bars "hot": microphone `--accent`, computer audio `--blue`, idle bars `--bar`.

## Components (reuse the markup from the A canvas)

Sidebar (logo, search with a Ctrl K hint, nav, folder tree, status card), segmented control, radio card, checkbox row,
waveform lane, secondary button (`btn2`), primary button (accent fill, `--on-accent` text), danger button
(`--danger` outline), status pill, warning banner, modal, popover menu, toast (bottom centre, `--surface-2`), tab row
for transcripts, player bar, tree row (16px indent per level, swatch, name, mono count), breadcrumb.

Cloud warning banner copy, exact: **Cloud model in use:** audio will be sent to Google, a third-party platform, for processing.
(Name the provider that applies: Google, ElevenLabs. For the Claude text review: transcript text, not audio, will be sent to Anthropic.)

## Light and dark in Claude Design

Every screen is two boards from one source:

1. `NN-name.dc.html` is the full screen. It declares a `theme` tweak: `data-props='{"theme":{"editor":"enum","options":["dark","light"],"default":"dark"},"$preview":{"width":1280,"height":800}}'`.
   `renderVals()` returns a string `vars` holding all the custom properties for the chosen theme, and the root `<div>` starts with `style="{{vars}} width: 1280px; height: 800px; ..."`. Every colour in the markup and in the helmet classes is `var(--token)`.
2. `NN-name-light.dc.html` contains only `<dc-import name="NN-name" theme="light" hint-size="1280px,800px"></dc-import>` plus the standard `<head>`/`<helmet>` lines so it renders alone.
   List both files as boards: dark at x 0, light at x 1360, one row per screen with 120px between rows (row y = index * 920). Title each board "NN Name, dark" and "NN Name, light".
   The first screen is `Main.dc.html` and its wrapper `Main-light.dc.html`.

## Content rules

Generic sample content only: no real meeting text, no real people or company names (use "Platform team", "Design team sessions", "Client calls", "Avery", "Sam"). Folder names to reuse: Daily standups (sub-folders Platform team, Mobile team), Design team sessions, Client calls, Personal notes. Mixed Hindi and English sample lines are fine when written in Roman script ("Aaj ka update, the build is green"). No lorem ipsum, no invented statistics.
