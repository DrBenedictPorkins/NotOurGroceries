import SwiftUI

/// A badge showing a user's profile colour with their initial
/// Used in Settings and anywhere a user avatar is needed
struct UserColorBadge: View {
    let colorKey: String
    let initial: Character?
    var size: CGFloat = 50

    private var profileColor: Color {
        ProfileColor(rawValue: colorKey)?.color ?? DesignSystem.Colors.dillGreen
    }

    var body: some View {
        ZStack {
            // Colour wash behind the initial
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(DesignSystem.Colors.cardBackground)
                .overlay {
                    UserIdentityGradient(colorKey: colorKey)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.24)
                        .stroke(profileColor.opacity(0.5), lineWidth: 2)
                }
                .shadow(color: profileColor.opacity(0.3), radius: 8, x: 0, y: 4)

            // Initial letter
            if let initial = initial {
                Text(String(initial).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A smaller, circular version for inline use
struct UserColorDot: View {
    let colorKey: String
    var size: CGFloat = 24

    private var profileColor: Color {
        ProfileColor(rawValue: colorKey)?.color ?? DesignSystem.Colors.dillGreen
    }

    var body: some View {
        Circle()
            .fill(DesignSystem.Colors.cardBackground)
            .overlay {
                UserIdentityGradient(colorKey: colorKey)
                    .clipShape(Circle())
            }
            .overlay {
                Circle()
                    .stroke(profileColor.opacity(0.6), lineWidth: 1.5)
            }
            .frame(width: size, height: size)
    }
}

// MARK: - Preview

#Preview("User Color Badge") {
    VStack(spacing: 24) {
        Text("Large Badges")
            .font(.headline)
            .foregroundColor(.white)

        HStack(spacing: 16) {
            UserColorBadge(colorKey: "cyan", initial: "S", size: 60)
            UserColorBadge(colorKey: "purple", initial: "M", size: 60)
            UserColorBadge(colorKey: "pink", initial: "A", size: 60)
            UserColorBadge(colorKey: "green", initial: "J", size: 60)
        }

        Text("Small Badges")
            .font(.headline)
            .foregroundColor(.white)

        HStack(spacing: 12) {
            UserColorBadge(colorKey: "cyan", initial: "S", size: 40)
            UserColorBadge(colorKey: "yellow", initial: "K", size: 40)
            UserColorBadge(colorKey: "blue", initial: "L", size: 40)
        }

        Text("Color Dots")
            .font(.headline)
            .foregroundColor(.white)

        HStack(spacing: 8) {
            ForEach(ProfileColor.allCases, id: \.self) { color in
                UserColorDot(colorKey: color.rawValue, size: 20)
            }
        }
    }
    .padding()
    .background(DesignSystem.Colors.background)
}
