# Koma (iOS) — project guide for Claude Code

## Communication
- Explain in Simplified Technical English (about 80% ASD-STE100): short sentences,
  simple words, active voice, one instruction per sentence.

## What the app is
A paid iOS/iPadOS app that reads manga and comics the user already has on the device.
The user imports `.zip` / `.cbz` files. The app extracts the pages, groups volumes into
series, and gives a clean reader with three modes.

- Business model: **paid up front**. No in-app purchases, no ads, no account, no server.
- Privacy: all data stays on the device. App Store privacy label = "Data Not Collected".
- App Store rule: the app never supplies or links to manga content. No download-from-web
  feature. Screenshots use invented placeholder art only.
- Competitor to beat on polish and simplicity (not on feature count): KedaReader/KedaManga.
- App name: **Koma** (Japanese コマ = a manga panel). Use "Koma" in all user-facing text,
  the app display name, and the privacy policy. The Swift app struct is `KomaApp`.
  Check that the name is free on the App Store before the first upload; if it is taken,
  use a subtitle form such as "Koma – Manga Reader".

## Fixed technical decisions
- **iOS 26.0 minimum**, iPhone and iPad. SwiftUI only.
- **SwiftData** for the library (`Series`, `Volume`, `Tag`). Models are CloudKit-ready:
  every property has a default, every relationship is optional, no `@Attribute(.unique)`.
  Keep it that way (iCloud sync is a possible later feature).
- **ZIPFoundation** (SPM, https://github.com/weichsel/ZIPFoundation) for unzipping.
- Native **Liquid Glass** APIs (`glassEffect`, `.buttonStyle(.glass)`, `GlassEffectContainer`).
  No fallback material for older iOS.
- Dark mode first (the default). Settings → Appearance: System/Light/Dark. Every Theme color is a
  light/dark pair (`Color.dynamic`); in light mode the white primary button is near-black.
  Use `Theme.primaryText`, not `.white`, outside the reader. The reader is always dark.
- Languages: English, Simplified Chinese, Traditional Chinese, Japanese (`App/Localizable.xcstrings`).
  Same English word, different meaning → give it its own key (e.g. `settings.reading`).

## Concurrency rules
- The project uses the Xcode 26 default: main-actor isolation by default.
- Slow file work (unzip, write pages, make covers) runs in an `actor` or `nonisolated` code.
  It returns plain `Sendable` structs. SwiftData models are created and changed only on the
  main actor (`modelContext` from the environment).
- Never decode a full-size image for display. Always use `ImageDownsampler`.

## Folder structure
    App/              App entry point, RootView (TabView), Localizable.xcstrings
    Models/           Series, Volume, Tag, ReadingMode
    Storage/          LibraryPaths (files on disk), ImageDownsampler
    DesignSystem/     Theme, Buttons, Chips, CoverView, ReadingProgressBar
    Features/         Import/, Library/, History/, Search/, Series/, Reader/, Settings/
    Preview Content/  SampleData (DEBUG only)

Files on disk:

    Application Support/MangaLibrary/<volume UUID>/cover.jpg
    Application Support/MangaLibrary/<volume UUID>/pages/0001.jpg, 0002.png, ...

SwiftData stores only the UUID, never a full path (the container path can change).

## Design rules (from the "Koma" prototype design canvas)
- Background: dark vertical gradient `#1C1C1E → #0B0B0C → #000000` (`ScreenBackground`).
- **One white primary button per screen** (`#F2F2F2` capsule, black text): Resume,
  Import Files, Continue. Use `PrimaryButtonStyle` (`.primary`, `.primaryFullWidth`).
- Secondary buttons: Apple `.buttonStyle(.glass)` capsules. Icon buttons: `GlassIconButton`
  (round glass, 44 pt; 48 pt in the reader).
- Filter chips: selected = white capsule, others = glass capsule (`FilterChip`).
- Cards: `.glassCard()` (corner radius 28). Covers: 2:3, radius 14, dark glass badge
  bottom-left ("8 vols", "NEW", "Finished").
- Text colors: primary white, secondary `#AEAEB2`, tertiary `#8E8E93`.
- Tab bar: native iOS 26 `TabView` (floating glass). Tabs: Library, History, plus the
  search tab (`Tab(role: .search)`). Settings opens as a sheet from a gear button.
- Reader: black background. Controls float as glass capsules (top: back, title, mode +
  bookmark; bottom: page label, slider, hint). Mode menu is a glass popover.
- Touch targets ≥ 44 pt. Text contrast ≥ 4.5:1. Every icon-only button has an
  accessibility label.

### Screens
1. **Library** — large title, import (+) and settings (gear) buttons, filter chips
   (All / Reading / Unread / Finished), "Continue" hero glass card (cover, title, author,
   "Vol. 3 · Page 42 of 186", progress, white Resume, glass "…"), "All Series" cover grid
   (3 columns iPhone, ~7 iPad). iPad: no sidebar, same layout, wider hero.
2. **Series detail** — background tinted with the cover color; back, Edit, "…" glass
   buttons; centered cover; title; **author** (tap → other series by this author);
   **tags** as glass chips + dashed "+ Tag" chip; "8 volumes · 1,412 pages · Right to Left";
   white "Continue · Vol. 3, p. 42"; volume cover grid (4 columns; finished = dimmed + check;
   current = progress bar).
3. **Reader** — modes: Right to Left, Left to Right, Vertical Scroll. Tap zones in paged
   modes: left 30% / center 40% / right 30%. Center toggles controls. In RTL, left = next
   page. In LTR, right = next page. Progress bar fills from the trailing edge in RTL.
4. **iPad reader** — two-page spread in landscape. In RTL the lower page number is on
   the right.
5. **First launch** — glass icon tile, "Your Shelf Starts Here", white "Import Files",
   glass "Open from Files App", "Supports ZIP and CBZ", "View Import Guide",
   "Only import manga you are allowed to use".
6. **Settings** (sheet with Done) — Appearance segmented control; Reading (default
   direction, detect webtoons, keep screen on); Storage (size used, delete finished
   volumes); Help & Feedback; About.

## Version 1 scope
In: import (picker, Files app "Open in", share sheet, AirDrop), library with series
grouping, covers, filters, sort, delete; reader with 3 modes, zoom, saved progress per
volume, mode saved per series, iPad two-page spread; series detail with author and tags;
settings; first launch; 4 languages.

Out (later): RAR/7z/PDF/EPUB, plain image folders, iCloud sync, bookmarks list,
collections, network/NAS sources, auto-split of double pages.

## Build plan
- [x] **Step 1 — Setup.** Models, LibraryPaths, ImageDownsampler, design-system
      components, temporary test screen, sample data.
- [x] **Step 2 — Import.** (details below)
- [x] **Step 3 — Library screen** (iPhone + iPad) with native TabView. Replace ContentView.
- [x] **Step 4 — Reader.** 3 modes, tap zones, zoom, progress saving, iPad spread,
      prefetch ±2 pages with ImageDownsampler, memory checks with large volumes.
- [x] **Step 5 — Series detail + Edit** (title, author, tags, reading mode, volume order).
- [x] **Step 6 — Settings, first launch, "Open in", light mode, localization.**

Each step must build and run before the next step starts.

### Step 2 details — Importer
- Entry points: SwiftUI `.fileImporter` (allowed types: `.zip` and the `cbz` UTType;
  multiple selection) now. "Open in" / share sheet comes in step 6 (`onOpenURL`,
  `CFBundleDocumentTypes`, `LSSupportsOpeningDocumentsInPlace = NO`).
- Call `startAccessingSecurityScopedResource()` on every picked URL; stop in `defer`.
- Keep image entries only (jpg, jpeg, png, apng, webp, gif, heic, avif). Skip `__MACOSX/`,
  hidden files, folders. Sort with `localizedStandardCompare` (natural order).
- Write pages as `0001.<ext>`, `0002.<ext>`… with names we choose. This also blocks
  zip-slip paths. Store the names in `Volume.pageFiles`.
- Make `cover.jpg` from the first page (downsample to about 600 px, JPEG ~0.8).
- **Non-UTF-8 entry names:** many zips from Chinese/Japanese Windows use GB18030 or
  Shift-JIS. If an entry is not flagged UTF-8 and the name does not decode cleanly, try
  GB18030, then Shift-JIS. Wrong names must never break the import (we rename pages anyway),
  but they affect sort order and ComicInfo lookup.
- **ComicInfo.xml** (root of the archive, if present): read `Series`, `Number`, `Volume`,
  `Title`, `Writer`, `Penciller`, `Genre`, `Tags`, `Summary`, `Manga`.
  `Manga = YesAndRightToLeft` → series reading mode = rightToLeft.
  Author = Writer (and Penciller if different). Tags = Genre + Tags (comma separated, trimmed).
- **Without ComicInfo:** parse the file name. Series title = name without volume markers.
  Volume number patterns: `Vol.03`, `Vol 3`, `v03`, `#3`, `第3卷`, `第03话/話`, `3巻`,
  trailing number. Keep decimals (12.5).
- **Grouping:** match an existing `Series` by normalized title (case-folded, width-folded,
  trimmed, punctuation removed). Else create a new Series. Reuse existing `Tag` by name.
- The import actor returns a `Sendable` struct per volume. The main actor creates and
  links the models. On any error, delete that volume's folder. One bad file must not stop
  the other files in a multi-file import. Show a summary of failures at the end.
- Show import progress (files done / total).
- Test with: CJK file names, GBK-encoded zips, nested folders inside the zip, zips with
  non-image files, an empty zip, a corrupt zip, a 500 MB+ zip.
