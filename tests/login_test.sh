#!/usr/bin/env bash
#
# Black-box tests for `bb-cli login`, the first command a new user runs.
#
# What these guard:
#   - the instructions match docs/setup.md. They pointed at the superseded
#     app-password page and at read-only permissions for a while, which hands a
#     new user a credential that cannot edit a PR or trigger a pipeline.
#   - `--with-token`, the non-interactive form. Without it an agent or a CI job
#     reaches `read -p`, gets EOF, and cannot finish onboarding at all.
#   - a non-tty run says so instead of failing on a prompt nobody could see.
#   - the credentials file lands 600 in a 700 directory, and the token is
#     written through printf %q rather than raw (the file is sourced).
#
# No network: a fake curl on PATH answers from a fixture.
#
# Run: tests/login_test.sh
set -u

# shellcheck source=tests/lib/fake_curl.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/fake_curl.sh"
harness_init

# login verifies with `curl -w '\n%{http_code}'` and reads the status off the
# last line. The fake curl does not implement -w, so the fixture carries it.
printf '%s\n200\n' '{"account_id":"abc"}' > "$CURL_BODY"

# A HOME of its own: these tests write a credentials file.
export HOME="$TMP/home"
mkdir -p "$HOME"
CREDS="$HOME/.config/bb-cli/credentials"

# The environment would win over the file and short-circuit what we are testing.
unset BITBUCKET_USERNAME BITBUCKET_API_TOKEN

echo "login tests"

# --- the instructions are the ones docs/setup.md gives --------------------

run_bb login < /dev/null
assert_contains "id.atlassian.com/manage-profile/security/api-tokens" "$BB_OUT" \
    "it points at Atlassian API tokens, not the superseded app-password page"
assert_contains "write:pullrequest:bitbucket" "$BB_OUT" \
    "it names the write scopes, not just the read ones"
assert_contains "write does not imply read" "$BB_OUT" \
    "it states the trap that costs a token re-creation"
assert_contains "EMAIL" "$BB_OUT" \
    "it says the username is an account email"

# --- a non-terminal stdin is told what to do instead ----------------------

assert_eq "1" "$BB_RC" "an interactive login with no terminal exits 1"
assert_contains "stdin is not a terminal" "$BB_OUT" "it says why"
assert_contains "--with-token" "$BB_OUT" "and names the form that does work"
assert_contains "BITBUCKET_API_TOKEN" "$BB_OUT" "and the environment escape hatch"
[[ -f "$CREDS" ]] && { echo "  FAIL - a failed login wrote a credentials file"; fail=$((fail + 1)); } \
                  || { echo "  ok   - a failed login writes no credentials file"; pass=$((pass + 1)); }

# --- --with-token: the form a script or an agent can complete --------------

: > "$CURL_LOG"
set +e
BB_OUT="$(printf %s 'tok-123' | "$BBCLI" login --with-token --email "me@example.com" 2>&1)"
BB_RC=$?
set -e
CURL_CALLS="$(cat "$CURL_LOG")"

assert_eq "0" "$BB_RC" "--with-token succeeds without prompting"
assert_contains "me@example.com:tok-123" "$CURL_CALLS" \
    "the credential is verified against the API before anything is written"
assert_contains "me@example.com" "$(cat "$CREDS" 2>/dev/null || echo MISSING)" \
    "the email is stored"
assert_contains "tok-123" "$(cat "$CREDS" 2>/dev/null || echo MISSING)" \
    "the token is stored"

# --- the file is only as readable as it has to be -------------------------

# GNU `stat -f` means "file system status", not "format", so it SUCCEEDS while
# printing filesystem details. A `stat -f ... || stat -c ...` fallback therefore
# never reaches the GNU form and silently compares garbage. Try GNU first: its
# -c is rejected outright by BSD stat.
file_mode() {
    stat -c '%a' "$1" 2> /dev/null || stat -f '%Lp' "$1" 2> /dev/null
}

assert_eq "600" "$(file_mode "$CREDS")" "the credentials file is mode 600"
assert_eq "700" "$(file_mode "$HOME/.config/bb-cli")" "its directory is mode 700"

# The file is sourced on every run, so a token containing shell metacharacters
# must be stored quoted or it becomes code.
: > "$CURL_LOG"
set +e
printf %s 'tok$(touch "'"$TMP"'/pwned")' | "$BBCLI" login --with-token --email "me@example.com" > /dev/null 2>&1
set -e
[[ -e "$TMP/pwned" ]] && { echo "  FAIL - a token containing \$() executed when the file was read"; fail=$((fail + 1)); } \
                      || { echo "  ok   - a token containing \$() is stored quoted, not executed"; pass=$((pass + 1)); }

run_bb status
assert_contains "me@example.com" "$BB_OUT" "and status reads the stored credential back"

# --- empty stdin is a clear error, not a silent empty token ---------------

run_bb login --with-token --email "me@example.com" < /dev/null
assert_eq "1" "$BB_RC" "--with-token with empty stdin exits 1"
assert_contains "stdin was empty" "$BB_OUT" "it says stdin was empty"

# --- no email anywhere ----------------------------------------------------

set +e
BB_OUT="$(cd "$TMP" && printf %s 'tok' | env -u BITBUCKET_USERNAME HOME="$TMP/empty-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$BBCLI" login --with-token 2>&1)"
BB_RC=$?
set -e
assert_eq "1" "$BB_RC" "--with-token with no email anywhere exits 1"
assert_contains "not a Bitbucket username" "$BB_OUT" "it says which identifier it wants"

# --- the flag surface -----------------------------------------------------

run_bb login --help
assert_eq "0" "$BB_RC" "login --help exits 0"
assert_contains "--with-token" "$BB_OUT" "the help documents the non-interactive form"
assert_contains "BITBUCKET_API_TOKEN" "$BB_OUT" "and the environment alternative"

run_bb login --nonsense
assert_eq "1" "$BB_RC" "an unknown flag is rejected"

summary
