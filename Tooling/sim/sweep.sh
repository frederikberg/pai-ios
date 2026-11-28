#!/usr/bin/env bash
# Launch the app once per screen in fixture mode, photograph it, and check what only the running
# app can answer. Every screen is attempted even after one fails, and the script fails once at the
# end: a run that stops at the second screen has spent the minutes and answered the fewest
# questions it could have.
#
# Fixture mode, the launch-argument router and the debug bridge are all `#if DEBUG`, so a Release
# build has none of this. The first launch (no route, the root session list) also asks the bridge
# for `/screens`, so a screen becomes photographable the moment its `Route` case exists.
#
# Environment:
#   SIM_UDID  the booted simulator
#   ONLY      comma-separated sections and route names to run; empty runs everything, `none` only
#             the root screen. `routes` selects every route screen. A name matching nothing fails.
#   PROBE     a script sourced after the sections; `screenshot`, `want`, $udid and $bundle are in scope
set -o pipefail
# shellcheck source=lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

SECTIONS="none routes measure note-bench auth-rejected fullscreen-image fullscreen-pdf secret-prompt compact-chip mailverdict person-settings playback playback-voice
new-session-landing notes-filtering notifications-filter scheduler-task-push settings-notes-cache
note-uncached-online notes-offline jump-landing deep-link-landing warm-jump clamped-landing note-refused
watch-keys alarm-facts alarm-sheet weather-states location-settings location-launch watch-key-create watch-key-revoke-ask watch-key-revoke
camera-import-result me-screens session-filters new-session-usage quick-actions apps settings-owner settings-guest sleep-mode
reminders-feed reminders-scheduler me-where todos-screens report-bar"

mkdir -p artifacts
udid="${SIM_UDID:?SIM_UDID is required}"
bundle=$BUNDLE
ONLY=${ONLY:-}
fail=0

# True when nothing was selected, or any of the given names was.
want() {
  [ -z "$ONLY" ] && return 0
  local name
  for name in "$@"; do
    case ",$ONLY," in *",$name,"*) return 0 ;; esac
  done
  return 1
}


chrome_assert() {
  curl -sS --max-time 5 "http://127.0.0.1:8765/screen/scroll-views" -o "artifacts/scroll-views-$1.json" || true
  python3 - "artifacts/scroll-views-$1.json" <<'PY' || { echo "::error::$1: a scroll view besides the list, see scroll-views-$1.json"; fail=1; }
import json, sys
views = json.load(open(sys.argv[1]))["views"]
print(views)
sys.exit(0 if views and all(v["height"] > 300 for v in views) else 1)
PY
}

screenshot() {
  name="$1"; shift
  xcrun simctl launch "$udid" "$bundle" -PaiFixtureMode "$@" > /dev/null
  ok=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/health" -o "artifacts/health-$name.json"; then
      # Why the app is on whatever screen it is on. A gate that never opens renders a
      # real screen, passes every check and satisfies the size floor — so without this
      # a wrong screen is indistinguishable from the right one.
      curl -sS --max-time 3 "http://127.0.0.1:8765/fixture" -o "artifacts/fixture-$name.json" || true
      # The route the running app was launched with must be the one asked for: a launch onto an
      # app that was still running ignores its arguments and photographs whatever was on screen.
      want_route=""
      prev=""
      for arg in "$@"; do
        [ "$prev" = "-PaiFixtureRoute" ] && want_route=$arg
        prev=$arg
      done
      if [ -n "$want_route" ]; then
        got_route=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('requestedRoute',''))" \
          "artifacts/fixture-$name.json" 2>/dev/null || echo "")
        if [ "$got_route" != "$want_route" ]; then
          echo "::error::$name: launched for route '$want_route' but the app reports '$got_route' — a previous instance was still running"
          fail=1
        fi
      fi
      ok=1
      break
    fi
    sleep 2
  done
  if [ "$ok" -ne 1 ]; then
    echo "::warning::$name: debug bridge never answered"
    fail=1
  fi
  # 🚨 The bridge starts listening in `PAIApp.init()`, BEFORE the first frame is drawn —
  # so "/health answered" proves the process is alive and proves nothing about the
  # screen. Without this settle the screenshot is a race the app usually wins and
  # occasionally loses, producing a black PNG that is indistinguishable from a genuinely
  # broken screen and costs an investigation to dismiss.
  sleep 6
  sim_screenshot "$udid" "artifacts/screen-$name.png"
  # Asked of every screen rather than of one guessed to be a transcript: the endpoint
  # answers with an empty list anywhere else, and the evaluation below takes whichever
  # report actually has rows in it. Guessing which screenshot leaves a transcript on top
  # is how this check came to run against no rows at all and report a warning nobody
  # would have read as "it proved nothing".
  curl -sS --max-time 10 "http://127.0.0.1:8765/transcript/row-agreement" \
    -o "artifacts/rowagree-$name.json" || true
  # A screen caught before its first frame is a black PNG that still compresses to tens
  # of kilobytes, so the size floor below cannot see it — and it is indistinguishable
  # from a screen that genuinely renders nothing, which would otherwise cost another
  # whole run to tell apart. One retake settles it: a real blank screen is blank twice.
  if [ "$(stat -f %z "artifacts/screen-$name.png")" -le 100000 ]; then
    sleep 5
    sim_screenshot "$udid" "artifacts/screen-$name.png"
  fi
  # Read AFTER the screenshot, not with the health probe: the bridge answers the moment
  # it is listening, which is before the screen has fetched, measured or drawn anything
  # worth logging. This is what distinguishes "nothing arrived" from "nothing measured"
  # from "nothing drawn" — three causes a picture cannot tell apart.
  curl -sS --max-time 3 "http://127.0.0.1:8765/logs?level=info&limit=200" \
    -o "artifacts/logs-$name.json" || true
  # Behind the sign-in gate every route is the sign-in screen, whatever it was asked for; only
  # the run that asks for a refused sign-in expects that.
  case " $* " in
    *" -PaiFixtureAuthState "*) ;;
    *)
      gate=$(curl -sS --max-time 5 "http://127.0.0.1:8765/fixture" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('gate',''))" 2> /dev/null || echo "")
      if [ "$gate" != "ready" ]; then
        echo "::error::$name: the app is behind its sign-in gate ('$gate'), not on the screen asked for"
        fail=1
      fi
      ;;
  esac
  bytes=$(stat -f %z "artifacts/screen-$name.png")
  echo "$name: ${bytes} bytes"
  # A wholly blank screen still produces a valid PNG, just a small one — the one thing
  # every other check here can pass while the screen renders nothing.
  #
  # 🚨 It catches only a screen that is blank ALL OVER. A screen that draws its
  # navigation bar and composer but none of its content is several times this size and
  # sails past — which has happened. The size floor is the cheap half; `logs-<name>.json`
  # above is the half that actually distinguishes an empty screen from a full one.
  if [ "$bytes" -le 20000 ]; then
    echo "::warning::$name: screenshot suspiciously small — the screen may be blank"
    fail=1
  fi
}

# Asserts on what the screen on display reported about itself (`fixtureFact`), read after the
# screenshot has settled. A screen can render, pass every size check and still be the wrong one.
fact_assert() {
  local name=$1 key=$2 want=$3 got
  got=$(curl -sS --max-time 5 "http://127.0.0.1:8765/fixture" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ''))" "$key" 2>/dev/null || echo "")
  if [ "$got" != "$want" ]; then
    echo "::error::$name: expected $key='$want' but the app reports '$got'"
    fail=1
  else
    echo "$name: $key=$got"
  fi
}

screenshot root
curl -sS --max-time 5 "http://127.0.0.1:8765/screens" -o artifacts/screens.json \
  || echo '{"screens":[]}' > artifacts/screens.json
names=$(python3 -c "import json; print('\n'.join(json.load(open('artifacts/screens.json'))['screens']))")

# `simctl launch` on a running app does nothing, launch arguments included: without this the first
# screenshot after the root one photographs the root screen again, labelled with its own route.
xcrun simctl terminate "$udid" "$bundle" || true

# A selection that matches nothing would pass by doing nothing.
for item in $(echo "$ONLY" | tr ',' ' '); do
  case " $(echo "$SECTIONS $names" | tr '\n' ' ') " in
    *" $item "*) ;;
    *) echo "::error::--only: '$item' is neither a section nor a screen"; exit 1 ;;
  esac
done

if want measure; then
  # Does the measured row height agree with what the view actually draws? Nothing checked
  # that until a nested list proved it false — the transcript lays out from analytic
  # heights and never asks a cell its size, so a disagreement is invisible to every other
  # check here and shows up as the reader being dragged around. Nested lists and a quote
  # are the shapes that were wrong; keep an easy case first so a failure is legible.
  printf 'Plain paragraph.\n' > /tmp/m1.md
  printf -- '- one\n- two\n  - nested a\n  - nested b\n    - deeper\n' > /tmp/m2.md
  printf -- '> quoted\n>\n> - a list inside a quote\n>   - and deeper\n' > /tmp/m3.md
  for m in 1 2 3; do
    curl -sS --max-time 5 --data-binary "@/tmp/m$m.md" \
      "http://127.0.0.1:8765/markdown/measure?width=360" \
      -o "artifacts/measure-$m.json" || true
  done

  # The Thinking card's block wraps through TextKit when measured and through SwiftUI `Text`
  # when drawn, and nothing else compares the two. A plain paragraph, a long unbroken
  # token and a run of short words are the shapes where the two wrap differently; a
  # non-zero `delta` in these reports is a Thinking card clipping or leaving a gap.
  python3 -c "
open('/tmp/t1.txt', 'w').write(
    'Thinking through the plan step by step, weighing each option against the others. ' * 40)
open('/tmp/t2.txt', 'w').write(
    'before ' + '/very/long/path/with/no/break/opportunities/' * 12 + ' after ' + 'x' * 300)
open('/tmp/t3.txt', 'w').write(' '.join('w%d' % i for i in range(600)))
"
  for t in 1 2 3; do
    curl -sS --max-time 5 --data-binary "@/tmp/t$t.txt" \
      "http://127.0.0.1:8765/markdown/measure?width=360&block=preformatted" \
      -o "artifacts/measure-thinking-$t.json" || true
  done
fi

if want note-bench; then
  # What a keystroke costs in the open editor on a note the size of the largest real ones, and
  # whether its heights hold still, with the line numbers off and on. Nothing else runs beside it:
  # a sampler pauses the app it measures.
  bench() {
    local name=$1 query=$2
    xcrun simctl terminate "$udid" "$bundle" || true
    screenshot "note-bench-$name" -PaiFixtureRoute noteLarge
    curl -sS --max-time 90 -X POST "http://127.0.0.1:8765/notes/editor-bench?keys=60&$query" \
      -o "artifacts/note-editor-bench-$name.json" || true
    cat "artifacts/note-editor-bench-$name.json" || true
    echo
    sim_screenshot "$udid" "artifacts/screen-note-bench-$name-after.png" || true
    xcrun simctl terminate "$udid" "$bundle" || true
  }
  bench plain lineNumbers=0
  bench line-numbers lineNumbers=1
fi

if want auth-rejected; then
  # The sign-in card, in its rejected state, over a screen with its own list content —
  # reproduces the shape of the bug report (the card drawn see-through over the
  # notification list beneath it) rather than only the ordinary session list, which has
  # no list content directly under the card to prove is or isn't bleeding through.
  screenshot auth-rejected -PaiFixtureRoute notifications -PaiFixtureAuthState rejected
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want fullscreen-image; then
  # `FilePreviewViewer` is a `.fullScreenCover(item:)`, reachable by no `Route` — the
  # session screen fetches the fixture attachment directly and presents it under this flag
  # (`SessionDetailView`'s own `.task`), rather than through a message row's attachment
  # chip, which the fixture corpus deliberately places outside the default tail window.
  screenshot fullscreen-image -PaiFixtureRoute session -PaiFixtureOpenImage
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want fullscreen-pdf; then
  # The same cover on a generated two-page PDF: `PDFPreviewView` and its scroll tracking
  # are drawn by nothing else.
  screenshot fullscreen-pdf -PaiFixtureRoute session -PaiFixtureOpenPdf
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want secret-prompt; then
  # The grant sheet a session pops up by itself when it needs a gated secret — the same
  # sheet the composer's plus menu opens manually, auto-presented on opening a session
  # that is carrying one. Nothing in fixture mode has a live conversation to raise a real
  # prompt, so `-PaiFixtureSecretPrompt` hands the session list one instead.
  screenshot secret-prompt -PaiFixtureRoute session -PaiFixtureSecretPrompt
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want compact-chip; then
  # A draft that starts with `/compact` gets its own chip in the composer's chip row.
  screenshot compact-chip -PaiFixtureRoute session -PaiFixtureDraftText "/compact keep the migration plan"
  fact_assert compact-chip composerDraft "/compact keep the migration plan"
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want session-filters; then
  # The session list with "Hide closed sessions" and the second machine set: the chips they leave
  # behind are the photographed state (a menu opens only on a tap). The rows must shrink against
  # the unfiltered list, and the facts name the filters the list reports.
  screenshot session-filters-none
  fact_assert session-filters-none sessionListFilters "manual hideClosed=false machine=-"
  rows_all=$(curl -sS --max-time 5 "http://127.0.0.1:8765/fixture" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('sessionListRows',''))" 2>/dev/null || echo "")
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot session-filters-hide-closed -PaiFixtureSessionFilters hideClosed
  fact_assert session-filters-hide-closed sessionListFilters "manual hideClosed=true machine=-"
  rows_hidden=$(curl -sS --max-time 5 "http://127.0.0.1:8765/fixture" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('sessionListRows',''))" 2>/dev/null || echo "")
  echo "session-filters: ${rows_all} rows unfiltered, ${rows_hidden} with closed hidden"
  if ! [ "${rows_all:-0}" -gt "${rows_hidden:-0}" ] || ! [ "${rows_hidden:-0}" -gt 0 ]; then
    echo "::error::session-filters: hiding closed sessions left ${rows_hidden} of ${rows_all} rows"
    fail=1
  fi
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot session-filters-both -PaiFixtureSessionFilters both
  fact_assert session-filters-both sessionListFilters "manual hideClosed=true machine=laptop"
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want quick-actions; then
  # The standard grid (five rows of three), the More list behind its tile, the grid pushed past
  # fifteen tiles by three example shortcuts (top, then scrolled to its end), the Actions Library
  # opened by the fixture flag (top, then scrolled to Hidden), and the add-shortcut sheet over it.
  grid="selfReport,me,more,computer,home,ultrafast,mailverdict,homeCall,ultrafastCamera,findNote,newNote,ultrafastCall,notes,alarm,weather"
  more="fastSession,fastCall,canteen,scheduler,decisions,usage,cameraImport,todos,newTodo,searchTodos,todosSwitcher,todosDesk,pauseNotifications"
  screenshot quick-actions-grid -PaiFixtureRoute quickActions
  fact_assert quick-actions-grid quickActionsGrid "$grid"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot quick-actions-more -PaiFixtureRoute quickActions -PaiFixtureQuickMore
  fact_assert quick-actions-more quickMoreList "$more"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot quick-actions-overflow -PaiFixtureRoute quickActions -PaiFixtureQuickShortcuts
  fact_assert quick-actions-overflow quickActionsGrid "$grid,shortcut,shortcut,shortcut"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot quick-actions-overflow-scrolled -PaiFixtureRoute quickActions -PaiFixtureQuickShortcuts -PaiFixtureScrollTo quickGridEnd
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot quick-actions-library -PaiFixtureRoute quickActions -PaiFixtureQuickEdit library
  fact_assert quick-actions-library quickActionsLibrary "grid:$grid|more:$more|hidden:"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot quick-actions-library-end -PaiFixtureRoute quickActions -PaiFixtureQuickEdit library -PaiFixtureQuickShortcuts -PaiFixtureScrollTo quickLibraryEnd
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot quick-actions-add-shortcut -PaiFixtureRoute quickActions -PaiFixtureQuickEdit addShortcut
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want new-session-usage; then
  # The new-session screen shows the plan usage an open session shows, before anything is sent.
  screenshot new-session-usage -PaiFixtureRoute createSession
  fact_assert new-session-usage planUsageBadge shown
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want mailverdict; then
  # The assistant: the new-session screen with it chosen.
  screenshot mailverdict-new-session -PaiFixtureRoute createSession -PaiFixtureNewSessionType mailverdict
  fact_assert mailverdict-new-session newSessionType mailverdict
  fact_assert mailverdict-new-session environmentRow "MailVerdict assistant"
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want person-settings; then
  # The page that holds the person's mail switch, read from the registry.
  screenshot person-settings -PaiFixtureRoute settings -PaiFixtureSettingsCategory notifications
  fact_assert person-settings settingsCategory notifications
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want watch-keys; then
  # The watch keys list in Settings, below the fold.
  screenshot watch-keys -PaiFixtureRoute settings -PaiFixtureSettingsCategory devices -PaiFixtureScrollTo watchKeys
  xcrun simctl terminate "$udid" "$bundle" || true
fi

# The watch-key probes press what a finger would, through `-PaiFixtureWatchKeys`, and are read
# after the settle in `screenshot` (the probe acts two seconds after the screen is up).
if want watch-key-create; then
  # Creating a key: the one-time key sheet must still be showing after the list reload.
  screenshot watch-key-create -PaiFixtureRoute settings -PaiFixtureSettingsCategory devices -PaiFixtureScrollTo watchKeys -PaiFixtureWatchKeys create
  fact_assert watch-key-create watchKeyProbe create:done
  fact_assert watch-key-create watchKeySheet shown
  fact_assert watch-key-create watchKeyCount 3
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want watch-key-revoke-ask; then
  # Revoke swiped on the first key: the confirmation must be on screen (read the picture).
  screenshot watch-key-revoke-ask -PaiFixtureRoute settings -PaiFixtureSettingsCategory devices -PaiFixtureScrollTo watchKeys -PaiFixtureWatchKeys revoke-ask
  fact_assert watch-key-revoke-ask watchKeyProbe revoke-ask:done
  fact_assert watch-key-revoke-ask watchKeyRevokeAsked k1
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want watch-key-revoke; then
  # Revoke confirmed: the list is read again without the key.
  screenshot watch-key-revoke -PaiFixtureRoute settings -PaiFixtureSettingsCategory devices -PaiFixtureScrollTo watchKeys -PaiFixtureWatchKeys revoke
  fact_assert watch-key-revoke watchKeyProbe revoke:done
  fact_assert watch-key-revoke watchKeyCount 1
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want alarm-facts; then
  # The Alarm screen read the fixture list: one ringing, two armed.
  screenshot alarm-facts -PaiFixtureRoute alarm
  fact_assert alarm-facts alarmRinging 1
  fact_assert alarm-facts alarmArmed 2
  # The blank row's height is the room under the rows; it is printed, not asserted, because it
  # depends on the device.
  echo "alarm-facts: alarmBlank=$(curl -sS --max-time 5 http://127.0.0.1:8765/fixture \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('alarmBlank', ''))" 2>/dev/null)"
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want alarm-sheet; then
  # The new-alarm sheet in both entry modes (read both pictures: the wheels, the toggle in the
  # title bar, Save disabled at 0:00:00).
  screenshot alarm-sheet-time -PaiFixtureRoute alarm -PaiFixtureAlarmSheet time
  fact_assert alarm-sheet-time alarmSheetMode time
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot alarm-sheet-in -PaiFixtureRoute alarm -PaiFixtureAlarmSheet in
  fact_assert alarm-sheet-in alarmSheetMode relative
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want weather-states; then
  # Every state the two rows can be in, each photographed and asserted on its verdicts.
  weather_state() {
    state=$1 now=$2 later=$3
    screenshot "weather-$state" -PaiFixtureRoute weather -PaiFixtureWeather "$state"
    fact_assert "weather-$state" weatherNowVerdict "$now"
    fact_assert "weather-$state" weatherLaterVerdict "$later"
    xcrun simctl terminate "$udid" "$bundle" || true
  }
  weather_state showersApproaching rain maybe
  weather_state rainingNow rain maybe
  weather_state dry dry dry
  weather_state noLocation unknown unknown
  weather_state sourceUnavailable unknown unknown
  weather_state forecastOnly unlikely rain
fi

if want me-screens; then
  # The three Me views, the composer over a seeded draft, and the states with less data. A Today
  # screenshot shows its top; `-PaiFixtureScrollTo` brings the tasks card, the plan and the diary
  # rows below the fold into view, and the day detail sits under the grid.
  me_screen() {
    name=$1 tab=$2 facts=$3
    shift 3
    screenshot "me-$name" -PaiFixtureRoute me -PaiFixtureMeTab "$tab" "$@"
    fact_assert "me-$name" meTab "$tab"
    for fact in $facts; do fact_assert "me-$name" "${fact%%=*}" "${fact#*=}"; done
    xcrun simctl terminate "$udid" "$bundle" || true
  }
  today_order=ribbon,body,write,review,tasks,plan,diary,pai,notes
  me_screen today today "meOverviewDays=14 meTodaySections=$today_order meTasksOpen=6"
  me_screen today-tasks today "meTasksOpen=6" -PaiFixtureScrollTo meTasks
  me_screen today-plan today "meTodaySections=$today_order" -PaiFixtureScrollTo mePlan
  me_screen today-diary today "meOverviewDays=14" -PaiFixtureScrollTo meDiary
  me_screen tasks-down today "meTasksOpen=6" -PaiFixtureMe tasksDown -PaiFixtureScrollTo meTasks
  me_screen days days "meOverviewDays=14"
  me_screen days-detail days "meOverviewDays=14" -PaiFixtureScrollTo meDayDetail
  me_screen days-past days "meOverviewDays=14" -PaiFixtureMeDay 2 -PaiFixtureScrollTo meDayDetail
  me_screen diary diary "meDiaryRows=7"
  me_screen no-garmin today "meOverviewDays=14 meTodaySections=$today_order" -PaiFixtureMe noGarmin
  me_screen no-garmin-days days "" -PaiFixtureMe noGarmin
  me_screen empty-diary diary "meDiaryRows=0" -PaiFixtureMe empty
  # Last: it leaves the seeded draft on the simulator, which the screens above must not show.
  me_screen composer today "" -PaiFixtureMeComposer
fi

if want camera-import-result; then
  # A whole run over the fixture camera folder and library, finished: three added, one imported
  # before, the video proxy skipped, one file the library refused.
  screenshot camera-import-result -PaiFixtureRoute cameraImport -PaiFixtureCameraImport
  fact_assert camera-import-result cameraImport "finished imported=3 already=1 ignored=1 failed=1"
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want location-settings; then
  # The Location section in Settings, below the fold.
  screenshot location-settings -PaiFixtureRoute settings -PaiFixtureSettingsCategory location -PaiFixtureScrollTo location
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want location-launch; then
  # A launch in the state a phone recording history relaunches in: Always access, significant
  # changes and place monitoring persisted on. The app must still answer well after launch; what
  # the bridge reports about the geofences is printed, not asserted, because the fixture's settings
  # decide whether this iPhone records at all. A simulator has no real geofencing, so this proves
  # the launch path runs to completion, not that a crossing arrives.
  xcrun simctl terminate "$udid" "$bundle" || true
  xcrun simctl privacy "$udid" grant location-always "$bundle" || true
  xcrun simctl location "$udid" set 37.3349,-122.0090 || true
  xcrun simctl spawn "$udid" defaults write "$bundle" locationMonitoring -bool YES
  xcrun simctl spawn "$udid" defaults write "$bundle" locationKeepsHistory -bool YES
  screenshot location-launch
  sleep 10
  if curl -sS --max-time 5 "http://127.0.0.1:8765/location" -o artifacts/location-launch.json; then
    cat artifacts/location-launch.json
    echo
  else
    echo "::error::location-launch: the app stopped answering after a launch with place monitoring on"
    fail=1
  fi
  curl -sS --max-time 5 "http://127.0.0.1:8765/crash" -o artifacts/location-launch-crash.json || true
  xcrun simctl terminate "$udid" "$bundle" || true
  xcrun simctl spawn "$udid" defaults delete "$bundle" locationKeepsHistory || true
  xcrun simctl spawn "$udid" defaults delete "$bundle" locationMonitoring || true
  xcrun simctl privacy "$udid" reset location "$bundle" || true
fi

if want playback; then
  # The player: the session's Listen chips (the plain session shot), the mini bar with playback on
  # and nothing playing, with a reply in hand, with a refusal, and the full view.
  screenshot playback-on -PaiFixtureRoute session -PaiFixturePlayback on
  fact_assert playback-on playbackBar idle
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot playback-paused -PaiFixtureRoute session -PaiFixturePlayback paused
  fact_assert playback-paused playbackBar paused
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot playback-error -PaiFixtureRoute session -PaiFixturePlayback error
  fact_assert playback-error playbackBar error
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot playback-sheet -PaiFixtureRoute session -PaiFixturePlayback sheet
  fact_assert playback-sheet playbackSheet "Both halves are done."
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want playback-voice; then
  # Settings' playback voices: the person's own voice picked from the account's list (the default
  # reads while they have picked none), the Try button and the speed row.
  screenshot playback-voice -PaiFixtureRoute settings -PaiFixtureSettingsCategory voices -PaiFixtureScrollTo playbackVoice
  fact_assert playback-voice playbackVoice "Default (George (en))"
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want new-session-landing; then
  # The real "New Session" send button, pressed with no device interaction to tap it:
  # the outbox entry, the create response, the handover carrying the new id back to the
  # sheet, and the push racing that sheet's own dismissal. `/transcript/landing` is the
  # proof that matters here, not the screenshot — anything that breaks that chain leaves
  # the screen where it was and never mounts a transcript at all, so `topVisibleRowId`
  # stays null forever rather than merely answering late.
  screenshot new-session-landing -PaiFixtureRoute createSession -PaiFixtureAutoCreateSession
  opened=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/new-session-landing.json; then
      top=$(python3 -c "import json; print(json.load(open('artifacts/new-session-landing.json')).get('topVisibleRowId'))")
      if [ "$top" != "None" ]; then opened=1; break; fi
    fi
    sleep 2
  done
  xcrun simctl terminate "$udid" "$bundle" || true
  if [ "$opened" -ne 1 ]; then
    echo "::error::new-session-landing: no transcript ever mounted after the push+dismiss race — see new-session-landing.json"
    fail=1
  fi
fi

if want notes-filtering; then
  # The note index, then with its filter field focused. Its chip row draws only if the list is the
  # scroll view the navigation bar treats as content: a thin scroll view in the row takes the bar's
  # edge effect, which can mask the chips while they stay tappable.
  screenshot notes-chrome -PaiFixtureRoute notes
  chrome_assert notes-chrome
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot notes-filtering -PaiFixtureRoute notes -PaiFixtureNotesFilterFocused
  chrome_assert notes-filtering
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want notifications-filter; then
  # The notification centre under its source filter. The fixture feed holds a quiet
  # scheduled row (stored read), a blocking one that pushed, and the ordinary rows; the
  # filtered screens must show only the rows each view keeps, task chip included.
  screenshot notifications-scheduled -PaiFixtureRoute notifications -PaiFixtureNotificationSource only
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot notifications-not-scheduled -PaiFixtureRoute notifications -PaiFixtureNotificationSource exclude
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want todos-screens; then
  # The Todos home with the desk in each of its three states, a view, a list, the checklist of a
  # shared list, a todo opened on its subtasks, the add sheet with the parser's chips and Today's
  # day, the same with "no date", the add sheet describing in plain words, Browse, a todo's
  # screen with its rendered description, its nudges with a default one, the sheet that adds a
  # subtask read with chips, the toast with Undo after a tick, the switcher with a typed name, Todos'
  # settings and its sections with the form for a new view, the add sheet holding thirty files, the
  # search that moves a todo under another, Upcoming, a list and Upcoming with todos selected and the
  # selection's bar (once with its tag picker open), the Logbook, search, and the desk being arranged,
  # each light and dark. The add sheet is also photographed with a picker where the keyboard
  # sits (when, horizon, tags, the nudges inside when), with a title long enough to be cut and
  # with its description being written, the todo's screen with a picker raised over it, and
  # search before anything is typed.
  # The fixture's desk has five cards under one section. The add sheets open with their words
  # typed and the keyboard down, so the words and their chips are what is photographed; the
  # keyboard's first-use tip is marked seen for any sheet that does raise it.
  xcrun simctl spawn "$udid" defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true || true
  todos_screen() {
    # `screenshot` sets the global `name`; a name of this function's own keeps the dark shot's.
    local shot=$1 facts=$2
    shift 2
    for look in light dark; do
      xcrun simctl ui "$udid" appearance "$look"
      screenshot "todos-$shot-$look" "$@"
      for fact in $facts; do fact_assert "todos-$shot-$look" "${fact%%=*}" "${fact#*=}"; done
      xcrun simctl terminate "$udid" "$bundle" || true
    done
  }
  todos_screen home-split "todosPage=Today todosDeskMode=split todosDeskCards=5" -PaiFixtureRoute todos
  todos_screen home-bar "todosDeskMode=bar" -PaiFixtureRoute todos -PaiFixtureTodosDesk bar
  todos_screen home-desk "todosDeskMode=desk todosDeskAddHere=2" -PaiFixtureRoute todos -PaiFixtureTodosDesk desk
  todos_screen view "todosPage=Home todosDeskMode=bar" -PaiFixtureRoute todosView
  todos_screen list "todosPage=Personal todosDeskMode=bar" -PaiFixtureRoute todosList
  todos_screen groceries "todosPage=Groceries" -PaiFixtureRoute todosGroceries
  todos_screen checklist "todosPage=Personal" -PaiFixtureRoute todosList -PaiFixtureTodosExpand
  todos_screen add "todosPage=Today todosAddMode=line todosAddWords=5 todosAddDefaults=0 todosAddChips=3 todosAddMarks=3 todosAddHorizon=Next" -PaiFixtureRoute todos -PaiFixtureTodosAdd "Buy stamps tomorrow #errand p1"
  todos_screen add-description "todosAddMode=line todosAddDescription=open" -PaiFixtureRoute todos -PaiFixtureTodosAdd "Buy stamps" -PaiFixtureTodosDetails "Two books of ten, the ones with the lighthouse."
  todos_screen add-no-date "todosAddMode=line todosAddDefaults=0 todosAddChips=1" -PaiFixtureRoute todos -PaiFixtureTodosAdd "Read Dune no date"
  todos_screen describe "todosAddMode=describe todosAddWords=11" -PaiFixtureRoute todos -PaiFixtureTodosDescribe "Buy stamps tomorrow and then call the plumber about the boiler"
  todos_screen add-when "todosAddPicker=when todosPicker=when todosAddChips=3 todosAddDefaults=1" -PaiFixtureRoute todos -PaiFixtureTodosAdd "Buy stamps #errand p1" -PaiFixtureTodosPicker when
  todos_screen add-horizon "todosAddPicker=horizon todosPicker=horizon" -PaiFixtureRoute todos -PaiFixtureTodosAdd "Buy stamps" -PaiFixtureTodosPicker horizon
  todos_screen add-tags "todosAddPicker=tags todosPicker=tags" -PaiFixtureRoute todosView -PaiFixtureTodosAdd "Buy stamps" -PaiFixtureTodosPicker tags
  todos_screen add-nudge "todosAddPicker=when todosPicker=nudge" -PaiFixtureRoute todos -PaiFixtureTodosAdd "Buy stamps tomorrow" -PaiFixtureTodosPicker nudge
  todos_screen add-long "todosAddMode=line todosAddDimmed=1" -PaiFixtureRoute todos -PaiFixtureTodosAdd "$(printf 'Ask the landlord whether the bike cellar gets a second key %.0s' 1 2 3 4 5 6 7 8 9 10)"
  todos_screen sheet-nudges "todosSheet=T-9 todosPicker=nudge todosDefaultNudges=1" -PaiFixtureRoute todosList -PaiFixtureTodosOpen -PaiFixtureTodosWhen
  todos_screen sheet-when "todosSheet=T-9 todosPicker=when" -PaiFixtureRoute todosList -PaiFixtureTodosOpen -PaiFixtureTodosPicker when
  todos_screen browse "todosBrowse=7,1,3" -PaiFixtureRoute todosBrowse
  todos_screen sheet "todosSheet=T-9 todosDescriptionBlocks=3 todosSubtasks=4 todosFiles=2" -PaiFixtureRoute todosList -PaiFixtureTodosOpen
  todos_screen subtask-add "todosSheet=T-9 todosAddChips=2 todosAddHorizon=Next" -PaiFixtureRoute todosList -PaiFixtureTodosOpen -PaiFixtureTodosSubtask "Pack the charger p1 #travel"
  todos_screen switcher "todosSwitcherFirst=Groceries" -PaiFixtureRoute todos -PaiFixtureTodosSwitch Groc
  todos_screen settings "todosSettings=all" -PaiFixtureRoute todos -PaiFixtureTodosSettings all
  todos_screen settings-general "todosSettings=general todosSettingsZone=Europe/Berlin" -PaiFixtureRoute todos -PaiFixtureTodosSettings general
  todos_screen settings-nudges "todosSettings=nudges todosSettingsNudges=2" -PaiFixtureRoute todos -PaiFixtureTodosSettings nudges
  todos_screen settings-lists "todosSettings=lists todosSettingsLists=3" -PaiFixtureRoute todos -PaiFixtureTodosSettings lists
  todos_screen settings-tags "todosSettings=tags todosSettingsTags=8" -PaiFixtureRoute todos -PaiFixtureTodosSettings tags
  todos_screen settings-views "todosSettings=views todosSettingsViews=8" -PaiFixtureRoute todos -PaiFixtureTodosSettings views
  todos_screen settings-view-new "todosSettingsView=new" -PaiFixtureRoute todos -PaiFixtureTodosSettings view-new
  todos_screen add-files "todosAddMode=line todosAddFiles=30" -PaiFixtureRoute todos -PaiFixtureTodosAdd "Send the scans" -PaiFixtureTodosFiles 30
  todos_screen sheet-move "todosSheet=T-9" -PaiFixtureRoute todosList -PaiFixtureTodosOpen -PaiFixtureTodosPicker parent -PaiFixtureTodosSearch plumber
  todos_screen tick-undo "todosUndoToast=shown" -PaiFixtureRoute todos -PaiFixtureTodosTick
  todos_screen upcoming "todosPage=Upcoming" -PaiFixtureRoute todosUpcoming
  todos_screen select "todosPage=Personal todosSelected=3" -PaiFixtureRoute todosList -PaiFixtureTodosSelect 3
  todos_screen select-tags "todosSelected=2 todosPicker=tags" -PaiFixtureRoute todosList -PaiFixtureTodosSelect 2 -PaiFixtureTodosPicker tags
  todos_screen select-upcoming "todosPage=Upcoming todosSelected=2" -PaiFixtureRoute todosUpcoming -PaiFixtureTodosSelect 2
  todos_screen logbook "todosPage=Logbook todosDayRows=7" -PaiFixtureRoute todosLogbook
  todos_screen search "todosSearchHits=1" -PaiFixtureRoute todosSearch -PaiFixtureTodosSearch plumber
  todos_screen search-empty "todosSearchRecents=3" -PaiFixtureRoute todosSearch
  todos_screen desk-arrange "todosDeskMode=desk" -PaiFixtureRoute todos -PaiFixtureTodosDesk desk -PaiFixtureTodosArrange
  xcrun simctl ui "$udid" appearance dark
fi

if want reminders-feed; then
  # The feed with its reminder row (name chip, "open reminder"),.
  screenshot reminders-feed -PaiFixtureRoute notifications
  fact_assert reminders-feed notificationKinds "agent,reminder,agent,alert,agent,agent,alert"
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want reminders-scheduler; then
  # The Scheduler on its reminder list (five reminders: place, Home Assistant, two scripts, one
  # fired) and the detail of the polling script (state, limits, last result, script, history).
  screenshot reminders-list -PaiFixtureRoute schedulerList -PaiFixtureSchedulerSection reminders
  fact_assert reminders-list reminderRows "door-bins,office-library-book,page-date,status-page,parcel-pickup"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot reminder-detail -PaiFixtureRoute reminder
  fact_assert reminder-detail reminderDetail "page-date armed"
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want me-where; then
  # The day detail's Where line over invented places: four stays, no gaps.
  screenshot me-where -PaiFixtureRoute me -PaiFixtureMeTab days -PaiFixtureScrollTo meDayDetail
  fact_assert me-where meWhere "stays=4 gaps=false"
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want report-bar; then
  # A report that came from a session: the session's message bar under the page, with the chip
  # that says the stored answer goes with the message.
  screenshot report-bar -PaiFixtureRoute report
  fact_assert report-bar reportBar answers
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want scheduler-task-push; then
  # The task form's push setting, below the fold of the plain `schedulerTask` screenshot.
  screenshot scheduler-task-push -PaiFixtureRoute schedulerTask -PaiFixtureScrollTo taskNotifyPush
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want settings-notes-cache; then
  # The notes cache section, below the fold of the plain `settings` screenshot, holding
  # the seeded cache.
  screenshot settings-notes-cache -PaiFixtureRoute settings -PaiFixtureSettingsCategory thisPhone \
    -PaiFixtureNotesCacheSeeded -PaiFixtureScrollTo notesCache
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want note-uncached-online; then
  # A note opened online under an id the corpus holds besides the rich note: the router
  # answers each note under its own id, so this photographs the Wikilink note, never the
  # Engram one.
  screenshot note-uncached-online -PaiFixtureRoute noteUncached
  xcrun simctl terminate "$udid" "$bundle" || true
fi

while IFS= read -r name; do
  [ -n "$name" ] && want "$name" routes || continue
  screenshot "$name" -PaiFixtureRoute "$name"
  [ "$name" = "subagentSession" ] && fact_assert "$name" composer subagent-bar
  xcrun simctl terminate "$udid" "$bundle" || true
done <<< "$names"

if want notes-offline; then
  # The notes without a connection. `-PaiFixtureOffline` fails every request the way
  # URLSession does in flight mode; the seed flags put the fixture index, note, files and an
  # unsynced edit on disk as if opened before. `/notes/cache` answers what the store holds,
  # and `/notes/offline` + `/notes/sync` take the edit back online the way the network
  # returning does.
  notes_assert() {
    label="$1"; file="$2"; shift 2
    python3 - "$file" "$@" <<'PY' || { echo "::error::$label: see $file"; fail=1; }
import json, sys
state = json.load(open(sys.argv[1]))
for check in sys.argv[2:]:
    if not eval(check, {}, {"s": state}):
        print(f"failed: {check}")
        print(json.dumps(state, indent=2))
        sys.exit(1)
print("ok:", ", ".join(sys.argv[2:]))
PY
  }

  screenshot notes-offline -PaiFixtureRoute notes -PaiFixtureOffline -PaiFixtureNotesCacheSeeded
  curl -sS --max-time 5 "http://127.0.0.1:8765/notes/cache" -o artifacts/notes-cache-notes-offline.json || true
  notes_assert notes-offline artifacts/notes-cache-notes-offline.json "s['isOffline']" "s['indexCount'] == 3"
  xcrun simctl terminate "$udid" "$bundle" || true

  screenshot note-offline -PaiFixtureRoute note -PaiFixtureOffline -PaiFixtureNotesCacheSeeded \
    -PaiFixtureNotePendingEdit
  curl -sS --max-time 5 "http://127.0.0.1:8765/notes/cache" -o artifacts/notes-cache-note-offline.json || true
  notes_assert note-offline artifacts/notes-cache-note-offline.json \
    "s['isOffline']" "len([p for p in s['pending'] if p['kind'] == 'body']) == 1"
  curl -sS --max-time 5 -X POST "http://127.0.0.1:8765/notes/offline?on=false" || true
  curl -sS --max-time 70 -X POST "http://127.0.0.1:8765/notes/sync" -o artifacts/notes-sync-note-offline.json || true
  curl -sS --max-time 5 "http://127.0.0.1:8765/notes/cache" -o artifacts/notes-cache-note-offline-synced.json || true
  notes_assert note-offline-synced artifacts/notes-cache-note-offline-synced.json \
    "s['pending'] == []" "s['lastSyncReport']['replayed'] == 1"
  sleep 3
  sim_screenshot "$udid" artifacts/screen-note-offline-synced.png || true
  xcrun simctl terminate "$udid" "$bundle" || true

  # The conflict policy: the first save meets a 409 with a different body, and the edit is
  # written over it, marked source=offline, without asking.
  screenshot note-offline-conflict -PaiFixtureRoute note -PaiFixtureOffline -PaiFixtureNotesCacheSeeded \
    -PaiFixtureNotePendingEdit -PaiFixtureNoteConflict
  curl -sS --max-time 5 -X POST "http://127.0.0.1:8765/notes/offline?on=false" || true
  curl -sS --max-time 70 -X POST "http://127.0.0.1:8765/notes/sync" -o artifacts/notes-sync-note-offline-conflict.json || true
  notes_assert note-offline-conflict artifacts/notes-sync-note-offline-conflict.json \
    "s['conflictsResolved'] == 1" "s['stillPending'] == 0"
  curl -sS --max-time 3 "http://127.0.0.1:8765/logs?level=info&limit=200" \
    -o artifacts/logs-note-offline-conflict-synced.json || true
  grep -q 'source=offline' artifacts/logs-note-offline-conflict-synced.json \
    || { echo "::error::note-offline-conflict: no log line for the write carrying source=offline"; fail=1; }
  sleep 3
  sim_screenshot "$udid" artifacts/screen-note-offline-conflict-synced.png || true
  xcrun simctl terminate "$udid" "$bundle" || true

  # A note never opened on this phone, opened without a connection.
  screenshot note-offline-unavailable -PaiFixtureRoute noteUncached -PaiFixtureOffline
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want jump-landing; then
  # Where a jump into UNLOADED history actually lands — a screenshot alone shows the
  # result, not the row id the controller computed, so this is what proves the .replaced
  # window path (the fault that shipped) rather than only the ordinary .prepended one
  # (the path that always worked, and the one every other screenshot here happens to
  # exercise since nothing else jumps far from the loaded tail). `boundary` kind search
  # lands on the session's own first row and its one `system`/`compact` row — both several
  # hundred ids clear of the fixture corpus's own tail window by construction.
  screenshot jump-landing -PaiFixtureRoute session -PaiFixtureSearchKind boundary
  landed=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/landing.json; then
      top=$(python3 -c "import json; print(json.load(open('artifacts/landing.json')).get('topVisibleRowId'))")
      if [ "$top" != "None" ]; then landed=1; break; fi
    fi
    sleep 2
  done
  xcrun simctl terminate "$udid" "$bundle" || true
  if [ "$landed" -ne 1 ]; then
    echo "::warning::jump-landing: /transcript/landing never reported a row — see landing.json"
    fail=1
  else
    # The two boundary hits in the fixture corpus (search-virtualization design's own
    # "the around page, and merge-or-replace") — landing anywhere else means the .replaced
    # path is still reading stale offsets.
    python3 -c "
import json, sys
top = json.load(open('artifacts/landing.json'))['topVisibleRowId']
ok = top in (9001, 9042) or 9001 <= top <= 9010 or 9033 <= top <= 9042
print(f'landed on row {top}')
sys.exit(0 if ok else 1)
" || { echo "::error::jump-landing: landed far from both boundary targets (9001, 9042) — see landing.json"; fail=1; }
  fi
fi

if want deep-link-landing; then
  # A tapped notification opening a session at a message far older than its tail — the
  # jump made inside the transcript's own first load, not on a settled screen the way the
  # search jump above is. 9020 is several hundred ids clear of the fixture tail, so this is
  # the `.replaced` landing. `deepLinkLandedMessageId` outlives the ring's fade, so polling
  # it cannot race the ring the way reading `highlightedMessageId` would.
  screenshot deep-link-landing -PaiFixtureRoute session -PaiFixtureJumpMessage 9020
  linked=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/deep-link-landing.json; then
      got=$(python3 -c "import json; print(json.load(open('artifacts/deep-link-landing.json')).get('deepLinkLandedMessageId'))")
      if [ "$got" != "None" ]; then linked=1; break; fi
    fi
    sleep 2
  done
  if [ "$linked" -ne 1 ]; then
    echo "::error::deep-link-landing: no deep-link landing was reported — see deep-link-landing.json"
    fail=1
  else
    python3 -c "
import json, sys
s = json.load(open('artifacts/deep-link-landing.json'))
top = s['topVisibleRowId'] or 0
print('landed on', s['deepLinkLandedMessageId'], 'with top row', top)
sys.exit(0 if s['deepLinkLandedMessageId'] == 9020 and 9001 <= top <= 9020 else 1)
" || { echo "::error::deep-link-landing: did not land on 9020 — see deep-link-landing.json"; fail=1; }

    # The landing's own window is not at the tail (9020 is far short of the corpus's
    # 9900), so it pages itself forward on its own once the reader's position sits near
    # its loaded edge — legitimate, and not what this checks. What it checks is whether
    # the edge-follow latch wrongly treats the bottom of that still-incomplete window as
    # the live edge while the catch-up runs: it then chases every page `loadNewer()`
    # brings in with its own `scrollToBottom`, walking the reader toward the corpus's true
    # tail in several steps — the bug a notification jump into old history hit. A read
    # right after landing cannot see that drift; only a read after it has had time to
    # happen can.
    sleep 5
    sim_screenshot "$udid" artifacts/screen-deep-link-landing-settled.png || true
    curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/deep-link-landing-settled.json || true
    python3 -c "
import json, sys
s = json.load(open('artifacts/deep-link-landing-settled.json'))
top = s['topVisibleRowId'] or 0
print('after settle: top row', top)
sys.exit(0 if 9001 <= top <= 9020 else 1)
" || { echo "::error::deep-link-landing: drifted away from row 9020 during the settle window — see deep-link-landing-settled.json"; fail=1; }
  fi
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want warm-jump; then
  # A notification tapped while its session is already open and following the live edge
  # — the path a phone takes coming back from the lock screen. 9850 is inside the fixture
  # tail, so the jump animates from the bottom rather than replacing the window. The
  # fixture stream ends after each pass and reconnects every couple of seconds, replaying
  # its `init`, and every replay asks the transcript to stick to the bottom if it is
  # following — so a jump that re-armed following on its way out is carried back down
  # within the settle window. Both the position and the follow state are read, since a
  # position that holds only because no event arrived in time proves nothing.
  screenshot warm-jump -PaiFixtureRoute session
  ready=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/warm-jump-before.json; then
      top=$(python3 -c "import json; print(json.load(open('artifacts/warm-jump-before.json')).get('topVisibleRowId'))")
      if [ "$top" != "None" ]; then ready=1; break; fi
    fi
    sleep 2
  done
  if [ "$ready" -ne 1 ]; then
    echo "::error::warm-jump: the transcript never reported a row before the jump — see warm-jump-before.json"
    fail=1
  else
    curl -sS --max-time 3 -X POST "http://127.0.0.1:8765/transcript/jump?messageId=9850" || true
    sleep 10
    sim_screenshot "$udid" artifacts/screen-warm-jump-settled.png || true
    curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/warm-jump-settled.json || true
    python3 -c "
import json, sys
before = json.load(open('artifacts/warm-jump-before.json'))
s = json.load(open('artifacts/warm-jump-settled.json'))
top = s['topVisibleRowId'] or 0
print('before jump: top row', before['topVisibleRowId'], 'following', before.get('isFollowingLiveEdge'))
print('after settle: landed', s['deepLinkLandedMessageId'], 'top row', top, 'following', s.get('isFollowingLiveEdge'))
ok = s['deepLinkLandedMessageId'] == 9850 and 9830 <= top <= 9850 and s.get('isFollowingLiveEdge') is False
sys.exit(0 if ok else 1)
" || { echo "::error::warm-jump: did not stay on row 9850 — see warm-jump-settled.json"; fail=1; }
  fi
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want clamped-landing; then
  # A cold landing on a target in the last screen is clamped onto the bottom, so the one
  # scroll sample it produces reads "at the edge". Nothing visibly moves in the fixture —
  # no new content arrives below — so the follow state is the only witness: the next
  # message to arrive on a real session would otherwise carry the reader off the target.
  screenshot clamped-landing -PaiFixtureRoute session -PaiFixtureJumpMessage 9899
  clamped=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/clamped-landing.json; then
      got=$(python3 -c "import json; print(json.load(open('artifacts/clamped-landing.json')).get('deepLinkLandedMessageId'))")
      if [ "$got" != "None" ]; then clamped=1; break; fi
    fi
    sleep 2
  done
  if [ "$clamped" -ne 1 ]; then
    echo "::error::clamped-landing: no deep-link landing was reported — see clamped-landing.json"
    fail=1
  else
    sleep 5
    curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/clamped-landing-settled.json || true
    python3 -c "
import json, sys
s = json.load(open('artifacts/clamped-landing-settled.json'))
print('clamped landing on', s['deepLinkLandedMessageId'], 'following', s.get('isFollowingLiveEdge'))
sys.exit(0 if s['deepLinkLandedMessageId'] == 9899 and s.get('isFollowingLiveEdge') is False else 1)
" || { echo "::error::clamped-landing: a landing clamped onto the bottom re-armed following — see clamped-landing-settled.json"; fail=1; }
  fi
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want note-refused; then
  # An edit the server refused (the note was deleted elsewhere), seeded in the outbox. It
  # stays on the simulator for every launch after it, and a note holds one edit, so these
  # screens come after every other note screenshot. The editor shows the failed-save
  # badge (its Try again / Copy / Discard menu opens only on a tap, so it stays
  # unphotographed); Settings lists the text under "Not saved".
  screenshot note-refused-edit -PaiFixtureRoute note -PaiFixtureNotesCacheSeeded -PaiFixtureNoteRefusedEdit
  curl -sS --max-time 5 "http://127.0.0.1:8765/notes/cache" -o artifacts/notes-cache-note-refused-edit.json || true
  notes_assert note-refused-edit artifacts/notes-cache-note-refused-edit.json \
    "len([p for p in s['pending'] if p['kind'] == 'body' and p['state'] == 'failed']) == 1"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot settings-not-saved -PaiFixtureRoute settings -PaiFixtureSettingsCategory thisPhone \
    -PaiFixtureNotesCacheSeeded -PaiFixtureNoteRefusedEdit -PaiFixtureScrollTo notSaved
  xcrun simctl terminate "$udid" "$bundle" || true
fi

# Settings, every page, for the owner and for a guest. The list is photographed first and its own
# report (the pages this role has) is what is asserted, so a page missing for one role fails here.
settings_pages() {
  local role=$1 pages=$2 flag=() page
  [ "$role" = guest ] && flag=(-PaiFixtureRole guest)
  screenshot "settings-$role-list" -PaiFixtureRoute settings "${flag[@]}"
  fact_assert "settings-$role-list" settingsCategories "$pages"
  xcrun simctl terminate "$udid" "$bundle" || true
  for page in $(echo "$pages" | tr ',' ' '); do
    screenshot "settings-$role-$page" -PaiFixtureRoute settings -PaiFixtureSettingsCategory "$page" "${flag[@]}"
    fact_assert "settings-$role-$page" settingsCategory "$page"
    xcrun simctl terminate "$udid" "$bundle" || true
  done
}

# The start screen with the apps in the fixture person's order (shown directly, then More), the
# same for a guest, the Apps list over the session list's place in the order, and the list that
# arranges them in settings.
if want apps; then
  screenshot apps-start -PaiFixtureRoute apps
  fact_assert apps-start appsPinned "sessions,notes,todos,me"
  fact_assert apps-start appsMore "quick-actions,arc,scheduler,alarm,weather,canteen,camera-import,usage,decisions,reports,browser"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot apps-start-guest -PaiFixtureRoute apps -PaiFixtureRole guest
  fact_assert apps-start-guest appsPinned "sessions,todos"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot app-order -PaiFixtureRoute settings -PaiFixtureSettingsCategory appearance -PaiFixtureAppOrder
  fact_assert app-order appOrder "sessions,notes,todos,me,---,quick-actions,arc,scheduler,alarm,weather,canteen,camera-import,usage,decisions,reports,browser"
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want settings-owner; then
  settings_pages owner "microphone,notifications,voices,appearance,location,devices,history,thisPhone,system,alerts,mail,providers,models,integrations,voiceSound,agents,people,diagnostics"
fi

if want settings-guest; then
  settings_pages guest "microphone,notifications,voices,appearance,location,devices,history,thisPhone"
fi

# Sleep mode: the screen that replaces the session list (the start screen's order without the
# apps put away), Quick Actions inside the window with its layout unchanged and the session
# actions put away, the start screen inside the window, the setup screen, and the PIN pad.
if want sleep-mode; then
  screenshot sleep-screen -PaiFixtureSleep on
  fact_assert sleep-screen sleepScreen on
  fact_assert sleep-screen sleepTiles "notes,todos,me,quick-actions,alarm,weather,canteen,camera-import"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot sleep-screen-guest -PaiFixtureSleep on -PaiFixtureRole guest
  fact_assert sleep-screen-guest sleepTiles "todos,quick-actions,alarm,weather,camera-import"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot sleep-quick-actions -PaiFixtureSleep on -PaiFixtureRoute quickActions
  fact_assert sleep-quick-actions quickActionsGrid "selfReport,me,more,computer,home,ultrafast,mailverdict,homeCall,ultrafastCamera,findNote,newNote,ultrafastCall,notes,alarm,weather"
  fact_assert sleep-quick-actions quickActionsPutAway "computer,home,ultrafast,mailverdict,homeCall,ultrafastCamera,ultrafastCall,fastSession,fastCall,scheduler,decisions,usage"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot sleep-apps -PaiFixtureSleep on -PaiFixtureRoute apps
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot sleep-settings -PaiFixtureSleep configured -PaiFixtureRoute settings -PaiFixtureSettingsCategory notifications -PaiFixtureSleepSettings
  fact_assert sleep-settings sleepModeEnabled on
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot sleep-awake -PaiFixtureSleep configured
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if [ -z "$ONLY" ]; then
  # The same question one level out: does a whole ROW's laid-out height agree with what
  # it draws? The transcript places rows from analytic heights and never asks a cell its
  # size, so a register's chrome, a visual clamp or a trailer being off by a few points is
  # invisible everywhere else and shows up only as the reader being dragged around.
  python3 - <<'PY'
import json, pathlib, sys
reports = []
for path in sorted(pathlib.Path('artifacts').glob('rowagree-*.json')):
    if not path.stat().st_size:
        continue
    try:
        rows = json.loads(path.read_text())
    except json.JSONDecodeError:
        continue
    if rows:
        reports.append((path.name, rows))
if not reports:
    print('::error::row agreement: no screen answered with a single transcript row, so nothing was checked')
    sys.exit(1)
name, rows = max(reports, key=lambda r: len(r[1]))
worst = max(rows, key=lambda r: abs(r['delta']))
print(f"row agreement: {len(rows)} rows from {name}, worst delta {worst['delta']:.2f}pt on message {worst['messageId']}")
# A point of slack for fractional font metrics; anything past that is a real disagreement.
if abs(worst['delta']) > 1.0:
    print(f"::error::row {worst['messageId']} measures {worst['measured']:.2f} and draws {worst['rendered']:.2f}")
    sys.exit(1)
PY
fi

# A probe is a branch-local script run with everything above in scope, so a question nobody
# has a section for needs no change to the workflow.
if [ -n "${PROBE:-}" ]; then
  # shellcheck source=/dev/null
  . "$PROBE"
fi

[ "$fail" -eq 0 ] || { echo 'one or more screens failed — see the warnings above'; exit 1; }
