import simd
import Foundation
import Network
import VideoToolbox

class NetworkManager {

    static let shared = NetworkManager()

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.maimai.network", qos: .userInteractive)

    private init() {
        do {
            listener = try NWListener(using: .tcp, on: 8080)
        } catch {
            print("NetworkManager: Listener init failed: \(error)")
            return
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("NetworkManager: Listening on port 8080")
            case .failed(let err):
                print("NetworkManager: Listener failed: \(err)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }

        listener?.start(queue: queue)
    }

    private func handleNewConnection(_ conn: NWConnection) {
        print("NetworkManager: Client connected: \(conn.endpoint)")
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("NetworkManager: Connection ready")
            case .failed(let err):
                print("NetworkManager: Connection failed: \(err)")
                self?.cleanupConnection()
            case .cancelled:
                print("NetworkManager: Connection cancelled")
                self?.cleanupConnection()
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    private func cleanupConnection() {
        connection = nil
        print("NetworkManager: Connection cleaned up")
    }

    func sendFrame(
        buffer: CVPixelBuffer,
        frameTimestamp: Double,
        topQuat: simd_quatf,
        centerQuat: simd_quatf,
        bottomQuat: simd_quatf
    ) {
        guard let conn = connection else { return }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { return }

        let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let ySize = yStride * yHeight

        let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let uvSize = uvStride * uvHeight

        guard let yPtr = yBase, let uvPtr = uvBase, ySize > 0, uvSize > 0 else { return }

        let payloadSize = UInt32(ySize + uvSize)

        var header = Data(capacity: 64)
        if let syncData = "SYNC".data(using: .ascii) { header.append(syncData) }
        withUnsafeBytes(of: frameTimestamp) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: topQuat.vector.x) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: topQuat.vector.y) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: topQuat.vector.z) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: topQuat.vector.w) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: centerQuat.vector.x) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: centerQuat.vector.y) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: centerQuat.vector.z) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: centerQuat.vector.w) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bottomQuat.vector.x) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bottomQuat.vector.y) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bottomQuat.vector.z) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bottomQuat.vector.w) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: payloadSize) { header.append(contentsOf: $0) }

        let yData = Data(bytesNoCopy: yPtr, count: ySize, deallocator: .none)
        let uvData = Data(bytesNoCopy: uvPtr, count: uvSize, deallocator: .none)

        let fullPayload = header + yData + uvData

        conn.send(content: fullPayload, completion: .contentProcessed { error in
            if let error {
                print("NetworkManager: Send failed: \(error)")
            }
        })
    }
}
