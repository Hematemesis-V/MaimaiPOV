import AVFoundation
import CoreImage
import SwiftUI
import UIKit

class CameraManager: NSObject, ObservableObject {

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.maimai.camera", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    @Published var isRunning = false
    @Published var awbLocked = false

    private var currentDevice: AVCaptureDevice?

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    override init() {
        super.init()
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    deinit {
        if session.isRunning {
            session.stopRunning()
        }
    }

    func startRunning() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    func stopRunning() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    static func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("CameraManager: No back wide-angle camera")
            return
        }
        currentDevice = device

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("CameraManager: Cannot add input")
            return
        }
        session.addInput(input)

        configureFormat(for: device)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(videoOutput) else {
            print("CameraManager: Cannot add video output")
            return
        }
        session.addOutput(videoOutput)

        for connection in videoOutput.connections {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }

        configureExposure(for: device)
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    }

    private func configureFormat(for device: AVCaptureDevice) {
        var bestFormat: AVCaptureDevice.Format?
        var bestWidth: Int32 = 0

        for format in device.formats {
            let dims = format.formatDescription.dimensions
            let ratio = Double(dims.width) / Double(dims.height)
            guard abs(ratio - 4.0 / 3.0) < 0.01 else { continue }

            let supports60 = format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= 60.0
            }
            guard supports60 else { continue }

            if dims.width > bestWidth {
                bestFormat = format
                bestWidth = dims.width
            }
        }

        guard let format = bestFormat else {
            print("CameraManager: No 4:3 60fps format found")
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let fps60 = CMTime(value: 1, timescale: 60)
            device.activeVideoMinFrameDuration = fps60
            device.activeVideoMaxFrameDuration = fps60
            device.unlockForConfiguration()
            let d = format.formatDescription.dimensions
            print("CameraManager: Format \(d.width)x\(d.height) @ 60fps locked")
        } catch {
            print("CameraManager: Format config failed: \(error)")
        }
    }

    private func configureExposure(for device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.custom) else {
            print("CameraManager: Custom exposure not supported")
            return
        }
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: 240)
            device.setExposureModeCustom(duration: duration, iso: device.currentISO, completionHandler: nil)
            device.unlockForConfiguration()
            print("CameraManager: Exposure locked 1/240s, ISO=\(device.currentISO)")
        } catch {
            print("CameraManager: Exposure config failed: \(error)")
        }
    }

    func setFocus(_ value: Float) {
        guard let device = currentDevice,
              device.isFocusModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: value, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            print("CameraManager: Focus set failed: \(error)")
        }
    }

    func lockWhiteBalance() {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            device.setWhiteBalanceModeLocked(with: device.deviceWhiteBalanceGains, completionHandler: nil)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.awbLocked = true }
        } catch {
            print("CameraManager: WB lock failed: \(error)")
        }
    }

    func unlockWhiteBalance() {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            device.whiteBalanceMode = .continuousAutoWhiteBalance
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.awbLocked = false }
        } catch {
            print("CameraManager: WB unlock failed: \(error)")
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureVideoDataOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let scaled = scaleTo1080x1440(pixelBuffer)
        onFrame?(scaled, timestamp)
    }

    private func scaleTo1080x1440(_ source: CVPixelBuffer) -> CVPixelBuffer {
        let srcW = CVPixelBufferGetWidth(source)
        let srcH = CVPixelBufferGetHeight(source)

        if srcW == 1080 && srcH == 1440 { return source }

        let ciImage = CIImage(cvPixelBuffer: source)
        let portrait: CIImage
        if srcW > srcH {
            portrait = ciImage.oriented(.right)
        } else {
            portrait = ciImage
        }

        let pw = portrait.extent.width
        let ph = portrait.extent.height

        var destBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            1080, 1440,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs as CFDictionary,
            &destBuffer
        )
        guard let dest = destBuffer else { return source }

        let scaleX = 1080.0 / pw
        let scaleY = 1440.0 / ph
        let scale = min(scaleX, scaleY)
        let scaled = portrait.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let colorSpace = portrait.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        ciContext.render(
            scaled,
            to: dest,
            bounds: CGRect(x: 0, y: 0, width: 1080, height: 1440),
            colorSpace: colorSpace
        )

        return dest
    }
}

class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.connection?.videoOrientation = .portrait
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
