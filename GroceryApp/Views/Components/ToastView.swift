//
//  ToastView.swift
//  GroceryApp
//
//  Created on 2026-01-04.
//  Ephemeral notification overlay for real-time updates
//

import SwiftUI

/// Toast notification types for different visual styles
enum ToastType {
    case success
    case error
    case warning
    case info

    var accentColor: Color {
        switch self {
        case .success: return Color(hex: "00D4FF")  // Cyan
        case .error: return Color(hex: "FF4757")    // Red
        case .warning: return Color(hex: "FFA502")  // Orange
        case .info: return Color(hex: "7B2CBF")     // Purple
        }
    }

    var secondaryColor: Color {
        switch self {
        case .success: return Color(hex: "7B2CBF")  // Purple
        case .error: return Color(hex: "FF6B81")    // Light red
        case .warning: return Color(hex: "FFD43B")  // Yellow
        case .info: return Color(hex: "00D4FF")     // Cyan
        }
    }

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var hapticType: UINotificationFeedbackGenerator.FeedbackType {
        switch self {
        case .success: return .success
        case .error: return .error
        case .warning: return .warning
        case .info: return .success
        }
    }
}

/// Toast notification that slides in from top and auto-dismisses
/// Shows user avatar and action message for collaborative updates
struct ToastView: View {
    let message: String
    let userName: String
    let avatarUrl: String?
    var type: ToastType = .success

    @State private var isVisible = false
    @State private var dismissTimer: Timer?

    /// How long a toast stays up before it starts fading.
    static let visibleDuration: TimeInterval = 5.0
    /// The fade itself, which the owner has to outlast before removing the view.
    static let fadeDuration: TimeInterval = 0.35

    var body: some View {
        HStack(spacing: 12) {
            // User avatar or type icon
            if userName.isEmpty {
                typeIcon
            } else {
                avatarView
            }

            // Message content
            VStack(alignment: .leading, spacing: 2) {
                if !userName.isEmpty {
                    Text(userName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(type.accentColor)
                }

                Text(message)
                    // The type's own colour rather than white, and heavier. A
                    // toast on a dark list in white medium text is the same
                    // treatment as every row it floats over, so it reads as part
                    // of the list instead of as something that just happened.
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(type.accentColor)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(toastBackground)
        .cornerRadius(16)
        .shadow(color: type.accentColor.opacity(0.3), radius: 16, x: 0, y: 8)
        .padding(.horizontal, 20)
        .offset(y: isVisible ? 0 : -100)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isVisible = true
            }

            // Five seconds. Three was long enough to notice and too short to
            // read a sentence naming an item and where it went.
            //
            // `ShoppingListViewModel.showToast` clears the flag a beat later, so
            // this fade always finishes before the view is torn out from under
            // it — the two used to be set to the same three seconds and raced.
            dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.visibleDuration, repeats: false) { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isVisible = false
                }
            }

            // Haptic feedback based on type
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(type.hapticType)
        }
        .onDisappear {
            dismissTimer?.invalidate()
        }
    }

    // MARK: - Type Icon (for system messages without user)

    private var typeIcon: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [type.accentColor.opacity(0.3), type.secondaryColor.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 40, height: 40)

            Image(systemName: type.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(type.accentColor)
        }
    }

    // MARK: - Avatar View

    private var avatarView: some View {
        Group {
            if let avatarUrl = avatarUrl, let url = URL(string: avatarUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        avatarPlaceholder
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        avatarPlaceholder
                    @unknown default:
                        avatarPlaceholder
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color(hex: "00D4FF"), Color(hex: "7B2CBF")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                )
            } else {
                avatarPlaceholder
            }
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "00D4FF").opacity(0.3), Color(hex: "7B2CBF").opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 40, height: 40)

            Text(String(userName.prefix(1)).uppercased())
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Toast Background

    private var toastBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(hex: "0D0D0D").opacity(0.95))
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.15),
                                Color.white.opacity(0.08)
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
                            colors: [
                                type.accentColor.opacity(0.5),
                                type.secondaryColor.opacity(0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
    }
}

// MARK: - Toast Message Model

/// Model for toast notification data
struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let userName: String
    let avatarUrl: String?
    var type: ToastType = .success

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        LinearGradient(
            colors: [Color(hex: "1a1a2e"), Color(hex: "16213e")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        VStack {
            ToastView(
                message: "added Milk to the list",
                userName: "John",
                avatarUrl: nil
            )
            .padding(.top, 60)

            Spacer()
        }
    }
}
