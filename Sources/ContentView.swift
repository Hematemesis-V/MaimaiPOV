import SwiftUI

struct ContentView: View {
    @State private var focusValue: Double = 0.5
    @State private var syncOffset: Double = -25.0
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Maimai POV Stabilizer")
                .font(.headline)
                .foregroundColor(.cyan)
            
            // 假装这里是相机预览
            Rectangle()
                .fill(Color.black)
                .aspectRatio(3.0/4.0, contentMode: .fit)
                .overlay(Text("Camera Preview (1080x1440)").foregroundColor(.gray))
            
            VStack(alignment: .leading) {
                Text("Focus: \(focusValue, specifier: "%.2f")")
                Slider(value: $focusValue, in: 0.0...1.0)
            }.padding(.horizontal)
            
            VStack(alignment: .leading) {
                Text("Sync Offset (ms): \(syncOffset, specifier: "%.1f")")
                Slider(value: $syncOffset, in: -50.0...50.0)
            }.padding(.horizontal)
            
            HStack {
                Button("Lock AWB") {
                    print("AWB Locked")
                }
                .buttonStyle(.borderedProminent)
                
                Spacer()
                
                Text("Server: Waiting...")
                    .foregroundColor(.orange)
            }.padding()
        }
        .preferredColorScheme(.dark)
    }
}