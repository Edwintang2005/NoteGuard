# NoteGuard

A Goodnotes-style iPad notes app that works directly on PDFs in the Files app, built for a
cracked screen and a passive (non-Bluetooth) stylus.

## What works today

- **Files-app native.** The home screen is the system file browser (PDFs only). Notebooks open and
  save *in place* wherever they live: iCloud Drive, On My iPad, Dropbox and so on. The app also shows
  up under "Open in…" for PDFs.
- **New notebooks** in Blank, Lined, Grid or Dotted (A4), saved as normal PDFs.
- **Handwriting on any PDF.** Pen, highlighter, eraser, four colours, undo/redo. One finger or the stylus
  draws; two fingers scroll and zoom; the hand tool switches to one-finger scrolling.
- **Pages.** Add a page of any style after the current one, delete pages, page thumbnails sidebar.
- **Ink lives inside the PDF.** Each page's handwriting is saved as a standard PDF annotation with a
  rendered appearance, so Files, Preview and Acrobat all show it. The same annotation carries the raw
  PencilKit strokes, so reopening in NoteGuard gives back fully editable ink. No sidecar files.
- **Dead-zone shield.** Map the cracked area once with freehand outlines, rectangles or ellipses, plus
  a padding margin. Any touch that *starts* inside a zone is swallowed before the app sees it. Strokes
  that start outside and drift in keep drawing.

## How the shield works

A small transparent window floats above the app, sized to just the zones. Touches that land in a
zone go to that window and are discarded. Everything else reaches the app normally. The window has
to stay zone-sized: a full-screen pass-through window stops the system Files browser (which runs
in another process) from receiving touches at all.

Zones are stored against the physical glass (the screen's fixed, home-button-down coordinate
space), so they stay on the crack through rotation, Split View and Stage Manager.

## Project layout

| Path | What it is |
|---|---|
| `NoteGuard/App/` | App and scene delegates (window setup, "Open in", shield refit on resize) |
| `NoteGuard/Browser/` | Files browser home screen, new-notebook flow |
| `NoteGuard/Document/` | `NoteDocument` (PDF load/save, ink annotations), page templates |
| `NoteGuard/Notebook/` | Notebook editor: PDF view, per-page PencilKit canvases, toolbar |
| `NoteGuard/Shield/` | Dead-zone model, shield window, shield menu |
| `NoteGuard/ZoneEditor/` | Full-screen zone editor (freehand / rectangle / ellipse) |
| `project.yml` | XcodeGen spec. Run `xcodegen generate` after adding or removing files |

## Install on your iPad

1. Open `NoteGuard.xcodeproj` in Xcode.
2. Select the **NoteGuard** target, open **Signing & Capabilities**, choose your team, and change
   the bundle identifier from `com.example.NoteGuard` to one of your own.
3. Connect the iPad, select it as the run destination, and press Run.
4. On the iPad, enable Developer Mode if prompted (Settings → Privacy & Security → Developer Mode).

On first launch the zone editor opens: trace around the crack, tap Done, then press around the
crack. Each blocked touch flashes red and bumps the counter in the shield menu.

## Known gaps

- Page thumbnails don't show handwriting yet (ink is drawn live, not baked into the page).
- Ink in the saved PDF is a high-resolution image (about 288 dpi), not vector paths.
- Adding and deleting pages isn't on the undo stack yet.
- Inside the Files browser itself the zone tint may not be visible, though blocking still applies.
