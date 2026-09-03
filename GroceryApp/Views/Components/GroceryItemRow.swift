import SwiftUI

struct GroceryItemRow: View {
    let item: GroceryItem
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @ObservedObject var userCache = UserCache.shared
    @State private var isPressed = false
    @State private var shakeOffset: CGFloat = 0
    @State private var isShaking = false
    @State private var showDetailSheet = false

    // Transition animation states
    @State private var isTransitioning = false
    @State private var showTransitionGlow = false
    @State private var transitionDirection: TransitionDirection = .none
    @State private var isPulsing = false

    private enum TransitionDirection {
        case none, toSuggestions, toActive, toCart
    }

    private var currentUserId: String {
        AmplifyService.shared.currentUser?.userId ?? ""
    }

    /// Get the current store - uses shopping store if in shopping mode, otherwise first store
    private var currentStore: HouseholdStore? {
        if let shoppingStoreId = viewModel.shoppingStoreId {
            return viewModel.householdStores.first { $0.id == shoppingStoreId }
        }
        return viewModel.householdStores.first
    }

    /// Display name of who last added this item to the active list. "-you-" for current user.
    private var addedByDisplayName: String {
        item.addedBy == currentUserId ? "-you-" : userCache.displayName(for: item.addedBy)
    }

    /// The adder's chosen colour, resolved at render time.
    ///
    /// Nothing is denormalised onto the item — it stores only `addedBy`, and the
    /// colour is looked up here. So changing your colour updates one row and
    /// every attribution on every device follows on its next refresh.
    private var addedByColor: Color {
        ProfileColor.named(userCache.profileColor(for: item.addedBy)).color
    }

    /// Locked by name looked up from cache, shows "-you-" for current user
    private var lockedByDisplayName: String? {
        guard let lockedBy = item.lockedBy else { return nil }
        if lockedBy == currentUserId {
            return "-you-"
        }
        return userCache.displayName(for: lockedBy)
    }

    /// Check if item is locked by another user (not current user)
    /// Note: Locks are ignored during shopping mode - only the shopper can modify items
    private var isLockedByAnotherUser: Bool {
        // During shopping mode, ignore locks - shopper has full control
        if viewModel.isCurrentUserShopping {
            return false
        }
        guard let lockedBy = item.lockedBy else { return false }
        return lockedBy != currentUserId
    }

    /// Check if item was remotely added and should show badge (during shopping mode)
    private var showRemoteAddedBadge: Bool {
        item.remoteAddedAt != nil && !item.hasSeenRemoteBadge && viewModel.isCurrentUserShopping
    }

    /// Check if item should pulse (recently added, within 3 seconds)
    private var shouldPulse: Bool {
        guard let remoteAddedAt = item.remoteAddedAt else { return false }
        return Date().timeIntervalSince(remoteAddedAt) < 3.0 && viewModel.isCurrentUserShopping
    }

    var body: some View {
        rowContent
            // Swipe LEFT: archive, never destroy. Delete used to live here and was
            // reachable by a hard swipe while scrolling — an irreversible action on
            // the same gesture people use to scroll past things. It now lives in the
            // context menu, so nothing on the swipe surface can lose data.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if item.status == .active {
                    if isLockedByAnotherUser {
                        // Not role: .destructive — that plays the removal animation
                        // on a row that is not going anywhere.
                        Button {
                            triggerShake()
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                            if let lockedBy = item.lockedBy {
                                viewModel.showLockedItemWarning(lockedBy: lockedBy)
                            }
                        } label: {
                            Label("Move", systemImage: "arrow.uturn.down")
                        }
                        .tint(.gray)
                    } else {
                        Button {
                            animateToSuggestions()
                        } label: {
                            Label("Suggestions", systemImage: "arrow.uturn.down")
                        }
                        .tint(DesignSystem.Colors.neonAmber)
                    }
                } else if item.status == .suggestion {
                    // On a suggestion, swipe-left is otherwise dead — there is
                    // nowhere to archive it to. Delete is the only thing it can
                    // mean here, and it is the only place a mis-dictated item
                    // ("cucumber diapers") can be got rid of once it has settled
                    // into the archive. Still confirms; still no full swipe.
                    //
                    // Red by tint, NOT `role: .destructive`. The role is not
                    // styling: SwiftUI hands it to UICollectionView as a real
                    // row deletion and animates the row out, expecting the data
                    // source to have shrunk by one in the same turn. This button
                    // only asks a question, so the count never changed, and UIKit
                    // aborted with "Invalid Number Of Items In Section" —
                    // confirmed in the crash report from 2026-09-03 17:52. It
                    // also took the confirmation down with the row it removed,
                    // which is why the dialog flashed and the item vanished
                    // without anybody answering it.
                    Button {
                        viewModel.itemPendingDeletion = item
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                // Swipe RIGHT: suggestions → active only. restoreItem enforces the
                // read-only rule if someone else is mid-trip.
                if item.status == .suggestion {
                    Button {
                        animateToActive()
                    } label: {
                        Label("Add to List", systemImage: "plus.circle.fill")
                    }
                    .tint(DesignSystem.Colors.dillGreen)
                }
            }
            // Long-press. Uses .contextMenu rather than a raw long-press gesture so
            // the duration, preview and destructive styling are the system's, not
            // ours — this is where iOS users look for row actions that are not on
            // the swipe.
            .contextMenu {
                Button(role: .destructive) {
                    viewModel.itemPendingDeletion = item
                } label: {
                    Label("Delete permanently", systemImage: "trash")
                }
            }
            .offset(x: shakeOffset)
            .overlay(transitionOverlay)
            .onTapGesture {
                // Block interactions briefly after app wakeup
                guard !viewModel.isInteractionLocked else { return }

                // Block any action if locked by another user
                if isLockedByAnotherUser, let lockedBy = item.lockedBy {
                    triggerShake()
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    viewModel.showLockedItemWarning(lockedBy: lockedBy)
                    return
                }

                if item.status == .active {
                    if viewModel.isCurrentUserShopping {
                        animateToCart()
                    } else if viewModel.isListLockedByOtherSession {
                        // Read-only while someone else is out. This used to file a
                        // removal request into an inbox; that flow is gone.
                        triggerShake()
                        viewModel.warnListReadOnly()
                    } else {
                        animateToSuggestions()
                    }
                } else if item.status == .suggestion {
                    animateToActive()
                } else if item.status == .inCart {
                    animateToActive()
                }
            }
            .sheet(isPresented: $showDetailSheet) {
                ItemDetailSheet(item: item)
                    .environmentObject(viewModel)
            }
    }

    // MARK: - Row Content

    private var rowContent: some View {
        ZStack {
            // Skeleton placeholder (visible when animating in)
            if item.isAnimatingIn {
                skeletonView
                    .transition(.opacity)
            }

            // Actual content
            itemContentView
                .opacity(item.isAnimatingIn ? 0 : 1)
        }
        .padding(16)
        .background(cardBackground)
        .cornerRadius(16)
        .overlay(animatingInGlow)
        .opacity(item.isPendingRemoval ? 0.5 : 1.0)
        .scaleEffect(scaleValue)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .animation(.easeOut(duration: 0.3), value: item.isAnimatingIn)
    }

    private var scaleValue: CGFloat {
        if item.isPendingRemoval { return 0.95 }
        // Don't show press scale for locked items (prevents visual glitch during shake)
        if isPressed && !isShaking { return 0.98 }
        return 1.0
    }

    private var itemContentView: some View {
        HStack(alignment: .top, spacing: 12) {
            // Show icon for suggestions and inCart items
            statusIcon

            VStack(alignment: .leading, spacing: 4) {
                itemNameRow
                ownerRow
            }

            Spacer()

            // Lock info in top right when locked: [Username] <lock>
            // Hide lock icons during shopping mode - locks are not honored while shopping
            if let lockedByName = lockedByDisplayName, !viewModel.isCurrentUserShopping {
                HStack(spacing: 4) {
                    Text("[\(lockedByName)]")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.neonPink.opacity(0.8))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.neonPink)
                }
            }

            // Detail sheet button
            Button {
                showDetailSheet = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Shows who added the item [Username]
    private var ownerRow: some View {
        HStack(spacing: 6) {
            if item.status == .active {
                Text("[\(addedByDisplayName)]")
                    .font(.system(size: 11, weight: .medium))
                    // Near full strength. The 11pt size already keeps this
                    // subordinate to the item name, and knocking the colour back
                    // as well pushed the darker end of the palette — purple,
                    // blue — close to invisible on the near-black ground.
                    .foregroundColor(addedByColor.opacity(0.9))
            }
        }
    }

    private var itemNameColor: Color {
        switch item.status {
        case .suggestion:
            return DesignSystem.Colors.neonAmber.opacity(0.85)
        case .inCart:
            return DesignSystem.Colors.success.opacity(0.6)
        default:
            return DesignSystem.Colors.textPrimary
        }
    }

    private var itemNameWeight: Font.Weight {
        (item.status == .suggestion || item.status == .inCart) ? .regular : .medium
    }

    private var itemNameRow: some View {
        HStack(spacing: 8) {
            // Item name with optional inline notes
            if let notes = item.notes, !notes.isEmpty {
                (Text(item.name)
                    .font(.system(size: 16, weight: itemNameWeight))
                    .foregroundColor(itemNameColor)
                    .strikethrough(item.status == .inCart, color: itemNameColor.opacity(0.5))
                +
                Text(" · ")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                +
                // Trip-scoped notes lean italic — the only cue that they won't outlive the trip
                Text(notes)
                    .font(item.notesEphemeral
                        ? .system(size: 14, weight: .regular).italic()
                        : .system(size: 14, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textTertiary))
            } else {
                Text(item.name)
                    .font(.system(size: 16, weight: itemNameWeight))
                    .foregroundColor(itemNameColor)
                    .strikethrough(item.status == .inCart, color: itemNameColor.opacity(0.5))
            }

            // Remote-added badge (sparkle) for items added by others during shopping
            if showRemoteAddedBadge {
                remoteAddedBadge
            }

            // Photo icon for items with images
            if !item.images.isEmpty {
                photoBadge
            }

            // No aisle badge. It only ever rendered while at a store, which is
            // the one screen that already groups rows under an aisle heading — so
            // every row repeated the header directly above it.
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        if item.isAnimatingIn {
            animatingInBackground
        } else {
            glassCardBackground
        }
    }

    @ViewBuilder
    private var animatingInGlow: some View {
        if item.isAnimatingIn {
            RoundedRectangle(cornerRadius: 16)
                .stroke(DesignSystem.Colors.dillGreen.opacity(0.6), lineWidth: 2)
                .blur(radius: 4)
        } else if showRemoteAddedBadge && isPulsing {
            // Pulsing glow for remotely-added items during shopping mode
            RoundedRectangle(cornerRadius: 16)
                .stroke(DesignSystem.Colors.dillGreen.opacity(0.5), lineWidth: 2)
                .blur(radius: 6)
        }
    }

    // MARK: - Status Icon (shown for suggestions and inCart items)

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .suggestion:
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.neonAmber.opacity(0.15))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .strokeBorder(DesignSystem.Colors.neonAmber.opacity(0.4), lineWidth: 1)
                    )

                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.neonAmber)
            }
        case .inCart:
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.success.opacity(0.15))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .strokeBorder(DesignSystem.Colors.success.opacity(0.4), lineWidth: 1)
                    )

                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.success)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Aisle Badge

    // MARK: - Photo Badge

    private var photoBadge: some View {
        Image(systemName: "photo.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(DesignSystem.Colors.dillGreen)
    }

    // MARK: - Remote Added Badge (sparkle)

    private var remoteAddedBadge: some View {
        Text("✨")
            .font(.system(size: 12))
            .scaleEffect(isPulsing ? 1.2 : 1.0)
            .opacity(isPulsing ? 1.0 : 0.8)
            .animation(
                shouldPulse
                    ? Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear {
                if shouldPulse {
                    isPulsing = true
                    // Stop pulsing after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        isPulsing = false
                    }
                }
            }
    }

    // MARK: - Skeleton View (for animating in)

    private var skeletonView: some View {
        HStack(spacing: 12) {
            // Skeleton content (no checkbox for active items)
            VStack(alignment: .leading, spacing: 6) {
                // Name placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 120, height: 14)

                // Metadata placeholder
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 80, height: 10)
            }

            Spacer()
        }
    }

    // MARK: - Animating In Background

    private var animatingInBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white.opacity(0.02))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.dillGreen.opacity(0.4),
                                DesignSystem.Colors.neonPurple.opacity(0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
    }

    // MARK: - Glass Card Background

    private var glassCardBackground: some View {
        let isSuggestion = item.status == .suggestion
        let borderColor: Color = {
            if isSuggestion {
                return DesignSystem.Colors.neonAmber.opacity(0.35)
            } else if item.isCustom {
                return DesignSystem.Colors.neonPink.opacity(0.5)
            } else {
                return DesignSystem.Colors.dillGreen.opacity(0.3)
            }
        }()

        return RoundedRectangle(cornerRadius: 16)
            .fill(isSuggestion ? DesignSystem.Colors.neonAmber.opacity(0.04) : Color.white.opacity(0.05))
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [
                                isSuggestion ? DesignSystem.Colors.neonAmber.opacity(0.08) : Color.white.opacity(0.1),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blur(radius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        LinearGradient(
                            colors: [borderColor, Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }

    // MARK: - Shake Animation

    private func triggerShake() {
        guard !isShaking else { return }
        isShaking = true

        // Rapid shake animation
        withAnimation(.linear(duration: 0.08)) {
            shakeOffset = 10
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.linear(duration: 0.08)) {
                shakeOffset = -10
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.linear(duration: 0.08)) {
                shakeOffset = 8
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.linear(duration: 0.08)) {
                shakeOffset = -8
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.linear(duration: 0.08)) {
                shakeOffset = 0
            }
            isShaking = false
        }
    }

    // MARK: - Transition Overlay

    @ViewBuilder
    private var transitionOverlay: some View {
        if showTransitionGlow {
            let glowColor: Color = {
                switch transitionDirection {
                case .toActive, .toCart:
                    return DesignSystem.Colors.dillGreen
                case .toSuggestions:
                    return DesignSystem.Colors.neonAmber
                case .none:
                    return DesignSystem.Colors.dillGreen
                }
            }()

            RoundedRectangle(cornerRadius: 16)
                .fill(glowColor.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(glowColor, lineWidth: 2)
                )
                .blur(radius: 2)
        }
    }

    // MARK: - Transition Animations

    private func animateToSuggestions() {
        guard !isTransitioning else { return }
        isTransitioning = true
        transitionDirection = .toSuggestions

        // Brief glow flash as visual cue
        withAnimation(.easeIn(duration: 0.15)) {
            showTransitionGlow = true
        }

        // Perform the move after glow — list .transition() handles departure animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            showTransitionGlow = false
            Task {
                await viewModel.moveToSuggestion(item)
            }
            isTransitioning = false
            transitionDirection = .none
        }
    }

    private func animateToCart() {
        guard !isTransitioning else { return }
        isTransitioning = true
        transitionDirection = .toCart

        // Brief glow flash as visual cue
        withAnimation(.easeIn(duration: 0.15)) {
            showTransitionGlow = true
        }

        // Perform the move after glow — list .transition() handles departure animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            showTransitionGlow = false
            Task {
                await viewModel.moveToCart(item)
            }
            isTransitioning = false
            transitionDirection = .none
        }
    }

    private func animateToActive() {
        guard !isTransitioning else { return }
        isTransitioning = true
        transitionDirection = .toActive

        // Brief glow flash as visual cue
        withAnimation(.easeIn(duration: 0.15)) {
            showTransitionGlow = true
        }

        // Perform the move after glow — list .transition() handles departure animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            showTransitionGlow = false
            Task {
                await viewModel.restoreItem(item)
            }
            isTransitioning = false
            transitionDirection = .none
        }
    }
}

#Preview {
    ZStack {
        DesignSystem.Colors.background
            .ignoresSafeArea()

        DesignSystem.Colors.darkMetallicGradient
            .ignoresSafeArea()
            .opacity(0.3)

        VStack(spacing: 16) {
            GroceryItemRow(item: .preview)
            GroceryItemRow(item: .customPreview)
            GroceryItemRow(item: .lockedPreview)
            GroceryItemRow(item: .animatingInPreview)
        }
        .padding(20)
    }
    .environmentObject(ShoppingListViewModel())
}
