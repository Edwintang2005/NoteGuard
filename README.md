# NoteGuard

A Goodnotes-style iPad notes app that works directly on PDFs in the Files app, built for a
cracked screen and a passive (non-Bluetooth) stylus.

## What works today

- **Files-app native.** The home screen is the system file browser (PDFs only). Notebooks open and
  save *in place* wherever they live: iCloud Drive, On My iPad, Dropbox and so on. The app also shows
  up under "Open in…" for PDFs.
- **New notebooks** in Blank, Lined, Grid or Dotted (A4), saved as normal PDFs.
- **Markup tools from the Files app.** The system tool palette: pen, fineliner, highlighter, pencil,
  crayon and more, colour picker with opacity, widths, pixel/object eraser, lasso, ruler, undo/redo.
  Drag it to any edge or let it float; its position and tool are remembered. One finger or the stylus
  draws; two fingers scroll and zoom; the hand button switches to one-finger scrolling.
- **Draw and hold for shapes.** Pause at the end of a stroke to snap it to a line, angle, triangle,
  rectangle, polygon, circle or ellipse (preview while holding, applied on lift). Undo once to get
  the freehand stroke back.
- **Rename, share and print** from the title menu. Move, duplicate, tag and delete are in the file
  browser's long-press menu, same as Files.
- **Pages.** Add a page of any style after the current one, delete pages, page thumbnails sidebar.
- **Ink lives inside the PDF.** Each page's handwriting is saved as a standard PDF annotation with a
  rendered appearance, so Files, Preview and Acrobat all show it. The same annotation carries the raw
  PencilKit strokes, so reopening in NoteGuard gives back fully editable ink. No sidecar files.
- **Dead-zone shield.** Map the cracked area once with freehand outlines, rectangles or ellipses, plus
  a padding margin. Zones are saved on the device (not synced, since a crack belongs to one iPad);
  setup opens automatically only on first launch, and later from the Shield menu. Any touch that *starts* inside a zone is swallowed before the app sees it. Strokes
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
| `NoteGuard/Assets.xcassets` | App icon (1024px, no alpha) |
| `NoteGuard/PrivacyInfo.xcprivacy` | Privacy manifest (UserDefaults reason CA92.1; no tracking or data collection) |
| `project.yml` | XcodeGen spec, the source of truth for the Xcode project |
| `Makefile` | `make project` (regenerate), `make build` / `make release` (CI's compile checks) |
| `.github/workflows/ci.yml` | GitHub Actions build gate on pushes and PRs |

## Working on the project

`NoteGuard.xcodeproj` is **generated** from `project.yml` with `make project`, but **committed**,
because Xcode Cloud builds from a plain clone and fails without it. After adding or renaming files,
run `make project` and commit the regenerated project with the change. Never change settings in
Xcode's UI (signing, versions, Info.plist): they're overwritten on the next regeneration. XcodeGen
is pinned in `.xcodegen-version`, and `make project` refuses any other version.

Signing (team `3L8Q3U3WY3`, bundle `com.NoteGuard.app`) lives in `project.yml`.

## Release pathway (same as Pair and Red String)

1. **Push to `main`** on GitHub.
2. **GitHub Actions** (`ci.yml`) checks the committed project matches `project.yml`, then builds
   Debug and Release unsigned with warnings as errors.
3. **Xcode Cloud** (workflow configured in App Store Connect, start condition: branch changes on
   `main`) archives the `NoteGuard` scheme in Release and uploads to TestFlight. Xcode Cloud stamps
   its own build numbers on these. The workflow's `manifest.json` lives in
   `NoteGuard.xcodeproj/xcshareddata/xcodecloud/` and is written by Xcode when the workflow is created.
4. The build lands in **TestFlight → Internal Testing** and installs via the TestFlight app.

For a manual upload instead: Product → Archive (destination "Any iOS Device"), then Organizer →
Distribute App → TestFlight & App Store. Bump `CURRENT_PROJECT_VERSION` in `project.yml` first.

## Install on your iPad directly

Open `NoteGuard.xcodeproj`, connect the iPad, select it as the run destination, and press Run.
Enable Developer Mode on the iPad if prompted (Settings → Privacy & Security → Developer Mode).

On first launch the zone editor opens: trace around the crack, tap Done, then press around the
crack. Each blocked touch flashes red and bumps the counter in the shield menu.

## Known gaps

- Page thumbnails don't show handwriting yet (ink is drawn live, not baked into the page).
- Ink in the saved PDF is a high-resolution image (about 288 dpi), not vector paths.
- Adding and deleting pages isn't on the undo stack yet.
- Inside the Files browser itself the zone tint may not be visible, though blocking still applies.
