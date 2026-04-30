# 📱 Maimai POV Stabilizer - iOS Frontend Spec

## 1. 系统核心定位
本项目是一个运行在 iPhone 15 Pro (巨魔环境) 上的极致低延迟视频与姿态采集服务端。其唯一目标是以最高性能抓取“片门全开”的无压缩视频流及高频陀螺仪数据，通过 USB 有线网络映射，零拷贝传输至 PC 端的空间防抖渲染管线。

## 2. 核心架构与线程模型
为了规避系统调度延迟，App 采用严格的三线程异步架构：
* **📡 线程 A (Network Server):** TCP 服务端，监听 `8888` 端口。负责与 PC (通过 `usbmuxd` 映射) 建立长连接，并执行无阻塞的 `send` 操作。
* **🎛️ 线程 B (Motion 采集):** 独立的高优先级队列，以 200Hz 频率疯狂读取 `CMMotionManager` 的融合姿态数据 (DeviceMotion)，并维护一个时长 0.5 秒的“环形时间戳缓冲区”。
* **📷 线程 C (Camera Delegate):** 视频帧回调线程 (60Hz)。接收到 NV12 内存指针后，提取硬件时间戳，向 Motion 缓冲区请求差值计算，完成 88 字节包头拼接，最后投递给网络线程。

## 3. 视觉管线参数 (极严苛限制)
为保证后续 PC 端世界锁防抖的绝对精确，相机的硬件参数必须写死或绕过系统自动逻辑：
* **画面比例与分辨率 (片门全开):** * iPhone 传感器原生比例为 4:3。为了获取最大的垂直视野（竖屏 3:4 片门全开），在 `AVCaptureSession` 中配置高分辨率的 4:3 Preset（如 `AVCaptureSession.Preset.photo` 或特定的高帧率 Format）。
    * 通过 `AVCaptureVideoDataOutput` 强制输出为 1080x1440 分辨率的 NV12 (Bi-Planar YUV 420) 格式。
* **帧率:** 严格锁定 60 FPS (`minFrameDuration` 与 `maxFrameDuration` = 1/60)。
* **快门与曝光:** * 快门时间 (Exposure Duration) 死锁在 **1/240 秒**。
    * ISO 设置为动态自动调节，确保画面亮度。
* **对焦:** 锁定为手动对焦 (Manual Focus)，并通过 UI 滑块提供调节接口，防止打机时手部动作触发反复抽搐拉箱。
* **防抖 (致命红线):** 必须通过 `connection.preferredVideoStabilizationMode = .off` 彻底关闭 OIS (光学防抖) 和 EIS (电子防抖)。
* **白平衡:** 提供锁定当前环境色温的按钮，防止机台闪光导致画面偏色。

## 4. 姿态同步与 RSC (卷帘快门补偿) 逻辑
PC 端的数学模型需要画面顶部、中心、底部的三个精准四元数。
* **基准时间:** 以 `AVCaptureVideoDataOutput` 提供的 `CMSampleBufferGetPresentationTimeStamp` 为准。
* **时间偏移 UI:** 提供一个 Slider (范围 -50.0ms 到 +50.0ms) 作为 `SYNC_OFFSET_MS`，用于手动校准 iOS 摄像头与陀螺仪的底层硬件时钟差。
* **RSC 计算:** 假设 Sensor 读出时间 (Readout Time) 为 9.18ms，当一帧画面的中心时间戳为 $t$ 时：
    * $Q_{top}$ 取自时间 $t - 4.59ms$
    * $Q_{center}$ 取自时间 $t$
    * $Q_{bottom}$ 取自时间 $t + 4.59ms$
    * 以上三个值均通过在 200Hz 缓冲区中二分查找相邻时间点并执行 `Slerp` (球面线性插值) 获得。

## 5. 网络通讯协议 (TCP Payload)
发送给 PC 的每一帧数据包结构必须与 PC 端的 `struct.Struct("<4sd4f4f4fI")` 严格对齐：
* **包头 Header (共 88 Bytes，小端序 Little-Endian):**
    * `Magic String` (4 Bytes): 固定的 `"SYNC"` 字符。
    * `Timestamp` (8 Bytes, Double): 当前帧的中心时间戳 (毫秒)。
    * `Q_Top` (16 Bytes, 4x Float): $W, X, Y, Z$
    * `Q_Center` (16 Bytes, 4x Float): $W, X, Y, Z$
    * `Q_Bottom` (16 Bytes, 4x Float): $W, X, Y, Z$
    * `Payload Size` (4 Bytes, UInt32): 后续 NV12 数据的字节数 (1080 * 1440 * 1.5 = 2,332,800)。
* **包体 Payload:**
    * 直接读取 `CVPixelBuffer` 的底层内存指针 (`CVPixelBufferGetBaseAddress`) 灌入 Socket 发送，全程**零拷贝**。

---

## 🚀 推荐开发流程 (分阶段实施)

为了避免代码耦合和调试困难，建议按照以下 4 个阶段向你的 AI 助手下达开发指令：

**Phase 1: 骨架与 UI 搭建 (UI & Permissions)**
* 配置巨魔/越狱环境下的 `Info.plist` (相机、网络权限)。
* 使用 SwiftUI 搭建控制面板界面。
* 包含元素：预览窗口、对焦滑块 (0.0~1.0)、时间轴偏移滑块 (-50~50ms)、锁定白平衡按钮、服务端状态文本。

**Phase 2: 极限相机管线 (The Camera Engine)**
* 封装 `CameraManager` 类。
* 实现 1/240 快门锁定、OIS 关闭、分辨率裁切输出为 1080x1440 NV12 的核心逻辑。
* 验证 `CVPixelBuffer` 的回调帧率是否稳定 60FPS，内存是否泄漏。

**Phase 3: 200Hz 陀螺仪与环形缓冲区 (Motion & Math)**
* 封装 `MotionManager` 类，开启 200Hz DeviceMotion。
* 实现线程安全的 Ring Buffer。
* 实现纳秒级 `mach_time` 到系统绝对时间的转换，确保视频戳与 IMU 戳处于同一时间域。
* 实现基于时间的四元数球面线性插值 (Slerp) 算法。

**Phase 4: 零拷贝网络传输 (Network & Integration)**
* 封装 `TCPServer` 类，绑定 8888 端口。
* 在 Camera 的每帧回调中，拼装 88 字节 Header。
* 锁定 `CVPixelBuffer` 内存，结合 Header 执行底层 socket 的 `send`，跑通与 PC 的全链路。