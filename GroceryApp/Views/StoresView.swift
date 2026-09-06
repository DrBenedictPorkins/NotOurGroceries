import SwiftUI

struct StoresView: View {
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @StateObject private var storeService = StoreService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCreateStore = false

    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                DesignSystem.Colors.darkMetallicGradient
                    .ignoresSafeArea()
                    .opacity(0.3)

                VStack(spacing: 0) {
                    // Header
                    headerView

                    if viewModel.householdStores.isEmpty {
                        emptyStateView
                    } else {
                        storeList
                    }

                    Spacer()

                    // Add New Store Button
                    addStoreButton
                }
                .padding(.horizontal, 20)
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showCreateStore, onDismiss: {
                refreshStores()
            }) {
                CreateStoreSheet()
                    .environmentObject(viewModel)
            }
            .onAppear {
                refreshStores()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    refreshStores()
                }
            }
        }
    }

    private func refreshStores() {
        guard let householdId = viewModel.householdId else { return }
        Task {
            do {
                let stores = try await storeService.fetchStores(householdId: householdId)
                await MainActor.run {
                    viewModel.householdStores = stores
                }
            } catch {
                // Used to fail silently via try?: the list kept showing whatever
                // was last loaded, so a failed refresh looked like no change.
                print("Failed to refresh stores: \(error)")
                await MainActor.run {
                    viewModel.showToast(message: "Couldn't load your stores. Check your signal and try again.", type: .error)
                }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stores")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.accentGradient)

                Text("Manage your grocery stores")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            // Version/Build number
            Text(AppVersion.full)
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textTertiary.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 60)
        .padding(.bottom, 20)
    }

    // MARK: - Store List

    private var storeList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(viewModel.storesInPickingOrder) { store in
                    NavigationLink(destination: StoreDetailView(storeId: store.id)) {
                        StoreCard(store: store)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "building.2")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(.white.opacity(0.3))

            Text("No Stores Yet")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Text("Add your first store to organize\nyour shopping by aisle")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Add Store Button

    private var addStoreButton: some View {
        Button(action: {
            showCreateStore = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add New Store")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(DesignSystem.Colors.dillGreen.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [DesignSystem.Colors.dillGreen, DesignSystem.Colors.dillGreen.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: DesignSystem.Shadows.dillGreenGlow, radius: 8, x: 0, y: 4)
            )
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Store Row View

#Preview {
    StoresView()
        .environmentObject(ShoppingListViewModel())
}
