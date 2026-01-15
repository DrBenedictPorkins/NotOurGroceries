import SwiftUI
import PhotosUI
import UIKit

/// Sheet for capturing/selecting store aisle photos for LLM extraction
struct AisleScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @StateObject private var storeService = StoreService.shared

    let store: HouseholdStore
    var onComplete: (() -> Void)?

    // MARK: - State

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedImages: [UIImage] = []
    @State private var isShowingCamera = false

    // Processing state
    @State private var isProcessing = false
    @State private var processingStatus: String = ""

    // Completion state
    @State private var completedJob: AisleExtractionJob?

    // Error state
    @State private var errorMessage: String? = nil
    @State private var showError = false

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
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                }
            }
            .sheet(isPresented: $isShowingCamera) {
                CameraViewMultiple(images: $selectedImages)
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
                .foregroundColor(DesignSystem.Colors.neonCyan.opacity(0.7))

            // Instructions
            VStack(spacing: 8) {
                Text("Capture Store Directory")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                Text("Take a photo of the store's aisle directory or select an existing photo to automatically map products to aisles.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
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
                            .fill(DesignSystem.Colors.neonCyan.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(DesignSystem.Colors.neonCyan, lineWidth: 1.5)
                            )
                    )
                    .shadow(color: DesignSystem.Shadows.neonCyanGlow, radius: 8)
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
                        .foregroundColor(DesignSystem.Colors.neonCyan)
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
                        .foregroundColor(DesignSystem.Colors.neonCyan)
                        .frame(width: 120, height: 160)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(DesignSystem.Colors.glassBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(
                                            style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                                        )
                                        .foregroundColor(DesignSystem.Colors.neonCyan.opacity(0.5))
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
                    .shadow(color: DesignSystem.Shadows.neonCyanGlow, radius: 8)
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

    private var processingView: some View {
        let service = AisleExtractionService.shared

        return VStack(spacing: 24) {
            Spacer()

            // Phase indicator
            if let job = service.currentJob, let phase = job.phase {
                HStack(spacing: 8) {
                    ForEach(1...3, id: \.self) { p in
                        Circle()
                            .fill(p <= phase ? DesignSystem.Colors.neonCyan : DesignSystem.Colors.glassBackground)
                            .frame(width: 12, height: 12)
                    }
                }

                Text("Phase \(phase) of 3")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            // Animated icon
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.glassBackground)
                    .frame(width: 100, height: 100)

                Image(systemName: phaseIcon)
                    .font(.system(size: 40, weight: .thin))
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                    .symbolEffect(.pulse)
            }

            // Status text
            VStack(spacing: 8) {
                if let job = service.currentJob {
                    Text(job.phaseLabel ?? "Processing...")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    if let detail = job.detail {
                        Text(detail)
                            .font(.system(size: 14))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
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

            // Polling countdown
            if service.secondsUntilNextPoll > 0 {
                Text("Checking in \(service.secondsUntilNextPoll)s...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary.opacity(0.7))
            }

            Spacer()
        }
    }

    // Helper for phase-specific icon
    private var phaseIcon: String {
        guard let phase = AisleExtractionService.shared.currentJob?.phase else {
            return "doc.text.magnifyingglass"
        }
        switch phase {
        case 1: return "doc.text.viewfinder"  // OCR
        case 2: return "arrow.triangle.branch" // Matching
        case 3: return "square.and.arrow.down" // Applying
        default: return "doc.text.magnifyingglass"
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

            if let error = AisleExtractionService.shared.currentJob?.lastError ?? errorMessage {
                Text(error)
                    .font(.system(size: 14))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            HStack(spacing: 16) {
                Button("Try Again") {
                    // Reset and retry
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
                    statRow(icon: "doc.text.viewfinder", color: DesignSystem.Colors.neonCyan, label: "Aisle entries found", value: entries)
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
                    .shadow(color: DesignSystem.Shadows.neonCyanGlow, radius: 8)
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
        isProcessing = true
        processingStatus = "Preparing images..."

        let extractionService = AisleExtractionService.shared

        do {
            // Convert images to data with size limits for Claude API (max 5MB per image)
            var imageDataArray: [Data] = []
            for (index, image) in selectedImages.enumerated() {
                processingStatus = "Compressing image \(index + 1) of \(selectedImages.count)..."
                if let data = compressImageForUpload(image, maxSizeBytes: 4_500_000) {
                    imageDataArray.append(data)
                }
            }

            // Process with job-based flow
            // Lambda handles all phases: upload -> OCR -> match -> apply mappings
            // Returns completed job with stats
            let job = try await extractionService.processStoreAisles(
                images: imageDataArray,
                storeId: store.id
            )

            await MainActor.run {
                isProcessing = false
                completedJob = job
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }

        } catch {
            await MainActor.run {
                isProcessing = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    /// Compress and resize image to fit within maxSizeBytes
    private func compressImageForUpload(_ image: UIImage, maxSizeBytes: Int) -> Data? {
        var currentImage = image
        let maxDimension: CGFloat = 2048  // Good quality while keeping size manageable

        // First, resize if image is too large
        let size = currentImage.size
        if size.width > maxDimension || size.height > maxDimension {
            let scale = min(maxDimension / size.width, maxDimension / size.height)
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)

            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            currentImage.draw(in: CGRect(origin: .zero, size: newSize))
            if let resizedImage = UIGraphicsGetImageFromCurrentImageContext() {
                currentImage = resizedImage
            }
            UIGraphicsEndImageContext()
        }

        // Try progressive compression until under size limit
        var compressionQuality: CGFloat = 0.8
        var imageData = currentImage.jpegData(compressionQuality: compressionQuality)

        while let data = imageData, data.count > maxSizeBytes, compressionQuality > 0.1 {
            compressionQuality -= 0.1
            imageData = currentImage.jpegData(compressionQuality: compressionQuality)
        }

        return imageData
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
