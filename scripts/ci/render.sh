#!/usr/bin/env bash
# Renders every application the way Argo CD will: the service chart once per values
# file, plus each application's plain manifests, one file per release in <out dir>.
#
#   apps/<app>/values.yaml          → release <app>,        namespace app-<app>
#   apps/<app>/<svc>/values.yaml    → release <app>-<svc>,  namespace app-<app>
#   apps/<app>/manifests/*.yaml     → <app>.manifests.yaml, as written
#
# The release name is what the tenant in platform-gitops sets as `helm.releaseName`,
# and the namespace is the one it creates; that repository's CI checks the other half.
#
# A values file that fails the chart's schema or guards fails here, with Helm's own
# message — the error Argo CD would otherwise show after the merge.
#
# Usage: scripts/ci/render.sh <out dir>     (from the repository root)
set -uo pipefail

OUT=${1:?usage: render.sh <out dir>}
CHART=charts/service
mkdir -p "$OUT"
FAIL=0

while read -r VALUES; do
  DIR=$(dirname "$VALUES")
  APP=${DIR#apps/}
  RELEASE=${APP//\//-}
  NAMESPACE=app-${APP%%/*}
  echo "== $VALUES → release $RELEASE in $NAMESPACE"
  if ! helm lint "$CHART" -f "$VALUES" --namespace "$NAMESPACE" --strict --quiet; then
    echo "::error file=$VALUES::helm lint failed for $RELEASE"
    FAIL=1
    continue
  fi
  if ! helm template "$RELEASE" "$CHART" -f "$VALUES" -n "$NAMESPACE" >"$OUT/$RELEASE.yaml"; then
    echo "::error file=$VALUES::helm template failed for $RELEASE"
    rm -f "$OUT/$RELEASE.yaml"
    FAIL=1
  fi
done < <(git ls-files 'apps/*values.yaml' | grep -v '/manifests/')

while read -r DIR; do
  APP=${DIR#apps/}
  APP=${APP%/manifests}
  echo "== $DIR"
  while read -r FILE; do
    printf -- '---\n# Source: %s\n' "$FILE"
    cat "$FILE"
    echo
  done < <(git ls-files "$DIR/*.yaml" "$DIR/*.yml") >"$OUT/${APP//\//-}.manifests.yaml"
done < <(git ls-files 'apps/*/manifests/*' | xargs -r -n1 dirname | sort -u)

exit "$FAIL"
