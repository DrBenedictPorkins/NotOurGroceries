import SwiftUI

struct RootView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @StateObject private var loadingState = AppLoadingState.shared

    var body: some View {
        ZStack {
            // The real screen is mounted underneath the splash rather than after
            // it. The second half of the handshake — list, stores, trip,
            // allowances — belongs to `ContentView`, because it owns the view
            // model those calls write into, and it cannot run it if it does not
            // exist yet. The splash sits on top until every step is done.
            Group {
                if !amplifyService.isAuthenticated && !amplifyService.isOffGrid {
                    AuthGateView()
                        // Says why you are looking at a sign-in screen when you were
                        // signed in a minute ago. Without it a bad connection on
                        // launch is indistinguishable from having been signed out,
                        // and the natural response is to type your password again.
                        .overlay(alignment: .top) {
                            if amplifyService.sessionCheckFailedOffline {
                                Text("Couldn't reach the server to check your sign-in. If you were already signed in, try again when you have signal.")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(DesignSystem.Colors.neonAmber)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(DesignSystem.Colors.cardBackground)
                                            .overlay(RoundedRectangle(cornerRadius: 14)
                                                .stroke(DesignSystem.Colors.neonAmber.opacity(0.5), lineWidth: 1))
                                    )
                                    .padding(.horizontal, 24)
                                    .padding(.top, 60)
                            }
                        }
                } else if amplifyService.currentHouseholdId == nil {
                    HouseholdSetupView()
                } else {
                    ContentView()
                }
            }
            // Mounted, but not reachable. The splash covers it visually; without
            // these it is still in the accessibility tree and still takes taps
            // through the cover, so VoiceOver reads a list nobody can see and a
            // stray tap lands on a row.
            .allowsHitTesting(!loadingState.isLoading)
            .accessibilityHidden(loadingState.isLoading)

            if loadingState.isLoading {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1000)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: loadingState.isLoading)
        .animation(.easeInOut(duration: 0.3), value: amplifyService.isAuthenticated)
        .animation(.easeInOut(duration: 0.3), value: amplifyService.currentHouseholdId)
        .animation(.easeInOut(duration: 0.3), value: amplifyService.isOffGrid)
        .sheet(item: $loadingState.error) { error in
            ErrorModalView(error: error)
        }
        .task {
            await performInitialization()
        }
    }

    /// The first half of the launch handshake: configure, prove who this is, and
    /// fetch the two caches that do not need a household. `ContentView` runs the
    /// second half, which does.
    private func performInitialization() async {
        loadingState.setStep(.initializing)

        // Local file read, not a call — no deadline worth showing.
        loadingState.setStep(.configuringServices)
        await amplifyService.configure()
        if !amplifyService.isConfigured {
            loadingState.reportError(
                title: "Connection Failed",
                message: "Could not connect to the server. Please check your internet connection and try again.",
                details: "Amplify configuration failed"
            )
            loadingState.markPhaseOneComplete()
            return
        }

        // The forced Cognito refresh plus the `getUser` that tells us which
        // household this is. The slowest call at launch, and the one everything
        // after it depends on.
        await loadingState.perform(.validatingLogin) {
            await amplifyService.checkAuthSession()
        }

        // Walking away from the session check used to leave the app looking
        // exactly like a sign-out: the sign-in screen, with no idea why. The
        // check has not failed — it is still in flight — so nothing else sets
        // the banner that exists for precisely this situation.
        //
        // If there is a list on the disk, the honest answer is better than a
        // banner: go off-grid and shop from it.
        if loadingState.wasSkipped(.validatingLogin), !amplifyService.isAuthenticated {
            if amplifyService.canGoOffGrid {
                amplifyService.goOffGrid()
            } else {
                amplifyService.sessionCheckFailedOffline = true
            }
        }

        // Off-grid still has a household and a list, so the second half runs —
        // it will fail against the server and keep the snapshot, which is the
        // whole point.
        guard amplifyService.isAuthenticated || amplifyService.isOffGrid else {
            loadingState.markPhaseOneComplete()
            loadingState.setStep(.ready)
            return
        }

        await loadingState.perform(.syncingProducts) {
            await ProductCache.shared.fetchAllProducts()
        }

        if let householdId = amplifyService.currentHouseholdId {
            await loadingState.perform(.syncingMembers) {
                await UserCache.shared.fetchUsersForHousehold(householdId)
            }
            // ContentView takes it from here and is the one that says `.ready`.
            loadingState.markPhaseOneComplete()
            return
        }

        loadingState.markPhaseOneComplete()
        loadingState.setStep(.ready)
    }
}

// MARK: - Splash View (Loading state)
struct SplashView: View {
    /// One per launch, held for the life of the view so it doesn't
    /// shuffle on every redraw.
    @State private var tagline = AppIdentity.randomTagline()
    @ObservedObject private var loadingState = AppLoadingState.shared

    private var versionString: String { AppVersion.full }

    private var buildDateString: String {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let modDate = attrs[.modificationDate] as? Date else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: modDate)
    }

    /// The auth step is the one where "skip" does not mean skip. There is
    /// nothing behind it but the sign-in screen — unless this phone is carrying
    /// a list, in which case there is somewhere real to go.
    private var stallStep: LoadingStep { loadingState.stalledStep ?? loadingState.currentStep }

    private var stallIsAuthStep: Bool {
        stallStep == .validatingLogin || stallStep == .configuringServices
    }

    private var stallSkipTitle: String {
        guard stallIsAuthStep else { return stallStep.skipButtonTitle }
        return AmplifyService.shared.canGoOffGrid ? "Go off-grid" : "Sign in instead"
    }

    private var stallConsequence: String {
        guard stallIsAuthStep else { return stallStep.stallConsequence }
        return AmplifyService.shared.canGoOffGrid
            ? "Off-grid shops from your saved list. Changes stay on this phone and go up when you're back."
            : stallStep.stallConsequence
    }

    private var stallPrompt: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Still waiting on the server. Your connection may be slow.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.neonAmber)
                Text(stallConsequence)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    loadingState.resolveStall(.retry)
                } label: {
                    Text("Retry")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(DesignSystem.Colors.accentGradient)
                        )
                }

                Button {
                    loadingState.resolveStall(.skip)
                } label: {
                    Text(stallSkipTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.08))
                        )
                }
            }
        }
        .padding(.top, 4)
        .transition(.opacity)
    }

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
                    .neonGlow(color: DesignSystem.Colors.dillGreen)

                Text(AppIdentity.name)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.accentGradient)

                Text(tagline)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)

                VStack(spacing: 4) {
                    Text(versionString)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                    if !buildDateString.isEmpty {
                        Text("Built \(buildDateString)")
                            .font(.system(size: 11))
                            .foregroundColor(DesignSystem.Colors.textSecondary.opacity(0.6))
                    }
                }

                Spacer()

                // Progress Section
                VStack(spacing: 16) {
                    if loadingState.isReady {
                        // What did not make it, said before the button rather
                        // than discovered later as an empty list.
                        if let missing = loadingState.skippedSummary {
                            Text(missing)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DesignSystem.Colors.neonAmber)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 8)
                        }

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
                                        .shadow(color: DesignSystem.Shadows.dillGreenGlow, radius: 12, x: 0, y: 6)
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
                            HStack(spacing: 6) {
                                ForEach(LoadingStep.allCases.filter { $0 != .ready }, id: \.rawValue) { step in
                                    Circle()
                                        .fill(step.rawValue <= loadingState.currentStep.rawValue
                                              ? DesignSystem.Colors.dillGreen
                                              : Color.white.opacity(0.2))
                                        .frame(width: 7, height: 7)
                                        .animation(.easeInOut, value: loadingState.currentStep)
                                }
                            }

                            // A step past its deadline. Rather than a bar that
                            // never moves again, say so and hand the choice over.
                            if loadingState.stalledStep != nil {
                                stallPrompt
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
                                .foregroundColor(DesignSystem.Colors.dillGreen)

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
                    .foregroundColor(DesignSystem.Colors.dillGreen)
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
