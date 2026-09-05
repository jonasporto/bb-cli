#!/usr/bin/env bash
#
# Black-box tests for `bb-cli api`, the authenticated passthrough.
#
# What these guard: the contract a session relies on when it reaches for `api`
# instead of `curl`. Method defaulting, :repo expansion, where fields land
# (query string on a read, JSON body on a write), byte-exact --input, jq
# filtering, header inclusion, pagination, and a non-zero exit on HTTP >= 400.
#
# No network: a fake curl on PATH records the argv and answers from a fixture.
#
# Run: tests/api_test.sh
set -u

# shellcheck source=tests/lib/fake_curl.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/fake_curl.sh"
harness_init

# A checkout with a Bitbucket origin, so :repo has something to expand from.
REPO_DIR="$TMP/checkout"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" remote add origin git@bitbucket.org:myworkspace/myrepo.git
cd "$REPO_DIR"

echo "api tests"

# --- endpoint resolution ---------------------------------------------------

run_bb api "repositories/:repo/pullrequests/10"
assert_contains "https://api.bitbucket.org/2.0/repositories/myworkspace/myrepo/pullrequests/10" \
    "$CURL_CALLS" ":repo expands from the git remote and 2.0/ is prefixed"

run_bb api "2.0/user"
assert_contains "https://api.bitbucket.org/2.0/user" "$CURL_CALLS" \
    "an explicit 2.0/ prefix is not doubled"

run_bb api "internal/repositories/:repo/pipelines/1"
assert_contains "https://api.bitbucket.org/internal/repositories/myworkspace/myrepo" \
    "$CURL_CALLS" "internal/ is kept, not forced under 2.0/"

run_bb api "https://api.bitbucket.org/2.0/repositories/other/thing"
assert_contains "https://api.bitbucket.org/2.0/repositories/other/thing" "$CURL_CALLS" \
    "a full Bitbucket URL passes through untouched"
# Hosts other than Bitbucket are refused; see tests/security_test.sh.

run_bb api "repositories/{workspace}/{slug}/commits"
assert_contains "repositories/myworkspace/myrepo/commits" "$CURL_CALLS" \
    "{workspace} and {slug} expand separately"

# Bitbucket wraps pipeline and step uuids in braces and then rejects them in a
# path unless the braces are percent-encoded: a raw {uuid} answers 400, which
# reads like a malformed request or a missing scope and is neither. The
# porcelain commands encode; `api` used not to, so copying a uuid from one into
# the other failed for a reason nothing explained. Reported from a real session
# that lost time to it and fell back to curl.
run_bb api "repositories/:repo/pipelines/{be3059e8-163d-4651-a950-ba450d92e45d}/stopPipeline" -X POST
assert_contains "pipelines/%7Bbe3059e8-163d-4651-a950-ba450d92e45d%7D/stopPipeline" "$CURL_CALLS" \
    "a brace-wrapped uuid is percent-encoded"
assert_not_contains "pipelines/{be3059e8" "$CURL_CALLS" "and the raw braces never reach curl"

run_bb api "repositories/:repo/pipelines/1234/steps/{a1b2c3d4-5e6f-7890-abcd-ef1234567890}/log"
assert_contains "steps/%7Ba1b2c3d4-5e6f-7890-abcd-ef1234567890%7D/log" "$CURL_CALLS" \
    "a uuid mid-path is encoded too"

run_bb api "repositories/:repo/pipelines/%7Balready-encoded%7D/x"
assert_contains "pipelines/%7Balready-encoded%7D/x" "$CURL_CALLS" \
    "an already-encoded uuid is not double-encoded"
assert_not_contains "%257B" "$CURL_CALLS" "no %257B anywhere"

run_bb api "https://api.bitbucket.org/2.0/repositories/w/r/pipelines/{be3059e8-163d-4651-a950-ba450d92e45d}"
assert_contains "pipelines/%7Bbe3059e8-163d-4651-a950-ba450d92e45d%7D" "$CURL_CALLS" \
    "a full URL gets its path encoded as well"
assert_contains "https://api.bitbucket.org/2.0/" "$CURL_CALLS" "with the authority untouched"

# POST /pipelines/ needs its trailing slash; splitting the path must not eat it.
run_bb api "repositories/:repo/pipelines/" -X POST --input /dev/null
assert_contains "myrepo/pipelines/ " "$CURL_CALLS " "a trailing slash survives the encoding pass"

# A 204 has no body. This is NOT a parser problem - it exits 0 and prints
# nothing, which is what gh does. Asserted so nobody "fixes" it into noise.
CURL_STATUS=204 ; export CURL_STATUS
: > "$CURL_BODY"
run_bb api "repositories/:repo/pipelines/{be3059e8-163d-4651-a950-ba450d92e45d}/stopPipeline" -X POST
assert_eq "0" "$BB_RC" "a 204 with no body exits 0"
assert_eq "" "$BB_OUT" "and prints nothing at all"
CURL_STATUS=200 ; export CURL_STATUS
echo '{"ok":true}' > "$CURL_BODY"

run_bb api "repositories/:repo" --repo other-ws/other-repo
assert_contains "repositories/other-ws/other-repo" "$CURL_CALLS" \
    "--repo overrides the git remote"

# --- method defaulting -----------------------------------------------------

run_bb api "repositories/:repo"
assert_contains "-X GET" "$CURL_CALLS" "a bare call defaults to GET"

# Deliberately NOT gh's rule. gh makes -f/-F imply POST; here a POST to
# /pullrequests creates a pull request, so fields must never change the method.
run_bb api "repositories/:repo/pullrequests" -f 'q=state="OPEN"'
assert_contains "-X GET" "$CURL_CALLS" "a field alone does NOT imply POST"

run_bb api "repositories/:repo/pullrequests/10" --input /dev/null
assert_contains "-X POST" "$CURL_CALLS" "--input implies POST"

run_bb api "repositories/:repo/pullrequests/10" -X PUT --input /dev/null
assert_contains "-X PUT" "$CURL_CALLS" "-X wins over the implied method"

run_bb api "repositories/:repo/caches/abc" -X delete
assert_contains "-X DELETE" "$CURL_CALLS" "the method is upper-cased"

# --- redirects: reads follow, writes must not ------------------------------

run_bb api "repositories/:repo/pipelines/1/steps/2/log"
assert_contains "-L" "$CURL_CALLS" "GET follows redirects (step logs 307 to storage)"

run_bb api "repositories/:repo/pipelines/" -X POST -F key=value
assert_not_contains " -L " " $CURL_CALLS " "POST does not follow redirects"

# --- where fields land -----------------------------------------------------

run_bb api "repositories/:repo/pullrequests" -f 'q=state="OPEN"'
assert_contains "--get" "$CURL_CALLS" "fields on a read become query parameters"
assert_contains 'q=state="OPEN"' "$CURL_CALLS" "the query value reaches curl for encoding"

run_bb api "repositories/:repo/statuses" -X POST -f key=local -f state=SUCCESSFUL
assert_contains '"key":"local"' "$CURL_BODIES" "-f builds a JSON body on a write"
assert_contains '"state":"SUCCESSFUL"' "$CURL_BODIES" "every -f pair lands in the body"

run_bb api "repositories/:repo/thing" -X POST -F count=3 -F draft=true -F note=hello
assert_contains '"count":3' "$CURL_BODIES" "-F leaves a number unquoted"
assert_contains '"draft":true' "$CURL_BODIES" "-F leaves a boolean unquoted"
assert_contains '"note":"hello"' "$CURL_BODIES" "-F still quotes a plain string"

# A value that only looks numeric must not be mangled by -f.
run_bb api "repositories/:repo/thing" -X POST -f version=3
assert_contains '"version":"3"' "$CURL_BODIES" "-f keeps a numeric-looking value a string"

# --- --input is byte-exact -------------------------------------------------
# This is the one that matters: getting Jira cards to stack in a PR body needs
# two trailing spaces per line preserved, and shell quoting eats them.

printf '{"description":"line one  \nline two  \n"}' > "$TMP/body.json"
run_bb api "repositories/:repo/pullrequests/10" -X PUT --input "$TMP/body.json"
assert_contains 'line one  ' "$CURL_BODIES" "--input preserves trailing spaces"
assert_contains "Content-Type: application/json" "$CURL_CALLS" "--input sets the JSON content type"

# A pipe would run run_bb in a subshell and lose every variable it sets, so the
# stdin case is fed by redirect.
echo '{"title":"from stdin"}' > "$TMP/stdin.json"
run_bb api "repositories/:repo/pullrequests/10" -X PUT --input - < "$TMP/stdin.json"
assert_contains "from stdin" "$CURL_BODIES" "--input - reads the body from stdin"

run_bb api "repositories/:repo/x" -X PUT --input "$TMP/does-not-exist.json"
assert_eq "1" "$BB_RC" "a missing --input file is an error, not a silent empty body"
assert_not_contains "api.bitbucket.org" "$CURL_CALLS" "a missing --input file makes no request"

# --- output shaping --------------------------------------------------------

echo '{"description":"the body text","id":10}' > "$CURL_BODY"
run_bb api "repositories/:repo/pullrequests/10" -q .description
assert_eq "the body text" "$BB_OUT" "-q extracts a raw field, no python needed"

run_bb api "repositories/:repo/pullrequests/10" -i
assert_contains "x-oauth-scopes" "$BB_OUT" "-i prints response headers"
assert_contains "HTTP/2 200" "$BB_OUT" "-i prints the status line"

run_bb api "repositories/:repo/pullrequests/10"
assert_contains '"id": 10' "$BB_OUT" "the default output is pretty-printed JSON"

run_bb api "repositories/:repo/x" -H "X-Custom: yes"
assert_contains "X-Custom: yes" "$CURL_CALLS" "-H passes an extra header through"

# --- pagination ------------------------------------------------------------
# The fake curl answers the same page every time, so `next` has to be dropped
# after the first page or the loop would never end. Fixture: one page, no next.

echo '{"values":[{"k":1},{"k":2}]}' > "$CURL_BODY"
run_bb api "repositories/:repo/pullrequests" --paginate -q '.values | length'
assert_eq "2" "$BB_OUT" "--paginate merges .values across pages"

# --- errors ----------------------------------------------------------------

CURL_STATUS=404 ; export CURL_STATUS
echo '{"type":"error","error":{"message":"Not found"}}' > "$CURL_BODY"
run_bb api "repositories/:repo/pullrequests/999999"
assert_eq "1" "$BB_RC" "HTTP 404 exits non-zero"
assert_contains "Not found" "$BB_OUT" "the error body is still printed, like gh"
assert_contains "HTTP 404" "$BB_OUT" "the status code is named on stderr"

CURL_STATUS=403 ; export CURL_STATUS
echo '{"error":{"detail":{"required":["admin:repository:bitbucket"]}}}' > "$CURL_BODY"
run_bb api "repositories/:repo/branch-restrictions"
assert_eq "1" "$BB_RC" "HTTP 403 exits non-zero"
assert_contains "bb-cli docs scopes" "$BB_OUT" "a 403 points at the scopes doc"

CURL_STATUS=200 ; export CURL_STATUS
echo '{"ok":true}' > "$CURL_BODY"

# --- argument hygiene ------------------------------------------------------

run_bb api
assert_eq "1" "$BB_RC" "no endpoint is an error"
assert_contains "Usage: bb-cli api" "$BB_OUT" "no endpoint prints usage"

run_bb api "repositories/:repo" --nonsense
assert_eq "1" "$BB_RC" "an unknown flag is rejected, not ignored"
assert_contains "unknown flag" "$BB_OUT" "the unknown flag is named"

run_bb api --help
assert_eq "0" "$BB_RC" "--help exits 0"
assert_contains "gh api" "$BB_OUT" "--help says what this is the analogue of"

summary
