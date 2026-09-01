import SwiftUI

struct CreateStoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @State private var storeName = ""
    @State private var chainName = ""
    @State private var createdStore: HouseholdStore?
    @State private var createStoreFailed = false
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
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                }
            }
        }
    }

    // MARK: - Step 1: Store Info

    private var storeInfoStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                storeInfoSection


                // Next button
                Button(action: saveAndAdvance) {
                    HStack(spacing: 8) {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        }
                        Text("Create Store")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                            .fill(canSave ? DesignSystem.Colors.dillGreen : DesignSystem.Colors.dillGreen.opacity(0.3))
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

            // This screen appears the moment Save is tapped, before the store
            // actually exists, so the headline has to follow the real state. It
            // used to show a green tick and "Store created!" while the mutation
            // was still in flight — and if that mutation failed it said so
            // permanently, with a spinner and no way forward.
            VStack(spacing: 16) {
                if createStoreFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundColor(DesignSystem.Colors.neonPink)

                    Text("Couldn't create the store")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Nothing was saved. Go back and try again.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else if createdStore == nil {
                    ProgressView()
                        .scaleEffect(1.6)
                        .tint(DesignSystem.Colors.dillGreen)
                        .frame(height: 56)

                    Text("Creating store…")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)

                    Text("One moment.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundColor(DesignSystem.Colors.success)

                    Text("Store created!")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)

                    Text("It comes with the usual departments. Put them in the order you walk the shop from the store's page.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Button(action: {
                dismiss()
            }) {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.dillGreen)
            }

            Spacer()
        }
    }

    // MARK: - Store Info Section

    private var storeInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STORE INFORMATION")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DesignSystem.Colors.dillGreen)
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
                                        .stroke(focusedField == .storeName ? DesignSystem.Colors.dillGreen.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
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
                                        .stroke(focusedField == .chainName ? DesignSystem.Colors.dillGreen.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
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
        // Straight to created. Every store arrives with the standard sections
        // already on it, so there is nothing to set up here — and asking someone
        // to type aisle numbers before they have ever used the store was the
        // step people abandoned. Aisles are added afterwards, one at a time, by
        // saying where something is while standing in front of it.
        isSaving = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        Task {
            let newStore = await viewModel.createStore(
                name: trimmedStoreName,
                chain: trimmedChain.isEmpty ? nil : trimmedChain,
                aisles: []
            )

            await MainActor.run {
                isSaving = false
                if let store = newStore {
                    createdStore = store
                } else {
                    createStoreFailed = true
                }
                dismiss()
            }
        }
    }
}

#Preview {
    CreateStoreSheet()
        .environmentObject(ShoppingListViewModel())
}
