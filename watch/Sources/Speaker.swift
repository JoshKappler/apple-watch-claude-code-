//
//  Speaker.swift
//  AVSpeechSynthesizer readback for `assistant_message`, paired with a haptic.
//
//  IMPORTANT watchOS caveat: TTS can be SILENT when there's no Bluetooth/AirPods
//  audio route connected (the watch's tiny speaker often won't play synthesized
//  speech). So we ALWAYS fire a haptic alongside speaking, and expose a mute toggle.
//  We configure the session as .playback / .spokenAudio with .duckOthers so podcasts
//  etc. dip rather than fight the readback.
//

import Foundation
import AVFoundation

@MainActor
final class Speaker: NSObject, ObservableObject {

    /// User toggle (persisted by the view via @AppStorage and pushed in here).
    /// Mutes the AUDIO only — the haptic still fires so you feel the readback.
    @Published var isMuted = false

    /// Master TTS on/off (mirrored from Store.ttsEnabled). When false we do NOTHING —
    /// no audio AND no haptic — so "TTS off" really is silent. This is the single gate
    /// every assistant readback passes through; the Store only ever calls speak() for a
    /// NEW assistant message (deduped at the source), so we don't dedupe again here.
    /// Defaults OFF to match Store.ttsEnabled (audible readback is opt-in).
    @Published var ttsEnabled = false

    /// True while audio is actively being spoken — drives the transcript "speaking pulse".
    @Published private(set) var isSpeaking = false

    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Speak an assistant message aloud (if enabled + unmuted). AUDIO ONLY — the per-reply
    /// haptic is fired by the Store (Haptics.response()) so you feel a reply land even with
    /// readback off, which is the common case. No-op entirely when TTS is disabled.
    func speak(_ text: String) {
        guard ttsEnabled else { return }
        guard !isMuted else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activateSession()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    /// Stop any in-progress speech immediately (e.g. on cancel / new turn).
    func stop() {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted { stop() }
    }

    /// Master enable/disable for TTS (driven by Store.ttsEnabled). Disabling stops any
    /// in-progress utterance immediately so toggling off shuts up mid-sentence.
    func setEnabled(_ enabled: Bool) {
        ttsEnabled = enabled
        if !enabled { stop() }
    }

    // MARK: - Audio session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        // .spokenAudio mode is the right policy for TTS; duckOthers dips background audio.
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
    }

    private func deactivateSession() {
        // Release the route so background audio un-ducks. Best-effort.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.deactivateSession()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.deactivateSession()
        }
    }
}
