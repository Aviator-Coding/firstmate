#!/usr/bin/env bash
# jev-decide.sh - ask TypeSafe Jev to pick one option for a decision, through a
# LiteLLM proxy (or any endpoint speaking OpenRouter's decisions API), and say
# whether the answer is strong enough to act on.
#
# Usage:
#   jev-decide.sh --question <text> --option <label>=<description> \
#                 --option <label>=<description> [--option ...] \
#                 [--context <text> | --context-file <path|->] [--json]
#
#   --question      what to decide, as one instruction to Jev
#   --option        one candidate; at least two; label is 1-64 characters of
#                   letters, digits, '.', '_' or '-' and starts with a letter or
#                   digit; labels must be unique; description must be non-empty
#   --context       free-text facts, constraints, and goals Jev should weigh
#   --context-file  read that context from a file, or from stdin with '-'
#   --json          print one JSON object instead of the text block
#
# What it does: one POST of {model, state: {context}, questions: {decision:
#   {type: "choice", instructions: <question>, criteria: {<label>:
#   <description>, ...}}}} to $JEV_DECIDE_BASE_URL$JEV_DECIDE_PATH, then
#   validates the answer and applies the verdict rule below. It never retries
#   and never picks an option on its own.
#
# Verdict rule:
#   decided       the answer is well formed, its choice is the single most
#                 probable option, confidence >= the floor, and the top
#                 probability beats the runner-up by at least the margin
#   inconclusive  anything else: confidence below the floor, top two options
#                 within the margin, a choice that disagrees with its own
#                 probabilities, a malformed answer, an HTTP or network error
#                 (401 reads "credential rejected", 403 "credential not
#                 granted" - the key is valid but not allowed on this route),
#                 a timeout, a missing tool, or missing configuration
#   Every verdict exits 0. Exit 2 is reserved for a usage error or an invalid
#   tuning value (a bad flag, fewer than two options, a malformed or duplicate
#   label, an out-of-range floor, margin, or timeout), which the caller must fix.
#
# Output (text, default):
#   jev-decide:
#     verdict: decided | inconclusive
#     choice: <label>                        (decided only)
#     leaning: <label>                       (inconclusive with a valid answer)
#     reason: <why inconclusive>             (inconclusive only)
#     confidence: <0..1>
#     probabilities: <label>=<p> ...         (most probable first)
#     model: <model>   latency_ms: <ms>
#   --json prints the same fields as one object: verdict, choice, leaning,
#   reason, confidence, probabilities, model, latency_ms, floor, margin
#   (absent values are null).
#
# Environment:
#   JEV_DECIDE_BASE_URL          required; proxy base URL, e.g.
#                                https://litellm.example.com
#   JEV_DECIDE_API_KEY           required; bearer key for that proxy
#   JEV_DECIDE_PATH              default /openrouter/alpha/decisions (LiteLLM's
#                                OpenRouter pass-through); use /alpha/decisions
#                                with base https://openrouter.ai/api to call
#                                OpenRouter directly
#   JEV_DECIDE_MODEL             default typesafe/jev-1.13
#   JEV_DECIDE_CONFIDENCE_FLOOR  default 0.7; minimum confidence, 0..1
#   JEV_DECIDE_MARGIN            default 0.15; minimum gap between the top two
#                                probabilities, 0..1
#   JEV_DECIDE_TIMEOUT           default 20; whole-request seconds, 1..300
#   A missing base URL or key is inconclusive, not an error, and makes no
#   network call.
#
# Key handling: the key is copied into a private shell variable and
#   JEV_DECIDE_API_KEY is unset before any child process starts. curl reads the
#   Authorization header from a file descriptor, so the key never appears on
#   any argv; any echo of it in an error body, whole or masked with **** or
#   ..., is redacted before printing.
#
# Requires: bash, curl, jq.
set -u

JEV_KEY_PRIVATE=${JEV_DECIDE_API_KEY:-}
export -n JEV_KEY_PRIVATE 2>/dev/null || true
unset JEV_DECIDE_API_KEY

BASE_URL=${JEV_DECIDE_BASE_URL:-}
API_PATH=${JEV_DECIDE_PATH:-/openrouter/alpha/decisions}
MODEL=${JEV_DECIDE_MODEL:-typesafe/jev-1.13}
FLOOR=${JEV_DECIDE_CONFIDENCE_FLOOR:-0.7}
MARGIN=${JEV_DECIDE_MARGIN:-0.15}
TIMEOUT=${JEV_DECIDE_TIMEOUT:-20}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}
die() { printf 'jev-decide: error: %s\n' "$1" >&2; exit 2; }

QUESTION='' CONTEXT='' CONTEXT_SET=0 JSON=0
LABELS=() DESCRIPTIONS=()
add_option() {
  local spec=$1 label desc existing
  case "$spec" in
    *=*) : ;;
    *) die "--option needs <label>=<description>, got: $spec" ;;
  esac
  label=${spec%%=*}
  desc=${spec#*=}
  [[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
    || die "option label must be 1-64 of [A-Za-z0-9._-] starting with a letter or digit: $label"
  [ -n "$desc" ] || die "option $label needs a non-empty description"
  for existing in "${LABELS[@]+"${LABELS[@]}"}"; do
    [ "$existing" != "$label" ] || die "duplicate option label: $label"
  done
  LABELS+=("$label")
  DESCRIPTIONS+=("$desc")
}

while [ $# -gt 0 ]; do
  case "$1" in
    --question) [ $# -ge 2 ] || die "--question needs a value"; QUESTION=$2; shift 2 ;;
    --option) [ $# -ge 2 ] || die "--option needs a value"; add_option "$2"; shift 2 ;;
    --context)
      [ $# -ge 2 ] || die "--context needs a value"
      [ "$CONTEXT_SET" -eq 0 ] || die "give --context or --context-file once"
      CONTEXT=$2; CONTEXT_SET=1; shift 2 ;;
    --context-file)
      [ $# -ge 2 ] || die "--context-file needs a path"
      [ "$CONTEXT_SET" -eq 0 ] || die "give --context or --context-file once"
      if [ "$2" = - ]; then
        CONTEXT=$(cat) || die "could not read context from stdin"
      else
        [ -r "$2" ] || die "context file not readable: $2"
        CONTEXT=$(cat -- "$2") || die "could not read context file: $2"
      fi
      CONTEXT_SET=1; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$QUESTION" ] || die "--question is required"
[ "${#LABELS[@]}" -ge 2 ] || die "at least two --option values are required"

is_unit_number() { [[ "$1" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; }
is_unit_number "$FLOOR" || die "JEV_DECIDE_CONFIDENCE_FLOOR must be a number from 0 to 1, got: $FLOOR"
is_unit_number "$MARGIN" || die "JEV_DECIDE_MARGIN must be a number from 0 to 1, got: $MARGIN"
[[ "$TIMEOUT" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$TIMEOUT" -le 300 ] \
  || die "JEV_DECIDE_TIMEOUT must be whole seconds from 1 to 300, got: $TIMEOUT"

# An inconclusive verdict that carries no model evidence. Works without jq so a
# missing jq is still reported in the requested format.
inconclusive_bare() {
  local reason=$1 escaped
  if [ "$JSON" -eq 1 ]; then
    if command -v jq >/dev/null 2>&1; then
      jq -cn --arg reason "$reason" --argjson floor "$FLOOR" --argjson margin "$MARGIN" \
        '{verdict: "inconclusive", choice: null, leaning: null, reason: $reason,
          confidence: null, probabilities: null, model: null, latency_ms: null,
          floor: $floor, margin: $margin}'
    else
      escaped=$(printf '%s' "$reason" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g')
      printf '{"verdict":"inconclusive","choice":null,"leaning":null,"reason":"%s","confidence":null,"probabilities":null,"model":null,"latency_ms":null,"floor":%s,"margin":%s}\n' \
        "$escaped" "$FLOOR" "$MARGIN"
    fi
  else
    printf 'jev-decide:\n  verdict: inconclusive\n  reason: %s\n' "$(printf '%s' "$reason" | tr '\n\r\t' '   ')"
  fi
  exit 0
}

# Error text is printed for diagnosis, so strip the key and any masked form of
# it (LiteLLM echoes keys as sk-...<last4> or <first4>****<last4>) before it
# leaves this process.
redact() {
  local text=$1
  if [ -n "$JEV_KEY_PRIVATE" ]; then
    text=${text//"$JEV_KEY_PRIVATE"/[redacted]}
  fi
  printf '%s' "$text" | tr '\n\r\t' '   ' \
    | sed -E 's/[^][:space:]"'"'"',;:=()[{}]*([*]{3,}|[.]{3})[A-Za-z0-9_-]+/[redacted]/g'
}

command -v jq >/dev/null 2>&1 || inconclusive_bare "jq is not installed"
command -v curl >/dev/null 2>&1 || inconclusive_bare "curl is not installed"
[ -n "$BASE_URL" ] || inconclusive_bare "not configured: JEV_DECIDE_BASE_URL is unset"
[ -n "$JEV_KEY_PRIVATE" ] || inconclusive_bare "not configured: JEV_DECIDE_API_KEY is unset"
case "$JEV_KEY_PRIVATE" in
  *[[:space:][:cntrl:]]*) inconclusive_bare "not configured: JEV_DECIDE_API_KEY contains whitespace or control characters" ;;
esac

URL="${BASE_URL%/}/${API_PATH#/}"

CRITERIA='{}'
i=0
while [ "$i" -lt "${#LABELS[@]}" ]; do
  CRITERIA=$(jq -c --arg k "${LABELS[$i]}" --arg v "${DESCRIPTIONS[$i]}" '. + {($k): $v}' <<<"$CRITERIA") \
    || inconclusive_bare "could not build the request"
  i=$((i + 1))
done
REQUEST=$(jq -cn --arg model "$MODEL" --arg question "$QUESTION" --arg context "$CONTEXT" \
  --argjson criteria "$CRITERIA" '
  {
    model: $model,
    state: {context: (if $context == "" then "(no additional context provided)" else $context end)},
    questions: {decision: {type: "choice", instructions: $question, criteria: $criteria}}
  }') || inconclusive_bare "could not build the request"

RESP_FILE=$(mktemp) || inconclusive_bare "mktemp failed"
ERR_FILE=$(mktemp) || { rm -f "$RESP_FILE"; inconclusive_bare "mktemp failed"; }
RESULT_FILE=$(mktemp) || { rm -f "$RESP_FILE" "$ERR_FILE"; inconclusive_bare "mktemp failed"; }
trap 'rm -f "$RESP_FILE" "$ERR_FILE" "$RESULT_FILE"' EXIT

CURL_OUT=$(printf '%s' "$REQUEST" | curl -sS --max-time "$TIMEOUT" -o "$RESP_FILE" \
  -w '%{http_code} %{time_total}' -X POST "$URL" -H 'Content-Type: application/json' \
  -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$JEV_KEY_PRIVATE") \
  --data-binary @- 2>"$ERR_FILE")
CURL_RC=$?
read -r HTTP TIME_TOTAL <<<"$CURL_OUT"
LAT_MS=$(awk -v t="${TIME_TOTAL:-0}" 'BEGIN { printf "%d", t * 1000 + 0.5 }')
if [ "$CURL_RC" -eq 28 ]; then
  inconclusive_bare "request timed out after ${TIMEOUT}s"
elif [ "$CURL_RC" -ne 0 ]; then
  inconclusive_bare "request failed (curl exit $CURL_RC): $(redact "$(head -c 200 "$ERR_FILE")")"
fi
case "${HTTP:-000}" in
  200) : ;;
  401) inconclusive_bare "credential rejected: http 401 after ${LAT_MS} ms: $(redact "$(head -c 200 "$RESP_FILE")")" ;;
  403) inconclusive_bare "credential not granted: http 403 after ${LAT_MS} ms: $(redact "$(head -c 200 "$RESP_FILE")")" ;;
  *) inconclusive_bare "http ${HTTP:-000} after ${LAT_MS} ms: $(redact "$(head -c 200 "$RESP_FILE")")" ;;
esac

LABELS_JSON=$(printf '%s\n' "${LABELS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')
jq -e --argjson labels "$LABELS_JSON" '
  (.answers.decision) as $a |
  ($a | type) == "object" and
  ($a.choice | type) == "string" and
  ($labels | index($a.choice)) != null and
  ($a.confidence | type) == "number" and $a.confidence >= 0 and $a.confidence <= 1 and
  ($a.probabilities | type) == "object" and
  ($a.probabilities | keys | sort) == $labels and
  all($a.probabilities[]; type == "number" and . >= 0 and . <= 1) and
  (([$a.probabilities[]] | add) as $total | $total >= 0.98 and $total <= 1.02)
' "$RESP_FILE" >/dev/null 2>&1 \
  || inconclusive_bare "response is not a valid choice answer for these options: $(redact "$(head -c 200 "$RESP_FILE")")"

jq -c --argjson floor "$FLOOR" --argjson margin "$MARGIN" --argjson lat "$LAT_MS" '
  (.answers.decision) as $a |
  ($a.probabilities | to_entries | sort_by(-.value)) as $ranked |
  ($ranked[0].value - $ranked[1].value) as $gap |
  ([$ranked[] | select(.value == $ranked[0].value)] | length) as $top_count |
  {
    confidence: $a.confidence,
    probabilities: ($ranked | from_entries),
    model: (.model // null),
    latency_ms: $lat,
    floor: $floor,
    margin: $margin
  } as $ev |
  (if $top_count > 1 or $ranked[0].key != $a.choice then
     "choice \($a.choice) is not the single most probable option"
   elif $a.confidence < $floor then
     "confidence \($a.confidence) below floor \($floor)"
   elif $gap < $margin then
     "top two options \($ranked[0].key) and \($ranked[1].key) are \($gap * 1000 | round / 1000) apart, within margin \($margin)"
   else null end) as $reason |
  if $reason == null then
    {verdict: "decided", choice: $a.choice, leaning: null, reason: null} + $ev
  else
    {verdict: "inconclusive", choice: null, leaning: $a.choice, reason: $reason} + $ev
  end
' "$RESP_FILE" > "$RESULT_FILE" 2>/dev/null || inconclusive_bare "could not evaluate the answer"

if [ "$JSON" -eq 1 ]; then
  cat "$RESULT_FILE"
else
  jq -r '
    def flat: tostring | gsub("[\t\r\n]"; " ");
    "jev-decide:",
    "  verdict: \(.verdict)",
    (if .choice then "  choice: \(.choice)" else empty end),
    (if .leaning then "  leaning: \(.leaning)" else empty end),
    (if .reason then "  reason: \(.reason | flat)" else empty end),
    "  confidence: \(.confidence)",
    "  probabilities: \([.probabilities | to_entries[] | "\(.key)=\(.value)"] | join(" "))",
    "  model: \(.model // "-" | flat)   latency_ms: \(.latency_ms)"
  ' "$RESULT_FILE"
fi
exit 0
