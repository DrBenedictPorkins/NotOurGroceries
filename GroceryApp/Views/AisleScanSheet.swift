import SwiftUI
import PhotosUI
import UIKit

/// Sheet for capturing/selecting store aisle photos for LLM extraction
struct AisleScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @StateObject private var storeService = StoreService.shared
    @ObservedObject private var extractionService = AisleExtractionService.shared

    let store: HouseholdStore
    var onComplete: (() -> Void)?

    // MARK: - State

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedImages: [UIImage] = []
    @State private var isShowingCamera = false

    // Processing state - now driven by extractionService for job polling
    private var isProcessing: Bool { extractionService.isProcessing }
    private var processingStatus: String { extractionService.processingStatus }

    // Completion state
    @State private var completedJob: AisleExtractionJob?

    // Error state
    @State private var errorMessage: String? = nil
    @State private var showError = false

    // Manual aisle setup
    @State private var isCreatingAisles = false

    var body: some View {
        NavigationView {
            ZStack {
                // Background
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                DesignSystem.Colors.darkMetallicGradient
                    .ignoresSafeArea()
                    .opacity(0.3)

                if let job = completedJob {
                    completionView(job: job)
                } else if showError {
                    errorView
                } else if isProcessing {
                    processingView
                } else if !selectedImages.isEmpty {
                    imagesPreviewView
                } else {
                    captureOptionsView
                }
            }
            .navigationTitle("Scan Store Directory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                }
            }
            .sheet(isPresented: $isShowingCamera) {
                CameraViewMultiple(images: $selectedImages)
            }
            .task {
                // Check for active job on appear
                await checkForActiveJob()
            }
            // Progressive mapping refresh: update StoreAisleManagementView as each phase lands data
            .onChange(of: extractionService.currentPhase) { _, newPhase in
                // Phase 4 starting means Phase 3 (catalog mappings) just finished writing
                if newPhase == 4 {
                    Task { try? await storeService.fetchMappings(storeId: store.id) }
                }
            }
            .onChange(of: completedJob?.id) { _, jobId in
                // Job complete means Phase 4 (LLM inferred mappings) just finished writing
                if jobId != nil {
                    Task { try? await storeService.fetchMappings(storeId: store.id) }
                }
            }
        }
    }

    // MARK: - Active Job Check

    /// Check if there's an active extraction job for this store and resume if so
    private func checkForActiveJob() async {
        do {
            if let job = try await extractionService.resumeActiveJob(for: store.id) {
                // Job was already complete
                await MainActor.run {
                    completedJob = job
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
            // If job is in progress, the service will update its @Published properties
            // and the view will show processingView automatically
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    // MARK: - Capture Options View

    private var captureOptionsView: some View {
        VStack(spacing: 32) {
            Spacer()

            // Icon
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 64, weight: .thin))
                .foregroundColor(DesignSystem.Colors.dillGreen.opacity(0.7))

            // Instructions
            VStack(spacing: 8) {
                Text("Photograph the aisles")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                // The old copy said "the store's aisle directory", which assumes a
                // board on the wall. Plenty of shops have none — they have a sign
                // hanging over each aisle saying the number and roughly what is
                // down it, and photographing those one by one works just as well.
                // The scan already takes up to ten photos; it just never said so.
                Text("Two ways, whichever your shop has.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 10) {
                    scanHint(
                        icon: "list.bullet.rectangle",
                        title: "A directory board",
                        detail: "The list near the entrance showing every aisle and what is in it. One photo usually does it."
                    )
                    scanHint(
                        icon: "signpost.right",
                        title: "The signs above each aisle",
                        detail: "\"Aisle 4 — pasta, rice, sauces\". Walk the shop and photograph them one at a time. Up to ten per scan."
                    )
                }
                .padding(.top, 4)
                    .padding(.horizontal, 32)
            }

            Spacer()

            // Action buttons
            VStack(spacing: 16) {
                // Camera button
                Button(action: {
                    isShowingCamera = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Take Photo")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(DesignSystem.Colors.dillGreen.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(DesignSystem.Colors.dillGreen, lineWidth: 1.5)
                            )
                    )
                    .shadow(color: DesignSystem.Shadows.dillGreenGlow, radius: 8)
                }

                // Photo library picker - supports multiple selection
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 10,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Choose from Library")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(DesignSystem.Colors.glassBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                            )
                    )
                }
                .onChange(of: selectedPhotoItems) { _, newItems in
                    Task {
                        var images: [UIImage] = []
                        for item in newItems {
                            if let data = try? await item.loadTransferable(type: Data.self),
                               let image = UIImage(data: data) {
                                images.append(image)
                            }
                        }
                        await MainActor.run {
                            selectedImages.append(contentsOf: images)
                            selectedPhotoItems = [] // Reset for next selection
                        }
                    }
                }

            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Images Preview View (Multiple)

    private var imagesPreviewView: some View {
        VStack(spacing: 16) {
            // Header with count
            HStack {
                Text("\(selectedImages.count) photo\(selectedImages.count == 1 ? "" : "s") selected")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                Spacer()
                Button(action: {
                    selectedImages = []
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Text("Clear All")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.dillGreen)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // Horizontal scrollable image thumbnails
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                                )

                            // Remove button
                            Button(action: {
                                withAnimation {
                                    selectedImages.remove(at: index)
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white)
                                    .background(Circle().fill(.black.opacity(0.5)))
                            }
                            .offset(x: 6, y: -6)
                        }
                    }

                    // Add more button
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 10,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        VStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 32, weight: .light))
                            Text("Add More")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(DesignSystem.Colors.dillGreen)
                        .frame(width: 120, height: 160)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(DesignSystem.Colors.glassBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(
                                            style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                                        )
                                        .foregroundColor(DesignSystem.Colors.dillGreen.opacity(0.5))
                                )
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(height: 180)

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                // Process button
                Button(action: {
                    Task {
                        await processImages()
                    }
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Process \(selectedImages.count) Photo\(selectedImages.count == 1 ? "" : "s")")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(DesignSystem.Colors.accentGradient)
                    )
                    .shadow(color: DesignSystem.Shadows.dillGreenGlow, radius: 8)
                }

                // Take another photo
                Button(action: {
                    isShowingCamera = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "camera")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Take Another Photo")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Processing View

    /// Color for current phase - changes to show visual progress
    private var phaseColor: Color {
        guard let phase = extractionService.currentJob?.phase else {
            return DesignSystem.Colors.dillGreen
        }
        switch phase {
        case 1: return DesignSystem.Colors.dillGreen    // OCR - Cyan
        case 2: return DesignSystem.Colors.neonPurple  // Matching - Purple
        case 3: return DesignSystem.Colors.success     // Applying - Green
        default: return DesignSystem.Colors.dillGreen
        }
    }

    private var processingView: some View {
        VStack(spacing: 20) {
            Spacer()

            // Phase indicator with color per phase
            if let job = extractionService.currentJob, let phase = job.phase {
                HStack(spacing: 8) {
                    ForEach(1...3, id: \.self) { p in
                        Circle()
                            .fill(p <= phase ? colorForPhase(p) : DesignSystem.Colors.glassBackground)
                            .frame(width: 12, height: 12)
                            .animation(.easeInOut(duration: 0.3), value: phase)
                    }
                }

                Text("Phase \(phase) of 3")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(phaseColor.opacity(0.8))
                    .animation(.easeInOut(duration: 0.3), value: phase)
            }

            // Sonar ping animation with progress, phase color, and discovered items
            SonarPingView(
                secondsUntilNextPoll: extractionService.secondsUntilNextPoll,
                progress: jobProgress,
                accentColor: phaseColor,
                phase: extractionService.currentJob?.phase ?? 1,
                itemsFound: extractionService.currentJob?.entriesExtracted ?? 0
            )
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.5), value: extractionService.currentJob?.phase)

            // Status text
            VStack(spacing: 8) {
                if let job = extractionService.currentJob {
                    Text(job.phaseLabel ?? "Processing...")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    if let detail = job.detail {
                        Text(detail)
                            .font(.system(size: 14))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }

                    // Retry indicator
                    if let retryCount = job.retryCount, retryCount > 0 {
                        Label("Retry \(retryCount)/3", systemImage: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundColor(DesignSystem.Colors.warning)
                    }
                } else {
                    Text(processingStatus)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            Spacer()
        }
    }

    /// Calculate job progress (0.0 to 1.0) based on phase and detail parsing
    private var jobProgress: Double {
        guard let job = extractionService.currentJob else { return 0.0 }

        let phase = job.phase ?? 0
        let baseProgress: Double

        switch phase {
        case 1: baseProgress = 0.1  // OCR phase
        case 2: baseProgress = 0.3  // Matching phase
        case 3: baseProgress = 0.7  // Applying phase
        default: baseProgress = 0.0
        }

        // Try to parse progress from detail text (e.g., "Matching products 51-100 of 239...")
        if let detail = job.detail {
            // Pattern: "X-Y of Z" or "X of Z"
            let patterns = [
                try? NSRegularExpression(pattern: "(\\d+)-(\\d+) of (\\d+)"),
                try? NSRegularExpression(pattern: "(\\d+) of (\\d+)")
            ]

            for pattern in patterns.compactMap({ $0 }) {
                if let match = pattern.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)) {
                    if pattern.numberOfCaptureGroups == 3 {
                        // X-Y of Z format
                        if let endRange = Range(match.range(at: 2), in: detail),
                           let totalRange = Range(match.range(at: 3), in: detail),
                           let current = Double(detail[endRange]),
                           let total = Double(detail[totalRange]), total > 0 {
                            let phaseProgress = current / total
                            // Scale within phase range
                            if phase == 2 {
                                return 0.3 + (phaseProgress * 0.4) // 30% to 70%
                            } else if phase == 3 {
                                return 0.7 + (phaseProgress * 0.25) // 70% to 95%
                            }
                        }
                    } else if pattern.numberOfCaptureGroups == 2 {
                        // X of Z format
                        if let currentRange = Range(match.range(at: 1), in: detail),
                           let totalRange = Range(match.range(at: 2), in: detail),
                           let current = Double(detail[currentRange]),
                           let total = Double(detail[totalRange]), total > 0 {
                            let phaseProgress = current / total
                            if phase == 2 {
                                return 0.3 + (phaseProgress * 0.4)
                            } else if phase == 3 {
                                return 0.7 + (phaseProgress * 0.25)
                            }
                        }
                    }
                }
            }
        }

        return baseProgress
    }

    // Helper for phase-specific icon
    private var phaseIcon: String {
        guard let phase = extractionService.currentJob?.phase else {
            return "doc.text.magnifyingglass"
        }
        switch phase {
        case 1: return "doc.text.viewfinder"  // OCR
        case 2: return "arrow.triangle.branch" // Matching
        case 3: return "square.and.arrow.down" // Applying
        default: return "doc.text.magnifyingglass"
        }
    }

    /// Returns color for a specific phase number (for dot indicators)
    private func colorForPhase(_ phase: Int) -> Color {
        switch phase {
        case 1: return DesignSystem.Colors.dillGreen
        case 2: return DesignSystem.Colors.neonPurple
        case 3: return DesignSystem.Colors.success
        default: return DesignSystem.Colors.dillGreen
        }
    }

    // MARK: - Error View

    private var errorView: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(DesignSystem.Colors.error)

            Text("Processing Failed")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)

            if let error = extractionService.currentJob?.lastError ?? errorMessage {
                Text(error)
                    .font(.system(size: 14))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    Button("Try Again") {
                        showError = false
                        Task { await processImages() }
                    }
                    .buttonStyle(.bordered)

                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                }

            }
        }
    }

    private func scanHint(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.dillGreen)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Completion View

    private func completionView(job: AisleExtractionJob) -> some View {
        VStack(spacing: 24) {
            Spacer()

            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(DesignSystem.Colors.success)

            Text("Mappings Applied!")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            // Job stats
            VStack(spacing: 8) {
                if let entries = job.entriesExtracted, entries > 0 {
                    statRow(icon: "doc.text.viewfinder", color: DesignSystem.Colors.dillGreen, label: "Aisle entries found", value: entries)
                }

                if let created = job.mappingsCreated, created > 0 {
                    statRow(icon: "arrow.up.circle.fill", color: DesignSystem.Colors.success, label: "Mappings created", value: created)
                }

                if let high = job.highConfidence, high > 0 {
                    statRow(icon: "checkmark.seal.fill", color: DesignSystem.Colors.success, label: "High confidence", value: high)
                }

                if let low = job.lowConfidence, low > 0 {
                    statRow(icon: "questionmark.circle", color: DesignSystem.Colors.warning, label: "Low confidence", value: low)
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            // Done button
            Button(action: {
                onComplete?()
                dismiss()
            }) {
                Text("Done")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(DesignSystem.Colors.accentGradient)
                    )
                    .shadow(color: DesignSystem.Shadows.dillGreenGlow, radius: 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }

    private func statRow(icon: String, color: Color, label: String, value: Int) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(label)
                .foregroundColor(DesignSystem.Colors.textSecondary)
            Spacer()
            Text("\(value)")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
        .font(.system(size: 15, weight: .medium))
    }

    // MARK: - Actions

    private func processImages() async {
        guard !selectedImages.isEmpty else { return }

        // Reset error state if retrying
        showError = false
        errorMessage = nil

        do {
            // Convert images to data with size limits for Claude API (max 5MB per image)
            // Note: extractionService.processingStatus will show upload progress
            var imageDataArray: [Data] = []
            for (index, image) in selectedImages.enumerated() {
                // Update service status for compression phase
                await MainActor.run {
                    extractionService.processingStatus = "Compressing image \(index + 1) of \(selectedImages.count)..."
                    extractionService.isProcessing = true
                }
                if let data = compressImageForUpload(image, maxSizeBytes: 4_500_000) {
                    imageDataArray.append(data)
                }
            }

            // Process with job-based flow
            // Lambda handles all phases: upload -> OCR -> match -> apply mappings
            // Returns completed job with stats
            // Service updates its @Published properties during polling
            let job = try await extractionService.processStoreAisles(
                images: imageDataArray,
                storeId: store.id
            )

            await MainActor.run {
                completedJob = job
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }

        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    /// Resize and compress image for Claude OCR upload.
    /// 1568px long edge matches Claude's internal processing cap — no benefit going higher.
    /// JPEG quality 0.9 preserves text stroke detail needed for aisle directory OCR.
    ///
    /// IMPORTANT: UIImage.size is in logical points, not pixels. On a 3x device a 4032px photo
    /// has size.width = 1344 pts. Always multiply by image.scale to get actual pixel dimensions,
    /// and use format.scale = 1.0 so the renderer output is 1 point = 1 pixel.
    private func compressImageForUpload(_ image: UIImage, maxSizeBytes: Int) -> Data? {
        let maxLongEdge: CGFloat = 1568

        // Use actual pixel dimensions (size is in points; scale corrects for Retina)
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longEdgePx = max(pixelWidth, pixelHeight)

        let targetImage: UIImage
        if longEdgePx > maxLongEdge {
            let scaleFactor = maxLongEdge / longEdgePx
            let targetSize = CGSize(width: (pixelWidth * scaleFactor).rounded(), height: (pixelHeight * scaleFactor).rounded())
            // scale = 1.0 → output image is exactly targetSize pixels (1 point = 1 pixel)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            targetImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        } else {
            targetImage = image
        }

        // Step down quality until under the size limit
        for quality in [CGFloat(0.9), CGFloat(0.85), CGFloat(0.75), CGFloat(0.6), CGFloat(0.5)] {
            if let data = targetImage.jpegData(compressionQuality: quality), data.count <= maxSizeBytes {
                return data
            }
        }

        // Last resort: halve the resolution and try at 0.85
        let fallbackPixelWidth = targetImage.size.width * targetImage.scale
        let fallbackPixelHeight = targetImage.size.height * targetImage.scale
        let fallbackSize = CGSize(width: (fallbackPixelWidth * 0.5).rounded(), height: (fallbackPixelHeight * 0.5).rounded())
        let fallbackFormat = UIGraphicsImageRendererFormat()
        fallbackFormat.scale = 1.0
        let fallbackRenderer = UIGraphicsImageRenderer(size: fallbackSize, format: fallbackFormat)
        let fallbackImage = fallbackRenderer.image { _ in
            targetImage.draw(in: CGRect(origin: .zero, size: fallbackSize))
        }
        return fallbackImage.jpegData(compressionQuality: 0.85)
    }
}

// MARK: - Camera View for Multiple Photos

private struct CameraViewMultiple: UIViewControllerRepresentable {
    @Binding var images: [UIImage]
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraViewMultiple

        init(_ parent: CameraViewMultiple) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.images.append(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Camera View

struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView

        init(_ parent: CameraView) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    AisleScanSheet(store: HouseholdStore.preview)
        .environmentObject(ShoppingListViewModel())
}
