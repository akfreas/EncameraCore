#!/usr/bin/env bash
#
# Full local pre-release smoke test.
#
# Runs every automated suite this repo has, in one pass, on this machine, so a
# release can be signed off from inspectable local output rather than from CI:
#
#   unit-core       EncameraCore's own unit tests             simulator
#   unit-app        App-level unit tests (Tests/)             simulator
#   unit-analytics  EncameraAnalytics package tests           simulator
#   ui-sim          The whole XCUITest suite                  simulator
#   device-smoke    The same XCUITest suite plus the          handset
#                   ENCAMERA_DEVICE_SMOKE-gated suites
#
# Why both ui-sim and device-smoke: the device-only suites (camera orientation,
# camera zoom startup, limited photo access) hard-gate on ENCAMERA_DEVICE_SMOKE
# and skip themselves under every other scheme, so a green simulator run proves
# nothing about them. Only the device phase runs them. The simulator run stays
# because it is the cheap, repeatable one.
#
# The console shows only what passed and what failed (formatted by xcpretty).
# The full xcodebuild output, the xcpretty log, a JUnit report and an .xcresult
# bundle for every phase land in a gitignored log directory, named at the end.
#
# Usage:
#   EncameraCore/Sources/EncameraCore/scripts/pre-release-smoke.sh [options]
#
# Options:
#   --list                  List the phases and exit.
#   --only  a,b,c           Run only these phases.
#   --skip  a,b,c           Run everything except these phases.
#   --skip-device           Shorthand for --skip build-device,device-smoke.
#   --device UDID           Run the device phases on this handset instead of the
#                           rig primary. Implies --single-device.
#   --single-device         Do not require the full two-phone rig; run the device
#                           phases on the primary phone alone.
#   --sim NAME              Simulator model name (default: iPhone 17 Pro). It is
#                           resolved to the newest installed runtime carrying
#                           that model.
#   --sim-udid UDID         Use this exact simulator instead of resolving a name.
#   --reset-sim-privacy     simctl privacy reset photos on the simulator first.
#                           Use when the UI suite trips over a stuck denial.
#   --regenerate            Run `xcodegen generate` before building.
#   --clean                 Delete the shared derived data first (slow, honest).
#   --fail-fast             Stop at the first failing phase (default: run all).
#   --log-dir DIR           Where to write this run's logs.
#   -h, --help              This help.
#
# The device phases refuse to start unless BOTH rig phones — Encamera iPhone and
# Red phone — report as connected. The suites here drive only the primary phone,
# but the two share one disposable test iCloud account, so a half-attached rig
# changes what a CloudKit or keychain suite is actually exercising. Pass
# --single-device when you knowingly want the primary phone alone.
#
# Before the device phases, on each attached handset:
#   * unlock it and set Auto-Lock to Never — a lock mid-run masquerades as a
#     product failure,
#   * grant camera and photo permission to the app,
#   * keep it plugged in.
#
# Exit code: 0 only if every selected phase passed with at least one test run.
#
#:END-HELP

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PROJECT="$REPO_ROOT/Encamera.xcodeproj"
ANALYTICS_PACKAGE="$REPO_ROOT/EncameraAnalytics"

# Derived data is shared across runs on purpose: a full smoke is long enough
# without recompiling the world every time. --clean opts out.
LOG_ROOT="$REPO_ROOT/build/pre-release-smoke"
DERIVED_DATA="$LOG_ROOT/derived-data"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$LOG_ROOT/run-$RUN_STAMP"

SIM_NAME="iPhone 17 Pro"
SIM_UDID=""
SIM_RUNTIME=""
DEVICE_UDID="${DEVICE_UDID:-00008101-001A4CE900782C3A}"   # Encamera iPhone, iPhone 12 Pro

# The two-phone rig. The device suites on this branch all run on the primary
# phone, but the rig is checked as a unit on purpose: both phones share one
# disposable test iCloud account, so a CloudKit or keychain suite run with only
# half the rig attached is a different experiment from the one the suites were
# written against — and the Red phone is where a destructive test's blast radius
# shows up. --single-device opts out.
RIG_DEVICES=(
  "Encamera iPhone|00008101-001A4CE900782C3A"
  "Red phone|00008030-000408141E6B402E"
)
REQUIRE_RIG=1

RESET_SIM_PRIVACY=0
REGENERATE=0
CLEAN=0
FAIL_FAST=0
STOPPED=0

# id|destination kind|human description
PHASES=(
  "build-sim|sim|Build all test bundles for the simulator"
  "unit-core|sim|EncameraCore unit tests"
  "unit-app|sim|App unit tests (Tests/)"
  "unit-analytics|sim|EncameraAnalytics package tests"
  "ui-sim|sim|XCUITest suite on the simulator"
  "build-device|device|Build the test bundles for the handset"
  "device-smoke|device|XCUITest suite + device-only suites on the handset"
)

ONLY=""
SKIP=""

# ---------------------------------------------------------------- formatting

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

WIDTH=74
HRULE="$(printf '─%.0s' $(seq 1 "$WIDTH"))"

rule() { printf '%s\n' "${DIM}${HRULE}${RESET}"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '%s\n' "${YELLOW}  ! $*${RESET}"; }
fail() { printf '%s\n' "${RED}  ✗ $*${RESET}"; }
ok()   { printf '%s\n' "${GREEN}  ✓ $*${RESET}"; }

banner() {
  # Padded by character count, not by printf's %-Ns: the titles carry em dashes
  # and printf pads by bytes, which knocks the right border two columns out.
  local text="$1" pad=$(( WIDTH - 2 - ${#1} ))
  (( pad < 0 )) && pad=0
  printf '\n%s\n' "${BOLD}${BLUE}╭${HRULE}╮${RESET}"
  printf '%s%s%*s%s\n' \
    "${BOLD}${BLUE}│${RESET} ${BOLD}" "$text" "$pad" "" "${RESET} ${BOLD}${BLUE}│${RESET}"
  printf '%s\n'   "${BOLD}${BLUE}╰${HRULE}╯${RESET}"
}

phase_header() {
  printf '\n%s\n' "${BOLD}▶ $1${RESET}  ${DIM}$2${RESET}"
  rule
}

usage() { sed -n '2,/^#:END-HELP/p' "$0" | grep -v '^#:END-HELP' | sed 's/^#\{0,1\} \{0,1\}//'; }

# ------------------------------------------------------------------- options

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      printf '%s\n' "${BOLD}Phases${RESET}"
      for p in "${PHASES[@]}"; do
        IFS='|' read -r id kind desc <<<"$p"
        printf '  %-16s %-9s %s\n' "$id" "[$kind]" "$desc"
      done
      exit 0 ;;
    --only)              ONLY="$2"; shift 2 ;;
    --skip)              SKIP="$2"; shift 2 ;;
    --skip-device)       SKIP="${SKIP:+$SKIP,}build-device,device-smoke"; shift ;;
    --device)            DEVICE_UDID="$2"; REQUIRE_RIG=0; shift 2 ;;
    --single-device)     REQUIRE_RIG=0; shift ;;
    --sim)               SIM_NAME="$2"; shift 2 ;;
    --sim-udid)          SIM_UDID="$2"; shift 2 ;;
    --reset-sim-privacy) RESET_SIM_PRIVACY=1; shift ;;
    --regenerate)        REGENERATE=1; shift ;;
    --clean)             CLEAN=1; shift ;;
    --fail-fast)         FAIL_FAST=1; shift ;;
    --log-dir)           LOG_DIR="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; echo "Try --help." >&2; exit 2 ;;
  esac
done

# Validate phase names up front — a typo in --only must not silently produce a
# green run that tested nothing.
validate_phase_list() {   # $1 = flag name, $2 = comma list
  local flag="$1" list="$2" wanted known
  [[ -z "$list" ]] && return 0
  IFS=',' read -ra wanted <<<"$list"
  for w in "${wanted[@]}"; do
    known=0
    for p in "${PHASES[@]}"; do
      [[ "${p%%|*}" == "$w" ]] && known=1
    done
    if [[ "$known" -eq 0 ]]; then
      echo "Unknown phase '$w' in $flag. Run --list to see the phases." >&2
      exit 2
    fi
  done
}
validate_phase_list --only "$ONLY"
validate_phase_list --skip "$SKIP"

selected() {   # $1 = phase id
  local id="$1"
  [[ "$STOPPED" -eq 1 ]] && return 1
  if [[ -n "$ONLY" ]]; then
    [[ ",$ONLY," == *",$id,"* ]] || return 1
  fi
  if [[ -n "$SKIP" ]]; then
    [[ ",$SKIP," == *",$id,"* ]] && return 1
  fi
  return 0
}

any_selected_of_kind() {   # $1 = sim|device
  local kind="$1" p id k desc
  for p in "${PHASES[@]}"; do
    IFS='|' read -r id k desc <<<"$p"
    [[ "$k" == "$kind" ]] || continue
    selected "$id" && return 0
  done
  return 1
}

skip_rest() {   # $1,… = phase ids to drop from the remaining run
  local id
  for id in "$@"; do SKIP="${SKIP:+$SKIP,}$id"; done
}

# --------------------------------------------------------------- run records

RESULT_IDS=(); RESULT_STATUS=(); RESULT_PASS=(); RESULT_FAIL=()
RESULT_SKIPPED=(); RESULT_SECONDS=(); RESULT_NOTE=()
LAST_VERDICT=""

record() {   # id status pass fail skipped seconds note
  RESULT_IDS+=("$1"); RESULT_STATUS+=("$2"); RESULT_PASS+=("$3")
  RESULT_FAIL+=("$4"); RESULT_SKIPPED+=("$5"); RESULT_SECONDS+=("$6")
  RESULT_NOTE+=("${7:-}")
  LAST_VERDICT="$2"
}

human_time() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

# --------------------------------------------------------------- log parsing
#
# Parsed from the raw xcodebuild log rather than from xcpretty: XCTest's own
# "Test Case '…' passed/failed/skipped" lines are the format that survives every
# Xcode version, and they cover the parallel-testing variant too
# ("Test case 'Foo.testBar()' passed on 'Clone 1 of …'").

count_matching() {   # $1 = log, $2 = passed|failed|skipped
  grep -icE "test case '.*' $2( on '| \()" "$1" 2>/dev/null || true
}

names_matching() {   # $1 = log, $2 = passed|failed|skipped
  grep -iE "test case '.*' $2( on '| \()" "$1" 2>/dev/null \
    | sed -E "s/^.*[Tt]est [Cc]ase '(-\[)?([^]']+)\]?'.*/\2/" \
    | sed 's/  */ /g' | sort -u
  return 0
}

failure_reasons() {   # $1 = log
  grep -E ":[0-9]+: error:|XCTAssert.* failed|error: Test .* (failed|crashed)" "$1" 2>/dev/null \
    | sed -E 's#^.*/([^/]+\.swift:[0-9]+): error: #\1: #' \
    | cut -c1-200 | sort -u | head -25
  return 0
}

build_errors() {   # $1 = log
  grep -E "error:" "$1" 2>/dev/null | grep -v "XCTAssert" \
    | cut -c1-200 | sort -u | head -25
  return 0
}

# ------------------------------------------------------------- the test runs

# run_phase <id> <description> <workdir> -- <xcodebuild args…>
#
# Streams xcpretty's per-test lines to the console, keeps everything else on
# disk, then decides the phase's verdict from the raw log. A phase that builds
# and exits 0 but runs zero tests is a FAILURE, not a pass: that is exactly how
# a mis-wired scheme, or a device suite that skipped itself wholesale, presents
# itself.
run_phase() {
  local id="$1" desc="$2" workdir="$3"; shift 3
  [[ "${1:-}" == "--" ]] && shift

  local raw="$LOG_DIR/$id.raw.log"
  local pretty="$LOG_DIR/$id.pretty.log"
  local junit="$LOG_DIR/$id.junit.xml"
  local started ended elapsed status

  phase_header "$id" "$desc"
  # Only test results and errors reach the console, so a build phase is silent
  # while it works. Say so, or a long build reads as a hang.
  [[ "$id" == build-* ]] && info "${DIM}building — this prints nothing unless it fails${RESET}"

  started=$(date +%s)
  # No `|| true` on this pipeline: `true` would overwrite PIPESTATUS and hide
  # xcodebuild's exit code.
  (
    cd "$workdir" || exit 70
    xcodebuild "$@" 2>&1
  ) | tee "$raw" \
    | { if command -v xcpretty >/dev/null 2>&1; then
          xcpretty --color --report junit --output "$junit"
        else
          cat
        fi; } \
    | tee "$pretty" \
    | grep --line-buffered -E '✓|✗|❌|Failing tests:|Testing failed|error:'
  status="${PIPESTATUS[0]}"
  ended=$(date +%s)
  elapsed=$((ended - started))

  local passed failed skipped
  passed=$(count_matching "$raw" passed)
  failed=$(count_matching "$raw" failed)
  skipped=$(count_matching "$raw" skipped)

  local verdict note=""
  if [[ "$id" == build-* ]]; then
    # Build phases run no tests; the exit code is the whole story.
    if [[ "$status" -eq 0 ]]; then verdict="PASSED"; else verdict="FAILED"; note="build failed"; fi
  elif [[ "$status" -ne 0 ]]; then
    verdict="FAILED"
    [[ "$failed" -eq 0 ]] && note="no test failed — build or runner error (exit $status)"
  elif [[ $((passed + failed + skipped)) -eq 0 ]]; then
    verdict="FAILED"; note="zero tests executed — nothing was proved"
  elif [[ "$failed" -gt 0 ]]; then
    verdict="FAILED"
  else
    verdict="PASSED"
  fi

  rule
  if [[ "$verdict" == "PASSED" ]]; then
    if [[ "$id" == build-* ]]; then
      ok "$id built cleanly in $(human_time "$elapsed")"
    else
      ok "$id — $passed passed, $skipped skipped, in $(human_time "$elapsed")"
    fi
  else
    fail "$id — $passed passed, $failed failed, $skipped skipped, in $(human_time "$elapsed")"
    [[ -n "$note" ]] && warn "$note"
    if [[ "$failed" -gt 0 ]]; then
      names_matching "$raw" failed | sed "s/^/${RED}      ✗ ${RESET}/"
      failure_reasons "$raw" | head -10 | sed 's/^/        /'
    else
      build_errors "$raw" | head -10 | sed 's/^/        /'
    fi
    # The commonest self-inflicted failure: running a test phase on its own
    # against derived data that was never built for testing.
    if grep -qiE "xctestrun|does not contain a test host|build for testing" "$raw" 2>/dev/null; then
      warn "this phase reuses the build-for-testing output — run the matching build phase first"
    fi
    info "${DIM}full log: $raw${RESET}"
  fi

  # Skips are reported even on a green phase: a skipped test proved nothing, and
  # in the device phase a skip usually means the gate variable never reached the
  # runner.
  if [[ "$skipped" -gt 0 ]]; then
    warn "$skipped skipped — these proved nothing:"
    names_matching "$raw" skipped | head -15 | sed "s/^/${YELLOW}      ~ ${RESET}/"
  fi

  record "$id" "$verdict" "$passed" "$failed" "$skipped" "$elapsed" "$note"
  [[ "$verdict" == "PASSED" ]]
}

OVERALL=0

note_failure() {   # $1 = phase id
  OVERALL=1
  if [[ "$FAIL_FAST" -eq 1 ]]; then
    warn "--fail-fast: stopping after $1"
    STOPPED=1
  fi
}

# ----------------------------------------------------------------- preflight

mkdir -p "$LOG_ROOT" "$LOG_DIR"
printf '*\n' > "$LOG_ROOT/.gitignore"   # belt and braces; build/ is already ignored

banner "Encamera pre-release smoke — $RUN_STAMP"

info "repo:      $REPO_ROOT"
info "branch:    $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
info "commit:    $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
info "log dir:   $LOG_DIR"

command -v xcpretty >/dev/null 2>&1 \
  || warn "xcpretty not on PATH — falling back to raw output. Install with: gem install xcpretty"

[[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]] \
  && warn "working tree is dirty — you are smoking uncommitted code"

if [[ "$REPO_ROOT/project.yml" -nt "$PROJECT/project.pbxproj" ]]; then
  [[ "$REGENERATE" -eq 1 ]] \
    || warn "project.yml is newer than Encamera.xcodeproj — rerun with --regenerate, or targets and schemes may be stale"
fi

if [[ "$REGENERATE" -eq 1 ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    if ( cd "$REPO_ROOT" && xcodegen generate ) >"$LOG_DIR/xcodegen.log" 2>&1; then
      ok "xcodegen generate"
    else
      fail "xcodegen generate failed — see $LOG_DIR/xcodegen.log"; exit 1
    fi
  else
    fail "--regenerate given but xcodegen is not installed"; exit 1
  fi
fi

if [[ "$CLEAN" -eq 1 ]]; then
  info "removing $DERIVED_DATA"
  rm -rf "$DERIVED_DATA" "$DERIVED_DATA-analytics"
fi

# Simulator ---------------------------------------------------------------
SIM_DEST=""
if any_selected_of_kind sim; then
  if [[ -z "$SIM_UDID" ]]; then
    # Resolve to a concrete UDID rather than passing a name: several runtimes
    # carry the same model name and `OS:latest` fails outright when the newest
    # installed runtime has no device of that name.  simctl lists runtimes
    # oldest-first, so the last match is the newest one that has this model.
    read -r SIM_UDID SIM_RUNTIME <<<"$(
      xcrun simctl list devices available | awk -v name="$SIM_NAME" '
        /^-- / { rt = $0; sub(/^-- /, "", rt); sub(/ --$/, "", rt); next }
        index($0, "    " name " (") == 1 {
          if (match($0, /\([0-9A-Fa-f-]+\)/)) {
            u = substr($0, RSTART + 1, RLENGTH - 2)
            if (length(u) == 36) found = u " " rt
          }
        }
        END { print found }'
    )"
  fi
  if [[ -z "$SIM_UDID" ]]; then
    fail "no available simulator named '$SIM_NAME' — choose another with --sim, or pass --sim-udid"
    exit 1
  fi
  SIM_DEST="platform=iOS Simulator,id=$SIM_UDID"
  info "simulator: $SIM_NAME ${SIM_RUNTIME:+($SIM_RUNTIME) }$SIM_UDID"

  # Boot up front so a boot failure is a preflight error rather than a
  # mysterious test failure, and so the first xcodebuild does not time out on a
  # cold simulator.
  xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 \
    && ok "simulator booted" \
    || warn "simulator did not report booted — xcodebuild will try anyway"

  if [[ "$RESET_SIM_PRIVACY" -eq 1 ]]; then
    xcrun simctl privacy "$SIM_UDID" reset photos >/dev/null 2>&1 \
      && ok "reset photo privacy on the simulator" \
      || warn "could not reset photo privacy on $SIM_UDID"
  fi
fi

# Handset -----------------------------------------------------------------
DEVICE_DEST=""
DEVICE_AVAILABLE=0
if any_selected_of_kind device; then
  # Only the "== Devices ==" block counts: xctrace lists paired-but-absent
  # phones under "== Devices Offline ==", and those cannot run anything.
  CONNECTED=$(xcrun xctrace list devices 2>/dev/null | awk '
    /^== Devices ==/  { inblock = 1; next }
    /^== /            { inblock = 0 }
    inblock && NF     { print }' | grep -E '\([0-9]+\.[0-9.]+\) \([0-9A-Fa-f-]{20,}\)')
  CONNECTED_UDIDS=$(sed -E 's/.*\(([0-9A-Fa-f-]{20,})\)[[:space:]]*$/\1/' <<<"$CONNECTED")

  # Verified before anything is built: finding out at the end of an hour-long
  # run that half the rig was unplugged is the expensive way to learn it.
  if [[ "$REQUIRE_RIG" -eq 1 ]]; then
    MISSING_RIG=()
    for entry in "${RIG_DEVICES[@]}"; do
      rig_name="${entry%%|*}"; rig_udid="${entry##*|}"
      if grep -qx "$rig_udid" <<<"$CONNECTED_UDIDS"; then
        ok "rig: $rig_name attached ($rig_udid)"
      else
        fail "rig: $rig_name NOT attached ($rig_udid)"
        MISSING_RIG+=("$rig_name")
      fi
    done
    if [[ "${#MISSING_RIG[@]}" -gt 0 ]]; then
      printf '\n'
      fail "the test rig is incomplete — refusing to start"
      info "attach and unlock: ${MISSING_RIG[*]}"
      info "a phone that is merely paired shows under 'Devices Offline' in \`xcrun xctrace list devices\` and cannot run anything"
      info "to run on the primary phone alone: --single-device (or name one with --device UDID)"
      exit 1
    fi
  fi

  # No silent fallback to whichever iPhone happens to be plugged in: the rig
  # phones are on a disposable iCloud account and the suites are destructive, so
  # running them against a personal handset must never happen by accident.
  if grep -qx "$DEVICE_UDID" <<<"$CONNECTED_UDIDS"; then
    DEVICE_AVAILABLE=1
    DEVICE_DEST="id=$DEVICE_UDID"
    DEVICE_NAME=$(grep "$DEVICE_UDID" <<<"$CONNECTED" | head -1 | sed -E 's/ \(.*//')
    info "handset:   ${DEVICE_NAME:-unknown} ($DEVICE_UDID)"
    warn "handset checklist: unlocked, Auto-Lock set to Never, camera and photo permission granted"
  else
    fail "no handset attached — the device phases cannot run"
    info "attach and unlock the phone and rerun, or pass --skip-device to accept a simulator-only smoke"
  fi
fi

# ------------------------------------------------------------------- phases

COMMON=(-project "$PROJECT" -derivedDataPath "$DERIVED_DATA")

# build-sim ---------------------------------------------------------------
if selected build-sim; then
  run_phase build-sim "Build all test bundles for the simulator" "$REPO_ROOT" -- \
    build-for-testing \
    "${COMMON[@]}" \
    -scheme Encamera \
    -destination "$SIM_DEST" \
    -resultBundlePath "$LOG_DIR/build-sim.xcresult"

  if [[ "$LAST_VERDICT" == "FAILED" ]]; then
    note_failure build-sim
    # Running the simulator suites into the same wall proves nothing and buries
    # the compile error under three more failures.
    warn "simulator build failed — skipping the simulator test phases"
    skip_rest unit-core unit-app ui-sim
  fi
fi

# The three simulator test phases share the build above, so they run with
# test-without-building. -only-testing splits them into separately attributable
# phases instead of one undifferentiated run.
if selected unit-core; then
  run_phase unit-core "EncameraCore unit tests" "$REPO_ROOT" -- \
    test-without-building \
    "${COMMON[@]}" \
    -scheme Encamera \
    -destination "$SIM_DEST" \
    -only-testing:EncameraCoreTests \
    -resultBundlePath "$LOG_DIR/unit-core.xcresult" \
    || note_failure unit-core
fi

if selected unit-app; then
  run_phase unit-app "App unit tests (Tests/)" "$REPO_ROOT" -- \
    test-without-building \
    "${COMMON[@]}" \
    -scheme Encamera \
    -destination "$SIM_DEST" \
    -only-testing:EncameraTests \
    -resultBundlePath "$LOG_DIR/unit-app.xcresult" \
    || note_failure unit-app
fi

# EncameraAnalytics is an iOS-only package, so `swift test` cannot run it —
# SwiftPM builds for macOS and its os.Logger / AdServices calls fail
# availability there. The package's own scheme is testable only when xcodebuild
# is pointed at the package directory; the copy vended inside Encamera.xcodeproj
# has no test action at all.
if selected unit-analytics; then
  run_phase unit-analytics "EncameraAnalytics package tests" "$ANALYTICS_PACKAGE" -- \
    test \
    -scheme EncameraAnalytics \
    -destination "$SIM_DEST" \
    -derivedDataPath "$DERIVED_DATA-analytics" \
    -resultBundlePath "$LOG_DIR/unit-analytics.xcresult" \
    || note_failure unit-analytics
fi

# ui-sim ------------------------------------------------------------------
# Serial on purpose: cloned simulators make UI-test output unreadable and the
# suite contends on the shared app container anyway. The device-gated suites
# skip here — that is expected, and the skip list names them.
if selected ui-sim; then
  run_phase ui-sim "XCUITest suite on the simulator" "$REPO_ROOT" -- \
    test-without-building \
    "${COMMON[@]}" \
    -scheme Encamera \
    -destination "$SIM_DEST" \
    -only-testing:EncameraUITests \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 600 \
    -resultBundlePath "$LOG_DIR/ui-sim.xcresult" \
    || note_failure ui-sim
fi

# device ------------------------------------------------------------------
# The EncameraDeviceSmoke scheme exists to set ENCAMERA_DEVICE_SMOKE=1 on the
# test action, which is what un-gates the device-only suites.
if selected build-device; then
  if [[ "$DEVICE_AVAILABLE" -eq 1 ]]; then
    run_phase build-device "Build the test bundles for the handset" "$REPO_ROOT" -- \
      build-for-testing \
      "${COMMON[@]}" \
      -scheme EncameraDeviceSmoke \
      -destination "$DEVICE_DEST" \
      -resultBundlePath "$LOG_DIR/build-device.xcresult"

    if [[ "$LAST_VERDICT" == "FAILED" ]]; then
      note_failure build-device
      warn "device build failed — skipping the device smoke phase"
      skip_rest device-smoke
    fi
  else
    record build-device "SKIPPED" 0 0 0 0 "no handset attached"
    OVERALL=1
  fi
fi

if selected device-smoke; then
  if [[ "$DEVICE_AVAILABLE" -eq 1 ]]; then
    run_phase device-smoke "XCUITest suite + device-only suites on the handset" "$REPO_ROOT" -- \
      test-without-building \
      "${COMMON[@]}" \
      -scheme EncameraDeviceSmoke \
      -destination "$DEVICE_DEST" \
      -parallel-testing-enabled NO \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 900 \
      -resultBundlePath "$LOG_DIR/device-smoke.xcresult" \
      || note_failure device-smoke
  else
    record device-smoke "SKIPPED" 0 0 0 0 "no handset attached"
    OVERALL=1
  fi
fi

# -------------------------------------------------------------------- report

SUMMARY="$LOG_DIR/summary.txt"

{
  printf 'Encamera pre-release smoke — %s\n' "$RUN_STAMP"
  printf 'branch %s  commit %s\n\n' \
    "$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')" \
    "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
  printf '%-16s %-8s %6s %6s %6s %8s  %s\n' PHASE RESULT PASS FAIL SKIP TIME NOTE
  for i in "${!RESULT_IDS[@]}"; do
    printf '%-16s %-8s %6s %6s %6s %8s  %s\n' \
      "${RESULT_IDS[$i]}" "${RESULT_STATUS[$i]}" "${RESULT_PASS[$i]}" \
      "${RESULT_FAIL[$i]}" "${RESULT_SKIPPED[$i]}" \
      "$(human_time "${RESULT_SECONDS[$i]}")" "${RESULT_NOTE[$i]}"
  done
  printf '\n'
  for i in "${!RESULT_IDS[@]}"; do
    phase_id="${RESULT_IDS[$i]}"
    phase_raw="$LOG_DIR/$phase_id.raw.log"
    [[ -f "$phase_raw" ]] || continue
    if [[ "${RESULT_FAIL[$i]}" -gt 0 ]]; then
      printf 'FAILED in %s:\n' "$phase_id"
      names_matching "$phase_raw" failed | sed 's/^/  /'
      failure_reasons "$phase_raw" | sed 's/^/    /'
      printf '\n'
    fi
    if [[ "${RESULT_SKIPPED[$i]}" -gt 0 ]]; then
      printf 'SKIPPED in %s (these proved nothing):\n' "$phase_id"
      names_matching "$phase_raw" skipped | sed 's/^/  /'
      printf '\n'
    fi
  done
} > "$SUMMARY"

banner "Results"

printf '  %-16s %-8s %6s %6s %6s %9s\n' PHASE RESULT PASS FAIL SKIP TIME
rule
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0
for i in "${!RESULT_IDS[@]}"; do
  COLOUR="$GREEN"
  case "${RESULT_STATUS[$i]}" in
    FAILED)  COLOUR="$RED" ;;
    SKIPPED) COLOUR="$YELLOW" ;;
  esac
  printf '  %-16s %s%-8s%s %6s %6s %6s %9s\n' \
    "${RESULT_IDS[$i]}" "$COLOUR" "${RESULT_STATUS[$i]}" "$RESET" \
    "${RESULT_PASS[$i]}" "${RESULT_FAIL[$i]}" "${RESULT_SKIPPED[$i]}" \
    "$(human_time "${RESULT_SECONDS[$i]}")"
  [[ -n "${RESULT_NOTE[$i]}" ]] && printf '    %s%s%s\n' "$DIM" "${RESULT_NOTE[$i]}" "$RESET"
  TOTAL_PASS=$((TOTAL_PASS + RESULT_PASS[i]))
  TOTAL_FAIL=$((TOTAL_FAIL + RESULT_FAIL[i]))
  TOTAL_SKIP=$((TOTAL_SKIP + RESULT_SKIPPED[i]))
done
rule
printf '  %-16s %-8s %6s %6s %6s\n' TOTAL "" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP"

printf '\n'
info "summary:  $SUMMARY"
info "logs:     $LOG_DIR"
info "${DIM}per phase: <id>.raw.log (xcodebuild), <id>.pretty.log (xcpretty), <id>.junit.xml, <id>.xcresult${RESET}"
printf '\n'

if [[ "${#RESULT_IDS[@]}" -eq 0 ]]; then
  fail "no phases ran — check --only/--skip"
  OVERALL=1
elif [[ "$OVERALL" -eq 0 ]]; then
  ok "${GREEN}${BOLD}PRE-RELEASE SMOKE PASSED${RESET}${GREEN} — every selected suite ran and every test passed${RESET}"
else
  fail "${RED}${BOLD}PRE-RELEASE SMOKE FAILED${RESET}${RED} — see the phases marked FAILED above${RESET}"
fi
printf '\n'

exit "$OVERALL"
