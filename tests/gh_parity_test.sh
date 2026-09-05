#!/usr/bin/env bash
#
# The command surface tracks `gh` wherever Bitbucket allows it. That is a design
# rule, not a coincidence, so it needs a test: someone adding a command should
# find out here that they picked a name `gh` does not use.
#
# Where the names differ, Bitbucket's noun is primary and gh's is an alias, a
# pipeline is what Bitbucket calls it in its UI, its docs and its API.
#
# Run: tests/gh_parity_test.sh
set -u

# shellcheck source=tests/lib/fake_curl.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/fake_curl.sh"
harness_init

# Capture before the cd below: BASH_SOURCE is relative.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO_DIR="$TMP/checkout"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" remote add origin git@bitbucket.org:myworkspace/myrepo.git
cd "$REPO_DIR"

echo "gh parity tests"

# --- gh's nouns are accepted ------------------------------------------------

echo '{"values":[],"page":1,"size":0,"pagelen":10}' > "$CURL_BODY"

run_bb run --limit 2
assert_eq "0" "$BB_RC" "'run' works as gh's noun for a pipeline"
assert_contains "/pipelines" "$CURL_CALLS" "and reaches the pipelines endpoint"

run_bb runs --limit 2
assert_eq "0" "$BB_RC" "'runs' too"

run_bb auth status
assert_contains "Authentication Status" "$BB_OUT" "gh-style 'auth status' works"

run_bb status
assert_contains "Authentication Status" "$BB_OUT" "and so does the top-level form"

run_bb auth --help
assert_contains "login" "$BB_OUT" "auth --help lists its subcommands"

# --- view, on both nouns ----------------------------------------------------

cat > "$CURL_BODY" <<'JSON'
{"id":10,"title":"A pull request","description":"body","state":"OPEN",
 "author":{"display_name":"Someone"},
 "source":{"branch":{"name":"feature"},"commit":{"hash":"abc123def456"}},
 "destination":{"branch":{"name":"master"}},
 "created_on":"2026-08-01T10:00:00.000Z","updated_on":"2026-08-02T10:00:00.000Z",
 "links":{"html":{"href":"https://bitbucket.org/x/y/pull-requests/10"}},
 "participants":[],"values":[],"uuid":"{abc}","build_number":10,
 "state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}}}
JSON

run_bb pr view 10
assert_eq "0" "$BB_RC" "gh-style 'pr view <n>' works"
assert_contains "PR #10" "$BB_OUT" "and shows the pull request"

run_bb pr 10
assert_contains "PR #10" "$BB_OUT" "the bare form still works"

run_bb pipeline view 10
assert_eq "0" "$BB_RC" "gh-style 'pipeline view <n>' works"

# --- gh pr checks -----------------------------------------------------------
# On Bitbucket the checks on a pull request are the build statuses on its head
# commit, the same objects `bb-cli signoff` writes.

run_bb pr checks 10
assert_eq "0" "$BB_RC" "'pr checks <n>' works"
assert_contains "/pullrequests/10" "$CURL_CALLS" "it resolves the pull request first"
assert_contains "/statuses" "$CURL_CALLS" "then reads the build statuses on its commit"
assert_not_contains "-X POST" "$CURL_CALLS" "and writes nothing"

# --- gh pr edit / ready / comment -------------------------------------------

cat > "$CURL_BODY" <<'JSON'
{"id":10,"title":"Existing title","description":"Existing body","state":"OPEN",
 "links":{"html":{"href":"https://bitbucket.org/x/y/pull-requests/10"}}}
JSON

# Bodies come from a file, byte for byte. Trailing spaces are markdown's hard
# line break, and command substitution strips them - which is what makes
# stacked links render as one run-on paragraph instead of one per line.
printf 'line one  \nline two  \n' > "$TMP/body.md"
run_bb pr edit 10 --body-file "$TMP/body.md"
assert_contains "-X PUT" "$CURL_CALLS" "pr edit issues a PUT"
assert_contains "line one  " "$CURL_BODIES" "the body keeps its trailing spaces"
assert_contains "Existing title" "$CURL_BODIES" \
    "the title is preserved when only the body was given"

run_bb pr edit 10 --title "New title"
assert_contains '"title":"New title"' "$CURL_BODIES" "--title sets the title"
assert_contains "Existing body" "$CURL_BODIES" \
    "and the description is preserved when only the title was given"

run_bb pr edit 10
assert_eq "1" "$BB_RC" "pr edit with nothing to change is an error"
assert_not_contains "-X PUT" "$CURL_CALLS" "and sends nothing"

run_bb pr edit 10 --body-file "$TMP/missing.md"
assert_eq "1" "$BB_RC" "an unreadable body file is an error"
assert_not_contains "-X PUT" "$CURL_CALLS" "and sends nothing"

run_bb pr edit
assert_eq "1" "$BB_RC" "pr edit without a number is an error"

run_bb pr ready 10
assert_contains "-X PUT" "$CURL_CALLS" "pr ready issues a PUT"
assert_contains '"draft":false' "$CURL_BODIES" "clearing the draft flag"

run_bb pr ready 10 --undo
assert_contains '"draft":true' "$CURL_BODIES" "--undo puts it back to draft"

printf 'Looks good.\n' > "$TMP/comment.md"
run_bb pr comment 10 --body-file "$TMP/comment.md"
assert_contains "-X POST" "$CURL_CALLS" "pr comment issues a POST"
assert_contains "/comments" "$CURL_CALLS" "to the comments endpoint"
assert_contains '"raw":"Looks good' "$CURL_BODIES" "with the body under content.raw"

run_bb pr comment 10
assert_eq "1" "$BB_RC" "a comment with no body is an error"

printf '' > "$TMP/empty.md"
run_bb pr comment 10 --body-file "$TMP/empty.md"
assert_eq "1" "$BB_RC" "an empty comment is refused"
assert_not_contains "-X POST" "$CURL_CALLS" "and posts nothing"

run_bb pr comment 10 --body-file "$TMP/comment.md" --dry-run
assert_eq "0" "$BB_RC" "--dry-run succeeds"
assert_not_contains "-X POST" "$CURL_CALLS" "and sends nothing"
assert_contains "POST https://api.bitbucket.org" "$BB_OUT" "printing the target instead"

# --- gh run cancel ----------------------------------------------------------

echo '{"build_number":1240,"uuid":"{2a2f5c49}","state":{"name":"IN_PROGRESS"}}' > "$CURL_BODY"
run_bb pipeline cancel 1240
assert_contains "-X POST" "$CURL_CALLS" "cancel issues a POST"
assert_contains "stopPipeline" "$CURL_CALLS" "to Bitbucket's stopPipeline endpoint"

run_bb run stop 1240
assert_contains "stopPipeline" "$CURL_CALLS" "'stop' and the 'run' noun compose"

run_bb pipeline cancel
assert_eq "1" "$BB_RC" "cancel without a build number is an error"
assert_not_contains "stopPipeline" "$CURL_CALLS" "and sends nothing"

# A finished build answers 400, not 403: authorisation passed, the state
# refused. That must not read as a permissions problem.
# The lookup must still succeed, so this fake answers per method: 200 with a
# pipeline on the GET, 400 with Bitbucket's refusal on the POST.
cp "$TMP/curl" "$TMP/curl.wellbehaved"
cat > "$TMP/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >> "$CURL_LOG"
hdr=""; out=""; prev=""; is_post=false
for a in "$@"; do
  [[ "$prev" == "-D" ]] && hdr="$a"
  [[ "$prev" == "-o" ]] && out="$a"
  [[ "$a" == "POST" ]] && is_post=true
  prev="$a"
done
if $is_post; then
  code=400
  body='{"error":{"message":"Cannot stop pipeline result that is already complete with status PASSED"}}'
else
  code=200
  body='{"build_number":1240,"uuid":"{2a2f5c49}","state":{"name":"COMPLETED"}}'
fi
[[ -n "$hdr" ]] && printf 'HTTP/2 %s\r\ncontent-type: application/json\r\n\r\n' "$code" > "$hdr"
if [[ -n "$out" ]]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
FAKE
chmod +x "$TMP/curl"

run_bb pipeline cancel 1240
assert_eq "1" "$BB_RC" "cancelling a finished build fails"
assert_contains "already finished" "$BB_OUT" "and says the build finished, not that a scope is missing"
assert_not_contains "docs scopes" "$BB_OUT" "so it does not send the user to the permissions doc"

cp "$TMP/curl.wellbehaved" "$TMP/curl"

# --- gh cache ---------------------------------------------------------------

cat > "$CURL_BODY" <<'JSON'
{"values":[
  {"uuid":"{aaaa-1}","name":"tools","file_size_bytes":10485760,"created_on":"2026-08-20T10:00:00.000Z"},
  {"uuid":"{aaaa-2}","name":"tools","file_size_bytes":20971520,"created_on":"2026-08-19T10:00:00.000Z"}
]}
JSON

run_bb cache list
assert_eq "0" "$BB_RC" "'cache list' works"
assert_contains "pipelines-config/caches" "$CURL_CALLS" "it reads the caches endpoint"
assert_contains "tools" "$BB_OUT" "and lists them"
assert_not_contains "-X POST" "$CURL_CALLS" "read-only"

run_bb cache
assert_eq "0" "$BB_RC" "bare 'cache' defaults to list"

# Deleting by name would remove every cache sharing it, on every branch, because
# caches are distinguished by path as well. Two here are both called "tools".
run_bb cache delete tools -y
assert_eq "1" "$BB_RC" "deleting by name is refused"
assert_not_contains "-X DELETE" "$CURL_CALLS" "and sends nothing"
assert_contains "every cache sharing that name" "$BB_OUT" "the refusal explains the trap"

run_bb cache delete "{aaaa-1}" -y
assert_contains "-X DELETE" "$CURL_CALLS" "deleting by uuid works"
assert_contains "caches/" "$CURL_CALLS" "against the cache endpoint"

run_bb cache delete
assert_eq "1" "$BB_RC" "delete with no argument is an error"

# --- the surface is documented ---------------------------------------------
# A command that exists but appears in no help is a command nobody finds.

run_bb help
for cmd in pr pipeline cache signoff api branch repo upgrade; do
    assert_contains "$cmd" "$BB_OUT" "help lists '${cmd}'"
done

run_bb help cache
assert_contains "gh cache" "$BB_OUT" "help names the gh command each one mirrors"

if grep -q "Coming from .gh" "${REPO_ROOT}/README.md"; then
    echo "  ok   - the README carries the gh mapping table"; pass=$((pass + 1))
else
    echo "  FAIL - the README has no gh mapping table"; fail=$((fail + 1))
fi

for pair in "gh run cancel" "gh cache list" "gh pr checks"; do
    if grep -q "$pair" "${REPO_ROOT}/README.md"; then
        echo "  ok   - the mapping table covers '${pair}'"; pass=$((pass + 1))
    else
        echo "  FAIL - the mapping table is missing '${pair}'"; fail=$((fail + 1))
    fi
done

summary
