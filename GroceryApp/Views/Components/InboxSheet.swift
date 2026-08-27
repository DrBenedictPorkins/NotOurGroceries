import SwiftUI

// MARK: - Inbox Sheet

/// Main sheet displaying pending shopping requests from household members
struct InboxSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @ObservedObject var userCache = UserCache.shared

    private var pendingRequests: [ShoppingRequest] {
        viewModel.pendingRequests
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                DesignSystem.Colors.darkMetallicGradient
                    .ignoresSafeArea()
                    .opacity(0.3)

                if pendingRequests.isEmpty {
                    emptyStateView
                } else {
                    requestsList
                }
            }
            .navigationTitle("Inbox (\(pendingRequests.count) pending)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.accentGradient)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 60, weight: .regular))
                .foregroundStyle(DesignSystem.Colors.accentGradient)
                .opacity(0.5)

            Text("No Pending Requests")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textPrimary)

            Text("Shopping requests from your household will appear here")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Requests List

    private var requestsList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(pendingRequests) { request in
                    RequestRow(request: request)
                        .environmentObject(viewModel)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Request Row

/// Individual row showing a pending request with approve/reject buttons
struct RequestRow: View {
    let request: ShoppingRequest
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @ObservedObject var userCache = UserCache.shared
    @State private var isProcessing = false

    private var requesterName: String {
        userCache.displayName(for: request.requestedBy)
    }

    private var requestColor: Color {
        request.isAddRequest ? DesignSystem.Colors.success : DesignSystem.Colors.neonPink
    }

    private var requestIcon: String {
        request.isAddRequest ? "plus.circle.fill" : "minus.circle.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Requester + Type
            HStack(spacing: 8) {
                Image(systemName: requestIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(requestColor)

                Text(requesterName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)

                Text(request.isAddRequest ? "wants to add" : "wants to remove")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textSecondary)

                Spacer()

                // Timestamp
                Text(timeAgo(from: request.requestedAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }

            // Item details
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(request.itemName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textPrimary)

                    if let quantity = request.quantity, !quantity.isEmpty {
                        quantityBadge(quantity)
                    }
                }

                if let notes = request.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .italic()
                }
            }
            .padding(.leading, 24) // Indent under header

            // Action buttons
            HStack(spacing: 12) {
                // Reject button
                Button(action: {
                    handleReject()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Reject")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)

                // Approve button
                Button(action: {
                    handleApprove()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Approve")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(requestColor)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)
            }
        }
        .padding(16)
        .background(cardBackground)
        .cornerRadius(16)
        .opacity(isProcessing ? 0.6 : 1.0)
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        LinearGradient(
                            colors: [requestColor.opacity(0.4), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }

    // MARK: - Quantity Badge

    private func quantityBadge(_ quantity: String) -> some View {
        Text(quantity)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DesignSystem.Colors.dillGreen)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.dillGreen.opacity(0.15))
                    .overlay(
                        Capsule()
                            .stroke(DesignSystem.Colors.dillGreen.opacity(0.3), lineWidth: 1)
                    )
            )
    }

    // MARK: - Actions

    private func handleReject() {
        guard !isProcessing else { return }
        isProcessing = true

        Task {
            await viewModel.rejectRequest(request)
            await MainActor.run {
                isProcessing = false
            }
        }
    }

    private func handleApprove() {
        guard !isProcessing else { return }
        isProcessing = true

        Task {
            await viewModel.approveRequest(request)
            await MainActor.run {
                isProcessing = false
            }
        }
    }

    // MARK: - Helpers

    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}

// MARK: - Inbox Badge

/// Small badge showing request count, designed to overlay on icons
struct InboxBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.error)
                    .frame(width: 18, height: 18)

                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Previews

#Preview("Inbox Sheet - Empty") {
    InboxSheet()
        .environmentObject(ShoppingListViewModel())
}

#Preview("Inbox Sheet - With Requests") {
    // Note: This preview won't show requests without mock data in ViewModel
    InboxSheet()
        .environmentObject(ShoppingListViewModel())
}

#Preview("Request Row - Add") {
    ZStack {
        DesignSystem.Colors.background
            .ignoresSafeArea()

        DesignSystem.Colors.darkMetallicGradient
            .ignoresSafeArea()
            .opacity(0.3)

        VStack(spacing: 16) {
            RequestRow(request: .preview)
                .environmentObject(ShoppingListViewModel())

            RequestRow(request: ShoppingRequest(
                householdId: "household1",
                requestType: .addItem,
                itemName: "Organic Milk",
                quantity: "1 gallon",
                notes: "Please get the organic brand",
                requestedBy: "user1"
            ))
            .environmentObject(ShoppingListViewModel())
        }
        .padding(20)
    }
}

#Preview("Request Row - Remove") {
    ZStack {
        DesignSystem.Colors.background
            .ignoresSafeArea()

        DesignSystem.Colors.darkMetallicGradient
            .ignoresSafeArea()
            .opacity(0.3)

        VStack(spacing: 16) {
            RequestRow(request: .removeRequestPreview)
                .environmentObject(ShoppingListViewModel())

            RequestRow(request: ShoppingRequest(
                householdId: "household1",
                requestType: .removeItem,
                itemName: "Bananas",
                targetItemId: "item123",
                requestedBy: "user2"
            ))
            .environmentObject(ShoppingListViewModel())
        }
        .padding(20)
    }
}

#Preview("Inbox Badge") {
    HStack(spacing: 20) {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "tray.fill")
                .font(.system(size: 28))
                .foregroundColor(DesignSystem.Colors.dillGreen)

            InboxBadge(count: 3)
                .offset(x: 8, y: -8)
        }

        ZStack(alignment: .topTrailing) {
            Image(systemName: "bell.fill")
                .font(.system(size: 28))
                .foregroundColor(DesignSystem.Colors.neonPurple)

            InboxBadge(count: 12)
                .offset(x: 8, y: -8)
        }

        ZStack(alignment: .topTrailing) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 28))
                .foregroundColor(DesignSystem.Colors.neonPink)

            InboxBadge(count: 0) // Should not show
                .offset(x: 8, y: -8)
        }
    }
    .padding(40)
    .background(DesignSystem.Colors.background)
}
