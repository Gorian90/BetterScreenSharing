import AVFoundation

/// Webbkameran. Sessionen körs bara när kameran är påslagen i scenen.
final class CameraController {
    let session = AVCaptureSession()
    private(set) lazy var previewLayer = AVCaptureVideoPreviewLayer(session: session)
    private let queue = DispatchQueue(label: "bss.camera")
    private var currentDeviceID: String?

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Ytterligare en bild från samma kamera, till exempel för kontrollpanelens förhandsvisning.
    /// Spegling sköts av scenen, så lagret får inte spegla själv.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
        return layer
    }

    /// `completion` får ett felmeddelande, eller nil om kameran startade.
    func start(deviceID: String?, completion: @escaping @MainActor (String?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure(deviceID: deviceID, completion: completion)
        case .notDetermined:
            // På nästa varv, så att guiden inte öppnas mitt i den tillståndsändring som slog på kameran.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    PermissionWizard.shared.run([.camera]) {
                        if PermissionStep.camera.isGranted {
                            self.configure(deviceID: deviceID, completion: completion)
                        } else {
                            completion(L("Camera access wasn't allowed.", "Kameraåtkomst tilläts inte."))
                        }
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                completion(L("Camera access is missing – turn it on in System Settings › Privacy & Security › Camera.", "Kameraåtkomst saknas – slå på den under Systeminställningar › Integritet och säkerhet › Kamera."))
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure(deviceID: String?, completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            let devices = Self.devices()
            guard let device = devices.first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .video) ?? devices.first else {
                DispatchQueue.main.async { completion(L("No camera found.", "Ingen kamera hittades.")) }
                return
            }
            if device.uniqueID != self.currentDeviceID || self.session.inputs.isEmpty {
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if self.session.canAddInput(input) { self.session.addInput(input) }
                    self.session.sessionPreset = self.session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
                } catch {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { completion(L("Couldn't open the camera: \(error.localizedDescription)", "Kunde inte öppna kameran: \(error.localizedDescription)")) }
                    return
                }
                self.session.commitConfiguration()
                self.currentDeviceID = device.uniqueID
            }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                // Spegling sköts med en transform i scenen, inte av förhandsvisningen.
                if let c = self.previewLayer.connection, c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = false
                }
                completion(nil)
            }
        }
    }
}
