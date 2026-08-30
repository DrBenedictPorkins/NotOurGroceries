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
            let stores = try? await storeService.fetchStores(householdId: householdId)
            await MainActor.run {
                if let stores = stores {
                    viewModel.householdStores = stores
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
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
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
                ForEach(viewModel.householdStores) { store in
                    NavigationLink(destination: StoreDetailView(store: store)) {
                        StoreRowView(store: store)
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

private struct StoreRowView: View {
    let store: HouseholdStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Store name
                Text(store.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            HStack(spacing: 12) {
                // Chain badge (if set)
                if let chain = store.chain, !chain.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "building.2")
                            .font(.system(size: 11, weight: .medium))
                        Text(chain)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DesignSystem.Colors.neonPurple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DesignSystem.Colors.neonPurple.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(DesignSystem.Colors.neonPurple.opacity(0.3), lineWidth: 1)
                    )
                }

                // Aisle count
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(store.aisleLayout.count) section\(store.aisleLayout.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
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

#Preview {
    StoresView()
        .environmentObject(ShoppingListViewModel())
}
