import SwiftUI
import SwiftData

/// The library with no series yet (the "First launch" board): glass icon tile,
/// "Your Shelf Starts Here", one primary "Import Files", glass "Open from Files App",
/// "Supports ZIP, CBZ and EPUB", "View Import Guide" and the legal line.
struct LibraryEmptyView: View {
    var onImport: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var showsGuide = false

    #if DEBUG
    @Environment(\.modelContext) private var context
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                GlassIconTile(systemImage: "books.vertical")

                Text("Your Shelf Starts Here")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)
                Text("Import a manga and pick up where you left off.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)

                Button("Import Files", systemImage: "plus", action: onImport)
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true, height: 54))
                    .padding(.top, 32)

                Button {
                    openURL(FilesApp.url)
                } label: {
                    Label("Open from Files App", systemImage: "folder")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.top, 12)
                .accessibilityHint("Opens the Files app. Share a ZIP, CBZ or EPUB file to Koma from there.")

                Text("Supports ZIP, CBZ and EPUB")
                    .font(.subheadline)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 20)

                Button("View Import Guide") { showsGuide = true }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.bodyText)
                    .frame(minHeight: 44)
                    .padding(.top, 2)

                Text("Only import manga you are allowed to use")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                #if DEBUG
                Button("Add Sample Data", systemImage: "wand.and.stars") {
                    SampleData.insert(into: context)
                }
                .buttonStyle(.glass)
                .padding(.top, 28)
                #endif
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { height, _ in height * 0.85 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .sheet(isPresented: $showsGuide) { ImportGuideView() }
    }
}

enum FilesApp {
    /// Opens the Files app on its Browse tab.
    static let url = URL(string: "shareddocuments://")!
}

/// How to get ZIP, CBZ and EPUB files into Koma. Opened from the first-launch screen and Settings.
struct ImportGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Three Ways to Import").font(.system(size: 20, weight: .bold))
                        step(icon: "plus",
                             title: "Import Files",
                             text: "Tap + in the library and choose one or more ZIP, CBZ or EPUB files.")
                        step(icon: "square.and.arrow.up",
                             title: "Share from Another App",
                             text: "In Files, Mail or Safari downloads, touch and hold a file, tap Share, then tap Koma.")
                        step(icon: "airplayaudio",
                             title: "AirDrop from a Mac",
                             text: "Send ZIP, CBZ or EPUB files with AirDrop. Koma opens and imports them.")
                    }
                    .sectionCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tips").font(.system(size: 20, weight: .bold))
                        tip("Volumes of one series group together when their file names share a title, like “Tidewater Saints v01.cbz” and “Tidewater Saints v02.cbz”.")
                        tip("If a file has ComicInfo.xml, Koma uses its title, author, tags and reading direction.")
                        tip("Comic EPUBs with one image per page work. Text books, such as novels, cannot be imported.")
                        tip("Pages can be JPG, PNG, WebP, GIF, HEIC or AVIF. Animated GIF, APNG and WebP pages play.")
                        tip("Everything stays on this device. Koma has no account and sends nothing.")
                    }
                    .sectionCard()

                    Text("Only import manga you are allowed to use.")
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(Theme.primaryText)
                .padding(20)
            }
            .navigationTitle("Import Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(Theme.sheetGradient)
    }

    private func step(icon: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .background(Theme.iconWellFill, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sectionFill, in: .rect(cornerRadius: Theme.Radius.row))
        .accessibilityElement(children: .combine)
    }

    private func tip(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
