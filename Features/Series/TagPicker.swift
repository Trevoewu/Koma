import SwiftUI
import SwiftData

/// The tag pool: every tag in the library, as chips. Tap a chip to add the tag to
/// the selection or remove it. The search field filters the pool, and
/// "Create “…”" adds a new tag to the pool and selects it.
/// Opened from "+ Tag" on the series page and from the Edit sheet.
struct TagPickerView: View {
    @Binding var selection: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var pool: [Tag]
    @State private var search = ""

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = allNames
        let shown = query.isEmpty ? names : names.filter { $0.localizedStandardContains(query) }
        let exists = names.contains { TitleNormalizer.key($0) == TitleNormalizer.key(query) }
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if !query.isEmpty, !exists {
                        Button { create(query) } label: {
                            Label("Create “\(query)”", systemImage: "plus")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glass)
                    }
                    if names.isEmpty, query.isEmpty {
                        Text("No tags yet. Type a name to create one.")
                            .font(.callout)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.top, 40)
                    }
                    FlowLayout(spacing: 8) {
                        ForEach(shown, id: \.self) { name in
                            TagToggleChip(name: name, isSelected: isSelected(name)) { toggle(name) }
                        }
                    }
                }
                .padding(20)
            }
            .background(ScreenBackground())
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("Search or Create Tag"))
            .onSubmit(of: .search) {
                if !query.isEmpty, !exists { create(query) }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
        .task { SeriesActions.mergeDuplicateTags(in: context) }
    }

    /// The pool plus selected names that are not saved yet, each name once, in name order.
    private var allNames: [String] {
        var names: [String] = []
        var keys = Set<String>()
        for name in pool.map(\.name) + selection where keys.insert(TitleNormalizer.key(name)).inserted {
            names.append(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func isSelected(_ name: String) -> Bool {
        selection.contains { TitleNormalizer.key($0) == TitleNormalizer.key(name) }
    }

    private func toggle(_ name: String) {
        if isSelected(name) {
            selection.removeAll { TitleNormalizer.key($0) == TitleNormalizer.key(name) }
        } else {
            selection.append(name)
        }
    }

    private func create(_ name: String) {
        _ = SeriesActions.tag(named: name, in: context)
        try? context.save()
        if !isSelected(name) { selection.append(name) }
        search = ""
    }
}

/// A tag in the picker. Selected = white capsule with a check, others = glass.
/// Not FilterChip: a tag name is user text and must not go through localization.
private struct TagToggleChip: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                }
                Text(verbatim: name)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Theme.onPrimary : Theme.bodyText)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background {
                if isSelected { Capsule().fill(Theme.primaryFill) }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .identity : .regular.interactive(), in: .capsule)
        .padding(.vertical, 4)   // 44 pt touch target
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Settings → Tags: the whole pool. Add a tag, tap one to rename it, swipe to delete.
struct TagManagerView: View {
    @Environment(\.modelContext) private var context
    @Query private var pool: [Tag]

    @State private var showsNew = false
    @State private var renaming: Tag?
    @State private var name = ""
    @State private var tagToDelete: Tag?

    var body: some View {
        let tags = pool.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        List {
            if tags.isEmpty {
                Text("No tags yet. Tap + to create one.")
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(tags) { tag in
                Button {
                    name = tag.name
                    renaming = tag
                } label: {
                    HStack {
                        Text(verbatim: tag.name)
                            .foregroundStyle(Theme.primaryText)
                        Spacer()
                        Text("\(tag.series?.count ?? 0) series")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Renames the tag")
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { tagToDelete = tag }
                }
            }
            .listRowBackground(Theme.cardFill)
        }
        .scrollContentBackground(.hidden)
        .task { SeriesActions.mergeDuplicateTags(in: context) }
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Tag", systemImage: "plus") {
                    name = ""
                    showsNew = true
                }
            }
        }
        .alert("New Tag", isPresented: $showsNew) {
            TextField("Tag Name", text: $name)
            Button("Add") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                _ = SeriesActions.tag(named: trimmed, in: context)
                try? context.save()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Tag", isPresented: renameBinding, presenting: renaming) { tag in
            TextField("Tag Name", text: $name)
            Button("Save") { SeriesActions.rename(tag, to: name, in: context) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(Text("Delete “\(tagToDelete?.name ?? "")”?"), isPresented: deleteBinding,
                            titleVisibility: .visible, presenting: tagToDelete) { tag in
            Button("Delete Tag", role: .destructive) { SeriesActions.delete(tag, in: context) }
        } message: { tag in
            Text("It is removed from \(tag.series?.count ?? 0) series.")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { tagToDelete != nil }, set: { if !$0 { tagToDelete = nil } })
    }
}
