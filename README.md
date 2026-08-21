# Kindle Wall Calendar

Turn a jailbroken Kindle Paperwhite into a wall-mounted calendar that runs for
months on a single charge. This repo hosts the **KUAL extension**
(`calendar.sh` plus menu files) that runs on the Kindle and talks to a
[TRMNL](https://usetrmnl.com)-compatible display API. The jailbreak and the
server are not included; the [Jailbreaking](#jailbreaking-not-included-here)
and [Server](#server) sections point to both.

## How it works

The extension polls a display server every 15 minutes for a pre-rendered
calendar image and draws it with `fbink`. Between refreshes it suspends the
Kindle to RAM instead of staying awake. E-ink holds the image on screen with
no power while suspended, and an RTC (real-time clock) alarm wakes the device
just before the next refresh is due. That is what gets the device to about a
month per charge instead of a few days.
[Suspend and battery design](#suspend-and-battery-design) covers the details
and the failure modes.

## What's in this repo

```
kindle/trmnlcal/
├── config.xml     KUAL extension manifest
├── menu.json      KUAL menu (the actions listed below)
└── bin/
    └── calendar.sh   the extension itself (POSIX sh)
```

Beyond the jailbreak, KUAL, and MRPI (covered below), nothing else is needed
on the Kindle side.

## Supported firmware / jailbreak lineage

This was built and run against:

- Kindle Paperwhite firmware **5.19.2**
- Jailbreak: **SpringBreak** (the [kindlemodding.org](https://kindlemodding.org)
  lineage, not the older MobileRead/KindleBreak one)

The kindlemodding.org lineage covers firmware roughly 5.16.3 and newer. If
your device is on an older firmware with a KindleBreak-era jailbreak, the KUAL
and MRPI packages below may not match. Check kindlemodding.org's
compatibility notes for your firmware first.

## Jailbreaking (not included here)

This repo does not include, link to a mirror of, or explain how to obtain
jailbreak files. Jailbreaking a Kindle voids its warranty and is done at your
own risk (see [Disclaimer](#disclaimer)).

Start at **[kindlemodding.org](https://kindlemodding.org)** and follow their
jailbreaking guide for your device and firmware version. Come back here once
your Kindle is jailbroken and you can see a `JAILBROKEN.txt` file on it.

## Installing KUAL and MRPI

Once jailbroken, you need two more things on the device before this
extension will run: **KUAL** (the launcher that runs extensions like this
one) and **MRPI** (the MobileRead Package Installer, used to install KUAL
itself). For the SpringBreak/kindlemodding.org lineage (FW 5.16.3+):

- KUAL for K5 and newer: [PEKI release](https://github.com/KindleTweaks/PEKI/releases/latest/download/PEKI.zip)
- MRPI: [kual-mrinstaller-khf.zip](https://kindlemodding.org/jailbreaking/post-jailbreak/installing-kual-mrpi/kual-mrinstaller-khf.zip)

Follow kindlemodding.org's install instructions for both packages, since the
packages and steps change over time. Confirm you're on a compatible firmware
first; MRPI's own `VERSION` file says which firmware range it is patched for.

## Installing this extension over USB

No SSH or USBNetwork is needed anywhere in this setup. Everything below
happens over a plain USB mass-storage connection.

1. With KUAL and MRPI installed (above), plug the Kindle into a computer over
   USB. It should mount as a normal USB drive.
2. Copy this repo's `kindle/trmnlcal/` folder to `extensions/trmnlcal/` on the
   Kindle (the `extensions/` folder KUAL reads from, alongside where KUAL
   itself lives).
3. Open `kindle/trmnlcal/bin/calendar.sh` and fill in the three `CHANGE_ME_*`
   values near the top of the file, or set them as environment variables
   (see [Configuration](#configuration)).
4. Safely unmount and unplug the Kindle.
5. On the Kindle: open **Library** → tap **KUAL**. If KUAL doesn't appear
   yet, plug/unplug once more or restart the Kindle from the power menu; the
   library index sometimes needs a nudge to pick up new extensions.

## Configuration

`calendar.sh` reads its server connection details from three environment
variables, each with a placeholder default you must replace (edit the top of
the script directly, or export them before KUAL invokes it):

| Variable | Purpose |
| --- | --- |
| `TRMNL_SERVER` | Base URL of your display server, e.g. `http://192.168.1.50:8484` |
| `TRMNL_DEVICE_ID` | The device ID you registered on that server |
| `TRMNL_ACCESS_TOKEN` | The access token your server expects for this device |

See [Server](#server) below for what the server side needs to provide.

## Using the extension (KUAL menu)

Tap **KUAL → TRMNL Calendar** to see these actions:

- **Test once (keeps Kindle normal)** — fetches and draws one frame without
  touching suspend or the reader framework. Use this first to confirm the
  server connection and drawing both work.
- **Suspend test (2 min, then wakes)** — the one-shot suspend diagnostic.
  Arms an RTC alarm 120s out, suspends once, and logs a
  `SUSPENDTEST verdict=...` line plus a PASS/FAIL card on screen. It never
  loops and always leaves the device awake afterward. Run this before
  trusting suspend on your device.
- **Start calendar display** — starts the refresh loop (every 15 minutes by
  default). This is the "leave it running" mode.
- **Stop and restore Kindle** — stops the loop and hands the device back to
  the normal reader framework.
- **Diagnose probes** — prints which RTC interface, HTTP client, and battery
  source the script found on your device, to `calendar.log` and the panel.
- **Show type ruler** — a drawing sanity check for `fbink` text sizing.

The refresh loop only reaches month-scale battery once suspend is explicitly
enabled; see the next section.

## Suspend and battery design

Suspend is the whole reason to use a Kindle for this instead of a tablet: a
device that stays awake needs charging every few days. It is also the part
that can fail in ways that leave a dark screen on your wall, so this section
covers the design and the two failures that shaped it.

### The mechanism

Before each suspend, the script arms a wakeup on the device's RTC
(`/sys/class/rtc/rtc0/wakealarm`, the generic kernel interface), reads the
armed value back to confirm it took, then suspends to RAM
(`echo mem > /sys/power/state`). E-ink needs no power to hold an image, so
the display stays on while the device sleeps, until the RTC alarm fires and
resumes it for the next refresh.

### Suspend is opt-in

The refresh loop only attempts suspend if a file,
`/mnt/us/calendar/suspend.enabled`, exists next to the log. Nothing creates
that file for you, not even a passing suspend test. You place it by hand over
USB, after you've read a diagnostic verdict and trust suspend on your device.
Without it, the loop refreshes fully awake: shorter battery life (days, not
months), but always safe, since a Kindle that never suspends can't fail to
wake up.

### A failed cycle still suspends

If Wi-Fi doesn't reassociate or the image fetch fails, the script keeps the
last good image on screen, retries the radio, and still suspends for the
interval rather than staying awake. An early version fell back to staying
awake on error, and that caused a multi-hour dark-screen outage: handing the
device back to the OS's own power management on the error path let it
idle-suspend with no alarm armed at all.

### Re-arm the safety alarm on every retry

A second, independent wakeup (the safety alarm) is armed for
`interval + grace` seconds at the top of every cycle, so a mid-cycle crash
still leaves a pending alarm. Arming it once per cycle turned out not to be
enough. One run saw `wait_for_wifi` block for around 18 hours instead of its
60-second bound, because an uncontrolled OS-level suspend caught it mid-wait,
and the only alarm covering that cycle had already elapsed. The device slept
with nothing to wake it until someone plugged in a USB cable. The fix: re-arm
the safety alarm before every Wi-Fi retry attempt, not just once at cycle
start, so an uncontrolled suspend during a long retry loop is always bounded
by a fresh alarm.

### The watchdog

A separate watchdog process checks a heartbeat file on its own schedule and
restarts the refresh loop if it goes stale. The RTC alarm can wake the
hardware, but it can't restart a process that has died. The watchdog is
deliberately tiny (sleep, read a timestamp, compare, restart) so there is as
little as possible in it that could itself hang.

With suspend enabled and both guards in place, the design targets about a
month per charge with Wi-Fi on. Whether that holds on your device depends on
its suspend behavior and Wi-Fi chipset. Run the suspend test and watch a
battery log before trusting it unattended overnight.

## Server

`calendar.sh` expects a small TRMNL-style display API. Any server that
implements these two endpoints will work:

- `GET /api/display` — called each refresh cycle with `ID` (or a
  `?id=` query param), `Access-Token`, and `FW-Version` headers (and
  optionally `RSSI` / `Battery-Percent`). Expected to return JSON containing
  an `image_url` field the script then downloads and draws.
- `POST /api/log` — log shipping so you can see what the device is doing
  without another USB pass. Optional; the display loop works without it.

This repo does not include a server. The reference implementation this was
built and tested against is **[TRMNL](https://usetrmnl.com)** — either their
hosted product, or one of their official self-host / BYOS (Bring Your Own
Server) options.

## Disclaimer

- Jailbreaking your Kindle **voids its warranty**. Do this at your own risk.
- This project is **not affiliated with, endorsed by, or supported by
  Amazon** or TRMNL. "Kindle" is a trademark of Amazon; "TRMNL" is a
  trademark of its respective owner. Both names are used here only to
  describe compatibility.
- Suspend-to-RAM behavior, RTC availability, and battery life all depend on
  your specific device and firmware. Nothing here is guaranteed to work
  identically on hardware other than what this was tested on (Kindle
  Paperwhite, firmware 5.19.2, SpringBreak jailbreak).

## Credits

- [fbink](https://github.com/NiLuJe/FBInk) — the e-ink drawing tool this
  extension shells out to.
- [KUAL](https://github.com/KindleTweaks/PEKI) (PEKI build) — the on-device
  extension launcher.
- MRPI (MobileRead Package Installer) — used to install KUAL; see
  [kindlemodding.org](https://kindlemodding.org) for current packages.
- [kindlemodding.org](https://kindlemodding.org) — the jailbreak and
  post-jailbreak tooling lineage this was built against.
- [TRMNL](https://usetrmnl.com) — the display API and product this extension
  was designed to speak to.

## License

MIT — see [LICENSE](LICENSE).
