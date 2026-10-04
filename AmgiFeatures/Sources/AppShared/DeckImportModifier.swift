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
                return
            }
            guard ext == "apkg" || ext == "colpkg" else {
                failure = "Unsupported file type. Choose an Anki deck (.apkg or .colpkg) or a text file with one note per line (.tsv, .txt or .csv)."
                return
            }
            Task {
                status = .importing(fileName: url.lastPathComponent)
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
}

extension View {
    public func deckImport(isPresented: Binding<Bool>, onRefresh: @escaping () -> Void) -> some View {
        modifier(DeckImportModifier(isPresented: isPresented, onRefresh: onRefresh))
    }
}
