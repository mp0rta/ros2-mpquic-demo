#!/usr/bin/env python3
"""Synthetic camera for the MPQUIC demo.

Publishes sensor_msgs/CompressedImage (JPEG) with a wall clock, a frame
counter and a bouncing ball drawn into the picture, so a viewer can SEE the
stream freeze and resume, and the receiver can MEASURE loss/latency exactly:
the frame number rides in header.frame_id and the send time in header.stamp.
"""
import math
import time

import cv2
import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSPresetProfiles
from sensor_msgs.msg import CompressedImage

WIDTH, HEIGHT, FPS = 640, 480, 20
JPEG_QUALITY = 70


class CameraSim(Node):
    def __init__(self):
        super().__init__("camera_sim")
        self.pub = self.create_publisher(
            CompressedImage, "/camera/image/compressed",
            QoSPresetProfiles.SENSOR_DATA.value,
        )
        self.frame = 0
        self.timer = self.create_timer(1.0 / FPS, self.tick)
        self.get_logger().info(f"publishing {WIDTH}x{HEIGHT}@{FPS}fps JPEG q{JPEG_QUALITY}")

    def tick(self):
        img = np.full((HEIGHT, WIDTH, 3), (40, 32, 24), np.uint8)
        t = time.time()
        # bouncing ball: freezes visibly when the stream stalls
        x = int((WIDTH - 80) / 2 * (1 + math.sin(t * 2.0))) + 40
        y = int((HEIGHT - 160) / 2 * (1 + math.sin(t * 2.7))) + 80
        cv2.circle(img, (x, y), 28, (60, 190, 255), -1)
        clock = time.strftime("%H:%M:%S", time.localtime(t)) + f".{int(t * 1000) % 1000:03d}"
        cv2.putText(img, clock, (20, 60), cv2.FONT_HERSHEY_SIMPLEX, 1.6, (255, 255, 255), 3)
        cv2.putText(img, f"frame {self.frame}", (20, HEIGHT - 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 1.0, (180, 255, 180), 2)
        cv2.putText(img, "ROS 2 over Multipath QUIC", (20, 110),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (160, 160, 160), 2)
        ok, jpg = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY])
        if not ok:
            return
        msg = CompressedImage()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = str(self.frame)  # machine-readable sequence number
        msg.format = "jpeg"
        msg.data = jpg.tobytes()
        self.pub.publish(msg)
        self.frame += 1


def main():
    rclpy.init()
    node = CameraSim()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
