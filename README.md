# NoteGuard

A Goodnotes-style iPad notes app that works directly on PDFs in the Files app, built for a
cracked screen and a passive (non-Bluetooth) stylus.

## What works today

- **Files-app native.** The home screen is the system file browser (PDFs only). Notebooks open and
  save *in place* wherever they live: iCloud Drive, On My iPad, Dropbox and so on. The app also shows
  up under "Open in…" for PDFs.
- **New notebooks** in Blank, Lined, Grid or Dotted (A4), saved as normal PDFs.
- **Markup tools from the Files app.** Notebooks open in scroll mode (the hand): one finger scrolls
  and nothing gets drawn by accident. Tap the pen to open the system tool palette (pen, fineliner,
  highlighter, pencil, crayon and more, colour picker with opacity, widths, pixel/object eraser,
  lasso, ruler, undo/redo); while it's open one finger or the stylus draws and two fingers scroll and
  zoom. Tap the pen again, or the hand, to close it. Drag the palette to any edge or let it float; its
  position and tool are remembered.
- **Draw and hold for shapes.** Pause at the end of a stroke to snap it to a line, angle, triangle,
  rectangle, polygon, circle or ellipse (preview while holding, applied on lift). Undo once to get
  the freehand stroke back.
- **Rename, share and print** from the title menu. Move, duplicate, tag and delete are in the file
  browser's long-press menu, same as Files.
- **Text boxes and images.** Insert a text box, a photo or an image from Files. The Select tool (arrow)
  moves them, resizes them from the corners (images keep their shape), double-tap edits text, and
  an edit menu offers text size, duplicate and delete. Text boxes are standard PDF FreeText
  annotations in Helvetica, so every PDF reader shows them the same.
- **Pages.** A sidebar of thumbnails on the left that include your handwriting: tap to jump, drag to reorder,
  long-press to duplicate, bookmark, save as template or delete. Templates: Blank, Lined, Grid,
  Dotted, Cornell Notes, Music Staves, Weekly Planner, plus any page you save as your own template.
- **Bookmarks** are the PDF's outline, so other readers list them too (and outlines that came with a
  PDF, such as a textbook's chapters, show up in the Bookmarks tab).
- **Everything is undoable:** strokes, shapes, page add/delete/move/duplicate, bookmarks, text and
  image edits.
- **Ink lives inside the PDF, as vectors.** Each page's handwriting is saved as a standard PDF
  annotation drawn with vector paths (textured pencil/crayon/watercolour strokes as 288 dpi images),
  so Files, Preview and Acrobat show it crisply at any zoom. The same annotation carries the raw
  PencilKit strokes, so reopening in NoteGuard gives back fully editable ink. No sidecar files.
  Saving is a single pass: 100 inked pages serialise in about half a second.
- **Dead-zone shield.** Map the cracked area once with freehand outlines, rectangles or ellipses.
  Exactly the masked area is ignored, with no margin around it. Zones are saved on the device (not synced, since a crack belongs to one iPad);
  setup opens automatically only on first launch, and later from the Shield menu. Any touch that *starts* inside a zone is swallowed before the app sees it. Strokes
  that start outside and drift in keep drawing.

## How the shield works

A small transparent window floats above the app, sized to the zones' bounding box. Touches that land in a
zone go to that window and are discarded. Everything else reaches the app normally. The window has
to stay zone-sized: a full-screen pass-through window stops the system Files browser (which runs
in another process) from receiving touches at all.

On the Files browser screen (which runs in another process) the whole bounding box of a round or
freehand zone may ignore touches; inside notebooks only the outline itself does.

Zones are stored against the physical glass (the screen's fixed, home-button-down coordinate
space), so they stay on the crack through rotation, Split View and Stage Manager.

## Project layout

| Path | What it is |
|---|---|
| `NoteGuard/App/` | App and scene delegates (window setup, "Open in", shield refit on resize) |
| `NoteGuard/Browser/` | Files browser home screen, new-notebook flow |
| `NoteGuard/Document/` | `NoteDocument` (load/save, undoable page/bookmark/object edits), `InkRenderer` (vector ink), ink and image annotations, templates |
| `NoteGuard/Notebook/` | Notebook editor: PDF view, per-page PencilKit canvases, toolbar, page sidebar, Select tool, shape snapping |
| `Tests/NoteGuardTests/` | Unit tests (Swift Testing): shapes, zones, save/reopen, undo, templates, vector-ink accuracy, save speed |
| `tools/make_icon.swift` | Draws the app icon (`make icon`) |
| `NoteGuard/Shield/` | Dead-zone model, shield window, shield menu |
| `NoteGuard/ZoneEditor/` | Full-screen zone editor (freehand / rectangle / ellipse) |
| `NoteGuard/Assets.xcassets` | App icon (1024px, no alpha) |
| `NoteGuard/PrivacyInfo.xcprivacy` | Privacy manifest (UserDefaults reason CA92.1; no tracking or data collection) |
| `project.yml` | XcodeGen spec, the source of truth for the Xcode project |
| `Makefile` | `make project` (regenerate), `make build` / `make release` (compile checks), `make test` (unit tests on an iPad simulator) |
| `.github/workflows/ci.yml` | GitHub Actions on pushes and PRs: project drift check, unit tests, Debug and Release builds |

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

- Textured inks (pencil, crayon, watercolour) are saved as high-resolution images rather than vectors.
- Whole-PDF rewrites on save: fast for notebooks, but a several-hundred-page scanned textbook will
  still take a moment each autosave (PDFKit has no incremental save).
- Inside the Files browser itself the zone tint may not be visible, though blocking still applies.
