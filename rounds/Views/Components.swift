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
    static let accent = Color(red: 0.16, green: 0.55, blue: 0.55)      // calm teal
    static let accentSoft = Color(red: 0.16, green: 0.55, blue: 0.55).opacity(0.12)
    static let warn = Color(red: 0.85, green: 0.34, blue: 0.18)
    static let danger = Color(red: 0.80, green: 0.20, blue: 0.20)
    static let hairline = Color.primary.opacity(0.08)
}

// MARK: - Disclaimer chin (always visible, non-dismissible)

struct DisclaimerChin: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cross.case")
                .font(.caption)
                .foregroundStyle(Theme.accent)
            Text("Rounds is a research assistant, not a doctor. It can be wrong, does not diagnose or prescribe, and does not replace professional care. Everything here is for discussion with a clinician.")
                .font(.caption)
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

// MARK: - Model picker (Opus default)

struct ModelPicker: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var app = app
        Menu {
            ForEach(RoundsModel.allCases, id: \.self) { m in
                Button {
                    app.selectedModel = m
                } label: {
                    Label(m.displayName, systemImage: app.selectedModel == m ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                Text(app.selectedModel.short)
            }
            .font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model used by Claude Code. Opus is the default.")
    }
}

// MARK: - Trust tier badge

struct TierBadge: View {
    let tier: String
    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .help(explanation)
    }
    private var label: String {
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
    private var explanation: String {
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
    private var color: Color {
        switch tier {
        case "PRIMARY": return Theme.accent
        case "T0", "T1": return Color(red: 0.13, green: 0.5, blue: 0.3)
        case "T2", "T3": return Color(red: 0.2, green: 0.45, blue: 0.7)
        case "T4", "T5": return Color(red: 0.6, green: 0.5, blue: 0.2)
        default: return .secondary
        }
    }
}

// MARK: - Small helpers

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}
