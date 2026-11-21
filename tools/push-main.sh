#!/usr/bin/env bash
# tools/push-main.sh — push the checked-out main to origin through the required "path-guard" check.
#
# main is protected (admins included): a commit gets in only when the path-guard job has passed on
# that very commit. So the commit goes to origin as guard/<sha> first (the pre-push hook scans it
# before it leaves this machine, the path-guard job scans it there); when the job is green the same
# commit is pushed to main and guard/<sha> is deleted. A red job leaves main untouched: fix the hit
# at its source, commit, run this again. Tags are pushed the usual way afterwards
# (`git push origin <tag>`); the hook scans them too.
#
# Needs gh (signed in) and the hook (tools/path-guard.sh install).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
die() { echo "push-main: $*" >&2; exit 2; }
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "the working tree is not clean"
tools/path-guard.sh installed
sha="$(git rev-parse HEAD)"
slug="$(git remote get-url origin | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
case "$slug" in */*) ;; *) die "origin is not a GitHub repository ($slug)";; esac
git fetch -q origin
if [ "$(git rev-parse -q --verify refs/remotes/origin/main || true)" = "$sha" ]; then
    echo "push-main: origin/main is already ${sha:0:7}"
    exit 0
fi
branch="guard/${sha:0:12}"
echo "==> ${sha:0:7} to $branch"
git push -q origin "$sha:refs/heads/$branch"
drop() { git push -q origin ":refs/heads/$branch" || echo "push-main: could not delete $branch on origin" >&2; }
echo "==> waiting for the path-guard job on ${sha:0:7}"
state=""
for _ in $(seq 1 120); do
    state="$(gh api "repos/$slug/commits/$sha/check-runs" --jq '[.check_runs[] | select(.name == "path-guard")] | sort_by(.started_at) | last | if . == null then "none" else "\(.status) \(.conclusion)" end' 2>/dev/null || echo "none")"
    case "$state" in
        "completed success") break ;;
        completed*) drop; echo "push-main: the path-guard job did not pass ($state). main is untouched. gh run list -R $slug --commit $sha" >&2; exit 1 ;;
    esac
    sleep 5
done
[ "$state" = "completed success" ] || { drop; echo "push-main: no path-guard result after 10 minutes. main is untouched." >&2; exit 1; }
echo "==> path-guard passed; ${sha:0:7} to main"
git push origin "$sha:refs/heads/main"
drop
echo "push-main: origin/main is ${sha:0:7}"
