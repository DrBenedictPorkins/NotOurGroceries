import SwiftUI
import UIKit

/// Mode for ItemDetailSheet - normal editing or proposed aisle review
enum ItemDetailMode {
    case normal
    case proposedAisle(result: AisleExtractionService.AisleInferenceResult, store: HouseholdStore)
}

struct ItemDetailSheet: View {
    let item: GroceryItem
    var mode: ItemDetailMode = .normal
    var onAisleChanged: ((String) -> Void)? = nil  // Callback when user changes proposed aisle

    @EnvironmentObject var viewModel: ShoppingListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var notesText: String = ""
    @State private var notesEphemeral: Bool = false
    @State private var aisleText: String = ""
    /// On-device speech, only for the aisle field. Not the Whisper path used to
    /// dictate a whole list: this is used standing in a shop, where the signal
    /// goes first, and it can be told the store's own aisle names so it stops
    /// hearing "sixty" for "sixteen".
    @StateObject private var aisleSpeech = AisleSpeechService()
    /// What the model proposed, kept because the batch sheet overwrites
    /// `suggestedAisle` with whatever the person types next.
    @State private var originalSuggestion: String?
    @State private var isHoldingToTalk = false
    /// What the aisle was before the last change, so it can be put back.
    @State private var undoTarget: String??
    @State private var waveAnimating = false

    /// Five bars at rest; they grow while listening.
    private var waveHeights: [CGFloat] {
        waveAnimating ? [14, 20, 9, 17, 12] : [4, 4, 4, 4, 4]
    }


    /// Whether we're in proposed aisle mode (from batch mapping)
    private var isProposedAisleMode: Bool {
        if case .proposedAisle = mode { return true }
        return false
    }

    /// True once the person has changed the aisle the model proposed.
    ///
    /// Everything the model said — the label, its reasoning, its confidence —
    /// describes the value it picked. The moment that value is replaced, all
    /// three describe something that is no longer on screen: a 95% confidence
    /// about the pharmacy aisle sitting under the number 7. Keeping them would
    /// assert a certainty nobody has.
    private var hasReplacedSuggestion: Bool {
        guard let original = originalSuggestion else { return false }
        let now = aisleText.trimmingCharacters(in: .whitespaces)
        guard !now.isEmpty else { return false }
        return AisleUtterance.normalise(now).caseInsensitiveCompare(
            AisleUtterance.normalise(original)
        ) != .orderedSame
    }

    /// The proposed aisle result (if in proposed mode)
    private var proposedAisleResult: AisleExtractionService.AisleInferenceResult? {
        if case .proposedAisle(let result, _) = mode { return result }
        return nil
    }

    /// The store for proposed aisle mode
    private var proposedStore: HouseholdStore? {
        if case .proposedAisle(_, let store) = mode { return store }
        return nil
    }

    // Photos State
    @State private var showImageSourcePicker = false
    @State private var showCamera = false
    @State private var showPhotoLibrary = false
    @State private var selectedFullScreenImage: (image: UIImage, metadata: ItemImage)? = nil
    @State private var imageToDelete: ItemImage? = nil
    @State private var loadedImages: [String: UIImage] = [:]  // Cache: imageId -> UIImage
    @State private var isUploadingImage = false
    @State private var pendingUploadImage: UIImage? = nil  // Thumbnail shown during upload

    private var currentUserId: String {
        AmplifyService.shared.currentUser?.userId ?? ""
    }

    /// Get the current household store - uses proposed store, shopping store, or first store
    private var currentStore: HouseholdStore? {
        // If in proposed aisle mode, use the proposed store
        if let store = proposedStore {
            return store
        }
        // If in shopping mode, use the store being shopped at
        if let shoppingStoreId = viewModel.shoppingStoreId {
            return viewModel.householdStores.first { $0.id == shoppingStoreId }
        }
        // Otherwise use the first available store
        return viewModel.householdStores.first
    }

    /// Whether there is anywhere to put this item.
    ///
    /// Every store carries the named departments, so this is only false when no
    /// store is selected at all — it is a nil guard rather than a kind of shop.
    private var storeSupportsAisles: Bool {
        !(currentStore?.aisleLayout.isEmpty ?? true)
    }

    /// Aisle UI only makes sense in proposed mode, or while shopping at an aisle-based store.
    private var showAisleSection: Bool {
        guard storeSupportsAisles else { return false }
        if isProposedAisleMode { return true }
        return viewModel.shoppingStatus == .atStore && currentStore != nil
    }

    /// Get the current aisle mapping for this item
    private var currentMapping: ProductAisleMapping? {
        guard let store = currentStore else { return nil }
        let mappings = StoreService.shared.productMappings[store.id] ?? []

        // Find mapping by productId or normalizedName
        return mappings.first { mapping in
            if let productId = item.productId, let mappingProductId = mapping.productId {
                return productId == mappingProductId
            }
            if let mappingName = mapping.normalizedName {
                return item.normalizedName == mappingName
            }
            return false
        }
    }

    /// Get the effective aisle string for display
    private var currentAisleString: String? {
        currentMapping?.effectiveAisle
    }

    /// Get current images from viewModel (updates after upload)
    private var currentImages: [ItemImage] {
        viewModel.items.first(where: { $0.id == item.id })?.images ?? item.images
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    // Item header
                    itemHeader

                    Divider()
                        .background(DesignSystem.Colors.glassBorder)

                    // Metadata section
                    metadataSection

                    // Aisle section (show when in proposed mode or actively shopping at a store).
                    // Hidden entirely when the active store has no aisles.
                    if showAisleSection {
                        Divider()
                            .background(DesignSystem.Colors.glassBorder)

                        aisleSection
                    }

                    Divider()
                        .background(DesignSystem.Colors.glassBorder)

                    // Notes section
                    notesSection

                    Divider()
                        .background(DesignSystem.Colors.glassBorder)

                    // Photos section
                    photosSection

                    Spacer(minLength: DesignSystem.Spacing.xl)
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .background(DesignSystem.Colors.background.ignoresSafeArea())
            .navigationTitle("Item Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        saveNotesAndDismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                }
            }
            .onAppear {
                notesText = item.notes ?? ""
                notesEphemeral = item.notesEphemeral
                // Both branches resolve through AisleNaming. The proposed one
                // used to show `suggestedAisle` raw, which is a storage id — so
                // an AI suggestion offered "standard-produce" as the answer to
                // "which aisle is this in", while the non-proposed branch beside
                // it had been showing a real name for weeks.
                if let proposed = proposedAisleResult {
                    aisleText = AisleNaming.displayName(
                        for: proposed.suggestedAisle,
                        in: currentStore?.aisleLayout ?? []
                    )
                    if originalSuggestion == nil { originalSuggestion = aisleText }
                } else {
                    aisleText = currentAisleText
                }
                loadImages()
            }
            .confirmationDialog("Add Photo", isPresented: $showImageSourcePicker, titleVisibility: .visible) {
                if ImagePicker.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") {
                        showCamera = true
                    }
                }
                Button("Choose from Library") {
                    showPhotoLibrary = true
                }
                Button("Cancel", role: .cancel) {}
            }
            .fullScreenCover(isPresented: $showCamera) {
                ImagePicker(
                    sourceType: .camera,
                    onImageSelected: { data in
                        showCamera = false
                        uploadImage(data)
                    },
                    onCancel: {
                        showCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showPhotoLibrary) {
                ImagePicker(
                    sourceType: .photoLibrary,
                    onImageSelected: { data in
                        showPhotoLibrary = false
                        uploadImage(data)
                    },
                    onCancel: {
                        showPhotoLibrary = false
                    }
                )
                .ignoresSafeArea()
            }
            .fullScreenCover(item: Binding(
                get: { selectedFullScreenImage.map { FullScreenImageWrapper(image: $0.image, metadata: $0.metadata) } },
                set: { _ in selectedFullScreenImage = nil }
            )) { wrapper in
                FullScreenImageView(
                    image: wrapper.image,
                    itemImage: wrapper.metadata,
                    onDismiss: { selectedFullScreenImage = nil }
                )
            }
            .alert("Delete Photo", isPresented: Binding(
                get: { imageToDelete != nil },
                set: { if !$0 { imageToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let image = imageToDelete {
                        deleteImage(image)
                    }
                }
                Button("Cancel", role: .cancel) {
                    imageToDelete = nil
                }
            } message: {
                Text("Are you sure you want to delete this photo?")
            }
        }
    }

    // MARK: - Save and Dismiss

    private func saveNotesAndDismiss() {
        let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNotes: String? = trimmedNotes.isEmpty ? nil : trimmedNotes

        // Only save if notes or their lifetime changed
        if newNotes != item.notes || notesEphemeral != item.notesEphemeral {
            Task {
                await viewModel.updateNotes(for: item, notes: newNotes, ephemeral: notesEphemeral)
            }
        }
        dismiss()
    }

    // MARK: - Item Header

    private var itemHeader: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text(item.name)
                .font(DesignSystem.Typography.title2)
                .foregroundColor(DesignSystem.Colors.textPrimary)

            if item.lockedBy != nil {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14))
                    .foregroundColor(DesignSystem.Colors.neonAmber)
            }

            Spacer()
        }
    }

    // MARK: - Metadata Section

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            metadataRow(
                label: "Added by",
                value: "\(UserCache.shared.displayName(for: item.addedBy)) \(formattedDate(item.addedAt))"
            )

            if let lockedBy = item.lockedBy {
                metadataRow(
                    label: "Locked by",
                    value: UserCache.shared.displayName(for: lockedBy),
                    valueColor: DesignSystem.Colors.neonAmber
                )
            }

            if item.status == .inCart {
                metadataRow(
                    label: "Status",
                    value: "In Cart",
                    valueColor: DesignSystem.Colors.dillGreen
                )
            } else if item.status == .suggestion {
                metadataRow(
                    label: "Status",
                    value: "Suggestion",
                    valueColor: DesignSystem.Colors.neonAmber
                )
            }
        }
    }

    private func metadataRow(label: String, value: String, valueColor: Color = DesignSystem.Colors.textSecondary) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(DesignSystem.Typography.subheadline)
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(DesignSystem.Typography.subheadline)
                .foregroundColor(valueColor)

            Spacer()
        }
    }

    // MARK: - Aisle Section

    private var aisleSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Aisle")
                    .font(DesignSystem.Typography.headline)
                    .foregroundColor(DesignSystem.Colors.textPrimary)

                if isProposedAisleMode && !hasReplacedSuggestion {
                    Text("(AI Suggested)")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.neonPurple)
                }
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                TextField("e.g., 1, A1, Bakery, Back Wall", text: $aisleText)
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                    .onSubmit {
                        if isProposedAisleMode {
                            handleProposedAisleChange()
                        } else {
                            saveAisle()
                        }
                    }
                    .onChange(of: aisleText) { _, newValue in
                        // In proposed mode, notify parent of changes
                        if isProposedAisleMode {
                            onAisleChanged?(newValue)
                        }
                    }
                    // Words land in the field as they are recognised, run
                    // through the same normalising as anything typed: "aisle
                    // sixteen" and "16" have to reach one aisle, or the store
                    // grows a 16 and a Sixteen holding half the items each.
                    .onChange(of: aisleSpeech.transcript) { _, spoken in
                        guard !spoken.isEmpty else { return }
                        aisleText = AisleUtterance.normalise(spoken)
                    }

                if !aisleText.isEmpty && !isProposedAisleMode {
                    Button {
                        aisleText = ""
                        Task {
                            await clearAisleAssignment()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                    }
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                    .fill(isProposedAisleMode ? DesignSystem.Colors.neonPurple.opacity(0.1) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                            .stroke(isProposedAisleMode ? DesignSystem.Colors.neonPurple : DesignSystem.Colors.glassBorder, lineWidth: isProposedAisleMode ? 2 : 1)
                    )
            )

            // Show AI confidence info in proposed mode
            if isProposedAisleMode, !hasReplacedSuggestion, let result = proposedAisleResult {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundColor(DesignSystem.Colors.neonPurple)
                    Text(result.reasoning)
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                    Spacer()
                    Text("\(Int(result.confidence * 100))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(result.confidence >= 0.7 ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                }
                .padding(.horizontal, DesignSystem.Spacing.xs)
            }

            // Shown in review mode too. Correcting a batch is exactly where one
            // tap per row pays, and the aisles are already on screen.
            numberStrip

            if aisleSpeech.isAvailable {
                holdToTalkPill

                // Said out loud. A microphone that cannot listen used to set
                // this reason and show nothing, so holding the pill looked
                // identical to the feature simply not working.
                if case .unavailable(let reason) = aisleSpeech.state {
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundColor(DesignSystem.Colors.neonPink)
                }
            }

            // What it actually heard, when that is not what the field now shows.
            // "aisle sixteen" becoming 16 is correct but looks like a misfire
            // unless the original is visible next to it.
            if !aisleSpeech.transcript.isEmpty,
               aisleSpeech.transcript.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(aisleText) != .orderedSame {
                HStack(spacing: 6) {
                    Text("Heard")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                    Text("\u{201C}\(aisleSpeech.transcript)\u{201D}")
                        .font(.system(size: 13))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
            }

            if let outcome = saveOutcome {
                HStack(spacing: 8) {
                    Text(isProposedAisleMode ? "Changes to" : "Saves to")
                        .font(.system(size: 13))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                    Text(outcome.label)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(DesignSystem.Colors.background)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(outcome.isNew
                                                   ? DesignSystem.Colors.neonAmber
                                                   : DesignSystem.Colors.dillGreen))
                    Text(outcome.note)
                        .font(.system(size: 11))
                        .foregroundColor(DesignSystem.Colors.textTertiary)

                    Spacer()

                    if undoTarget != nil {
                        Button("Undo") { undoLastChange() }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.neonAmber)
                    }
                }
            }

            Text(hintText)
                .font(DesignSystem.Typography.caption)
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
    }

    /// Where the current text will land, resolved the same way saving resolves it.
    private var saveOutcome: (label: String, note: String, isNew: Bool)? {
        let text = aisleText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        switch AisleUtterance.resolve(text, in: currentStore?.aisleLayout ?? []) {
        case .existing(let aisle):
            return (AisleNaming.displayName(for: aisle.id, in: currentStore?.aisleLayout ?? []),
                    "already an aisle here", false)
        case .new(let number, let name):
            return (number.isEmpty ? name : "Aisle \(number)", "new — added to the end", true)
        case .rejected:
            return nil
        }
    }

    private var hintText: String {
        if hasReplacedSuggestion { return "Your aisle. It replaces what was suggested." }
        if isProposedAisleMode { return "Say or type a different aisle to change the suggestion" }
        return "Say it or type it — an aisle number, or what the section is called"
    }

    /// Handle aisle change in proposed mode - just updates text, actual save happens on batch apply
    private func handleProposedAisleChange() {
        let trimmed = aisleText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onAisleChanged?(trimmed)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }


    /// The current aisle as display text
    /// What the field shows — and therefore what has to be typeable back in.
    ///
    /// It used to show `currentAisleString`, which is the raw storage id, so the
    /// field read "standard-bakery". Resolving it means the lookup on save has to
    /// accept the resolved form too, or typing back what you were shown creates a
    /// second aisle called "Aisle 15".
    private var currentAisleText: String {
        guard let raw = currentAisleString, !raw.isEmpty else { return "" }
        return AisleNaming.displayName(for: raw, in: currentStore?.aisleLayout ?? [])
    }

    /// Applies a choice straight away and keeps what it replaced.
    ///
    /// There is no Save. A picker that needs confirming is two taps for one
    /// decision, and the decision is cheap to reverse — Undo puts back exactly
    /// what was there, including nothing.
    private func apply(_ aisle: String) {
        undoTarget = .some(currentAisleString)
        aisleText = AisleUtterance.normalise(aisle)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Review mode writes nothing here. The correction rides in the pending
        // result — `onAisleChanged` picks it up off the field — and lands with
        // Apply & Continue next to the suggestions you left alone. A chip that
        // wrote straight through would commit part of a batch you had not
        // agreed to yet, and Cancel would no longer cancel.
        guard !isProposedAisleMode else { return }
        Task { await assignToAisleByName(aisleText) }
    }

    private func undoLastChange() {
        guard let previous = undoTarget else { return }
        undoTarget = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let restored = (previous?.isEmpty == false)
            ? AisleNaming.displayName(for: previous!, in: currentStore?.aisleLayout ?? [])
            : ""

        guard !isProposedAisleMode else {
            aisleText = restored
            return
        }

        Task {
            if !restored.isEmpty {
                aisleText = restored
                await assignToAisleByName(aisleText)
            } else {
                aisleText = ""
                await clearAisleAssignment()
            }
        }
    }

    private func saveAisle() {
        let trimmed = aisleText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        Task {
            await assignToAisleByName(trimmed)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// Assign item to aisle by name - creates the aisle if it doesn't exist
    ///
    /// Every exit from here used to be silent: three bare `return`s and a
    /// `catch { print }`. On a weak connection the mutation threw, the message
    /// went to a console nobody can see, and the sheet just sat there — reported
    /// from a real shop as "aisle save does not work". A save that did not happen
    /// has to say so; there is no version of this where silence is right.
    private func assignToAisleByName(_ aisleName: String) async {
        guard var store = currentStore else {
            reportAisleFailure("No store selected — pick one before setting an aisle.")
            return
        }

        // One matcher, shared with dictation, so typing and saying the same thing
        // land in the same place. Exact first — number, name, id, this screen's
        // rendering — then a looser pass, which is what stops "Dairy" creating a
        // rival to the "Dairy & Eggs" department that is already there. It also
        // decides whether the words are an aisle number or a department name;
        // writing a name into `number` is what produced an aisle called "Dairy"
        // sitting next to "Dairy & Eggs".
        let targetAisle: StoreAisle
        switch AisleUtterance.resolve(aisleName, in: store.aisleLayout) {
        case .existing(let existing):
            targetAisle = existing

        case .new(let number, let name):
            do {
                store = try await StoreService.shared.addAisle(to: store, number: number, name: name)
                guard let created = store.aisleLayout.last else {
                    reportAisleFailure("Couldn't find or create aisle \(aisleName).")
                    return
                }
                targetAisle = created
            } catch {
                print("Failed to create aisle: \(error)")
                reportAisleFailure("Couldn't add aisle \(aisleName). Check your connection and try again.")
                return
            }

        case .rejected(let reason):
            reportAisleFailure(reason)
            return
        }

        let aisle = targetAisle

        // Upsert mapping
        do {
            // `aisle.id`, not `aisle.number`. The standard departments carry an
            // empty number — "Bakery" has no aisle number — so writing the number
            // stored an empty aisleId, the mutation succeeded, the toast said
            // "Aisle saved: Bakery", and the item never moved. Scanned aisles have
            // real numbers, which is why typing "6" worked and typing a
            // department name did not.
            //
            // Lookup matches on id, name or number, so the id is the safe one to
            // write and the only one that is always present.
            try await StoreService.shared.assignProductToAisle(
                productId: item.productId,
                // Always, not only when there is no productId. Lookup falls back
                // from id to name, so sending one looked sufficient — but the
                // inference prompt reads `normalizedName || productId`, so a
                // mapping without the name taught the model
                // "Aisle 4: f9ad8b60-4cb7-41f2-81ae-915ae46933ef". The one
                // signal worth more than any guess, written where nothing can
                // read it, and paid for in tokens on every later call.
                normalizedName: item.normalizedName,
                storeId: store.id,
                aisleId: aisle.id,
                // Somebody opened this item and said where it is. That is worth
                // more than any later guess, so it goes on `userAisleOverride`,
                // which inference does not touch.
                sightedByUser: true
            )

            // Refresh mappings and notify observers
            _ = try await StoreService.shared.fetchMappings(storeId: store.id)
            StoreService.shared.objectWillChange.send()

            // Stays open. Picking an aisle is one tap in a screen you may have
            // opened to do something else, and closing on it takes away both the
            // Undo and the chance to correct a mis-tap. Done is how you leave.
            viewModel.toastMessage = "Aisle saved: \(aisleName)"
            viewModel.toastType = .success
            viewModel.showToast = true
        } catch {
            print("Failed to assign aisle: \(error)")
            // The one she actually hit. Not queued anywhere either — the outbox
            // carries item changes only — so this is lost unless she retries,
            // and she can only know to retry if we say so. Sheet stays open on
            // purpose, with what she typed still in the field.
            reportAisleFailure("Couldn't save aisle \(aisleName). Nothing was changed — try again when you have signal.")
        }
    }

    // MARK: - Saying the aisle out loud

    /// Speech lands in the same field as typing, and Save is still a separate
    /// tap. Any recogniser confuses "sixteen" and "sixty" over a tannoy, so what
    /// it heard has to be on screen and editable before anything is written.
    /// Numbers, always visible, no popup to open or dismiss.
    ///
    /// Standing in aisle 7 you should not have to talk, and you should not have
    /// to open anything either. Tapping applies straight away — Undo is what
    /// takes it back, so there is no Save to forget.
    /// 1–20, plus any higher aisle this shop has actually recorded.
    ///
    /// Twenty covers the supermarkets in use — ShopRite has 16, Stop&Shop 21 —
    /// and a strip long enough for every conceivable shop is a strip nobody can
    /// reach the end of. Aisle 99 exists somewhere; you say it rather than scroll
    /// to it, and once said it appears here.
    private var stripNumbers: [Int] {
        let recorded = (currentStore?.aisleLayout ?? [])
            .compactMap { Int($0.number.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 20 }
        return Array(1...20) + Set(recorded).sorted()
    }

    private var numberStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // One state, not two. Chips used to also mark the aisles this
                // shop already knew, and that green was read as "this item is in
                // aisle 4" every single time. It never earned the confusion:
                // tapping 7 creates aisle 7 just as happily, so knowing the shop
                // has heard of it changes nothing you can do — and it is no help
                // at all with the only question on screen, which is where this
                // item actually is.
                ForEach(stripNumbers, id: \.self) { n in
                    let selected = AisleUtterance.normalise(aisleText) == "\(n)"
                    Button {
                        apply("\(n)")
                    } label: {
                        Text("\(n)")
                            .font(.system(size: 20, weight: .semibold))
                            .monospacedDigit()
                            .frame(width: 58, height: 58)
                            .foregroundColor(selected ? DesignSystem.Colors.background
                                             : DesignSystem.Colors.textSecondary)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(selected ? DesignSystem.Colors.dillGreen
                                          : DesignSystem.Colors.glassBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var holdToTalkPill: some View {
        let listening = aisleSpeech.state == .listening
        return HStack(spacing: 10) {
            if listening {
                // Bars, not a static glyph. While your thumb is down the only
                // question is "is it hearing me", and a still icon does not
                // answer it.
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule()
                            .frame(width: 3, height: waveHeights[i])
                            .animation(.easeInOut(duration: 0.28).repeatForever(autoreverses: true)
                                       .delay(Double(i) * 0.07), value: waveAnimating)
                    }
                }
                .frame(height: 20)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(listening ? "Listening — let go when you're done" : "Hold to say the aisle")
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundColor(listening ? DesignSystem.Colors.background : DesignSystem.Colors.dillGreen)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                .fill(listening ? DesignSystem.Colors.dillGreen : DesignSystem.Colors.dillGreen.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                        .stroke(DesignSystem.Colors.dillGreen.opacity(listening ? 0 : 0.4), lineWidth: 1)
                )
        )
        // minimumDistance 0 so it fires on touch-down rather than after a drag.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isHoldingToTalk else { return }
                    isHoldingToTalk = true
                    waveAnimating = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await aisleSpeech.start(hints: aisleDictationHints) }
                }
                .onEnded { _ in
                    isHoldingToTalk = false
                    waveAnimating = false
                    Task {
                        let heard = await aisleSpeech.finish()
                        if !heard.isEmpty { apply(heard) }
                    }
                }
        )
        .accessibilityLabel("Hold to say the aisle")
    }

    /// Every name and number this store already knows, so the recogniser leans
    /// towards them rather than inventing a near-miss.
    private var aisleDictationHints: [String] {
        guard let store = currentStore else { return [] }
        return store.aisleLayout.flatMap { [$0.name, $0.number] }.filter { !$0.isEmpty }
    }

    private func reportAisleFailure(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        viewModel.toastMessage = message
        viewModel.toastType = .error
        viewModel.showToast = true
    }

    /// Format aisle display name flexibly - handles numbers, alphanumeric, or words
    private func aisleDisplayName(_ aisle: StoreAisle) -> String {
        let number = aisle.number.trimmingCharacters(in: .whitespaces)
        let name = aisle.name.trimmingCharacters(in: .whitespaces)

        // If both are empty, return placeholder
        if number.isEmpty && name.isEmpty {
            return "Unknown"
        }

        // If only one is provided, return it
        if number.isEmpty {
            return name
        }
        if name.isEmpty {
            return number
        }

        // If number and name are the same (case-insensitive), return just one
        if number.lowercased() == name.lowercased() {
            return name
        }

        // Otherwise combine them
        return "\(number) - \(name)"
    }

    private func clearAisleAssignment() async {
        guard let store = currentStore, currentMapping != nil else { return }

        do {
            try await StoreService.shared.removeMapping(
                storeId: store.id,
                productId: item.productId,
                normalizedName: item.productId == nil ? item.normalizedName : nil
            )
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            // Same silence as saving had. The field is cleared optimistically
            // before this runs, so without a message the aisle looks removed and
            // comes back on the next refresh.
            print("Failed to clear aisle assignment: \(error)")
            reportAisleFailure("Couldn't clear the aisle. It's still set — try again when you have signal.")
        }
    }

    // MARK: - Notes Section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Notes")
                .font(DesignSystem.Typography.headline)
                .foregroundColor(DesignSystem.Colors.textPrimary)

            TextField("Add notes (e.g., Kosher, Large size, Brand: Heinz)", text: $notesText, axis: .vertical)
                .font(DesignSystem.Typography.body)
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .lineLimit(3...6)
                .padding(DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                                .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                        )
                )

            Toggle(isOn: $notesEphemeral) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Just for this trip")
                        .font(DesignSystem.Typography.subheadline)
                        .foregroundColor(DesignSystem.Colors.textPrimary)
                    Text("Cleared when shopping finishes")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }
            }
            .tint(DesignSystem.Colors.dillGreen)
            .disabled(notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
        }
    }

    // MARK: - Photos Section

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            // Header with camera button
            HStack {
                Text("Photos (\(currentImages.count)/5)")
                    .font(DesignSystem.Typography.headline)
                    .foregroundColor(DesignSystem.Colors.textPrimary)

                Spacer()

                Button {
                    showImageSourcePicker = true
                } label: {
                    HStack(spacing: 6) {
                        if isUploadingImage {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.dillGreen))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 14))
                        }
                    }
                    .foregroundColor(currentImages.count >= 5 ? DesignSystem.Colors.textTertiary : DesignSystem.Colors.dillGreen)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                Circle()
                                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                            )
                    )
                    .contentShape(Circle())
                }
                .disabled(currentImages.count >= 5 || isUploadingImage)
                .zIndex(1)
            }

            // Images list
            if currentImages.isEmpty && pendingUploadImage == nil {
                Text("No photos yet")
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .padding(.vertical, DesignSystem.Spacing.sm)
            } else {
                VStack(spacing: DesignSystem.Spacing.md) {
                    // Show pending upload first
                    if let pendingImage = pendingUploadImage {
                        pendingUploadRow(pendingImage)
                    }

                    // Show existing images
                    ForEach(currentImages.sorted(by: { $0.uploadedAt < $1.uploadedAt })) { itemImage in
                        photoRow(itemImage)
                    }
                }
            }
        }
    }

    private func pendingUploadRow(_ image: UIImage) -> some View {
        ZStack {
            // Image
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipped()
                .cornerRadius(DesignSystem.CornerRadius.md)
                .opacity(0.6)

            // Upload progress overlay
            VStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.dillGreen))
                    .scaleEffect(1.5)

                Text("Uploading...")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textPrimary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm)
                    .fill(Color.black.opacity(0.6))
            )
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                .stroke(DesignSystem.Colors.dillGreen.opacity(0.5), lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
    }

    /// One photo: the image, then a caption strip beneath it.
    ///
    /// The strip used to sit *on* the image behind a dark gradient, which works
    /// on a dark photo and disappears on a bright one — a 12pt trash icon over a
    /// picture of a lemon is not a control anybody can find. Below the image it
    /// has its own ground and is legible whatever was photographed.
    ///
    /// It is also outside the tap-to-enlarge button now. A delete button nested
    /// inside another button is a coin toss about which one gets the tap.
    private func photoRow(_ itemImage: ItemImage) -> some View {
        VStack(spacing: 0) {
            Button {
                if let image = loadedImages[itemImage.id] {
                    selectedFullScreenImage = (image: image, metadata: itemImage)
                }
            } label: {
                if let image = loadedImages[itemImage.id] {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .overlay(
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.textTertiary))
                        )
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(DesignSystem.Colors.dillGreen)

                Text(UserCache.shared.displayName(for: itemImage.uploadedBy))
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textPrimary)

                Text("\u{00B7}")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textTertiary)

                Text(relativeDate(itemImage.uploadedAt))
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textSecondary)

                Spacer()

                Button {
                    imageToDelete = itemImage
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.error)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle().fill(DesignSystem.Colors.error.opacity(0.15))
                        )
                        .overlay(
                            Circle().stroke(DesignSystem.Colors.error.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(DesignSystem.Colors.glassBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
        )
    }

    // MARK: - Photo Helper Methods

    private func loadImages() {
        for itemImage in item.images {
            guard loadedImages[itemImage.id] == nil else { continue }
            Task {
                do {
                    let data = try await viewModel.downloadItemImage(s3Key: itemImage.s3Key)
                    if let image = UIImage(data: data) {
                        await MainActor.run {
                            loadedImages[itemImage.id] = image
                        }
                    }
                } catch {
                    print("Failed to load image \(itemImage.id): \(error)")
                }
            }
        }
    }

    private func uploadImage(_ data: Data) {
        // Show thumbnail immediately
        if let uiImage = UIImage(data: data) {
            pendingUploadImage = uiImage
        }

        isUploadingImage = true
        Task { @MainActor in
            do {
                try await viewModel.uploadItemImage(for: item, imageData: data)

                // After upload, get the newly added image from viewModel and cache it
                if let updatedItem = viewModel.items.first(where: { $0.id == item.id }),
                   let newImage = updatedItem.images.last,
                   let uiImage = pendingUploadImage {
                    loadedImages[newImage.id] = uiImage
                }

                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                print("Failed to upload image: \(error)")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            pendingUploadImage = nil
            isUploadingImage = false
        }
    }

    private func deleteImage(_ image: ItemImage) {
        Task { @MainActor in
            do {
                try await viewModel.deleteItemImage(from: item, imageId: image.id)
                loadedImages.removeValue(forKey: image.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                print("Failed to delete image: \(error)")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: - Aisle Name Cleanup

    /// Strips redundant "Aisle" prefix from aisle names for clean display
    /// e.g., "Aisle 4" -> "4", "Aisle Dairy" -> "Dairy", "4" -> "4"
    private func cleanAisleName(_ aisle: String) -> String {
        let trimmed = aisle.trimmingCharacters(in: .whitespaces)
        // Case-insensitive match for "Aisle " prefix
        if let range = trimmed.range(of: "^aisle\\s+", options: [.regularExpression, .caseInsensitive]) {
            return String(trimmed[range.upperBound...])
        }
        return trimmed
    }

    // MARK: - Date Formatting

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - FullScreenImageWrapper

/// Wrapper to make the tuple Identifiable for fullScreenCover
private struct FullScreenImageWrapper: Identifiable {
    let id = UUID()
    let image: UIImage
    let metadata: ItemImage
}

// MARK: - Preview

#Preview {
    ItemDetailSheet(item: GroceryItem.preview)
        .environmentObject(ShoppingListViewModel())
}
