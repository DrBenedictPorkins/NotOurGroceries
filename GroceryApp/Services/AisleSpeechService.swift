import Foundation
import Speech
import AVFoundation

/// On-device speech, for saying which aisle something is in.
///
/// Deliberately not the Whisper path `SpeechDictationService` uses. That one
/// uploads audio to a Lambda, which is right for dictating a whole list at the
/// kitchen table and wrong here: this is used standing deep inside a shop, where
/// the signal is the first thing to go. `requiresOnDeviceRecognition` means no
/// network at all, and the result arrives as you speak rather than after a round
/// trip.
///
/// It also takes `contextualStrings`, which Whisper has no equivalent for. Given
/// the store's own aisle names and the number words, the recogniser stops
/// offering "sixty" when somebody said "sixteen" — the single most likely way
/// this feature gets something wrong.
@MainActor
final class AisleSpeechService: ObservableObject {

    enum State: Equatable {
        case idle
        case listening
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    /// Updated continuously while listening, so the sheet can show words landing.
    @Published private(set) var transcript: String = ""

    private let recogniser = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Set when the recogniser has delivered everything it is going to.
    private var didFinish = false

    /// Whether talking to it is worth offering at all. When false the sheet opens
    /// straight onto the keyboard rather than a microphone that cannot work.
    var isAvailable: Bool {
        guard let recogniser else { return false }
        return recogniser.isAvailable && recogniser.supportsOnDeviceRecognition
    }

    // MARK: - Listening

    /// Asks permission if needed, then starts. `hints` are the store's existing
    /// aisle names — see the note on `contextualStrings` above.
    func start(hints: [String]) async {
        guard isAvailable else {
            state = .unavailable("On-device dictation isn't available on this phone.")
            return
        }
        guard await requestAuthorisation() else {
            state = .unavailable("Speech recognition is off for this app. Settings › Got Dill?")
            return
        }
        // Speech recognition and the microphone are two separate grants. Only
        // the first was ever asked for, so on a phone that had never used bulk
        // import the engine started against a microphone nobody had allowed and
        // recorded silence.
        guard await requestMicrophone() else {
            state = .unavailable("The microphone is off for this app. Settings › Got Dill?")
            return
        }

        stop()
        transcript = ""
        didFinish = false

        do {
            try configureSession()
        } catch {
            state = .unavailable("Couldn't use the microphone.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Never leaves the phone. This is the whole point of the service.
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = contextualStrings(for: hints)
        self.request = request

        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            state = .unavailable("Couldn't start the microphone.")
            return
        }

        state = .listening
        task = recogniser?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                // An aisle is one breath long, so the first final result is the
                // answer — there is nothing to wait around for after it.
                if result?.isFinal == true || error != nil {
                    self.didFinish = true
                    self.stop()
                }
            }
        }
    }

    /// End the recording and wait for what was actually said.
    ///
    /// `stop()` cancels the recognition task, which throws away anything the
    /// recogniser has not delivered yet — and on a one-word utterance that is
    /// usually all of it, because partial results lag the audio by a few hundred
    /// milliseconds. Reading `transcript` the instant a thumb lifted therefore
    /// read an empty string, and the aisle was never applied. This stops feeding
    /// the recogniser but leaves it alive long enough to finish the job.
    func finish() async -> String {
        guard state == .listening else {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()

        // Capped, because a recogniser that never finalises must not leave a
        // thumb-lift hanging with no aisle and no explanation.
        let deadline = Date().addingTimeInterval(2)
        while !didFinish && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        stop()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if state == .listening { state = .idle }
    }

    // MARK: - Plumbing

    /// The store's own aisle names, plus the words people actually use to say a
    /// number. Capped because the API ignores an unreasonably long list.
    private func contextualStrings(for hints: [String]) -> [String] {
        let numbers = ["aisle", "one", "two", "three", "four", "five", "six", "seven",
                       "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
                       "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        let named = hints.filter { !$0.isEmpty }.prefix(60)
        return numbers + named
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func requestMicrophone() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    private func requestAuthorisation() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
