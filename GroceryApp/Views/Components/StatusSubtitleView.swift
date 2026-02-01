//
//  StatusSubtitleView.swift
//  GroceryApp
//
//  Created on 2026-01-18.
//  Unified notification subtitle for consistent messaging across views
//

import SwiftUI

/// Unified subtitle component for displaying status and notifications
/// Used in both ShoppingListView and AtStoreModeView for consistent UX
struct StatusSubtitleView: View {
    // MARK: - Properties

    /// Default status text when no notification is active
    let defaultStatus: String

    /// Whether a notification is currently being shown
    let isShowingNotification: Bool

    /// The notification message text
    let notificationMessage: String

    /// The user name associated with the notification (if any)
    let notificationUserName: String

    /// The type of notification for styling
    let notificationType: ToastType

    /// Whether this action is from another user (for visual differentiation)
    let isOtherUser: Bool

    // MARK: - Animation State

    @State private var pulseScale: CGFloat = 1.0

    // MARK: - Body

    var body: some View {
        Group {
            if isShowingNotification, !notificationMessage.isEmpty {
                notificationContent
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            } else {
                defaultContent
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isShowingNotification)
    }

    // MARK: - Default Content

    private var defaultContent: some View {
        Text(defaultStatus)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(DesignSystem.Colors.textSecondary)
    }

    // MARK: - Notification Content

    private var notificationContent: some View {
        HStack(spacing: 6) {
            // Type icon for errors/warnings
            if notificationType != .success {
                Image(systemName: notificationType.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(notificationType.accentColor)
            }

            // User name (highlighted for other users)
            if !notificationUserName.isEmpty {
                Text(notificationUserName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(userNameColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .scaleEffect(isOtherUser ? pulseScale : 1.0)
                    .onAppear {
                        if isOtherUser {
                            startPulseAnimation()
                        }
                    }
                    .onChange(of: isOtherUser) { oldValue, newValue in
                        if newValue {
                            startPulseAnimation()
                        } else {
                            pulseScale = 1.0
                        }
                    }
            }

            // Message
            Text(notificationMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(messageColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Colors

    /// Color for the user name - cyan for other users to catch attention
    private var userNameColor: Color {
        if isOtherUser {
            return DesignSystem.Colors.neonCyan
        }
        return notificationType.accentColor
    }

    /// Color for the message text
    private var messageColor: Color {
        switch notificationType {
        case .success:
            return DesignSystem.Colors.textSecondary
        case .error:
            return notificationType.accentColor.opacity(0.9)
        case .warning:
            return notificationType.accentColor.opacity(0.85)
        case .info:
            return DesignSystem.Colors.textSecondary
        }
    }

    // MARK: - Animation

    private func startPulseAnimation() {
        // Subtle pulse animation to draw attention
        withAnimation(
            .easeInOut(duration: 0.3)
            .repeatCount(2, autoreverses: true)
        ) {
            pulseScale = 1.08
        }

        // Reset after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeOut(duration: 0.2)) {
                pulseScale = 1.0
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 40) {
        // Default state
        StatusSubtitleView(
            defaultStatus: "5 items",
            isShowingNotification: false,
            notificationMessage: "",
            notificationUserName: "",
            notificationType: .success,
            isOtherUser: false
        )

        // Own action notification
        StatusSubtitleView(
            defaultStatus: "5 items",
            isShowingNotification: true,
            notificationMessage: "added Milk",
            notificationUserName: "You",
            notificationType: .success,
            isOtherUser: false
        )

        // Other user notification (cyan + pulse)
        StatusSubtitleView(
            defaultStatus: "5 items",
            isShowingNotification: true,
            notificationMessage: "added Eggs",
            notificationUserName: "Polina",
            notificationType: .success,
            isOtherUser: true
        )

        // Error notification
        StatusSubtitleView(
            defaultStatus: "5 items",
            isShowingNotification: true,
            notificationMessage: "Failed to sync",
            notificationUserName: "",
            notificationType: .error,
            isOtherUser: false
        )
    }
    .padding()
    .metallicBackground()
}
