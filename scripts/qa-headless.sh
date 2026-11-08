#!/bin/zsh
# Headless UI regression for the installed T3 Mini.app, driven with synthetic CGEvents.
# Needs: Accessibility permission for the terminal (to post events). No Screen Recording needed:
# state is read from the app's own snapshot (open -g t3mini://debug → ~/Library/Logs/T3Mini/state.json),
# which this script enables for the run and turns off again.
# Uses the main display's size; works best on a display of at least 1440x900.
# Starts small throwaway T3 threads ("T3 Mini QA …") with your most recently used model when it needs Ready
# cards (they cost a few tokens; archive them afterwards). Pick the project with T3MINI_QA_PROJECT
# (project title or id; default "No project", else your most recent project).
# Do not touch the mouse while it runs (about 2 minutes). It restores the pet to the bottom-right slot.
set -u
cd "$(dirname "$0")/.."
BIN=.build/qa; mkdir -p $BIN
for t in input wins mousepos clearmods ax; do
  [[ $BIN/$t -nt tools/qa/$t.swift ]] || swiftc -O tools/qa/$t.swift -o $BIN/$t 2>&1 | grep -v "search path" | grep error
done
I=$BIN/input
T3HOME=${T3CODE_HOME:-$HOME/.t3}; DB=$T3HOME/userdata/statev2.sqlite
pass=0; fail=0
defaults write com.t3mini.app debugSnapshot -bool true
trap 'defaults delete com.t3mini.app debugSnapshot 2>/dev/null' EXIT
snap() { open -g "t3mini://debug"; sleep 0.6; }
get() { python3 -c "import json,sys;d=json.load(open('$HOME/Library/Logs/T3Mini/state.json'));v=eval(sys.argv[1]);print(v if not isinstance(v,(list,dict)) else json.dumps(v))" "$1"; }
ctl() { snap; python3 -c "import json,sys;c=json.load(open('$HOME/Library/Logs/T3Mini/state.json'))['controls'];v=c.get(sys.argv[1]);print(int(v[0]),int(v[1])) if v else print('')" "$1"; }
check() { # name, python-expr over d
  snap
  if python3 -c "import json,sys;d=json.load(open('$HOME/Library/Logs/T3Mini/state.json'));sys.exit(0 if eval(sys.argv[1]) else 1)" "$2"; then
    echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1   ($2)"; fail=$((fail+1)); fi
}
front() { lsappinfo info -only name $(lsappinfo front) | head -1 | cut -d'"' -f2; }

# Abort if someone is using the mouse.
moves=$($BIN/mousepos | sort -u | wc -l | tr -d ' ')
[[ $moves -gt 1 ]] && { echo "Mouse is moving; not running (would fight the user)."; exit 2; }

open -g "t3mini://pet"; open -g "t3mini://show"; sleep 1
snap; read W H <<< "$(get "' '.join(str(int(x)) for x in d['screens'][0][2:4])")"   # main display, points
CX=$((W/2)); CY=$((H/2))
# Need >=2 visible throwaway "T3 Mini QA" Ready cards for the stack / card checks; start them if missing.
snap; have=$(get "sum(1 for c in d['cards'] if c['title'].startswith('T3 Mini QA') and c['state']=='ready')")
if [[ $have -lt 2 ]]; then
  WANT=${T3MINI_QA_PROJECT:-No project}
  PROJ=$(sqlite3 -readonly $DB "select project_id from projection_projects where (title='$WANT' or project_id='$WANT') and deleted_at is null limit 1")
  [[ -z "$PROJ" ]] && PROJ=$(sqlite3 -readonly $DB "select p.project_id from projection_projects p join orchestration_v2_projection_threads t on t.project_id=p.project_id where p.deleted_at is null order by t.updated_at desc limit 1")
  MODEL=$(sqlite3 -readonly $DB "select json_extract(payload_json,'$.modelSelection.instanceId')||' '||json_extract(payload_json,'$.modelSelection.model') from orchestration_v2_projection_threads where json_extract(payload_json,'$.modelSelection.model') is not null order by updated_at desc limit 1")
  for n in $(seq $have 1); do
    echo "Reply with exactly OK." | $T3HOME/bin/t3 thread start $PROJ - --provider ${${=MODEL}[1]} --model ${${=MODEL}[2]} --title "T3 Mini QA $RANDOM" >/dev/null 2>&1
  done
  for i in {1..20}; do sleep 3; snap; have=$(get "sum(1 for c in d['cards'] if c['title'].startswith('T3 Mini QA') and c['state']=='ready')"); [[ $have -ge 2 ]] && break; done
  echo "(started QA threads; $have QA cards ready)"
fi
$I click $CX $CY; sleep 0.5  # click-away: reset tray/composer
open -a Finder; sleep 1

P=($(ctl pet))
check "app visible, pet sprite loaded" "d['visible'] and d['petLoaded']"
$I move $CX $CY; sleep 0.6
check "rest: only the pet (no bar)" "not d['revealed'] and set(d['controls'])<= {'pet','greeting'}"
$I move $P[1] $((P[2] + 61 + 30)); sleep 0.5
check "proximity <40pt reveals bar (New chat + bell)" "d['revealed'] and 'bell' in d['controls'] and 'newchat' in d['controls']"
$I move $P[1] $((P[2] + 61 + 120)); sleep 1.3
check "leaving >56pt hides bar after 300ms" "not d['revealed']"
$I move $P[1] $P[2]; sleep 0.5
check "pointer on sprite plays jumping" "d['animation']=='jumping'"

$I click $P[1] $P[2]; sleep 0.9
check "click pet opens focused composer" "d['chatOpen'] and d['isKey']"
[[ "$(front)" == "Finder" ]] && { echo "PASS  composer focus doesn't activate T3 Mini (Finder stays front)"; pass=$((pass+1)); } || { echo "FAIL  front app changed to $(front)"; fail=$((fail+1)); }
$I type "qa draft"; sleep 0.3
check "typing goes to the composer" "d['draft']=='qa draft'"
$I key 51 8; $I key 53; sleep 0.5
check "Escape closes composer and gives up key" "not d['chatOpen'] and not d['isKey']"
# Typing goes back to the previous app after Escape .
open -a TextEdit; sleep 1; TE=$(lsappinfo info -only pid -app com.apple.TextEdit | grep -o '[0-9]*' | head -1)
if [[ -n "$TE" && -n "$($BIN/ax $TE 0 --focused-value 2>/dev/null; echo x)" ]]; then
  P=($(ctl pet)); $I click $P[1] $P[2]; sleep 0.8; $I key 53; sleep 0.5
  before=$($BIN/ax $TE 0 --focused-value | wc -c); $I type "zq"; sleep 0.4; after=$($BIN/ax $TE 0 --focused-value)
  if [[ "$after" == *zq* ]]; then echo "PASS  after Escape, typing returns to the previous app"; pass=$((pass+1)); $I key 51 2
  else echo "FAIL  typing after Escape did not reach TextEdit"; fail=$((fail+1)); fi
  open -a Finder; sleep 0.8
fi

$I move $P[1] $P[2]; sleep 0.5
check "compact bar: one 80x40 pill centred on the pet, 4 pt from it" "abs(d['controls']['bar'][2]-80)<2 and d['controls']['bar'][3]==40 and abs(d['controls']['bar'][0]-d['controls']['pet'][0]-d['pillShift'])<2 and abs(d['pillShift'])<1 and (abs((d['controls']['pet'][1]-d['controls']['pet'][3]/2) - (d['controls']['bar'][1]+20) - 4) < 2 if not d['anchorTop'] else abs((d['controls']['bar'][1]-20) - (d['controls']['pet'][1]+d['controls']['pet'][3]/2) - 4) < 2)"
B=($(ctl bell)); $I click $B[1] $B[2]; sleep 0.8
check "bell → tray (collapsed stack when >1 item)" "d['expanded'] and not d['listExpanded']"
if [[ $(get "len(d['cards'])") -gt 1 ]]; then
  # Toward the stack = away from the bar: wheel down (-) when the tray is below the pet, up (+) when above.
  if [[ $(get "d['anchorTop']") == "True" ]]; then TOWARD=-60; else TOWARD=60; fi
  S=($(ctl stack)); $I scroll $S[1] $S[2] $((-TOWARD)); sleep 0.6
  check "scrolling away from the stack does not expand it" "d['expanded'] and not d['listExpanded']"
  $I scroll $S[1] $S[2] $TOWARD; sleep 0.8
  check "scrolling toward the collapsed stack expands it" "d['expanded'] and d['listExpanded']"
  L=($(ctl list)); $I scroll $L[1] $L[2] $((-TOWARD)); sleep 0.8
  check "scrolling back at the list's end collapses it to the stack" "d['expanded'] and not d['listExpanded']"
  S=($(ctl stack)); $I click $S[1] $S[2]; sleep 0.8
  check "click collapsed stack → full list" "d['expanded'] and d['listExpanded'] and 'list' in d['controls']"
  B=($(ctl bell)); $I click $B[1] $B[2]; sleep 0.7
  check "bell from list → back to collapsed stack" "d['expanded'] and not d['listExpanded']"
  B=($(ctl bell)); $I click $B[1] $B[2]; sleep 0.7
  check "bell from stack → hidden" "not d['expanded']"
  B=($(ctl bell)); $I move $P[1] $P[2]; sleep 0.4; B=($(ctl bell)); $I click $B[1] $B[2]; sleep 0.7
fi
# Card hover actions + dismiss, only on throwaway "T3 Mini QA" cards.
QA=$(get "next((c['id'] for c in d['cards'] if c['title'].startswith('T3 Mini QA') and c['state']!='running'), '')")
if [[ -n "$QA" ]]; then
  open -g "t3mini://activity"; sleep 0.8; snap
  if [[ $(get "d['listExpanded']") != "True" ]]; then S=($(ctl stack)); [[ -n "${S[1]:-}" ]] && { $I click $S[1] $S[2]; sleep 0.7; }; fi
  C=($(ctl "card:$QA")); $I move $C[1] $C[2]; sleep 0.2; $I move $((C[1] + 2)) $C[2]; sleep 0.2; $I move $C[1] $C[2]; sleep 0.5
  check "hovering a card shows Reply (right) and Dismiss (top-left)" "'reply:$QA' in d['controls'] and 'dismiss:$QA' in d['controls'] and d['controls']['dismiss:$QA'][0] < d['controls']['card:$QA'][0]-100"
  # Right-click → Mute chat (menu: Open, Reply, Peek, —, Mute, Dismiss)
  $I rclick $C[1] $C[2]; sleep 0.6; $I key 125 4; $I key 36; sleep 0.8
  check "right-click → Mute chat hides the card and its count" "'$QA' in d['muted'] and all(c['id']!='$QA' for c in d['cards'])"
  open -g "t3mini://unmute"; sleep 0.8
  # Right-click while typing in the composer keeps the field focused and the user's app frontmost.
  FRONT=$(front); P=($(ctl pet)); $I click $P[1] $P[2]; sleep 0.8; $I type "keep"; sleep 0.2
  open -g "t3mini://activity"; sleep 0.6; C=($(ctl "card:$QA")); [[ -z "${C[1]:-}" ]] && { S=($(ctl stack)); C=($S[1] $S[2]); }
  $I rclick $C[1] $C[2]; sleep 0.6; $I key 53; sleep 0.6
  check "right-click while typing keeps the composer focused" "d['chatOpen'] and d['isKey'] and d['draft']=='keep'"
  [[ "$(front)" == "$FRONT" ]] && { echo "PASS  right-click while typing leaves $FRONT frontmost"; pass=$((pass+1)); } || { echo "FAIL  frontmost changed to $(front)"; fail=$((fail+1)); }
  $I key 51 4; $I key 53; sleep 0.4; open -g "t3mini://activity"; sleep 0.6
  check "unmuting brings the card back" "any(c['id']=='$QA' for c in d['cards'])"
  if [[ $(get "d['listExpanded']") != "True" ]]; then S=($(ctl stack)); [[ -n "${S[1]:-}" ]] && { $I click $S[1] $S[2]; sleep 0.7; }; fi
  C=($(ctl "card:$QA")); hover() { $I move $(( $1 + 60 )) $(( $2 + 10 )); sleep 0.2; $I move $1 $2; sleep 0.2; $I move $(( $1 + 2 )) $2; sleep 0.2; $I move $1 $2; sleep 0.5; }; hover $C[1] $C[2]
  X=($(ctl "dismiss:$QA")); $I click $X[1] $X[2]; sleep 0.8
  check "Dismiss removes the card" "all(c['id']!='$QA' for c in d['cards'])"
  $I click $((W/6)) $((H/4)); sleep 0.5
fi
$I click $((W/6)) $((H/4)); sleep 0.6
check "outside click closes the tray" "not d['expanded']"

$I move $P[1] $P[2]; sleep 0.4; N=($(ctl newchat)); $I click $N[1] $N[2]; sleep 0.8
check "New chat button opens the composer" "d['chatOpen'] and d['isKey']"
$I key 53; sleep 0.4

DX=$((W*36/100)); DY=$((H*46/100))
$I drag $P[1] $P[2] $DX $DY; sleep 0.9
check "plain drop stays where released" "abs(d['petFrame'][0]+d['petFrame'][2]/2-$DX)<10 and abs(($H-d['petFrame'][1]-d['petFrame'][3]/2)-$DY)<10"
P=($(ctl pet)); $I dragopt $P[1] $P[2] $((W/4)) $((H*3/4)); sleep 0.9
check "Option-drop lower-left snaps to the bottom-left slot" "d['petFrame'][0]<=20 and d['anchorLeading'] and not d['anchorTop']"
P=($(ctl pet)); $I dragopt $P[1] $P[2] $((CX + 40)) $((H*28/100)); sleep 0.9
check "Option-drop upper-middle snaps to top-centre slot; tray opens below" "d['anchorTop'] and abs(d['petFrame'][0]+d['petFrame'][2]/2-$CX)<4"

# Click-through: an empty spot of the overlay must not receive the click.
P=($(ctl pet)); open -a Finder; sleep 0.8
defaults write com.t3mini.app traceEvents -bool true; : > ~/Library/Logs/T3Mini/trace.log
$I click $((P[1] - 250)) $((P[2] - 250)); sleep 0.5
n=$(grep -c "type=1 " ~/Library/Logs/T3Mini/trace.log); defaults delete com.t3mini.app traceEvents
[[ $n -eq 0 ]] && { echo "PASS  transparent area passes clicks through"; pass=$((pass+1)); } || { echo "FAIL  overlay swallowed $n click(s)"; fail=$((fail+1)); }

open -g "t3mini://hide"; sleep 0.6; $I hotkey; sleep 0.9
check "Control+Option+P shows T3 Mini and focuses the composer" "d['visible'] and d['chatOpen'] and d['isKey']"
$I key 53; sleep 0.3

open -g "t3mini://mini"; sleep 0.8
check "Mini mode: no pet, compact bar with New chat + bell" "d['mode']=='mini' and 'pet' not in d['controls'] and 'newchat' in d['controls'] and 'bell' in d['controls']"
open -g "t3mini://pet"; sleep 0.8

# restore bottom-right slot
P=($(ctl pet)); $I dragopt $P[1] $P[2] $((W - 60)) $((H - 70)); sleep 0.8
$BIN/clearmods >/dev/null
echo "----"; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
