# Koma

## Build and run

1. Open `Koma.xcodeproj` in Xcode 26 or later.
2. Xcode fetches the ZIPFoundation package (0.9.19 or later) the first time.
3. Choose an iPhone or iPad simulator and press Run.
4. To run on a device: target → Signing & Capabilities → choose your team.
   Change the bundle ID (`com.trevorwu.koma`) if you need to.

The project uses folder-synced groups. New files in `App/`, `Models/`, `Storage/`,
`DesignSystem/`, `Features/` and `Preview Content/` join the app target
automatically. You do not need to add them in Xcode.

Build settings follow the Xcode 26 defaults: main-actor isolation by default
and approachable concurrency. Minimum iOS 26.0, iPhone and iPad.

## Importing

Tap **+** or **Import Files** and pick one or more `.zip` / `.cbz` files.
A glass card at the bottom shows "Importing 2 of 5". If a file fails, a summary
sheet lists each file and the reason. In the picker, switch to List view to
select more than one file.

`Info.plist` declares the `.cbz` type (`app.koma.cbz`). Without it the picker
greys out `.cbz` files.

Files can also come from other apps: Share → Koma in Files, Mail or Safari, and
AirDrop. `CFBundleDocumentTypes` lists ZIP and CBZ, and
`LSSupportsOpeningDocumentsInPlace` is NO, so iOS copies the file into
`Documents/Inbox`. Koma imports it and deletes the copy. The Files app's
"Open With" menu does not list Koma; it shows only apps that open files in place.

## Translations

`App/Localizable.xcstrings` has English, Simplified Chinese, Traditional Chinese and
Japanese. To test a language in the simulator:

    xcrun simctl launch booted com.trevorwu.koma -AppleLanguages "(ja)"

## Folder structure

    App/            App entry point, RootView (tabs), Localizable.xcstrings
    Models/         SwiftData: Series, Volume, Tag, ReadingMode
    Storage/        File locations on disk, memory-safe image loading
    DesignSystem/   Theme, buttons, chips, cover, progress bar
    Features/       Import, Library, History, Search, Series, Reader, Settings
    Preview Content/ Sample data (DEBUG only)
    Info.plist      Only the keys Xcode cannot generate (the CBZ type)
