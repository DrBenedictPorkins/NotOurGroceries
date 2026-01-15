import SwiftUI

struct ProfileColorPickerSheet: View {
    @Binding var selectedColor: String
    @Binding var selectedPattern: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 32) {
                    // Preview
                    previewSection

                    // Color selection
                    colorSection

                    // Pattern selection
                    patternSection
                }
                .padding(24)
            }
            .background(DesignSystem.Colors.background.ignoresSafeArea())
            .navigationTitle("Customize Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave()
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(spacing: 16) {
            Text("Preview")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            UserColorBadge(
                colorKey: selectedColor,
                patternKey: selectedPattern,
                initial: "Y",
                size: 100
            )

            Text("Your Profile Badge")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - Color Section

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Color")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textTertiary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 16) {
                ForEach(ProfileColor.allCases, id: \.self) { color in
                    ColorOption(
                        color: color,
                        isSelected: selectedColor == color.rawValue
                    ) {
                        selectedColor = color.rawValue
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
        }
    }

    // MARK: - Pattern Section

    private var patternSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pattern")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textTertiary)

            HStack(spacing: 12) {
                ForEach(ProfilePattern.allCases, id: \.self) { pattern in
                    PatternOption(
                        pattern: pattern,
                        colorKey: selectedColor,
                        isSelected: selectedPattern == pattern.rawValue
                    ) {
                        selectedPattern = pattern.rawValue
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
        }
    }
}

// MARK: - Color Option

private struct ColorOption: View {
    let color: ProfileColor
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(color.color)
                    .frame(width: 50, height: 50)
                    .shadow(color: color.color.opacity(0.4), radius: isSelected ? 8 : 0, x: 0, y: 4)

                if isSelected {
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 50, height: 50)

                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.1 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

// MARK: - Pattern Option

private struct PatternOption: View {
    let pattern: ProfilePattern
    let colorKey: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignSystem.Colors.cardBackground)
                    .frame(width: 70, height: 70)
                    .overlay {
                        UserIdentityGradient(colorKey: colorKey, patternKey: pattern.rawValue)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isSelected ? DesignSystem.Colors.neonCyan : Color.white.opacity(0.1),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                    .shadow(
                        color: isSelected ? DesignSystem.Colors.neonCyan.opacity(0.3) : .clear,
                        radius: 8,
                        x: 0,
                        y: 4
                    )

                Text(pattern.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? DesignSystem.Colors.neonCyan : DesignSystem.Colors.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

// MARK: - Preview

#Preview {
    ProfileColorPickerSheet(
        selectedColor: .constant("cyan"),
        selectedPattern: .constant("solid"),
        onSave: {}
    )
}
