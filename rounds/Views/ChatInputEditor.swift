//
//  ChatInputEditor.swift
//  rounds
//
//  Native multi-line text editor (NSTextView in an NSScrollView) for the chat input. SwiftUI's
//  TextField(axis: .vertical) gives no usable scrollbar / scroll-wheel and the caret doesn't follow
//  typing once the text is tall. This grows with content up to a max height, then scrolls normally
//  (wheel + scroller), with the caret kept in view. Special keys are routed back to MentionField so
//  the @-mention / slash menus and send keep working; Shift+Enter inserts a newline at the caret.
//

import SwiftUI
import AppKit

struct ChatInputEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var autofocus: Bool
    var onEnter: () -> Bool       // Enter without Shift: return true if consumed (send / pick a menu item)
    var onArrow: (Bool) -> Bool   // up == true / down == false: true if consumed (menu navigation)
    var onEscape: () -> Bool      // true if consumed (close a menu)
    var onRegisterTextView: ((ChatKeyTextView?) -> Void)? = nil   // hand the live text view to the owner (voice insert)

    let minHeight: CGFloat = 24
    let maxHeight: CGFloat = 132

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ChatKeyTextView()
        tv.delegate = context.coordinator
        tv.string = text
        tv.font = .preferredFont(forTextStyle: .body)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.placeholderString = placeholder
        tv.onEnter = onEnter; tv.onArrow = onArrow; tv.onEscape = onEscape

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        context.coordinator.textView = tv
        onRegisterTextView?(tv)
        DispatchQueue.main.async {
            context.coordinator.recomputeHeight()
            if autofocus {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ChatKeyTextView else { return }
        // CRITICAL: re-point the coordinator at the CURRENT struct so its text binding tracks the
        // active chat. The NSTextView is reused across chat switches / re-renders; without this,
        // textDidChange keeps writing to a STALE runtime's draft — the visible text then gets wiped
        // on the next re-render and the send button reads empty. (Fixes draft loss on scroll/switch.)
        context.coordinator.parent = self
        tv.onEnter = onEnter; tv.onArrow = onArrow; tv.onEscape = onEscape
        tv.placeholderString = placeholder
        if tv.string != text {     // external change (send-clear, pick/slash insert, draft restore)
            tv.string = text
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.needsDisplay = true
            DispatchQueue.main.async { context.coordinator.recomputeHeight() }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputEditor          // updated each updateNSView so the binding tracks the active chat
        weak var textView: ChatKeyTextView?
        init(_ p: ChatInputEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            tv.needsDisplay = true   // refresh the placeholder
            recomputeHeight()
        }

        func recomputeHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let h = min(max(used, parent.minHeight), parent.maxHeight)
            if abs(parent.height - h) > 0.5 { parent.height = h }
        }
    }
}

final class ChatKeyTextView: NSTextView {
    var onEnter: (() -> Bool)?
    var onArrow: ((Bool) -> Bool)?
    var onEscape: (() -> Bool)?
    var placeholderString = "" { didSet { needsDisplay = true } }

    /// Insert text at the caret — or at the very start if the field isn't focused / was never used
    /// (so dictation lands where the user left the cursor). Keeps undo and notifies the binding.
    func insertAtCaret(_ s: String) {
        let focused = (window?.firstResponder === self)
        let len = (string as NSString).length
        var r = focused ? selectedRange() : NSRange(location: 0, length: 0)
        if r.location > len { r = NSRange(location: len, length: 0) }
        window?.makeFirstResponder(self)
        insertText(s, replacementRange: r)
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 36, 76:                                      // Return / keypad Enter
            if shift { super.keyDown(with: event); return }   // newline at the caret
            if onEnter?() == true { return }                  // send / pick
            super.keyDown(with: event); return
        case 126: if onArrow?(true) == true { return }        // ↑
        case 125: if onArrow?(false) == true { return }       // ↓
        case 53:  if onEscape?() == true { return }           // Esc
        default: break
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? .preferredFont(forTextStyle: .body),
        ]
        let pad = textContainer?.lineFragmentPadding ?? 5
        (placeholderString as NSString).draw(at: NSPoint(x: textContainerInset.width + pad, y: textContainerInset.height),
                                             withAttributes: attrs)
    }
}
