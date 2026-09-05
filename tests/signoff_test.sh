#!/usr/bin/env bash
#
# Black-box tests for `bb-cli signoff`.
#
# A signoff is a claim: "the suite ran green against exactly this commit". Most
# of what is guarded here is the guards - a dirty tree or an unpushed commit
# must refuse rather than publish something that is not true. The rest is the
# payload contract confirmed against the live API on 2026-08-21: key, state and
# url are required, state is one of four values, name and description optional.
#
# No network: a fake curl on PATH records the argv and answers from a fixture.
#
# Run: tests/signoff_test.sh
set -u

# shellcheck source=tests/lib/fake_curl.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/fake_curl.sh"
harness_init

# A checkout with a Bitbucket origin, one commit, and a remote-tracking ref that
# contains it - i.e. the normal "pushed and clean" state.
REPO_DIR="$TMP/checkout"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "test@example.com"
git -C "$REPO_DIR" config user.name "Test User"
git -C "$REPO_DIR" remote add origin git@bitbucket.org:myworkspace/myrepo.git
echo "hello" > "$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -qm "first"
SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
# Fake "this commit is on the remote" without a network: point a remote-tracking
# ref at it, which is what `git branch -r --contains` reads.
git -C "$REPO_DIR" update-ref "refs/remotes/origin/main" "$SHA"
cd "$REPO_DIR"

echo '{"key":"local-signoff","state":"SUCCESSFUL","type":"build"}' > "$CURL_BODY"

echo "signoff tests"

# --- the happy path --------------------------------------------------------

run_bb signoff
assert_eq "0" "$BB_RC" "a clean, pushed commit signs off"
assert_contains "-X POST" "$CURL_CALLS" "signoff issues a POST"
assert_contains "/commit/${SHA}/statuses/build" "$CURL_CALLS" \
    "it posts to the build-status endpoint for HEAD"
assert_contains '"state":"SUCCESSFUL"' "$CURL_BODIES" "the default state is SUCCESSFUL"
assert_contains '"key":"local-signoff"' "$CURL_BODIES" "the default key is local-signoff"
assert_contains '"url":"https://bitbucket.org/myworkspace/myrepo/commits/'"$SHA" \
    "$CURL_BODIES" "url defaults to the commit page (it is a required field)"
assert_contains "Test User signed off" "$CURL_BODIES" \
    "the description names who signed off, from git config"

# The three fields the live API declared required, all present.
for field in key state url; do
    assert_contains "\"${field}\":" "$CURL_BODIES" "the required field '${field}' is sent"
done

# --- labels ----------------------------------------------------------------

run_bb signoff --name "vitest 461 passed, 23 skipped, 8s"
assert_contains "vitest 461 passed" "$CURL_BODIES" \
    "--name carries the numbers a reviewer reads weeks later"

run_bb signoff --key lint
assert_contains '"key":"lint"' "$CURL_BODIES" "--key sets the status identity"

run_bb signoff --description "custom text"
assert_contains '"description":"custom text"' "$CURL_BODIES" "--description overrides the default"

run_bb signoff --url "https://example.com/build/1"
assert_contains "https://example.com/build/1" "$CURL_BODIES" "--url overrides the commit page"

# --- state ----------------------------------------------------------------

run_bb signoff --fail
assert_contains '"state":"FAILED"' "$CURL_BODIES" "--fail is shorthand for FAILED"

run_bb signoff --in-progress
assert_contains '"state":"INPROGRESS"' "$CURL_BODIES" "--in-progress maps to INPROGRESS"

run_bb signoff --state successful
assert_contains '"state":"SUCCESSFUL"' "$CURL_BODIES" "a lower-case state is upper-cased"

run_bb signoff --state PENDING
assert_eq "1" "$BB_RC" "a state outside the enum is refused"
assert_not_contains "api.bitbucket.org" "$CURL_CALLS" \
    "an invalid state is caught locally, with no request"
assert_contains "SUCCESSFUL, FAILED, INPROGRESS, STOPPED" "$BB_OUT" \
    "the refusal lists the four valid states"

# --- the guards ------------------------------------------------------------
# These are the point of the command. A signoff that does not attest a real run
# against a real commit is worse than no signoff.

echo "dirty" >> "$REPO_DIR/file.txt"
run_bb signoff
assert_eq "1" "$BB_RC" "a dirty working tree refuses"
assert_not_contains "api.bitbucket.org" "$CURL_CALLS" "a dirty tree publishes nothing"
assert_contains "working tree is not clean" "$BB_OUT" "the refusal says why"

run_bb signoff --force
assert_eq "0" "$BB_RC" "--force overrides the dirty-tree guard"
assert_contains "-X POST" "$CURL_CALLS" "--force does publish"
git -C "$REPO_DIR" checkout -q -- file.txt

# An unpushed commit: Bitbucket has no such object to attach a status to.
echo "second" > "$REPO_DIR/second.txt"
git -C "$REPO_DIR" add second.txt
git -C "$REPO_DIR" commit -qm "second (unpushed)"
run_bb signoff
assert_eq "1" "$BB_RC" "an unpushed commit refuses"
assert_not_contains "api.bitbucket.org" "$CURL_CALLS" "an unpushed commit publishes nothing"
assert_contains "not on any remote" "$BB_OUT" "the refusal says the commit is not pushed"

run_bb signoff --force
assert_eq "0" "$BB_RC" "--force overrides the unpushed guard too"

git -C "$REPO_DIR" reset -q --hard "$SHA"
rm -f "$REPO_DIR/second.txt"

# --- commit selection ------------------------------------------------------

run_bb signoff --commit "$SHA"
assert_contains "/commit/${SHA}/" "$CURL_CALLS" "--commit takes a full sha"

run_bb signoff --commit HEAD
assert_contains "/commit/${SHA}/" "$CURL_CALLS" "--commit resolves a revision name"

run_bb signoff --commit not-a-real-ref
assert_eq "1" "$BB_RC" "an unresolvable revision is an error"
assert_contains "not a commit" "$BB_OUT" "the error names the bad revision"

# --repo without --commit would resolve HEAD in the checkout you are standing
# in, which is a different repository from the one you named.
run_bb signoff --repo other-ws/other-repo
assert_eq "1" "$BB_RC" "--repo without --commit is refused"
assert_contains "needs an explicit --commit" "$BB_OUT" "the refusal explains the mismatch"

run_bb signoff --repo other-ws/other-repo --commit "$SHA" --force
assert_contains "repositories/other-ws/other-repo/commit/${SHA}" "$CURL_CALLS" \
    "--repo with --commit targets the named repository"

# --- dry run ---------------------------------------------------------------

run_bb signoff --dry-run
assert_eq "0" "$BB_RC" "--dry-run succeeds"
assert_not_contains "api.bitbucket.org/2.0/repositories/myworkspace/myrepo/commit" "$CURL_CALLS" \
    "--dry-run sends nothing"
assert_contains "POST https://api.bitbucket.org" "$BB_OUT" "--dry-run prints the target URL"
assert_contains '"state": "SUCCESSFUL"' "$BB_OUT" "--dry-run prints the payload"

# --- reading statuses back -------------------------------------------------

cat > "$CURL_BODY" <<'JSON'
{"values":[
  {"key":"local-signoff","state":"SUCCESSFUL","name":"vitest 461 passed","updated_on":"2026-08-21T19:30:00.000Z"},
  {"key":"default","state":"SUCCESSFUL","name":"Pipeline - default","updated_on":"2026-08-21T18:53:00.000Z"}
]}
JSON

run_bb signoff status
assert_eq "0" "$BB_RC" "signoff status succeeds"
assert_not_contains "-X POST" "$CURL_CALLS" "signoff status is read-only"
assert_contains "/commit/${SHA}/statuses" "$CURL_CALLS" "it reads the statuses endpoint"
assert_contains "local-signoff" "$BB_OUT" "our own status is listed"
assert_contains "Pipeline - default" "$BB_OUT" "third-party statuses are listed too"
assert_contains "2026-08-21" "$BB_OUT" "the date column is rendered"

run_bb signoff status --json
assert_contains '"key": "local-signoff"' "$BB_OUT" "--json returns the raw payload"

echo '{"values":[]}' > "$CURL_BODY"
run_bb signoff status
assert_eq "0" "$BB_RC" "an empty status list is not an error"
assert_contains "No build statuses" "$BB_OUT" "an empty list says so"
assert_contains "bb-cli signoff" "$BB_OUT" "and points at how to publish one"

# --- API errors ------------------------------------------------------------

echo '{"key":"x"}' > "$CURL_BODY"
CURL_STATUS=403 ; export CURL_STATUS
run_bb signoff
assert_eq "1" "$BB_RC" "a 403 from the API exits non-zero"
assert_contains "bb-cli docs scopes" "$BB_OUT" "a 403 points at the scopes doc"
CURL_STATUS=200 ; export CURL_STATUS

# --- help ------------------------------------------------------------------

run_bb signoff --help
assert_eq "0" "$BB_RC" "--help exits 0"
assert_contains "gh signoff" "$BB_OUT" "--help names the tool this mirrors"
assert_contains "admin:repository:bitbucket" "$BB_OUT" \
    "--help explains why 'signoff install' is absent"

summary
