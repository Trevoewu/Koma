import SwiftUI
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    /// Comic book ZIP. There is no system type for it, so Info.plist declares
    /// it (UTImportedTypeDeclarations). A dynamic type does not work: the
    /// picker greys out .cbz files.
    static let cbz = UTType(importedAs: "app.koma.cbz", conformingTo: .zip)

    /// The types the picker accepts. If another app on the device declares .cbz
    /// too, the system may resolve files to that app's type, so we add it.
    static var importable: [UTType] {
        var types: [UTType] = [.zip, .cbz]
        if let other = UTType(filenameExtension: "cbz"), !types.contains(other) {
            types.append(other)
        }
        return types
    }
}

extension View {
    /// Adds the file picker, the floating progress card and the failure summary.
    /// Set `isPresented` to true to open the picker.
    func importFlow(isPresented: Binding<Bool>) -> some View {
        modifier(ImportFlow(isPresented: isPresented))
    }
}

private struct ImportFlow: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(ImportController.self) private var controller
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        @Bindable var controller = controller
        content
            .fileImporter(isPresented: $isPresented,
                          allowedContentTypes: UTType.importable,
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    controller.start(urls, context: context)
                }
            }
            // safeAreaInset, not overlay: it keeps the card above the floating tab bar.
            .safeAreaInset(edge: .bottom) {
                if controller.phase == .running || (controller.phase == .finished && !controller.showsSummary) {
                    ImportProgressCard(controller: controller)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: controller.phase)
            .sheet(isPresented: $controller.showsSummary, onDismiss: controller.dismissSummary) {
                ImportSummaryView(importedCount: controller.importedCount,
                                  failures: controller.failures,
                                  onDone: controller.dismissSummary)
            }
    }
}
