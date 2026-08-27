import SwiftUI

/// Sonar/radar ping animation for job polling visualization
/// Reacts continuously to progress changes with visual pattern shifts
struct SonarPingView: View {
    let secondsUntilNextPoll: Int
    let progress: Double // 0.0 to 1.0
    var accentColor: Color = DesignSystem.Colors.dillGreen
    var phase: Int = 1 // 1 = OCR (discovering), 2 = Matching (capturing), 3 = Applying (converging)
    var itemsFound: Int = 0 // Number of items discovered (for dot count)

    // Animation states
    @State private var scanLineAngle: Double = 0
    @State private var pingRingScale: CGFloat = 0.2
    @State private var pingRingOpacity: Double = 0.8
    @State private var discoveredDots: [DiscoveredDot] = []
    @State private var hasStarted = false
    @State private var progressPulse: CGFloat = 1.0 // Pulses on progress change
    @State private var lastProgress: Double = 0
    @State private var gridShift: Double = 0 // Shifts grid pattern on progress

    private var sonarColor: Color { accentColor }
    private let capturedColor = Color(red: 0.0, green: 1.0, blue: 0.5) // Bright green for captured

    // Calculate how many dots to show based on progress and items
    private var targetDotCount: Int {
        let baseCount = min(max(itemsFound / 10, 3), 12) // 3-12 dots based on items
        return Int(Double(baseCount) * min(progress * 2, 1.0)) // Appear in first half of progress
    }

    // Grid ring scales shift based on progress
    private var gridScales: [CGFloat] {
        let base: [CGFloat] = [0.3, 0.5, 0.7, 0.9]
        let shift = CGFloat(gridShift * 0.05)
        return base.map { $0 + shift }
    }

    var body: some View {
        ZStack {
            // Progress arc (outer ring that fills)
            progressArc

            // Background radar grid (reactive to progress)
            radarGrid

            // Ping ring (pulses outward)
            Circle()
                .stroke(sonarColor.opacity(pingRingOpacity), lineWidth: 2)
                .scaleEffect(pingRingScale)

            // Rotating scan line (intensity varies with progress)
            scanLine

            // Center point (grows with progress)
            Circle()
                .fill(sonarColor)
                .frame(width: 8 + CGFloat(progress * 6), height: 8 + CGFloat(progress * 6))
                .scaleEffect(progressPulse)
                .shadow(color: sonarColor, radius: 4 + CGFloat(progress * 4))

            // Discovered item dots
            ForEach(discoveredDots) { dot in
                DotView(
                    dot: dot,
                    phase: phase,
                    progress: progress,
                    sonarColor: sonarColor,
                    capturedColor: capturedColor
                )
            }

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
            if newValue > oldValue {
                triggerPing()
            }
        }
        .onChange(of: progress) { _, newProgress in
            onProgressChange(newProgress)
        }
        .onChange(of: phase) { _, newPhase in
            onPhaseChange(newPhase)
        }
    }

    // MARK: - Progress Arc

    private var progressArc: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(sonarColor.opacity(0.1), lineWidth: 3)
                .frame(width: 190, height: 190)

            // Progress fill
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    sonarColor.opacity(0.6),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 190, height: 190)
                .rotationEffect(.degrees(-90))

            // Tick marks that appear as progress increases
            ForEach(0..<12, id: \.self) { i in
                let tickProgress = Double(i) / 12.0
                Rectangle()
                    .fill(sonarColor.opacity(progress > tickProgress ? 0.5 : 0.1))
                    .frame(width: 2, height: progress > tickProgress ? 8 : 4)
                    .offset(y: -92)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
        }
    }

    // MARK: - Radar Grid

    private var radarGrid: some View {
        ZStack {
            // Concentric circles (shift with progress)
            ForEach(Array(gridScales.enumerated()), id: \.offset) { index, scale in
                let ringProgress = Double(index + 1) / 4.0
                let isActive = progress >= ringProgress * 0.25
                Circle()
                    .stroke(sonarColor.opacity(isActive ? 0.25 : 0.12), lineWidth: isActive ? 1.5 : 1)
                    .scaleEffect(scale)
            }

            // Cross lines (opacity varies with progress)
            Path { path in
                path.move(to: CGPoint(x: 100, y: 20))
                path.addLine(to: CGPoint(x: 100, y: 180))
                path.move(to: CGPoint(x: 20, y: 100))
                path.addLine(to: CGPoint(x: 180, y: 100))
            }
            .stroke(sonarColor.opacity(0.08 + progress * 0.1), lineWidth: 1)

            // Diagonal lines
            Path { path in
                path.move(to: CGPoint(x: 40, y: 40))
                path.addLine(to: CGPoint(x: 160, y: 160))
                path.move(to: CGPoint(x: 160, y: 40))
                path.addLine(to: CGPoint(x: 40, y: 160))
            }
            .stroke(sonarColor.opacity(0.06 + progress * 0.08), lineWidth: 1)
        }
    }

    // MARK: - Scan Line

    private var scanLine: some View {
        // Trail intensity increases with progress
        let trailIntensity = 0.1 + progress * 0.2
        let trailWidth = 45.0 + progress * 30.0 // Wider trail as progress increases

        return ZStack {
            // Sweep trail (gradient fan - grows with progress)
            AngularGradient(
                gradient: Gradient(colors: [
                    sonarColor.opacity(0.0),
                    sonarColor.opacity(0.0),
                    sonarColor.opacity(trailIntensity * 0.3),
                    sonarColor.opacity(trailIntensity * 0.6),
                    sonarColor.opacity(trailIntensity),
                    sonarColor.opacity(0.0)
                ]),
                center: .center,
                startAngle: .degrees(scanLineAngle - trailWidth),
                endAngle: .degrees(scanLineAngle)
            )
            .clipShape(Circle())
            .scaleEffect(0.95)

            // Main scan line (brighter with progress)
            Path { path in
                path.move(to: CGPoint(x: 100, y: 100))
                path.addLine(to: CGPoint(x: 100, y: 10))
            }
            .stroke(
                LinearGradient(
                    colors: [sonarColor.opacity(0.7 + progress * 0.3), sonarColor.opacity(0.0)],
                    startPoint: .bottom,
                    endPoint: .top
                ),
                lineWidth: 2
            )
            .rotationEffect(.degrees(scanLineAngle))
        }
    }

    // MARK: - Animations

    private func startAnimations() {
        guard !hasStarted else { return }
        hasStarted = true

        // Initialize progress tracking
        lastProgress = progress

        // Scan line rotation - speed varies by phase
        let duration: Double = phase == 1 ? 3.0 : (phase == 2 ? 2.5 : 2.0)
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            scanLineAngle = 360
        }

        // Initial ping
        triggerPing()

        // Initialize dots
        updateDots(for: progress)
    }

    private func triggerPing() {
        // Reset ping ring
        pingRingScale = 0.15
        pingRingOpacity = 0.9

        // Animate outward
        withAnimation(.easeOut(duration: 1.5)) {
            pingRingScale = 1.1
            pingRingOpacity = 0.0
        }

        // In phase 1, potentially discover a new dot when ping happens
        if phase == 1 && discoveredDots.count < targetDotCount {
            addNewDot()
        }
    }

    private func onProgressChange(_ newProgress: Double) {
        // Only react if progress actually changed
        guard abs(newProgress - lastProgress) > 0.001 else { return }

        let progressDelta = newProgress - lastProgress
        lastProgress = newProgress

        // Pulse center point on progress change
        withAnimation(.easeOut(duration: 0.15)) {
            progressPulse = 1.15
        }
        withAnimation(.easeIn(duration: 0.2).delay(0.15)) {
            progressPulse = 1.0
        }

        // Shift grid pattern
        withAnimation(.easeInOut(duration: 0.3)) {
            gridShift = (gridShift + progressDelta * 5).truncatingRemainder(dividingBy: 1.0)
        }

        // Update dots
        updateDots(for: newProgress)

        // Trigger mini-ping on significant progress jumps
        if progressDelta > 0.05 {
            triggerMiniPing()
        }
    }

    private func updateDots(for newProgress: Double) {
        let needed = targetDotCount

        // Add dots if we need more
        while discoveredDots.count < needed {
            addNewDot()
        }
    }

    private func triggerMiniPing() {
        // Smaller ping for progress updates (not full countdown reset)
        pingRingScale = 0.4
        pingRingOpacity = 0.5

        withAnimation(.easeOut(duration: 0.6)) {
            pingRingScale = 0.8
            pingRingOpacity = 0.0
        }
    }

    private func addNewDot() {
        // Random angle and start at outer edge
        let angle = Double.random(in: 0..<360)
        let newDot = DiscoveredDot(
            id: UUID(),
            angle: angle,
            initialRadius: 85,
            appearTime: Date()
        )

        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            discoveredDots.append(newDot)
        }
    }

    private func onPhaseChange(_ newPhase: Int) {
        // When phase changes, trigger visual feedback
        triggerPing()

        // In phase 3, start converging all dots faster
        if newPhase == 3 {
            // Dots will automatically converge due to progress-based radius calculation
        }
    }
}

// MARK: - Discovered Dot Model

struct DiscoveredDot: Identifiable {
    let id: UUID
    let angle: Double // Position angle in degrees
    let initialRadius: CGFloat // Starting distance from center
    let appearTime: Date

    // Each dot has slight variation
    var orbitSpeed: Double { Double.random(in: 0.8...1.2) }
    var pulseOffset: Double { Double.random(in: 0...2) }
}

// MARK: - Dot View

struct DotView: View {
    let dot: DiscoveredDot
    let phase: Int
    let progress: Double
    let sonarColor: Color
    let capturedColor: Color

    @State private var currentAngle: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var isVisible: Bool = false
    @State private var progressBump: CGFloat = 0 // Reacts to progress changes

    // Calculate radius based on phase and progress (plus reactive bump)
    private var currentRadius: CGFloat {
        let baseRadius: CGFloat
        switch phase {
        case 1:
            // Phase 1: Dots at outer edge, move inward with progress
            baseRadius = dot.initialRadius - CGFloat(progress * 15)
        case 2:
            // Phase 2: Dots move inward as they're "captured"
            let captureProgress = min(progress * 1.5, 1.0)
            baseRadius = dot.initialRadius * CGFloat(1.0 - captureProgress * 0.6)
        case 3:
            // Phase 3: Dots converge to center
            let convergeProgress = min(progress * 2, 1.0)
            baseRadius = dot.initialRadius * CGFloat(1.0 - convergeProgress * 0.9)
        default:
            baseRadius = dot.initialRadius
        }
        return baseRadius + progressBump
    }

    // Dot color based on phase - gradient shift with progress
    private var dotColor: Color {
        switch phase {
        case 1: return sonarColor
        case 2: return progress > 0.3 ? capturedColor.opacity(0.7 + progress * 0.3) : sonarColor
        case 3: return capturedColor
        default: return sonarColor
        }
    }

    // Dot size grows slightly with progress
    private var dotSize: CGFloat {
        6 + CGFloat(progress * 3)
    }

    var body: some View {
        ZStack {
            // Outer glow ring
            Circle()
                .stroke(dotColor.opacity(0.3 + progress * 0.2), lineWidth: 1.5)
                .frame(width: (dotSize + 8) * pulseScale, height: (dotSize + 8) * pulseScale)

            // Inner dot
            Circle()
                .fill(dotColor)
                .frame(width: dotSize, height: dotSize)
                .shadow(color: dotColor, radius: 3 + CGFloat(progress * 2))
        }
        .opacity(isVisible ? 1.0 : 0.0)
        .offset(
            x: cos(currentAngle * .pi / 180) * currentRadius,
            y: sin(currentAngle * .pi / 180) * currentRadius
        )
        .onAppear {
            currentAngle = dot.angle

            // Fade in
            withAnimation(.easeOut(duration: 0.3)) {
                isVisible = true
            }

            // Start subtle orbit
            startOrbit()

            // Start pulse
            startPulse()
        }
        .onChange(of: progress) { _, _ in
            // React to every progress change with a small bump
            withAnimation(.easeOut(duration: 0.1)) {
                progressBump = -4 // Bump inward
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(0.1)) {
                progressBump = 0
            }
        }
        .onChange(of: phase) { _, _ in
            // Animate to new position when phase changes
            withAnimation(.easeInOut(duration: 0.8)) {
                // Radius changes are automatic via currentRadius
            }
        }
    }

    private func startOrbit() {
        // Subtle angle drift
        withAnimation(
            .easeInOut(duration: 4 * dot.orbitSpeed)
            .repeatForever(autoreverses: true)
        ) {
            currentAngle = dot.angle + (phase == 1 ? 30 : 15)
        }
    }

    private func startPulse() {
        withAnimation(
            .easeInOut(duration: 1.2 + dot.pulseOffset)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale = phase == 2 ? 1.4 : 1.2
        }
    }
}

// MARK: - Compact Sonar (for inline use)

/// Smaller sonar indicator for inline countdown display
struct CompactSonarView: View {
    let secondsUntilNextPoll: Int

    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity: Double = 0.8

    private let sonarColor = DesignSystem.Colors.dillGreen

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

#Preview("Sonar Ping - Phase 1") {
    ZStack {
        Color.black.ignoresSafeArea()
        SonarPingView(
            secondsUntilNextPoll: 2,
            progress: 0.3,
            accentColor: DesignSystem.Colors.dillGreen,
            phase: 1,
            itemsFound: 50
        )
    }
}

#Preview("Sonar Ping - Phase 2") {
    ZStack {
        Color.black.ignoresSafeArea()
        SonarPingView(
            secondsUntilNextPoll: 2,
            progress: 0.6,
            accentColor: DesignSystem.Colors.neonPurple,
            phase: 2,
            itemsFound: 100
        )
    }
}

#Preview("Sonar Ping - Phase 3") {
    ZStack {
        Color.black.ignoresSafeArea()
        SonarPingView(
            secondsUntilNextPoll: 2,
            progress: 0.9,
            accentColor: DesignSystem.Colors.success,
            phase: 3,
            itemsFound: 100
        )
    }
}
