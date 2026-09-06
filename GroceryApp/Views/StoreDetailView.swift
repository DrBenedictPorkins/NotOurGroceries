import SwiftUI

/// Detail view for managing an individual grocery store
struct StoreDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @StateObject private var storeService = StoreService.shared

    /// The store's id, not the store. See the note on
    /// `StoreAisleManagementView.storeId` — the same rebuild that discarded the
    /// aisle screen discards this one, one level up.
    let storeId: String

    // MARK: - State

    @State private var storeName: String
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var hasChanges = false

    // MARK: - Initialization

    init(storeId: String) {
        self.storeId = storeId
        _storeName = State(initialValue: StoreService.shared.householdStores.first { $0.id == storeId }?.name ?? "")
    }

    // MARK: - Computed Properties

    /// Get fresh store data from viewModel (updated after extraction completes)
    private var currentStore: HouseholdStore {
        viewModel.householdStores.first { $0.id == storeId }
            ?? HouseholdStore(id: storeId, householdId: "", name: "", chain: nil, address: nil, aisleLayout: [])
    }

    private var aisleCount: Int {
        currentStore.aisleLayout.count
    }

    private var nameIsTaken: Bool {
        StoreService.shared.nameIsTaken(storeName, excludingStoreId: storeId)
    }

    private var canSave: Bool {
        !storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !nameIsTaken &&
        hasChanges &&
        !isSaving
    }


    // MARK: - Body

    var body: some View {
        ZStack {
            // Background
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.darkMetallicGradient
                .ignoresSafeArea()
                .opacity(0.3)

            ScrollView {
                VStack(spacing: 24) {
                    // Store Info Section
                    storeInfoSection

                    // Every store gets the same screen. There used to be a
                    // branch here for "no aisle" stores that hid all of this —
                    // but both kinds carry the identical seeded sections, so the
                    // branch only decided which buttons appeared, and the other
                    // route to this feature never had it.
                    // A shop with no aisles or departments has no layout to
                    // manage, and a screen that only ever says "nothing here" is
                    // worse than no screen. It comes back on its own the moment
                    // the store has an aisle — saying where something is on an
                    // item creates one — so this is not a one-way door.
                    if !currentStore.aisleLayout.isEmpty {
                        aisleManagementSection
                    }

    
                    // Delete Section
                    deleteSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .navigationTitle("Store Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if canSave {
                    Button("Save") {
                        Task {
                            await saveChanges()
                        }
                    }
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                }
            }
        }
        .alert("Delete Store", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await deleteStore()
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(currentStore.name)\"? This will remove all aisle mappings for this store. This action cannot be undone.")
        }
        .onChange(of: storeName) { _, _ in
            checkForChanges()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refreshStoreData()
            }
        }
        .onDisappear {
            // Auto-save on dismiss if there are changes
            if hasChanges && !storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task {
                    await saveChanges()
                }
            }
        }
    }

    // MARK: - Store Info Section

    private var storeInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "STORE INFORMATION", icon: "storefront")

            // Store Name Field
            VStack(alignment: .leading, spacing: 6) {
                Text("Store Name")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)

                TextField("Enter store name", text: $storeName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DesignSystem.Colors.glassBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                            )
                    )

                if nameIsTaken {
                    Text("You already have a store called that.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DesignSystem.Colors.neonPink)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(DesignSystem.Colors.glassBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Aisle Management Section

    private var aisleManagementSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "AISLE LAYOUT", icon: "arrow.triangle.branch")

            // `store`, not `currentStore`. Adding, deleting or reordering an
            // aisle republishes `householdStores`, which changed `currentStore`,
            // which handed the NavigationLink a different destination value —
            // and SwiftUI popped the screen you were working on. The pushed view
            // reads the live store from the view model itself, so it only needs
            // the identity here, and the identity never changes.
            NavigationLink(destination: StoreAisleManagementView(storeId: storeId).environmentObject(viewModel)) {
                HStack(spacing: 16) {
                    // Aisle icon
                    ZStack {
                        Circle()
                            .fill(DesignSystem.Colors.dillGreen.opacity(0.15))
                            .frame(width: 48, height: 48)

                        Image(systemName: "list.bullet.indent")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.dillGreen)
                    }

                    // Content
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Manage Aisles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)

                        Text("\(aisleCount) aisle\(aisleCount == 1 ? "" : "s") configured")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                    }

                    Spacer()

                    // Chevron
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(DesignSystem.Colors.glassBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Delete Section

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "DANGER ZONE", icon: "exclamationmark.triangle.fill")

            Button(action: {
                showDeleteConfirmation = true
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }) {
                HStack(spacing: 16) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(DesignSystem.Colors.error.opacity(0.15))
                            .frame(width: 48, height: 48)

                        if isDeleting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.error))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(DesignSystem.Colors.error)
                        }
                    }

                    // Content
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delete Store")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.error)

                        Text("Remove this store and all mappings")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                    }

                    Spacer()
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(DesignSystem.Colors.glassBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(DesignSystem.Colors.error.opacity(0.3), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
        }
    }

    // MARK: - Helper Views

    // MARK: - No Aisles Section

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DesignSystem.Colors.dillGreen)

            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DesignSystem.Colors.dillGreen)
                .tracking(1.0)
        }
    }

    // MARK: - Actions

    private func refreshStoreData() {
        guard let householdId = viewModel.householdId else { return }
        Task {
            do {
                let stores = try await storeService.fetchStores(householdId: householdId)
                await MainActor.run {
                    viewModel.householdStores = stores
                }
            } catch {
                // Used to fail silently via try?: the screen kept showing stale
                // store details with no sign the refresh had failed.
                print("Failed to refresh store data: \(error)")
                await MainActor.run {
                    viewModel.showToast(message: "Couldn't refresh this store. Check your signal and try again.", type: .error)
                }
            }
        }
    }

    private func checkForChanges() {
        hasChanges = storeName != currentStore.name
    }

    private func saveChanges() async {
        guard canSave else { return }

        isSaving = true
        defer { isSaving = false }

        let trimmedName = storeName.trimmingCharacters(in: .whitespacesAndNewlines)

        let updatedStore = HouseholdStore(
            id: storeId,
            householdId: currentStore.householdId,
            name: trimmedName,
            chain: currentStore.chain,
            address: currentStore.address,
            // The live layout, not the one this screen opened with. Renaming
            // after adding an aisle used to write the old layout back over it.
            aisleLayout: currentStore.aisleLayout
        )

        do {
            try await storeService.updateStore(updatedStore)
            await MainActor.run {
                // Also update viewModel's householdStores
                if let index = viewModel.householdStores.firstIndex(where: { $0.id == updatedStore.id }) {
                    viewModel.householdStores[index] = updatedStore
                }
                hasChanges = false
                viewModel.toastMessage = "Store updated"
                viewModel.toastType = .success
                viewModel.showToast = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } catch {
            await MainActor.run {
                viewModel.toastMessage = "Failed to save: \(error.localizedDescription)"
                viewModel.toastType = .error
                viewModel.showToast = true
            }
        }
    }

    private func deleteStore() async {
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await storeService.deleteStore(storeId)
            await MainActor.run {
                // Also remove from viewModel's householdStores
                viewModel.householdStores.removeAll { $0.id == storeId }
                viewModel.toastMessage = "Store deleted"
                viewModel.toastType = .success
                viewModel.showToast = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            }
        } catch {
            await MainActor.run {
                viewModel.toastMessage = "Failed to delete: \(error.localizedDescription)"
                viewModel.toastType = .error
                viewModel.showToast = true
            }
        }
    }
}

// MARK: - Preview

#Preview {
    StoreDetailView(storeId: HouseholdStore.preview.id)
        .environmentObject(ShoppingListViewModel())
}
