import SwiftUI

/// Available profile colors mapped to DesignSystem colors
/// Twelve colours, all bright enough to read as 11pt text on the near-black
/// ground (`#0A100B`). That constraint is why this is a fixed palette and not a
/// colour wheel: an arbitrary dark navy would make someone's name invisible on
/// every row they added, and silently correcting their choice is worse than not
/// offering it.
///
/// The first six are the original names and must keep their spellings — they are
/// stored on `User.profileColor` and on rows written before the palette grew.
enum ProfileColor: String, CaseIterable {
    case cyan
    case purple
    case pink
    case blue
    case yellow
    case green
    case coral
    case sky
    case lavender
    case gold
    case rose
    case periwinkle

    var color: Color {
        switch self {
        case .cyan: return DesignSystem.Colors.dillGreen
        case .purple: return DesignSystem.Colors.neonPurple
        case .pink: return DesignSystem.Colors.neonPink
        case .blue: return DesignSystem.Colors.neonBlue
        case .yellow: return DesignSystem.Colors.neonAmber
        case .green: return DesignSystem.Colors.success
        case .coral: return Color(hex: "FF6B5C")
        case .sky: return Color(hex: "3DDCFF")
        case .lavender: return Color(hex: "C9A7FF")
        case .gold: return Color(hex: "FFD93D")
        case .rose: return Color(hex: "FF8FB1")
        case .periwinkle: return Color(hex: "8AA0FF")
        }
    }

    var displayName: String {
        rawValue.capitalized
    }

    /// Black or white, whichever is legible on top of this colour.
    ///
    /// Twelve colours run from #0080FF to #FFD93D, so a single fixed ink is
    /// wrong for half of them. Computed from the colour itself rather than
    /// listed per case, so adding a thirteenth needs no second edit.
    var inkOnTop: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return .white
        }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.35 ? .black : .white
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
