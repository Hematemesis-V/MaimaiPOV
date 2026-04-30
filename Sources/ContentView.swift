import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var focusValue: Double = 0.5
    @State private var syncOffset: Double = -25.0

    var body: some View {
        VStack(spacing: 20) {
            Text("Maimai POV Stabilizer")
                .font(.headline)
                .foregroundColor(.cyan)

            if cameraManager.cameraAuthorized {
                CameraPreviewView(session: cameraManager.session)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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

                Text(cameraManager.isRunning ? "Camera: Running" : "Camera: Stopped")
                    .foregroundColor(cameraManager.isRunning ? .green : .orange)
            }.padding()
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
