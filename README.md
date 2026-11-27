# Scanner

Scan documents and photos on NextBSD, as Image Capture does on a Mac: the
scanners SANE finds, on USB and the network; an overview of the glass; drag
a box to scan part of it; colour, greyscale or black and white, the
resolution, and PDF (several pages in one), PNG, JPEG or TIFF.

Installed by the NextBSD desktop as `/System/Applications/Scanner.app`,
built by [nextbsd-desktop](https://github.com/nextbsd/nextbsd-desktop). Work
is tracked in [nextbsd/nextbsd](https://github.com/nextbsd/nextbsd) (#717).

## Building

```
. /System/Library/Makefiles/GNUstep.sh
gmake
```

It links `libsane.so.1` from NextBSD-gnustep-support (sane-backends: the
backends in `/usr/lib/sane`, their configuration in `/usr/etc/sane.d`) and
zlib.

## How it works

- All of SANE's C API (`sane_init`, `sane_get_devices`, `sane_open`, the
  options, `sane_start`, `sane_read`) is called on one thread of Scanner's
  own (`SCScanner`), so the window never waits for a scanner. It looks for
  scanners every few seconds for as long as it runs. Cancel stops a scan
  between two reads.
- PDFs are written by `SCPDFWriter`: each page is the scan itself, JPEG for
  colour and grey and one bit a pixel (deflated) for black and white, at the
  size the paper was. Several pages go into one PDF.
- Light and Dark follow the desktop's `NBAppearance`, and change with it.
- The saved file is opened with NSWorkspace: in Preview if there is one,
  else in whatever opens it.

## SANE settings for one account

Scanner puts the account's own SANE directory before the system's in
`SANE_CONFIG_DIR`: `~/Library/ApplicationSupport/Scanner/sane.d` (or the
first directory of `SANE_CONFIG_DIR`, when it is set). SANE reads the first
copy of each file it finds, so a file there replaces the system's for this
account only:

- **Add a Network Scanner…** writes the host into `net.conf` there (a copy
  of the system's the first time), for SANE's `net` backend.
- SANE's `test` backend, a pretend scanner for trying Scanner without one,
  is off in the system's `dll.conf`. To turn it on for one account:

  ```
  mkdir -p ~/Library/ApplicationSupport/Scanner/sane.d/dll.d
  echo test > ~/Library/ApplicationSupport/Scanner/sane.d/dll.d/test
  ```

  It then appears as "Test scanner". A copy of `/usr/etc/sane.d/test.conf`
  beside it with `test-picture "Color pattern"` gives it something to show.

USB scanners need the account at the screen to be allowed to open them:
`usbconsoled` (nextbsd-userland) hands the console user the USB devices no
kernel driver claims, as diskarbitrationd does disks.

BSD 2-Clause; see [LICENSE](LICENSE).
