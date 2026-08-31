import SwiftUI

/// Sheet for batch-mapping unmapped items to aisles before shopping
struct BatchAisleMappingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel

    let store: HouseholdStore
    let unmappedItems: [GroceryItem]
    let onComplete: () -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var isProcessing = false
    @State private var processingMessage = "Analyzing items..."
    @State private var results: [String: AisleExtractionService.AisleInferenceResult] = [:]
    @State private var error: String?
    @State private var isSaving = false

    // Item detail sheet state
    @State private var selectedItemForDetail: GroceryItem?
    @State private var selectedItemResult: AisleExtractionService.AisleInferenceResult?

    var body: some View {
        NavigationView {
            ZStack {
                // Background (same as AisleScanSheet)
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                DesignSystem.Colors.darkMetallicGradient
                    .ignoresSafeArea()
                    .opacity(0.3)

                // State-based content
                if !results.isEmpty {
                    resultsView
                } else if let error = error {
                    errorView(error)
                } else if isProcessing {
                    processingView
                } else {
                    idleView
                }
            }
            .navigationTitle("Map Aisles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                }
            }
            .sheet(item: $selectedItemForDetail) { item in
                if let result = selectedItemResult {
                    ItemDetailSheet(
                        item: item,
                        mode: .proposedAisle(result: result, store: store),
                        onAisleChanged: { newAisle in
                            // Update the result with the new aisle
                            var updatedResult = result
                            updatedResult.suggestedAisle = newAisle
                            results[item.id] = updatedResult
                        }
                    )
                    .environmentObject(viewModel)
                }
            }
        }
    }

    // MARK: - Idle View (initial state)

    private var idleView: some View {
        VStack(spacing: 32) {
            Spacer()

            // Icon
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 64, weight: .thin))
                .foregroundColor(DesignSystem.Colors.neonPurple.opacity(0.7))

            // Info
            VStack(spacing: 12) {
                Text("\(unmappedItems.count) items need aisle info")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                Text("Use AI to automatically find the best aisle for each item based on \(store.name)'s layout.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Item preview (first few items)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(unmappedItems.prefix(5), id: \.id) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(DesignSystem.Colors.warning)
                            .font(.system(size: 14))
                        Text(item.name)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                        Spacer()
                    }
                }
                if unmappedItems.count > 5 {
                    Text("... and \(unmappedItems.count - 5) more")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignSystem.Colors.glassBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 24)

            Spacer()

            // Map with AI button
            Button {
                Task { await performBatchInference() }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Map All with AI")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(DesignSystem.Colors.neonPurple.opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(DesignSystem.Colors.neonPurple, lineWidth: 1.5)
                        )
                )
                .shadow(color: DesignSystem.Colors.neonPurple.opacity(0.3), radius: 8)
            }
            .padding(.horizontal, 24)

            // Skip button
            Button {
                onComplete()
                dismiss()
            } label: {
                Text("Skip")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Processing View

    private var processingView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)
                .tint(DesignSystem.Colors.neonPurple)

            Text(processingMessage)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white)

            Text("This may take a moment...")
                .font(.system(size: 14))
                .foregroundColor(DesignSystem.Colors.textSecondary)

            Spacer()
        }
    }

    // MARK: - Results View

    private var resultsView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(DesignSystem.Colors.success)

                Text("Aisles Found")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                Text("\(results.count) of \(unmappedItems.count) items mapped")
                    .font(.system(size: 14))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Results list
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(unmappedItems, id: \.id) { item in
                        if let result = results[item.id] {
                            resultRow(item: item, result: result)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 100)
            }

            // Apply button
            VStack {
                Button {
                    Task { await saveResults() }
                } label: {
                    HStack(spacing: 12) {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        Text(isSaving ? "Saving..." : "Apply & Continue")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(DesignSystem.Colors.success)
                    )
                }
                .disabled(isSaving)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .background(
                LinearGradient(
                    colors: [DesignSystem.Colors.background.opacity(0), DesignSystem.Colors.background],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)
                .allowsHitTesting(false)
            )
        }
    }

    // MARK: - Result Row

    private func resultRow(item: GroceryItem, result: AisleExtractionService.AisleInferenceResult) -> some View {
        BatchMappingResultRow(
            item: item,
            result: result,
            aisleLayout: store.aisleLayout,
            onLongPress: {
                selectedItemResult = result
                selectedItemForDetail = item
            }
        )
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(DesignSystem.Colors.warning)

            Text("Something went wrong")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)

            Text(message)
                .font(.system(size: 15))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            // Retry button
            Button {
                error = nil
                Task { await performBatchInference() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Try Again")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(DesignSystem.Colors.neonPurple.opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(DesignSystem.Colors.neonPurple, lineWidth: 1.5)
                        )
                )
            }
            .padding(.horizontal, 24)

            // Skip button
            Button {
                onComplete()
                dismiss()
            } label: {
                Text("Skip")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Actions

    private func performBatchInference() async {
        isProcessing = true
        processingMessage = "Analyzing \(unmappedItems.count) items..."

        do {
            // Build input items
            let inputs = unmappedItems.map { item in
                AisleExtractionService.BatchInferenceInput(
                    id: item.id,
                    productName: item.name,
                    normalizedName: item.normalizedName,
                    productId: item.productId
                )
            }

            // Call batch inference
            let inferenceResults = try await AisleExtractionService.shared.inferProductAisleBatch(
                storeId: store.id,
                items: inputs
            )

            await MainActor.run {
                results = inferenceResults
                isProcessing = false
            }

            UINotificationFeedbackGenerator().notificationOccurred(.success)

        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isProcessing = false
            }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func saveResults() async {
        isSaving = true

        do {
            let inputs = unmappedItems.map { item in
                AisleExtractionService.BatchInferenceInput(
                    id: item.id,
                    productName: item.name,
                    normalizedName: item.normalizedName,
                    productId: item.productId
                )
            }

            _ = try await AisleExtractionService.shared.saveBatchInferenceResults(
                items: inputs,
                results: results,
                storeId: store.id
            )

            // Refresh mappings cache
            _ = try? await StoreService.shared.fetchMappings(storeId: store.id)

            await MainActor.run {
                isSaving = false
                onComplete()
                dismiss()
            }

            UINotificationFeedbackGenerator().notificationOccurred(.success)

        } catch {
            await MainActor.run {
                isSaving = false
                self.error = "Failed to save: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Result Row View (with press animation)

private struct BatchMappingResultRow: View {
    let item: GroceryItem
    let result: AisleExtractionService.AisleInferenceResult
    /// Needed to name the aisle. Without it the row printed the raw id, so the
    /// answer to "where is this?" was "standard-household".
    let aisleLayout: [StoreAisle]
    let onLongPress: () -> Void

    @State private var isPressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Item name -> Aisle
            HStack {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.textSecondary)

                Text(AisleNaming.displayName(for: result.suggestedAisle, in: aisleLayout))
                    .font(.system(size: 16, weight: .bold))
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(DesignSystem.Colors.dillGreen)
            }

            // Reasoning
            Text(result.reasoning)
                .font(.system(size: 13))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .lineLimit(2)

            // Confidence indicator + hint
            HStack(spacing: 4) {
                Text("\(Int(result.confidence * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(result.confidence >= 0.7 ? DesignSystem.Colors.success : DesignSystem.Colors.warning)

                Spacer()

                Text("Tap to edit")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystem.Colors.glassBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        // A tap opens it. The hint said "long press to edit" and sat in 10pt
        // grey in the corner, which is a fair description of a gesture nobody
        // goes looking for — the natural thing to do with a row is tap it.
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onLongPress()
        }
        // Long press still works, for anyone who learned it the hard way.
        .onLongPressGesture(minimumDuration: 0.5) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLongPress()
        }
    }
}
