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
}

/// Available profile patterns
enum ProfilePattern: String, CaseIterable {
    case solid
    case stripes
    case dots
    case gradient

    var displayName: String {
        rawValue.capitalized
    }
}

/// A visual indicator showing a user's chosen color and pattern
/// Used for subtle item corner overlays to show who added an item
struct UserIdentityGradient: View {
    let colorKey: String
    let patternKey: String

    private var profileColor: Color {
        // Try exact match first, then lowercase for case-insensitivity
        if let color = ProfileColor(rawValue: colorKey) {
            return color.color
        }
        if let color = ProfileColor(rawValue: colorKey.lowercased()) {
            return color.color
        }
        print("UserIdentityGradient: Unknown color key '\(colorKey)', defaulting to cyan")
        return DesignSystem.Colors.dillGreen
    }

    private var pattern: ProfilePattern {
        ProfilePattern(rawValue: patternKey) ?? ProfilePattern(rawValue: patternKey.lowercased()) ?? .solid
    }

    var body: some View {
        GeometryReader { geometry in
            switch pattern {
            case .solid:
                solidPattern(in: geometry.size)
            case .stripes:
                stripesPattern(in: geometry.size)
            case .dots:
                dotsPattern(in: geometry.size)
            case .gradient:
                gradientPattern(in: geometry.size)
            }
        }
    }

    // MARK: - Pattern Views

    private func solidPattern(in size: CGSize) -> some View {
        LinearGradient(
            colors: [profileColor.opacity(0.9), profileColor.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func stripesPattern(in size: CGSize) -> some View {
        Canvas { context, size in
            let stripeWidth: CGFloat = 5
            let gap: CGFloat = 4
            let totalWidth = stripeWidth + gap
            let stripeCount = Int((size.width + size.height) / totalWidth) + 1

            for i in 0..<stripeCount {
                let offset = CGFloat(i) * totalWidth
                let path = Path { p in
                    p.move(to: CGPoint(x: offset, y: 0))
                    p.addLine(to: CGPoint(x: 0, y: offset))
                    p.addLine(to: CGPoint(x: 0, y: offset + stripeWidth))
                    p.addLine(to: CGPoint(x: offset + stripeWidth, y: 0))
                    p.closeSubpath()
                }
                context.fill(path, with: .color(profileColor.opacity(0.9)))
            }
        }
        .mask(
            LinearGradient(
                colors: [.white, .white.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private func dotsPattern(in size: CGSize) -> some View {
        Canvas { context, size in
            let dotSize: CGFloat = 4
            let spacing: CGFloat = 8
            let rows = Int(size.height / spacing) + 1
            let cols = Int(size.width / spacing) + 1

            for row in 0..<rows {
                for col in 0..<cols {
                    let x = CGFloat(col) * spacing + (row.isMultiple(of: 2) ? spacing / 2 : 0)
                    let y = CGFloat(row) * spacing

                    // Fade based on x position (left to right)
                    let opacity = max(0, 1.0 - (x / size.width))

                    if opacity > 0 {
                        let rect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                        context.fill(Circle().path(in: rect), with: .color(profileColor.opacity(0.9 * opacity)))
                    }
                }
            }
        }
    }

    private func gradientPattern(in size: CGSize) -> some View {
        let secondaryColor: Color = {
            switch ProfileColor(rawValue: colorKey) ?? ProfileColor(rawValue: colorKey.lowercased()) ?? .cyan {
            case .cyan: return DesignSystem.Colors.neonBlue
            case .purple: return DesignSystem.Colors.neonPink
            case .pink: return DesignSystem.Colors.neonPurple
            case .blue: return DesignSystem.Colors.dillGreen
            case .yellow: return DesignSystem.Colors.success
            case .green: return DesignSystem.Colors.neonAmber
            }
        }()

        return LinearGradient(
            colors: [profileColor.opacity(0.9), secondaryColor.opacity(0.6), .clear],
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

#Preview("All Patterns") {
    VStack(spacing: 20) {
        ForEach(ProfilePattern.allCases, id: \.self) { pattern in
            HStack(spacing: 16) {
                ForEach(ProfileColor.allCases, id: \.self) { color in
                    VStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DesignSystem.Colors.cardBackground)
                            .frame(width: 50, height: 50)
                            .overlay(alignment: .topLeading) {
                                UserIdentityGradient(colorKey: color.rawValue, patternKey: pattern.rawValue)
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedCorner(radius: 12, corners: [.topLeft]))
                            }

                        Text(color.rawValue.prefix(1).uppercased())
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal)

            Text(pattern.displayName)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
    }
    .padding()
    .background(DesignSystem.Colors.background)
}
