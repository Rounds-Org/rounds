//
//  OCRService.swift
//  rounds
//
//  Extracts a TEXT layer from an uploaded document using the macOS Vision framework
//  (on-device, private — nothing leaves the Mac). This enforces Principle 1: the model
//  reasons over extracted TEXT, never over pixels. If a document yields too little text
//  for its size, we flag it as image-only / text-layer-suspect so the brain asks for a
//  written report instead of guessing from a scan.
//

import Foundation
@preconcurrency import Vision
import AppKit
import PDFKit

nonisolated struct OCRResult: Sendable {
    var text: String
    var pageCount: Int
    var wordCount: Int
    var isImageOnly: Bool        // looks like a scan/tracing with no readable report
    var textLayerSuspect: Bool   // some text, but sparse for the page count
}

nonisolated enum OCRService {

    static func extract(from url: URL) async -> OCRResult {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return await extractPDF(url)
        }
        if ["jpg", "jpeg", "png", "heic", "tiff", "gif", "bmp", "webp"].contains(ext) {
            let text = await recognize(imageURL: url)
            return classify(text: text, pageCount: 1)
        }
        // Plain text / markdown / unknown: read what we can.
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return classify(text: text, pageCount: 1)
    }

    // MARK: - PDF

    private static func extractPDF(_ url: URL) async -> OCRResult {
        guard let doc = PDFDocument(url: url) else {
            return OCRResult(text: "", pageCount: 0, wordCount: 0, isImageOnly: true, textLayerSuspect: true)
        }
        let pages = doc.pageCount
        // First try the embedded text layer.
        let embedded = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if wordCount(embedded) >= max(20, pages * 8) {
            return classify(text: embedded, pageCount: pages)
        }
        // Otherwise render each page and OCR (scanned PDF).
        var ocr = embedded
        for i in 0..<pages {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let img = NSImage(size: NSSize(width: bounds.width * scale, height: bounds.height * scale))
            img.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
            }
            img.unlockFocus()
            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let pageText = await recognize(cgImage: cg)
                if !pageText.isEmpty { ocr += "\n" + pageText }
            }
        }
        return classify(text: ocr.trimmingCharacters(in: .whitespacesAndNewlines), pageCount: pages)
    }

    // MARK: - Vision OCR

    private static func recognize(imageURL: URL) async -> String {
        guard let nsImage = NSImage(contentsOf: imageURL),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }
        return await recognize(cgImage: cg)
    }

    private static func recognize(cgImage: CGImage) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let request = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ru-RU", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) }
                catch { cont.resume(returning: "") }
            }
        }
    }

    // MARK: - Classification

    private static func classify(text: String, pageCount: Int) -> OCRResult {
        let words = wordCount(text)
        let pages = max(pageCount, 1)
        // A real report has a meaningful amount of text per page.
        let suspect = words < max(12, pages * 6)
        let imageOnly = words < 8
        return OCRResult(text: text, pageCount: pages, wordCount: words,
                         isImageOnly: imageOnly, textLayerSuspect: suspect)
    }

    private static func wordCount(_ s: String) -> Int {
        s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }
}
