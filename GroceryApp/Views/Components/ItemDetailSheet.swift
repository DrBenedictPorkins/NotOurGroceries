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
    @State private var aisleText: String = ""

    // AI Aisle Inference State
    @State private var isInferring = false
    @State private var inferenceResult: AisleExtractionService.AisleInferenceResult?
    @State private var inferenceError: String?

    /// Whether we're in proposed aisle mode (from batch mapping)
    private var isProposedAisleMode: Bool {
        if case .proposedAisle = mode { return true }
        return false
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

    private var hasMyReactions: Bool {
        item.reactions.contains { $0.userId == currentUserId }
    }

    private var sortedReactions: [ItemReaction] {
        item.reactions.sorted { $0.addedAt < $1.addedAt }
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

                    // Aisle section (show when in proposed mode or actively shopping at a store)
                    if isProposedAisleMode || (viewModel.shoppingStatus == .atStore && currentStore != nil) {
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

                    Divider()
                        .background(DesignSystem.Colors.glassBorder)

                    // Reactions section
                    reactionsSection

                    // Clear reactions buttons (only show if there are reactions)
                    if !item.reactions.isEmpty {
                        clearReactionsSection
                    }

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
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                }
            }
            .onAppear {
                notesText = item.notes ?? ""
                // In proposed mode, use the proposed aisle; otherwise use current mapping
                if let proposed = proposedAisleResult {
                    aisleText = proposed.suggestedAisle
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

        // Only save if notes changed
        if newNotes != item.notes {
            Task {
                await viewModel.updateNotes(for: item, notes: newNotes)
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
                    .foregroundColor(DesignSystem.Colors.neonYellow)
            }

            Spacer()
        }
    }

    // MARK: - Metadata Section

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            if let quantity = item.quantity, !quantity.isEmpty {
                metadataRow(label: "Quantity", value: quantity)
            }

            metadataRow(
                label: "Added by",
                value: "\(UserCache.shared.displayName(for: item.addedBy)) \(formattedDate(item.addedAt))"
            )

            if let lockedBy = item.lockedBy {
                metadataRow(
                    label: "Locked by",
                    value: UserCache.shared.displayName(for: lockedBy),
                    valueColor: DesignSystem.Colors.neonYellow
                )
            }

            if item.status == .inCart {
                metadataRow(
                    label: "Status",
                    value: "In Cart",
                    valueColor: DesignSystem.Colors.neonCyan
                )
            } else if item.status == .suggestion {
                metadataRow(
                    label: "Status",
                    value: "Suggestion",
                    valueColor: DesignSystem.Colors.neonYellow
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

                if isProposedAisleMode {
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

                if !aisleText.isEmpty && aisleText != currentAisleText && !isProposedAisleMode {
                    Button {
                        saveAisle()
                    } label: {
                        Text("Save")
                            .font(DesignSystem.Typography.subheadline)
                            .foregroundColor(DesignSystem.Colors.neonCyan)
                    }
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
            if isProposedAisleMode, let result = proposedAisleResult {
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

            // AI Inference Button - hide in proposed mode (already AI-generated)
            if !isProposedAisleMode {
                aiInferenceSection
            }

            Text(isProposedAisleMode ? "Edit to change the suggested aisle" : "Type any aisle identifier - number, letter, or name")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
    }

    /// Handle aisle change in proposed mode - just updates text, actual save happens on batch apply
    private func handleProposedAisleChange() {
        let trimmed = aisleText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onAisleChanged?(trimmed)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - AI Inference Section

    private var aiInferenceSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Show inference result if available
            if let result = inferenceResult {
                aiInferenceResultView(result)
            } else if let error = inferenceError {
                // Error message
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(DesignSystem.Colors.warning)
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.warning)
                }
                .padding(DesignSystem.Spacing.sm)
            } else {
                // Find Aisle button
                Button {
                    Task {
                        await inferAisle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isInferring {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text(isInferring ? "Finding aisle..." : "Find Aisle with AI")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DesignSystem.Colors.neonPurple.opacity(0.3))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(DesignSystem.Colors.neonPurple, lineWidth: 1)
                            )
                    )
                }
                .disabled(isInferring)
            }
        }
        .padding(.top, DesignSystem.Spacing.xs)
    }

    private func aiInferenceResultView(_ result: AisleExtractionService.AisleInferenceResult) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Header with suggestion
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(DesignSystem.Colors.neonPurple)
                Text("AI Suggestion")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.neonPurple)
                Spacer()
                Text("\(Int(result.confidence * 100))% confident")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(result.confidence >= 0.7 ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
            }

            // Suggested aisle
            HStack(spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                Text("Aisle \(cleanAisleName(result.suggestedAisle))")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
            }

            // Reasoning
            Text(result.reasoning)
                .font(DesignSystem.Typography.caption)
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Accept/Reject buttons
            HStack(spacing: 12) {
                Button {
                    Task {
                        await acceptInference(result)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                        Text("Accept")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(DesignSystem.Colors.success)
                    )
                }

                Button {
                    rejectInference()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                        Text("Reject")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(DesignSystem.Colors.textTertiary)
                    )
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                .fill(DesignSystem.Colors.neonPurple.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                        .stroke(DesignSystem.Colors.neonPurple.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - AI Inference Actions

    private func inferAisle() async {
        guard let store = currentStore else { return }

        isInferring = true
        inferenceError = nil
        inferenceResult = nil

        do {
            let result = try await AisleExtractionService.shared.inferProductAisle(
                productName: item.name,
                normalizedName: item.normalizedName,
                productId: item.productId,
                storeId: store.id
            )
            inferenceResult = result
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            inferenceError = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }

        isInferring = false
    }

    private func acceptInference(_ result: AisleExtractionService.AisleInferenceResult) async {
        guard let store = currentStore else { return }

        do {
            try await AisleExtractionService.shared.createMappingFromInference(
                productName: item.name,
                normalizedName: item.normalizedName,
                productId: item.productId,
                storeId: store.id,
                inference: result
            )

            // Refresh mappings - use explicit fetch and trigger update
            _ = try await StoreService.shared.fetchMappings(storeId: store.id)

            // Trigger explicit objectWillChange to notify observers
            StoreService.shared.objectWillChange.send()

            UINotificationFeedbackGenerator().notificationOccurred(.success)

            // Set toast message before dismissing so it shows on the main view
            viewModel.toastMessage = "Aisle saved: \(result.suggestedAisle)"
            viewModel.toastType = .success
            viewModel.showToast = true

            // Dismiss sheet so the shopping list refreshes with updated aisle
            dismiss()
        } catch {
            // Show error in sheet since we're not dismissing
            inferenceError = "Failed to save: \(error.localizedDescription)"
            inferenceResult = nil
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func rejectInference() {
        inferenceResult = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// The current aisle as display text
    private var currentAisleText: String {
        currentAisleString ?? ""
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
    private func assignToAisleByName(_ aisleName: String) async {
        guard var store = currentStore else { return }

        // Check if aisle already exists (case-insensitive match on number or name)
        let lowerName = aisleName.lowercased()
        var targetAisle = store.aisleLayout.first { aisle in
            aisle.number.lowercased() == lowerName ||
            aisle.name.lowercased() == lowerName ||
            aisleDisplayName(aisle).lowercased() == lowerName
        }

        // If aisle doesn't exist, create it
        if targetAisle == nil {
            do {
                store = try await StoreService.shared.addAisle(to: store, number: aisleName, name: "")
                targetAisle = store.aisleLayout.last
            } catch {
                print("Failed to create aisle: \(error)")
                return
            }
        }

        guard let aisle = targetAisle else { return }

        // Upsert mapping
        do {
            try await StoreService.shared.assignProductToAisle(
                productId: item.productId,
                normalizedName: item.productId == nil ? item.normalizedName : nil,
                storeId: store.id,
                aisleId: aisle.number
            )

            // Refresh mappings and notify observers
            _ = try await StoreService.shared.fetchMappings(storeId: store.id)
            StoreService.shared.objectWillChange.send()

            // Show toast and dismiss
            viewModel.toastMessage = "Aisle saved: \(aisleName)"
            viewModel.toastType = .success
            viewModel.showToast = true
            dismiss()
        } catch {
            print("Failed to assign aisle: \(error)")
        }
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
            print("Failed to clear aisle assignment: \(error)")
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
                                .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.neonCyan))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 14))
                        }
                    }
                    .foregroundColor(currentImages.count >= 5 ? DesignSystem.Colors.textTertiary : DesignSystem.Colors.neonCyan)
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
                    .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.neonCyan))
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
                .stroke(DesignSystem.Colors.neonCyan.opacity(0.5), lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
    }

    private func photoRow(_ itemImage: ItemImage) -> some View {
        Button {
            if let image = loadedImages[itemImage.id] {
                selectedFullScreenImage = (image: image, metadata: itemImage)
            }
        } label: {
            ZStack(alignment: .bottom) {
                // Image or placeholder
                if let image = loadedImages[itemImage.id] {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .clipped()
                        .cornerRadius(DesignSystem.CornerRadius.md)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .cornerRadius(DesignSystem.CornerRadius.md)
                        .overlay(
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.textTertiary))
                        )
                }

                // Metadata overlay at bottom
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(DesignSystem.Colors.neonCyan)

                    Text(UserCache.shared.displayName(for: itemImage.uploadedBy))
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.textPrimary)

                    Text("-")
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
                            .font(.system(size: 12))
                            .foregroundColor(DesignSystem.Colors.error)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(DesignSystem.Colors.error.opacity(0.2))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.7),
                            Color.black.opacity(0.3),
                            Color.clear
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .clipShape(RoundedCorner(radius: DesignSystem.CornerRadius.md, corners: [.bottomLeft, .bottomRight]))
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
        }
        .buttonStyle(.plain)
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

    // MARK: - Reactions Section

    private var reactionsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Reactions")
                    .font(DesignSystem.Typography.headline)
                    .foregroundColor(DesignSystem.Colors.textPrimary)

                if !item.reactions.isEmpty {
                    Text("(\(item.reactions.count))")
                        .font(DesignSystem.Typography.subheadline)
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }

                Spacer()
            }

            // Add reaction emoji picker
            addReactionPicker

            if item.reactions.isEmpty {
                Text("No reactions yet")
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .padding(.vertical, DesignSystem.Spacing.sm)
            } else {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(sortedReactions, id: \.self) { reaction in
                        reactionRow(reaction)
                    }
                }
            }
        }
    }

    /// Emoji picker to add reactions
    private var addReactionPicker: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ForEach(ReactionEmoji.allCases, id: \.self) { reaction in
                let hasThisReaction = item.reactions.contains { $0.emoji == reaction.rawValue && $0.userId == currentUserId }

                Button {
                    Task {
                        await viewModel.toggleReaction(reaction.rawValue, on: item)
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(reaction.rawValue)
                        .font(.system(size: 28))
                        .opacity(hasThisReaction ? 1.0 : 0.5)
                        .scaleEffect(hasThisReaction ? 1.1 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasThisReaction)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                        .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                )
        )
    }

    private func reactionRow(_ reaction: ItemReaction) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Text(reaction.emoji)
                .font(.system(size: 20))

            Text(UserCache.shared.displayName(for: reaction.userId))
                .font(DesignSystem.Typography.body)
                .foregroundColor(reaction.userId == currentUserId ? DesignSystem.Colors.neonCyan : DesignSystem.Colors.textPrimary)

            Spacer()

            Text(relativeDate(reaction.addedAt))
                .font(DesignSystem.Typography.caption)
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    // MARK: - Clear Reactions Section

    private var clearReactionsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Actions")
                .font(DesignSystem.Typography.headline)
                .foregroundColor(DesignSystem.Colors.textPrimary)

            HStack(spacing: DesignSystem.Spacing.md) {
                // Clear Mine button
                Button {
                    Task {
                        await viewModel.clearMyReactions(from: item)
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    dismiss()
                } label: {
                    HStack {
                        Spacer()
                        Text("Clear Mine")
                            .font(DesignSystem.Typography.subheadline)
                            .foregroundColor(hasMyReactions ? DesignSystem.Colors.warning : DesignSystem.Colors.textTertiary)
                        Spacer()
                    }
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm)
                            .fill(hasMyReactions ? DesignSystem.Colors.warning.opacity(0.1) : DesignSystem.Colors.glassBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm)
                                    .stroke(hasMyReactions ? DesignSystem.Colors.warning.opacity(0.3) : DesignSystem.Colors.glassBorder, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasMyReactions)

                // Clear All button
                Button {
                    Task {
                        await viewModel.clearAllReactions(from: item)
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    dismiss()
                } label: {
                    HStack {
                        Spacer()
                        Text("Clear All")
                            .font(DesignSystem.Typography.subheadline)
                            .foregroundColor(DesignSystem.Colors.error)
                        Spacer()
                    }
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm)
                            .fill(DesignSystem.Colors.error.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm)
                                    .stroke(DesignSystem.Colors.error.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, DesignSystem.Spacing.md)
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
    ItemDetailSheet(item: GroceryItem.withReactionsPreview)
        .environmentObject(ShoppingListViewModel())
}
