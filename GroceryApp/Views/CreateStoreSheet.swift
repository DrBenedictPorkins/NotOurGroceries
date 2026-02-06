import SwiftUI

struct CreateStoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @State private var storeName = ""
    @State private var chainName = ""
    @State private var aisles: [EditableAisle] = []
    @State private var showAisleScanSheet = false
    @State private var createdStore: HouseholdStore?
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case storeName
        case chainName
        case aisle(UUID)
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                DesignSystem.Colors.darkMetallicGradient
                    .ignoresSafeArea()
                    .opacity(0.3)

                ScrollView {
                    VStack(spacing: 24) {
                        // Store Info Section
                        storeInfoSection

                        // Aisles Section
                        aislesSection

                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                }
            }
            .navigationTitle("New Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveStore()
                    }
                    .foregroundColor(canSave ? DesignSystem.Colors.neonCyan : DesignSystem.Colors.textTertiary)
                    .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showAisleScanSheet) {
                if let store = createdStore {
                    AisleScanSheet(store: store) {
                        // Scan complete - dismiss both sheets
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Store Info Section

    private var storeInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STORE INFORMATION")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DesignSystem.Colors.neonCyan)
                .tracking(1.2)

            VStack(spacing: 16) {
                // Store Name Field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Store Name")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)

                    TextField("e.g., Stop & Shop Stamford", text: $storeName)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(focusedField == .storeName ? DesignSystem.Colors.neonCyan.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                                )
                        )
                        .focused($focusedField, equals: .storeName)
                }

                // Chain Name Field (Optional)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chain (Optional)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)

                    TextField("e.g., Stop & Shop", text: $chainName)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(focusedField == .chainName ? DesignSystem.Colors.neonCyan.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                                )
                        )
                        .focused($focusedField, equals: .chainName)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                    .fill(DesignSystem.Colors.glassBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                            .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Aisles Section

    private var aislesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AISLES")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.neonPurple)
                    .tracking(1.2)

                Spacer()

                Button(action: addAisle) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Add Aisle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(DesignSystem.Colors.neonPurple)
                }
            }

            if aisles.isEmpty {
                emptyAislesView
            } else {
                VStack(spacing: 8) {
                    ForEach(aisles) { aisle in
                        aisleRow(aisle)
                    }
                }
            }

            // Scan Aisle Sign button
            scanAisleButton
        }
    }

    // MARK: - Scan Aisle Button

    private var scanAisleButton: some View {
        Button(action: scanAisleSign) {
            HStack(spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 20, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan Aisle Sign")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Take a photo of the store directory")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }
            .foregroundColor(DesignSystem.Colors.neonCyan)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                    .fill(DesignSystem.Colors.neonCyan.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                            .stroke(DesignSystem.Colors.neonCyan.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .disabled(!canSave || isSaving)
        .opacity(canSave ? 1.0 : 0.5)
    }

    // MARK: - Aisle Row

    private func aisleRow(_ aisle: EditableAisle) -> some View {
        HStack(spacing: 12) {
            // Aisle Number
            TextField("1", text: binding(for: aisle).number)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .frame(width: 60)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(focusedField == .aisle(aisle.id) ? DesignSystem.Colors.neonPurple.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .focused($focusedField, equals: .aisle(aisle.id))
                .keyboardType(.numbersAndPunctuation)

            // Aisle Name
            TextField("Name (e.g., Dairy)", text: binding(for: aisle).name)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )

            // Delete Button
            Button(action: {
                deleteAisle(aisle)
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.error.opacity(0.8))
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystem.Colors.error.opacity(0.1))
                    )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                .fill(DesignSystem.Colors.glassBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                        .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Empty Aisles View

    private var emptyAislesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.system(size: 32, weight: .thin))
                .foregroundColor(.white.opacity(0.3))

            Text("No aisles added yet")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                .fill(DesignSystem.Colors.glassBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                        .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Helpers

    private var canSave: Bool {
        !storeName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func binding(for aisle: EditableAisle) -> Binding<EditableAisle> {
        guard let index = aisles.firstIndex(where: { $0.id == aisle.id }) else {
            fatalError("Aisle not found")
        }
        return $aisles[index]
    }

    private func addAisle() {
        let newAisle = EditableAisle(number: "", name: "")
        aisles.append(newAisle)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Focus the new aisle field after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedField = .aisle(newAisle.id)
        }
    }

    private func deleteAisle(_ aisle: EditableAisle) {
        withAnimation(.easeOut(duration: 0.2)) {
            aisles.removeAll { $0.id == aisle.id }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func saveStore() {
        let trimmedStoreName = storeName.trimmingCharacters(in: .whitespaces)
        guard !trimmedStoreName.isEmpty else { return }

        // Convert EditableAisles to StoreAisles
        let storeAisles = aisles.enumerated().compactMap { index, editableAisle -> StoreAisle? in
            let trimmedNumber = editableAisle.number.trimmingCharacters(in: .whitespaces)
            let trimmedName = editableAisle.name.trimmingCharacters(in: .whitespaces)

            // Skip aisles without both number and name
            guard !trimmedNumber.isEmpty && !trimmedName.isEmpty else { return nil }

            return StoreAisle(
                id: UUID().uuidString,
                number: trimmedNumber,
                name: trimmedName,
                displayOrder: index + 1
            )
        }

        Task {
            await viewModel.createStore(
                name: trimmedStoreName,
                chain: chainName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : chainName.trimmingCharacters(in: .whitespaces),
                aisles: storeAisles
            )
            dismiss()
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func scanAisleSign() {
        guard canSave else { return }

        isSaving = true
        let trimmedStoreName = storeName.trimmingCharacters(in: .whitespaces)
        let trimmedChain = chainName.trimmingCharacters(in: .whitespaces)

        // Convert any manually added aisles
        let storeAisles = aisles.enumerated().compactMap { index, editableAisle -> StoreAisle? in
            let trimmedNumber = editableAisle.number.trimmingCharacters(in: .whitespaces)
            let trimmedName = editableAisle.name.trimmingCharacters(in: .whitespaces)
            guard !trimmedNumber.isEmpty && !trimmedName.isEmpty else { return nil }
            return StoreAisle(
                id: UUID().uuidString,
                number: trimmedNumber,
                name: trimmedName,
                displayOrder: index + 1
            )
        }

        Task {
            // Create the store first
            let newStore = await viewModel.createStore(
                name: trimmedStoreName,
                chain: trimmedChain.isEmpty ? nil : trimmedChain,
                aisles: storeAisles
            )

            await MainActor.run {
                isSaving = false
                if let store = newStore {
                    createdStore = store
                    showAisleScanSheet = true
                }
            }
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

// MARK: - Editable Aisle

struct EditableAisle: Identifiable {
    let id = UUID()
    var number: String
    var name: String
}

#Preview {
    CreateStoreSheet()
        .environmentObject(ShoppingListViewModel())
}
