//
//  DeckImportModifier.swift
//  AppShared
//
//  Created by Vladimir Gusev on 13.06.2026.
//

public import SwiftUI
import Theme
import UniformTypeIdentifiers

private struct DeckImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    /// A file another app opened Amgi with, from its share sheet or Files.
    @Binding var openedFile: URL?
    let onRefresh: () -> Void

    @State private var status: ImportStatusBanner.Status?
    @State private var failure: String?
    /// A text file picked, being set up for import (`TextImportSheet`).
    @State private var textImport: TextImportFile?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.data]) { result in
                handleImport(result)
            }
            // Initial too: a file that opened Amgi from closed arrives
            // before this screen does.
            .onChange(of: openedFile, initial: true) { _, file in
                guard let file else { return }
                openedFile = nil
                handleImport(.success(file))
            }
            .sheet(item: $textImport) { file in
                TextImportSheet(file: file, onImported: onRefresh)
            }
            .overlay(alignment: .top) { ImportStatusBanner(status: status) }
            .animation(AmgiMotion.momentum, value: status)
            .alert(
                "Couldn't import",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                presenting: failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

}

private extension DeckImportModifier {
    func handleImport(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let ext = url.pathExtension.lowercased()
            // A text file, one note per line, is set up in a sheet first.
            if TextImportFile.extensions.contains(ext) {
                do {
                    textImport = try TextImportFile.copy(from: url)
                } catch {
                    failure = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
                }
                Self.removeIfHandedOver(url)
                return
            }
            guard ext == "apkg" || ext == "colpkg" else {
                failure = "Unsupported file type. Choose an Anki deck (.apkg or .colpkg) or a text file with one note per line (.tsv, .txt or .csv)."
                Self.removeIfHandedOver(url)
                return
            }
            Task {
                status = .importing(fileName: url.lastPathComponent)
                defer { Self.removeIfHandedOver(url) }
                do {
                    let summary = try await ImportHelper.importPackage(from: url)
                    onRefresh()
                    status = .finished(summary: summary)
                    try? await Task.sleep(for: .seconds(3))
                    status = nil
                } catch {
                    status = nil
                    failure = error.localizedDescription
                }
            }
        case .failure(let error):
            failure = "Could not select file: \(error.localizedDescription)"
        }
    }

    /// A copy another app handed over lands in Documents/Inbox and would
    /// stay there: it's imported now, so it goes. A file picked, or opened
    /// in place from Files, is left alone.
    static func removeIfHandedOver(_ url: URL) {
        let inbox = URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory).standardizedFileURL.path
        guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(inbox + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

extension View {
    /// The Library's import: a deck or text file picked with `isPresented`,
    /// or one Amgi was opened with (`openedFile`).
    public func deckImport(
        isPresented: Binding<Bool>,
        openedFile: Binding<URL?> = .constant(nil),
        onRefresh: @escaping () -> Void
    ) -> some View {
        modifier(DeckImportModifier(isPresented: isPresented, openedFile: openedFile, onRefresh: onRefresh))
    }
}
