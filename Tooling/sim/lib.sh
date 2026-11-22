# Sourced by the scripts beside it. Bash 3.2: macOS ships nothing newer, and no `timeout`.

SIM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SIM_DIR/lane.env"

BRIDGE=http://127.0.0.1:8765

# Chosen from what the machine actually has: device lists change between images, and a hardcoded
# name fails late and confusingly.
sim_pick_device() {
  xcrun simctl list devices available -j | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
for runtime in sorted(devices, reverse=True):
    if 'iOS' not in runtime: continue
    for d in devices[runtime]:
        if d.get('isAvailable') and 'iPhone' in d['name']:
            print(d['udid']); raise SystemExit
"
}

# `simctl io screenshot` refuses a device with more than one display (a foldable's two panels) and
# lists them as `--display=<id>  <name> (<role>) <w>x<h>`. Photograph the one marked `(primary)`;
# a device with a single display needs no flag, so the plain call comes first. The simulator's
# own listing goes to the log so the chosen display can be checked against it.
sim_screenshot() {
  local udid=$1 file=$2 out display
  out=$(xcrun simctl io "$udid" screenshot "$file" 2>&1) && return 0
  display=$(printf '%s\n' "$out" | sed -n 's/^ *--display=\([0-9][0-9]*\)  *.*(primary) [0-9x]*$/\1/p' | head -1)
  if [ -z "$display" ]; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  echo "screenshot: $udid has several displays, using --display=$display" >&2
  xcrun simctl io "$udid" screenshot --display="$display" "$file" > /dev/null
}

# `bootstatus -b` can wait forever on a simulator that hung during boot, so it runs in the
# background under a deadline. Returns non-zero when the deadline passes.
sim_wait_booted() {
  local udid=$1 deadline=$((SECONDS + $2)) pid
  xcrun simctl bootstatus "$udid" -b > /dev/null &
  pid=$!
  while kill -0 "$pid" 2> /dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$pid" 2> /dev/null
      wait "$pid" 2> /dev/null
      return 1
    fi
    sleep 2
  done
  wait "$pid"
}

sim_find_app() {
  find "$1/Build/Products" -name '*.app' -maxdepth 3 | head -1
}
