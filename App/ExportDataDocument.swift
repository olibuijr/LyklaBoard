//
//  ExportDataDocument.swift
//  BetterKeyboard
//
//  Thin `FileDocument` wrapper so the "Flytja út gögnin mín" action can hand
//  the personal-model JSON straight to SwiftUI's `.fileExporter` (Save to
//  Files / AirDrop / share sheet). Read support exists only to satisfy the
//  `FileDocument` protocol — the app never imports its own export in v1.
//

import SwiftUI
import UniformTypeIdentifiers

struct ExportDataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
