# backlightctl

Event-based backlight control for Linux. Reads and writes display brightness through sysfs. Unlike [brightnessctl](https://github.com/Hummer12007/brightnessctl), it can watch for changes instead of being polled.

## Motivation

I wanted to show screen brightness on my [status bar](https://github.com/skdishansachin/config/blob/main/quickshell/shell.qml), but `brightnessctl` requires polling on a timer to catch brightness-key presses. The kernel already reports every backlight change to userspace (a `KOBJ_CHANGE` uevent plus `sysfs_notify()` on `actual_brightness`), so `backlightctl monitor` streams one machine-readable line per event. The bar runs a single long-lived process instead of polling.

## Permissions

Writing needs access to `/sys/class/backlight`. Either install the udev rule or run as root.

```
sudo cp contrib/90-backlight.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=backlight
```

Then add your user to the `video` group and log back in.

## License

MIT, see [LICENSE](LICENSE).
