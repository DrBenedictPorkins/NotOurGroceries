import SwiftUI

// MARK: - Design System
// Futuristic metallic theme with dark mode, glassmorphism, and neon accents

struct DesignSystem {

    // MARK: - Colors
    struct Colors {
        // Base colors
        static let background = Color(hex: "0A0E1A")
        static let secondaryBackground = Color(hex: "12161F")
        static let cardBackground = Color(hex: "1A1F2E")

        // Metallic gradients
        static let metallicGradient = LinearGradient(
            colors: [
                Color(hex: "2C3E50"),
                Color(hex: "34495E"),
                Color(hex: "2C3E50")
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let darkMetallicGradient = LinearGradient(
            colors: [
                Color(hex: "1A1F2E"),
                Color(hex: "2C3E50"),
                Color(hex: "1A1F2E")
            ],
            startPoint: .top,
            endPoint: .bottom
        )

        // Neon accents
        static let neonCyan = Color(hex: "00F5FF")
        static let neonPurple = Color(hex: "B026FF")
        static let neonPink = Color(hex: "FF00E5")
        static let neonBlue = Color(hex: "0080FF")
        static let neonYellow = Color(hex: "FFD60A")

        // Gradient accents
        static let accentGradient = LinearGradient(
            colors: [neonCyan, neonPurple],
            startPoint: .leading,
            endPoint: .trailing
        )

        static let accentGradient2 = LinearGradient(
            colors: [neonPurple, neonPink],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        // Text colors
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.7)
        static let textTertiary = Color.white.opacity(0.5)

        // Status colors
        static let success = Color(hex: "00FF88")
        static let warning = Color(hex: "FFB800")
        static let error = Color(hex: "FF3B30")

        // Glassmorphism
        static let glassBackground = Color.white.opacity(0.05)
        static let glassBorder = Color.white.opacity(0.1)
    }

    // MARK: - Typography
    struct Typography {
        static let largeTitle = Font.system(size: 34, weight: .bold, design: .default)
        static let title = Font.system(size: 28, weight: .bold, design: .default)
        static let title2 = Font.system(size: 22, weight: .bold, design: .default)
        static let title3 = Font.system(size: 20, weight: .semibold, design: .default)
        static let headline = Font.system(size: 17, weight: .semibold, design: .default)
        static let body = Font.system(size: 17, weight: .regular, design: .default)
        static let callout = Font.system(size: 16, weight: .regular, design: .default)
        static let subheadline = Font.system(size: 15, weight: .regular, design: .default)
        static let footnote = Font.system(size: 13, weight: .regular, design: .default)
        static let caption = Font.system(size: 12, weight: .regular, design: .default)
        static let caption2 = Font.system(size: 11, weight: .regular, design: .default)
    }

    // MARK: - Spacing
    struct Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    // MARK: - Corner Radius
    struct CornerRadius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: - Shadows
    struct Shadows {
        static let small = Color.black.opacity(0.1)
        static let medium = Color.black.opacity(0.2)
        static let large = Color.black.opacity(0.3)

        static let neonCyanGlow = Color(hex: "00F5FF").opacity(0.3)
        static let neonPurpleGlow = Color(hex: "B026FF").opacity(0.3)
    }
}

// MARK: - View Modifiers

struct GlassMorphismCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                    .fill(DesignSystem.Colors.glassBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                            .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                    )
                    .shadow(color: DesignSystem.Shadows.medium, radius: 10, x: 0, y: 4)
            )
    }
}

struct NeonGlow: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.5), radius: 8, x: 0, y: 0)
            .shadow(color: color.opacity(0.3), radius: 16, x: 0, y: 0)
    }
}

struct MetallicBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.darkMetallicGradient
                .ignoresSafeArea()
                .opacity(0.3)

            content
        }
    }
}

// MARK: - View Extensions

extension View {
    func glassMorphismCard() -> some View {
        modifier(GlassMorphismCard())
    }

    func neonGlow(color: Color) -> some View {
        modifier(NeonGlow(color: color))
    }

    func metallicBackground() -> some View {
        modifier(MetallicBackground())
    }
}

// MARK: - Color Extension for Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview
struct DesignSystem_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Text("Grocery App")
                .font(DesignSystem.Typography.largeTitle)
                .foregroundColor(DesignSystem.Colors.textPrimary)

            VStack(spacing: DesignSystem.Spacing.md) {
                Text("Glassmorphism Card")
                    .font(DesignSystem.Typography.headline)
                Text("With neon accent gradient")
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
            .padding(DesignSystem.Spacing.lg)
            .glassMorphismCard()

            HStack(spacing: DesignSystem.Spacing.md) {
                Circle()
                    .fill(DesignSystem.Colors.neonCyan)
                    .frame(width: 40, height: 40)
                    .neonGlow(color: DesignSystem.Colors.neonCyan)

                Circle()
                    .fill(DesignSystem.Colors.neonPurple)
                    .frame(width: 40, height: 40)
                    .neonGlow(color: DesignSystem.Colors.neonPurple)

                Circle()
                    .fill(DesignSystem.Colors.neonPink)
                    .frame(width: 40, height: 40)
                    .neonGlow(color: DesignSystem.Colors.neonPink)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .metallicBackground()
    }
}
