import SwiftUI
import OSLog

struct ContentView: View {
    private let logger = Logger(subsystem: "com.byteclub.grocery", category: "Launch")
    @EnvironmentObject var amplifyService: AmplifyService
    @StateObject private var viewModel = ShoppingListViewModel()

    // Shopping status check state
    @State private var hasCheckedShoppingStatus = false
    @State private var showInfoModal = false
    @State private var isAtStoreMode = false

    // The allowance pop-up. Shown on launch and on return to the foreground
    // after a long background, when half or more of a recurring allowance is
    // gone, and never while a trip is on — see MONETIZATION.qmd, "The nudge".
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var allowances = AllowanceService.shared
    @State private var backgroundedAt: Date?
    @State private var showAllowanceNudge = false
    @ObservedObject private var devices = DeviceRegistry.shared
    @State private var isFlushingForEviction = false
    @State private var showAllowances = false
    private static let longBackground: TimeInterval = 90 * 60

    var body: some View {
        ZStack {
            // Everyone in the household watches the same screen while a trip is
            // running. It used to be the shopper's alone: the others stayed on
            // the plain list, in a different order, with no sign of what had been
            // ticked off — same data, two pictures, and the person at home could
            // not tell what was already in the trolley.
            if isAtStoreMode || viewModel.shoppingStatus == .atStore {
                AtStoreModeView(isPresented: $isAtStoreMode)
                    .environmentObject(viewModel)
                    .environmentObject(amplifyService)
            } else {
                // Normal TabView
                TabView {
                    ShoppingListView()
                        .tabItem {
                            Label("Shopping List", systemImage: "list.bullet")
                        }

                    StoresView()
                        .tabItem {
                            Label("Stores", systemImage: "building.2.fill")
                        }

                    HouseholdView()
                        .tabItem {
                            Label("Household", systemImage: "person.3.fill")
                        }

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape.fill")
                        }
                }
                .tint(DesignSystem.Colors.dillGreen)
                .metallicBackground()
                .environmentObject(viewModel)
                .environmentObject(amplifyService)
            }

            // The allowance pop-up, same card and place as the shopping modal.
            if showAllowanceNudge, let summary = allowances.summary {
                AllowanceNudgeModal(
                    summary: summary,
                    itemsUsed: viewModel.totalItemCount,
                    onSeeAllowances: {
                        withAnimation(.easeOut(duration: 0.2)) { showAllowanceNudge = false }
                        showAllowances = true
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.2)) { showAllowanceNudge = false }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(99)
            }

            // The account has moved to another phone. Above everything, because
            // nothing on the screen underneath belongs to this device any more.
            if let other = devices.supersededBy {
                DeviceSupersededModal(
                    otherDeviceName: other,
                    stuck: viewModel.stuckSyncNames,
                    isFlushing: isFlushingForEviction,
                    onSignOut: {
                        devices.clearSuperseded()
                        Task { try? await amplifyService.signOut() }
                    }
                )
                .transition(.opacity)
                .zIndex(200)
            }

            // Info modal overlay
            if showInfoModal {
                ShoppingActiveInfoModal(
                    isCurrentUserShopping: viewModel.isCurrentUserShopping,
                    shopperName: viewModel.activeShopperDisplayName,
                    storeName: shoppingStoreName,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showInfoModal = false
                        }
                    },
                    onTakeOver: {
                        withAnimation(.easeOut(duration: 0.2)) { showInfoModal = false }
                        Task {
                            await viewModel.takeOverShopping()
                            if viewModel.isCurrentUserShopping { isAtStoreMode = true }
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isAtStoreMode)
        // Presented here, above every list that shows a row. Owned by the row,
        // this sheet was torn down whenever the list rebuilt underneath it —
        // which is what saying an aisle out loud does, because the write
        // republishes the stores.
        .sheet(item: $viewModel.itemShowingDetail) { item in
            ItemDetailSheet(item: item)
                .environmentObject(viewModel)
        }
        // Deleting an item is confirmed here, above every list that shows one.
        // Owned by a row, this dialog was presented while the swipe collapsed and
        // the row was rebuilt underneath it — it flashed and its Delete fired on
        // its own. Delete is for an item that should not exist: a mis-heard
        // dictation, a typo. It is not "not this week", which is what tapping the
        // row does, and the message says so because both make the row disappear
        // and only one is recoverable.
        .confirmationDialog(
            viewModel.itemPendingDeletion.map { "Delete \($0.name)?" } ?? "Delete this item?",
            isPresented: Binding(
                get: { viewModel.itemPendingDeletion != nil },
                set: { if !$0 { viewModel.itemPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let doomed = viewModel.itemPendingDeletion else { return }
                viewModel.itemPendingDeletion = nil
                Task { await viewModel.deleteItem(doomed) }
            }
            Button("Cancel", role: .cancel) { viewModel.itemPendingDeletion = nil }
        } message: {
            Text("This removes it permanently. To keep it for next time, tap the item instead — it moves to suggestions.")
        }
        .task {
            await runLaunchHandshake()
        }
        .onReceive(NetworkStatus.shared.$pathIsSatisfied) { satisfied in
            guard satisfied else { return }
            Task {
                await comeBackOnTheGridIfPossible()
                await flushPendingFinish()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = Date()
            case .active:
                // Refresh on every return so the feature gates are current; the
                // card only after a long time away.
                let longEnough = backgroundedAt.map { Date().timeIntervalSince($0) >= Self.longBackground } ?? false
                backgroundedAt = nil
                // First, because everything else is a request and the sockets
                // are what keep the list current between them.
                viewModel.reconnectSubscriptions()
                Task {
                    await comeBackOnTheGridIfPossible()
                    await flushPendingFinish()
                    await standDownIfSuperseded()
                    await refreshAllowancesAndMaybeNudge(showCard: longEnough)
                }
            default:
                break
            }
        }
        .sheet(isPresented: $showAllowances) {
            AllowancesView()
                .environmentObject(viewModel)
        }
        // On every tab and inside a shopping trip, because a failure is not a
        // property of the screen you happened to be on.
        //
        // `safeAreaInset` rather than an overlay: it pushes the content down
        // instead of covering it. As an overlay the banner landed on top of the
        // heading and the two were unreadable through each other.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = viewModel.activeError {
                ErrorBanner(error: error) {
                    withAnimation(.easeOut(duration: 0.2)) { viewModel.activeError = nil }
                }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: viewModel.activeError)
        .allowanceRefusal($viewModel.allowanceRefusal, viewModel: viewModel)
        // Attached here, not on the list screen, so it is seen whichever tab is
        // open. A list that has stopped tracking the household is not something
        // to mention quietly on one screen.
        .overlay {
            if !viewModel.stuckSyncNames.isEmpty {
                SyncStuckModal(
                    stuckNames: viewModel.stuckSyncNames,
                    onDiscardAndReload: {
                        Task { await viewModel.discardStuckChangesAndReload() }
                    },
                    onKeepTrying: { viewModel.stuckSyncNames = [] }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(98)
            }
        }
        .onChange(of: isAtStoreMode) { _, newValue in
            // When exiting shopping mode, sync the viewModel state
            if !newValue {
                viewModel.isAtStoreMode = false
            }
        }
    }

    // MARK: - Computed Properties

    private var shoppingStoreName: String? {
        guard let storeId = viewModel.shoppingStoreId else { return nil }
        return viewModel.householdStores.first(where: { $0.id == storeId })?.name
    }

    // MARK: - Allowances

    private func refreshAllowancesAndMaybeNudge(showCard: Bool) async {
        await allowances.refresh()
        guard showCard else { return }
        maybeShowAllowanceNudge()
    }

    /// The decision half, separated from the fetch so the launch handshake can
    /// time the fetch as its own step and still ask this afterwards.
    @MainActor
    private func maybeShowAllowanceNudge() {
        // The hard rule: never while at the store. `isAtStoreMode` covers the
        // shopper; `shoppingStatus` covers everyone else in the household.
        guard !isAtStoreMode, viewModel.shoppingStatus != .atStore else { return }
        guard let summary = allowances.summary, !summary.entitled else { return }
        let freshSignIn = allowances.showOnNextAppearance
        allowances.showOnNextAppearance = false
        if freshSignIn || summary.warrantsNudge(itemCount: viewModel.totalItemCount) {
            withAnimation(.easeIn(duration: 0.3)) { showAllowanceNudge = true }
        }
    }

    /// Has another phone taken this account?
    ///
    /// Checked on launch and on every return to the foreground, because Cognito's
    /// own eviction only bites when the access token lapses — up to an hour, all
    /// of it spent as a second shopper the household cannot see.
    ///
    /// Anything this phone still owes the server is pushed first. A superseded
    /// device is about to become unreachable, so this is the last chance those
    /// changes have; whatever will not go is named before it is lost.
    private func standDownIfSuperseded(askServer: Bool = true) async {
        // The launch handshake already answered this in the same round trip that
        // rebuilt the screen, so asking again there would be a second call for a
        // question we hold the answer to.
        if askServer { await devices.verify() }
        guard devices.supersededBy != nil else { return }
        guard !isFlushingForEviction else { return }

        isFlushingForEviction = true
        await viewModel.sendPendingFinish()
        _ = await viewModel.flushOutbox()
        isFlushingForEviction = false
    }

    /// Off-grid ends by itself, not by the person remembering to leave it.
    ///
    /// Tried whenever the app comes forward and whenever an interface appears —
    /// the two moments a phone that was in a shop basement is likely to have
    /// signal again. Costs one token refresh and does nothing at all when there
    /// is still no network.
    private func comeBackOnTheGridIfPossible() async {
        guard amplifyService.isOffGrid else { return }
        await amplifyService.retrySessionIfOffGrid()
        guard !amplifyService.isOffGrid else { return }
        viewModel.showToast(message: "Back on the grid — sending your changes.", type: .success)
        await viewModel.refreshAllData()
    }

    /// A trip that ended with no signal still has one call to make. Tried on
    /// every return to the app, whether or not we were ever off-grid — the
    /// common case is a trip finished in a car park by somebody who never lost
    /// their session, only their bars.
    private func flushPendingFinish() async {
        guard PendingFinishStore.isPending else { return }
        await viewModel.sendPendingFinish()
    }

    // MARK: - Shopping Status Check

    /// The second half of the launch handshake, run while the splash is still on
    /// screen.
    ///
    /// These four used to run after the splash had gone. On a good connection
    /// nobody noticed; on a bad one the list, the stores and the allowance card
    /// arrived one at a time over the following minute, on top of a screen the
    /// person was already using, with nothing to say why. Everything the app
    /// needs before it is usable is now watched, named and given a deadline.
    private func runLaunchHandshake() async {
        let loading = AppLoadingState.shared
        await loading.waitForPhaseOne()

        guard !hasCheckedShoppingStatus else { return }
        hasCheckedShoppingStatus = true

        // Off-grid means the server has already been shown not to answer. The
        // snapshot is on screen; asking again would only cost a deadline.
        if amplifyService.isOffGrid {
            loading.setStep(.ready)
            return
        }

        // One call for everything: profile, household, members, items, stores,
        // allowances, the catalogue, and whether this device still holds the
        // account. Eight round trips became one, and eight ways of being half
        // loaded became none.
        var restoreShopping = false
        var handshakeDone = false

        while !handshakeDone {
            var failure: ServiceFailure?
            await loading.perform(.syncing) {
                do {
                    let result = try await HandshakeService.run(deviceId: DeviceRegistry.shared.deviceId)
                    viewModel.apply(handshake: result)
                    restoreShopping = viewModel.isCurrentUserShopping
                    if !result.deviceStillOurs {
                        DeviceRegistry.shared.noteSuperseded(by: result.activeDeviceName)
                    }
                } catch {
                    failure = ServiceFailure.from(error)
                }
            }

            guard let failure else { handshakeDone = true; break }

            SessionLog.shared.failure("launch", "handshakeFailed", failure)

            // Offline is a condition the app is built to carry on through — the
            // snapshot is already on screen and the header says what it is.
            // Anything else is a fault: we do not know what the household looks
            // like, and walking somebody into a list built from a stale file
            // while a banner apologises for it is the half-loaded state this
            // whole call was meant to end. So stop and ask.
            if failure.isOffline {
                viewModel.noteOfflineAtLaunch()
                handshakeDone = true
                break
            }

            if await loading.askAboutFailure(.syncing, failure) == .skip {
                viewModel.noteOfflineAtLaunch()
                handshakeDone = true
            }
        }

        let shouldRestoreShoppingMode = restoreShopping
        loading.setStep(.ready)

        await standDownIfSuperseded(askServer: false)
        applyShoppingStatusOnLaunch(shouldRestoreShoppingMode)
        maybeShowAllowanceNudge()
    }

    @MainActor
    private func applyShoppingStatusOnLaunch(_ shouldRestoreShoppingMode: Bool) {
        // AT_STORE with nobody holding the slot is not somebody else's trip,
        // it is a wedged household: the button is hidden because a trip is
        // running, and no one can end a trip they do not own. Treat it as
        // over so the app can always be used.
        if viewModel.shoppingStatus == .atStore, viewModel.activeShopperId == nil {
            viewModel.shoppingStatus = .idle
            return
        }

        if viewModel.shoppingStatus == .atStore {
            // Shopping is active - show info modal
            if shouldRestoreShoppingMode {
                // Current user is the shopper
                viewModel.isAtStoreMode = true
                isAtStoreMode = true
            }
            // Show info modal for both shopper and non-shopper
            withAnimation(.easeIn(duration: 0.3)) {
                showInfoModal = true
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AmplifyService.shared)
}
