import Foundation
import AVFoundation
import Amplify
import AWSPluginsCore

@MainActor
final class SpeechDictationService: ObservableObject {
    enum AuthState {
        case unknown
        case granted
        case denied(reason: String)
    }

    enum State {
        case idle
        case recording
        case transcribing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var authState: AuthState = .unknown
    @Published var errorMessage: String?

    /// 0...1 mic input level, updated ~10x/sec while recording. Drives the level
    /// meter — the only honest signal that the mic is actually hearing you. A
    /// stalled bar means recording stopped, which a "Stop" button can't tell you.
    @Published private(set) var level: Double = 0

    /// True while the audio session is interrupted (call, alarm, Siri, another
    /// app taking the mic). Recording is genuinely stopped during this.
    @Published private(set) var isInterrupted = false

    var onCommit: ((String) -> Void)?

    var isRecording: Bool { state == .recording }
    var isTranscribing: Bool { state == .transcribing }
    var isBusy: Bool { state != .idle }

    private var audioRecorder: AVAudioRecorder?
    private var audioFileURL: URL?
    private var levelTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        observeInterruptions()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        levelTimer?.invalidate()
    }

    // MARK: - Interruptions

    /// Without this, a call or alarm stops AVAudioRecorder and nothing notices:
    /// the state stays .recording, the button still says Stop, and the user keeps
    /// talking into a dead mic — losing everything said after the interruption.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleInterruption(note)
            }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard state == .recording,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            isInterrupted = true
            level = 0
            stopLevelMonitoring()

        case .ended:
            let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)

            if opts.contains(.shouldResume), resumeRecording() {
                isInterrupted = false
            } else {
                // Can't resume — say so rather than pretending to still listen.
                isInterrupted = false
                errorMessage = "Recording was interrupted and couldn't resume. Tap Stop to keep what was captured."
            }

        @unknown default:
            break
        }
    }

    @discardableResult
    private func resumeRecording() -> Bool {
        guard let recorder = audioRecorder else { return false }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            guard recorder.record() else { return false }
            startLevelMonitoring()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Level metering

    private func startLevelMonitoring() {
        audioRecorder?.isMeteringEnabled = true
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.audioRecorder, self.state == .recording else { return }
                r.updateMeters()
                // dBFS is roughly -60 (silent) to 0 (peak); map to 0...1 with a
                // curve so normal speech uses most of the bar rather than a sliver.
                let db = Double(r.averagePower(forChannel: 0))
                let clamped = max(-55, min(0, db))
                self.level = pow((clamped + 55) / 55, 1.6)
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    func requestAuth() async {
        let mic = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        authState = mic ? .granted : .denied(reason: "Microphone permission not granted. Enable it in Settings.")
    }

    func start() {
        guard state == .idle else { return }
        errorMessage = nil

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nog-dict-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.prepareToRecord(), recorder.record() else {
                errorMessage = "Could not start recording."
                return
            }
            self.audioRecorder = recorder
            self.audioFileURL = url
            self.state = .recording
            self.isInterrupted = false
            self.startLevelMonitoring()
        } catch {
            errorMessage = "Could not start microphone session."
        }
    }

    func stop() {
        guard state == .recording else { return }
        stopLevelMonitoring()
        level = 0
        isInterrupted = false
        audioRecorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = audioFileURL else {
            state = .idle
            return
        }
        state = .transcribing
        Task { await transcribe(url: url) }
    }

    private func transcribe(url: URL) async {
        defer { cleanupFile(url) }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            errorMessage = "Recording was empty."
            state = .idle
            return
        }
        let base64 = data.base64EncodedString()

        let document = """
        mutation TranscribeAudio($audioData: String!) {
            transcribeAudio(audioData: $audioData)
        }
        """
        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["audioData": base64],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        do {
            let response = try await Amplify.API.mutate(request: request)
            switch response {
            case .success(let json):
                if let text = extractTranscript(from: json), !text.isEmpty {
                    onCommit?(text)
                } else {
                    errorMessage = "No speech detected."
                }
            case .failure(let error):
                errorMessage = "Transcription failed: \(error.errorDescription)"
            }
        } catch {
            errorMessage = "Transcription failed: \(error.localizedDescription)"
        }
        state = .idle
    }

    private func extractTranscript(from json: JSONValue) -> String? {
        guard case .object(let root) = json else { return nil }
        if case .string(let s) = root["transcribeAudio"] {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func cleanupFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        audioFileURL = nil
        audioRecorder = nil
    }
}
