//
//  FilePreviewView.swift
//  rounds
//
//  In-app document preview using Quick Look (handles PDF, images, text natively), so a
//  clicked file opens inside Rounds as a tab rather than bouncing out to Preview.app.
//

import SwiftUI
import Quartz

struct FilePreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }
}

/// A file tab's content: the preview plus a small header with the file name and actions.
struct FileTabContent: View {
    @Environment(AppState.self) private var app
    let doc: MedDocument

    private var titleWithPerson: String {
        let name = app.people.first { $0.slug == doc.personId }?.displayName ?? ""
        return name.isEmpty ? doc.displayName : "\(doc.displayName) (\(name))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: doc.isImaging ? "photo" : "doc.text").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleWithPerson)
                        .font(.headline)
                    HStack(spacing: 6) {
                        if let d = doc.testDate { Text(d).font(.caption).foregroundStyle(.secondary) }
                        if let lab = doc.sourceLab { Text("· \(lab)").font(.caption).foregroundStyle(.tertiary) }
                    }
                }
                Spacer()
                Button { app.openInExternalPreview(doc) } label: { Label("Open in Preview", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button { app.revealInFinder(doc) } label: { Image(systemName: "folder") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(12)
            Divider()
            if doc.isImaging && !doc.hasTextReport {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.warn)
                    Text("This is an image with no written report — Rounds stores it but won't draw conclusions from the picture.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10).background(Theme.warn.opacity(0.08))
            }
            FilePreviewView(url: app.fileURL(doc))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
    }
}
