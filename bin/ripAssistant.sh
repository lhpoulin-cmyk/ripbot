#!/usr/bin/env bash
# ripAssistant.sh
#
# Phase 1:
#   - Detect disc in a target drive
#   - Probe MakeMKV title info
#   - Parse durations and build candidate title list
#
# Phase 2:
#   - Classify titles using deterministic heuristics
#   - Produce a confidence score and AI-ready summary payload
#
# Phase 3:
#   - If confidence >= threshold, rip only candidate titles
#   - If confidence is too low, stop and ask for review
#
# Assumption:
#   - "makemkvcon mkv dev:/dev/sr1 <title> <dest>" is successful when invoked
#
# Notes:
#   - This is intentionally verbose for operator trust.
#   - Uses only bash + awk + grep + sort + sed + MakeMKV.
#   - Designed for TV episodic discs first.
#   - Movie-mode support can be added later.

set -euo pipefail

########################################
# Defaults
########################################

DEVICE="/dev/sr1"
DEST_ROOT="${HOME}/rips"
SHOW_NAME="UNKNOWN_SHOW"
SEASON="01"
DISC_LABEL_OVERRIDE=""
MODE="tv"                         # tv | movie
MIN_EPISODE_SECONDS=$((15*60))    # lower bound for episodic content
MAX_EPISODE_SECONDS=$((35*60))    # upper bound for episodic content
CONFIDENCE_THRESHOLD=0.80
VERBOSITY=2                       # 0=errors only, 1=normal, 2=verbose, 3=debug
DRY_RUN=0
FORCE_RIP=0
KEEP_PROBE_FILE=1

########################################
# Logging
########################################

log_error() {
  echo "[ERROR] $*" >&2
}

log_info() {
  [[ "${VERBOSITY}" -ge 1 ]] && echo "[INFO]  $*"
}

log_verbose() {
  [[ "${VERBOSITY}" -ge 2 ]] && echo "[VERBOSE] $*"
}

log_debug() {
  [[ "${VERBOSITY}" -ge 3 ]] && echo "[DEBUG] $*"
}

die() {
  log_error "$*"
  exit 1
}

########################################
# Usage
########################################

usage() {
  cat <<'EOF'
Usage:
  rip_assistant.sh [options]

Options:
  --device /dev/sr1           Optical device to inspect/rip (default: /dev/sr1)
  --dest-root PATH            Base destination directory (default: ~/rips)
  --show-name "Name"          Show or movie name for folder naming
  --season 01                 Season number for TV mode (default: 01)
  --disc-label "disc1"        Override disc label used in output naming
  --mode tv|movie             Classification mode (default: tv)
  --min-episode-seconds N     Lower bound for candidate episode duration
  --max-episode-seconds N     Upper bound for candidate episode duration
  --confidence-threshold F    Auto-rip threshold (default: 0.80)
  --dry-run                   Probe/classify only, do not rip
  --force-rip                 Rip even if confidence is below threshold
  -q, --quiet                 Reduce output verbosity
  -v, --verbose               Increase output verbosity
  -h, --help                  Show this help

Examples:
  ./rip_assistant.sh \
    --device /dev/sr1 \
    --show-name "The Big Bang Theory" \
    --season 01 \
    --mode tv

  ./rip_assistant.sh \
    --device /dev/sr1 \
    --show-name "The Big Bang Theory" \
    --season 01 \
    --dry-run \
    -v

Verbosity:
  -q once     -> normal -> quiet
  -q twice    -> errors only
  -v once     -> verbose
  -v twice    -> debug
EOF
}

########################################
# Arg parsing
########################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      DEVICE="$2"; shift 2
      ;;
    --dest-root)
      DEST_ROOT="$2"; shift 2
      ;;
    --show-name)
      SHOW_NAME="$2"; shift 2
      ;;
    --season)
      SEASON="$2"; shift 2
      ;;
    --disc-label)
      DISC_LABEL_OVERRIDE="$2"; shift 2
      ;;
    --mode)
      MODE="$2"; shift 2
      ;;
    --min-episode-seconds)
      MIN_EPISODE_SECONDS="$2"; shift 2
      ;;
    --max-episode-seconds)
      MAX_EPISODE_SECONDS="$2"; shift 2
      ;;
    --confidence-threshold)
      CONFIDENCE_THRESHOLD="$2"; shift 2
      ;;
    --dry-run)
      DRY_RUN=1; shift
      ;;
    --force-rip)
      FORCE_RIP=1; shift
      ;;
    -q|--quiet)
      VERBOSITY=$((VERBOSITY-1)); shift
      ;;
    -v|--verbose)
      VERBOSITY=$((VERBOSITY+1)); shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

(( VERBOSITY < 0 )) && VERBOSITY=0

########################################
# Preconditions
########################################

command -v makemkvcon >/dev/null 2>&1 || die "makemkvcon not found"
command -v awk >/dev/null 2>&1 || die "awk not found"
command -v grep >/dev/null 2>&1 || die "grep not found"
command -v sed >/dev/null 2>&1 || die "sed not found"
[[ -b "${DEVICE}" ]] || die "Device not found or not a block device: ${DEVICE}"

########################################
# Helpers
########################################

sanitize_name() {
  local s="$1"
  s="${s//\//-}"
  s="${s//$'\n'/ }"
  echo "$s" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

hhmmss_to_seconds() {
  local t="$1"
  awk -F: '
    NF==3 { print ($1*3600)+($2*60)+$3; next }
    NF==2 { print ($1*60)+$2; next }
    { print 0 }
  ' <<<"$t"
}

seconds_to_hhmmss() {
  local total="$1"
  local h=$((total/3600))
  local m=$(((total%3600)/60))
  local s=$((total%60))
  printf "%02d:%02d:%02d\n" "$h" "$m" "$s"
}

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g'
}

########################################
# Probe disc
########################################

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
TMPDIR="$(mktemp -d)"
PROBE_FILE="${TMPDIR}/probe.txt"
SUMMARY_FILE="${TMPDIR}/summary.json"

log_info "Probing disc in ${DEVICE}"
log_verbose "Temporary working directory: ${TMPDIR}"

if ! makemkvcon -r info "dev:${DEVICE}" > "${PROBE_FILE}" 2>&1; then
  cat "${PROBE_FILE}" >&2 || true
  die "makemkvcon probe failed"
fi

log_verbose "Probe complete"

########################################
# Extract disc label
########################################

DISC_LABEL="$(
  awk -F'"' '/^DRV:/ && $6 != "" { print $6; exit }' "${PROBE_FILE}" | sed 's/^ *//; s/ *$//'
)"

if [[ -n "${DISC_LABEL_OVERRIDE}" ]]; then
  DISC_LABEL="${DISC_LABEL_OVERRIDE}"
fi

[[ -n "${DISC_LABEL}" ]] || DISC_LABEL="UNLABELED_DISC"
DISC_LABEL="$(sanitize_name "${DISC_LABEL}")"

log_info "Disc label: ${DISC_LABEL}"

########################################
# Parse titles
#
# We care about:
#   TINFO:<id>,9,0,"0:21:14"   duration
#   TINFO:<id>,10,0,"3.2 GB"    size display
#   TINFO:<id>,27,0,"foo.mkv"   filename
########################################

TITLE_LINES="$(
  awk -F'"' '
    /^TINFO:/ {
      split($1, a, /[:,]/)
      tid=a[2]
      key=a[3]
      val=$2

      if (key == 9)  duration[tid]=val
      if (key == 10) size[tid]=val
      if (key == 27) fname[tid]=val
    }
    END {
      for (tid in duration) {
        printf "%s|%s|%s|%s\n", tid, duration[tid], size[tid], fname[tid]
      }
    }
  ' "${PROBE_FILE}" | sort -t'|' -k1,1n
)"

[[ -n "${TITLE_LINES}" ]] || die "No title durations found in probe output"

log_verbose "Parsed titles:"
if [[ "${VERBOSITY}" -ge 2 ]]; then
  while IFS='|' read -r tid dur size fname; do
    printf '[VERBOSE] title=%s duration=%s size=%s file=%s\n' "$tid" "$dur" "$size" "$fname"
  done <<< "${TITLE_LINES}"
fi

########################################
# Build candidate list
########################################

declare -a ALL_TITLES=()
declare -a CANDIDATE_TITLES=()
declare -a SHORT_TITLES=()
declare -a LONG_TITLES=()

declare -A TITLE_DURATION_HMS=()
declare -A TITLE_DURATION_SEC=()
declare -A TITLE_SIZE=()
declare -A TITLE_FNAME=()

while IFS='|' read -r tid dur size fname; do
  [[ -n "${tid}" ]] || continue
  ALL_TITLES+=("$tid")
  TITLE_DURATION_HMS["$tid"]="$dur"
  TITLE_DURATION_SEC["$tid"]="$(hhmmss_to_seconds "$dur")"
  TITLE_SIZE["$tid"]="$size"
  TITLE_FNAME["$tid"]="$fname"

  sec="${TITLE_DURATION_SEC[$tid]}"
  if (( sec >= MIN_EPISODE_SECONDS && sec <= MAX_EPISODE_SECONDS )); then
    CANDIDATE_TITLES+=("$tid")
  elif (( sec < MIN_EPISODE_SECONDS )); then
    SHORT_TITLES+=("$tid")
  else
    LONG_TITLES+=("$tid")
  fi
done <<< "${TITLE_LINES}"

TOTAL_TITLES="${#ALL_TITLES[@]}"
CANDIDATE_COUNT="${#CANDIDATE_TITLES[@]}"
SHORT_COUNT="${#SHORT_TITLES[@]}"
LONG_COUNT="${#LONG_TITLES[@]}"

log_info "Total titles found: ${TOTAL_TITLES}"
log_info "Candidate episode-length titles: ${CANDIDATE_COUNT}"
log_verbose "Short titles: ${SHORT_COUNT}"
log_verbose "Long titles: ${LONG_COUNT}"

########################################
# Confidence scoring
#
# TV heuristics:
#   + more points if many titles fall into a tight episodic range
#   + penalty if there are many long ambiguous titles
#   + penalty if too few candidate titles
#   + bonus if candidate titles are in mostly sequential order
########################################

CONFIDENCE="0.00"
REASONING=()

if [[ "${MODE}" == "tv" ]]; then
  score=0

  # Baseline: enough episode-like titles
  if (( CANDIDATE_COUNT >= 4 )); then
    score=$((score + 30))
    REASONING+=("Found at least 4 episode-length titles")
  fi

  if (( CANDIDATE_COUNT >= 6 )); then
    score=$((score + 20))
    REASONING+=("Found 6+ episode-length titles, strong TV-disc signal")
  fi

  if (( CANDIDATE_COUNT >= 8 )); then
    score=$((score + 10))
    REASONING+=("Found 8+ episode-length titles")
  fi

  # Sequential title IDs help confidence
  sequential_pairs=0
  if (( CANDIDATE_COUNT > 1 )); then
    for ((i=1; i<${#CANDIDATE_TITLES[@]}; i++)); do
      prev="${CANDIDATE_TITLES[$((i-1))]}"
      curr="${CANDIDATE_TITLES[$i]}"
      if (( curr == prev + 1 )); then
        sequential_pairs=$((sequential_pairs + 1))
      fi
    done
  fi

  if (( sequential_pairs >= CANDIDATE_COUNT - 2 )); then
    score=$((score + 15))
    REASONING+=("Candidate titles are mostly sequential")
  fi

  # Penalty: many long titles can indicate ambiguity
  if (( LONG_COUNT >= 2 )); then
    score=$((score - 15))
    REASONING+=("Multiple long titles increase ambiguity")
  fi

  # Penalty: no short titles is unusual but not fatal; lots of shorts is normal
  if (( CANDIDATE_COUNT <= 2 )); then
    score=$((score - 30))
    REASONING+=("Too few episode-length titles")
  fi

  # Tight cluster bonus
  if (( CANDIDATE_COUNT > 0 )); then
    min_sec=999999
    max_sec=0
    for tid in "${CANDIDATE_TITLES[@]}"; do
      sec="${TITLE_DURATION_SEC[$tid]}"
      (( sec < min_sec )) && min_sec="$sec"
      (( sec > max_sec )) && max_sec="$sec"
    done
    spread=$((max_sec - min_sec))
    log_debug "Candidate duration spread (seconds): ${spread}"

    if (( spread <= 300 )); then
      score=$((score + 15))
      REASONING+=("Episode candidates form a tight duration cluster")
    elif (( spread <= 600 )); then
      score=$((score + 8))
      REASONING+=("Episode candidates form a reasonable duration cluster")
    else
      score=$((score - 10))
      REASONING+=("Episode candidates are duration-diverse; possible ambiguity")
    fi
  fi

  # Clamp 0..100
  (( score < 0 )) && score=0
  (( score > 100 )) && score=100

  CONFIDENCE="$(awk -v s="$score" 'BEGIN { printf "%.2f", s/100 }')"
else
  # Placeholder for movie mode.
  # For now, keep it conservative.
  CONFIDENCE="0.40"
  REASONING+=("Movie mode not fully implemented yet; conservative confidence")
fi

########################################
# AI-ready summary payload
########################################

{
  echo "{"
  printf '  "timestamp": "%s",\n' "${TIMESTAMP}"
  printf '  "device": "%s",\n' "${DEVICE}"
  printf '  "disc_label": "%s",\n' "$(printf '%s' "${DISC_LABEL}" | json_escape)"
  printf '  "mode": "%s",\n' "${MODE}"
  printf '  "total_titles": %d,\n' "${TOTAL_TITLES}"
  printf '  "candidate_count": %d,\n' "${CANDIDATE_COUNT}"
  printf '  "short_count": %d,\n' "${SHORT_COUNT}"
  printf '  "long_count": %d,\n' "${LONG_COUNT}"
  printf '  "confidence": %s,\n' "${CONFIDENCE}"

  echo '  "candidate_titles": ['
  for i in "${!CANDIDATE_TITLES[@]}"; do
    tid="${CANDIDATE_TITLES[$i]}"
    comma=","
    [[ "$i" -eq $((${#CANDIDATE_TITLES[@]} - 1)) ]] && comma=""
    printf '    {"title_id": %s, "duration": "%s", "size": "%s"}%s\n' \
      "$tid" \
      "${TITLE_DURATION_HMS[$tid]}" \
      "$(printf '%s' "${TITLE_SIZE[$tid]}" | json_escape)" \
      "${comma}"
  done
  echo '  ],'

  echo '  "reasoning": ['
  for i in "${!REASONING[@]}"; do
    comma=","
    [[ "$i" -eq $((${#REASONING[@]} - 1)) ]] && comma=""
    printf '    "%s"%s\n' "$(printf '%s' "${REASONING[$i]}" | json_escape)" "${comma}"
  done
  echo '  ]'
  echo "}"
} > "${SUMMARY_FILE}"

########################################
# Operator summary
########################################

echo
echo "========== DISC SUMMARY =========="
echo "Device:              ${DEVICE}"
echo "Disc label:          ${DISC_LABEL}"
echo "Mode:                ${MODE}"
echo "Total titles:        ${TOTAL_TITLES}"
echo "Candidate titles:    ${CANDIDATE_COUNT}"
echo "Short titles:        ${SHORT_COUNT}"
echo "Long titles:         ${LONG_COUNT}"
echo "Confidence:          ${CONFIDENCE}"
echo "Threshold:           ${CONFIDENCE_THRESHOLD}"
echo "Summary JSON:        ${SUMMARY_FILE}"
echo

echo "Candidate titles selected for rip:"
for tid in "${CANDIDATE_TITLES[@]}"; do
  printf '  - title %s | %s | %s\n' \
    "$tid" \
    "${TITLE_DURATION_HMS[$tid]}" \
    "${TITLE_SIZE[$tid]}"
done

echo
echo "Reasoning:"
for r in "${REASONING[@]}"; do
  echo "  - ${r}"
done
echo "=================================="
echo

########################################
# Phase 2.5 AI hook placeholder
########################################
# This function does nothing yet, but the shape is here on purpose.
# Later you can:
#   - POST ${SUMMARY_FILE} to an AI endpoint
#   - receive:
#       * candidate title ids
#       * confidence override
#       * explanation
#       * recommended action: proceed / hold / alert
#
# For today, the rules engine remains authoritative.

ai_review_placeholder() {
  log_debug "AI review hook not implemented; using rules-engine decision"
  return 0
}

ai_review_placeholder

########################################
# Phase 3: auto-rip if approved
########################################

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "Dry-run mode enabled; exiting before rip"
  [[ "${KEEP_PROBE_FILE}" -eq 1 ]] && log_info "Probe kept at: ${PROBE_FILE}"
  exit 0
fi

should_rip=0
if [[ "${FORCE_RIP}" -eq 1 ]]; then
  should_rip=1
  log_info "Force-rip enabled; proceeding regardless of confidence"
else
  cmp="$(awk -v a="${CONFIDENCE}" -v b="${CONFIDENCE_THRESHOLD}" 'BEGIN { if (a >= b) print "yes"; else print "no" }')"
  if [[ "${cmp}" == "yes" ]]; then
    should_rip=1
  fi
fi

if [[ "${should_rip}" -ne 1 ]]; then
  log_info "Confidence below threshold; not ripping"
  log_info "Review summary: ${SUMMARY_FILE}"
  [[ "${KEEP_PROBE_FILE}" -eq 1 ]] && log_info "Probe kept at: ${PROBE_FILE}"
  exit 2
fi

DEST_DIR="${DEST_ROOT}/$(sanitize_name "${SHOW_NAME}")/Season ${SEASON}/${DISC_LABEL}_${TIMESTAMP}"
mkdir -p "${DEST_DIR}"

log_info "Rip approved"
log_info "Destination: ${DEST_DIR}"
log_info "Beginning rip of ${CANDIDATE_COUNT} titles"

ripped_count=0
for tid in "${CANDIDATE_TITLES[@]}"; do
  log_info "Ripping title ${tid} (${TITLE_DURATION_HMS[$tid]}, ${TITLE_SIZE[$tid]})"
  makemkvcon mkv "dev:${DEVICE}" "${tid}" "${DEST_DIR}"
  ripped_count=$((ripped_count + 1))
  log_verbose "Completed title ${tid}"
done

log_info "Rip complete"
log_info "Titles ripped: ${ripped_count}"
log_info "Output directory: ${DEST_DIR}"
[[ "${KEEP_PROBE_FILE}" -eq 1 ]] && log_info "Probe kept at: ${PROBE_FILE}"

########################################
# Projected growth path
########################################
# 1) Add real AI review
#    - Send ${SUMMARY_FILE} to an API endpoint
#    - Let AI classify:
#         * likely episodes
#         * likely extras
#         * confidence override
#         * anomaly explanation
#    - Only allow AI to advise; script still owns final execution rules
#
# 2) Add notification layer
#    - On low confidence, rip failure, or ambiguous disc:
#         * send SMS / Pushover / ntfy / Signal / email
#    - On success:
#         * send concise completion notice with disc label and file count
#
# 3) Add automatic disc detection
#    - Run from udev/systemd path trigger
#    - On media insert, launch probe automatically
#    - On tray open/close, update state file
#
# 4) Add post-rip validation
#    - Check for duplicate durations
#    - Check for suspiciously small files
#    - Run mediainfo on ripped MKVs
#    - Hash outputs for future duplicate detection
#
# 5) Add rename/move logic
#    - TV mode:
#         * map candidate titles to SxxExx
#    - Movie mode:
#         * select main feature only
#    - Move finished files into Jellyfin library staging
#
# 6) Add state/history
#    - Store prior disc decisions in JSON/YAML
#    - Reuse prior known-good patterns by show/disc label
#    - Raise confidence faster on repeated, consistent discs
#
# 7) Add operator approval workflow
#    - If confidence is medium:
#         * pause and wait for approval token / CLI flag / phone reply
#
# 8) Add transcoding/compression stage if desired
#    - After archival rip, optionally queue HandBrake/ffmpeg encode job
#    - Keep archival rip separate from streaming copy
#
# 9) Add web UI
#    - Current disc
#    - Candidate titles
#    - Confidence
#    - Rip queue
#    - History and exceptions
