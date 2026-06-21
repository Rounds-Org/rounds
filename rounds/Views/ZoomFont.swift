//
//  ZoomFont.swift
//  rounds
//
//  ⌘+/⌘− text zoom done RIGHT: macOS ignores Dynamic Type and `scaleEffect` breaks hit-testing
//  when used to reflow, so instead every `.font(...)` becomes `.zfont(...)` which reads a zoom
//  scale from the environment and produces a REAL scaled font. The layout reflows naturally and,
//  because there is no transform, every click lands exactly where the control is drawn.
//
//  At scale == 1 a plain style returns the identical semantic font, so the default look is unchanged.
//

import SwiftUI

private struct ZoomScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1.0 }
extension EnvironmentValues {
    var zoomScale: CGFloat {
        get { self[ZoomScaleKey.self] }
        set { self[ZoomScaleKey.self] = newValue }
    }
}

extension Font.TextStyle {
    /// Approximate macOS point size per style (only used when scale != 1 — at scale 1 we use the
    /// real semantic font, so these values only set the *proportions* of the zoom).
    var zBaseSize: CGFloat {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .subheadline: 11
        case .body: 13
        case .callout: 12
        case .footnote: 10
        case .caption: 10
        case .caption2: 10
        @unknown default: 13
        }
    }
    var zDefaultWeight: Font.Weight { self == .headline ? .semibold : .regular }
}

struct ZFontModifier: ViewModifier {
    @Environment(\.zoomScale) private var scale
    var style: Font.TextStyle?
    var size: CGFloat?
    var weight: Font.Weight?
    var design: Font.Design?

    func body(content: Content) -> some View { content.font(resolved) }

    private var resolved: Font {
        if let size {
            return .system(size: size * scale, weight: weight ?? .regular, design: design ?? .default)
        }
        let s = style ?? .body
        if scale == 1, design == nil {
            let base = Font.system(s)
            return weight.map { base.weight($0) } ?? base
        }
        return .system(size: s.zBaseSize * scale, weight: weight ?? s.zDefaultWeight, design: design ?? .default)
    }
}

extension View {
    func zfont(_ style: Font.TextStyle, _ weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(ZFontModifier(style: style, size: nil, weight: weight, design: design))
    }
    func zfont(size: CGFloat, weight: Font.Weight? = nil) -> some View {
        modifier(ZFontModifier(style: nil, size: size, weight: weight, design: nil))
    }
}
