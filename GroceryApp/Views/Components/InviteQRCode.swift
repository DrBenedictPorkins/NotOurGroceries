import SwiftUI
import CoreImage.CIFilterBuiltins
import AVFoundation

/// Any payload as a QR square.
///
/// Two things use this: a household invite code, and handing a shopping list to
/// a guest's phone. Both are the same gesture — one person holds up a square,
/// the other points a camera at it — so both draw the same way.
struct QRSquare: View {
    let payload: String
    var size: CGFloat = 180
    /// `M` survives a fingerprint and is right for an invite square that gets
    /// handed around. `L` packs about 27% more in and makes a smaller, easier
    /// square, which is the better trade for a transfer that lives ten seconds
    /// on a screen with nothing to damage it.
    var correctionLevel: String = "M"

    private static let context = CIContext()

    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }

        // Render at the size it will be shown, scaled by nearest-neighbour, so
        // the modules stay hard-edged instead of being blurred by the view.
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = Self.context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
                    // A QR reader needs light modules on a dark ground or the
                    // reverse, with real contrast. The app is dark throughout, so
                    // the square gets its own white plate rather than being
                    // inverted, which many scanners refuse.
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignSystem.Colors.glassBackground)
                    .frame(width: size, height: size)
                    .overlay(
                        Text("Couldn't draw the code")
                            .font(.system(size: 12))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                    )
            }
        }
    }
}

/// The invite code as a QR square.
///
/// Most household invites happen in the same room — you hand someone the phone,
/// or they point theirs at yours. Reading eight characters aloud works and stays
/// as the fallback, but scanning is the path people will actually use, and it
/// cannot mishear a B for a D.
///
/// The payload is the bare code, nothing else. A URL would be nicer for someone
/// who does not have the app yet, but that needs a URL scheme, an
/// `apple-app-site-association` file and a web page to fall back to — none of
/// which exist. A plain code needs none of it and the scanner below is the only
/// thing that has to understand it.
struct InviteQRCode: View {
    let code: String
    var size: CGFloat = 180

    var body: some View {
        QRSquare(payload: code, size: size)
            .accessibilityLabel("Invite code \(code) as a QR square")
    }
}

/// Camera scanner for a QR square.
///
/// Reports the first code it reads and then stops. Both callers want exactly one
/// result: an invite admits one person, and a scanned list is handed over once.
///
/// The value arrives trimmed but otherwise untouched. It used to be upper-cased
/// here, which was invisible while an eight-character invite code was the only
/// thing being scanned and would have shouted every item on a shopping list.
struct QRScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onFound: (String) -> Void
        private var hasFound = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !hasFound,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            hasFound = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onFound(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    final class ScannerViewController: UIViewController {
        weak var delegate: AVCaptureMetadataOutputObjectsDelegate?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            // Set after adding the output — the available types are empty until
            // the output belongs to a session, and assigning an unsupported type
            // raises.
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            self.preview = preview
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard !session.isRunning else { return }
            // Off the main thread: starting a capture session blocks for a
            // noticeable moment and UIKit complains about it.
            Task.detached { [session] in session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard session.isRunning else { return }
            Task.detached { [session] in session.stopRunning() }
        }
    }
}
