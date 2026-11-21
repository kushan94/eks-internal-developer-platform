#!/usr/bin/env bash
# Tests the App deploy workflow's shell steps, taken from the workflow itself and
# run against a real repository with a remote: the tag bump that app repos get,
# and the guard that keeps other branches from getting a trusted image.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
failures=0
check() { if [ "$2" = ok ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; failures=$((failures + 1)); fi; }

wf="${APP_DEPLOY_WORKFLOW:-.github/workflows/app-deploy.yml}"
yq() { docker run --rm -i -v "$PWD":/repo -w /repo mikefarah/yq:4.47.2 "$@"; }
step() { yq ".jobs.build.steps[] | select(.name == \"$1\") | .run" "$wf"; }

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
step "Deploy the new image through Git" > "$dir/bump.sh"
step "Only deploy from the default branch" > "$dir/guard.sh"
[ "$(grep -c . "$dir/bump.sh")" -gt 3 ] && [ "$(grep -c . "$dir/guard.sh")" -ge 1 ] || { echo "  FAIL  couldn't read the steps from $wf"; exit 1; }

# An app repo with its remote, as the workflow finds it after checkout.
git init -q --bare "$dir/remote.git"
git clone -q "$dir/remote.git" "$dir/app" 2> /dev/null
mkdir -p "$dir/app/deploy"
cat > "$dir/app/deploy/web.yaml" << 'EOF'
apiVersion: platform.example.org/v1alpha1
kind: WebService
metadata:
  name: orders
spec:
  runtime: kubernetes
  image: nginxinc/nginx-unprivileged:1.29-alpine
  port: 8080
EOF
git -C "$dir/app" add -A
git -C "$dir/app" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$dir/app" push -q origin HEAD 2> /dev/null

# bump <sha> [deploy file]: runs the workflow's step inside the app repo.
bump() {
  (cd "$dir/app" && GITHUB_SHA="$1" GITHUB_STEP_SUMMARY=/dev/null IMAGE=ghcr.io/kushan94/orders DEPLOY_FILE="${2:-deploy/web.yaml}" bash -e "$dir/bump.sh") > "$dir/out.log" 2>&1
}

sha1=1111111111111111111111111111111111111111
sha2=2222222222222222222222222222222222222222

bump "$sha1" && check "the first build replaces the image" ok || check "the first build replaces the image" fail
[ "$(grep -c "^  image: ghcr.io/kushan94/orders:$sha1$" "$dir/app/deploy/web.yaml")" = 1 ] && check "the file names the new tag" ok || check "the file names the new tag" fail
[ "$(git -C "$dir/remote.git" log -1 --format=%s)" = "Deploy 1111111" ] && check "the commit reached the remote" ok || check "the commit reached the remote" fail
[ "$(grep -c '^  port: 8080$' "$dir/app/deploy/web.yaml")" = 1 ] && check "the rest of the file is untouched" ok || check "the rest of the file is untouched" fail

before="$(git -C "$dir/remote.git" rev-parse HEAD)"
bump "$sha1" && [ "$(git -C "$dir/remote.git" rev-parse HEAD)" = "$before" ] && check "the same tag again commits nothing" ok || check "the same tag again commits nothing" fail

bump "$sha2" && [ "$(git -C "$dir/remote.git" log -1 --format=%s)" = "Deploy 2222222" ] && check "a newer build replaces the tag" ok || check "a newer build replaces the tag" fail

# Someone else pushed to main while the build ran: the step rebases and retries.
git clone -q "$dir/remote.git" "$dir/other" 2> /dev/null
echo "# note" >> "$dir/other/README.md"
git -C "$dir/other" add -A
git -C "$dir/other" -c user.name=t -c user.email=t@t commit -q -m "Edit the readme"
git -C "$dir/other" push -q origin HEAD 2> /dev/null
sha3=3333333333333333333333333333333333333333
bump "$sha3" && [ "$(git -C "$dir/remote.git" log -1 --format=%s)" = "Deploy 3333333" ] && check "a push that landed meanwhile is rebased over" ok || check "a push that landed meanwhile is rebased over" fail

bump "$sha3" deploy/missing.yaml && check "a mistyped path fails" fail || check "a mistyped path fails" ok
printf '  image: second\n' >> "$dir/app/deploy/web.yaml"
bump "$sha1" && check "two image lines fail" fail || check "two image lines fail" ok

guard() { REF="$1" DEFAULT_BRANCH=main bash -e "$dir/guard.sh" > /dev/null 2>&1; }
guard refs/heads/main && check "main may deploy" ok || check "main may deploy" fail
guard refs/heads/feature && check "a feature branch may not" fail || check "a feature branch may not" ok
guard refs/pull/7/merge && check "a pull request ref may not" fail || check "a pull request ref may not" ok

echo
[ "$failures" = 0 ] && echo "The App deploy steps behave." || { echo "$failures check(s) failed."; exit 1; }
