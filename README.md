# Unplug Tray

A small macOS menu bar app for ejecting USB sticks, SD cards, external SSDs and disk images safely.

Click the eject icon in the menu bar and you get every removable drive, its volumes and how much space is free on each. Click Eject and it unmounts all of the drive's volumes and ejects the device, the same as Finder does. You get a notification once the drive is safe to pull out.

When a drive won't eject, Unplug Tray tells you which programs have files open on it. You can quit those apps and eject in one click, try again, or force the eject. Hold Option while the menu is open to see Force Eject directly.

It runs offline. There is no network code, no analytics and no settings file. It reads drive details with `diskutil` and `lsof`, which ship with macOS.

## What it shows

* Only drives you could unplug: external, removable or ejectable volumes mounted under `/Volumes`. The startup disk and system volumes never appear.
* APFS drives as one device. An APFS volume lives in a container disk, so the app follows the container back to the physical disk and ejects that.
* Drives with several partitions as one entry with one Eject button.

## Install

You need macOS 13 or later and the Xcode command line tools.

```
git clone https://github.com/psmux/unplug-tray.git
cd unplug-tray
./scripts/install.sh
```

This builds a universal app and copies it to `~/Applications/Unplug Tray.app`. Keep it on the startup disk. If the app ran from an external drive, it would keep that drive busy and you could never eject it.

Turn on Open at Login from the menu if you want it there after every restart.

To build without installing, run `./scripts/build-app.sh`; the app lands in `build/`. The build is signed ad hoc. Set `SIGN_IDENTITY` to a Developer ID to sign it properly.

## Tests

```
swift test
```

The tests cover the parsing of `lsof` and `diskutil` output and how volumes map to physical disks.

## Why force eject is behind a warning

Force eject unmounts a volume while programs still have files open on it. Anything those programs hadn't saved is lost, and a file that was half written can end up damaged. Unplug Tray always tries a normal eject first and names the programs in the way, so you rarely need the force option.

## License

MIT. See [LICENSE](LICENSE).
