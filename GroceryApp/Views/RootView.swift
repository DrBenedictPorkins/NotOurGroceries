import SwiftUI

struct RootView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @StateObject private var loadingState = AppLoadingState.shared

    var body: some View {
        Group {
            if loadingState.isLoading {
                SplashView()
            } else if !amplifyService.isAuthenticated {
                AuthGateView()
            } else if amplifyService.currentHouseholdId == nil {
                HouseholdSetupView()
            } else {
                ContentView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: loadingState.isLoading)
        .animation(.easeInOut(duration: 0.3), value: amplifyService.isAuthenticated)
        .animation(.easeInOut(duration: 0.3), value: amplifyService.currentHouseholdId)
        .sheet(item: $loadingState.error) { error in
            ErrorModalView(error: error)
        }
        .task {
            await performInitialization()
        }
    }

    private func performInitialization() async {
        // Step 1: Initializing
        loadingState.setStep(.initializing)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Step 2: Configure Amplify
        loadingState.setStep(.configuringServices)
        do {
            await amplifyService.configure()
            if !amplifyService.isConfigured {
                loadingState.reportError(
                    title: "Connection Failed",
                    message: "Could not connect to the server. Please check your internet connection and try again.",
                    details: "Amplify configuration failed"
                )
                return
            }
        } catch {
            loadingState.reportError(
                title: "Connection Failed",
                message: "Could not connect to the server.",
                details: error.localizedDescription
            )
            return
        }

        // Step 3: Validate Login
        loadingState.setStep(.validatingLogin)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // If not authenticated, we're done loading - show auth screen
        guard amplifyService.isAuthenticated else {
            loadingState.setStep(.ready)
            return
        }

        // Step 4: Sync Products
        loadingState.setStep(.syncingProducts)
        await ProductCache.shared.fetchAllProducts()

        // Step 5: Sync Lists (if user has a household)
        if amplifyService.currentHouseholdId != nil {
            loadingState.setStep(.syncingLists)
            await UserCache.shared.fetchUsersForHousehold(amplifyService.currentHouseholdId!)
        }

        // Done
        loadingState.setStep(.ready)
    }
}

// MARK: - Splash View (Loading state)
struct SplashView: View {
    @ObservedObject private var loadingState = AppLoadingState.shared

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.darkMetallicGradient
                .ignoresSafeArea()
                .opacity(0.3)

            VStack(spacing: 32) {
                Spacer()

                // App Icon
                Image(systemName: "cart.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(DesignSystem.Colors.accentGradient)
                    .neonGlow(color: DesignSystem.Colors.neonCyan)

                Text("NotOurGroceries")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.accentGradient)

                Spacer()

                // Progress Section
                VStack(spacing: 16) {
                    if loadingState.isReady {
                        // Ready state - show button
                        Button(action: {
                            loadingState.dismissSplash()
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }) {
                            Text("Let's Shop!")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(DesignSystem.Colors.accentGradient)
                                        .shadow(color: DesignSystem.Shadows.neonCyanGlow, radius: 12, x: 0, y: 6)
                                )
                        }
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .opacity
                        ))
                    } else {
                        // Loading state - show progress
                        VStack(spacing: 16) {
                            // Status Text
                            Text(loadingState.currentStep.description)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(DesignSystem.Colors.textSecondary)
                                .animation(.easeInOut, value: loadingState.currentStep)

                            // Progress Bar
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    // Background track
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.1))
                                        .frame(height: 8)

                                    // Progress fill
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(DesignSystem.Colors.accentGradient)
                                        .frame(width: geometry.size.width * loadingState.currentStep.progress, height: 8)
                                        .animation(.easeInOut(duration: 0.3), value: loadingState.currentStep)
                                }
                            }
                            .frame(height: 8)

                            // Step indicator
                            HStack(spacing: 8) {
                                ForEach(LoadingStep.allCases.filter { $0 != .ready }, id: \.rawValue) { step in
                                    Circle()
                                        .fill(step.rawValue <= loadingState.currentStep.rawValue
                                              ? DesignSystem.Colors.neonCyan
                                              : Color.white.opacity(0.2))
                                        .frame(width: 8, height: 8)
                                        .animation(.easeInOut, value: loadingState.currentStep)
                                }
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 80)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: loadingState.isReady)
            }
        }
    }
}

// MARK: - Error Modal View
struct ErrorModalView: View {
    let error: AppError
    @Environment(\.dismiss) private var dismiss
    @State private var showCopied = false

    var body: some View {
        NavigationView {
            ZStack {
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Error Icon
                        HStack {
                            Spacer()
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 60))
                                .foregroundColor(DesignSystem.Colors.neonPink)
                            Spacer()
                        }
                        .padding(.top, 20)

                        // Title
                        Text(error.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(DesignSystem.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .center)

                        // Message
                        Text(error.message)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)

                        Divider()
                            .background(Color.white.opacity(0.2))

                        // Technical Details
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Debug Information")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(DesignSystem.Colors.neonCyan)

                            Text(error.formattedDetails)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundColor(DesignSystem.Colors.textSecondary)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.black.opacity(0.3))
                                )
                        }

                        // Copy Button
                        Button(action: {
                            UIPasteboard.general.string = error.formattedDetails
                            showCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                showCopied = false
                            }
                        }) {
                            HStack {
                                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                Text(showCopied ? "Copied!" : "Copy Debug Info")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(0.1))
                            )
                        }

                        // Retry Button
                        Button(action: {
                            dismiss()
                            AppLoadingState.shared.reset()
                        }) {
                            Text("Retry")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(DesignSystem.Colors.accentGradient)
                                )
                        }
                    }
                    .padding(24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Dismiss") {
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    RootView()
        .environmentObject(AmplifyService.shared)
}
