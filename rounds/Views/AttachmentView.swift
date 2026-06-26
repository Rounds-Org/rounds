//
//  AttachmentView.swift
//  rounds
//
//  Renders a file Reference inside the chat as a real preview: images as small inline images,
//  other files (PDF, docx, …) as a QuickLook thumbnail with the filename. A click opens the file
//  in the native Preview app. Used in the input draft row and on sent user messages. Non-file
//  references (person / step / chat) fall back to the compact @-mention chip.
//

import SwiftUI
import AppKit
import QuickLookThumbnailing

/// QuickLook thumbnail for any file (PDF first page, doc preview, …); falls back to the file icon.
struct AttachmentThumb: View {
    let url: URL
    var side: CGFloat = 48
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack { Color.secondary.opacity(0.08); ProgressView().controlSize(.small) }
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: url.path) { await load() }
    }

    private func load() async {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                               scale: scale, representationTypes: .all)
        let img: NSImage? = await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
        image = img ?? NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Renders a Reference. For a file that exists on disk: an image preview (images) or a thumbnail
/// card (other files), opening in Preview on click. Everything else: the compact @-mention chip.
struct RefAttachment: View {
    @Environment(AppState.self) private var app
    let ref: Reference
    var compact: Bool = false
    var onRemove: (() -> Void)? = nil

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "tiff", "tif", "webp"]

    var body: some View {
        if ref.kind == .file, let url = app.referenceFileURL(ref) {
            content(url)
                .overlay(alignment: .topTrailing) { removeButton }
                .onTapGesture { NSWorkspace.shared.open(url) }
                .help("Open “\(ref.label)” in Preview")
        } else {
            chip
        }
    }

    @ViewBuilder private func content(_ url: URL) -> some View {
        if Self.imageExts.contains(url.pathExtension.lowercased()), let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().scaledToFit()
                .frame(maxWidth: compact ? 120 : 200, maxHeight: compact ? 72 : 150)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        } else {
            HStack(spacing: 8) {
                AttachmentThumb(url: url, side: compact ? 34 : 46)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
                VStack(alignment: .leading, spacing: 1) {
                    Text(ref.label).zfont(.caption, .medium).lineLimit(1)
                    Text(url.pathExtension.uppercased()).zfont(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: compact ? 120 : 170, alignment: .leading)
            }
            .padding(compact ? 5 : 7)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }
    }

    @ViewBuilder private var removeButton: some View {
        if let onRemove {
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill").zfont(.body) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                .offset(x: 6, y: -6)
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            Image(systemName: ref.iconName).zfont(.caption2)
            Text(ref.label).zfont(.caption2).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").zfont(size: 8) }.buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
    }
}
