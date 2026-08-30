# Kindle Touch Wall Display

This KUAL extension turns a Kindle Touch into a wall display. It shows a PNG
supplied by a server and suspends between refreshes.

This version is for the Kindle Touch K5, fourth generation, with a 600 x 800
screen and firmware 5.3.7.3. It was built for the NiLuJe K5 jailbreak and KUAL
KDK 2.0.

## Requirements

- A jailbroken Kindle Touch with KUAL installed
- Wi-Fi configured on the Kindle
- A display server on the same network
- A USB cable

## Install

The files needed on the Kindle are:

```text
extensions/
└── wall-display/
    ├── bin/wall-display.sh
    ├── config.xml
    └── menu.json
```

1. On GitHub, select `Code > Download ZIP`, then extract it.
2. Open `extensions/wall-display/bin/wall-display.sh` and replace
   `CHANGE_ME_SERVER_HOST:8484` with the LAN address and port of your server.
3. Connect the Kindle by USB. Copy the `wall-display` folder from the ZIP's
   `extensions` folder into the Kindle's `extensions` folder.
4. The result must include this file:

   ```text
   extensions/wall-display/bin/wall-display.sh
   ```

5. Eject the Kindle and open `KUAL > Kindle Wall Display > Diagnose`.
6. Select `Test once`.
7. Select `Suspend test (2 min, then wakes)` and leave the Kindle alone. After
   about two minutes, it should wake and show a result screen. `PASS` means the
   Kindle suspended, woke on time, and reconnected to Wi-Fi.
8. Press the Home button after reading the result. Test text may remain over the
   home screen after a partial e-ink refresh.
9. After a passing test, connect the Kindle by USB and create an empty file named
   `wall-display/suspend.enabled`.
10. Eject the Kindle and select `Start wall display` in KUAL.

Without `suspend.enabled`, the display refreshes while the Kindle stays awake.

## Server response

The Kindle sends `GET /api/display`. The response must contain an image URL:

```json
{
  "image_url": "http://192.168.1.20:4567/display.png",
  "refresh_rate": 900
}
```

The image URL must be reachable from the Kindle. Use a 600 x 800 portrait PNG.
Plain HTTP is the safest choice with the Kindle's old TLS software.

`assets/placeholder.png` is a sample image for testing.

`POST /api/log` is optional.

## KUAL controls

- `Test once` downloads and draws one image.
- `Suspend test (2 min)` checks suspend and RTC wake.
- `Restore reader screen` clears test text left by a partial refresh.
- `Start wall display` starts the refresh loop.
- `Stop and restore Kindle` stops the loop and restores the reader.
- `Diagnose` shows the detected network, display, battery, and RTC tools.

## Problems

Logs are stored in `wall-display/wall-display.log` on the Kindle's USB storage.

If the KUAL menu is missing, check the extension path in step 4. If an image
does not load, check `SERVER`, the JSON response, and whether `image_url` opens
from another device on the same network.

To stop the display without KUAL, create `wall-display/stop.flag` over USB. A
Kindle restart also restores the normal reader.

## Credits

This project is a fork of
[jstriblet/kindle-wall-display](https://github.com/jstriblet/kindle-wall-display).

Released under the MIT License. See [LICENSE](LICENSE).
