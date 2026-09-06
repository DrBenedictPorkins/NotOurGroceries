import SwiftUI

/// Something went wrong, said once and left on screen.
struct SurfacedError: Identifiable, Equatable {
    let id = UUID()
    let message: String
    /// Warnings are the same shape in a calmer colour — the list is full, a
    /// partial save — where an error is something that failed outright.
    var isWarning: Bool = false
    let occurredAt = Date()

    static func == (a: SurfacedError, b: SurfacedError) -> Bool { a.id == b.id }
}

/// A banner that stays until dismissed.
///
/// Errors used to be toasts: three or four seconds, then gone. A person who
/// looked away missed it entirely, and the only way to read it was to repeat the
/// thing that had just failed — which is precisely what nobody should be nudged
/// into doing after a failure. It cost a real user a restore he could not explain
/// and could only investigate by trying again.
///
/// Successes still fade. Nobody needs to dismiss good news.
struct ErrorBanner: View {
    let error: SurfacedError
    let onDismiss: () -> Void

    private var accent: Color {
        error.isWarning ? DesignSystem.Colors.neonAmber : DesignSystem.Colors.error
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error.isWarning
                  ? "exclamationmark.triangle.fill"
                  : "exclamationmark.octagon.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(accent)

            Text(error.message)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(DesignSystem.Colors.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.16)))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(accent.opacity(0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
        )
        .padding(.horizontal, 16)
    }
}
