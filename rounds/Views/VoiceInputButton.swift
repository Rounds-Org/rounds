//
//  VoiceInputButton.swift
//  rounds
//
//  The microphone in the chat input (left of the paperclip). Tap → record (live waveform, a stop
//  and a cancel) → stop shows a spinner while Whisper transcribes → the text is inserted at the
//  caret. Errors keep the audio so you can Retry without speaking again. No API key → the key sheet.
//

import SwiftUI
import Foundation
import AVFoundation

@MainActor @Observable
final class VoiceInputController {
    enum Phase: Equatable { case idle, recording, transcribing, failed(String) }
    var phase: Phase = .idle
    var meter: [CGFloat] = []
    var elapsed: TimeInterval = 0

    private let recorder = AudioRecorder()
    private var audioURL: URL?

    var insert: ((String) -> Void)?       // wired to AppState.insertVoiceTranscript
    var requestKeyEntry: (() -> Void)?    // show the OpenAI key sheet
    var language: String?                 // optional Whisper hint (ISO code)

    var canRetry: Bool { audioURL != nil }

    func micTapped() {
        guard KeychainStore.get(KeychainStore.openAIKey) != nil else { requestKeyEntry?(); return }
        Task { await beginRecording() }
    }

    private func beginRecording() async {
        switch AudioRecorder.authorization() {
        case .authorized: break
        case .notDetermined:
            if await AudioRecorder.requestAccess() == false {
                phase = .failed(VoiceError.micDenied.errorDescription ?? "Microphone access is off."); return
            }
        default:
            phase = .failed(VoiceError.micDenied.errorDescription ?? "Microphone access is off."); return
        }
        meter = []; elapsed = 0
        recorder.onLevel = { [weak self] lvl in
            guard let self else { return }
            self.meter.append(CGFloat(lvl))
            if self.meter.count > 28 { self.meter.removeFirst() }
            self.elapsed = self.recorder.elapsed
        }
        do { try recorder.start(); phase = .recording }
        catch { phase = .failed((error as? VoiceError)?.errorDescription ?? error.localizedDescription) }
    }

    func stopAndTranscribe() {
        audioURL = recorder.stop()
        phase = .transcribing
        transcribe()
    }

    func cancelRecording() { recorder.cancel(); audioURL = nil; phase = .idle }

    func retry() {
        guard audioURL != nil else { phase = .idle; return }
        phase = .transcribing
        transcribe()
    }

    func dismissError() {
        if let u = audioURL { try? FileManager.default.removeItem(at: u) }
        audioURL = nil; phase = .idle
    }

    func teardown() { recorder.cancel(); audioURL = nil; phase = .idle }

    private func transcribe() {
        guard let url = audioURL, let key = KeychainStore.get(KeychainStore.openAIKey) else {
            phase = .failed("No OpenAI API key — add one to use voice."); return
        }
        Task {
            do {
                let text = try await WhisperClient.transcribe(url, apiKey: key, language: language)
                insert?(text)
                try? FileManager.default.removeItem(at: url); audioURL = nil
                phase = .idle
            } catch {
                phase = .failed((error as? VoiceError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

struct VoiceInputButton: View {
    @Environment(AppState.self) private var app
    @State private var c = VoiceInputController()

    var body: some View {
        content
            .onAppear {
                c.insert = { app.insertVoiceTranscript($0) }
                c.requestKeyEntry = { app.showOpenAIKeySheet = true }
                c.language = app.whisperLanguageHint
            }
            .onDisappear { c.teardown() }
    }

    @ViewBuilder private var content: some View {
        switch c.phase {
        case .idle:
            Button { c.micTapped() } label: {
                Image(systemName: "mic").zfont(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Voice input — dictate with OpenAI Whisper")
        case .recording:
            recordingBar
        case .transcribing:
            ProgressView().controlSize(.small).frame(width: 22, height: 22).help("Transcribing…")
        case .failed(let msg):
            errorBar(msg)
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 7) {
            Button { c.cancelRecording() } label: { Image(systemName: "xmark").zfont(.caption2) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel")
            PulsingRecDot()
            HStack(spacing: 2) {
                ForEach(Array(c.meter.suffix(20).enumerated()), id: \.offset) { _, v in
                    Capsule().fill(Theme.accent).frame(width: 2.5, height: max(3, v * 18))
                }
            }
            .frame(width: 52, height: 20, alignment: .trailing)
            Text(timeString(c.elapsed)).zfont(.caption2).monospacedDigit().foregroundStyle(.secondary)
            Button { c.stopAndTranscribe() } label: { Image(systemName: "stop.circle.fill").zfont(.title3) }
                .buttonStyle(.borderless).foregroundStyle(.red).help("Stop & transcribe")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.bg, in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline))
    }

    private func errorBar(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).zfont(.caption2)
            Text(msg).zfont(.caption2).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: 190, alignment: .leading)
            if c.canRetry { Button("Retry") { c.retry() }.zfont(.caption2).buttonStyle(.borderless) }
            Button { c.dismissError() } label: { Image(systemName: "xmark").zfont(size: 9) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.warn.opacity(0.10), in: Capsule())
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PulsingRecDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(.red).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Sheet for the user's own OpenAI API key (stored in the Keychain). Shown when voice is used with
/// no key set, and from Settings. The user types their key; Rounds never sees it elsewhere.
struct OpenAIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key: String = KeychainStore.get(KeychainStore.openAIKey) ?? ""
    private var hasExisting: Bool { KeychainStore.get(KeychainStore.openAIKey) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("OpenAI API key").zfont(.title3, .semibold)
            Text("Voice input transcribes your speech with OpenAI Whisper using your own API key. It's stored only in this Mac's Keychain and sent only to OpenAI.")
                .zfont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("sk-…", text: $key).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
            Link("Get a key at platform.openai.com/api-keys", destination: URL(string: "https://platform.openai.com/api-keys")!)
                .zfont(.caption)
            HStack {
                if hasExisting {
                    Button("Remove key", role: .destructive) {
                        KeychainStore.set(nil, account: KeychainStore.openAIKey); dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    KeychainStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: KeychainStore.openAIKey)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 430)
    }
}
