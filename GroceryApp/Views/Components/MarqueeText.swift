import SwiftUI

struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isAnimating: Bool = false

    private let spacing: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            let needsMarquee = textWidth > geometry.size.width

            HStack(spacing: 0) {
                if needsMarquee {
                    // Scrolling text with duplicate for seamless loop
                    HStack(spacing: spacing) {
                        Text(text)
                            .font(font)
                            .foregroundColor(color)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(text)
                            .font(font)
                            .foregroundColor(color)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .offset(x: offset)
                } else {
                    // Static text when it fits
                    Text(text)
                        .font(font)
                        .foregroundColor(color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .onAppear {
                containerWidth = geometry.size.width
                measureText()
                if textWidth > containerWidth {
                    startAnimation()
                }
            }
            .onChange(of: text) { _, _ in
                offset = 0
                isAnimating = false
                measureText()
                if textWidth > containerWidth {
                    startAnimation()
                }
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                containerWidth = newWidth
                if textWidth > containerWidth && !isAnimating {
                    startAnimation()
                } else if textWidth <= containerWidth {
                    offset = 0
                    isAnimating = false
                }
            }
        }
        .frame(height: 20) // Fixed height for consistent layout
    }

    private func measureText() {
        let uiFont: UIFont
        // Convert SwiftUI Font to UIFont for measurement
        uiFont = UIFont.systemFont(ofSize: 14, weight: .medium)

        let attributes: [NSAttributedString.Key: Any] = [.font: uiFont]
        let size = (text as NSString).size(withAttributes: attributes)
        textWidth = size.width
    }

    private func startAnimation() {
        guard !isAnimating else { return }
        isAnimating = true

        // Start from visible position
        offset = 0

        // Delay before starting scroll
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard isAnimating else { return }

            // Calculate scroll distance (text width + spacing)
            let scrollDistance = -(textWidth + spacing)
            let duration = Double(textWidth + spacing) / 40.0 // 40 points per second

            withAnimation(.linear(duration: duration)) {
                offset = scrollDistance
            }

            // Schedule reset and restart
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                offset = 0
                isAnimating = false
                // Restart animation if still showing
                if textWidth > containerWidth {
                    startAnimation()
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        MarqueeText(
            text: "This is a very long text that should scroll across the screen in a marquee fashion",
            font: .system(size: 14, weight: .medium),
            color: .white
        )
        .frame(width: 200)
        .background(Color.gray.opacity(0.3))

        MarqueeText(
            text: "Short text",
            font: .system(size: 14, weight: .medium),
            color: .white
        )
        .frame(width: 200)
        .background(Color.gray.opacity(0.3))
    }
    .padding()
    .background(Color.black)
}
