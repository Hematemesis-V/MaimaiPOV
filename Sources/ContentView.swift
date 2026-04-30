import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var focusValue: Double = 0.5
    @State private var syncOffset: Double = -25.0
    @State private var selectedLens: CameraManager.LensType = .main

    var body: some View {
        VStack(spacing: 20) {
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
                Text("Sync Offset (ms): \(syncOffset, specifier: "%.1f")")
                Slider(value: $syncOffset, in: -50.0...50.0)
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
        }
        .onChange(of: focusValue) { newValue in
            cameraManager.setFocus(Float(newValue))
        }
        .onDisappear {
            cameraManager.stopRunning()
        }
    }
}
