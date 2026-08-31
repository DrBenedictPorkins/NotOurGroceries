import SwiftUI

/// Available profile colors mapped to DesignSystem colors
enum ProfileColor: String, CaseIterable {
    case cyan
    case purple
    case pink
    case blue
    case yellow
    case green

    var color: Color {
        switch self {
        case .cyan: return DesignSystem.Colors.dillGreen
        case .purple: return DesignSystem.Colors.neonPurple
        case .pink: return DesignSystem.Colors.neonPink
        case .blue: return DesignSystem.Colors.neonBlue
        case .yellow: return DesignSystem.Colors.neonAmber
        case .green: return DesignSystem.Colors.success
        }
    }

    var displayName: String {
        rawValue.capitalized
    }

    /// Tolerant lookup — the stored key has been written in mixed case, and a
    /// user who never opened the picker has none at all.
    static func named(_ key: String?) -> ProfileColor {
        guard let key else { return .cyan }
        return ProfileColor(rawValue: key)
            ?? ProfileColor(rawValue: key.lowercased())
            ?? .cyan
    }
}

/// A user's colour, fading out to the right.
///
/// Patterns (stripes, dots, gradient) used to live here too. They were dropped
/// on 2026-08-30: at badge size they read as noise rather than identity, and
/// they could not follow the colour to the one place identity actually matters —
/// the `[name]` attribution on a list row, which is text.
struct UserIdentityGradient: View {
    let colorKey: String

    private var profileColor: Color {
        ProfileColor.named(colorKey).color
    }

    var body: some View {
        LinearGradient(
            colors: [profileColor.opacity(0.9), profileColor.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// Helper shape for rounding specific corners
struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Preview

#Preview("All Colours") {
    HStack(spacing: 16) {
        ForEach(ProfileColor.allCases, id: \.self) { color in
            VStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignSystem.Colors.cardBackground)
                    .frame(width: 50, height: 50)
                    .overlay(alignment: .topLeading) {
                        UserIdentityGradient(colorKey: color.rawValue)
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedCorner(radius: 12, corners: [.topLeft]))
                    }

                Text(color.displayName)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
    .padding()
    .background(DesignSystem.Colors.background)
}
