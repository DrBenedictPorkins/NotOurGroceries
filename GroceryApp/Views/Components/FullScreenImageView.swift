import SwiftUI

struct FullScreenImageView: View {
    let image: UIImage
    let itemImage: ItemImage
    let onDismiss: () -> Void

    // Zoom and pan state
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isFitMode: Bool = true

    // Animation
    @State private var showControls: Bool = true

    // Constants
    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 5.0
    private let doubleTapScale: CGFloat = 2.5

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dark background
                Color.black
                    .ignoresSafeArea()

                // Image with gestures
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isFitMode ? .fit : .fill)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(combinedGesture(in: geometry))
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            toggleZoomMode()
                        }
                    }
                    .onTapGesture(count: 1) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls.toggle()
                        }
                    }

                // Overlay controls
                if showControls {
                    VStack {
                        // Top bar with dismiss button
                        HStack {
                            Spacer()

                            Button(action: onDismiss) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(DesignSystem.Colors.textPrimary)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        Circle()
                                            .fill(DesignSystem.Colors.glassBackground)
                                            .overlay(
                                                Circle()
                                                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                                            )
                                    )
                            }
                            .padding(.trailing, DesignSystem.Spacing.md)
                            .padding(.top, DesignSystem.Spacing.md)
                        }

                        Spacer()

                        // Bottom metadata overlay
                        metadataOverlay
                    }
                    .transition(.opacity)
                }
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Metadata Overlay

    private var metadataOverlay: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(DesignSystem.Colors.neonCyan)

            Text(UserCache.shared.displayName(for: itemImage.uploadedBy))
                .font(DesignSystem.Typography.footnote)
                .foregroundColor(DesignSystem.Colors.textPrimary)

            Text("-")
                .foregroundColor(DesignSystem.Colors.textTertiary)

            Text(relativeTimeString(from: itemImage.uploadedAt))
                .font(DesignSystem.Typography.footnote)
                .foregroundColor(DesignSystem.Colors.textSecondary)

            Spacer()
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.8),
                    Color.black.opacity(0.4),
                    Color.clear
                ],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 80)
            .offset(y: 20)
        )
        .padding(.bottom, DesignSystem.Spacing.lg)
    }

    // MARK: - Gestures

    private func combinedGesture(in geometry: GeometryProxy) -> some Gesture {
        SimultaneousGesture(
            magnificationGesture(),
            dragGesture(in: geometry)
        )
    }

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                let newScale = scale * delta
                scale = min(max(newScale, minScale), maxScale)
            }
            .onEnded { _ in
                lastScale = 1.0
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    if scale < minScale {
                        scale = minScale
                        offset = .zero
                    }
                }
            }
    }

    private func dragGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }

                let newOffset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = constrainOffset(newOffset, in: geometry)
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    // MARK: - Helper Functions

    private func toggleZoomMode() {
        if scale > 1.0 {
            // Reset to fit
            scale = 1.0
            offset = .zero
            lastOffset = .zero
            isFitMode = true
        } else {
            // Zoom in
            scale = doubleTapScale
            isFitMode = false
        }
    }

    private func constrainOffset(_ proposedOffset: CGSize, in geometry: GeometryProxy) -> CGSize {
        let imageSize = calculateScaledImageSize(in: geometry)
        let containerSize = geometry.size

        let maxOffsetX = max(0, (imageSize.width - containerSize.width) / 2)
        let maxOffsetY = max(0, (imageSize.height - containerSize.height) / 2)

        return CGSize(
            width: min(max(proposedOffset.width, -maxOffsetX), maxOffsetX),
            height: min(max(proposedOffset.height, -maxOffsetY), maxOffsetY)
        )
    }

    private func calculateScaledImageSize(in geometry: GeometryProxy) -> CGSize {
        let imageAspect = image.size.width / image.size.height
        let containerAspect = geometry.size.width / geometry.size.height

        var baseSize: CGSize
        if imageAspect > containerAspect {
            // Image is wider - width fills container
            baseSize = CGSize(
                width: geometry.size.width,
                height: geometry.size.width / imageAspect
            )
        } else {
            // Image is taller - height fills container
            baseSize = CGSize(
                width: geometry.size.height * imageAspect,
                height: geometry.size.height
            )
        }

        return CGSize(
            width: baseSize.width * scale,
            height: baseSize.height * scale
        )
    }

    private func relativeTimeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Preview

#Preview {
    FullScreenImageView(
        image: UIImage(systemName: "photo")!,
        itemImage: ItemImage(
            id: UUID().uuidString,
            s3Key: "test/image.jpg",
            uploadedBy: "user123",
            uploadedAt: Date().addingTimeInterval(-3600)
        ),
        onDismiss: {}
    )
}
