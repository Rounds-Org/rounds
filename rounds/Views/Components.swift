//
//  Components.swift
//  rounds
//
//  Shared visual language: theme, the fixed disclaimer chin, the model picker, and the
//  trust-tier badge.
//

import SwiftUI

enum Theme {
    static let bg = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let accent = Color(red: 0.337, green: 0.584, blue: 0.404)   // Rounds green #569567
    static let accentSoft = Color(red: 0.337, green: 0.584, blue: 0.404).opacity(0.12)
    static let warn = Color(red: 0.85, green: 0.34, blue: 0.18)
    static let danger = Color(red: 0.80, green: 0.20, blue: 0.20)
    static let hairline = Color.primary.opacity(0.08)
}

// MARK: - Disclaimer chin (always visible, non-dismissible)

struct DisclaimerChin: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cross.case")
                .zfont(.caption)
                .foregroundStyle(Theme.accent)
            Text("Rounds is a research assistant grounded in sources, not a doctor. It can be wrong and doesn't replace professional care — use it to understand your options and decide with a clinician.")
                .zfont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(Divider(), alignment: .top)
    }
}

// MARK: - Model picker (live list from Claude Code; Opus alias default)

struct ModelPicker: View {
    @Environment(AppState.self) private var app
    var body: some View {
        Menu {
            ForEach(app.availableModels, id: \.self) { m in item(m) }
            if !app.olderModels.isEmpty {
                Menu("Older models") {
                    ForEach(app.olderModels, id: \.self) { m in item(m) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                Text(app.selectedModel.short)
            }
            .zfont(.caption, .medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model used by Claude Code. The list comes from your installed Claude Code, so new models appear automatically.")
    }

    private func item(_ m: RoundsModel) -> some View {
        Button {
            app.selectedModel = m
        } label: {
            Label(m.displayName, systemImage: app.selectedModel == m ? "checkmark" : "")
        }
    }
}

struct EffortPicker: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var app = app
        Menu {
            // Only the levels the selected model actually supports (from the live model list).
            ForEach(RoundsEffort.allCases.filter { $0 == .default || app.selectedModel.supportedEfforts.contains($0.rawValue) }, id: \.self) { e in
                Button { app.selectedEffort = e } label: {
                    Label(e.displayName, systemImage: app.selectedEffort == e ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                Text(app.selectedModel.supportedEfforts.contains(app.selectedEffort.rawValue) ? app.selectedEffort.short : RoundsEffort.default.short)
            }
            .zfont(.caption, .medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Reasoning effort (claude --effort): higher is more thorough but slower.")
    }
}

/// Compact model + reasoning-effort controls, sized to sit beside a chat / ask input. All input
/// controls share one look: primary (black) foreground, medium weight — see `ChatView`/`DashboardView`.
struct InputControls: View {
    var body: some View {
        HStack(spacing: 10) {
            ModelPicker()
            Divider().frame(height: 12)
            EffortPicker()
        }
        .foregroundStyle(.primary)
    }
}

/// Research-stage (evidence-maturity) control. A compact text button in the input bar — like the
/// model / effort pills — showing the current stage; tapping it opens a popover with a square-thumb
/// slider and a clear description of every level. The binding is supplied by the caller so the Home
/// composer drives the global default and a chat drives its own per-chat stage.
struct ResearchStagePicker: View {
    @Binding var stage: RoundsResearchStage
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                // Fixed lab icon (never changes with the level), and no chevron — the label alone
                // reads as tappable. The popover anchors to THIS icon so it doesn't drift left/right
                // as the level word changes length.
                Image(systemName: "testtube.2")
                    .popover(isPresented: $open, arrowEdge: .top) {
                        ResearchStagePopover(stage: $stage)
                    }
                Text(stage.short).zfont(.caption, .medium)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Research stage — how far past settled medicine Rounds reaches.")
    }
}

/// Popover body: header with the live level name, a square-thumb 4-stop slider, Settled↔Experimental
/// end labels, the active level's description, and a compact legend of what every level means.
private struct ResearchStagePopover: View {
    @Binding var stage: RoundsResearchStage
    private var tint: Color { stage == .experimental ? Theme.warn : Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Research stage").zfont(.callout, .semibold)
                Spacer()
                Text(stage.displayName).zfont(.caption, .medium).foregroundStyle(tint)
            }

            StageSquareSlider(stage: $stage, tint: tint)

            HStack {
                Text("Settled").zfont(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Experimental").zfont(.caption2).foregroundStyle(.secondary)
            }

            Text(stage.blurb)
                .zfont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                ForEach(RoundsResearchStage.allCases, id: \.self) { s in
                    Button { stage = s } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(s.index)")
                                .zfont(.caption2, .semibold).monospacedDigit()
                                .foregroundStyle(s == stage ? tint : .secondary)
                                .frame(width: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.displayName)
                                    .zfont(.caption, .medium)
                                    .foregroundStyle(s == stage ? Color.primary : .secondary)
                                Text(s.legend)
                                    .zfont(.caption2).foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 288)
    }
}

/// A 4-stop slider whose thumb is a rounded SQUARE on a filled track (Claude-app style). Drag or tap.
private struct StageSquareSlider: View {
    @Binding var stage: RoundsResearchStage
    var tint: Color
    private let count = 4
    private let thumb: CGFloat = 26
    private let dot: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let travel = max(1, w - thumb)
            let frac = CGFloat(stage.index - 1) / CGFloat(count - 1)
            ZStack(alignment: .leading) {
                // Track background.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: thumb)
                // Filled portion up to the thumb.
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.16))
                    .frame(width: thumb / 2 + travel * frac, height: thumb)
                // Stop dots.
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(i + 1 <= stage.index ? tint : Color.primary.opacity(0.28))
                        .frame(width: dot, height: dot)
                        .offset(x: thumb / 2 - dot / 2 + travel * CGFloat(i) / CGFloat(count - 1))
                }
                // Square thumb with its own background + subtle shadow.
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.bg)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint, lineWidth: 1.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(tint)
                            .frame(width: 8, height: 8)
                    )
                    .frame(width: thumb, height: thumb)
                    .shadow(color: Color.black.opacity(0.12), radius: 2, y: 1)
                    .offset(x: travel * frac)
            }
            .frame(height: thumb)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = min(1, max(0, (v.location.x - thumb / 2) / travel))
                        let idx = Int((f * CGFloat(count - 1)).rounded()) + 1
                        let ns = RoundsResearchStage.from(index: idx)
                        if ns != stage { stage = ns }
                    }
            )
        }
        .frame(height: thumb)
    }
}

// MARK: - Trust tier badge

struct TierBadge: View {
    let tier: String
    var body: some View {
        Text(TierBadge.label(tier))
            .zfont(.caption2, .medium)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(TierBadge.color(tier).opacity(0.16), in: Capsule())
            .foregroundStyle(TierBadge.color(tier))
            .help(TierBadge.explanation(tier))
    }
    static func label(_ tier: String) -> String {
        switch tier {
        case "PRIMARY": "Your record"
        case "T0": "Drug label"
        case "T1": "Guideline"
        case "T2": "Systematic review"
        case "T3": "Clinical trial"
        case "T4": "Cohort study"
        case "T5": "Case report"
        case "T6": "Preprint"
        default: tier
        }
    }
    static func explanation(_ tier: String) -> String {
        switch tier {
        case "PRIMARY": "Your own uploaded record — the primary source about you."
        case "T0": "Regulatory drug label — an authoritative fact, not evidence-graded."
        case "T1": "Clinical guideline or Cochrane review — the highest level of trust."
        case "T2": "Systematic review / meta-analysis — very strong evidence."
        case "T3": "Randomized controlled trial — strong evidence."
        case "T4": "Cohort or observational study — moderate evidence."
        case "T5": "Case report or narrative review — low evidence, context only."
        case "T6": "Preprint or unindexed source — lowest confidence."
        default: "Trust tier \(tier)."
        }
    }
    static func color(_ tier: String) -> Color {
        switch tier {
        case "PRIMARY": return Theme.accent
        case "T0", "T1": return Color(red: 0.13, green: 0.5, blue: 0.3)
        case "T2", "T3": return Color(red: 0.2, green: 0.45, blue: 0.7)
        case "T4", "T5": return Color(red: 0.6, green: 0.5, blue: 0.2)
        default: return .secondary
        }
    }
}

/// A glossary line where the TERM is highlighted marker-style (inline, same line height) and the
/// definition flows on as normal prose that wraps underneath — used in the Sources legend.
struct MarkerParagraph: View {
    let term: String
    let definition: String
    let color: Color
    var body: some View {
        (marker + Text("  ") + Text(definition).foregroundColor(.secondary))
            .zfont(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineSpacing(2)
    }
    private var marker: Text {
        var a = AttributedString(" \(term) ")
        a.backgroundColor = color.opacity(0.22)
        a.foregroundColor = color
        return Text(a)
    }
}

// MARK: - Small helpers

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .zfont(.caption2, .semibold)
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .zfont(.caption2, .medium)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}
