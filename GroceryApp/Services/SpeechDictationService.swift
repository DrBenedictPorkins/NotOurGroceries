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

    var onCommit: ((String) -> Void)?

    var isRecording: Bool { state == .recording }
    var isTranscribing: Bool { state == .transcribing }
    var isBusy: Bool { state != .idle }

    private var audioRecorder: AVAudioRecorder?
    private var audioFileURL: URL?

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
        } catch {
            errorMessage = "Could not start microphone session."
        }
    }

    func stop() {
        guard state == .recording else { return }
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
