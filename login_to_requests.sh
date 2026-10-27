#!/usr/bin/env bash
# Logs in to the Ping app on the connected Android device (only if not already logged in)
# and opens the Requests tab.
# Usage: ./login_to_requests.sh   (EMAIL and PASSWORD default to the test account below; override via env)
# EMAIL and PASSWORD are only needed when the app is not already logged in.
# Set LOGOUT_FIRST=1 to log out first so the login flow is always exercised.
# On the Requests page:
#   1. toggle "Requests requiring attention" OFF and check the request list is available
#   2. toggle it ON and check the active filter colours match it
#      (background vs toggle track, text vs toggle knob)
#   3. toggle it OFF again and check each filter (New, Scheduled, In Progress, Issue,
#      Completed, Cancelled) lists only requests with that status, or a blank page if none.
# Finally logs out.
# The device screen is recorded and saved with the run log in recordings/<date_time>/
# next to this script (set RECORD=0 to skip the screen recording).

set -euo pipefail

EMAIL="${EMAIL:-hetanshi.zoriontech+3@gmail.com}"
PASSWORD="${PASSWORD:-Hetanshi123!}"
PACKAGE="com.pingservices.pingsocialapp"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
command -v "$ADB" >/dev/null 2>&1 || ADB=adb

TMP_DIR="$(mktemp -d -t ping_test)"
UI_XML="$TMP_DIR/ui.xml"
SCREEN_PNG="$TMP_DIR/screen.png"
RUN_DIR="$(cd "$(dirname "$0")" && pwd)/recordings/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_DIR"
exec > >(tee "$RUN_DIR/log.txt") 2>&1

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Screen recording (screenrecord stops at 180s, so it is restarted in parts) ---
REC_PID=""
start_recording() {
  [[ "${RECORD:-1}" == 1 ]] || return 0
  "$ADB" shell 'rm -f /sdcard/ping_rec_*.mp4' >/dev/null 2>&1 || true
  touch "$TMP_DIR/recording"
  (
    i=1
    while [[ -e "$TMP_DIR/recording" ]]; do
      "$ADB" shell screenrecord --time-limit 180 "/sdcard/ping_rec_$i.mp4" >/dev/null 2>&1 || true
      i=$((i + 1))
    done
  ) &
  REC_PID=$!
  log "Recording screen"
}

stop_recording() {
  [[ -n "$REC_PID" ]] || return 0
  rm -f "$TMP_DIR/recording"
  "$ADB" shell pkill -2 screenrecord >/dev/null 2>&1 || true
  wait "$REC_PID" 2>/dev/null || true
  REC_PID=""
  sleep 1   # let screenrecord finish writing the file
  local f
  for f in $("$ADB" shell 'ls /sdcard/ping_rec_*.mp4' 2>/dev/null | tr -d '\r'); do
    "$ADB" pull "$f" "$RUN_DIR/part_$(basename "$f" .mp4 | sed 's/ping_rec_//').mp4" >/dev/null 2>&1 || true
    "$ADB" shell rm -f "$f" >/dev/null 2>&1 || true
  done
  log "Recording and log saved in: $RUN_DIR"
}

cleanup() { stop_recording; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

SWITCH='class="android.widget.Switch"'
FILTER_ROW='class="android.widget.HorizontalScrollView"'
STATUS_FILTERS=("New" "Scheduled" "In Progress" "Issue" "Completed" "Cancelled")

dump_ui() {
  "$ADB" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  "$ADB" shell cat /sdcard/ui.xml > "$UI_XML"
}

# Prints the center "x y" of the first node whose attributes match the regex in $1.
find_center() {
  local node bounds
  node=$(tr '>' '\n' < "$UI_XML" | grep -E "$1" | head -1) || return 1
  bounds=$(echo "$node" | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | grep -oE '[0-9]+') || return 1
  set -- $bounds
  echo "$(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))"
}

screen_has() { grep -qE "$1" "$UI_XML"; }

tap() {
  local xy
  xy=$(find_center "$1") || fail "element not found: $1"
  "$ADB" shell input tap $xy
}

# Waits up to $2 seconds (default 15) for the regex in $1 to appear on screen.
wait_for() {
  local timeout="${2:-15}" i
  for ((i = 0; i < timeout; i++)); do
    dump_ui
    screen_has "$1" && return 0
    sleep 1
  done
  return 1
}

# Focuses the Nth EditText (1-based), clears it, and types $2.
fill_field() {
  local xy
  xy=$(tr '>' '\n' < "$UI_XML" | grep 'class="android.widget.EditText"' | sed -n "${1}p" \
        | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | grep -oE '[0-9]+' \
        | paste -sd' ' - | awk '{print int(($1+$3)/2), int(($2+$4)/2)}')
  [[ -n "$xy" ]] || fail "input field #$1 not found"
  "$ADB" shell input tap $xy
  sleep 0.5
  "$ADB" shell input keyevent KEYCODE_MOVE_END
  "$ADB" shell input keyevent $(printf '67 %.0s' {1..60})
  "$ADB" shell "input text '$2'"
}

logout() {
  dump_ui
  tap 'content-desc="OTHER"'
  wait_for 'content-desc="Logout"' 10 || fail "Logout option not found on OTHER tab"
  tap 'content-desc="Logout"'
  wait_for 'Are you sure you want to Logout' 10 || fail "logout confirmation did not appear"
  tap 'content-desc="LOGOUT"'
  wait_for 'content-desc="(Login|LOGIN)"' 15 || fail "login screen did not appear after logout"
  log "Logged out"
}

# --- Device check ---
"$ADB" get-state >/dev/null 2>&1 || fail "no device connected (check wireless debugging / 'adb devices')"
log "Device: $("$ADB" shell getprop ro.product.model | tr -d '\r')"
start_recording

# --- Bring app to foreground ---
if ! "$ADB" shell dumpsys window | grep mCurrentFocus | grep -q "$PACKAGE"; then
  log "Launching app"
  "$ADB" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
fi

wait_for 'content-desc="(Login|LOGIN)"|content-desc="REQUESTS"' 20 || fail "neither login screen nor home screen appeared"

# --- Logout (only when LOGOUT_FIRST=1) so the login flow is exercised ---
if screen_has 'content-desc="REQUESTS"' && [[ "${LOGOUT_FIRST:-0}" == 1 ]]; then
  log "Already logged in - logging out"
  logout
fi

# --- Login (only if not already logged in) ---
if screen_has 'content-desc="(Login|LOGIN)"'; then
  [[ -n "$EMAIL" && -n "$PASSWORD" ]] \
    || fail "login needed: run as EMAIL=... PASSWORD=... ./login_to_requests.sh"
  log "Entering email: $EMAIL"
  fill_field 1 "$EMAIL"
  dump_ui
  log "Entering password"
  fill_field 2 "$PASSWORD"
  "$ADB" shell input keyevent KEYCODE_BACK   # hide keyboard
  sleep 0.5

  dump_ui
  log "Tapping Login"
  tap 'content-desc="(Login|LOGIN)"'

  wait_for 'Invalid username or password|Would you like to enable auto login|content-desc="REQUESTS"' 20 \
    || fail "no response after tapping Login"
  screen_has 'Invalid username or password' && fail "app says: Invalid username or password"

  if screen_has 'Would you like to enable auto login'; then
    log "Declining Touch ID auto-login"
    tap 'content-desc="NO"'
    wait_for 'content-desc="REQUESTS"' 15 || fail "home screen did not appear after login"
  fi
else
  log "Already logged in"
fi

# --- Open Requests tab ---
log "Opening REQUESTS tab"
tap 'content-desc="REQUESTS"'
wait_for 'content-desc="Requests requiring attention"|content-desc="Filter"' 15 \
  || fail "Requests page did not load"

# Pull to refresh once so the list is up to date; nothing below refreshes again.
log "Refreshing request list (once)"
"$ADB" shell input swipe 540 700 540 1700 300
sleep 3

# Request cards have content-desc="<name> #<id>&#10;<status>".
card_lines() {
  tr '>' '\n' < "$UI_XML" | grep -oE 'content-desc="[^"]* #[0-9]+&#10;[^"&]*' \
    | sed -E 's/^content-desc="//; s/&#10;/|/' || true
}

swipe_list() {   # $1 = up (scroll down the list) | down (gently back towards the top)
  if [[ $1 == up ]]; then "$ADB" shell input swipe 540 1800 540 900 300
  else "$ADB" shell input swipe 540 900 540 1400 400; fi
  sleep 0.8
}

# Chips appear in this order in the filter row.
FILTER_ORDER=("All" "${STATUS_FILTERS[@]}")

chip_index() {
  local i
  for i in "${!FILTER_ORDER[@]}"; do [[ ${FILTER_ORDER[$i]} == "$1" ]] && { echo "$i"; return; }; done
  echo -1
}

# Brings the filter chip named $1 into view (scrolling the chip row) and taps it.
# Scrolls the chip row straight towards the chip, using the first visible chip to pick the direction.
# Scrolls the list back up only while the filter row is hidden, so it never pull-to-refreshes.
select_filter() {
  local i y name want first
  want=$(chip_index "$1")
  for ((i = 0; i < 14; i++)); do
    dump_ui
    if screen_has "content-desc=\"$1\""; then tap "content-desc=\"$1\""; sleep 1; return 0; fi
    if ! screen_has "$FILTER_ROW"; then swipe_list down; continue; fi
    first=-1
    for name in "${FILTER_ORDER[@]}"; do
      screen_has "content-desc=\"$name\"" && { first=$(chip_index "$name"); break; }
    done
    y=$(find_center "$FILTER_ROW" | awk '{print $2}')
    if ((first < want)); then "$ADB" shell input swipe 900 "$y" 400 "$y" 500   # reveal chips on the right
    else "$ADB" shell input swipe 400 "$y" 900 "$y" 500; fi                   # reveal chips on the left
    sleep 0.4
  done
  return 1
}

# Sets the "Requests requiring attention" toggle to $1 (on|off).
set_toggle() {
  local want=false; [[ $1 == on ]] && want=true
  dump_ui
  screen_has "$SWITCH"'[^>]*checked="'$want'"' && return 0
  log "Turning 'Requests requiring attention' toggle $1"
  tap "$SWITCH"
  wait_for "$SWITCH"'[^>]*checked="'$want'"' 5 || fail "attention toggle did not turn $1"
  sleep 1   # let the list reload
}

# --- Toggle OFF: the full request list must be available ---
select_filter "All" || fail "filter chip 'All' not found"
set_toggle off
dump_ui
count=$(tr '>' '\n' < "$UI_XML" | grep -cE 'content-desc="[^"]* #[0-9]+' || true)
[[ $count -gt 0 ]] || fail "no requests listed with the attention toggle OFF"
log "PASS: request list available with toggle OFF ($count request(s) visible)"
tr '>' '\n' < "$UI_XML" | grep -oE 'content-desc="[^"]* #[0-9]+[^"]*"' \
  | sed -E 's/content-desc="//; s/"$//; s/&#10;/ - /g; s/^/    /' || true

# --- Toggle ON: active filter colours match the toggle ---
#   active filter background == toggle track colour
#   active filter text       == toggle knob colour
log "Checking active filter colours against attention toggle"
# Scroll the chip row back to the start if the active "All" chip is not visible.
if ! screen_has 'content-desc="All"'; then
  row_y=$(find_center "$FILTER_ROW" | awk '{print $2}') || fail "filter row not found"
  for i in 1 2 3; do "$ADB" shell input swipe 300 "$row_y" 900 "$row_y" 300; sleep 0.3; done
fi
set_toggle on
dump_ui
"$ADB" exec-out screencap -p > "$SCREEN_PNG"
python3 -I - "$SCREEN_PNG" "$UI_XML" <<'PY' || fail "active filter colours do not match the attention toggle"
import re, struct, sys, zlib
from collections import Counter

png_path, xml_path = sys.argv[1], sys.argv[2]
FILTERS = ["All", "New", "Scheduled", "In Progress", "Issue", "Completed", "Cancelled"]
TOLERANCE = 12  # max summed RGB difference still treated as the same colour

def attr(node, key):
    m = re.search(key + r'="([^"]*)"', node)
    return m.group(1) if m else ""

def bounds(node):
    return tuple(map(int, re.findall(r"\d+", attr(node, "bounds"))))

chips, switch, row = {}, None, None
for node in re.findall(r"<node [^>]*>", open(xml_path, encoding="utf-8").read()):
    desc = attr(node, "content-desc")
    if desc in FILTERS:
        chips[desc] = bounds(node)
    elif desc == "Filter":
        row = bounds(node)
    if attr(node, "class") == "android.widget.Switch" and switch is None:
        switch = (bounds(node), attr(node, "checked") == "true")
if not chips or switch is None or row is None:
    print("    filter chips or attention toggle not found on screen")
    sys.exit(1)

# Decode the screenshot PNG (8-bit RGB/RGBA) only down to the last row we need.
def load_rows(path, max_y):
    data, i, idat = open(path, "rb").read(), 8, b""
    while i < len(data):
        n, = struct.unpack(">I", data[i:i + 4])
        kind, chunk = data[i + 4:i + 8], data[i + 8:i + 8 + n]
        if kind == b"IHDR":
            width, _, _, ctype = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"IDAT":
            idat += chunk
        i += 12 + n
    bpp = {2: 3, 6: 4}[ctype]
    raw, stride, prev, rows, o = zlib.decompress(idat), width * bpp, bytearray(width * bpp), [], 0
    for _ in range(max_y + 1):
        f, r = raw[o], bytearray(raw[o + 1:o + 1 + stride])
        o += 1 + stride
        for x in range(stride):
            a = r[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                r[x] = (r[x] + a) & 255
            elif f == 2:
                r[x] = (r[x] + b) & 255
            elif f == 3:
                r[x] = (r[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                r[x] = (r[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(r)
        prev = r
    return rows, bpp

max_y = max([b[3] for b in chips.values()] + [switch[0][3], row[3]])
rows, bpp = load_rows(png_path, max_y)

def colours(x0, y0, x1, y1):
    c = Counter()
    for y in range(int(y0), int(y1)):
        line = rows[y]
        for x in range(int(x0), int(x1)):
            c[tuple(line[x * bpp:x * bpp + 3])] += 1
    return c

def dist(a, b):
    return sum(abs(p - q) for p, q in zip(a, b))

def hexc(c):
    return "#%02X%02X%02X" % c

page_bg = colours(*row).most_common(1)[0][0]

# Active filter = the chip whose area is mostly a fill colour other than the page background.
active = None
for name, (x0, y0, x1, y1) in chips.items():
    c = colours(x0 + 4, y0 + 4, x1 - 4, y1 - 4)
    # Inactive chips are white-ish on a lightly tinted page, so require a clearly different fill.
    fill, count = next(((col, n) for col, n in c.most_common() if dist(col, page_bg) > 60), (None, 0))
    if fill and count / sum(c.values()) > 0.5:
        if active:
            print("    more than one filter looks active: %s, %s" % (active[0], name))
            sys.exit(1)
        # Sample text from the chip centre only, so the chip's dark outline is not mistaken for text.
        w, h = x1 - x0, y1 - y0
        inner = colours(x0 + w * 0.2, y0 + h * 0.25, x1 - w * 0.2, y1 - h * 0.25)
        text = next((col for col, n in inner.most_common() if dist(col, fill) > 100), None)
        active = (name, fill, text)
if not active or active[2] is None:
    print("    could not detect the active filter chip")
    sys.exit(1)

(sx0, sy0, sx1, sy1), checked = switch
if not checked:
    print("    SKIP: 'Requests requiring attention' toggle is OFF, nothing to compare")
    sys.exit(0)
w, h = sx1 - sx0, sy1 - sy0
band = (sy0 + h * 0.3, sy1 - h * 0.3)
track_c = colours(sx0 + w * 0.08, band[0], sx0 + w * 0.35, band[1])
track = next(col for col, n in track_c.most_common() if dist(col, page_bg) > TOLERANCE)
knob = colours(sx0 + w * 0.55, band[0], sx0 + w * 0.9, band[1]).most_common(1)[0][0]

name, fill, text = active
checks = [
    ("Active filter '%s' background vs toggle track" % name, fill, track),
    ("Active filter '%s' text vs toggle knob" % name, text, knob),
]
ok = True
for label, a, b in checks:
    match = dist(a, b) <= TOLERANCE
    ok &= match
    print("    %s %s: %s vs %s" % ("OK  " if match else "FAIL", label, hexc(a), hexc(b)))
sys.exit(0 if ok else 1)
PY
log "PASS: active filter colours match the attention toggle"

# --- Toggle OFF again so the filter checks see every request ---
set_toggle off

# --- Filter checks: each status filter lists only requests with that status ---
failed=()
for filter in "${STATUS_FILTERS[@]}"; do
  log "Filter: $filter"
  # Only one filter is active at a time: the previous one is deselected at the end of each pass.
  select_filter "$filter" || fail "filter chip '$filter' not found"

  # Collect every card, scrolling until a scroll shows no new ones (a blank list needs no scrolling).
  seen=""
  for ((i = 0; i < 25; i++)); do
    dump_ui
    new=$(card_lines | grep -vxF -f <(printf '%s\n' "$seen") || true)
    [[ -n "$new" ]] || break
    seen=$(printf '%s\n%s' "$seen" "$new" | sed '/^$/d')
    swipe_list up
  done

  if [[ -z "$seen" ]]; then
    log "    PASS: '$filter' shows a blank page (no requests with this status)"
  else
    total=$(printf '%s\n' "$seen" | wc -l | tr -d ' ')
    wrong=$(printf '%s\n' "$seen" | awk -F'|' -v want="$filter" '$2 != want' || true)
    if [[ -z "$wrong" ]]; then
      log "    PASS: all $total request(s) have status '$filter'"
    else
      log "    FAIL: '$filter' shows requests with another status:"
      printf '%s\n' "$wrong" | sed 's/|/ - /; s/^/        /'
      failed+=("$filter")
    fi
  fi

  # Tap the same chip again to deselect it before moving on to the next filter.
  log "    Deselecting '$filter'"
  select_filter "$filter" || fail "filter chip '$filter' not found to deselect"
done

# Leave the page on "All".
select_filter "All" || true

# --- Logout ---
log "Logging out"
logout

[[ ${#failed[@]} -eq 0 ]] || fail "filters with wrong data: ${failed[*]}"
log "PASS: all status filters show the correct requests"