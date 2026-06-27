//
//  VoiceInput.swift
//  rounds
//
//  Voice dictation for the chat input: record the mic to a small m4a, send it to OpenAI Whisper
//  (with the user's OWN key, from the Keychain), and return the transcript. The audio file is kept
//  until the transcript succeeds so a transient error can RETRY without re-recording.
//
//  Mic access needs: NSMicrophoneUsageDescription (Info.plist), the audio-input entitlement (we're
//  hardened-runtime, see rounds.entitlements), and a one-time TCC grant.
//

import Foundation
import AVFoundation

enum VoiceError: LocalizedError {
    case micDenied
    case recordFailed(String)
    case api(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .micDenied: "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        case .recordFailed(let m): "Couldn't record: \(m)"
        case .api(let m): m
        case .empty: "No speech detected — try again."
        }
    }
}

/// Records the microphone to a temporary m4a and reports a 0…1 input level for the UI.
@MainActor
final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?
    private var levelTimer: Timer?
    var onLevel: ((Float) -> Void)?

    static func authorization() -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }

    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rounds-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,        // Whisper is happy with 16 kHz mono; keeps the upload small
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.prepareToRecord(), r.record() else {
            throw VoiceError.recordFailed("the recorder wouldn't start")
        }
        recorder = r
        fileURL = url
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                let db = r.averagePower(forChannel: 0)          // ~ -160…0 dB
                self.onLevel?(max(0, min(1, (db + 55) / 55)))    // → 0…1
            }
        }
        RunLoop.main.add(t, forMode: .common)
        levelTimer = t
    }

    /// Stop and keep the file (for transcription). Returns the recorded file URL.
    @discardableResult
    func stop() -> URL? {
        levelTimer?.invalidate(); levelTimer = nil
        recorder?.stop()
        recorder = nil
        return fileURL
    }

    /// Stop and discard the file.
    func cancel() {
        levelTimer?.invalidate(); levelTimer = nil
        recorder?.stop()
        if let u = fileURL { try? FileManager.default.removeItem(at: u) }
        recorder = nil; fileURL = nil
    }
}

/// OpenAI Whisper transcription over the HTTP API (multipart upload).
enum WhisperClient {
    static func transcribe(_ fileURL: URL, apiKey: String, language: String? = nil) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "rounds-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func part(_ s: String) { body.append(s.data(using: .utf8)!) }
        func field(_ name: String, _ value: String) {
            part("--\(boundary)\r\n")
            part("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            part("\(value)\r\n")
        }
        field("model", "whisper-1")
        if let language, !language.isEmpty { field("language", language) }
        let fileData = try Data(contentsOf: fileURL)
        guard fileData.count <= 25 * 1024 * 1024 else {     // Whisper hard limit
            throw VoiceError.api("That recording is too long for Whisper (25 MB max). Try a shorter clip.")
        }
        part("--\(boundary)\r\n")
        part("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        part("Content-Type: audio/m4a\r\n\r\n")
        body.append(fileData)
        part("\r\n")
        part("--\(boundary)--\r\n")
        req.httpBody = body
        req.timeoutInterval = 120

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = (obj?["error"] as? [String: Any])?["message"] as? String
            if code == 401 { throw VoiceError.api("Your OpenAI API key was rejected (401). Check it in voice settings.") }
            throw VoiceError.api(msg ?? "OpenAI error (HTTP \(code)).")
        }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (obj?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw VoiceError.empty }
        return text
    }
}
