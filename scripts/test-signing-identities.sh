#!/usr/bin/env bash
# Tests which GitHub workflow identities the signed-images policy trusts, using
# the policy's own regular expressions. Kyverno's test command can't verify a
# signature, so this checks the part that decides who may sign.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
failures=0
check() { if [ "$2" = ok ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; failures=$((failures + 1)); fi; }

policy="${SIGNED_IMAGES_POLICY:-platform/policies/signed-images.yaml}"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
docker run --rm -i -v "$PWD":/repo -w /repo mikefarah/yq:4.47.2 '.spec.attestors[].cosign.keyless.identities[].subjectRegExp' "$policy" > "$dir/regexps"
[ "$(grep -c . "$dir/regexps")" -ge 2 ] || { echo "  FAIL  couldn't read the identities from $policy"; exit 1; }

# trusted <subject>: whether any of the policy's expressions accepts it.
trusted() { while read -r re; do printf '%s\n' "$1" | grep -Eq "$re" && return 0; done < "$dir/regexps"; return 1; }
expect() { if trusted "$2"; then [ "$1" = yes ] && check "$3" ok || check "$3" fail; else [ "$1" = no ] && check "$3" ok || check "$3" fail; fi; }

base=https://github.com/kushan94/eks-internal-developer-platform/.github/workflows
expect yes "$base/visits-image.yml@refs/heads/main" "the visits image workflow on main"
expect yes "$base/app-deploy.yml@refs/tags/app-deploy-v1" "app-deploy at release tag v1"
expect yes "$base/app-deploy.yml@refs/tags/app-deploy-v12" "app-deploy at release tag v12"
expect no "$base/app-deploy.yml@refs/heads/main" "app-deploy at main is not trusted"
expect no "$base/app-deploy.yml@refs/heads/feature" "app-deploy on a branch is not trusted"
expect no "$base/app-deploy.yml@refs/tags/app-deploy-v1-evil" "a tag with a suffix is not trusted"
expect no "$base/app-deploy.yml@refs/tags/v1" "a tag without the prefix is not trusted"
expect no "$base/app-deploy.yml@refs/heads/app-deploy-v1" "a branch named like a release tag is not trusted"
expect no "$base/visits-image.yml@refs/tags/app-deploy-v1" "other workflows aren't trusted at a tag"
expect no "$base/promote.yml@refs/heads/main" "a workflow that doesn't sign isn't trusted"
expect no "https://github.com/kushan94/other-repo/.github/workflows/app-deploy.yml@refs/tags/app-deploy-v1" "the same workflow in another repo is not trusted"
expect no "https://github.com/kushan94/eks-internal-developer-platform-evil/.github/workflows/app-deploy.yml@refs/tags/app-deploy-v1" "a repo with a longer name is not trusted"

echo
[ "$failures" = 0 ] && echo "The policy trusts only the intended identities." || { echo "$failures check(s) failed."; exit 1; }
