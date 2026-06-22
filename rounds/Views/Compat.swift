//
//  Compat.swift
//  rounds
//
//  Backward-compat shims so Rounds runs on macOS 14 (Sonoma), not just the latest macOS.
//  A couple of nice-to-have SwiftUI APIs are macOS 15+ only; these wrappers use them when
//  available and degrade gracefully on 14. macOS 14 is the floor because the app's reactive
//  core uses the Observation framework (@Observable / @Environment(Type.self)), introduced
//  in macOS 14 — going lower would mean rewriting all of app state.
//

import SwiftUI

extension View {
    /// `.pointerStyle(.link)` is macOS 15+. On 14 the cursor just stays the default arrow.
    @ViewBuilder func linkCursor() -> some View {
        if #available(macOS 15.0, *) { self.pointerStyle(.link) } else { self }
    }

    /// macOS-14 replacement for `.onGeometryChange(for: CGFloat.self) { $0.size.height }`:
    /// measures the view's height with a background GeometryReader + a preference key.
    func onHeightChange(_ action: @escaping @MainActor (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { g in
                Color.clear.preference(key: HeightPreferenceKey.self, value: g.size.height)
            }
        )
        .onPreferenceChange(HeightPreferenceKey.self) { value in
            Task { @MainActor in action(value) }
        }
    }
}

private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
