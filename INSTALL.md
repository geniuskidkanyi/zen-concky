# Installing zen-conky

This guide assumes an ASUS Zenbook Duo with a ScreenPad Plus, running KDE
Plasma on **X11**. Debian and Ubuntu commands are shown; other distributions
ship the same packages under similar names.

## 1. Requirements

| Need | Package (Debian/Ubuntu) | Why |
|---|---|---|
| conky 1.24+ with Lua, cairo and mouse events | `conky-all` | renders the dashboard and receives touch |
| xrandr | `x11-xserver-utils` | finds the ScreenPad's position and size |
| Python 3 | `python3` (preinstalled) | GPU helper |
| NVIDIA proprietary driver | `nvidia-driver` | provides `libnvidia-ml.so.1` for GPU readings (optional) |
| asusd / asusctl | from [asus-linux.org](https://asus-linux.org) | thermal profile buttons (optional) |

```sh
sudo apt install conky-all x11-xserver-utils
```

Check that your conky build supports Lua and mouse events:

```sh
conky --version | grep -iE 'lua|mouse'
```

You should see `Lua bindings` and `Mouse events` listed under X11.

The fonts are Noto Sans and Noto Sans Mono, which most desktops already have.
If they are missing, install `fonts-noto-core`.

## 2. Get the code

```sh
git clone https://github.com/geniuskidkanyi/zen-concky.git ~/Tools/zen-conky
cd ~/Tools/zen-conky
```

Any location works. The scripts find their own directory.

## 3. Turn on the ScreenPad

The ScreenPad has to be **enabled** as a display. Turn it on with the ScreenPad
key, or in **System Settings → Display & Monitor**. Then check that X sees it
with a position:

```sh
xrandr --query | grep -A1 ' connected'
```

You should see something like `DP-1 connected 2880x864+0+1200`. If the line
has no `+X+Y` offset, the screen is still disabled.

## 4. Start it

```sh
./start.sh
```

The launcher:
1. finds the ScreenPad: the connected output with a mode of at least 3:1, or the
   one you name in `ZEN_OUTPUT`;
2. reads its geometry and starts conky as a borderless, transparent window
   pinned below other windows on that screen;
3. starts `bin/zen-gpu.py` for NVIDIA readings. The helper exits when conky does.

To stop it:

```sh
./start.sh stop
```

## 5. Start at login

```sh
./start.sh autostart
```

This writes `~/.config/autostart/zen-conky.desktop`. At login it waits 8 seconds
so Plasma can set up the displays, then runs `start.sh`. To remove it:

```sh
./start.sh noautostart
```

## 6. Enable the fan buttons (optional)

The CPU/GPU fan **AUTO / MAX** buttons write to
`/sys/class/hwmon/hwmonN/pwm{1,2}_enable`, which only root can write by
default. This one-time step installs a udev rule that lets members of the
`plugdev` group write them:

```sh
sudo ./start.sh fan-access
groups | grep -q plugdev || sudo usermod -aG plugdev "$USER"   # then log out and back in
```

The rule lives at `/etc/udev/rules.d/90-zen-conky-fans.rules`. To undo it, delete
that file and reboot.

The **profile** buttons don't need this step. They go through `asusd` over D-Bus.

## 7. Configuration

`start.sh` passes these environment variables through to conky:

| Variable | Default | Meaning |
|---|---|---|
| `ZEN_OUTPUT` | auto | force an output name, e.g. `DP-1` |
| `ZEN_WINDOW_TYPE` | `normal` | `normal`, `desktop` or `dock` (see Troubleshooting) |
| `ZEN_INTERVAL` | `0.5` | redraw interval in seconds; data still samples once per second |
| `ZEN_DISK` | root disk | block device for the I/O graph, e.g. `nvme0n1` |
| `ZEN_MOUNT` | `/` | filesystem shown in the storage bar |
| `ZEN_PRIVATE` | off | `1` hides hostname, SSID and IP |
| `ZEN_DEBUG` | off | `1` logs every pointer/touch event |

Example:

```sh
ZEN_PRIVATE=1 ZEN_MOUNT=/home ./start.sh
```

For autostart with options, edit the `Exec=` line in
`~/.config/autostart/zen-conky.desktop`, e.g.
`Exec=sh -c 'sleep 8; ZEN_INTERVAL=1 "/path/to/start.sh"'`.

Colours, fonts and card layout are set in `lua/zen/theme.lua` and
`lua/main.lua` (see the README).

## Troubleshooting

The log is at `$XDG_RUNTIME_DIR/zen-conky.log`, usually `/run/user/1000/zen-conky.log`.

**"No ScreenPad Plus found" or "connected but disabled"**
: Enable the screen (step 3), then run `./start.sh` again. If your ScreenPad
  reports an unusual mode, name it yourself: `ZEN_OUTPUT=DP-1 ./start.sh`.

**The dashboard is on the wrong screen or offset after changing displays**
: The geometry is read when the dashboard starts. Run `./start.sh` again after
  re-arranging monitors.

**Window is visible but blank**
: Check the log for Lua errors. zen-conky draws through `cairo_xlib` because
  `conky_surface()` in conky 1.24.2 can draw to a stale surface and leave the
  window empty.

**Taps do nothing**
: Run `ZEN_DEBUG=1 ./start.sh`, tap the screen, then look for
  `type=button_down` lines in the log. If there are none, the touchscreen may
  be mapped to the wrong output. In **System Settings → Touchscreen**, map the
  ScreenPad's touch device to the ScreenPad output.

**"Fan control locked" when tapping a fan button**
: Do step 6, and make sure you are in the `plugdev` group.

**The dashboard disappears with Show Desktop (Meta+D)**
: Try `ZEN_WINDOW_TYPE=desktop ./start.sh` or `ZEN_WINDOW_TYPE=dock ./start.sh`.

**GPU shows "powered down" or "reading…"**
: "powered down" is expected while the dGPU is runtime-suspended; zen-conky never
  wakes it just to read it. "reading…" means the GPU is awake but NVML isn't
  responding. Check that `libnvidia-ml.so.1` exists (proprietary driver).

**Wayland**
: zen-conky targets X11. On Wayland, conky's window placement on a specific
  output isn't reliable.

## Uninstall

```sh
./start.sh stop
./start.sh noautostart
sudo rm -f /etc/udev/rules.d/90-zen-conky-fans.rules
rm -rf ~/Tools/zen-conky
```
