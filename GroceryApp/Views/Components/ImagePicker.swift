import SwiftUI
import UIKit
import AVFoundation
import Photos

/// A SwiftUI wrapper for UIImagePickerController that handles camera and photo library access
/// with automatic image processing (resize and compression).
struct ImagePicker: UIViewControllerRepresentable {

    /// The source type for image selection
    enum SourceType {
        case camera
        case photoLibrary

        var uiImagePickerSourceType: UIImagePickerController.SourceType {
            switch self {
            case .camera:
                return .camera
            case .photoLibrary:
                return .photoLibrary
            }
        }
    }

    /// Permission status for the image picker
    enum PermissionStatus {
        case authorized
        case denied
        case notDetermined
        case restricted
    }

    let sourceType: SourceType
    let onImageSelected: (Data) -> Void
    let onCancel: () -> Void

    /// Maximum dimension (width or height) for the processed image
    private let maxImageDimension: CGFloat = 1920

    /// JPEG compression quality (0.0 to 1.0)
    private let compressionQuality: CGFloat = 0.8

    // MARK: - Permission Checking

    /// Checks if the specified source type is available on the device
    static func isSourceTypeAvailable(_ sourceType: SourceType) -> Bool {
        UIImagePickerController.isSourceTypeAvailable(sourceType.uiImagePickerSourceType)
    }

    /// Checks the current permission status for the camera
    static func cameraPermissionStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }

    /// Checks the current permission status for the photo library
    static func photoLibraryPermissionStatus() -> PermissionStatus {
        let status: PHAuthorizationStatus
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch status {
        case .authorized, .limited:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }

    /// Requests camera permission
    static func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// Requests photo library permission
    static func requestPhotoLibraryPermission(completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                completion(status == .authorized || status == .limited)
            }
        }
    }

    // MARK: - UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType.uiImagePickerSourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onImageSelected: onImageSelected,
            onCancel: onCancel,
            maxDimension: maxImageDimension,
            compressionQuality: compressionQuality
        )
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImageSelected: (Data) -> Void
        let onCancel: () -> Void
        let maxDimension: CGFloat
        let compressionQuality: CGFloat

        init(
            onImageSelected: @escaping (Data) -> Void,
            onCancel: @escaping () -> Void,
            maxDimension: CGFloat,
            compressionQuality: CGFloat
        ) {
            self.onImageSelected = onImageSelected
            self.onCancel = onCancel
            self.maxDimension = maxDimension
            self.compressionQuality = compressionQuality
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)

            guard let originalImage = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }

            // Process the image on a background thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                let processedImage = ImageProcessor.resizeImage(
                    originalImage,
                    maxDimension: self.maxDimension
                )

                guard let imageData = ImageProcessor.compressToJPEG(
                    processedImage,
                    quality: self.compressionQuality
                ) else {
                    DispatchQueue.main.async {
                        self.onCancel()
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.onImageSelected(imageData)
                }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onCancel()
        }
    }
}

// MARK: - Image Processing Helper

/// Helper struct for image processing operations
struct ImageProcessor {

    /// Resizes an image so that its longest edge does not exceed the specified maximum dimension.
    /// Maintains aspect ratio and handles image orientation correctly.
    /// - Parameters:
    ///   - image: The original image to resize
    ///   - maxDimension: The maximum allowed width or height
    /// - Returns: The resized image, or the original if already within bounds
    static func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let originalSize = image.size

        // Check if resizing is needed
        guard originalSize.width > maxDimension || originalSize.height > maxDimension else {
            return image
        }

        // Calculate the new size maintaining aspect ratio
        let aspectRatio = originalSize.width / originalSize.height
        let newSize: CGSize

        if originalSize.width > originalSize.height {
            // Landscape: constrain width
            newSize = CGSize(
                width: maxDimension,
                height: maxDimension / aspectRatio
            )
        } else {
            // Portrait or square: constrain height
            newSize = CGSize(
                width: maxDimension * aspectRatio,
                height: maxDimension
            )
        }

        // Use UIGraphicsImageRenderer for better quality and memory efficiency
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        return resizedImage
    }

    /// Compresses an image to JPEG format with the specified quality.
    /// - Parameters:
    ///   - image: The image to compress
    ///   - quality: JPEG compression quality (0.0 to 1.0, where 1.0 is highest quality)
    /// - Returns: The compressed image data, or nil if compression fails
    static func compressToJPEG(_ image: UIImage, quality: CGFloat) -> Data? {
        image.jpegData(compressionQuality: quality)
    }

    /// Processes an image by resizing and compressing it in a single operation.
    /// - Parameters:
    ///   - image: The original image
    ///   - maxDimension: Maximum dimension for the longest edge (default: 1920)
    ///   - compressionQuality: JPEG quality (default: 0.8)
    /// - Returns: The processed image data, or nil if processing fails
    static func processImage(
        _ image: UIImage,
        maxDimension: CGFloat = 1920,
        compressionQuality: CGFloat = 0.8
    ) -> Data? {
        let resized = resizeImage(image, maxDimension: maxDimension)
        return compressToJPEG(resized, quality: compressionQuality)
    }
}

// MARK: - Convenience View Modifier

/// A view modifier that presents an ImagePicker as a sheet
struct ImagePickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let sourceType: ImagePicker.SourceType
    let onImageSelected: (Data) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                ImagePicker(
                    sourceType: sourceType,
                    onImageSelected: { data in
                        isPresented = false
                        onImageSelected(data)
                    },
                    onCancel: {
                        isPresented = false
                    }
                )
                .ignoresSafeArea()
            }
    }
}

extension View {
    /// Presents an image picker sheet when the binding is true.
    /// - Parameters:
    ///   - isPresented: Binding to control sheet presentation
    ///   - sourceType: Camera or photo library
    ///   - onImageSelected: Callback with processed image data
    func imagePicker(
        isPresented: Binding<Bool>,
        sourceType: ImagePicker.SourceType,
        onImageSelected: @escaping (Data) -> Void
    ) -> some View {
        modifier(ImagePickerModifier(
            isPresented: isPresented,
            sourceType: sourceType,
            onImageSelected: onImageSelected
        ))
    }
}
