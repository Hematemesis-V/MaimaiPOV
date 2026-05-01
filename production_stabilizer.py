import cv2
import time
import math
import struct
import socket
import threading
import queue
import numpy as np
import torch
import torch.nn.functional as F
from ultralytics import YOLO

# ================================================================
# ⚙️ 全局参数化配置 (Production Config - Dual Lens System)
# ================================================================
CFG = {
    # 📡 网络与传输层
    "network": {
        "host": "127.0.0.1",        
        "port": 8080,               
        "reconnect_delay": 2.0,     
        "recv_buf_size": 1 << 20,   
    },
    
    # 📺 核心管线分辨率
    "resolution": {
        "nv12_w": 1440,             
        "nv12_h": 1920,             
        "stab_w": 1080,             
        "stab_h": 1440,             
        "yolo_in_size": 640,        
        "output_size": 540,         
    },
    
    # 📷 双镜头物理内参矩阵 (支持按键热切换)
    "cameras": {
        "calib_base_width": 1440.0, # 标定时画面的基准宽度 (用于自适应分辨率缩放)
        
        "main": {
            "name": "Main (Full Frame)",
            "fx": 681.64316686, "fy": 678.07553237,
            "cx": 720.0,        "cy": 960.0,
            "k1": 0.09888157,   "k2": -0.06466674,
            "k3": 0.0287103,    "k4": -0.00650599,
            "default_fov": 100  # 主摄默认的虚拟视野偏窄
        },
        
        "uw": {
            "name": "Ultra-Wide (Circular)",
            "fx": 385.42440948, "fy": 387.16735166,
            "cx": 719.80053711, "cy": 893.22271729, # 完美保留向上偏移的 80 像素！
            "k1": 0.05338301,   "k2": -0.00722338,
            "k3": -0.00279242,  "k4": -0.00033171,
            "default_fov": 145  # 超广角默认的虚拟视野更广
        }
    },
    
    # 🤖 AI 目标追踪参数
    "yolo": {
        "model_path": r"D:\maimai\maimai_trae\runs\detect\maimai_bbox_v1\exp_4060ti\weights\best.engine",
        "inner_screen_class": 1,    
        "confidence_threshold": 0.8,
        "padding": 40,              
    },
    
    # 🎯 运镜与平滑系统
    "tracking": {
        "alpha": 0.2,              
        "max_edge_speed": 15.0,     
        "inner_screen_ratio": 0.5,  
        "recenter_decay": 0.02,     
        "recenter_grace_sec": 0.5,  
    },
    
    # ⚡ GPU 算子极限优化
    "stabilizer": {
        "grid_ds": 10,              
    },
}

# ================================================================
# 📐 派生常量
# ================================================================
_NV12_W = CFG["resolution"]["nv12_w"]
_NV12_H = CFG["resolution"]["nv12_h"]
_STAB_W = CFG["resolution"]["stab_w"]
_STAB_H = CFG["resolution"]["stab_h"]
_YOLO_IN = CFG["resolution"]["yolo_in_size"]
_OUT_SIZE = CFG["resolution"]["output_size"]

PACK_HEADER = struct.Struct("<4sd4f4f4fI")
HEADER_SIZE = PACK_HEADER.size
EXPECTED_NV12 = _NV12_W * _NV12_H * 3 // 2

# ================================================================
# 🧠 CUDA 常驻显存池
# ================================================================
_NV12_CUDA_BUFFER = torch.empty(EXPECTED_NV12, dtype=torch.uint8, device="cuda")
_Y2R = torch.tensor([[1.0, 1.0, 1.0], [0.0, -0.344136, 1.772], [1.402, -0.714136, 0.0]], dtype=torch.float32, device="cuda")
_Q_CONJ = torch.tensor([1.0, -1.0, -1.0, -1.0], dtype=torch.float32, device="cuda")

# ================================================================
# 🧵 异步双轨通讯层 (保持不变)
# ================================================================
frame_queue = queue.Queue(maxsize=1)

class SharedCropState:
    def __init__(self):
        self.lock = threading.Lock()
        self.detected = False
        self.last_detect_time = 0.0
        self.cx = _STAB_W / 2.0
        self.cy = _STAB_H / 2.0
        self.crop_size = float(min(_STAB_W, _STAB_H))
        self._update_corners()

    def _update_corners(self):
        half = self.crop_size / 2.0
        self.x1 = int(max(0, self.cx - half))
        self.y1 = int(max(0, self.cy - half))
        self.x2 = int(min(_STAB_W, self.cx + half))
        self.y2 = int(min(_STAB_H, self.cy + half))

    def set_crop(self, cx, cy, crop_size):
        with self.lock:
            self.cx = cx
            self.cy = cy
            self.crop_size = float(crop_size)
            self.detected = True
            self.last_detect_time = time.monotonic()
            self._update_corners()

    def recenter_step(self):
        with self.lock:
            if not self.detected: return
            elapsed = time.monotonic() - self.last_detect_time
            if elapsed < CFG["tracking"]["recenter_grace_sec"]: return
            decay = CFG["tracking"]["recenter_decay"]
            target_cx = _STAB_W / 2.0
            target_cy = _STAB_H / 2.0
            target_size = float(min(_STAB_W, _STAB_H))
            self.cx += (target_cx - self.cx) * decay
            self.cy += (target_cy - self.cy) * decay
            self.crop_size += (target_size - self.crop_size) * decay
            self._update_corners()

    def get_crop(self):
        with self.lock:
            return self.x1, self.y1, self.x2, self.y2

    def get_ideal_params(self):
        with self.lock:
            return self.cx, self.cy, self.crop_size

shared_crop = SharedCropState()

def recv_exact(sock, n):
    buf = bytearray(n)
    view = memoryview(buf)
    off = 0
    chunk_size = CFG["network"]["recv_buf_size"]
    while off < n:
        chunk = sock.recv_into(view[off:], min(n - off, chunk_size))
        if not chunk: raise ConnectionError("Connection closed")
        off += chunk
    return buf

@torch.inference_mode()
def nv12_to_rgb_cuda(nv12_raw):
    raw_cpu = torch.frombuffer(nv12_raw, dtype=torch.uint8)
    _NV12_CUDA_BUFFER.copy_(raw_cpu, non_blocking=True)
    
    # 🎯 核心修复：顺应 iPhone 传感器的物理横向读取特性 (W=1920, H=1440)
    RAW_W = max(_NV12_W, _NV12_H)
    RAW_H = min(_NV12_W, _NV12_H)
    
    # 按照 1920x1440 的正确步长切分 Y 轴和 UV 轴，条纹瞬间消失！
    y = _NV12_CUDA_BUFFER[: RAW_H * RAW_W].reshape(RAW_H, RAW_W).float()
    uv = _NV12_CUDA_BUFFER[RAW_H * RAW_W :].reshape(RAW_H // 2, RAW_W)
    
    u = F.interpolate(uv[:, 0::2].float().unsqueeze(0).unsqueeze(0), size=(RAW_H, RAW_W), mode="bilinear", align_corners=False).squeeze()
    v = F.interpolate(uv[:, 1::2].float().unsqueeze(0).unsqueeze(0), size=(RAW_H, RAW_W), mode="bilinear", align_corners=False).squeeze()
    
    yuv = torch.stack([y, u - 128.0, v - 128.0], dim=-1)
    rgb = torch.matmul(yuv, _Y2R).clamp(0, 255) / 255.0
    
    # 🔄 GPU 零延迟旋转：将横向画面 (1440, 1920) 顺时针旋转 90 度，变回我们需要的标准竖屏
    # 如果你发现画面竖起来之后是“头朝下”的，把这里的 k=-1 改成 k=1 即可。
    rgb_portrait = torch.rot90(rgb, k=-1, dims=(0, 1))
    
    return rgb_portrait.permute(2, 0, 1).unsqueeze(0)

# ================================================================
# 🏗️ 动态光学引擎：带热切换的鱼眼防抖矫正器
# ================================================================
class ZeroCopyStabilizer:
    def __init__(self, in_h, in_w, out_h, out_w, grid_ds=10):
        self.device = "cuda"
        self.h_in, self.w_in = in_h, in_w
        self.h_out, self.w_out = out_h, out_w

        self.h_low = out_h // grid_ds
        self.w_low = out_w // grid_ds

        u, v = torch.meshgrid(
            torch.linspace(0, self.w_out - 1, self.w_low, device=self.device),
            torch.linspace(0, self.h_out - 1, self.h_low, device=self.device),
            indexing="xy",
        )
        self.x_s = u - self.w_out / 2.0
        self.y_s = v - self.h_out / 2.0
        r_s = torch.sqrt(self.x_s**2 + self.y_s**2)
        self.r_safe = torch.clamp(r_s, min=1e-5)
        self.r_norm = r_s / (self.w_out / 2.0)

        self.q_anchor = None
        self.rays_virtual_low = None
        self.rays_w_cache = None
        
        # 物理镜头参数容器
        self.fx = self.fy = self.cx = self.cy = 0.0
        self.k1 = self.k2 = self.k3 = self.k4 = 0.0
        
        self.state = {"fov": -1, "dist": -1, "yaw": -999, "pitch": -999, "roll": -999, "lens": None}

    def load_lens(self, lens_key):
        """核心：在 GPU 运行时瞬间切换物理镜头内参矩阵"""
        if self.state["lens"] == lens_key: return
        
        cam = CFG["cameras"][lens_key]
        scale = _NV12_W / CFG["cameras"]["calib_base_width"]
        
        self.fx = cam["fx"] * scale
        self.fy = cam["fy"] * scale
        self.cx = cam["cx"] * scale
        self.cy = cam["cy"] * scale
        self.k1 = cam["k1"]
        self.k2 = cam["k2"]
        self.k3 = cam["k3"]
        self.k4 = cam["k4"]
        
        # 强制清空视角缓存，让 GPU 在下一帧重算网格
        self.state["fov"] = -1
        self.state["lens"] = lens_key

    def set_anchor(self, q_list):
        self.q_anchor = F.normalize(torch.tensor(q_list, device=self.device).float(), dim=0)
        self.state["yaw"] = -999 

    def _update_view_cache(self, fov_deg, dist_ratio, yaw, pitch, roll):
        if (fov_deg == self.state["fov"] and dist_ratio == self.state["dist"] and
            yaw == self.state["yaw"] and pitch == self.state["pitch"] and roll == self.state["roll"] and
            self.rays_w_cache is not None):
            return

        if fov_deg != self.state["fov"] or dist_ratio != self.state["dist"]:
            fov_rad_half = math.radians(fov_deg / 2.0)
            theta_rect = torch.atan(self.r_norm * math.tan(fov_rad_half))
            theta_fish = self.r_norm * fov_rad_half
            theta = dist_ratio * theta_rect + (1.0 - dist_ratio) * theta_fish
            
            rz = torch.cos(theta)
            r_xy = torch.sin(theta)
            rx = r_xy * (self.x_s / self.r_safe)
            ry = r_xy * (self.y_s / self.r_safe)
            self.rays_virtual_low = torch.stack((rx, ry, rz), dim=-1)

        y_r, p_r, r_r = math.radians(yaw), math.radians(pitch), math.radians(roll)
        cy, sy = math.cos(y_r), math.sin(y_r)
        cp, sp = math.cos(p_r), math.sin(p_r)
        cr, sr = math.cos(r_r), math.sin(r_r)
        
        Rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
        Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
        Rz = np.array([[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]])
        R_view = Rz @ Ry @ Rx
        R_view_t = torch.from_numpy(R_view).float().to(self.device)

        rays_view_low = torch.matmul(self.rays_virtual_low, R_view_t.T)
        self.rays_w_cache = self._q_rot(self.q_anchor, rays_view_low)

        self.state.update({"fov": fov_deg, "dist": dist_ratio, "yaw": yaw, "pitch": pitch, "roll": roll})

    @staticmethod
    def _q_inv(q): return q * _Q_CONJ

    @staticmethod
    def _q_rot(q, v):
        a0, a1, a2 = q[..., 1], q[..., 2], q[..., 3]
        b0, b1, b2 = v[..., 0], v[..., 1], v[..., 2]
        c0, c1, c2 = a1 * b2 - a2 * b1, a2 * b0 - a0 * b2, a0 * b1 - a1 * b0
        t0, t1, t2 = c0 * 2, c1 * 2, c2 * 2
        d0, d1, d2 = a1 * t2 - a2 * t1, a2 * t0 - a0 * t2, a0 * t1 - a1 * t0
        w = q[..., 0]
        return torch.stack([b0 + w * t0 + d0, b1 + w * t1 + d1, b2 + w * t2 + d2], dim=-1)

    def _distort(self, rx, ry, rz):
        """GPU 级别物理畸变反解，现在使用动态实例变量"""
        rxy = torch.sqrt(rx**2 + ry**2)
        th = torch.atan2(rxy, rz)
        t2 = th**2; t4 = t2**2; t6 = t4 * t2; t8 = t4**2
        th_p = th * (1 + self.k1 * t2 + self.k2 * t4 + self.k3 * t6 + self.k4 * t8)
        s = torch.where(rxy > 1e-5, th_p / rxy, torch.zeros_like(rxy))
        return rx * s, ry * s

    def _compute_grid_low(self, qt, qc, qb):
        rl = self._q_rot(self._q_inv(qc), self.rays_w_cache)
        _, ya = self._distort(rl[..., 0], rl[..., 1], rl[..., 2])
        y_frac = torch.clamp((self.fy * ya + self.cy) / self.h_in, 0.0, 1.0).unsqueeze(-1)

        qp = F.normalize(qt * (1.0 - y_frac) + qb * y_frac, p=2, dim=-1)

        rl2 = self._q_rot(self._q_inv(qp), self.rays_w_cache)
        xf, yf = self._distort(rl2[..., 0], rl2[..., 1], rl2[..., 2])

        mx = 2.0 * (self.fx * xf + self.cx) / (self.w_in - 1) - 1.0
        my = 2.0 * (self.fy * yf + self.cy) / (self.h_in - 1) - 1.0
        return torch.stack((mx, my), dim=-1).unsqueeze(0)

    @torch.inference_mode()
    def process_frame(self, rgb, q_center, q_top, q_bottom, yaw, pitch, roll, fov_deg, dist_ratio):
        if self.q_anchor is None:
            self.set_anchor(q_center)
            
        self._update_view_cache(fov_deg, dist_ratio, yaw, pitch, roll)

        qc = F.normalize(torch.tensor(q_center, device=self.device).float(), dim=0).view(1, 1, 4)
        qt = F.normalize(torch.tensor(q_top, device=self.device).float(), dim=0).view(1, 1, 4)
        qb = F.normalize(torch.tensor(q_bottom, device=self.device).float(), dim=0).view(1, 1, 4)

        grid_low = self._compute_grid_low(qt, qc, qb)
        grid_low_permuted = grid_low.permute(0, 3, 1, 2)
        grid_high_permuted = F.interpolate(grid_low_permuted, size=(self.h_out, self.w_out), mode="bilinear", align_corners=True)
        grid_high = grid_high_permuted.permute(0, 2, 3, 1)

        return F.grid_sample(rgb, grid_high, mode="bilinear", padding_mode="zeros", align_corners=True)

# ================================================================
# 🤖 YOLO 跟踪线程 (保持不变)
# ================================================================
def yolo_inference_thread():
    model_path = CFG["yolo"]["model_path"]
    inner_cls = CFG["yolo"]["inner_screen_class"]
    conf_thresh = CFG["yolo"]["confidence_threshold"]
    alpha = CFG["tracking"]["alpha"]
    max_speed = CFG["tracking"]["max_edge_speed"]
    ratio = CFG["tracking"]["inner_screen_ratio"]
    pad = CFG["yolo"]["padding"]

    print(f"[YOLO] 正在加载 TensorRT 引擎: {model_path}")
    model = YOLO(model_path, task="detect")
    print("[YOLO] ✅ 引擎加载完成，AI 追踪启动！")

    smooth_x1 = smooth_y1 = smooth_x2 = smooth_y2 = None

    while True:
        try:
            item = frame_queue.get(block=True)
            if item is None: break
            tensor, scale, pad_left, pad_top = item

            results = model(tensor, verbose=False, device="cuda")
            detected = False
            
            if len(results[0].boxes) > 0:
                boxes = results[0].boxes.xyxy
                classes = results[0].boxes.cls
                confidences = results[0].boxes.conf

                for i in range(len(boxes)):
                    if int(classes[i]) == inner_cls and confidences[i] >= conf_thresh:
                        raw_x1, raw_y1, raw_x2, raw_y2 = boxes[i].cpu().numpy()

                        raw_x1 -= pad_left; raw_y1 -= pad_top
                        raw_x2 -= pad_left; raw_y2 -= pad_top
                        raw_x1 /= scale; raw_y1 /= scale
                        raw_x2 /= scale; raw_y2 /= scale
                        raw_x1 -= pad; raw_y1 -= pad
                        raw_x2 -= pad; raw_y2 -= pad

                        if smooth_x1 is None:
                            smooth_x1, smooth_y1 = raw_x1, raw_y1
                            smooth_x2, smooth_y2 = raw_x2, raw_y2
                        else:
                            dx1 = np.clip(raw_x1 - smooth_x1, -max_speed, max_speed)
                            dy1 = np.clip(raw_y1 - smooth_y1, -max_speed, max_speed)
                            dx2 = np.clip(raw_x2 - smooth_x2, -max_speed, max_speed)
                            dy2 = np.clip(raw_y2 - smooth_y2, -max_speed, max_speed)

                            safe_x1, safe_y1 = smooth_x1 + dx1, smooth_y1 + dy1
                            safe_x2, safe_y2 = smooth_x2 + dx2, smooth_y2 + dy2

                            smooth_x1 = alpha * safe_x1 + (1 - alpha) * smooth_x1
                            smooth_y1 = alpha * safe_y1 + (1 - alpha) * smooth_y1
                            smooth_x2 = alpha * safe_x2 + (1 - alpha) * smooth_x2
                            smooth_y2 = alpha * safe_y2 + (1 - alpha) * smooth_y2

                        detected = True
                        break

            if detected:
                cx, cy = (smooth_x1 + smooth_x2) / 2.0, (smooth_y1 + smooth_y2) / 2.0
                w, h = smooth_x2 - smooth_x1, smooth_y2 - smooth_y1
                crop_size = int(max(w, h) / ratio)
                shared_crop.set_crop(cx, cy, crop_size)
            else:
                shared_crop.recenter_step()

        except Exception as e:
            print(f"\n[YOLO Thread Error] {e}")
            time.sleep(0.1)

def _qmul(a, b):
    return [
        a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3],
        a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2],
        a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1],
        a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0],
    ]

_DEV_TO_CAM = [0.0, 1.0, 0.0, 0.0]
_DEV_TO_CAM_INV = [0.0, -1.0, 0.0, 0.0]

def align_imu(q):
    q_cam = _qmul(_qmul(_DEV_TO_CAM, q), _DEV_TO_CAM_INV)
    norm = math.sqrt(sum(c * c for c in q_cam))
    return [c / norm for c in q_cam]

def nothing(x): pass

def init_trackbars(window_name, default_fov):
    cv2.createTrackbar('Stab', window_name, 1, 1, nothing)
    cv2.createTrackbar('Track', window_name, 1, 1, nothing)
    cv2.createTrackbar('Yaw', window_name, 90, 180, nothing)     
    cv2.createTrackbar('Pitch', window_name, 90, 180, nothing)   
    cv2.createTrackbar('Roll', window_name, 90, 180, nothing)    
    cv2.createTrackbar('FOV', window_name, default_fov, 160, nothing)    
    cv2.createTrackbar('Distort', window_name, 100, 100, nothing) 

# ================================================================
# 🎮 主渲染循环 — 动态双镜头管理
# ================================================================
def main():
    host = CFG["network"]["host"]
    port = CFG["network"]["port"]
    reconnect_delay = CFG["network"]["reconnect_delay"]

    stab = ZeroCopyStabilizer(_NV12_H, _NV12_W, _STAB_H, _STAB_W, grid_ds=CFG["stabilizer"]["grid_ds"])
    
    # 默认启动主摄模式
    active_lens_key = "main"
    stab.load_lens(active_lens_key)

    yolo_t = threading.Thread(target=yolo_inference_thread, daemon=True)
    yolo_t.start()

    VIDEO_WINDOW = "Live Maimai Stream"
    CONTROL_WINDOW = "Live Control Panel"
    
    cv2.namedWindow(VIDEO_WINDOW, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(VIDEO_WINDOW, _OUT_SIZE, _OUT_SIZE)
    cv2.namedWindow(CONTROL_WINDOW, cv2.WINDOW_AUTOSIZE)
    init_trackbars(CONTROL_WINDOW, CFG["cameras"][active_lens_key]["default_fov"])

    n_cnt = g_cnt = 0
    n_t = g_t = time.perf_counter()
    n_fps = g_fps = 0.0

    while True:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        try:
            sock.connect((host, port))
            print(f"[TCP] ✅ 已连接 {host}:{port}")
        except OSError as e:
            print(f"[TCP] ❌ 网络错误: {e}，{reconnect_delay}s 后重试...")
            time.sleep(reconnect_delay)
            continue

        stab.q_anchor = None

        try:
            while True:
                hdr = recv_exact(sock, HEADER_SIZE)
                fields = PACK_HEADER.unpack(hdr)
                if fields[0] != b"SYNC": continue

                yaw = cv2.getTrackbarPos('Yaw', CONTROL_WINDOW) - 90
                pitch = cv2.getTrackbarPos('Pitch', CONTROL_WINDOW) - 90
                roll = cv2.getTrackbarPos('Roll', CONTROL_WINDOW) - 90
                fov = max(10, cv2.getTrackbarPos('FOV', CONTROL_WINDOW))
                dist_ratio = cv2.getTrackbarPos('Distort', CONTROL_WINDOW) / 100.0

                n_cnt += 1
                now = time.perf_counter()
                if now - n_t >= 1.0:
                    n_fps = n_cnt / (now - n_t)
                    n_cnt = 0; n_t = now

                raw_w, raw_x, raw_y, raw_z = fields[6:10]
                print(f"\U0001f9ed IMU [W,X,Y,Z] -> W: {raw_w:+.3f} | X: {raw_x:+.3f} | Y: {raw_y:+.3f} | Z: {raw_z:+.3f}")

                q_top = align_imu(fields[2:6])
                q_center = align_imu(fields[6:10])
                q_bottom = align_imu(fields[10:14])
                nv12_size = fields[14]
                nv12_raw = recv_exact(sock, nv12_size)

                rgb = nv12_to_rgb_cuda(nv12_raw)

                stab_on = cv2.getTrackbarPos('Stab', CONTROL_WINDOW) == 1
                track_on = stab_on and cv2.getTrackbarPos('Track', CONTROL_WINDOW) == 1

                if stab_on:
                    out = stab.process_frame(rgb, q_center, q_top, q_bottom, yaw, pitch, roll, fov, dist_ratio)
                else:
                    out = rgb

                if track_on and frame_queue.empty():
                    pad = CFG["yolo"]["padding"]
                    padded = F.pad(out, (pad, pad, pad, pad), value=0.0)
                    _, _, ph, pw = padded.shape
                    scale = min(_YOLO_IN / pw, _YOLO_IN / ph)
                    new_w = int(pw * scale)
                    new_h = int(ph * scale)
                    resized = F.interpolate(padded, size=(new_h, new_w), mode="bilinear", align_corners=False)
                    pad_left = (_YOLO_IN - new_w) // 2
                    pad_top = (_YOLO_IN - new_h) // 2
                    pad_right = _YOLO_IN - new_w - pad_left
                    pad_bottom = _YOLO_IN - new_h - pad_top
                    yolo_input = F.pad(resized, (pad_left, pad_right, pad_top, pad_bottom), value=0.0)
                    frame_queue.put((yolo_input, scale, pad_left, pad_top))

                if stab_on:
                    if track_on:
                        cx, cy, crop_size = shared_crop.get_ideal_params()
                    else:
                        cx, cy, crop_size = _STAB_W / 2.0, _STAB_H / 2.0, float(min(_STAB_W, _STAB_H))

                    half = crop_size / 2.0
                    x1_valid = int(max(0, cx - half))
                    y1_valid = int(max(0, cy - half))
                    x2_valid = int(min(_STAB_W, cx + half))
                    y2_valid = int(min(_STAB_H, cy + half))

                    if x2_valid > x1_valid and y2_valid > y1_valid:
                        cropped = out[:, :, y1_valid:y2_valid, x1_valid:x2_valid]
                    else:
                        cropped = out

                    pad_left = int(x1_valid - (cx - half))
                    pad_top = int(y1_valid - (cy - half))
                    pad_right = int((cx + half) - x2_valid)
                    pad_bottom = int((cy + half) - y2_valid)

                    if pad_left > 0 or pad_right > 0 or pad_top > 0 or pad_bottom > 0:
                        cropped = F.pad(cropped, (pad_left, pad_right, pad_top, pad_bottom), value=0.0)

                    out_final = F.interpolate(cropped, size=(_OUT_SIZE, _OUT_SIZE), mode="bilinear", align_corners=False)
                else:
                    _, _, raw_h, raw_w = out.shape
                    side = min(raw_h, raw_w)
                    y_off = (raw_h - side) // 2
                    x_off = (raw_w - side) // 2
                    cropped = out[:, :, y_off:y_off+side, x_off:x_off+side]
                    out_final = F.interpolate(cropped, size=(_OUT_SIZE, _OUT_SIZE), mode="bilinear", align_corners=False)
                    pad_left = pad_right = pad_top = pad_bottom = cx = cy = crop_size = 0

                out_uint8 = (out_final.squeeze(0) * 255.0).clamp(0, 255).byte()
                out_bgr = out_uint8.flip(0).permute(1, 2, 0)
                preview = out_bgr.cpu().numpy()

                g_cnt += 1
                now = time.perf_counter()
                if now - g_t >= 1.0:
                    g_fps = g_cnt / (now - g_t)
                    g_cnt = 0; g_t = now

                # ======= 控制面板 UI =======
                control_panel = np.zeros((280, 500, 3), dtype=np.uint8)
                lens_name = CFG["cameras"][active_lens_key]["name"]
                
                cv2.putText(control_panel, f"Net: {n_fps:.1f} FPS | GPU: {g_fps:.1f} FPS", (20, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
                # 提示用户热切换快捷键
                cv2.putText(control_panel, f"Lens: {lens_name}", (20, 70), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 255), 2)
                cv2.putText(control_panel, "[Press 'S' to Hot-Swap Lens]", (20, 100), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (100, 100, 255), 1)
                
                cv2.putText(control_panel, f"Stab: {'ON' if stab_on else 'OFF'}  Track: {'ON' if track_on else 'OFF'}", (20, 140), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255) if stab_on else (100, 100, 100), 2)
                cv2.putText(control_panel, f"Y:{yaw} P:{pitch} R:{roll}", (20, 180), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 165, 255), 2)
                cv2.putText(control_panel, f"FOV:{fov} Dist:{dist_ratio:.2f}", (20, 220), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 165, 255), 2)
                cv2.putText(control_panel, f"Crop: ({cx:.0f},{cy:.0f}) size={crop_size:.0f}", (20, 260), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1)
                
                cv2.imshow(CONTROL_WINDOW, control_panel)
                cv2.imshow(VIDEO_WINDOW, preview)

                # ================= 监听键盘指令 =================
                key = cv2.waitKey(1) & 0xFF
                if key == ord("q"):
                    frame_queue.put(None)
                    sock.close()
                    cv2.destroyAllWindows()
                    return
                elif key == ord("s"):
                    # 🔄 触发热切换逻辑
                    active_lens_key = "uw" if active_lens_key == "main" else "main"
                    print(f"\n[Lens Swap] 切换至镜头: {CFG['cameras'][active_lens_key]['name']}")
                    
                    # 1. 向 GPU 引擎热注入新矩阵
                    stab.load_lens(active_lens_key)
                    # 2. 自动把 FOV 滑块重置到该镜头最舒服的视野大小，防止画面突变
                    cv2.setTrackbarPos('FOV', CONTROL_WINDOW, CFG["cameras"][active_lens_key]["default_fov"])

        except (ConnectionError, OSError) as e:
            print(f"\n[TCP] ⚠️ 连接断开: {e}，{reconnect_delay}s 后重连...")
        except KeyboardInterrupt:
            print("\n[Main] 用户中断")
            frame_queue.put(None)
            sock.close()
            cv2.destroyAllWindows()
            return
        finally:
            try: sock.close()
            except Exception: pass

        time.sleep(reconnect_delay)

if __name__ == "__main__":
    main()