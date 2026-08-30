import SwiftUI
import Amplify
import AWSPluginsCore
import PhotosUI

// MARK: - Data Model

struct ParsedIngredient: Identifiable {
    let id = UUID()
    let originalName: String
    var name: String
    var quantity: String?
    var notes: String?
    var productId: String?
    var isSelected: Bool = true

    /// The speaker's own words, when the parsed name differs from them.
    var heardAs: String?
    /// The parser couldn't resolve this from the transcript alone.
    var needsInput: Bool = false
    /// Candidate names, best first, when the words support more than one product.
    var alternatives: [String] = []
    /// Something a kitchen probably already has. Arrives unticked.
    var isStaple: Bool = false
    /// Set once the user picks or confirms, so it leaves the "needs input" section.
    var resolved: Bool = false

    /// Still awaiting the user. Drives which section the row appears in.
    var isUnresolved: Bool { needsInput && !resolved }

    init(
        name: String,
        quantity: String? = nil,
        notes: String? = nil,
        productId: String? = nil,
        isSelected: Bool? = nil,
        heardAs: String? = nil,
        needsInput: Bool = false,
        alternatives: [String] = [],
        isStaple: Bool = false
    ) {
        self.originalName = name
        self.name = name
        self.quantity = quantity
        self.notes = notes
        self.productId = productId
        // A recipe lists everything it uses; you only shop for what you are out
        // of. Staples arrive unticked so the default is "I have this", which is
        // true far more often than not — and the row is still right there.
        self.isSelected = isSelected ?? !isStaple
        self.heardAs = heardAs
        self.needsInput = needsInput
        self.alternatives = alternatives
        self.isStaple = isStaple
    }
}

// MARK: - Phase

private enum ImportPhase {
    case input
    case parsing
    case review([ParsedIngredient])
    case adding(done: Int, total: Int)
}

// MARK: - BulkImportSheet

struct BulkImportSheet: View {
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @Binding var isPresented: Bool

    /// Where the accepted items go. Nil means the shared household list, which is
    /// the normal case. The Quick List passes a closure so the same four import
    /// sources — speak, camera, photos, paste — work on a list that never leaves
    /// this phone, without a second copy of this screen.
    var onCommit: (([String]) -> Void)? = nil

    @State private var rawText = ""
    @State private var selectedImage: UIImage? = nil
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var phase: ImportPhase = .input
    @State private var ingredients: [ParsedIngredient] = []
    @State private var errorMessage: String?
    @FocusState private var editorFocused: Bool
    @StateObject private var dictation = SpeechDictationService()
    @State private var showMicAuthHint = false
    @State private var isTyping = false

    /// Parsing or writing items — nothing should interrupt either.
    private var isBusy: Bool {
        switch phase {
        case .parsing, .adding: return true
        case .input, .review:   return false
        }
    }

    private var selectedCount: Int {
        ingredients.filter(\.isSelected).count
    }

    var body: some View {
        ZStack {
            DesignSystem.Colors.background.ignoresSafeArea()
            DesignSystem.Colors.darkMetallicGradient.ignoresSafeArea().opacity(0.3)

            VStack(spacing: 0) {
                headerBar
                    .padding(.top, 20)

                switch phase {
                case .input:
                    inputView
                case .parsing:
                    parsingView
                case .review:
                    reviewView
                case .adding(let done, let total):
                    addingView(done: done, total: total)
                }
            }
        }
        // A stray downward drag while this is working used to dismiss the sheet
        // and take the image and transcript with it. Work in progress is not
        // something to lose to a gesture.
        .interactiveDismissDisabled(isBusy)
        .onAppear {
            // Opens empty, every time. A persisted draft used to outlive the
            // sheet so a stray dismissal couldn't cost a long dictation, but in
            // practice it resurrected stale text on nearly every open, which is
            // worse: you are re-reading and deleting someone else's leftovers
            // before you can start. Accidental dismissal is already guarded by
            // interactiveDismissDisabled while parsing.
            rawText = ""
            UserDefaults.standard.removeObject(forKey: "bulkImportDraft")
            editorFocused = true
            dictation.onCommit = { chunk in
                if rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rawText = chunk
                } else {
                    rawText += "\n" + chunk
                }
            }
        }
        .onDisappear {
            if dictation.isRecording { dictation.stop() }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(image: $selectedImage)
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: photoPickerItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { selectedImage = img }
                }
                await MainActor.run { photoPickerItem = nil }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DesignSystem.Colors.textSecondary)

            Spacer()

            Text("Import Items")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accentGradient)

            Spacer()

            // Invisible balance element
            Text("Cancel")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.clear)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Input Phase

    private var hasInput: Bool {
        selectedImage != nil || !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputView: some View {
        VStack(spacing: 20) {
            if let image = selectedImage {
                imagePreviewSection(image: image)
            } else if hasText || isTyping || dictation.isBusy {
                textInputSection
            } else {
                // Nothing yet — lead with the ways in, not with a text box.
                // Typing is the least likely of the five and used to occupy the
                // whole screen while the other four fought over a button strip.
                sourceChooser
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(DesignSystem.Colors.neonPink)
                    .lineLimit(3)
                    .padding(.horizontal, 20)
            }

            Spacer()

            if hasText || selectedImage != nil {
                parseButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            }
        }
        .padding(.top, 4)
    }

    private var hasText: Bool {
        !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Source Chooser

    private var sourceChooser: some View {
        VStack(spacing: 14) {
            Text("How do you want to add items?")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .padding(.top, 6)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                sourceTile(icon: "mic.fill", title: "Speak",
                           detail: "Say the whole list", tint: DesignSystem.Colors.dillGreen) {
                    toggleDictation()
                }
                sourceTile(icon: "camera.fill", title: "Camera",
                           detail: "Photograph a recipe", tint: DesignSystem.Colors.neonPurple) {
                    editorFocused = false
                    showCamera = true
                }
                sourceTile(icon: "photo.fill", title: "Photos",
                           detail: "Pick an existing shot", tint: DesignSystem.Colors.neonPurple) {
                    editorFocused = false
                    showPhotoPicker = true
                }
                sourceTile(icon: "doc.on.clipboard.fill", title: "Paste",
                           detail: pasteDetail, tint: DesignSystem.Colors.neonAmber) {
                    pasteFromClipboard()
                }
            }
            .padding(.horizontal, 20)

            Button {
                isTyping = true
                editorFocused = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 13, weight: .medium))
                    Text("Type it instead")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            micStatusView
        }
    }

    /// The clipboard can hold either, so say which is waiting rather than
    /// making the user tap to find out.
    private var pasteDetail: String {
        if UIPasteboard.general.image != nil { return "An image is on the clipboard" }
        if UIPasteboard.general.hasStrings   { return "Text is on the clipboard" }
        return "Nothing copied yet"
    }

    private func pasteFromClipboard() {
        editorFocused = false
        if let img = UIPasteboard.general.image {
            selectedImage = img
        } else if let text = UIPasteboard.general.string, !text.isEmpty {
            rawText = text
            isTyping = true
        } else {
            errorMessage = "Nothing on the clipboard to paste."
        }
    }

    private func sourceTile(
        icon: String,
        title: String,
        detail: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(tint.opacity(0.14)))

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)

                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(tint.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var textInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Paste a recipe, notes, or a list")
                    .font(.system(size: 13))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                Spacer()
                Button("Start over") {
                    rawText = ""
                    isTyping = false
                    editorFocused = false
                    errorMessage = nil
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DesignSystem.Colors.dillGreen)
            }
            .padding(.horizontal, 20)

            ZStack(alignment: .topLeading) {
                if rawText.isEmpty {
                    Text("e.g. 2 cups flour, 3 eggs, 1 stick butter")
                        .font(.system(size: 15))
                        .foregroundColor(DesignSystem.Colors.textTertiary.opacity(0.6))
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $rawText)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .frame(minHeight: 180)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(DesignSystem.Colors.dillGreen.opacity(editorFocused ? 0.5 : 0.2),
                                    lineWidth: editorFocused ? 1.5 : 1)
                    )
            )
            .padding(.horizontal, 20)

            // Voice stays reachable while typing — dictate more onto what's there.
            HStack(spacing: 12) {
                Spacer()
                micButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)

            micStatusView
        }
    }

    private var micButton: some View {
        let recording = dictation.isRecording
        let transcribing = dictation.isTranscribing
        return Button(action: toggleDictation) {
            VStack(spacing: 4) {
                Group {
                    if transcribing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(DesignSystem.Colors.dillGreen)
                    } else {
                        Image(systemName: recording ? "stop.circle.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .medium))
                    }
                }
                .frame(height: 16)
                Text(transcribing ? "Wait…" : (recording ? "Stop" : "Voice"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(recording ? DesignSystem.Colors.neonPink : (transcribing ? DesignSystem.Colors.dillGreen : DesignSystem.Colors.textSecondary))
            .frame(width: 68, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(recording ? DesignSystem.Colors.neonPink.opacity(0.15) : Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                recording ? DesignSystem.Colors.neonPink.opacity(0.6) : Color.white.opacity(0.12),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(transcribing)
    }

    /// Moves with your voice. This is the honest signal that the mic is live —
    /// a flat bar while you're talking means recording actually stopped, which
    /// a "Stop" button can never tell you.
    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [DesignSystem.Colors.dillGreen, DesignSystem.Colors.neonPurple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(3, geo.size.width * dictation.level))
                    .animation(.linear(duration: 0.1), value: dictation.level)
            }
        }
        .frame(height: 4)
        .opacity(dictation.isInterrupted ? 0.3 : 1)
    }

    @ViewBuilder
    private var micStatusView: some View {
        if dictation.isRecording {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(dictation.isInterrupted
                              ? DesignSystem.Colors.warning
                              : DesignSystem.Colors.neonPink)
                        .frame(width: 8, height: 8)
                    Text(dictation.isInterrupted
                         ? "Paused — something else took the microphone."
                         : "Recording… speak items, tap Stop when done.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                    Spacer()
                }

                levelMeter
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
        } else if dictation.isTranscribing {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(DesignSystem.Colors.dillGreen)
                Text("Transcribing…")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
        } else if case .denied(let reason) = dictation.authState {
            Text(reason)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DesignSystem.Colors.neonPink)
                .padding(.horizontal, 20)
                .padding(.top, 6)
        } else if let err = dictation.errorMessage {
            Text(err)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DesignSystem.Colors.neonPink)
                .padding(.horizontal, 20)
                .padding(.top, 6)
        }
    }

    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
            return
        }
        if dictation.isTranscribing { return }
        editorFocused = false
        Task {
            if case .granted = dictation.authState {
                dictation.start()
                return
            }
            await dictation.requestAuth()
            if case .granted = dictation.authState {
                dictation.start()
            }
        }
    }

    private func imagePreviewSection(image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Image ready — tap Scan to extract items")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .padding(.horizontal, 20)

            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)

                Button(action: { selectedImage = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                }
                .padding(.trailing, 28)
                .padding(.top, 8)
            }
        }
    }

    private func imageSourceButton(icon: String, label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DesignSystem.Colors.textSecondary)
            .frame(width: 68, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .opacity(disabled ? 0.3 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var parseButton: some View {
        Button(action: startParsing) {
            HStack(spacing: 10) {
                Image(systemName: selectedImage != nil ? "eye" : "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                Text(selectedImage != nil ? "Scan Image" : "Parse Items")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(hasInput ? .white : .white.opacity(0.3))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(hasInput ? DesignSystem.Colors.dillGreen.opacity(0.2) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                hasInput ? DesignSystem.Colors.dillGreen.opacity(0.6) : Color.white.opacity(0.1),
                                lineWidth: 1.5
                            )
                    )
            )
        }
        .disabled(!hasInput)
        .buttonStyle(.plain)
    }

    // MARK: - Parsing Phase

    private var parsingView: some View {
        VStack(spacing: 20) {
            Spacer()

            // Show the thing being worked on, so the wait has an object.
            if let image = selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(DesignSystem.Colors.dillGreen.opacity(0.4), lineWidth: 1.5)
                    )
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(DesignSystem.Colors.dillGreen.opacity(0.6))
            }

            VStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(DesignSystem.Colors.dillGreen)

                Text(selectedImage != nil ? "Reading the image…" : "Sorting out what you said…")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)

                Text("Keep this open — it takes a few seconds")
                    .font(.system(size: 12))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Swallow drags so the sheet cannot be flung away by accident.
        .gesture(DragGesture())
    }

    // MARK: - Review Phase

    private var reviewView: some View {
        VStack(spacing: 0) {
            // Summary bar
            HStack {
                Text("\(ingredients.count) item\(ingredients.count == 1 ? "" : "s") found")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.dillGreen)

                Spacer()

                Button(action: toggleAll) {
                    Text(selectedCount == ingredients.count ? "Deselect All" : "Select All")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // Items list — confident first, anything the parser guessed at below.
            // Splitting them is the point: reviewing every item is as useless as
            // reviewing none, so only the uncertain ones ask for attention.
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($ingredients) { $item in
                        if !item.isUnresolved {
                            IngredientReviewRow(item: $item, viewModel: viewModel)
                        }
                    }

                    // A dish's ingredients arrive as one thought, so they should
                    // be reviewed as one — a card you accept or trim, not eight
                    // separate interrogations.
                    ForEach(intentGroups, id: \.self) { intent in
                        IntentGroupCard(
                            intent: intent,
                            ingredients: $ingredients
                        )
                    }

                    if ungroupedUnresolvedCount > 0 {
                        needsInputHeader

                        ForEach($ingredients) { $item in
                            if item.isUnresolved && !isGrouped(item) {
                                NeedsInputRow(item: $item, viewModel: viewModel)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 100) // space for button
            }

            // Add button
            VStack(spacing: 0) {
                Divider().background(Color.white.opacity(0.1))
                addButton
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
            }
            .background(DesignSystem.Colors.background)
        }
    }

    private var unresolvedCount: Int {
        ingredients.filter(\.isUnresolved).count
    }

    /// An intent the parser expanded into several items — "for burritos". Only a
    /// group of two or more is worth a card; a lone item reads better as a row.
    private var intentGroups: [String] {
        let counts = Dictionary(grouping: ingredients.filter { $0.isUnresolved && $0.heardAs != nil },
                                by: { $0.heardAs! })
        return counts.filter { $0.value.count >= 2 }.keys.sorted()
    }

    private func isGrouped(_ item: ParsedIngredient) -> Bool {
        guard let h = item.heardAs else { return false }
        return intentGroups.contains(h)
    }

    private var ungroupedUnresolvedCount: Int {
        ingredients.filter { $0.isUnresolved && !isGrouped($0) }.count
    }

    private var needsInputHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("NOT SURE ABOUT \(unresolvedCount)")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.5)
            Spacer()
        }
        .foregroundColor(DesignSystem.Colors.warning)
        .padding(.top, 20)
        .padding(.bottom, 2)
    }

    private var addButton: some View {
        Button(action: addSelectedItems) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                VStack(spacing: 1) {
                    Text(selectedCount == 0 ? "No Items Selected" : "Add \(selectedCount) Item\(selectedCount == 1 ? "" : "s")")
                        .font(.system(size: 17, weight: .semibold))
                    // Don't let a guess in silently — say how many are unanswered.
                    if unresolvedCount > 0 && selectedCount > 0 {
                        Text("\(unresolvedCount) unanswered — best guess will be used")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.warning)
                    }
                }
            }
            .foregroundColor(selectedCount == 0 ? .white.opacity(0.3) : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        selectedCount == 0
                        ? Color.white.opacity(0.05)
                        : DesignSystem.Colors.dillGreen.opacity(0.2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                selectedCount == 0
                                ? Color.white.opacity(0.1)
                                : DesignSystem.Colors.dillGreen.opacity(0.6),
                                lineWidth: 1.5
                            )
                    )
            )
        }
        .disabled(selectedCount == 0)
        .buttonStyle(.plain)
    }

    // MARK: - Adding Phase

    private func addingView(done: Int, total: Int) -> some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(DesignSystem.Colors.dillGreen)
                    .padding(.horizontal, 40)

                Text("Adding \(done) of \(total) items...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            Spacer()
        }
    }

    // MARK: - Actions

    private func startParsing() {
        errorMessage = nil
        editorFocused = false
        phase = .parsing

        Task {
            do {
                var items: [ParsedIngredient]
                if let image = selectedImage {
                    items = try await callParseIngredients(image: image)
                } else {
                    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        await MainActor.run { phase = .input }
                        return
                    }
                    items = try await callParseIngredients(text: text)
                }

                for i in items.indices {
                    if let match = ProductCache.shared.findMatchingProduct(for: items[i].name) {
                        items[i].productId = match.id
                    }
                }
                await MainActor.run {
                    if items.isEmpty {
                        errorMessage = "Nothing to add — this reads what you paste, it doesn't write recipes."
                        phase = .input
                    } else {
                        ingredients = items
                        phase = .review(items)
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to parse. Please try again."
                    phase = .input
                }
            }
        }
    }

    private func toggleAll() {
        let allSelected = selectedCount == ingredients.count
        for i in ingredients.indices {
            ingredients[i].isSelected = !allSelected
        }
    }

    private func addSelectedItems() {
        let selected = ingredients.filter(\.isSelected)
        guard !selected.isEmpty else { return }

        let total = selected.count
        phase = .adding(done: 0, total: total)

        if let onCommit {
            // Names only. Folding the quantity in produced "Salt — ½ teaspoon",
            // which is a recipe measurement, not a shopping instruction — you buy
            // a box of salt. It also broke deduplication, since "Milk — 2 cups"
            // and "Milk" are different strings.
            onCommit(selected.map { $0.name })
            isPresented = false
            return
        }

        Task {
            for (i, item) in selected.enumerated() {
                await viewModel.addItem(name: item.name, quantity: item.quantity, notes: item.notes, productId: item.productId)
                await MainActor.run {
                    phase = .adding(done: i + 1, total: total)
                }
            }
            await MainActor.run {
                rawText = ""
                isPresented = false
            }
        }
    }

    // MARK: - GraphQL

    private func callParseIngredients(text: String) async throws -> [ParsedIngredient] {
        let document = """
        mutation ParseIngredients($rawText: String!, $knownTerms: [String]) {
            parseIngredients(rawText: $rawText, knownTerms: $knownTerms)
        }
        """

        let knownTerms = ProductCache.shared.products.map { $0.normalizedName }
        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["rawText": text, "knownTerms": knownTerms],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            return extractIngredients(from: json)
        case .failure(let error):
            if case GraphQLResponseError<JSONValue>.partial(let json, _) = error {
                return extractIngredients(from: json)
            }
            if case GraphQLResponseError<JSONValue>.transformationError(let raw, _) = error {
                return try extractIngredientsFromRaw(raw)
            }
            throw error
        }
    }

    private func callParseIngredients(image: UIImage) async throws -> [ParsedIngredient] {
        guard let jpegData = resizeImage(image) else {
            throw NSError(domain: "BulkImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to process image"])
        }
        let base64 = jpegData.base64EncodedString()

        // rawText is required in schema until Amplify Console deploys the schema update —
        // passing empty string; Lambda ignores it when imageData is present.
        let document = """
        mutation ParseIngredients($rawText: String!, $knownTerms: [String], $imageData: String) {
            parseIngredients(rawText: $rawText, knownTerms: $knownTerms, imageData: $imageData)
        }
        """

        let knownTerms = ProductCache.shared.products.map { $0.normalizedName }
        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["rawText": "", "knownTerms": knownTerms, "imageData": base64],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            return extractIngredients(from: json)
        case .failure(let error):
            if case GraphQLResponseError<JSONValue>.partial(let json, _) = error {
                return extractIngredients(from: json)
            }
            if case GraphQLResponseError<JSONValue>.transformationError(let raw, _) = error {
                return try extractIngredientsFromRaw(raw)
            }
            throw error
        }
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat = 1568) -> Data? {
        let size = image.size
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.85)
    }

    private func extractIngredients(from json: JSONValue) -> [ParsedIngredient] {
        guard case .object(let root) = json else { return [] }
        switch root["parseIngredients"] {
        case .array(let array):
            return array.compactMap { element -> ParsedIngredient? in
                guard case .object(let obj) = element,
                      case .string(let name) = obj["name"] else { return nil }
                let qty: String? = { if case .string(let q) = obj["quantity"] { return q }; return nil }()
                let notes: String? = { if case .string(let q) = obj["qualifier"] { return q }; return nil }()
                let heard: String? = { if case .string(let h) = obj["heardAs"] { return h }; return nil }()
                let needs: Bool = { if case .boolean(let b) = obj["needsInput"] { return b }; return false }()
                let alts: [String] = {
                    guard case .array(let a) = obj["alternatives"] else { return [] }
                    return a.compactMap { if case .string(let v) = $0 { return v }; return nil }
                }()
                let staple: Bool = { if case .boolean(let b) = obj["staple"] { return b }; return false }()
                return ParsedIngredient(name: name, quantity: qty, notes: notes,
                                        heardAs: heard, needsInput: needs, alternatives: alts,
                                        isStaple: staple)
            }
        case .string(let s):
            guard let data = s.data(using: .utf8),
                  let items = try? JSONDecoder().decode([_RawItem].self, from: data) else { return [] }
            return items.map {
                ParsedIngredient(name: $0.name, quantity: $0.quantity, notes: $0.qualifier,
                                 heardAs: $0.heardAs, needsInput: $0.needsInput ?? false,
                                 alternatives: $0.alternatives ?? [],
                                 isStaple: $0.staple ?? false)
            }
        default:
            return []
        }
    }

    private func extractIngredientsFromRaw(_ raw: String) throws -> [ParsedIngredient] {
        guard let data = raw.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = obj["data"] as? [String: Any] else { return [] }

        if let str = dataObj["parseIngredients"] as? String {
            guard let itemData = str.data(using: .utf8) else { return [] }
            let items = try JSONDecoder().decode([_RawItem].self, from: itemData)
            return items.map {
                ParsedIngredient(name: $0.name, quantity: $0.quantity, notes: $0.qualifier,
                                 heardAs: $0.heardAs, needsInput: $0.needsInput ?? false,
                                 alternatives: $0.alternatives ?? [],
                                 isStaple: $0.staple ?? false)
            }
        } else if let arr = dataObj["parseIngredients"] as? [[String: Any]] {
            return arr.compactMap { obj -> ParsedIngredient? in
                guard let name = obj["name"] as? String else { return nil }
                return ParsedIngredient(name: name, quantity: obj["quantity"] as? String, notes: obj["qualifier"] as? String,
                                        heardAs: obj["heardAs"] as? String,
                                        needsInput: obj["needsInput"] as? Bool ?? false,
                                        alternatives: obj["alternatives"] as? [String] ?? [],
                                        isStaple: obj["staple"] as? Bool ?? false)
            }
        }
        return []
    }
}

private struct _RawItem: Decodable {
    let name: String
    let quantity: String?
    let qualifier: String?
    let heardAs: String?
    let needsInput: Bool?
    let alternatives: [String]?
    let staple: Bool?
}

// MARK: - Ingredient Review Row

private struct IngredientReviewRow: View {
    @Binding var item: ParsedIngredient
    let viewModel: ShoppingListViewModel

    private var nameLabel: Text {
        if let notes = item.notes, !notes.isEmpty {
            return (Text(item.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(item.isSelected ? .white : DesignSystem.Colors.textSecondary)
            + Text(" · ")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textTertiary)
            + Text(notes)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textTertiary))
            .strikethrough(!item.isSelected, color: DesignSystem.Colors.textTertiary)
        } else {
            return Text(item.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(item.isSelected ? .white : DesignSystem.Colors.textSecondary)
                .strikethrough(!item.isSelected, color: DesignSystem.Colors.textTertiary)
        }
    }

    var body: some View {
        rowContent
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(item.isSelected ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
            )
            .animation(.easeInOut(duration: 0.15), value: item.isSelected)
    }

    private var rowContent: some View {
        // Three things only: is it coming, what is it, how much. Everything else
        // that used to live here — a catalog badge, an expand chevron, an
        // ellipsis to a detail sheet — was noise on a screen you look at once
        // and then never again.
        HStack(spacing: 12) {
            Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 21))
                .foregroundColor(item.isSelected
                                 ? DesignSystem.Colors.dillGreen
                                 : DesignSystem.Colors.textTertiary.opacity(0.5))

            nameLabel
                .opacity(item.isSelected ? 1 : 0.45)

            Spacer(minLength: 8)

            // Says why it arrived unticked. Without it an unchecked row looks
            // like the parser failed rather than made a guess about your cupboard.
            if item.isStaple && !item.isSelected {
                Text("probably have")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            }

            if let qty = item.quantity, !qty.isEmpty {
                Text(qty)
                    .font(.system(size: 13))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .opacity(item.isSelected ? 1 : 0.45)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture { item.isSelected.toggle() }
    }
}

// MARK: - Ingredient Detail Sheet

private struct IngredientDetailSheet: View {
    @Binding var item: ParsedIngredient
    @Environment(\.dismiss) var dismiss

    @State private var editName: String
    @State private var editQuantity: String
    @State private var editNotes: String

    init(item: Binding<ParsedIngredient>) {
        self._item = item
        self._editName = State(initialValue: item.wrappedValue.name)
        self._editQuantity = State(initialValue: item.wrappedValue.quantity ?? "")
        self._editNotes = State(initialValue: item.wrappedValue.notes ?? "")
    }

    var body: some View {
        NavigationView {
            ZStack {
                DesignSystem.Colors.background.ignoresSafeArea()
                DesignSystem.Colors.darkMetallicGradient.ignoresSafeArea().opacity(0.3)

                ScrollView {
                    VStack(spacing: 0) {
                        // Item name header
                        Text(editName.isEmpty ? item.name : editName)
                            .font(DesignSystem.Typography.title2)
                            .foregroundColor(DesignSystem.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DesignSystem.Spacing.lg)
                            .padding(.top, DesignSystem.Spacing.md)
                            .padding(.bottom, DesignSystem.Spacing.lg)

                        Divider().background(DesignSystem.Colors.glassBorder)

                        VStack(spacing: DesignSystem.Spacing.lg) {
                            fieldSection(label: "Name") {
                                TextField("Item name", text: $editName)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundColor(DesignSystem.Colors.textPrimary)
                                    .padding(DesignSystem.Spacing.md)
                                    .background(fieldBackground)
                            }

                            fieldSection(label: "Quantity") {
                                TextField("e.g. 2, 1 lb, 3 cups", text: $editQuantity)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundColor(DesignSystem.Colors.textPrimary)
                                    .padding(DesignSystem.Spacing.md)
                                    .background(fieldBackground)
                            }

                            fieldSection(label: "Notes") {
                                TextField("Add notes (e.g., Kosher, Large size, Brand: Heinz)", text: $editNotes, axis: .vertical)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundColor(DesignSystem.Colors.textPrimary)
                                    .lineLimit(3...6)
                                    .padding(DesignSystem.Spacing.md)
                                    .background(fieldBackground)
                            }
                        }
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.top, DesignSystem.Spacing.lg)
                        .padding(.bottom, DesignSystem.Spacing.xxl)
                    }
                }
            }
            .navigationTitle("Item Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        let trimmedName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedName.isEmpty { item.name = trimmedName }
                        let trimmedQty = editQuantity.trimmingCharacters(in: .whitespacesAndNewlines)
                        item.quantity = trimmedQty.isEmpty ? nil : trimmedQty
                        let trimmedNotes = editNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                        item.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                    .font(DesignSystem.Typography.headline)
                }
            }
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
            .fill(DesignSystem.Colors.glassBackground)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
            )
    }

    private func fieldSection<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(label)
                .font(DesignSystem.Typography.footnote)
                .foregroundColor(DesignSystem.Colors.textSecondary)
            content()
        }
    }
}

// MARK: - Camera Picker

private struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Needs Input Row

/// A row for something the parser couldn't resolve from the transcript alone.
/// Two shapes: pick-one when the words genuinely support several products, and
/// plain confirm when it repaired a probable mis-hearing.
struct NeedsInputRow: View {
    @Binding var item: ParsedIngredient
    let viewModel: ShoppingListViewModel

    private var accent: Color { DesignSystem.Colors.warning }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // What was actually said, so the user can judge the guess.
            if let heard = item.heardAs, !heard.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                    Text("You said “\(heard)”")
                        .font(.system(size: 12, weight: .medium))
                        .italic()
                    Spacer(minLength: 0)
                }
                .foregroundColor(DesignSystem.Colors.textTertiary)
            }

            if item.alternatives.count > 1 {
                Text("Which did you mean?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)

                // Best-first, so the thing this household actually buys leads.
                FlowRow(spacing: 8) {
                    ForEach(item.alternatives, id: \.self) { choice in
                        Button {
                            item.name = choice
                            item.resolved = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text(choice)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(DesignSystem.Colors.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    Capsule()
                                        .fill(accent.opacity(0.12))
                                        .overlay(Capsule().stroke(accent.opacity(0.45), lineWidth: 1))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                // Nothing to choose between — it repaired a mis-hearing and
                // wants a nod before treating it as fact.
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textPrimary)
                    if let q = item.quantity, !q.isEmpty {
                        Text(q)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Button {
                        item.resolved = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Label("Yes", systemImage: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.success)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(DesignSystem.Colors.success.opacity(0.12))
                                    .overlay(Capsule().stroke(DesignSystem.Colors.success.opacity(0.45), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        item.isSelected = false
                        item.resolved = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Label("Skip", systemImage: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(accent.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(accent.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

/// Wraps chips onto as many lines as they need. The alternatives are product
/// names of unpredictable length, so a fixed HStack would clip them.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Intent Group Card

/// The ingredients the parser inferred from one spoken intent — "I'm making
/// burritos" — presented as the single thought they came from. Accept the lot,
/// or uncheck the two you already have. Beats eight separate Yes/Skip rows for
/// what was, to the speaker, one sentence.
struct IntentGroupCard: View {
    let intent: String
    @Binding var ingredients: [ParsedIngredient]

    private var accent: Color { DesignSystem.Colors.neonPurple }

    private var members: [ParsedIngredient] {
        ingredients.filter { $0.isUnresolved && $0.heardAs == intent }
    }

    /// "for burritos" → "Burritos". The parser phrases it for a sentence; the
    /// card wants a title.
    private var title: String {
        var t = intent
        for prefix in ["for the ", "for a ", "for ", "to make "] {
            if t.lowercased().hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count))
                break
            }
        }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(DesignSystem.Colors.textPrimary)
                    Text("You didn't name these — we guessed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }

                Spacer(minLength: 0)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    for i in ingredients.indices where ingredients[i].heardAs == intent && ingredients[i].isUnresolved {
                        ingredients[i].resolved = true
                    }
                } label: {
                    Text("Add all \(members.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(accent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(accent.opacity(0.14))
                                .overlay(Capsule().stroke(accent.opacity(0.45), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 0) {
                ForEach(members) { member in
                    HStack(spacing: 10) {
                        Button {
                            guard let i = ingredients.firstIndex(where: { $0.id == member.id }) else { return }
                            ingredients[i].resolved = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 19))
                                .foregroundColor(accent)
                        }
                        .buttonStyle(.plain)

                        Text(member.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.textPrimary)

                        if let q = member.quantity, !q.isEmpty {
                            Text(q)
                                .font(.system(size: 12))
                                .foregroundColor(DesignSystem.Colors.textTertiary)
                        }

                        Spacer(minLength: 0)

                        Button {
                            guard let i = ingredients.firstIndex(where: { $0.id == member.id }) else { return }
                            ingredients[i].isSelected = false
                            ingredients[i].resolved = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DesignSystem.Colors.textTertiary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 7)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(accent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(accent.opacity(0.35), lineWidth: 1)
                )
        )
        .padding(.top, 14)
    }
}
