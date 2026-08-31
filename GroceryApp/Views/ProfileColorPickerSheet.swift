import SwiftUI

struct ProfileColorPickerSheet: View {
    @Binding var selectedColor: String

    /// Colours worn by *other* people in this household, mapped to their initial.
    ///
    /// The colour is what tells one person's items from another's on a list row,
    /// so two members sharing one defeats the point. Taken colours stay in the
    /// grid wearing the initial of whoever has them: a dimmed circle alone reads
    /// as a rendering fault, while a circle with a B on it explains itself.
    var takenColors: [String: Character] = [:]

    /// The current user's initial, so the preview is their badge, not a mock-up.
    var initial: Character? = nil

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
                    .foregroundColor(DesignSystem.Colors.dillGreen)
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
                initial: initial,
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
                        isSelected: selectedColor == color.rawValue,
                        takenBy: takenColors[color.rawValue]
                    ) {
                        selectedColor = color.rawValue
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }

            if !takenColors.isEmpty {
                Text("Colours showing someone's initial are already taken in your household.")
                    .font(.system(size: 12))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }
        }
    }

}

// MARK: - Color Option

private struct ColorOption: View {
    let color: ProfileColor
    let isSelected: Bool
    /// Initial of the household member already wearing this colour, if any.
    var takenBy: Character? = nil
    let onTap: () -> Void

    private var isTaken: Bool { takenBy != nil }

    var body: some View {
        Button(action: { if !isTaken { onTap() } }) {
            ZStack {
                Circle()
                    // Taken colours are drawn at full strength, same as the rest.
                    // Dimming was tried twice and read as a rendering fault both
                    // times: #B026FF at 0.55 on a near-black ground is a black
                    // circle. The initial is what says the colour is spoken for,
                    // so the colour itself has no reason to hide.
                    .fill(color.color)
                    .frame(width: 50, height: 50)
                    .shadow(color: color.color.opacity(0.4), radius: isSelected ? 8 : 0, x: 0, y: 4)

                if let initial = takenBy {
                    Text(String(initial).uppercased())
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundColor(color.inkOnTop)
                } else if isSelected {
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
        .disabled(isTaken)
        .scaleEffect(isSelected ? 1.1 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel(isTaken
            ? "\(color.displayName), taken by \(takenBy.map(String.init) ?? "")"
            : color.displayName)
    }
}

// MARK: - Preview

#Preview {
    ProfileColorPickerSheet(
        selectedColor: .constant("cyan"),
        takenColors: ["purple": "B", "pink": "J"],
        initial: "M",
        onSave: {}
    )
}
