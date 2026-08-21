#!/usr/bin/env python3
"""QoE monitor for the MPQUIC demo.

Subscribes to the camera stream, measures per-frame QoE (arrival gaps =
freezes, frame loss from the frame_id sequence, one-way latency from
header.stamp — valid here because both ends share the host clock), serves
the live picture as MJPEG over HTTP for a browser, and writes a CSV +
summary on shutdown.

Loss accounting assumes frame ids arrive in increasing order (holds here:
one publisher, one ordered transport) and cannot see frames sent after the
last one received — the demo script stops the camera before the monitor so
no tail loss is hidden.

Usage: qoe_monitor.py [--csv PATH] [--port 8080]
"""
import argparse
import signal
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSPresetProfiles
from sensor_msgs.msg import CompressedImage

FREEZE_THRESHOLD_S = 0.5  # arrival gap counted as a visible freeze


class QoeMonitor(Node):
    def __init__(self, csv_path):
        super().__init__("qoe_monitor")
        self.csv = open(csv_path, "w") if csv_path else None
        if self.csv:
            self.csv.write("frame,arrival_unix,latency_ms,gap_ms\n")
        self.lock = threading.Lock()
        self.latest_jpeg = None
        self.first_frame = None
        self.last_frame = None
        self.received = 0
        self.lost = 0
        self.max_gap_ms = 0.0
        self.freezes = []  # (frame_before, gap_ms)
        self.last_arrival = None
        self.latencies = []
        self.sub = self.create_subscription(
            CompressedImage, "/camera/image/compressed", self.on_frame,
            QoSPresetProfiles.SENSOR_DATA.value,
        )

    def on_frame(self, msg):
        now = time.time()
        mono = time.monotonic()  # gaps must survive wall-clock steps (NTP)
        frame = int(msg.header.frame_id)
        sent = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
        latency_ms = (now - sent) * 1000.0
        gap_ms = (mono - self.last_arrival) * 1000.0 if self.last_arrival else 0.0
        with self.lock:
            self.latest_jpeg = bytes(msg.data)
            if self.first_frame is None:
                self.first_frame = frame
                self.get_logger().info(f"first frame {frame} received")
            if self.last_frame is not None and frame > self.last_frame + 1:
                self.lost += frame - self.last_frame - 1
            self.last_frame = frame
            self.received += 1
            self.latencies.append(latency_ms)
            if gap_ms > self.max_gap_ms:
                self.max_gap_ms = gap_ms
            if gap_ms > FREEZE_THRESHOLD_S * 1000.0:
                self.freezes.append((frame, gap_ms))
                self.get_logger().warn(f"freeze: {gap_ms:.0f} ms before frame {frame}")
        if self.csv:
            self.csv.write(f"{frame},{now:.3f},{latency_ms:.1f},{gap_ms:.1f}\n")
            self.csv.flush()
        self.last_arrival = mono

    def summary(self):
        with self.lock:
            expected = (self.last_frame - self.first_frame + 1) if self.received else 0
            lat = sorted(self.latencies)
            p50 = lat[len(lat) // 2] if lat else 0.0
            p99 = lat[int(len(lat) * 0.99)] if lat else 0.0
            lines = [
                "----------------------------------------------",
                " QoE summary (/camera/image/compressed)",
                "----------------------------------------------",
                f" frames received : {self.received} / {expected} expected"
                f" ({self.lost} lost)" if self.received else " frames received : 0",
                f" latency p50/p99 : {p50:.1f} / {p99:.1f} ms",
                f" worst freeze    : {self.max_gap_ms:.0f} ms",
                f" freezes >{int(FREEZE_THRESHOLD_S * 1000)}ms  : "
                + (", ".join(f"{g:.0f}ms@frame{f}" for f, g in self.freezes) or "none"),
                "----------------------------------------------",
            ]
        return "\n".join(lines)


class MjpegHandler(BaseHTTPRequestHandler):
    monitor = None

    def do_GET(self):
        if self.path not in ("/", "/stream"):
            self.send_error(404)
            return
        if self.path == "/":
            body = (b"<html><body style='background:#111;text-align:center'>"
                    b"<h2 style='color:#eee;font-family:sans-serif'>"
                    b"ROS 2 camera over Multipath QUIC</h2>"
                    b"<img src='/stream' style='max-width:95%'/></body></html>")
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.end_headers()
        try:
            while True:
                with self.monitor.lock:
                    jpg = self.monitor.latest_jpeg
                if jpg:
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\n"
                                     + f"Content-Length: {len(jpg)}\r\n\r\n".encode()
                                     + jpg + b"\r\n")
                time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default=None)
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()

    rclpy.init()
    node = QoeMonitor(args.csv)
    MjpegHandler.monitor = node
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    httpd = socketserver.ThreadingTCPServer(("0.0.0.0", args.port), MjpegHandler)
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    node.get_logger().info(f"MJPEG viewer on http://localhost:{args.port}/")

    # A plain flag + spin_once loop: overriding SIGTERM with an exception-
    # raising handler would replace rclpy's C-level handler and leave nobody
    # to wake the blocking rcl_wait, hanging the process instead of exiting.
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    try:
        while rclpy.ok() and not stop.is_set():
            rclpy.spin_once(node, timeout_sec=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        print(node.summary(), flush=True)
        sys.stdout.flush()


if __name__ == "__main__":
    main()
