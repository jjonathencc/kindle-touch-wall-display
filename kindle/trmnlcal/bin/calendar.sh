#!/bin/sh
# TRMNL calendar screen for Kindle, run as a KUAL extension.
#
# The battery plan: suspend the device to RAM between refreshes and wake on an RTC
# alarm. E-ink holds the last image with no power, so the agenda stays visible while
# the device sleeps. That is what buys months-class battery instead of days.
#
# The suspend cycle is PROVEN: this has run as the normal operating mode in
# production since early August 2026, with nightly runs of roughly 96 wake
# cycles (one every 15 minutes) confirming months-class battery, and a further
# fix in August 2026 that closed a gap where a long Wi-Fi retry could outlive
# its safety alarm (see the re-arm logic in the wifi-retry loop below). On a
# device where the RTC wakealarm interface is present and writable, this is
# no longer an open question - it works.
#
# It still is an open question on hardware this hasn't run on, so:
#
#   1. "suspendtest" is the one-shot diagnostic: arm +120s, suspend once, report a
#      PASS/FAIL card on the panel and a verdict line in calendar.log. Run this
#      first on any device this hasn't been proven on yet.
#   2. The refresh loop only attempts suspend when the file suspend.enabled exists
#      next to this log. Nothing creates that file automatically - not even a
#      passing suspendtest. It is placed by hand, over USB, after the diagnostic
#      verdict has been read. Without it the loop refreshes fully awake - a safe
#      default for a device this hasn't been proven on yet.
#
# Fail-safe rules the loop obeys, in order of importance:
#   - Never suspend without reading the armed alarm back from the RTC.
#   - A failed cycle (Wi-Fi did not come back, or the fetch failed) NEVER stops the
#     loop and NEVER restores the framework. It first hard-cycles the radio and
#     retries; if still down it keeps the last good image and suspends the interval
#     anyway, then retries on the next wake. Handing the device back to powerd on an
#     error is what sleeps it with no alarm and freezes the watchdog (the 2026-08-09
#     dark-screen outage). Suspending through an outage keeps months-class battery.
#   - Three consecutive suspend failures (the RTC refuses the sleep, a separate
#     hardware fault): keep refreshing but stay awake this run (battery becomes
#     days-class; the display keeps working). This is the only awake-fallback left.
#   - stop.flag next to the log ends the loop at the next wake. It can be created
#     over plain USB mass storage, so there is always a way in without a shell.
#
# Every wake logs battery percentage, so an overnight run yields drain-per-wake.
#
# The TRMNL_* environment overrides exist for the host-side test harness; they are
# never set on the device, so every default below is the real device value.
#
# Usage: calendar.sh once | suspendtest [seconds] | start | stop | probe | ruler
#
# ---- CONFIGURE THESE for your setup (edit below, or export as env vars) ----
#   TRMNL_SERVER        base URL of your TRMNL-API-compatible server, e.g.
#                        http://192.168.1.50:8484 (see README "Server" section)
#   TRMNL_DEVICE_ID      the device ID you registered on that server
#   TRMNL_ACCESS_TOKEN   the access token your server expects for this device
# ------------------------------------------------------------------------

SERVER="${TRMNL_SERVER:-http://CHANGE_ME_SERVER_HOST:8484}"
DEVICE="${TRMNL_DEVICE_ID:-CHANGE_ME_DEVICE_ID}"
ACCESS_TOKEN="${TRMNL_ACCESS_TOKEN:-CHANGE_ME_ACCESS_TOKEN}"
BASE="${TRMNL_BASE:-/mnt/us/calendar}"
OUT="$BASE/screen.png"
TMP="$BASE/screen.png.part"
LOG="$BASE/calendar.log"
PIDFILE="$BASE/loop.pid"
STATEFILE="$BASE/takeover.active"
STOPFLAG="$BASE/stop.flag"
SUSPEND_ENABLED="$BASE/suspend.enabled"
FBINK="${TRMNL_FBINK:-/mnt/us/libkh/bin/fbink}"

INTERVAL="${TRMNL_INTERVAL:-900}"    # fallback seconds between refreshes; the live
                                     # value comes from the server's refresh_rate
                                     # field on /api/display when it is sane
MIN_INTERVAL="${TRMNL_MIN_INTERVAL:-300}"    # served values outside these bounds are
MAX_INTERVAL="${TRMNL_MAX_INTERVAL:-21600}"  # ignored and INTERVAL is used instead
FULL_REFRESH_EVERY=4                 # flash the panel every Nth draw to clear ghosting
FIRST_DRAW_DELAY="${TRMNL_FIRST_DRAW_DELAY:-3}"  # let KUAL finish repainting first
WIFI_MAX_WAIT="${TRMNL_WIFI_MAX_WAIT:-60}"       # seconds to wait for Wi-Fi after resume
WIFI_PROBE_WAIT="${TRMNL_WIFI_PROBE_WAIT:-10}"   # quick UNHELD first probe; a healthy
                                                 # cycle associates in a few s, so it
                                                 # passes here and never holds the radio
                                                 # awake (keeps normal suspends untouched)
WIFI_RESET_TRIES="${TRMNL_WIFI_RESET_TRIES:-3}"  # hard radio resets before a cycle is failed
FAIL_BACKOFF="${TRMNL_FAIL_BACKOFF:-60}"         # awake pause after a failed cycle
REDRAW_EVERY="${TRMNL_REDRAW_EVERY:-30}"         # re-blit cadence during awake sleeps
HEARTBEAT_EVERY="${TRMNL_HEARTBEAT_EVERY:-30}"  # log a liveness line this often while waiting
KILL_WINDOW="${TRMNL_KILL_WINDOW:-5}"            # pause before suspend so stop can win
MAX_FAILS=3
SUSPEND_RETRIES="${TRMNL_SUSPEND_RETRIES:-5}"   # transient display/wifi locks clear in seconds
SUSPEND_RETRY_WAIT="${TRMNL_SUSPEND_RETRY_WAIT:-4}"

RTC_ALARM="${TRMNL_RTC_ALARM:-/sys/class/rtc/rtc0/wakealarm}"
POWER_STATE="${TRMNL_POWER_STATE:-/sys/power/state}"

# ---------------------------------------------------------------- watchdog
#
# 2026-08-06: the loop ran 88 clean cycles, then stopped between fetching
# /api/display (server saw the 200) and requesting the image. It logged NOTHING
# after that, not even one of the ERROR paths, so the script did not fail - the
# process stopped existing. With the loop gone, nothing held the device awake,
# powerd suspended it, and because the loop dies BEFORE it arms the next alarm
# the device slept with no wake alarm at all. It stayed dark for four hours until
# the power button brought it back.
#
# Two independent guards, because either one alone leaves a hole:
#   1. SAFETY ALARM, armed at the TOP of every cycle for interval+grace. If the
#      process dies mid-cycle the device still has a pending wake, so it comes
#      back instead of sleeping forever.
#   2. WATCHDOG PROCESS, separate from the loop, checking a heartbeat file. The
#      safety alarm wakes the hardware, but a dead loop cannot restart itself,
#      so something outside it has to. It is deliberately tiny: sleep, read a
#      number, compare, restart. Nothing it does can block.
#
# The watchdog is frozen along with everything else during suspend-to-RAM and
# resumes with the device, so it measures wall-clock age from the heartbeat file
# rather than counting its own iterations. That means STALE must comfortably
# exceed one whole sleep: a normal heartbeat is ~interval seconds old at wake.
HBFILE="$BASE/heartbeat"
WDPIDFILE="$BASE/watchdog.pid"
WDLOG="$BASE/watchdog.log"
WD_POLL="${TRMNL_WD_POLL:-120}"          # how often the watchdog looks
WD_STALE="${TRMNL_WD_STALE:-2400}"       # 40 min: > one 900s sleep plus slack
SAFETY_GRACE="${TRMNL_SAFETY_GRACE:-600}"  # safety alarm = interval + this

# Host to ping when checking Wi-Fi is back, derived from SERVER unless overridden.
# Empty means "skip the check".
if [ -n "${TRMNL_WIFI_TEST_IP+set}" ]; then
    WIFI_TEST_IP="$TRMNL_WIFI_TEST_IP"
else
    WIFI_TEST_IP=$(echo "$SERVER" | sed -e 's|^[a-z]*://||' -e 's|[:/].*$||')
fi

mkdir -p "$BASE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# The watchdog keeps its own file so a wedged/huge calendar.log can never stop it
# writing, but it ALSO writes into the main log, because push_log only ships the
# main log and a watchdog that restarts things invisibly is worse than no
# watchdog. Every decision it makes ends up on the server.
wdlog() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') WD $*" >> "$WDLOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') WATCHDOG $*" >> "$LOG"
}

# Liveness marker. Written as a bare epoch so the watchdog's check is a single
# integer compare with nothing to parse and nothing to go wrong.
heartbeat() {
    date +%s > "$HBFILE" 2>/dev/null
}

# Ship the tail of the log to the server. This exists so that diagnosing this
# device NEVER requires another USB pass: every plug/unplug cycle costs real
# time and gets old fast. Best effort only - it must never fail a cycle, never
# block, and never be the reason a refresh dies.
# Read it back on your server's logs by grepping for KINDLE_LOG, e.g. (if
# self-hosting with Docker):
#   docker logs <your-trmnl-server-container> 2>&1 | grep KINDLE_LOG
push_log() {   # $1 = short reason tag, $2 = how many trailing lines
    [ -n "$HTTP" ] || return 0
    tail_n="${2:-40}"
    body=$(tail -n "$tail_n" "$LOG" 2>/dev/null \
        | tr -d '\\"' | tr '\t' ' ' | awk '{printf "%s | ", $0}')
    payload="{\"device\":\"$DEVICE\",\"tag\":\"KINDLE_LOG ${1:-tick}\",\"body\":\"$body\"}"
    case "$HTTP" in
        curl) curl -s -m 15 -X POST -H "Content-Type: application/json" \
                   -d "$payload" "$SERVER/api/log" >/dev/null 2>&1 ;;
        wget) wget -q -T 15 -O /dev/null --header="Content-Type: application/json" \
                   --post-data="$payload" "$SERVER/api/log" >/dev/null 2>&1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------- http client

if command -v curl >/dev/null 2>&1; then
    HTTP="curl"
elif command -v wget >/dev/null 2>&1; then
    HTTP="wget"
else
    HTTP=""
fi

http_file() {   # $1 = url, $2 = destination
    case "$HTTP" in
        curl) curl -s -m 60 -o "$2" "$1" ;;
        wget) wget -q -T 60 -O "$2" "$1" ;;
        *)    return 1 ;;
    esac
}

# ---------------------------------------------------------------- telemetry

# Signal strength in dBm, straight from the wireless driver. Only sent when it looks
# like a negative integer, because a malformed value would be rejected by the server.
rssi_value() {
    # Do NOT match on an interface name; this device does not use wlan0. Take the
    # first data line, whatever the interface is called: lines 1-2 are headers, and
    # column 4 is the signal level in dBm.
    r=$(awk 'NR > 2 && /:/ { v = $4; sub(/\.$/, "", v); print v; exit }' /proc/net/wireless 2>/dev/null)
    case "$r" in
        -[0-9]*) echo "$r"; return ;;
    esac

    if command -v iwconfig >/dev/null 2>&1; then
        r=$(iwconfig 2>/dev/null | sed -n 's/.*Signal level[=:]\{1\}\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' | head -1)
        case "$r" in
            -[0-9]*) echo "$r"; return ;;
        esac
    fi

    echo ""
}

_valid_percent() {   # echoes $1 back when it is a plain 0-100 integer
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 0 ] 2>/dev/null && [ "$1" -le 100 ] 2>/dev/null || return 1
    echo "$1"
}

# Battery charge as a whole-number percentage, or empty if nothing can read it.
# Four sources because none is guaranteed on this firmware.
battery_percent() {
    if [ -n "$TRMNL_BATT_OVERRIDE" ]; then
        _valid_percent "$TRMNL_BATT_OVERRIDE" && return
    fi

    if command -v gasgauge-info >/dev/null 2>&1; then
        b=$(gasgauge-info -c 2>/dev/null | tr -cd '0-9')
        _valid_percent "$b" && return
    fi

    if command -v lipc-get-prop >/dev/null 2>&1; then
        b=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null | tr -cd '0-9')
        _valid_percent "$b" && return
    fi

    for cap in /sys/class/power_supply/*/capacity; do
        [ -r "$cap" ] || continue
        b=$(cat "$cap" 2>/dev/null | tr -cd '0-9')
        _valid_percent "$b" && return
    done

    if command -v lipc-get-prop >/dev/null 2>&1; then
        b=$(lipc-get-prop com.lab126.powerd status 2>/dev/null \
            | grep -i "battery" | head -1 | tr -cd '0-9')
        _valid_percent "$b" && return
    fi

    echo ""
}

# ---------------------------------------------------------------- drawing

draw() {    # $1 = image path, $2 = "full" to flash the panel
    if [ -x "$FBINK" ]; then
        if [ "$2" = "full" ]; then
            "$FBINK" -c -f -g file="$1" >/dev/null 2>&1 && return 0
        else
            "$FBINK" -g file="$1" >/dev/null 2>&1 && return 0
        fi
    fi
    if command -v eips >/dev/null 2>&1; then
        [ "$2" = "full" ] && eips -c
        eips -g "$1" >/dev/null 2>&1 && return 0
    fi
    log "ERROR no working display tool (fbink or eips)"
    return 1
}

# Text card drawn over whatever is on screen. Best effort: the framework can paint
# over it later, so the log line is always the authoritative record.
text_card() {   # $1 = headline, $2.. = detail lines
    [ -x "$FBINK" ] || return 0
    "$FBINK" -c >/dev/null 2>&1
    "$FBINK" -y 3 "$1" >/dev/null 2>&1
    y=5
    shift
    for line in "$@"; do
        "$FBINK" -y "$y" "$line" >/dev/null 2>&1
        y=$((y + 1))
    done
    "$FBINK" -y $((y + 2)) "Details: calendar/calendar.log" >/dev/null 2>&1
}

# ---------------------------------------------------------------- wifi

# THE reason suspend was refused, found 2026-08-04 21:54 from the device's own
# wakelock dump: of ~25 wakeup sources, exactly one was active - "WLAN timeout",
# active_since non-zero - and it is the Wi-Fi driver's own lock. We suspend
# immediately after fetching, while the radio is still associated and holding it,
# so the kernel answers EBUSY. That is also why the standalone suspendtest always
# PASSED: it never fetches, so no Wi-Fi lock is ever taken. Dropping the radio
# before suspending releases the lock and saves the radio's idle draw as well.
wifi_down() {
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1 && {
            log "wifi disabled before suspend (releases the WLAN timeout wakelock)"
            return 0
        }
    fi
    if command -v wifid >/dev/null 2>&1; then
        wifid disable >/dev/null 2>&1 && { log "wifi disabled via wifid"; return 0; }
    fi
    iface=$(awk 'NR > 2 && /:/ { sub(/:$/, "", $1); print $1; exit }' /proc/net/wireless 2>/dev/null)
    if [ -n "$iface" ] && command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$iface" down >/dev/null 2>&1 && { log "wifi $iface brought down via ifconfig"; return 0; }
    fi
    log "WARN could not disable wifi; suspend may still be refused"
    return 1
}

wifi_up() {
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1 && return 0
    fi
    if command -v wifid >/dev/null 2>&1; then
        wifid enable >/dev/null 2>&1 && return 0
    fi
    iface=$(awk 'NR > 2 && /:/ { sub(/:$/, "", $1); print $1; exit }' /proc/net/wireless 2>/dev/null)
    [ -n "$iface" ] && command -v ifconfig >/dev/null 2>&1 && ifconfig "$iface" up >/dev/null 2>&1
    return 0
}

# A HARD radio cycle for when the driver comes back from suspend wedged and a plain
# wifi_up is not enough. 2026-08-09: three cycles in a row logged wifi=FAIL after
# wake, the radio never reassociated, and the loop gave up. wifi_up only asks the
# radio to turn on; if it is already nominally "on" but stuck, that is a no-op.
# Toggling it fully off, letting it settle, then on - plus a wifid kick - forces a
# fresh association. Costs a few seconds and is safe when the radio is healthy.
wifi_reset() {
    wifi_down
    sleep 3
    if command -v wifid >/dev/null 2>&1; then
        wifid disable >/dev/null 2>&1
        wifid enable  >/dev/null 2>&1
    fi
    wifi_up
    sleep 2
    return 0
}

wait_for_wifi() {   # $1 = optional max seconds (default WIFI_MAX_WAIT); echoes seconds
                    # waited; rc 0 when the server host answers a ping
    _wmax="${1:-$WIFI_MAX_WAIT}"
    if [ -z "$WIFI_TEST_IP" ]; then
        echo 0
        return 0
    fi
    w0=$(date +%s)
    while :; do
        if ping -c 1 "$WIFI_TEST_IP" >/dev/null 2>&1; then
            echo $(( $(date +%s) - w0 ))
            return 0
        fi
        [ $(( $(date +%s) - w0 )) -ge "$_wmax" ] && break
        sleep 1
    done
    echo $(( $(date +%s) - w0 ))
    return 1
}

# ---------------------------------------------------------------- fetch

fetch_and_draw() {   # $1 = "full" to force a flashing refresh
    if [ -z "$HTTP" ]; then
        log "ERROR no curl or wget on this device, cannot fetch"
        return 1
    fi

    rssi=$(rssi_value)
    batt=$(battery_percent)

    # FW-Version advertises grayscale support, which is what makes the server return
    # the full-grayscale PNG rather than a 1-bit BMP. Calling /api/display is also what
    # keeps the device card thumbnail current on the server's Devices tab.
    if [ "$HTTP" = "curl" ]; then
        set -- -s -m 30 -H "ID: $DEVICE" -H "Access-Token: $ACCESS_TOKEN" -H "FW-Version: 1.6.6"
        [ -n "$rssi" ] && set -- "$@" -H "RSSI: $rssi"
        [ -n "$batt" ] && set -- "$@" -H "Battery-Percent: $batt"
        json=$(curl "$@" "$SERVER/api/display")
    else
        set -- -q -T 30 -O - --header="ID: $DEVICE" --header="Access-Token: $ACCESS_TOKEN" \
            --header="FW-Version: 1.6.6"
        [ -n "$rssi" ] && set -- "$@" --header="RSSI: $rssi"
        [ -n "$batt" ] && set -- "$@" --header="Battery-Percent: $batt"
        json=$(wget "$@" "$SERVER/api/display")
    fi

    img=$(echo "$json" | sed -n 's/.*"image_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -z "$img" ]; then
        log "ERROR no image_url in response"
        return 1
    fi

    # The server also tells us how often to come back. Honor it only when it is a
    # plain integer inside sane bounds; anything else (missing field, garbage, a
    # server bug serving an absurd number) falls back to INTERVAL. Cadence changes
    # are therefore server-side only - no USB pass needed.
    SERVED_INTERVAL=""
    served=$(echo "$json" | sed -n 's/.*"refresh_rate"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p')
    case "$served" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$served" -ge "$MIN_INTERVAL" ] 2>/dev/null && \
               [ "$served" -le "$MAX_INTERVAL" ] 2>/dev/null; then
                SERVED_INTERVAL="$served"
            fi
            ;;
    esac

    if ! http_file "$img" "$TMP"; then
        log "ERROR download failed, keeping previous screen"
        return 1
    fi
    if [ ! -s "$TMP" ]; then
        log "ERROR empty download, keeping previous screen"
        return 1
    fi

    # Only replace the live image once the download succeeded, so a failed fetch
    # leaves the last good agenda on screen instead of blanking it.
    mv "$TMP" "$OUT"

    draw "$OUT" "$1"
    log "drew $OUT mode=${1:-partial} rssi=${rssi:-none} batt=${batt:-none}"
    return 0
}

# ---------------------------------------------------------------- rtc suspend

# The 2026-08-02 on-device probe confirmed /sys/class/rtc/rtc0/wakealarm is present
# and writable from this script's context, so the mxc and rtcwake fallbacks the
# first draft carried are gone: dead code on this device, and a fallback that only
# fires when the primary breaks is exactly the code path that never gets tested.

arm_alarm() {   # $1 = seconds from now; rc 0 only when the armed value reads back
    echo 0 > "$RTC_ALARM" 2>/dev/null
    if ! echo "+$1" > "$RTC_ALARM" 2>/dev/null; then
        # Some kernels reject the relative form; fall back to an absolute epoch.
        echo $(( $(date +%s) + $1 )) > "$RTC_ALARM" 2>/dev/null || return 1
    fi
    ARMED_AT=$(cat "$RTC_ALARM" 2>/dev/null)
    # A non-empty readback is NOT proof the alarm is set. A cleared wakealarm
    # reads back as "0", and [ -n "0" ] is TRUE, so the old check passed with no
    # alarm armed and the device then suspended with nothing to wake it - it
    # sleeps until someone presses the power button. That is the most likely
    # cause of the 2026-08-05 09:00 stop after 44 clean cycles: silent, no error,
    # calendar frozen on the last draw. Demand a number strictly in the future.
    case "$ARMED_AT" in
        ''|*[!0-9]*) log "ERROR alarm readback not numeric: '$ARMED_AT'"; return 1 ;;
    esac
    now_s=$(date +%s)
    if [ "$ARMED_AT" -le "$now_s" ] 2>/dev/null; then
        log "ERROR alarm readback $ARMED_AT is not in the future (now $now_s); refusing to suspend"
        return 1
    fi
    log "alarm armed readback=$ARMED_AT (+$((ARMED_AT - now_s))s)"
    return 0
}

disarm_alarm() {
    echo 0 > "$RTC_ALARM" 2>/dev/null
}

do_suspend() {   # $1 = expected seconds; sets SLEPT; rc 0 when the write succeeded
    s0=$(date +%s)
    sync    # the log must survive even if the device never wakes
    # The kernel's refusal text (e.g. "write error: Device or resource busy") goes
    # into the log: a refused suspend must say WHY without another debugging pass.
    # The stderr redirect comes FIRST: redirections apply left to right, and if the
    # stdout open is what fails, a trailing 2>> would never capture the message.
    if ! echo mem 2>>"$LOG" > "$POWER_STATE"; then
        SLEPT=0
        return 1
    fi
    SLEPT=$(( $(date +%s) - s0 ))
    return 0
}

suspend_held() {   # $1 = expected seconds; rc 0 when the sleep ran at least 7/8 of it
    [ "$SLEPT" -ge $(( $1 * 7 / 8 )) ]
}

# ---------------------------------------------------------------- diagnostics

probe_report() {
    iface=$(awk 'NR > 2 && /:/ { sub(/:$/, "", $1); print $1; exit }' /proc/net/wireless 2>/dev/null)
    rssi=$(rssi_value)
    batt=$(battery_percent)
    gg=$(command -v gasgauge-info >/dev/null 2>&1 && echo yes || echo no)
    lp=$(command -v lipc-get-prop >/dev/null 2>&1 && echo yes || echo no)
    caps=$(ls /sys/class/power_supply/ 2>/dev/null | tr '\n' ' ')
    rtc=NONE
    [ -w "$RTC_ALARM" ] && rtc=wakealarm

    log "PROBE iface=${iface:-none} rssi=${rssi:-FAIL} batt=${batt:-FAIL}"
    log "PROBE gasgauge=$gg lipc=$lp power_supply='${caps:-none}' http=${HTTP:-NONE} rtc=$rtc"

    if [ -x "$FBINK" ]; then
        "$FBINK" -c >/dev/null 2>&1
        "$FBINK" -y 2  "TRMNL calendar probe report" >/dev/null 2>&1
        "$FBINK" -y 4  "wifi iface : ${iface:-none}" >/dev/null 2>&1
        "$FBINK" -y 5  "rssi       : ${rssi:-FAILED}" >/dev/null 2>&1
        "$FBINK" -y 6  "battery %  : ${batt:-FAILED}" >/dev/null 2>&1
        "$FBINK" -y 8  "gasgauge   : $gg" >/dev/null 2>&1
        "$FBINK" -y 9  "lipc       : $lp" >/dev/null 2>&1
        "$FBINK" -y 10 "power_supply: ${caps:-none}" >/dev/null 2>&1
        "$FBINK" -y 12 "http client: ${HTTP:-NONE}" >/dev/null 2>&1
        "$FBINK" -y 13 "rtc wakeup : $rtc" >/dev/null 2>&1
        "$FBINK" -y 15 "Also written to calendar.log" >/dev/null 2>&1
    fi
}

show_ruler() {
    card="$BASE/type_ruler.png"
    if [ ! -s "$card" ]; then
        log "ERROR ruler card missing at $card"
        [ -x "$FBINK" ] && "$FBINK" -c -y 4 "Type ruler image not found." >/dev/null 2>&1
        return 1
    fi
    draw "$card" full
    log "drew type ruler $card"
}

# One suspend/resume cycle, nothing else. Does not stop the framework, does not
# loop, and always ends with the device awake. This must PASS - and its log must be
# read - before anyone enables suspend in the refresh loop.
# Same test, but with the screen takeover applied first. suspend_test passes on
# this device while the loop's suspend is always refused, and takeover_begin is the
# only material difference between them: it stops the framework. This isolates that
# single variable in one 2-minute run instead of another overnight guess.
# MUST run detached, for exactly the reason the loop must: takeover_begin stops the
# framework, KUAL is part of the framework and is our parent, so a foreground run
# kills itself the moment the takeover lands. The 2026-08-04 21:41 attempt did
# precisely that - "taking over screen" and then nothing, no verdict at all. So the
# entry point only detaches; the real work happens in __suspendtest_takeover.
suspend_test_takeover() {
    dur="${1:-120}"
    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
    if [ -z "$SCRIPT_PATH" ] || [ ! -f "$SCRIPT_PATH" ]; then
        case "$0" in
            /*) SCRIPT_PATH="$0" ;;
            *)  SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
        esac
    fi
    log "SUSPENDTEST-TAKEOVER: detaching, then stopping framework, then same test"
    if command -v setsid >/dev/null 2>&1; then
        setsid /bin/sh "$SCRIPT_PATH" __suspendtest_takeover "$dur" </dev/null >/dev/null 2>&1 &
    else
        /bin/sh "$SCRIPT_PATH" __suspendtest_takeover "$dur" </dev/null >/dev/null 2>&1 &
    fi
    return 0
}

suspend_test() {   # $1 = seconds to sleep, default 120
    dur="${1:-120}"
    sleep "$FIRST_DRAW_DELAY"
    b0=$(battery_percent)
    log "SUSPENDTEST begin dur=${dur}s batt=${b0:-none}"

    if ! arm_alarm "$dur"; then
        log "SUSPENDTEST verdict=FAIL reason=alarm-not-armed (write failed or readback empty)"
        text_card "TRMNL SUSPEND TEST: FAIL" \
            "RTC alarm did not arm." \
            "Device was NOT suspended and is awake."
        return 1
    fi
    log "SUSPENDTEST armed readback=$ARMED_AT now=$(date +%s); suspending"

    if ! do_suspend "$dur"; then
        disarm_alarm
        log "SUSPENDTEST verdict=FAIL reason=suspend-write-refused"
        wakelock_report
        push_log "suspendtest-fail" 30
        text_card "TRMNL SUSPEND TEST: FAIL" \
            "Kernel refused the suspend write." \
            "Device never slept and is awake."
        return 1
    fi

    # From here the device did come back, or none of this would run.
    wifi_up
    wifi_s=$(wait_for_wifi)
    wifi_ok=$?
    b1=$(battery_percent)

    if suspend_held "$dur"; then
        held=yes
    else
        held=no
        disarm_alarm    # a stale alarm from a failed sleep must not fire later
    fi

    verdict=FAIL
    reason=""
    if [ "$held" = "yes" ] && [ "$wifi_ok" -eq 0 ]; then
        verdict=PASS
    elif [ "$held" = "no" ]; then
        reason=" reason=short-sleep (suspend returned early or never entered)"
    else
        reason=" reason=wifi-not-back (slept fine, no ping within ${WIFI_MAX_WAIT}s)"
    fi

    log "SUSPENDTEST verdict=$verdict slept=${SLEPT}s expected=${dur}s wifi_back=${wifi_s}s wifi_ok=$wifi_ok batt_before=${b0:-none} batt_after=${b1:-none}$reason"
    if [ "$verdict" = "PASS" ]; then
        log "SUSPENDTEST note: suspend stays LOCKED for the loop until suspend.enabled is created by hand"
    fi

    text_card "TRMNL SUSPEND TEST: $verdict" \
        "slept      : ${SLEPT}s of ${dur}s" \
        "wifi back  : ${wifi_s}s (ok=$wifi_ok)" \
        "battery    : ${b0:-?}% -> ${b1:-?}%" \
        "Device is awake and back to normal."
    # The framework may repaint on resume; draw the card a second time so it wins.
    sleep 2
    text_card "TRMNL SUSPEND TEST: $verdict" \
        "slept      : ${SLEPT}s of ${dur}s" \
        "wifi back  : ${wifi_s}s (ok=$wifi_ok)" \
        "battery    : ${b0:-?}% -> ${b1:-?}%" \
        "Device is awake and back to normal."
    [ "$verdict" = "PASS" ]
}

# ---------------------------------------------------------------- takeover

takeover_begin() {
    # Order follows kindle-dash: stop the reader UI first so nothing repaints over
    # the agenda, then drop the CPU to powersave.
    #
    # preventScreenSaver is deliberately NOT set here. On the 2026-08-02 overnight
    # run every suspend write came back refused, while the suspendtest - which never
    # runs this takeover - suspended cleanly. preventScreenSaver's entire job is to
    # hold the device awake, so setting it and then asking for suspend-to-RAM is
    # asking powerd to fight the kernel. It is now set only when the loop gives up
    # on suspend and needs to stay awake for long stretches (screensaver_hold).
    log "taking over screen"
    # Firmware 5.19.2 evidence (2026-08-03 log): the old /etc/init.d/framework and
    # bare initctl guards both failed SILENTLY, the framework stayed up, and the
    # home UI repainted over the calendar - which read as "Start does nothing".
    # So: try each known GUI stop in order, record which one actually worked, and
    # say NONE out loud when nothing did. takeover_end restores the same method.
    gui_method=""
    if command -v initctl >/dev/null 2>&1; then
        initctl stop framework >/dev/null 2>&1 && gui_method="initctl framework"
        if [ -z "$gui_method" ]; then
            initctl stop lab126_gui >/dev/null 2>&1 && gui_method="initctl lab126_gui"
        fi
    fi
    if [ -z "$gui_method" ] && [ -x /etc/init.d/framework ]; then
        /etc/init.d/framework stop >/dev/null 2>&1 && gui_method="init.d framework"
    fi
    if [ -n "$gui_method" ]; then
        echo "$gui_method" > "$BASE/gui.method"
        log "takeover: gui stopped via $gui_method"
    else
        mv "$BASE/gui.method" "$BASE/gui.method.none" 2>/dev/null
        log "takeover: NO gui stop method worked; relying on the redraw guard"
    fi
    if command -v initctl >/dev/null 2>&1; then
        initctl stop webreader >/dev/null 2>&1
    fi
    if [ -w /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        echo powersave > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
    fi
    : > "$STATEFILE"
}

# Hold off the screensaver, once, for awake-fallback modes where the device will
# sit unsuspended for whole intervals - otherwise the screensaver paints over the
# agenda within minutes. Never call this on the suspend path. takeover_end clears it.
SCREENSAVER_HELD=0
screensaver_hold() {
    [ "$SCREENSAVER_HELD" -eq 1 ] && return 0
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1
    fi
    SCREENSAVER_HELD=1
    log "screensaver held off for awake fallback"
}

# The hold is sticky, and preventScreenSaver's whole job is to keep the device
# awake, so leaving it set while asking the kernel to suspend is asking powerd to
# fight the kernel. Once awake_sleep started holding it unconditionally, every
# LATER suspend attempt in the same run would have inherited that hold and could
# have been refused because of it - the fix causing the failure it was fixing.
# Release before any suspend attempt; awake_sleep re-holds when it needs to.
screensaver_release() {
    [ "$SCREENSAVER_HELD" -eq 0 ] && return 0
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1
    fi
    SCREENSAVER_HELD=0
    log "screensaver hold released before suspend attempt"
}

# A refused suspend is EBUSY from a held wakelock. Without naming the holder the
# log only says "refused", which is what turned this into a multi-day guess.
wakelock_report() {
    for f in /sys/power/wake_lock /proc/wakelocks /sys/kernel/debug/wakeup_sources; do
        [ -r "$f" ] || continue
        val=$(head -c 2000 "$f" 2>/dev/null | tr '\n' ' ')
        [ -n "$val" ] && log "WAKELOCK $f: $val"
    done
    if command -v lipc-get-prop >/dev/null 2>&1; then
        pss=$(lipc-get-prop com.lab126.powerd preventScreenSaver 2>/dev/null)
        log "WAKELOCK preventScreenSaver=${pss:-unknown}"
    fi
}

takeover_end() {
    # Restore in the reverse order. Nothing here is persistent, so a power-button
    # restart also returns the Kindle to normal even if this never runs.
    log "restoring normal Kindle"
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1
    fi
    if [ -w /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        echo ondemand > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
    fi
    if command -v initctl >/dev/null 2>&1; then
        initctl start webreader >/dev/null 2>&1
    fi
    # Restart the GUI with whichever method takeover_begin recorded; if none was
    # recorded, try them all - restarting an already-running framework is harmless.
    gui_method=$(cat "$BASE/gui.method" 2>/dev/null)
    case "$gui_method" in
        "initctl framework")   initctl start framework >/dev/null 2>&1 ;;
        "initctl lab126_gui")  initctl start lab126_gui >/dev/null 2>&1 ;;
        "init.d framework")    /etc/init.d/framework start >/dev/null 2>&1 ;;
        *)
            command -v initctl >/dev/null 2>&1 && initctl start framework >/dev/null 2>&1
            command -v initctl >/dev/null 2>&1 && initctl start lab126_gui >/dev/null 2>&1
            [ -x /etc/init.d/framework ] && /etc/init.d/framework start >/dev/null 2>&1
            ;;
    esac
    mv "$BASE/gui.method" "$BASE/gui.method.last" 2>/dev/null
    [ -f "$STATEFILE" ] && mv "$STATEFILE" "$STATEFILE.last" 2>/dev/null
}

# ---------------------------------------------------------------- loop

main_loop() {
    n=0
    fails=0           # consecutive failed cycles (wifi or fetch)
    suspend_fails=0   # consecutive failed suspends; at MAX_FAILS suspend is abandoned
    draws=0
    iv="$INTERVAL"    # effective interval; updated from the served value each cycle
    iv_src=default

    # KUAL repaints as it exits, so wait a moment before the first draw or the
    # agenda can be painted over immediately and look like nothing happened.
    sleep "$FIRST_DRAW_DELAY"

    while :; do
        if [ -f "$STOPFLAG" ]; then
            mv "$STOPFLAG" "$STOPFLAG.done" 2>/dev/null
            log "stop.flag found; loop exiting, restoring Kindle"
            takeover_end
            return 0
        fi

        n=$((n + 1))
        heartbeat

        # SAFETY ALARM, armed before any work in this cycle can wedge.
        #
        # The normal path re-arms this precisely just before suspending, so in
        # healthy operation this value is always overwritten and costs nothing.
        # It only matters when the cycle never reaches the suspend step: on
        # 2026-08-06 the loop died mid-fetch, powerd suspended the device, and
        # because arming happened only at the END of a cycle there was no alarm
        # pending and the device slept until a power-button hold. Arming here
        # means the worst case is one missed refresh, not a dark screen.
        if arm_alarm $(( iv + SAFETY_GRACE )); then
            log "safety alarm armed for $(( iv + SAFETY_GRACE ))s before cycle n=$n"
        else
            log "WARN safety alarm could NOT be armed before cycle n=$n"
        fi

        batt=$(battery_percent)
        # The radio is deliberately taken down before every suspend attempt, so it
        # must be brought back at the top of every cycle before anything needs the
        # network. wifi_up is cheap and idempotent when the radio is already on.
        wifi_up
        # Quick UNHELD probe first. On a healthy cycle the radio associates in a few
        # seconds, so this returns fast and we never hold the screensaver - normal
        # suspends stay exactly as before, months-class battery untouched.
        wifi_s=$(wait_for_wifi "$WIFI_PROBE_WAIT")
        wifi_ok=$?
        # If the radio did not reassociate, hard-cycle it and wait again, a few times
        # (the 2026-08-09 fix for a wedged adapter). Do this with the device HELD
        # AWAKE: taking the radio down inside wifi_reset releases the WLAN wakelock,
        # and without a hold powerd idle-suspends MID-recovery. On 2026-08-13 one such
        # uncontrolled mid-recovery suspend missed its wake for ~14h while the network
        # was up the whole time. The hold is BOUNDED - at most WIFI_RESET_TRIES x
        # WIFI_MAX_WAIT (~4 min) - and released the instant wifi is up or the bound is
        # hit, then the normal CONTROLLED suspend (arm_alarm + readback) runs. This is
        # never an open-ended awake loop; the awake-fallback pattern stays banned.
        if [ "$wifi_ok" -ne 0 ]; then
            screensaver_hold
            wifi_try=1
            while [ "$wifi_ok" -ne 0 ] && [ "$wifi_try" -le "$WIFI_RESET_TRIES" ]; do
                log "wifi not back after ${wifi_s}s; hard radio reset ($wifi_try/$WIFI_RESET_TRIES)"
                # Re-arm the same safety window used at the top of the cycle, every
                # retry. 2026-08-19: a single wait_for_wifi() call blocked ~18.5h
                # instead of its ~60s bound (an uncontrolled powerd suspend caught it
                # mid-call), and the only alarm covering the cycle was the one armed
                # once at cycle top, whose window had already elapsed - so the device
                # slept with nothing to wake it until a USB plug-in ended a ~19h dark
                # screen. Re-arming here means any uncontrolled suspend during a
                # retry is still bounded, not just the first ~25 minutes of the cycle.
                if arm_alarm $(( iv + SAFETY_GRACE )); then
                    log "safety alarm re-armed for $(( iv + SAFETY_GRACE ))s before wifi retry $wifi_try"
                else
                    log "WARN safety alarm could NOT be re-armed before wifi retry $wifi_try"
                fi
                wifi_reset
                extra=$(wait_for_wifi)
                wifi_ok=$?
                wifi_s=$((wifi_s + extra))
                wifi_try=$((wifi_try + 1))
            done
            screensaver_release
            log "wifi recovery done: radio $([ "$wifi_ok" -eq 0 ] && echo up || echo 'still down') after ${wifi_s}s held (bounded)"
        fi

        cycle_ok=1
        if [ "$wifi_ok" -ne 0 ]; then
            log "CYCLE n=$n batt=${batt:-none} wifi=FAIL(${wifi_s}s) fetch=skipped"
        else
            if [ "$draws" -eq 0 ]; then
                fetch_and_draw full
                rc=$?
            else
                fetch_and_draw
                rc=$?
            fi
            if [ "$rc" -eq 0 ]; then
                cycle_ok=0
                draws=$((draws + 1))
                [ "$draws" -ge "$FULL_REFRESH_EVERY" ] && draws=0
                if [ -n "$SERVED_INTERVAL" ]; then
                    iv="$SERVED_INTERVAL"; iv_src=served
                else
                    iv="$INTERVAL"; iv_src=default
                fi
                log "CYCLE n=$n batt=${batt:-none} wifi=${wifi_s}s fetch=ok interval=${iv}(${iv_src})"
            else
                log "CYCLE n=$n batt=${batt:-none} wifi=${wifi_s}s fetch=FAIL"
            fi
        fi

        if [ "$cycle_ok" -ne 0 ]; then
            # A failed cycle means Wi-Fi or the fetch was down. Do NOT restore the
            # framework and do NOT stop. Handing the device back to powerd sleeps it
            # with no wake alarm and freezes the watchdog - that is exactly the
            # 2026-08-09 outage, where the loop quit after 3 Wi-Fi failures and the
            # screen stayed dark for 7 hours until a USB plug. Instead keep the last
            # good image, keep the takeover, and fall through to the normal suspend
            # path so the device sleeps the interval on battery and retries Wi-Fi on
            # the next wake. An extended Wi-Fi outage now costs cheap suspends, not a
            # dead display, and months-class battery is preserved.
            fails=$((fails + 1))
            log "cycle failed ($fails); wifi/fetch down, keeping last image, retry after suspend"
            [ $(( fails % 4 )) -eq 0 ] && wakelock_report
            push_log "cycle-failed" 20
        else
            fails=0
            push_log "cycle-ok" 12
        fi

        # Small awake window so the loop can be stopped before it suspends.
        sleep "$KILL_WINDOW"

        if [ ! -f "$SUSPEND_ENABLED" ]; then
            screensaver_hold
            log "suspend locked (no suspend.enabled); plain sleep ${iv}s, device awake"
            awake_sleep "$iv"
            continue
        fi
        if [ "$suspend_fails" -ge "$MAX_FAILS" ]; then
            awake_sleep "$iv"
            continue
        fi

        # Any hold from a previous awake fallback must go before we ask to suspend.
        screensaver_release
        # And the radio must go down, or its wakelock refuses the suspend outright.
        wifi_down
        sleep 3

        if ! arm_alarm "$iv"; then
            wifi_up
            suspend_fails=$((suspend_fails + 1))
            log "ERROR RTC alarm did not arm or read back ($suspend_fails/$MAX_FAILS); staying awake ${iv}s"
            push_log "alarm-failed" 20
            suspend_fallback_check
            awake_sleep "$iv"
            continue
        fi

        # A refusal is usually TRANSIENT, so do not give up on the first one.
        # 2026-08-05 08:56: 43 consecutive suspends had succeeded, then one was
        # refused with hwtcon_wakelock and cmdq_wakelock active - the e-ink
        # display controller and its command queue, held by our OWN redraw
        # moments earlier. Those clear within seconds. The old code treated that
        # single refusal as failure, dropped into the awake fallback, and the
        # device then froze there anyway (heartbeat counter advanced 30s while
        # the wall clock advanced an hour) and never recovered. Retrying costs
        # seconds and avoids the fallback path entirely.
        # Stamp liveness immediately before going under. The watchdog is frozen
        # with us and wakes to find this marker exactly one sleep old, which is
        # why WD_STALE has to exceed a whole interval rather than a cycle time.
        heartbeat
        susp_try=1
        while [ "$susp_try" -le "$SUSPEND_RETRIES" ]; do
            do_suspend "$iv" && break
            if [ "$susp_try" -lt "$SUSPEND_RETRIES" ]; then
                log "suspend refused (attempt $susp_try/$SUSPEND_RETRIES); waiting ${SUSPEND_RETRY_WAIT}s for transient locks to clear"
                sleep "$SUSPEND_RETRY_WAIT"
            fi
            susp_try=$((susp_try + 1))
        done
        if [ "$susp_try" -gt "$SUSPEND_RETRIES" ]; then
            disarm_alarm
            wifi_up
            suspend_fails=$((suspend_fails + 1))
            log "ERROR suspend write refused ($suspend_fails/$MAX_FAILS); staying awake ${iv}s"
            wakelock_report
            push_log "suspend-refused" 25
            suspend_fallback_check
            awake_sleep "$iv"
            continue
        fi

        if suspend_held "$iv"; then
            suspend_fails=0
            log "WAKE n=$n slept=${SLEPT}s of ${iv}s"
        else
            disarm_alarm
            suspend_fails=$((suspend_fails + 1))
            remain=$(( iv - SLEPT ))
            [ "$remain" -lt 1 ] && remain=1
            log "ERROR suspend did not hold: slept ${SLEPT}s of ${iv}s ($suspend_fails/$MAX_FAILS); staying awake ${remain}s"
            suspend_fallback_check
            awake_sleep "$remain"
        fi
    done
}

# Awake sleep with a redraw guard. When suspend is not running, the framework may
# still be alive (5.19.2 has no verified GUI stop yet) and repaints over the agenda
# whenever the device is touched. Sleeping in slices and re-blitting the last good
# image caps any cover-up at REDRAW_EVERY seconds. It also notices stop.flag in a
# slice instead of an interval. The suspend path never comes through here: a
# suspended device holds its image with no power and needs no guard.
awake_sleep() {   # $1 = total seconds
    # Any awake wait MUST hold off the screensaver, no exceptions. This used to be
    # called only after MAX_FAILS suspend failures, so the very first refused
    # suspend dropped us into a 3600s awake wait with nothing stopping powerd from
    # sleeping the device on its own. 2026-08-03 22:47:17 logged "staying awake
    # 3600s" and the loop never reached cycle 2: no crash, no stop line, just
    # silence, which is what a frozen process looks like. The hold is idempotent.
    screensaver_hold
    # ALARM NET (2026-08-11): the screensaver hold is advisory, not a guarantee.
    # On 2026-08-10 05:55 a suspend-did-not-hold drop into this fallback held the
    # screensaver, yet powerd suspended the device seconds later - with the cycle
    # alarm already disarmed, so NOTHING could wake it. 35-hour coma, ended only
    # by a USB plug. Every awake wait therefore arms its own RTC net covering the
    # full wait plus grace. If the device stays awake, the alarm fires while
    # awake and is a harmless no-op; the next cycle top re-arms over it either way.
    if ! arm_alarm "$(( $1 + 120 ))"; then
        log "WARN awake_sleep alarm net did not arm; a rogue suspend here cannot self-recover"
    fi
    left=$1
    total=$1
    since_beat=0
    while [ "$left" -gt 0 ]; do
        chunk="$REDRAW_EVERY"
        [ "$left" -lt "$chunk" ] && chunk="$left"
        sleep "$chunk"
        left=$((left - chunk))
        # An awake wait is legitimate liveness, so keep the marker fresh or the
        # watchdog would restart a loop that is doing exactly what it should.
        heartbeat
        [ -f "$STOPFLAG" ] && return 0
        # Heartbeat: without it an awake wait is completely silent, so a loop that
        # dies mid-wait is indistinguishable from one that is waiting normally.
        # The log must be able to say how far it got.
        since_beat=$((since_beat + chunk))
        if [ "$since_beat" -ge "$HEARTBEAT_EVERY" ]; then
            since_beat=0
            log "awake heartbeat: $((total - left))s of ${total}s elapsed"
        fi
        if [ "$left" -gt 0 ] && [ -s "$OUT" ]; then
            draw "$OUT" >/dev/null 2>&1
        fi
    done
    return 0
}

suspend_fallback_check() {
    [ "$suspend_fails" -ge "$MAX_FAILS" ] || return 0
    log "WARN $MAX_FAILS suspend failures in a row; suspend abandoned for this run, battery will be days not months"
    screensaver_hold
}

# ---------------------------------------------------------------- entrypoints

# Resolved once, for every branch. $0 is relative ("./bin/calendar.sh") when KUAL
# invokes us, and a detached child cannot rely on inheriting a working directory
# that survives its parent - a relative path here is a way to launch nothing at
# all. The watchdog relaunches the loop by this path, so it has to be correct in
# the watchdog's context too, not only inside `start`.
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
if [ -z "$SCRIPT_PATH" ] || [ ! -f "$SCRIPT_PATH" ]; then
    case "$0" in
        /*) SCRIPT_PATH="$0" ;;
        *)  SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
    esac
fi

case "$1" in
    once)
        # Deliberately does not take the screen over, so this is safe to test with.
        sleep "$FIRST_DRAW_DELAY"
        fetch_and_draw full
        ;;
    suspendtest-takeover)
        suspend_test_takeover "$2"
        ;;
    __suspendtest_takeover)
        trap '' HUP
        takeover_begin
        sleep 2
        suspend_test "${2:-120}"
        rc=$?
        log "SUSPENDTEST-TAKEOVER rc=$rc (compare against a plain suspendtest run)"
        wakelock_report
        push_log "suspendtest-takeover-verdict" 40
        ;;
    suspendtest)
        suspend_test "$2"
        ;;
    probe)
        sleep "$FIRST_DRAW_DELAY"
        probe_report
        ;;
    ruler)
        sleep "$FIRST_DRAW_DELAY"
        show_ruler
        ;;
    __watchdog)
        # Internal: the watchdog process. Separate from the loop on purpose - the
        # thing that restarts a dead loop cannot live inside it.
        #
        # Kept deliberately stupid. It sleeps, reads one integer, compares it, and
        # in the bad case kills and relaunches. No network, no drawing, no
        # subshells that can block. Anything clever in here is another thing that
        # can wedge, and then nothing is watching at all.
        trap '' HUP
        echo $$ > "$WDPIDFILE"
        wdlog "watchdog started pid $$ poll=${WD_POLL}s stale=${WD_STALE}s"
        wd_restarts=0
        while :; do
            sleep "$WD_POLL"
            if [ -f "$STOPFLAG" ] || [ -f "$STOPFLAG.done" ]; then
                wdlog "stop flag present; watchdog exiting"
                exit 0
            fi
            hb=$(cat "$HBFILE" 2>/dev/null)
            case "$hb" in
                ''|*[!0-9]*)
                    wdlog "heartbeat unreadable ('$hb'); waiting for the loop to write one"
                    continue ;;
            esac
            now_s=$(date +%s)
            age=$((now_s - hb))
            [ "$age" -lt 0 ] && age=0     # clock stepped backwards; not a stall
            if [ "$age" -le "$WD_STALE" ]; then
                continue
            fi

            wd_restarts=$((wd_restarts + 1))
            wdlog "heartbeat ${age}s old (limit ${WD_STALE}s) - loop is not running; restart #$wd_restarts"
            # Report BEFORE touching anything. push_log needs the radio, and a
            # restart may take the radio down; the existing suspend-refused path
            # already loses its message that way. Say it while we still can.
            wifi_up >/dev/null 2>&1
            push_log "watchdog-restart" 30

            oldpid=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$oldpid" ]; then
                kill -- "-$oldpid" 2>/dev/null || kill "$oldpid" 2>/dev/null
            fi
            pkill -f "calendar.sh __loop" >/dev/null 2>&1
            sleep 2
            heartbeat      # give the new loop a full window before judging it
            setsid /bin/sh "$SCRIPT_PATH" __loop </dev/null >/dev/null 2>&1 &
            wdlog "relaunched loop"
        done
        ;;
    __loop)
        # Internal: the detached loop process itself. Immune to SIGHUP so KUAL's
        # session teardown can never take it down, and it records its OWN pid -
        # the pid in the file is always the process stop must kill, never a wrapper.
        trap '' HUP
        echo $$ > "$PIDFILE"
        # The takeover MUST happen here, inside the detached child, never in the
        # parent. takeover_begin stops the framework, and the framework is what
        # runs KUAL, which is the parent of the launching script. On 2026-08-03 the
        # parent called it first and killed itself mid-launch: the device log shows
        # "taking over screen" and then nothing at all, not even the dead-launch
        # error below, and the framework stayed down so KUAL reported "Application
        # Error: the selected application could not be started". By the time we get
        # here we are already in our own session, so stopping the framework cannot
        # reach us.
        takeover_begin
        main_loop
        ;;
    start)
        # A pid file alone is not proof the loop is running: stop cannot delete it
        # (no rm on this system, ever), and after a device restart the pid can be
        # reused by an unrelated process. kill -0 alone made Start a silent no-op
        # in exactly that state. So the pid only counts when /proc says it is
        # actually this script's loop.
        if [ -f "$PIDFILE" ]; then
            oldpid=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$oldpid" ] && [ -d "/proc/$oldpid" ] && \
               grep -q "calendar.sh" "/proc/$oldpid/cmdline" 2>/dev/null; then
                log "loop already running (pid $oldpid)"
                exit 0
            fi
            mv "$PIDFILE" "$PIDFILE.stale" 2>/dev/null
            log "cleared stale loop.pid (pid ${oldpid:-empty} is not our loop)"
        fi
        # Detach the loop from KUAL's session entirely FIRST, and let the detached
        # child do the takeover. Order matters: see the note in __loop above.
        # SCRIPT_PATH must be absolute. $0 is relative ("./bin/calendar.sh") when
        # KUAL invokes us, and the detached child cannot rely on inheriting a
        # working directory that survives its parent, so a relative path here is a
        # second way to launch nothing at all.
        SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
        if [ -z "$SCRIPT_PATH" ] || [ ! -f "$SCRIPT_PATH" ]; then
            case "$0" in
                /*) SCRIPT_PATH="$0" ;;
                *)  SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
            esac
        fi
        if [ ! -f "$SCRIPT_PATH" ]; then
            log "ERROR cannot resolve own path (\$0=$0); refusing to launch"
            exit 1
        fi
        mv "$PIDFILE" "$PIDFILE.prev" 2>/dev/null
        if command -v setsid >/dev/null 2>&1; then
            setsid /bin/sh "$SCRIPT_PATH" __loop </dev/null >/dev/null 2>&1 &
        else
            /bin/sh "$SCRIPT_PATH" __loop </dev/null >/dev/null 2>&1 &
        fi
        # Wait for the child to announce itself so the started log line is truthful.
        tries=0
        while [ ! -f "$PIDFILE" ] && [ "$tries" -lt 50 ]; do
            sleep 0.1 2>/dev/null || sleep 1
            tries=$((tries + 1))
        done
        if [ -f "$PIDFILE" ]; then
            log "loop started pid $(cat "$PIDFILE") fallback_interval ${INTERVAL}s suspend=$([ -f "$SUSPEND_ENABLED" ] && echo enabled || echo locked)"

        # Start the watchdog only once the loop is really up, and seed the
        # heartbeat first so it cannot judge a loop that has not had a chance to
        # write one yet. Any previous watchdog is killed: two of them would fight
        # over restarts.
        heartbeat
        pkill -f "calendar.sh __watchdog" >/dev/null 2>&1
        if command -v setsid >/dev/null 2>&1; then
            setsid /bin/sh "$SCRIPT_PATH" __watchdog </dev/null >/dev/null 2>&1 &
        else
            /bin/sh "$SCRIPT_PATH" __watchdog </dev/null >/dev/null 2>&1 &
        fi
        wtries=0
        while [ ! -f "$WDPIDFILE" ] && [ "$wtries" -lt 50 ]; do
            sleep 0.1 2>/dev/null || sleep 1
            wtries=$((wtries + 1))
        done
        if [ -f "$WDPIDFILE" ]; then
            log "watchdog started pid $(cat "$WDPIDFILE") poll=${WD_POLL}s stale=${WD_STALE}s"
        else
            # Worth saying loudly: the loop still runs, but unattended recovery
            # is exactly what we just built, and silently not having it is how
            # the display ends up dark for four hours again.
            log "ERROR watchdog did not start; loop is UNSUPERVISED"
        fi
        push_log "loop-started" 20
        else
            log "ERROR loop did not announce a pid within 5s; check for a dead launch"
        fi
        ;;
    stop)
        # THE WATCHDOG DIES FIRST, before the loop is touched. Kill the loop while
        # the watchdog is still alive and it does precisely what it was built to
        # do - spots a dead loop and starts a fresh one - so Stop would look like
        # it did nothing at all.
        if [ -f "$WDPIDFILE" ]; then
            wdpid=$(cat "$WDPIDFILE" 2>/dev/null)
            if [ -n "$wdpid" ]; then
                kill -- "-$wdpid" 2>/dev/null || kill "$wdpid" 2>/dev/null
            fi
            mv "$WDPIDFILE" "$WDPIDFILE.last" 2>/dev/null
        fi
        pkill -f "calendar.sh __watchdog" >/dev/null 2>&1

        if [ -f "$PIDFILE" ]; then
            stoppid=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$stoppid" ]; then
                # The loop is a session leader (setsid), so kill the whole group:
                # that takes out an in-flight external sleep as well. Fall back to
                # the single pid when group kill is unsupported.
                kill -- "-$stoppid" 2>/dev/null || kill "$stoppid" 2>/dev/null
            fi
            mv "$PIDFILE" "$PIDFILE.last" 2>/dev/null
        fi
        # Belt and braces: current loops match __loop; pre-2026-08-03 ones match start.
        pkill -f "calendar.sh __loop" >/dev/null 2>&1
        pkill -f "calendar.sh start" >/dev/null 2>&1
        disarm_alarm    # the safety alarm must not wake a device we just stopped
        takeover_end
        log "stopped"
        ;;
    *)
        echo "usage: calendar.sh once|suspendtest [seconds]|start|stop|probe|ruler"
        exit 1
        ;;
esac
