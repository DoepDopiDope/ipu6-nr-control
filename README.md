# ipu6-nr-control

`ipu6-nr-control` provides the `cameranoise` command, which controls manual noise-reduction strength through the Intel IPU6 camera HAL on the Dell Precision 5690 with the OV02E10 sensor.

It fixes excessive motion trails caused by temporal noise reduction while preserving Intel's original graph XML and proprietary `OV02E10_ASG202N3_MTL.aiqb` tuning profile. The camera relay remains 1920x1080 NV12 at 30 fps.

## Tested environment

This module has only been tested on the following machine and software stack:

- Dell Precision 5690 with the integrated OV02E10 sensor and Intel IPU6
- Ubuntu 24.04.4 LTS (`amd64`)
- Linux kernel `6.17.0-22-generic`
- `gstreamer1.0-icamera` `0~git202509260937.4fb31db~ubuntu24.04.9`
- `libcamhal-ipu6epmtl` `0~git202601200757.9899efa~ubuntu24.04.3`
- `v4l2-relayd` `0.1.2-0ubuntu3.1`

Other Ubuntu releases, kernels, camera modules, and IPU6 package versions are untested. The kernel version matters because the OV02E10 sensor driver and IPU6 media stack are kernel-coupled. The shim also relies on the C++ ABI exported by the installed `libcamhal.so.0`. Rebuild and rerun `make test` after a kernel or camera-stack upgrade before relying on the module.

## Supported input range

Every multiple of 10 from `-100` through `100` is accepted and passed to `Parameters::setNrLevel()`:

```text
-100, -90, -80, ... -20, -10, 0, 10, 20, ... 80, 90, 100
```

Known results on this laptop:

| Strength | Result |
|---:|---|
| `-100` | Tested: no ghosting; most visible grain |
| `-60` | Tested: works well; less grain than `-100` |

The installed HAL has an important upper-limit behavior: its processing code clips effective NR strength to `+20` after applying tuning adjustments. The CLI still accepts and passes `30` through `100` exactly as requested, but those settings may behave identically to `20` on this machine. Values outside `-100…100`, and values not divisible by 10, are rejected.

## Install

No package installation is performed. The installer uses the existing `g++`, `libcamhal.so.0`, `icamerasrc`, `v4l2-relayd`, and systemd installation.

Close Cheese, browsers, meeting applications, and anything else using the camera. Then run from this directory:

```bash
./install.sh -60
```

The installer requests sudo, builds the shim, installs the `cameranoise` command, preserves the original relay configuration under `/var/lib/cameranoise`, and restarts `v4l2-relayd@default.service`. Use any supported 10-point strength as the initial setting; the default is `-60`.

## Use

Close camera applications before switching levels, then run:

```bash
cameranoise -100
cameranoise -90
cameranoise -60
cameranoise 0
cameranoise 20
cameranoise 100
```

The command requests sudo when a setting change requires it. Read-only commands do not:

```bash
cameranoise status
cameranoise levels
cameranoise --help
```

## How it works

The installed `icamerasrc` plugin does not expose `Parameters::setNrLevel()` as a GStreamer property. The service-scoped library in this project intercepts the otherwise-unused `Parameters::setWdrLevel()` call and translates `CAMERANOISE_STRENGTH` into a `camera_nr_level_t` passed to the HAL.

The installer adds `wdr-level=0` to the relay's `VIDEOSRC` line so the setter is called, then loads the shim only into `v4l2-relayd` through a systemd drop-in. The shim places the requested value in the overall, spatial, and temporal fields. This installed HAL's processing code uses only the overall field.

Installed files:

- `/usr/local/bin/cameranoise`
- `/usr/local/lib/cameranoise/libcameranoise.so`
- `/etc/default/cameranoise`
- `/etc/systemd/system/v4l2-relayd@default.service.d/30-cameranoise.conf`
- `/var/lib/cameranoise/default.conf.before-install`

## Test

```bash
make test
```

The test builds the shim, checks its dynamic dependency and immediate symbol binding, validates the shell scripts, and exercises all 21 supported inputs through `icamerasrc` without opening a camera stream.

## Uninstall

Close all camera applications, then run:

```bash
./uninstall.sh
```

The uninstaller removes the module's installed files and restores the relay configuration saved at installation. It refuses to overwrite a relay configuration changed afterward unless explicitly run with `--force`.

## License

This project is licensed under the [MIT License](LICENSE).

## Troubleshooting

After changing a level, open Cheese and compare motion trails, grain, and detail. Confirm configuration and relay state with:

```bash
cameranoise status
sudo journalctl -u v4l2-relayd@default.service -n 80 --no-pager \
  | grep -F 'cameranoise:'
```

If the relay hits systemd's restart limit:

```bash
sudo systemctl reset-failed v4l2-relayd@default.service
sudo systemctl start v4l2-relayd@default.service
```

If the image becomes black and the camera LED remains stuck on, rebooting is the safest known recovery. Live LJCA/IPU6 bridge resets did not reliably rebuild this machine's camera graph.

Revalidate the shim after `icamerasrc` or `libcamhal` package upgrades because it relies on the camera HAL's exported C++ ABI.
