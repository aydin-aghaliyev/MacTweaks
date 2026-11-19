# MacTweaks

A small menu bar app bundling the macOS tweaks I actually use. No dependencies beyond the Command Line Tools.

## Modules

- **Dock Window List**: hover a Dock icon to get a text list of that app's windows on the current Space (when it has more than one); click one to focus it.
- **Scroll Direction**: separate scroll direction for trackpads and mice (macOS only has one switch). Adapted from [Scroll Reverser](https://github.com/pilotmoon/scroll-reverser); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Monitor Brightness Control**: brightness sliders in the menu for the built-in display and external monitors (DDC/CI, Apple Silicon). Adapted from [MonitorControl](https://github.com/MonitorControl/MonitorControl).

Use **Refresh Dock Position** from the menu if Fill expands windows behind the Dock after unplugging a display. It briefly moves the Dock to another edge and then restores its original position.

## Build

```sh
make signing   # once: creates a local self-signed identity in .signing/ so Accessibility permission survives rebuilds
make run       # build, bundle, sign and (re)launch build/MacTweaks.app
make install   # same, into ~/Applications
```

Grant Accessibility access when prompted (System Settings → Privacy & Security → Accessibility).

## Config

`~/.config/mactweaks/config.yaml` (menu → Open Config File… creates it). Changes apply on next use (within a second), no restart.

```yaml
dock_window_list:
  font_size: 13   # 8–32; the header is 2pt smaller
  min_width: 160  # the list fits its titles between min and max width (100–1200 pt)
  max_width: 360  # default scales with font size (360 at 13); set equal to min_width for a fixed width

scroll_direction:  # natural, classic, or system (leave as set in System Settings)
  trackpad: natural
  mouse: classic
```

Only a YAML subset is supported: nested `key: value` maps and `#` comments.

## License

MIT, see [LICENSE](LICENSE). Portions are adapted from Scroll Reverser (Apache-2.0) and MonitorControl (MIT); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
