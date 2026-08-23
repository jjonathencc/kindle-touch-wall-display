# Kindle Wall Calendar

Turn a jailbroken Kindle into a wall-mounted calendar that runs for weeks to
months on a single charge, instead of the few days you get from a browser
left open on a page. This is mostly a manual: how the pieces fit together,
what to jailbreak, what to install, and the exact failure modes we hit
building it. It happens to ship a small piece of code too.

**[Photo/GIF placeholder — add a picture or clip of the calendar running on
the wall here before publishing]**

## Contents

1. [What this is](#what-this-is)
2. [Hardware](#hardware)
3. [Jailbreak](#jailbreak-not-included-here)
4. [KUAL, MRPI, and the tools this is built on](#kual-mrpi-and-the-tools-this-is-built-on)
5. [The server](#the-server)
6. [Our custom code: the KUAL extension](#our-custom-code-the-kual-extension)
7. [What makes this different](#what-makes-this-different)
8. [Known issues](#known-issues)
9. [License](#license)

## What this is

A KUAL extension (`calendar.sh` plus two small manifest files) that runs on
a jailbroken Kindle and turns it into a dedicated e-ink calendar display.
Every 15 minutes it fetches a pre-rendered calendar image from a display
server on your LAN and draws it with `fbink`. Between refreshes, instead of
sitting there with the screen backlight-equivalent draw of a normal
awake device, it suspends the Kindle to RAM and wakes itself with a
real-time-clock (RTC) alarm timed for the next refresh. E-ink holds the
image with no power while the device sleeps, so nearly all of the battery
drain between refreshes goes away.

This repo ships the **device-side client only** — the extension that runs
on the Kindle. The server it talks to is a self-hosted, open-source project
built by someone else (see [The server](#the-server)); we point you to it
rather than shipping a copy. The plugin that actually renders a calendar
into an image lives on our own server and isn't included here either — more
on why in [Our custom code](#our-custom-code-the-kual-extension).

If you just want to know whether this is worth the weekend it'll cost you:
yes, if you want a wall calendar that survives unattended for weeks without
a charger, and you're comfortable jailbreaking a Kindle and running a small
self-hosted server. No, if you want something you can buy and plug in — for
that, look at [TRMNL](https://trmnl.com) itself, or their official hardware.

## Hardware

**Proven on:** a Kindle Paperwhite 5 Signature Edition (PW5SE), firmware
5.19.2, jailbroken with SpringBreak. Panel is 1236×1648 portrait at 300ppi
(E Ink Carta 1200). That's the only device this has actually run on.

**Probably works, not verified:** the same jailbreak (SpringBreak) also
covers Kindle Touch 5 (KT5), Kindle Touch 4 (KT4), and Paperwhite 4 (PW4) on
their supported firmware ranges, and the KUAL/MRPI packages below aren't
device-specific. But the display panel's resolution and DPI vary by model,
and the image the server renders is sized for the PW5's panel — using a
different Kindle means your server-side calendar renderer needs to know
your panel's dimensions too. Nobody has done that work here yet.

What you need, concretely:

- **A jailbroken Kindle.** See [Jailbreak](#jailbreak-not-included-here)
  below — this is the part that depends entirely on your specific device
  and firmware, and it's on you to get right.
- **A USB cable.** Installing the extension is a plain USB mass-storage
  copy. No SSH, no USBNetwork, no on-device shell access needed anywhere in
  this setup — deliberately, because getting either of those working on a
  modern jailbreak is its own rabbit hole and this doesn't need it.
- **A machine on your LAN to run the display server.** Nothing exotic —
  this runs comfortably on a small home server or even a Raspberry Pi
  alongside other self-hosted services. Docker is the easiest path; see
  [The server](#the-server).
- **A source of calendar data and a plugin to render it,** which you'll
  have to build yourself for now — see the note in
  [Our custom code](#our-custom-code-the-kual-extension).

## Jailbreak (not included here)

**This repo does not host, mirror, link directly to, or explain how to
obtain jailbreak files.** We're not going to pretend that's neutral — it's
because jailbreak tooling changes constantly as Amazon patches firmware,
and a stale copy sitting in this repo would eventually be actively wrong,
maybe in a way that bricks someone's device. Go to the source, which stays
current. This is entirely your own choice and your own risk: jailbreaking a
Kindle voids its warranty, and while it's normally reversible, "normally"
isn't "always."

**Check your firmware version first.** On most Kindles: **Settings → All
Settings → Device Options → Device Info** (exact wording drifts a little
between firmware generations, but it's always under Device Info or Device
Options). The jailbreak you need depends entirely on your model and that
firmware number — there is no one-size-fits-all answer.

**Start at [kindlemodding.org](https://kindlemodding.org)**, the actively
maintained hub for current-generation Kindle jailbreaking. Their
[Jailbreak Wizard](https://kindlemodding.org/jailbreak-wizard.html) takes
your device and firmware version and tells you which jailbreak applies —
use that instead of guessing. This device used **SpringBreak**
(github.com/KindleModding/SpringBreak), which covers Kindle Touch 5, PW5(SE)
on firmware 5.19.2+, and KT4/PW4 on 5.18.1.1.1+.

**If you're on an older Kindle or older firmware,** the modern
kindlemodding.org tools won't apply, and you're looking at older,
historical jailbreaks instead — which one depends on exactly what you have:

- **WinterBreak** — Kindle 5th-generation-and-newer devices, firmware up
  through 5.18.0 (patched by Amazon in 5.18.1; SpringBreak above is what
  picked up where it left off).
- **KindleBreak** (2021, built on the KindleDrip exploit) — older devices:
  Paperwhite 2/3/4, Oasis 1/2/3, Voyage, and basic Kindles 8th–10th
  generation, on firmware in the 5.10.3–5.13.3 range.

Both of those, along with anything newer, are best found through the
kindlemodding.org hub above rather than an old forum link that may have
rotted. The **[MobileRead Kindle Developer's
Corner](https://www.mobileread.com/forums/forumdisplay.php?f=150)** is the
long-running community forum behind most of this work (jailbreaks, KUAL
itself, and most of the tools below trace back to threads there) — worth
searching if your exact device/firmware combination isn't covered cleanly
by the current hub.

Come back here once your Kindle is jailbroken and you can see a
`JAILBROKEN.txt` file on it.

## KUAL, MRPI, and the tools this is built on

Two more things go on the device before this extension will run, and
neither is ours:

- **[KUAL](https://github.com/KindleTweaks/PEKI)** (Kindle Unified
  Application Launcher) — the on-device launcher that runs extensions like
  this one. We used the **PEKI** build
  ([latest release](https://github.com/KindleTweaks/PEKI/releases/latest)),
  which targets Kindle 5-and-newer devices and doesn't require MRPI to
  install itself.
- **MRPI** (MobileRead Package Installer) — used to install KUAL. Get the
  current package from kindlemodding.org's
  [post-jailbreak install guide](https://kindlemodding.org/jailbreaking/post-jailbreak/installing-kual-mrpi/kual-mrinstaller-khf.zip)
  — check the MRPI package's own `VERSION` file for which firmware range
  it's built for before installing; it changes.

Follow kindlemodding.org's own instructions for installing both, since the
exact packages and steps shift over time and their docs stay current where
this README won't.

**What we built on top of, and where the design came from:** the
suspend-to-RAM approach — arm an RTC alarm, suspend the whole device to
RAM between refreshes, wake for the next fetch — is not something we
invented. It comes from **[kindle-dash](https://github.com/pascalw/kindle-dash)**
by Pascal Widdershoven, which pioneered exactly this pattern for turning an
old Kindle into a low-power dashboard. `calendar.sh`'s own screen-takeover
ordering (stop the reader framework, then drop the CPU into powersave)
follows kindle-dash's lead directly — it's called out in the code comments.
What we built differently: kindle-dash's docs describe installing over
SSH/USBNetwork, while this setup deliberately avoids that (plain USB +
KUAL menu only); and this extension adds a wireless update channel, a
watchdog process, dual-alarm redundancy, and hardened Wi-Fi recovery on top
of the base suspend/wake mechanism kindle-dash established — see
[What makes this different](#what-makes-this-different) and the code itself
for the details.

The actual screen drawing is done by **[FBInk](https://github.com/NiLuJe/FBInk)**
by NiLuJe, the framebuffer/e-ink drawing tool the jailbreak toolchain ships.
We don't distribute FBInk; it's already on the device once you're
jailbroken, and `calendar.sh` just shells out to it.

## The server

`calendar.sh` expects a small TRMNL-style display API. Any server
implementing these two endpoints works:

- **`GET /api/display`** — called every refresh cycle with an `ID` header
  (device identity), `Access-Token`, `FW-Version`, and optionally `RSSI` /
  `Battery-Percent`. Must return JSON containing an `image_url` field
  pointing at the image to draw next.
- **`POST /api/log`** — optional. The device ships a tail of its own log
  here on every cycle, so you can see what it's doing without another USB
  pass. The display loop works fine without it; you just lose the easy
  remote diagnostics.

We didn't write a server from scratch. This runs against a self-hosted fork
of **[usetrmnl/byos_fastapi](https://github.com/usetrmnl/byos_fastapi)** —
a FastAPI implementation of the TRMNL "Bring Your Own Server" API, built by
Rui Carmo on earlier work by [@ohAnd](https://github.com/ohAnd/trmnlServer).
**We are not shipping that code here.** It's someone else's open-source
project, MIT-licensed on its own terms; go clone and self-host it directly
from their repo. [TRMNL](https://trmnl.com) is the company/product this API
shape comes from — they also sell their own hardware and a hosted cloud
service, neither of which this project uses.

## Our custom code: the KUAL extension

This is what's actually in `kindle/trmnlcal/`:

```
kindle/trmnlcal/
├── config.xml     KUAL extension manifest
├── menu.json      KUAL menu (the actions listed below)
└── bin/
    └── calendar.sh   the extension itself, POSIX sh
```

**One honest gap:** the plugin that renders a Google Calendar into the
actual PNG this script fetches and draws lives inside our BYOS server fork,
not in this repo. We left it out on purpose — it's wired directly into
personal infrastructure (a home dashboard's API, some personal habit
counters that show up in the title bar) that would take real work to
sanitize properly, and rather than rush a half-scrubbed version out, we're
shipping the honest client + the API contract above instead. If you want
the calendar image itself, you're writing a plugin for your BYOS server
that returns a PNG at `/api/display`. The contract above is everything
`calendar.sh` needs from it; the panel is 1236×1648 portrait, 8-bit
grayscale, if you're targeting the same Kindle Paperwhite 5 panel.

### Installing it

No SSH or USBNetwork anywhere in this. Everything below is a plain USB
mass-storage copy.

1. With KUAL and MRPI installed (previous section), plug the Kindle into a
   computer over USB. It mounts as a normal USB drive.
2. Copy this repo's `kindle/trmnlcal/` folder to `extensions/trmnlcal/` on
   the Kindle (the same `extensions/` folder KUAL itself lives in).
3. Open `kindle/trmnlcal/bin/calendar.sh` and change the `SERVER` line near
   the top:
   ```sh
   SERVER="${TRMNL_SERVER:-http://CHANGE_ME_SERVER_HOST:8484}"
   ```
   Replace `CHANGE_ME_SERVER_HOST` with your BYOS server's LAN address
   (e.g. `192.168.1.50`). That's the only value you strictly need to
   change; `DEVICE` and the `Access-Token` header just below it are plain
   identifiers, not secrets — edit them directly in the file if you want a
   different device name, but the defaults work fine for a single-Kindle
   setup.
4. Safely unmount and unplug the Kindle.
5. On the Kindle: **Library → KUAL**. If KUAL doesn't show up yet, plug/
   unplug once more or restart the Kindle from the power menu — the
   library index sometimes needs a nudge to notice a new extension.

### Using it (KUAL → TRMNL Calendar)

- **Test once (keeps Kindle normal)** — fetches and draws one frame without
  touching suspend or the reader framework. Run this first to confirm the
  server connection and drawing both work before anything else.
- **Suspend test (2 min, then wakes)** — the one-shot suspend diagnostic.
  Arms an RTC alarm 120 seconds out, suspends once, and logs a
  `SUSPENDTEST verdict=...` line plus a PASS/FAIL card on the panel. It
  never loops and always leaves the device awake afterward. **Run this and
  read the verdict before trusting suspend on your device** — the loop
  won't suspend on its own no matter what this test says.
- **Suspend test WITH takeover (diagnostic)** — the same test, but with the
  reader framework stopped first, the way the real loop runs it. Useful if
  the plain suspend test passes but the real loop's suspends don't; it
  isolates whether stopping the framework is what's changing the outcome.
- **Start calendar display** — starts the refresh loop (every 15 minutes,
  overridable from the server side). This is the "leave it running" mode.
  It does **not** suspend by itself — see below.
- **Stop and restore Kindle** — stops the loop and the watchdog, and hands
  the device back to the normal reader framework.
- **Diagnose probes** — prints which RTC interface, HTTP client, and
  battery source the script found on your device, to `calendar.log` and
  the panel. Useful for a first sanity check on new hardware.
- **Show type ruler** — a pixel-for-pixel sizing reference for `fbink` text,
  used while tuning the server-side renderer's font sizes to a specific
  panel. Not needed unless you're doing that work yourself.

**Suspend is opt-in, on purpose.** The refresh loop only attempts suspend
if a file, `suspend.enabled`, exists next to `calendar.log` on the device.
Nothing creates that file automatically — not even a passing suspend test.
You place it by hand, over USB, once you've read a diagnostic verdict and
trust suspend on your specific device. Without it, the loop refreshes
fully awake: days-class battery instead of weeks-to-months, but it can
never fail to wake up, because it never went to sleep.

A note on the comments inside `calendar.sh`: they're real engineering notes
written while this was being built and debugged, dated to when they were
written. Some describe the state of things as of early August 2026 and
haven't been updated since — they're a working log, not always the current
status. For the current, honest state of things, see
[Known issues](#known-issues) below, which is kept up to date.

## What makes this different

Most Kindle-as-dashboard tutorials fall into one of two camps: leave a
browser open on a page and let the Kindle's own screensaver/refresh cycle
handle it (which mostly defeats e-ink's power advantage — the device stays
functionally awake), or run a script that fetches and redraws on a timer
without ever actually suspending the device. Either way you're looking at
days of battery, not weeks or months, because the device never stops
drawing power between refreshes.

This one suspends the whole device to RAM between refreshes and wakes on a
real RTC alarm — the mechanism [kindle-dash](https://github.com/pascalw/kindle-dash)
established and this extension builds on directly (credited above). E-ink
holds the last image with zero power while suspended, so nearly the entire
gap between one 15-minute refresh and the next costs almost nothing.
Measured in clean overnight runs: about 0.15%/hour of drain, which works
out to roughly a month per charge — not the multi-day ceiling of an
always-awake approach.

What this extension adds on top of the base suspend/wake idea: a wireless
update channel (push a new `calendar.sh` to the device over Wi-Fi, with a
sha256 + syntax check before it's applied and an automatic revert if the
new version never completes a healthy cycle — no more USB trips for every
fix), a separate watchdog process that restarts the refresh loop if it
ever goes stale, a second RTC alarm mirrored as backup where the hardware
supports it, and Wi-Fi recovery that hard-resets the radio and retries
rather than giving up and handing the device back to its own power
management (which is what caused the worst early outages — see below).

None of that changes the target: the design goal is "months of battery,
unattended," full stop. We treat trading that away for reliability — e.g.
just leaving the device awake — as not a fix, only a last resort the code
falls back to after repeated hardware-level suspend failures on a given
device.

## Known issues

Two real bugs are open right now. We're not going to sand these off the
README — if you build this, you should know what to expect.

**(A) Wi-Fi sometimes fails to reassociate for extended periods.**
Observed 2026-08-13 and again 2026-08-22. The device wakes on its normal
schedule every time — the RTC alarm and suspend cycle keep working — but
the Wi-Fi radio won't reconnect to the access point for anywhere from
hours to (in the worst case so far) about 33 hours, before recovering on
its own. Battery is unaffected throughout, since the device is still
suspending normally between failed retries; what you lose is a fresh
calendar image, not battery life. This is instrumented (diagnostic
logging added 2026-08-22) but not yet root-caused or fixed. Actively being
worked; a fix is expected within days, not weeks.

**(B) A suspend that doesn't hold can cascade into a silent awake
fallback.** Occasionally (2026-08-05, 2026-08-10/11, and again 2026-08-23)
a suspend returns early instead of holding for the full interval. The
script has always had a documented fallback for this — stay awake and keep
refreshing rather than risk not waking up at all — but on 2026-08-23 a bug
in that fallback's own timing logic caused it to lose track of how long it
had actually been awake, and the device sat idle for nearly two hours
without anyone (including the server) being able to tell something was
wrong. **The silent part of this is fixed** as of script version
`2026-08-23.1`: the fallback now checks real wall-clock time against a
budget and bails out to a full retry instead of drifting silently, and a
stuck fallback now shows up in server-side logs without needing to pull
the device's own log to see it. **What's still open:** the underlying
trigger — why the suspend didn't hold in the first place — is not yet
explained. New diagnostics were added alongside the fix (2026-08-23) to
capture what actually woke the device next time this happens, so the next
occurrence should be diagnosable from server logs alone. Actively being
worked; expected within days.

If you hit either of these on your own hardware, the device recovers on
its own in both cases — worst case, a single power-button press followed
by KUAL → TRMNL Calendar → Start calendar display gets it going again.
Neither has caused data loss or bricked anything.

## License

The code in this repo (`kindle/trmnlcal/`) is MIT-licensed — see
[LICENSE](LICENSE).

That doesn't extend to anything you install alongside it:

- **The BYOS FastAPI server** you'll self-host is its own separate
  project with its own MIT license (Rui Carmo, building on @ohAnd's
  earlier work) — review the license in
  [usetrmnl/byos_fastapi](https://github.com/usetrmnl/byos_fastapi)
  directly; nothing here inherits or modifies it, since we don't ship any
  of that code.
- **FBInk**, which the jailbreak provides and this script shells out to,
  is GPLv3+. We don't distribute FBInk ourselves — it's already present on
  a jailbroken device — so no obligation flows from this repo, but if you
  ever bundle FBInk's binary with something you build on top of this,
  GPLv3+'s terms apply to that.
- **KUAL, MRPI, and the jailbreak itself** each have their own licensing
  and distribution terms, set by their own maintainers linked above. This
  repo doesn't distribute any of them.
