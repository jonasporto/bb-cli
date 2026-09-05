#!/usr/bin/env bash
#
# Black-box routing tests for `bb-cli pipeline` trigger / rerun / watch / show.
#
# Regression guard for the arg-parse bug (fixed 2026-07): a flag BEFORE the
# subcommand (e.g. `pipeline --repo=X rerun 1240`) set action=list, then the
# while-loop had no `trigger` case and the `rerun` case didn't consume its ref,
# so `trigger` was re-read as `show trigger` and `rerun 1240` as `show 1240`,
# and neither ever issued a POST. These tests assert the RIGHT HTTP verb/endpoint
# reaches the network layer for each command shape, with NO real network: a fake
# `curl` on PATH records every invocation and returns canned JSON.
#
# Run: tests/pipeline_routing_test.sh   (exit 0 = all pass)
set -u

BBCLI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/bb-cli"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export BITBUCKET_USERNAME="test-user"
export BITBUCKET_API_TOKEN="test-token"

# Fake curl: append its args to $CURL_LOG, emit canned JSON keyed by method.
cat > "$TMP/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >> "$CURL_LOG"
is_post=false; url=""
for a in "$@"; do
  [[ "$a" == "POST" ]] && is_post=true
  [[ "$a" == https://* ]] && url="$a"
done
single='{"build_number":1240,"uuid":"{2a2f5c49}","state":{"name":"COMPLETED","result":{"name":"FAILED"}},"target":{"type":"pipeline_ref_target","ref_type":"branch","ref_name":"my-branch","selector":{"type":"custom","pattern":"Unit specs"}}}'
if $is_post; then
  echo '{"build_number":99999,"uuid":"{new-run}","state":{"name":"PENDING"},"target":{"type":"pipeline_ref_target","ref_type":"branch","ref_name":"my-branch"}}'
elif [[ "$url" == *pagelen* ]]; then
  # build-number -> uuid lookup expects a paginated list
  echo "{\"values\":[${single}],\"page\":1,\"size\":1,\"pagelen\":100}"
else
  echo "$single"
fi
FAKE
chmod +x "$TMP/curl"
export PATH="$TMP:$PATH"

pass=0; fail=0
run() { # capture the fake curl log for one bb-cli pipeline invocation
  export CURL_LOG="$TMP/log"; : > "$CURL_LOG"
  BB_OUT="$("$BBCLI" pipeline "$@" 2>&1)"; BB_RC=$?
  CURL_CALLS="$(cat "$CURL_LOG")"
}
assert_contains()     { if [[ "$2" == *"$1"* ]]; then echo "  ok   - $3"; ((pass++)); else echo "  FAIL - $3 (expected substring: '$1')"; ((fail++)); fi; }
assert_not_contains() { if [[ "$2" != *"$1"* ]]; then echo "  ok   - $3"; ((pass++)); else echo "  FAIL - $3 (unexpected substring: '$1')"; ((fail++)); fi; }

echo "pipeline routing tests"

# 1. rerun, flag BEFORE subcommand, the original bug. Must POST to /pipelines/.
run --repo=myworkspace/myrepo rerun 1240
assert_contains "POST" "$CURL_CALLS" "rerun (flag-first) issues a POST"
assert_contains "/pipelines/" "$CURL_CALLS" "rerun (flag-first) hits the pipelines endpoint"

# 2. rerun, subcommand first: must also POST.
run rerun 1240 --repo=myworkspace/myrepo
assert_contains "POST" "$CURL_CALLS" "rerun (subcommand-first) issues a POST"

# 3. trigger, flag-first + custom selector: must POST with the custom pattern.
run --repo=myworkspace/myrepo trigger --custom "Unit specs"
assert_contains "POST" "$CURL_CALLS" "trigger (flag-first) issues a POST"
assert_contains "Unit specs" "$CURL_CALLS" "trigger passes the custom selector in the body"

# 4. show (bare build number) must NOT POST. Read only.
run --repo=myworkspace/myrepo 1240
assert_not_contains "POST" "$CURL_CALLS" "show issues no POST (read-only)"

# 5. rerun --failed: public API can't; must NOT POST, and must explain.
run --repo=myworkspace/myrepo rerun 1240 --failed
assert_not_contains "POST" "$CURL_CALLS" "rerun --failed issues no POST"
assert_contains "cannot rerun only failed steps" "$BB_OUT" "rerun --failed explains the public-API limitation"

# 6. failures (flag-first) must NOT POST and must read the steps endpoint.
run --repo=myworkspace/myrepo failures 1240
assert_not_contains "POST" "$CURL_CALLS" "failures issues no POST (read-only)"

# 7. Build-number lookup goes straight at /pipelines/<n>, not page by page.
# Bitbucket accepts a build number in the {pipeline_uuid} slot even though only
# a uuid is documented there. Without this, resolving an older build walks the
# list 100 at a time: measured 59.4s against 0.6s for build #1234 on a repo
# whose newest build was #1300. If this test starts failing, the undocumented
# form stopped working and the fallback scan is carrying every lookup.
run --repo=myworkspace/myrepo 1240
assert_contains "/pipelines/1240" "$CURL_CALLS" "a build number is looked up directly"
assert_not_contains "page=1" "$CURL_CALLS" "no page-by-page scan when the direct form answers"

echo ""
echo "passed: $pass   failed: $fail"
[[ "$fail" -eq 0 ]]
