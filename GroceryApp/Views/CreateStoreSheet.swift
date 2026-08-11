import SwiftUI

struct CreateStoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @State private var storeName = ""
    @State private var chainName = ""
    @State private var layoutType: StoreLayoutType = .aisles
    @State private var showAisleScanSheet = false
    @State private var createdStore: HouseholdStore?
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case storeName
        case chainName
    }

    enum WizardStep {
        case storeInfo
        case aisleSetup
    }

    @State private var step: WizardStep = .storeInfo

    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                DesignSystem.Colors.darkMetallicGradient
                    .ignoresSafeArea()
                    .opacity(0.3)

                switch step {
                case .storeInfo:
                    storeInfoStep
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading),
                            removal: .move(edge: .leading)
                        ))
                case .aisleSetup:
                    aisleSetupStep
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .trailing)
                        ))
                }
            }
            .navigationTitle(step == .storeInfo ? "New Store" : "Set Up Aisles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(step == .storeInfo ? "Cancel" : "Done") {
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.neonCyan)
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

    // MARK: - Step 1: Store Info

    private var storeInfoStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                storeInfoSection

                storeLayoutSection

                // Next button
                Button(action: saveAndAdvance) {
                    HStack(spacing: 8) {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(layoutType == .noAisles ? "Create Store" : "Next")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                            .fill(canSave ? DesignSystem.Colors.neonCyan : DesignSystem.Colors.neonCyan.opacity(0.3))
                    )
                    .foregroundColor(canSave ? .black : .white.opacity(0.3))
                }
                .disabled(!canSave || isSaving)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
    }

    // MARK: - Step 2: Aisle Setup

    private var aisleSetupStep: some View {
        VStack(spacing: 32) {
            Spacer()

            // Success confirmation
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundColor(DesignSystem.Colors.success)

                Text("Store created!")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)

                Text("Set up aisles now, or do it later from the store detail page.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Scan Aisle Sign - primary CTA
            Button(action: {
                showAisleScanSheet = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }) {
                HStack(spacing: 12) {
                    if createdStore == nil {
                        ProgressView()
                            .tint(DesignSystem.Colors.neonCyan)
                    } else {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 20, weight: .medium))
                    }

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
            .disabled(createdStore == nil)
            .opacity(createdStore == nil ? 0.6 : 1.0)
            .padding(.horizontal, 20)

            // Done button - secondary
            Button(action: {
                dismiss()
            }) {
                Text("Skip")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            Spacer()
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

    // MARK: - Store Layout Section

    private var storeLayoutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STORE LAYOUT")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DesignSystem.Colors.neonCyan)
                .tracking(1.2)

            VStack(spacing: 12) {
                layoutOption(
                    type: .aisles,
                    icon: "list.bullet.indent",
                    title: "Has numbered aisles",
                    subtitle: "Sort your list by aisle while shopping"
                )

                layoutOption(
                    type: .noAisles,
                    icon: "basket",
                    title: "No aisles",
                    subtitle: "Farmers market, corner shop, small grocery"
                )
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

    private func layoutOption(type: StoreLayoutType, icon: String, title: String, subtitle: String) -> some View {
        let isSelected = layoutType == type

        return Button(action: {
            layoutType = type
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isSelected ? DesignSystem.Colors.neonCyan : DesignSystem.Colors.textTertiary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isSelected ? .white : DesignSystem.Colors.textSecondary)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? DesignSystem.Colors.neonCyan : DesignSystem.Colors.textTertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                    .fill(isSelected ? DesignSystem.Colors.neonCyan.opacity(0.08) : Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                            .stroke(isSelected ? DesignSystem.Colors.neonCyan.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var canSave: Bool {
        !storeName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func saveAndAdvance() {
        guard canSave else { return }

        focusedField = nil

        // Save store in background, advance wizard immediately
        let trimmedStoreName = storeName.trimmingCharacters(in: .whitespaces)
        let trimmedChain = chainName.trimmingCharacters(in: .whitespaces)

        // A store with no aisles has nothing to set up in step 2 — create and dismiss.
        let skipAisleSetup = layoutType == .noAisles
        let selectedLayout = layoutType

        isSaving = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if !skipAisleSetup {
            withAnimation(.spring) {
                step = .aisleSetup
            }
        }

        Task {
            let newStore = await viewModel.createStore(
                name: trimmedStoreName,
                chain: trimmedChain.isEmpty ? nil : trimmedChain,
                aisles: [],
                layoutType: selectedLayout
            )

            await MainActor.run {
                isSaving = false
                if let store = newStore {
                    createdStore = store
                }
                if skipAisleSetup {
                    dismiss()
                }
            }
        }
    }
}

#Preview {
    CreateStoreSheet()
        .environmentObject(ShoppingListViewModel())
}
