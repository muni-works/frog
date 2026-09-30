import SwiftUI
import VisionKit

/// The camera, looking for the QR code in the Mac's settings. (The Camera app works too: the code
/// is a frog://pair link.)
struct Scanner: UIViewControllerRepresentable {
    let found: (URL) -> Void

    static var available: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .fast, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (URL) -> Void
        private var done = false
        init(found: @escaping (URL) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let s = code.payloadStringValue, let url = URL(string: s), Pairing.parse(url) != nil else { continue }
                done = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                found(url)
            }
        }
    }
}
