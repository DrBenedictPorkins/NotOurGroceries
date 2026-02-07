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

    /// Get the effective aisle string for this item
    private var aisleString: String? {
        guard let store = currentStore else { return nil }
        let mappings = StoreService.shared.productMappings[store.id] ?? []

        let mapping = mappings.first { mapping in
            if let productId = item.productId, let mappingProductId = mapping.productId {
                return productId == mappingProductId
            }
            if let mappingName = mapping.normalizedName {
                return item.normalizedName == mappingName
            }
            return false
        }

        return mapping?.effectiveAisle
    }

    /// Display name looked up from cache, shows "-you-" for current user
    private var addedByDisplayName: String {
        if item.addedBy == currentUserId {
            return "-you-"
        }
        return userCache.displayName(for: item.addedBy)
    }

    /// Locked by name looked up from cache, shows "-you-" for current user
    private var lockedByDisplayName: String? {
        guard let lockedBy = item.lockedBy else { return nil }
        if lockedBy == currentUserId {
            return "-you-"
        }
        return userCache.displayName(for: lockedBy)
    }

    private var groupedReactions: [(emoji: String, count: Int, includesCurrentUser: Bool)] {
        var groups: [String: (count: Int, includesCurrentUser: Bool)] = [:]

        for reaction in item.reactions {
            if var existing = groups[reaction.emoji] {
                existing.count += 1
                if reaction.userId == currentUserId {
                    existing.includesCurrentUser = true
                }
                groups[reaction.emoji] = existing
            } else {
                groups[reaction.emoji] = (count: 1, includesCurrentUser: reaction.userId == currentUserId)
            }
        }

        return groups.map { (emoji: $0.key, count: $0.value.count, includesCurrentUser: $0.value.includesCurrentUser) }
            .sorted { $0.emoji < $1.emoji }
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
            .swipeActions(edge: .trailing, allowsFullSwipe: !isLockedByAnotherUser && !viewModel.isSomeoneElseShopping) {
                // Delete action (both lists - swipe LEFT to delete)
                // When someone else is shopping, show "Suggest Removal" instead
                if viewModel.isSomeoneElseShopping {
                    Button {
                        Task {
                            await viewModel.suggestRemoval(item)
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        Label("Suggest Removal", systemImage: "xmark.circle")
                    }
                    .tint(DesignSystem.Colors.neonPink)
                } else if isLockedByAnotherUser {
                    // Locked by another user - show error feedback instead of delete
                    // Note: Do NOT use role: .destructive as it triggers removal animation
                    Button {
                        triggerShake()
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        if let lockedBy = item.lockedBy {
                            viewModel.showLockedItemWarning(lockedBy: lockedBy)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.gray)
                } else {
                    Button(role: .destructive) {
                        Task {
                            await viewModel.deleteItem(item)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                // Lock/Unlock action (only for active items - swipe RIGHT)
                // Hide during shopping mode - locks don't apply while shopping
                if item.status == .active && !viewModel.isCurrentUserShopping {
                    if isLockedByAnotherUser {
                        // Locked by another user - show error feedback instead of unlock
                        Button {
                            triggerShake()
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                            if let lockedBy = item.lockedBy {
                                viewModel.showLockedItemWarning(lockedBy: lockedBy)
                            }
                        } label: {
                            Label("Unlock", systemImage: "lock.open")
                        }
                        .tint(.gray)
                    } else {
                        Button {
                            Task {
                                await viewModel.toggleLock(item)
                            }
                        } label: {
                            Label(item.lockedBy != nil ? "Unlock" : "Lock", systemImage: item.lockedBy != nil ? "lock.open" : "lock")
                        }
                        .tint(DesignSystem.Colors.neonPurple)
                    }
                }
            }
            .offset(x: shakeOffset)
            .overlay(transitionOverlay)
            .onTapGesture {
                // Block any action if locked by another user
                if isLockedByAnotherUser, let lockedBy = item.lockedBy {
                    triggerShake()
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    viewModel.showLockedItemWarning(lockedBy: lockedBy)
                    return
                }

                if item.status == .suggestion {
                    // Tap on suggestion adds it back to list
                    if viewModel.isSomeoneElseShopping {
                        // Submit request to add this suggestion back
                        Task {
                            await viewModel.submitAddRequest(
                                name: item.name,
                                quantity: item.quantity,
                                notes: item.notes,
                                productId: item.productId
                            )
                        }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } else {
                        animateToActive()
                    }
                } else if item.status == .active {
                    // During shopping: move to cart. During list building: move to suggestions
                    if viewModel.isCurrentUserShopping {
                        animateToCart()
                    } else if viewModel.isSomeoneElseShopping {
                        // Non-shopper can only suggest removal, not directly move
                        Task {
                            await viewModel.submitRemoveRequest(item: item)
                        }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } else {
                        // Normal list building - move to suggestions
                        animateToSuggestions()
                    }
                } else if item.status == .inCart {
                    // Tap on in-cart item restores it to active list
                    animateToActive()
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !isTransitioning { isPressed = true } }
                    .onEnded { _ in isPressed = false }
            )
            .onLongPressGesture(minimumDuration: 0.5) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showDetailSheet = true
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
                ownerAndReactionsRow
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
        }
    }

    /// Shows who added the item [Username] followed by inline reaction badges
    private var ownerAndReactionsRow: some View {
        HStack(spacing: 6) {
            Text("[\(addedByDisplayName)]")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(item.status == .suggestion ? DesignSystem.Colors.neonYellow.opacity(0.5) : DesignSystem.Colors.textTertiary)

            if !groupedReactions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(groupedReactions, id: \.emoji) { group in
                        ReactionBadge(
                            emoji: group.emoji,
                            count: group.count,
                            includesCurrentUser: group.includesCurrentUser
                        )
                    }
                }
                // Consume taps to prevent row tap gesture from triggering
                .onTapGesture { }
            }
        }
    }

    private var itemNameColor: Color {
        switch item.status {
        case .suggestion:
            return DesignSystem.Colors.neonYellow.opacity(0.85)
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
                Text(notes)
                    .font(.system(size: 14, weight: .regular))
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

            // Star for custom items next to name
            if item.isCustom {
                customBadge
            }

            // Photo icon for items with images
            if !item.images.isEmpty {
                photoBadge
            }

            if let quantity = item.quantity, !quantity.isEmpty {
                quantityBadge(quantity)
            }

            // Aisle badge (only show when actively shopping at a store)
            if viewModel.shoppingStatus == .atStore, let aisle = aisleString {
                aisleBadge(aisle)
            }
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
                .stroke(DesignSystem.Colors.neonCyan.opacity(0.6), lineWidth: 2)
                .blur(radius: 4)
        } else if showRemoteAddedBadge && isPulsing {
            // Pulsing glow for remotely-added items during shopping mode
            RoundedRectangle(cornerRadius: 16)
                .stroke(DesignSystem.Colors.neonCyan.opacity(0.5), lineWidth: 2)
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
                    .fill(DesignSystem.Colors.neonYellow.opacity(0.15))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .strokeBorder(DesignSystem.Colors.neonYellow.opacity(0.4), lineWidth: 1)
                    )

                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.neonYellow)
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

    // MARK: - Quantity Badge

    private func quantityBadge(_ quantity: String) -> some View {
        Text(quantity)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DesignSystem.Colors.neonCyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.neonCyan.opacity(0.15))
                    .overlay(
                        Capsule()
                            .stroke(DesignSystem.Colors.neonCyan.opacity(0.3), lineWidth: 1)
                    )
            )
    }

    // MARK: - Aisle Badge

    private func aisleBadge(_ aisle: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 10))
            Text(aisle)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(DesignSystem.Colors.neonPurple)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.neonPurple.opacity(0.15))
                .overlay(
                    Capsule()
                        .stroke(DesignSystem.Colors.neonPurple.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Custom Badge (star only)

    private var customBadge: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(DesignSystem.Colors.neonPink)
    }

    // MARK: - Photo Badge

    private var photoBadge: some View {
        Image(systemName: "photo.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(DesignSystem.Colors.neonCyan)
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
                                DesignSystem.Colors.neonCyan.opacity(0.4),
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
                return DesignSystem.Colors.neonYellow.opacity(0.35)
            } else if item.isCustom {
                return DesignSystem.Colors.neonPink.opacity(0.5)
            } else {
                return DesignSystem.Colors.neonCyan.opacity(0.3)
            }
        }()

        return RoundedRectangle(cornerRadius: 16)
            .fill(isSuggestion ? DesignSystem.Colors.neonYellow.opacity(0.04) : Color.white.opacity(0.05))
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [
                                isSuggestion ? DesignSystem.Colors.neonYellow.opacity(0.08) : Color.white.opacity(0.1),
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
                    return DesignSystem.Colors.neonCyan
                case .toSuggestions:
                    return DesignSystem.Colors.neonYellow
                case .none:
                    return DesignSystem.Colors.neonCyan
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

/// Read-only reaction badge for item rows (non-interactive)
struct ReactionBadge: View {
    let emoji: String
    let count: Int
    let includesCurrentUser: Bool

    var body: some View {
        HStack(spacing: 2) {
            Text(emoji)
                .font(.system(size: 12))
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(includesCurrentUser
                    ? DesignSystem.Colors.neonCyan.opacity(0.2)
                    : Color.white.opacity(0.08))
        )
        .overlay(
            Capsule()
                .stroke(includesCurrentUser
                    ? DesignSystem.Colors.neonCyan.opacity(0.4)
                    : Color.clear, lineWidth: 1)
        )
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
