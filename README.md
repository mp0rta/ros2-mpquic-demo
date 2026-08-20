# ros2-mpquic-demo

**A ROS 2 camera stream that survives a network-path failure — live, in your
browser, with measured QoE.**

One QUIC connection, two network paths. Pull the primary path mid-stream and
the video stutters for well under a second instead of blacking out for the
whole outage:

![side-by-side failover comparison](docs/demo.gif)

(two `./demo.sh` runs, captured from the live browser stream and aligned at
the failure instant — that is why the two wall clocks differ)

|                       | Multipath QUIC | single path (baseline) |
|-----------------------|---------------:|-----------------------:|
| worst video freeze    |     **401 ms** |           **10710 ms** |
| frames lost           |    **0 / 675** |             213 / 670  |
| path-failure detection|         ~0.3 s |     n/a (session died) |
| QUIC connections used |  1 (no reconnect) | reconnect after recovery |

(the same two runs the GIF shows; 20 fps synthetic camera, 10 s primary-path
outage injected mid-stream, Linux netns + netem topology. Every run writes
its raw logs and a per-frame CSV to `./logs/<mode>/`, so when you run the
demo yourself you can recompute every number in this table from your own
data)

```
camera_sim --CycloneDDS-- zenoh-bridge-ros2dds ==MPQUIC (2 paths)== zenoh-bridge-ros2dds --CycloneDDS-- qoe_monitor --> your browser
  (netns zc, ROS domain 0)                                             (netns zs, ROS domain 1)          http://localhost:8480
```

The transport is [Zenoh](https://github.com/eclipse-zenoh/zenoh) with an
experimental QUIC backend based on [noq](https://github.com/n0-computer/noq)
(Quinn fork implementing
[draft-ietf-quic-multipath](https://datatracker.ietf.org/doc/draft-ietf-quic-multipath/)),
one UDP socket per NIC (`SO_BINDTODEVICE`), and out-of-band interface
monitoring (netlink) for ~300 ms failure detection. ROS 2 and
`zenoh-bridge-ros2dds` are unmodified (the bridge is only rebuilt against the
fork).

## What you see

- A synthetic camera (wall clock + frame counter + bouncing ball) streamed as
  a ROS 2 `CompressedImage` topic across the bridge, viewable live in a
  browser (MJPEG).
- Mid-stream, the primary network interface is taken down. With multipath the
  ball stutters for a beat (0.3–0.7 s across our runs) and keeps bouncing;
  the baseline freezes for the whole outage and drops every frame in it.
- A QoE summary (frame loss, latency percentiles, freeze durations, per-frame
  CSV) and the path-event log (detection latency, no-reconnect proof) are
  printed automatically.

## Running it

Prerequisites: Linux, Docker, Rust and `openssl`. The multipath forks
(zenoh @ `feat/noq-mpquic-poc`, noq @ `feat/mpquic-poc`,
zenoh-plugin-ros2dds @ `feat/mpquic-demo`) are bundled as git submodules,
so one recursive clone brings everything needed:

```bash
git clone --recursive https://github.com/mp0rta/ros2-mpquic-demo.git
cd ros2-mpquic-demo

# 1. build the bridge against the bundled forks (once)
( cd zenoh-plugin-ros2dds && cargo build -p zenoh-bridge-ros2dds )

# 2. build the demo image (once)
docker build -t mpquic-demo:local .

# 3. run — then open http://localhost:8480 and watch
./demo.sh              # multipath: the stream survives the outage
./demo.sh --single     # baseline: the stream blacks out
```

Cloned without `--recursive`? Run `git submodule update --init` first.
(For fork development, `demo.sh` also accepts the three forks checked out
as siblings of this repo instead of the submodules.)

`STEADY_SECS` extends the watch time before the failure is injected;
`VIEW_PORT` changes the browser port. Everything runs inside one privileged
container (network namespaces + veth + netem); nothing touches your host
network beyond the browser port on localhost. Logs and the per-frame CSV
land in `./logs/<mode>/`.

The bridge binary is built on the host and runs inside the container
(Ubuntu 24.04 base) — if your host's glibc is newer than the container's,
build the bridge inside a matching container instead.

## Honesty notes

- The QoE advantage shown here is **continuity/availability**: seamless
  failover of one logical connection. Bandwidth **aggregation** across paths
  (e.g. `/camera` steering in mixed workloads) needs a multipath scheduler,
  which is future work in the underlying stack (today noq sends on the
  lowest available path).
- The baseline is genuinely handicapped by having one NIC; that is the point
  of the comparison — multipath turns standby hardware into instant failover
  without any application change.
- Frame-loss figures depend on QoS: the demo uses best-effort sensor QoS.
  During the multipath failover every frame was still delivered — the
  surviving path retransmits the in-flight data as soon as the failure is
  detected, so the sub-second stall never overflows the best-effort queue —
  while the baseline's 10 s outage dropped everything sent in it.
- The multipath worst freeze varies mildly run to run (0.3–0.7 s observed
  across repeated runs on one machine); detection (~0.3 s) and the
  baseline's ~10.7 s blackout were stable. The freeze is dominated by
  failure detection: netlink-based interface monitoring plus a 250 ms
  debounce, then immediate retransmission on the surviving path.
- The detection figure is measured by polling the bridge log every 50 ms,
  so it is an upper bound with ~0.1 s of quantization — hence "~0.3 s".

## License

[Apache-2.0](LICENSE)

## Repository layout

- `ros/camera_sim.py` — synthetic camera (frame id in `header.frame_id`,
  send time in `header.stamp`, both drawn into the picture)
- `ros/qoe_monitor.py` — QoE measurement + MJPEG server for the browser
- `configs/` — zenoh bridge configs (multipath + single-path baseline)
- `netns.sh`, `gen-certs.sh`, `Dockerfile`, `demo.sh`
- `zenoh/`, `noq/`, `zenoh-plugin-ros2dds/` — the multipath transport forks
  (git submodules pinned to the tested commits)
