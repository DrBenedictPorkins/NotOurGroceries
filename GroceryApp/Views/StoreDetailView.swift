import SwiftUI

/// Detail view for managing an individual grocery store
struct StoreDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @StateObject private var storeService = StoreService.shared
    @ObservedObject private var extractionService = AisleExtractionService.shared

    let store: HouseholdStore

    // MARK: - State

    @State private var storeName: String
    @State private var isSaving = false
    @State private var showAisleScanSheet = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var hasChanges = false

    // MARK: - Initialization

    init(store: HouseholdStore) {
        self.store = store
        _storeName = State(initialValue: store.name)
    }

    // MARK: - Computed Properties

    /// Get fresh store data from viewModel (updated after extraction completes)
    private var currentStore: HouseholdStore {
        viewModel.householdStores.first { $0.id == store.id } ?? store
    }

    private var aisleCount: Int {
        currentStore.aisleLayout.count
    }

    private var canSave: Bool {
        !storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        hasChanges &&
        !isSaving
    }

    private var hasActiveExtractionJob: Bool {
        extractionService.activeJobId(for: store.id) != nil
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

                    // Aisle machinery is meaningless for stores with no aisles
                    if !currentStore.hasNoAisles {
                        // Aisle Management Section
                        aisleManagementSection

                        // Actions Section
                        actionsSection
                    } else {
                        noAislesSection
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
        .sheet(isPresented: $showAisleScanSheet) {
            AisleScanSheet(store: currentStore) {
                // Refresh store AND mappings after scan complete
                // Lambda updates aisleLayout in Phase 1.5, so we need fresh store data
                Task {
                    if let householdId = viewModel.householdId {
                        let stores = try? await storeService.fetchStores(householdId: householdId)
                        await MainActor.run {
                            if let stores = stores {
                                viewModel.householdStores = stores
                            }
                        }
                    }
                    try? await storeService.fetchMappings(storeId: store.id)
                }
            }
            .environmentObject(viewModel)
        }
        .alert("Delete Store", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await deleteStore()
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(store.name)\"? This will remove all aisle mappings for this store. This action cannot be undone.")
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

            NavigationLink(destination: StoreAisleManagementView(store: currentStore).environmentObject(viewModel)) {
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

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "QUICK ACTIONS", icon: "bolt.fill")

            // Scan Aisle Directory Button
            Button(action: {
                showAisleScanSheet = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }) {
                HStack(spacing: 16) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(hasActiveExtractionJob ?
                                  DesignSystem.Colors.dillGreen.opacity(0.15) :
                                  DesignSystem.Colors.neonPurple.opacity(0.15))
                            .frame(width: 48, height: 48)

                        if hasActiveExtractionJob {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(DesignSystem.Colors.dillGreen)
                        } else {
                            Image(systemName: "doc.viewfinder")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(DesignSystem.Colors.neonPurple)
                        }
                    }

                    // Content
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hasActiveExtractionJob ? "Extraction In Progress" : "Scan Aisle Directory")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)

                        Text(hasActiveExtractionJob ?
                             "Tap to view progress" :
                             "Take a photo to auto-map products")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                    }

                    Spacer()

                    // Arrow or pulse indicator
                    if hasActiveExtractionJob {
                        Circle()
                            .fill(DesignSystem.Colors.dillGreen)
                            .frame(width: 12, height: 12)
                            .shadow(color: DesignSystem.Colors.dillGreen.opacity(0.5), radius: 4)
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(DesignSystem.Colors.neonPurple.opacity(0.7))
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(DesignSystem.Colors.glassBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(hasActiveExtractionJob ?
                                        DesignSystem.Colors.dillGreen.opacity(0.3) :
                                        DesignSystem.Colors.neonPurple.opacity(0.3), lineWidth: 1)
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

    private var noAislesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "STORE LAYOUT", icon: "list.bullet.indent")

            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.neonPurple.opacity(0.15))
                        .frame(width: 48, height: 48)

                    Image(systemName: "basket")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.neonPurple)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("No Aisles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Your list stays in one section while shopping here")
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
                            .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                    )
            )
        }
    }

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
            let stores = try? await storeService.fetchStores(householdId: householdId)
            await MainActor.run {
                if let stores = stores {
                    viewModel.householdStores = stores
                }
            }
        }
    }

    private func checkForChanges() {
        hasChanges = storeName != store.name
    }

    private func saveChanges() async {
        guard canSave else { return }

        isSaving = true
        defer { isSaving = false }

        let trimmedName = storeName.trimmingCharacters(in: .whitespacesAndNewlines)

        let updatedStore = HouseholdStore(
            id: store.id,
            householdId: store.householdId,
            name: trimmedName,
            chain: store.chain,
            address: store.address,
            aisleLayout: store.aisleLayout
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
            try await storeService.deleteStore(store.id)
            await MainActor.run {
                // Also remove from viewModel's householdStores
                viewModel.householdStores.removeAll { $0.id == store.id }
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
    StoreDetailView(store: HouseholdStore.preview)
        .environmentObject(ShoppingListViewModel())
}
