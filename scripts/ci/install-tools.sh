#!/usr/bin/env bash
# Installs the tools CI uses, each pinned and checked against its release checksum,
# so a runner image update cannot change what fails. Bump a version with its sum.
#
# Helm stays on the 3.x line: it is what Argo CD renders the chart with.
#
# Usage: scripts/ci/install-tools.sh      (CI only — installs with sudo)
set -euo pipefail

HELM_VERSION=v3.22.1
HELM_SHA256=896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea
KUBECONFORM_VERSION=v0.8.0
KUBECONFORM_SHA256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
CRANE_VERSION=v0.22.1
CRANE_SHA256=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0

TMP=$(mktemp -d)

fetch() { # url file sha256
  curl -sSfLo "$TMP/$2" "$1"
  echo "$3  $TMP/$2" | sha256sum -c -
}

fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" helm.tgz "$HELM_SHA256"
tar -xzf "$TMP/helm.tgz" -C "$TMP" linux-amd64/helm
sudo install "$TMP/linux-amd64/helm" /usr/local/bin/helm

fetch "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
  kubeconform.tgz "$KUBECONFORM_SHA256"
tar -xzf "$TMP/kubeconform.tgz" -C "$TMP" kubeconform
sudo install "$TMP/kubeconform" /usr/local/bin/kubeconform

fetch "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" \
  crane.tgz "$CRANE_SHA256"
tar -xzf "$TMP/crane.tgz" -C "$TMP" crane
sudo install "$TMP/crane" /usr/local/bin/crane

# PyYAML for check.py, hash-pinned, in a virtualenv: the runner's system Python is
# externally managed and its packages change with the image.
python3 -m venv "$TMP/venv"
"$TMP/venv/bin/pip" install --quiet --require-hashes -r scripts/ci/requirements.txt
echo "$TMP/venv/bin" >>"${GITHUB_PATH:-/dev/null}"

helm version --short
kubeconform -v
crane version
