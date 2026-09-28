#!/usr/bin/env bash
# Behavior tests for skills/jev-decide/scripts/jev-decide.sh and its firstmate
# entry point bin/fm-decide.sh.
#
# Drives the public argv and environment interface against a local stub HTTP
# server that speaks the decisions API shape: it records each request's path,
# headers, and body, and answers according to a mode file the case sets. A PATH
# shim in front of the real curl records curl's argv and environment so the
# cases can prove the key never rides on argv or into a child environment. No
# case touches the real network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the stub decisions server"
command -v jq >/dev/null 2>&1 || fail "jq is required"
REAL_CURL=$(command -v curl) || fail "curl is required"

CLI="$ROOT/skills/jev-decide/scripts/jev-decide.sh"
WRAPPER="$ROOT/bin/fm-decide.sh"
TMP_ROOT=$(fm_test_tmproot fm-decide)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
REC="$TMP_ROOT/rec"
MODE="$TMP_ROOT/mode"
KEY='sk-test-SECRET-4f9a8b7c6d5e'
mkdir -p "$HOME_DIR" "$REC"

cat > "$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" >> '$REC/curl.argv'
env >> '$REC/curl.env'
exec '$REAL_CURL' "\$@"
SH
chmod +x "$FAKEBIN/curl"

cat > "$TMP_ROOT/server.py" <<'PY'
import json, os, socketserver, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

rec, mode_file, port_file = sys.argv[1], sys.argv[2], sys.argv[3]

def probs(labels, top, second):
    rest = labels[2:]
    left = max(0.0, 1.0 - top - second)
    out = {labels[0]: top, labels[1]: second}
    for label in rest:
        out[label] = round(left / len(rest), 4)
    return out

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(os.path.join(rec, "count"), "a") as f:
            f.write("x\n")
        with open(os.path.join(rec, "path"), "w") as f:
            f.write(self.path)
        with open(os.path.join(rec, "headers"), "w") as f:
            f.write(str(self.headers))
        with open(os.path.join(rec, "body"), "wb") as f:
            f.write(body)
        mode = open(mode_file).read().strip()
        req = json.loads(body)
        labels = list(req["questions"]["decision"]["criteria"].keys())
        status, answer = 200, None
        if mode == "decided":
            answer = {"choice": labels[0], "probabilities": probs(labels, 0.9, 0.06), "confidence": 0.86}
        elif mode == "low-confidence":
            answer = {"choice": labels[0], "probabilities": probs(labels, 0.9, 0.06), "confidence": 0.55}
        elif mode == "close-margin":
            answer = {"choice": labels[0], "probabilities": probs(labels, 0.5, 0.42), "confidence": 0.8}
        elif mode == "disagree":
            answer = {"choice": labels[1], "probabilities": probs(labels, 0.9, 0.06), "confidence": 0.9}
        elif mode == "wrong-labels":
            answer = {"choice": "other", "probabilities": {"other": 1.0}, "confidence": 0.9}
        elif mode == "slow":
            time.sleep(4)
            answer = {"choice": labels[0], "probabilities": probs(labels, 0.9, 0.06), "confidence": 0.86}
        elif mode == "error":
            auth = self.headers.get("Authorization", "")
            key = auth.split(" ", 1)[-1]
            status = 500
            payload = {"error": {"message": "upstream failed for key " + key + " (" + key[:4] + "****" + key[-4:] + ", sk-..." + key[-4:] + ")"}}
        if answer is not None:
            answer["type"] = "choice"
            payload = {"model": "typesafe/jev-stub", "answers": {"decision": answer},
                       "usage": {"input_tokens": 10, "output_tokens": 2}}
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

class Server(HTTPServer):
    # HTTPServer.server_bind resolves the host's FQDN, which can stall for
    # seconds on macOS; the stub only needs the bound loopback port.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]

server = Server(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
PY

SERVER_PID=
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null
  fm_test_cleanup
}
trap cleanup EXIT
python3 "$TMP_ROOT/server.py" "$REC" "$MODE" "$TMP_ROOT/port" &
SERVER_PID=$!
for _ in $(seq 1 100); do
  [ -s "$TMP_ROOT/port" ] && break
  sleep 0.05
done
[ -s "$TMP_ROOT/port" ] || fail "stub decisions server did not start"
BASE="http://127.0.0.1:$(cat "$TMP_ROOT/port")"

reset_rec() { rm -f "$REC"/*; }
request_count() { if [ -f "$REC/count" ]; then wc -l < "$REC/count" | tr -d ' '; else echo 0; fi; }

# run <exit-var> <out-var> <err-var> <tool> [args...]; the caller sets any
# JEV_DECIDE_* configuration in the environment of this call.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$PATH" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

code='' out='' err=''
OPTS=(--question "Which cache backend should the pager use?"
  --option "memory=Keep entries in an in-process map"
  --option "disk=Persist entries to a local file"
  --option "none=Do not cache at all")

# --- decided --------------------------------------------------------------------
reset_rec
printf 'decided\n' > "$MODE"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY \
  run code out err "$CLI" "${OPTS[@]}" --context "The pager is called once per keypress."
expect_code 0 "$code" "decided exits 0"
assert_contains "$out" "verdict: decided" "decided verdict is printed"
assert_contains "$out" "choice: memory" "decided choice is printed"
assert_contains "$out" "confidence: 0.86" "decided confidence is printed"
assert_contains "$out" "probabilities: memory=0.9 disk=0.06 none=0.04" "probabilities print most probable first"
assert_not_contains "$out" "leaning:" "a decided answer has no leaning line"
assert_equals /openrouter/alpha/decisions "$(cat "$REC/path")" "default path is the LiteLLM OpenRouter pass-through"
jq -e '
  .model == "typesafe/jev-1.13" and
  .state.context == "The pager is called once per keypress." and
  .questions.decision.type == "choice" and
  .questions.decision.instructions == "Which cache backend should the pager use?" and
  .questions.decision.criteria == {"memory": "Keep entries in an in-process map", "disk": "Persist entries to a local file", "none": "Do not cache at all"}
' "$REC/body" >/dev/null || fail "request body is not the documented choice question: $(cat "$REC/body")"
assert_grep "Authorization: Bearer $KEY" "$REC/headers" "the key reaches the server as a bearer header"
assert_no_grep "$KEY" "$REC/curl.argv" "the key never appears on curl's argv"
assert_no_grep "$KEY" "$REC/curl.env" "the key never appears in curl's environment"
assert_not_contains "$out$err" "$KEY" "the key never appears in output"
pass "a strong answer is decided, and the key travels only as a header"

reset_rec
JEV_DECIDE_BASE_URL="$BASE/" JEV_DECIDE_PATH=door/decide JEV_DECIDE_MODEL='~typesafe/jev-latest' JEV_DECIDE_API_KEY=$KEY \
  run code out err "$CLI" "${OPTS[@]}" --json
expect_code 0 "$code" "json decided exits 0"
jq -e '.verdict == "decided" and .choice == "memory" and .leaning == null and .reason == null and
  .confidence == 0.86 and (.probabilities | keys_unsorted) == ["memory", "disk", "none"] and
  .model == "typesafe/jev-stub" and (.latency_ms | type) == "number" and .floor == 0.7 and .margin == 0.15' \
  <<<"$out" >/dev/null || fail "json output is not the documented decided object: $out"
assert_equals /door/decide "$(cat "$REC/path")" "JEV_DECIDE_PATH replaces the default path"
jq -e '.model == "~typesafe/jev-latest" and .state.context == "(no additional context provided)"' "$REC/body" >/dev/null \
  || fail "model override or empty context default not sent: $(cat "$REC/body")"
pass "json output, path, and model are configurable"

printf 'Context read from a file.\n' > "$TMP_ROOT/context.txt"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY run code out err "$CLI" "${OPTS[@]}" --context-file "$TMP_ROOT/context.txt"
jq -e '.state.context == "Context read from a file."' "$REC/body" >/dev/null || fail "context file not sent"
out=$(printf 'Context from stdin.' | JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY PATH="$FAKEBIN:$PATH" "$CLI" "${OPTS[@]}" --context-file -)
jq -e '.state.context == "Context from stdin."' "$REC/body" >/dev/null || fail "stdin context not sent"
pass "context comes from a file or stdin"

# --- inconclusive ---------------------------------------------------------------
printf 'low-confidence\n' > "$MODE"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY run code out err "$CLI" "${OPTS[@]}"
expect_code 0 "$code" "low confidence exits 0"
assert_contains "$out" "verdict: inconclusive" "low confidence is inconclusive"
assert_contains "$out" "reason: confidence 0.55 below floor 0.7" "low confidence names the floor"
assert_contains "$out" "leaning: memory" "low confidence still reports the leaning"
assert_not_contains "$out" "choice:" "an inconclusive answer never prints a choice"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY JEV_DECIDE_CONFIDENCE_FLOOR=0.5 run code out err "$CLI" "${OPTS[@]}"
assert_contains "$out" "verdict: decided" "a lowered floor accepts the same answer"
pass "confidence below the floor is inconclusive"

printf 'close-margin\n' > "$MODE"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY run code out err "$CLI" "${OPTS[@]}" --json
expect_code 0 "$code" "close margin exits 0"
jq -e '.verdict == "inconclusive" and .choice == null and .leaning == "memory" and
  (.reason | test("top two options memory and disk are 0.08 apart, within margin 0.15"))' <<<"$out" >/dev/null \
  || fail "close margin is not inconclusive with the margin reason: $out"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY JEV_DECIDE_MARGIN=0.05 run code out err "$CLI" "${OPTS[@]}"
assert_contains "$out" "verdict: decided" "a narrower margin accepts the same answer"
pass "top two options within the margin are inconclusive"

printf 'disagree\n' > "$MODE"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY run code out err "$CLI" "${OPTS[@]}"
assert_contains "$out" "verdict: inconclusive" "a choice contradicting its probabilities is inconclusive"
assert_contains "$out" "reason: choice disk is not the single most probable option" "contradiction is named"
printf 'wrong-labels\n' > "$MODE"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY run code out err "$CLI" "${OPTS[@]}"
assert_contains "$out" "verdict: inconclusive" "an answer for other options is inconclusive"
assert_contains "$out" "reason: response is not a valid choice answer for these options" "malformed answer is named"
pass "self-contradictory or malformed answers are inconclusive"

# --- errors ---------------------------------------------------------------------
printf 'error\n' > "$MODE"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY run code out err "$CLI" "${OPTS[@]}"
expect_code 0 "$code" "http error exits 0"
assert_contains "$out" "verdict: inconclusive" "http error is inconclusive"
assert_contains "$out" "reason: http 500 after" "http error names the status"
assert_contains "$out" "upstream failed for key [redacted] ([redacted], [redacted])" "an echoed key is redacted whole and masked"
assert_not_contains "$out$err" "$KEY" "an echoed key never reaches output"
assert_not_contains "$out$err" "4f9a8b7c6d5e" "no key fragment reaches output"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY run code out err "$CLI" "${OPTS[@]}" --json
jq -e '.verdict == "inconclusive" and .choice == null and .leaning == null and (.reason | startswith("http 500"))' <<<"$out" >/dev/null \
  || fail "json http error is not inconclusive: $out"
pass "an HTTP error is inconclusive and redacts any echoed key"

printf 'slow\n' > "$MODE"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY JEV_DECIDE_TIMEOUT=1 run code out err "$CLI" "${OPTS[@]}"
expect_code 0 "$code" "timeout exits 0"
assert_contains "$out" "reason: request timed out after 1s" "timeout is inconclusive with its reason"
pass "a timeout is inconclusive"

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
JEV_DECIDE_BASE_URL="http://127.0.0.1:$port" JEV_DECIDE_API_KEY=$KEY run code out err "$CLI" "${OPTS[@]}"
expect_code 0 "$code" "connection failure exits 0"
assert_contains "$out" "reason: request failed (curl exit 7)" "connection failure is inconclusive"
pass "a network failure is inconclusive"

# --- missing configuration -------------------------------------------------------
printf 'decided\n' > "$MODE"
reset_rec
env -u JEV_DECIDE_BASE_URL JEV_DECIDE_API_KEY=$KEY PATH="$FAKEBIN:$PATH" "$CLI" "${OPTS[@]}" > "$TMP_ROOT/out" 2>&1
expect_code 0 "$?" "missing base URL exits 0"
assert_grep "reason: not configured: JEV_DECIDE_BASE_URL is unset" "$TMP_ROOT/out" "missing base URL is named"
env -u JEV_DECIDE_API_KEY JEV_DECIDE_BASE_URL="$BASE" PATH="$FAKEBIN:$PATH" "$CLI" "${OPTS[@]}" --json > "$TMP_ROOT/out" 2>&1
expect_code 0 "$?" "missing key exits 0"
jq -e '.verdict == "inconclusive" and .reason == "not configured: JEV_DECIDE_API_KEY is unset"' "$TMP_ROOT/out" >/dev/null \
  || fail "missing key is not an inconclusive json verdict: $(cat "$TMP_ROOT/out")"
JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$'sk-a\nInjected: yes' run code out err "$CLI" "${OPTS[@]}"
assert_contains "$out" "reason: not configured: JEV_DECIDE_API_KEY contains whitespace or control characters" "a multi-line key is refused"
assert_absent "$REC/curl.argv" "missing configuration makes no network call"
assert_equals 0 "$(request_count)" "missing configuration never reaches the server"
pass "missing configuration is inconclusive with a clear reason and no network call"

# --- usage errors ---------------------------------------------------------------
for bad in \
  "at least two --option values are required|--question|q|--option|a=x" \
  "--question is required|--option|a=x|--option|b=y" \
  "duplicate option label: a|--question|q|--option|a=x|--option|a=y" \
  "option label must be 1-64|--question|q|--option|-a=x|--option|b=y" \
  "option b needs a non-empty description|--question|q|--option|a=x|--option|b=" \
  "--option needs <label>=<description>|--question|q|--option|a" \
  "unknown argument: --bogus|--bogus"; do
  IFS='|' read -r -a parts <<<"$bad"
  JEV_DECIDE_BASE_URL=$BASE JEV_DECIDE_API_KEY=$KEY run code out err "$CLI" "${parts[@]:1}"
  expect_code 2 "$code" "usage error exits 2: ${parts[0]}"
  assert_contains "$err" "${parts[0]}" "usage error is named: ${parts[0]}"
done
for tuning in JEV_DECIDE_CONFIDENCE_FLOOR=1.5 JEV_DECIDE_CONFIDENCE_FLOOR=.7 JEV_DECIDE_MARGIN=-0.1 JEV_DECIDE_TIMEOUT=0 JEV_DECIDE_TIMEOUT=301; do
  run code out err env "$tuning" JEV_DECIDE_BASE_URL="$BASE" JEV_DECIDE_API_KEY="$KEY" "$CLI" "${OPTS[@]}"
  expect_code 2 "$code" "invalid tuning exits 2: $tuning"
  assert_contains "$err" "${tuning%%=*} must be" "invalid tuning is named: $tuning"
done
run code out err "$CLI" --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" "Usage:" "--help prints usage"
assert_absent "$REC/curl.argv" "usage errors make no network call"
pass "usage and tuning errors exit 2 before any network call"

# --- firstmate entry point --------------------------------------------------------
reset_rec
cat > "$HOME_DIR/.env" <<ENV
JEV_DECIDE_BASE_URL=$BASE
export JEV_DECIDE_API_KEY="$KEY"
JEV_DECIDE_PATH=/from-dotenv
ENV
env -u JEV_DECIDE_BASE_URL -u JEV_DECIDE_API_KEY -u JEV_DECIDE_PATH FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
  "$WRAPPER" "${OPTS[@]}" > "$TMP_ROOT/out" 2>&1
expect_code 0 "$?" "wrapper with .env config exits 0"
assert_grep "verdict: decided" "$TMP_ROOT/out" "wrapper reads its configuration from the home .env"
assert_equals /from-dotenv "$(cat "$REC/path")" "wrapper passes .env path through"
assert_grep "Authorization: Bearer $KEY" "$REC/headers" "wrapper passes the .env key as the bearer header"
assert_no_grep "$KEY" "$REC/curl.argv" "wrapper never puts the key on argv"
assert_no_grep "$KEY" "$REC/curl.env" "wrapper key never reaches curl's environment"

JEV_DECIDE_PATH=/from-env FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" JEV_DECIDE_BASE_URL='' JEV_DECIDE_API_KEY='' \
  "$WRAPPER" "${OPTS[@]}" > "$TMP_ROOT/out" 2>&1
assert_grep "verdict: decided" "$TMP_ROOT/out" "empty environment values fall back to .env"
assert_equals /from-env "$(cat "$REC/path")" "a non-empty environment value wins over .env"

reset_rec
env -u JEV_DECIDE_BASE_URL -u JEV_DECIDE_API_KEY FM_HOME="$TMP_ROOT/empty-home" PATH="$FAKEBIN:$PATH" \
  "$WRAPPER" "${OPTS[@]}" > "$TMP_ROOT/out" 2>&1
expect_code 0 "$?" "unconfigured wrapper exits 0"
assert_grep "reason: not configured: JEV_DECIDE_BASE_URL is unset" "$TMP_ROOT/out" "unconfigured wrapper is inconclusive"
assert_equals 0 "$(request_count)" "unconfigured wrapper makes no request"
pass "fm-decide.sh reads JEV_DECIDE_* from the environment first, then the home .env"

printf '# all fm-decide tests passed\n'
