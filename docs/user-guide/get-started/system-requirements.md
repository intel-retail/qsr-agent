# System Requirements

## Hardware

| Component | Requirement |
|---|---|
| Processor | Intel® Core™ Ultra, Intel® Core™, or Intel® Xeon® processor (x86-64) |
| GPU | Intel® GPU (integrated or Intel® Arc™ discrete) exposed at `/dev/dri/renderD*` |
| GPU memory | Enough to hold the INT4 model (about 5 GB for the default Qwen3-8B, about 16 GB for Qwen3-30B-A3B) plus a 4 GB KV cache |
| Disk | About 30 GB free: up to 16 GB for the model, the rest for container images and data |

## Software

| Component | Requirement |
|---|---|
| Operating system | Linux x86-64 with Intel GPU drivers installed |
| Docker | Docker Engine with the Compose v2 plugin, usable by the current user without `sudo` |
| Tools | Git, `make`, `curl`, Python 3 (used by the model download script) |
| Network | Access to GitHub, Docker Hub, and Hugging Face during installation |

## Verify the System

Confirm the Intel GPU device is visible:

```bash
ls /dev/dri/renderD*
```

Confirm Docker works for your user:

```bash
docker run --rm hello-world
docker compose version
```

If Docker requires `sudo`, add your user to the `docker` group, then log out and
back in:

```bash
sudo usermod -aG docker "$USER"
```

## Network Ports

| Port | Service | Default binding |
|---|---|---|
| 8600 | Operator UI and event webhook | All interfaces (`0.0.0.0`) |
| 4444 | OpenVINO™ Model Server API | Loopback only |
| 8090 | Weather service | Loopback only |

Change ports and bindings in [Configuration](configuration.md).

---

[Back to Get Started](../get-started.md)
