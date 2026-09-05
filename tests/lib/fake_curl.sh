#!/usr/bin/env bash
#
# Shared test harness: a fake `curl` on PATH that records every invocation and
# answers from a canned fixture. No network, so the whole suite runs in the time
# a single real request would take.
#
# Source this, then call `harness_init`. It exports:
#   TMP         a scratch dir, removed on exit
#   CURL_LOG    every fake-curl argv, one invocation per line
#   CURL_BODY   file whose contents the fake curl echoes as the response body
#   CURL_STATUS the HTTP status the fake curl writes into the -D header file
#
# Assertions: assert_contains / assert_not_contains / assert_eq, and `summary`
# which prints the tally and sets the exit status.

harness_init() {
    BBCLI="$(cd "$(dirname "${BASH_SOURCE[1]}")/../bin" && pwd)/bb-cli"
    export BBCLI
    TMP="$(mktemp -d)"
    export TMP
    trap 'rm -rf "$TMP"' EXIT

    export BITBUCKET_USERNAME="test-user"
    export BITBUCKET_API_TOKEN="test-token"
    export CURL_LOG="$TMP/curl.log"
    export CURL_BODY="$TMP/response.json"
    export CURL_STATUS="200"
    : > "$CURL_LOG"
    echo '{"ok":true}' > "$CURL_BODY"

    cat > "$TMP/curl" <<'FAKE'
#!/usr/bin/env bash
# Record the argv, then answer from the fixture. Honours -D by writing a header
# block with $CURL_STATUS, which is what bb-cli parses the status code out of.
echo "$@" >> "$CURL_LOG"

hdr=""
prev=""
for a in "$@"; do
  [[ "$prev" == "-D" ]] && hdr="$a"
  prev="$a"
done

if [[ -n "$hdr" ]]; then
  {
    printf 'HTTP/2 %s\r\n' "${CURL_STATUS:-200}"
    printf 'content-type: application/json\r\n'
    printf 'x-oauth-scopes: read:repository:bitbucket, read:pullrequest:bitbucket\r\n'
    printf '\r\n'
  } > "$hdr"
fi

# --data-binary/-d bodies are recorded separately so tests can assert on the
# exact JSON that would go over the wire.
prev=""
for a in "$@"; do
  case "$prev" in
    --data-binary|-d|--data) printf '%s\n' "$a" >> "${CURL_LOG}.body" ;;
  esac
  prev="$a"
done

# Honour -o, the way real curl does: bb-cli writes the body to a file so the
# status code survives (a command substitution would run it in a subshell).
out=""
prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  prev="$a"
done

if [[ -n "$out" ]]; then
  cat "${CURL_BODY:-/dev/null}" > "$out"
else
  cat "${CURL_BODY:-/dev/null}"
fi
FAKE
    chmod +x "$TMP/curl"
    export PATH="$TMP:$PATH"

    pass=0
    fail=0
}

# Run bb-cli with a clean log. Captures BB_OUT, BB_RC, CURL_CALLS, CURL_BODIES.
run_bb() {
    : > "$CURL_LOG"
    : > "${CURL_LOG}.body"
    set +e
    BB_OUT="$("$BBCLI" "$@" 2>&1)"
    BB_RC=$?
    set -e
    CURL_CALLS="$(cat "$CURL_LOG")"
    CURL_BODIES="$(cat "${CURL_LOG}.body" 2>/dev/null || true)"
}

assert_contains() {
    if [[ "$2" == *"$1"* ]]; then
        echo "  ok   - $3"
        pass=$((pass + 1))
    else
        echo "  FAIL - $3"
        echo "         expected substring: '$1'"
        echo "         in: $(printf '%s' "$2" | head -c 400)"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    if [[ "$2" != *"$1"* ]]; then
        echo "  ok   - $3"
        pass=$((pass + 1))
    else
        echo "  FAIL - $3 (unexpected substring: '$1')"
        fail=$((fail + 1))
    fi
}

assert_eq() {
    if [[ "$1" == "$2" ]]; then
        echo "  ok   - $3"
        pass=$((pass + 1))
    else
        echo "  FAIL - $3 (expected '$1', got '$2')"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "passed: $pass   failed: $fail"
    [[ "$fail" -eq 0 ]]
}
