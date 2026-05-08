import CoreMedia
import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var focusValue: Double = 0.5
    @State private var syncOffset: Double = -25.0
    @State private var readoutTimeMs: Double = 9.18
    @State private var selectedLens: CameraManager.LensType = .main
    @State private var frameCounter = 0
    @State private var shutterIndex: Int = 10
    @State private var isoValue: Double = 50.0
    @State private var minISO: Double = 50.0
    @State private var maxISO: Double = 3200.0

    private let shutterOptions: [(label: String, timescale: Int32)] = [
        ("1/10000", 10000), ("1/8000", 8000), ("1/6000", 6000),
        ("1/4000", 4000), ("1/3000", 3000), ("1/2000", 2000),
        ("1/1500", 1500), ("1/1000", 1000), ("1/750", 750),
        ("1/500", 500), ("1/375", 375), ("1/250", 250),
        ("1/180", 180), ("1/125", 125), ("1/90", 90),
        ("1/60", 60),
    ]

    var body: some View {
        VStack(spacing: 12) {
            Text("Maimai POV Stabilizer")
                .font(.headline)
                .foregroundColor(.cyan)

            if cameraManager.cameraAuthorized {
                ZStack(alignment: .topTrailing) {
                    CameraPreviewView(session: cameraManager.session)
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if cameraManager.isRecording {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                            Text("REC")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.red)
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        .padding(8)
                    }
                }
            } else {
                Rectangle()
                    .fill(Color.black)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay(
                        Text("Camera Not Authorized")
                            .foregroundColor(.gray)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Picker("Lens", selection: $selectedLens) {
                ForEach(CameraManager.LensType.allCases, id: \.self) { lens in
                    Text(lens.rawValue).tag(lens)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)
            .onChange(of: selectedLens) { newLens in
                cameraManager.switchLens(to: newLens)
            }

            VStack(alignment: .leading) {
                Text("Focus: \(focusValue, specifier: "%.2f")")
                Slider(value: $focusValue, in: 0.0...1.0)
            }.padding(.horizontal)

            VStack(alignment: .leading) {
                HStack {
                    Text("Shutter: \(shutterOptions[shutterIndex].label)")
                    Spacer()
                    Button(cameraManager.exposureMode == .custom ? "Auto" : "Manual") {
                        if cameraManager.exposureMode == .custom {
                            cameraManager.setAutoExposure()
                        } else {
                            cameraManager.setCustomExposure()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .tint(cameraManager.exposureMode == .custom ? .orange : .green)
                }
                Slider(value: $shutterIndex, in: 0...Double(shutterOptions.count - 1), step: 1)
                    .disabled(cameraManager.exposureMode != .custom)
                    .opacity(cameraManager.exposureMode == .custom ? 1.0 : 0.4)
            }.padding(.horizontal)

            VStack(alignment: .leading) {
                Text("ISO: \(Int(isoValue))")
                Slider(value: $isoValue, in: minISO...maxISO, step: 1)
                    .disabled(cameraManager.exposureMode != .custom)
                    .opacity(cameraManager.exposureMode == .custom ? 1.0 : 0.4)
            }.padding(.horizontal)

            VStack(alignment: .leading) {
                Text("Sync Offset (ms): \(syncOffset, specifier: "%.1f")")
                Slider(value: $syncOffset, in: -50.0...50.0)
            }.padding(.horizontal)

            VStack(alignment: .leading) {
                Text("Readout Time (ms): \(readoutTimeMs, specifier: "%.2f")")
                Slider(value: $readoutTimeMs, in: 5.0...15.0)
            }.padding(.horizontal)

            HStack {
                Button(cameraManager.awbLocked ? "Unlock AWB" : "Lock AWB") {
                    if cameraManager.awbLocked {
                        cameraManager.unlockWhiteBalance()
                    } else {
                        cameraManager.lockWhiteBalance()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(cameraManager.awbLocked ? .red : .blue)

                Spacer()

                Button(cameraManager.isRecording ? "Stop Rec" : "Rec") {
                    if cameraManager.isRecording {
                        cameraManager.stopRecording()
                    } else {
                        cameraManager.startRecording()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(cameraManager.isRecording ? .red : .gray)
            }
            .padding(.horizontal)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            cameraManager.checkPermissionAndStart()
            cameraManager.setFocus(Float(focusValue))
            MotionManager.shared.startUpdates()

            minISO = Double(cameraManager.getMinISO())
            maxISO = Double(cameraManager.getMaxISO())
            isoValue = minISO

            cameraManager.onFrame = { pixelBuffer, timestamp in
                frameCounter += 1
                if frameCounter % 3 != 0 { return }

                let frameTime = CMTimeGetSeconds(timestamp)
                let centerTime = frameTime + (syncOffset / 1000.0)
                let topTime = centerTime - (readoutTimeMs / 2000.0)
                let bottomTime = centerTime + (readoutTimeMs / 2000.0)

                if let topQuat = MotionManager.shared.getQuaternion(at: topTime),
                   let centerQuat = MotionManager.shared.getQuaternion(at: centerTime),
                   let bottomQuat = MotionManager.shared.getQuaternion(at: bottomTime) {

                    NetworkManager.shared.sendFrame(
                        buffer: pixelBuffer,
                        frameTimestamp: centerTime,
                        topQuat: topQuat,
                        centerQuat: centerQuat,
                        bottomQuat: bottomQuat
                    )
                }
            }
        }
        .onChange(of: focusValue) { newValue in
            cameraManager.setFocus(Float(newValue))
        }
        .onChange(of: shutterIndex) { newIndex in
            if cameraManager.exposureMode == .custom {
                let timescale = shutterOptions[Int(newIndex)].timescale
                let duration = CMTime(value: 1, timescale: timescale)
                cameraManager.setExposure(duration: duration, iso: Float(isoValue))
            }
        }
        .onChange(of: isoValue) { newValue in
            if cameraManager.exposureMode == .custom {
                let timescale = shutterOptions[shutterIndex].timescale
                let duration = CMTime(value: 1, timescale: timescale)
                cameraManager.setExposure(duration: duration, iso: Float(newValue))
            }
        }
        .onChange(of: syncOffset) { newValue in
            AppSyncConfig.syncOffsetMs = newValue
        }
        .onDisappear {
            cameraManager.onFrame = nil
            cameraManager.stopRunning()
            MotionManager.shared.stopUpdates()
        }
    }
}
