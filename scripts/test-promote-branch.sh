#!/usr/bin/env bash
# Tests that the Promote workflow's branch name can't be blocked by a branch
# named "promote" (Git can't hold promote and promote/...), using the branch
# line from the workflow itself and a real repository.
set -uo pipefail
cd "$(dirname "$0")/.."
failures=0
check() { if [ "$2" = ok ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; failures=$((failures + 1)); fi; }

line="$(grep -E '^ *branch="promote' .github/workflows/promote.yml)"
[ "$(printf "%s\n" "$line" | grep -c .)" = 1 ] || { echo "  FAIL  expected one branch= line in promote.yml"; exit 1; }

SERVICE=demo/visits TO=prod tag=0123456789abcdef
eval "$line"
echo "Branch name: $branch"

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
git -C "$dir" init -q
git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$dir" branch promote
git -C "$dir" branch "$branch" 2> /dev/null && check "a branch named promote doesn't block $branch" ok || check "a branch named promote doesn't block $branch" fail
git -C "$dir" branch "promote/demo-visits/prod/0123456789ab" 2> /dev/null && check "control: the old name is blocked by it" fail || check "control: the old name is blocked by it" ok
case "$branch" in promote/*) check "the name has no promote/ prefix" fail ;; *) check "the name has no promote/ prefix" ok ;; esac

echo
[ "$failures" = 0 ] && echo "The branch name can't be blocked." || { echo "$failures check(s) failed."; exit 1; }
