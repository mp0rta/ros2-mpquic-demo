#!/usr/bin/env bash
# One-command demo: a ROS 2 camera stream that survives a network-path
# failure over one Multipath QUIC connection — watch it live in a browser
# and get an automatic QoE summary.
#
#   camera_sim --CycloneDDS-- bridge ==MPQUIC(2 paths)== bridge --CycloneDDS-- qoe_monitor --> browser
#     (netns zc, domain 0)                                  (netns zs, domain 1)     http://localhost:8080
#
# Usage:
#   ./demo.sh            # multipath: failover mid-stream, ~0.3s freeze, no session loss
#   ./demo.sh --single   # baseline: same failure without multipath (blackout + reconnect)
# Env: STEADY_SECS (default 15) time to watch before the failure is injected;
#      VIEW_PORT (default 8480) host port for the browser stream.
#
# Requires: docker, the image (docker build -t mpquic-demo:local .), and the
# sibling fork checkouts with a debug bridge binary
# (../zenoh-plugin-ros2dds/target/debug/zenoh-bridge-ros2dds, branch feat/mpquic-demo).
set -euo pipefail
cd "$(dirname "$0")"
WS="$(cd .. && pwd)"

MODE=multipath
[ "${1:-}" = "--single" ] && MODE=single

BRIDGE=zenoh-plugin-ros2dds/target/debug/zenoh-bridge-ros2dds
[ -f "$WS/$BRIDGE" ] || { echo "bridge binary not found: $WS/$BRIDGE (build it on branch feat/mpquic-demo)" >&2; exit 1; }
[ -f certs/server.pem ] || ./gen-certs.sh
mkdir -p logs

IMAGE="${MPQUIC_DEMO_IMAGE:-mpquic-demo:local}"

VIEW_PORT="${VIEW_PORT:-8480}"
docker run --rm --privileged -p "$VIEW_PORT":8080 -v "$WS":/ws -w /ws/ros2-mpquic-demo "$IMAGE" \
  env MODE="$MODE" STEADY_SECS="${STEADY_SECS:-15}" VIEW_PORT="$VIEW_PORT" bash -c '
set -euo pipefail
LOG=logs
say() { printf "\n\033[1m== %s ==\033[0m\n" "$*"; }
now_ms() { date -u +%s%3N; }

# DDS pinned to loopback (failing c0 must not break the local DDS hop);
# split domains so DDS cannot bypass the bridge.
export CYCLONEDDS_URI="<CycloneDDS><Domain><General><Interfaces><NetworkInterface name=\"lo\"/></Interfaces><AllowMulticast>false</AllowMulticast></General><Discovery><ParticipantIndex>auto</ParticipantIndex><Peers><Peer address=\"127.0.0.1\"/></Peers></Discovery></Domain></CycloneDDS>"

if [ "$MODE" = single ]; then
  CAM_CFG=configs/bridge-camera-single.json5
  MON_CFG=configs/bridge-monitor-single.json5
else
  CAM_CFG=configs/bridge-camera.json5
  MON_CFG=configs/bridge-monitor.json5
fi

say "1/6 building the 2-path netns topology ($MODE mode)"
./netns.sh up
./netns.sh netem

say "2/6 starting the monitoring side (netns zs: bridge + QoE monitor + browser stream)"
ip netns exec zs env CYCLONEDDS_URI="$CYCLONEDDS_URI" RUST_LOG=zenoh_link_commons=debug,zenoh=info \
  /ws/zenoh-plugin-ros2dds/target/debug/zenoh-bridge-ros2dds -c $MON_CFG -d 1 > $LOG/bridge-monitor.log 2>&1 &
sleep 3
ip netns exec zs env CYCLONEDDS_URI="$CYCLONEDDS_URI" ROS_DOMAIN_ID=1 bash -c \
  "source /opt/ros/jazzy/setup.bash && exec python3 ros/qoe_monitor.py --csv $LOG/qoe.csv --port 8080" \
  > $LOG/qoe.log 2>&1 &
# expose the in-namespace MJPEG server on the container (and thus the host)
socat TCP-LISTEN:8080,fork,reuseaddr EXEC:"ip netns exec zs socat STDIO TCP\:127.0.0.1\:8080" &

say "3/6 starting the camera side (netns zc: bridge + synthetic camera)"
ip netns exec zc env CYCLONEDDS_URI="$CYCLONEDDS_URI" RUST_LOG=zenoh_link_commons=debug,zenoh=info \
  /ws/zenoh-plugin-ros2dds/target/debug/zenoh-bridge-ros2dds -c $CAM_CFG -d 0 > $LOG/bridge-camera.log 2>&1 &
sleep 3
ip netns exec zc env CYCLONEDDS_URI="$CYCLONEDDS_URI" ROS_DOMAIN_ID=0 bash -c \
  "source /opt/ros/jazzy/setup.bash && exec python3 ros/camera_sim.py" > $LOG/camera.log 2>&1 &

say "4/6 waiting for the stream to flow end-to-end"
for i in $(seq 1 30); do
  grep -q "first frame" $LOG/qoe.log 2>/dev/null && break
  sleep 1
done
grep -q "first frame" $LOG/qoe.log || {
  echo "FAIL: monitor never received a frame"
  for f in $LOG/*.log; do echo "--- $f"; tail -n 5 "$f"; done
  exit 1
}
if [ "$MODE" = multipath ]; then
  grep -m1 "state=validated" $LOG/bridge-camera.log >/dev/null || { echo "FAIL: second path not validated"; exit 1; }
  echo "stream flowing over 2 paths on one QUIC connection"
else
  echo "stream flowing over a single path"
fi
echo ""
echo ">>> WATCH IT LIVE: http://localhost:${VIEW_PORT}  (streaming for ${STEADY_SECS}s before the failure)"
sleep "$STEADY_SECS"

say "5/6 failing the primary path (c0 down) while streaming"
OFFSET=$(wc -c < $LOG/bridge-camera.log)
T_FAIL=$(now_ms)
ip -n zc link set c0 down
DETECT_MS=""
if [ "$MODE" = multipath ]; then
  for i in $(seq 1 100); do
    if tail -c +$((OFFSET + 1)) $LOG/bridge-camera.log | grep -q "state=failed"; then
      DETECT_MS=$(( $(now_ms) - T_FAIL )); break
    fi
    sleep 0.05
  done
fi
sleep 10
ip -n zc link set c0 up
sleep 8   # single mode: give the reconnect a chance after recovery

say "6/6 teardown and summary"
kill %5 2>/dev/null || true         # camera
sleep 0.5
kill %2 2>/dev/null || true         # qoe monitor (SIGTERM -> prints QoE summary)
sleep 2
kill %4 %3 %1 2>/dev/null || true   # bridges + socat
grep -A99 "QoE summary" $LOG/qoe.log || { echo "FAIL: no QoE summary produced"; exit 1; }

echo ""
if [ "$MODE" = multipath ]; then
  FAIL_REASON=$(tail -c +$((OFFSET + 1)) $LOG/bridge-camera.log | grep -m1 "state=failed" | sed "s/\x1b\[[0-9;]*m//g" | grep -oE "reason=[A-Za-z]+" || true)
  RECONNECTS=$(grep -c "state=active (primary)" $LOG/bridge-camera.log || true)
  echo " path failure detection : ${DETECT_MS:-NOT DETECTED} ms (${FAIL_REASON:-n/a})"
  echo " QUIC connections used  : $RECONNECTS (1 = no reconnect)"
  [ -n "$DETECT_MS" ] || { echo "FAIL: path failure was never detected"; exit 1; }
  [ "$RECONNECTS" = "1" ] || { echo "FAIL: session reconnected"; exit 1; }
  # the stream must have kept flowing: the worst freeze must be well below
  # the 10s outage window a single-path session would suffer
  WORST=$(grep -oE "worst freeze *: *[0-9]+" $LOG/qoe.log | grep -oE "[0-9]+$" || echo 999999)
  [ "$WORST" -lt 5000 ] || { echo "FAIL: stream stalled for ${WORST}ms (no failover?)"; exit 1; }
else
  echo " (baseline: compare this QoE summary with the multipath run)"
fi
'
echo ""
echo "logs in ./logs/ (bridge-camera, bridge-monitor, camera, qoe + qoe.csv)"
