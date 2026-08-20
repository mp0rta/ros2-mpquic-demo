# Runtime image for the demo: ROS 2 + CycloneDDS RMW + OpenCV for the
# synthetic camera / QoE monitor, plus network tooling for the netns
# topology and the MJPEG port forward.
FROM ros:jazzy-ros-base
RUN apt-get update && apt-get install -y --no-install-recommends \
    ros-jazzy-rmw-cyclonedds-cpp \
    python3-opencv \
    iproute2 \
    iputils-ping \
    socat \
    && rm -rf /var/lib/apt/lists/*
ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
