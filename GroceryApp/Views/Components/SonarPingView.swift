import SwiftUI

/// Sonar/radar ping animation for job polling visualization
/// Creates expanding rings with a target blip that approaches as progress increases
struct SonarPingView: View {
    let secondsUntilNextPoll: Int
    let progress: Double // 0.0 to 1.0, target approaches center as progress increases

    // Animation states
    @State private var ringScales: [CGFloat] = [0.3, 0.3, 0.3]
    @State private var ringOpacities: [Double] = [0.8, 0.8, 0.8]
    @State private var targetAngle: Double = 45
    @State private var targetPulse: Bool = false
    @State private var scanLineAngle: Double = 0
    @State private var pingCount: Int = 0

    private let sonarColor = DesignSystem.Colors.neonCyan
    private let targetColor = Color(red: 0.0, green: 1.0, blue: 0.5) // Bright green blip

    var body: some View {
        ZStack {
            // Background radar grid
            radarGrid

            // Expanding ping rings
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(
                        sonarColor.opacity(ringOpacities[index]),
                        lineWidth: 2
                    )
                    .scaleEffect(ringScales[index])
            }

            // Rotating scan line
            scanLine

            // Center ping point
            Circle()
                .fill(sonarColor)
                .frame(width: 8, height: 8)
                .shadow(color: sonarColor, radius: 4)

            // Target blip - appears and approaches center based on progress
            targetBlip

            // Countdown text at bottom
            VStack {
                Spacer()
                Text("ping in \(secondsUntilNextPoll)s")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(sonarColor.opacity(0.7))
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 200, height: 200)
        .onAppear {
            startAnimations()
        }
        .onChange(of: secondsUntilNextPoll) { oldValue, newValue in
            // Trigger a new ping wave when countdown resets (poll completed)
            if newValue > oldValue {
                triggerPing()
            }
        }
    }

    // MARK: - Radar Grid

    private var radarGrid: some View {
        ZStack {
            // Concentric static circles (grid lines)
            ForEach([0.3, 0.5, 0.7, 0.9], id: \.self) { scale in
                Circle()
                    .stroke(sonarColor.opacity(0.15), lineWidth: 1)
                    .scaleEffect(scale)
            }

            // Cross lines
            Path { path in
                path.move(to: CGPoint(x: 100, y: 20))
                path.addLine(to: CGPoint(x: 100, y: 180))
                path.move(to: CGPoint(x: 20, y: 100))
                path.addLine(to: CGPoint(x: 180, y: 100))
            }
            .stroke(sonarColor.opacity(0.1), lineWidth: 1)

            // Diagonal lines
            Path { path in
                path.move(to: CGPoint(x: 40, y: 40))
                path.addLine(to: CGPoint(x: 160, y: 160))
                path.move(to: CGPoint(x: 160, y: 40))
                path.addLine(to: CGPoint(x: 40, y: 160))
            }
            .stroke(sonarColor.opacity(0.08), lineWidth: 1)
        }
    }

    // MARK: - Scan Line

    private var scanLine: some View {
        ZStack {
            // Sweep trail (gradient fan)
            AngularGradient(
                gradient: Gradient(colors: [
                    sonarColor.opacity(0.0),
                    sonarColor.opacity(0.0),
                    sonarColor.opacity(0.0),
                    sonarColor.opacity(0.05),
                    sonarColor.opacity(0.1),
                    sonarColor.opacity(0.15),
                    sonarColor.opacity(0.0)
                ]),
                center: .center,
                startAngle: .degrees(scanLineAngle - 45),
                endAngle: .degrees(scanLineAngle)
            )
            .clipShape(Circle())
            .scaleEffect(0.95)

            // Main scan line
            Path { path in
                path.move(to: CGPoint(x: 100, y: 100))
                path.addLine(to: CGPoint(x: 100, y: 10))
            }
            .stroke(
                LinearGradient(
                    colors: [sonarColor.opacity(0.8), sonarColor.opacity(0.0)],
                    startPoint: .bottom,
                    endPoint: .top
                ),
                lineWidth: 2
            )
            .rotationEffect(.degrees(scanLineAngle))
        }
    }

    // MARK: - Target Blip

    @State private var targetRadius: CGFloat = 70
    @State private var blipVisible: Bool = true

    private var targetBlip: some View {
        // Progress affects base radius - closer to center as job progresses
        let progressRadius = (1.0 - progress) * 50 + 20 // Range: 20-70 from center

        return ZStack {
            // Outer glow ring - pulses
            Circle()
                .stroke(targetColor.opacity(targetPulse ? 0.7 : 0.3), lineWidth: 2)
                .frame(width: targetPulse ? 28 : 18, height: targetPulse ? 28 : 18)

            // Inner blip
            Circle()
                .fill(targetColor)
                .frame(width: 10, height: 10)
                .shadow(color: targetColor, radius: targetPulse ? 10 : 5)

            // Echo ring that expands outward
            Circle()
                .stroke(targetColor.opacity(blipVisible ? 0.6 : 0.0), lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .scaleEffect(blipVisible ? 1.0 : 3.0)
        }
        .offset(
            x: cos(targetAngle * .pi / 180) * (progressRadius + targetRadius - 70),
            y: sin(targetAngle * .pi / 180) * (progressRadius + targetRadius - 70)
        )
    }

    // MARK: - Animations

    private func startAnimations() {
        // Continuous scan line rotation
        withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
            scanLineAngle = 360
        }

        // Initial ping wave
        triggerPing()

        // Target angle drift - slow orbit around center
        withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
            targetAngle = 315
        }

        // Target radius wobble - subtle in/out movement
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
            targetRadius = 85
        }

        // Target pulse glow
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            targetPulse = true
        }

        // Blip echo animation
        startBlipEcho()
    }

    private func startBlipEcho() {
        // Repeating echo effect
        withAnimation(.easeOut(duration: 1.5)) {
            blipVisible = false
        }

        // Reset and repeat
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            blipVisible = true
            startBlipEcho()
        }
    }

    private func triggerPing() {
        pingCount += 1

        // Stagger the ring animations
        for i in 0..<3 {
            let delay = Double(i) * 0.15

            // Reset
            ringScales[i] = 0.2
            ringOpacities[i] = 0.9

            // Animate outward
            withAnimation(.easeOut(duration: 1.5).delay(delay)) {
                ringScales[i] = 1.1
                ringOpacities[i] = 0.0
            }
        }
    }
}

// MARK: - Compact Sonar (for inline use)

/// Smaller sonar indicator for inline countdown display
struct CompactSonarView: View {
    let secondsUntilNextPoll: Int

    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity: Double = 0.8

    private let sonarColor = DesignSystem.Colors.neonCyan

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                // Ping ring
                Circle()
                    .stroke(sonarColor.opacity(ringOpacity), lineWidth: 1.5)
                    .frame(width: 24, height: 24)
                    .scaleEffect(ringScale)

                // Center dot
                Circle()
                    .fill(sonarColor)
                    .frame(width: 6, height: 6)
            }
            .frame(width: 30, height: 30)

            Text("checking in \(secondsUntilNextPoll)s")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(sonarColor.opacity(0.8))
        }
        .onAppear {
            animatePing()
        }
        .onChange(of: secondsUntilNextPoll) { oldValue, newValue in
            if newValue > oldValue {
                animatePing()
            }
        }
    }

    private func animatePing() {
        ringScale = 0.3
        ringOpacity = 1.0

        withAnimation(.easeOut(duration: 1.2)) {
            ringScale = 1.2
            ringOpacity = 0.0
        }
    }
}

// MARK: - Preview

#Preview("Sonar Ping") {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(spacing: 40) {
            SonarPingView(secondsUntilNextPoll: 2, progress: 0.3)

            CompactSonarView(secondsUntilNextPoll: 1)
        }
    }
}
