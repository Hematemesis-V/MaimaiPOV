import AVFoundation
import CoreImage
import SwiftUI
import UIKit

class CameraManager: NSObject, ObservableObject {

    enum LensType: String, CaseIterable {
        case main = "Main (1x)"
        case ultraWide = "Ultra Wide (0.5x)"

        var deviceType: AVCaptureDevice.DeviceType {
            switch self {
            case .main:      return .builtInWideAngleCamera
            case .ultraWide: return .builtInUltraWideCamera
            }
        }
    }

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.maimai.camera", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    @Published var isRunning = false
    @Published var awbLocked = false
    @Published var cameraAuthorized = false
    @Published var activeLens: LensType = .main
    @Published var isRecording = false
    @Published var recordedFileURL: URL?

    private var currentDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime: CMTime?
    private var frameCount: Int64 = 0

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    override init() {
        super.init()
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

    func checkPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.cameraAuthorized = true }
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.configureSession(for: self.activeLens)
                self.session.startRunning()
                DispatchQueue.main.async { self.isRunning = self.session.isRunning }
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async { self.cameraAuthorized = granted }
                if granted {
                    self.sessionQueue.async {
                        self.configureSession(for: self.activeLens)
                        self.session.startRunning()
                        DispatchQueue.main.async { self.isRunning = self.session.isRunning }
                    }
                }
            }
        default:
            DispatchQueue.main.async { self.cameraAuthorized = false }
        }
    }

    private func configureSession(for lens: LensType) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let existing = currentInput {
            session.removeInput(existing)
            currentInput = nil
        }

        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
            print("CameraManager: No \(lens.rawValue) camera")
            return
        }
        currentDevice = device

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("CameraManager: Cannot add input for \(lens.rawValue)")
            return
        }
        session.addInput(input)
        currentInput = input

        configureFormat(for: device)

        if session.outputs.isEmpty {
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

            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        }

        configureExposure(for: device)
    }

    func switchLens(to lens: LensType) {
        guard lens != activeLens else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(for: lens)
            DispatchQueue.main.async { self.activeLens = lens }
        }
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
            device.setExposureModeCustom(duration: duration, iso: AVCaptureDevice.currentISO, completionHandler: nil)
            device.unlockForConfiguration()
            print("CameraManager: Exposure locked 1/240s, ISO=\(AVCaptureDevice.currentISO)")
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

    func startRecording() {
        guard !isRecording else { return }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "calib_\(Int(Date().timeIntervalSince1970)).mp4"
        let fileURL = docs.appendingPathComponent(filename)

        do {
            let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)

            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1080,
                AVVideoHeightKey: 1440
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferWidthKey as String: 1080,
                    kCVPixelBufferHeightKey as String: 1440
                ]
            )

            guard writer.canAdd(input) else {
                print("CameraManager: Cannot add writer input")
                return
            }
            writer.addInput(input)

            assetWriter = writer
            assetWriterInput = input
            pixelBufferAdaptor = adaptor
            recordingStartTime = nil
            frameCount = 0

            DispatchQueue.main.async {
                self.isRecording = true
                self.recordedFileURL = nil
            }
            print("CameraManager: Recording to \(fileURL.lastPathComponent)")
        } catch {
            print("CameraManager: AssetWriter init failed: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        assetWriterInput?.markAsFinished()
        assetWriter?.finishWriting { [weak self] in
            guard let self else { return }
            let url = self.assetWriter?.outputURL
            DispatchQueue.main.async {
                self.isRecording = false
                self.recordedFileURL = url
            }
            print("CameraManager: Recording saved to \(url?.lastPathComponent ?? "unknown")")
            self.assetWriter = nil
            self.assetWriterInput = nil
            self.pixelBufferAdaptor = nil
            self.recordingStartTime = nil
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let scaled = scaleTo1080x1440(pixelBuffer)

        if isRecording, let input = assetWriterInput, input.isReadyForMoreMediaData {
            if assetWriter?.status == .unknown {
                recordingStartTime = timestamp
                assetWriter?.startWriting()
                assetWriter?.startSession(atSourceTime: timestamp)
            }

            if let adaptor = pixelBufferAdaptor, assetWriter?.status == .writing {
                adaptor.append(scaled, withPresentationTime: timestamp)
                frameCount += 1
            }
        }

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
