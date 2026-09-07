#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_FILE="${RELEASE_FILE:-$REPO_ROOT/archinfra/releases/v1.36.4-r1.env}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
WORK_DIR="${WORK_DIR:-${RUNNER_TEMP:-/tmp}/archinfra-kubernetes-runtime}"

[[ -f "$RELEASE_FILE" ]] || { echo "ERROR: release file not found: $RELEASE_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$RELEASE_FILE"

GHCR_USER="${GHCR_USER:?GHCR_USER is required}"
GHCR_TOKEN="${GHCR_TOKEN:?GHCR_TOKEN is required}"

mkdir -p "$OUT_DIR" "$WORK_DIR"
ROOT="$WORK_DIR/rootfs"
rm -rf "$ROOT"
mkdir -p "$ROOT"

log() { printf '[archinfra-runtime] %s\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
  done
}
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
assert_sha256() {
  local expected="$1" file="$2" actual
  actual="$(sha256_of "$file")"
  [[ "$actual" == "$expected" ]] || fail "SHA256 mismatch: $file expected=$expected actual=$actual"
  log "sha256 OK: $(basename "$file") = $actual"
}

require_cmd buildah skopeo jq sha256sum tar file sed grep install
[[ "$ARCH" == amd64 ]] || fail "r1 supports amd64 only (got: $ARCH)"
[[ "$RUNTIME_PROFILE" == docker ]] || fail "r1 supports Docker profile only (got: $RUNTIME_PROFILE)"

SEALOS_CACHE_REF="${SEALOS_CACHE_IMAGE}@${SEALOS_CACHE_DIGEST}"
DOCKER_CACHE_REF="${DOCKER_CACHE_IMAGE}@${DOCKER_CACHE_DIGEST}"
CRICTL_CACHE_REF="${CRICTL_CACHE_IMAGE}@${CRICTL_CACHE_DIGEST}"
KUBERNETES_CACHE_REF="${KUBERNETES_CACHE_IMAGE}@${KUBERNETES_CACHE_DIGEST}"

cleanup() {
  sudo buildah umount --all >/dev/null 2>&1 || true
  sudo buildah rm --all >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "release=$RELEASE_VERSION arch=$ARCH profile=$RUNTIME_PROFILE"
log "cache build git sha=$CACHE_BUILD_GIT_SHA run=$CACHE_BUILD_RUN_ID"

# Authenticate rootful Buildah because Sealos also uses the root container storage.
printf '%s' "$GHCR_TOKEN" | sudo buildah login --username "$GHCR_USER" --password-stdin ghcr.io >/dev/null

mount_cache() {
  local ref="$1" cid
  cid="$(sudo buildah from --platform "linux/$ARCH" "$ref")"
  sudo buildah mount "$cid"
}

log "mount VERIFIED cache artifacts"
MOUNT_SEALOS="$(mount_cache "$SEALOS_CACHE_REF")"
MOUNT_DOCKER="$(mount_cache "$DOCKER_CACHE_REF")"
MOUNT_CRICTL="$(mount_cache "$CRICTL_CACHE_REF")"
MOUNT_KUBE="$(mount_cache "$KUBERNETES_CACHE_REF")"

# Defense-in-depth: verify the key bytes inside the digest-pinned cache images.
assert_sha256 "$DOCKER_SOURCE_SHA256" "$MOUNT_DOCKER/cri/docker.tgz"
assert_sha256 "$CRI_DOCKERD_SOURCE_SHA256" "$MOUNT_DOCKER/cri/cri-dockerd.tgz"
assert_sha256 "$CRICTL_SOURCE_SHA256" "$MOUNT_CRICTL/cri/crictl.tar.gz"
assert_sha256 "$KUBERNETES_IMAGE_LIST_SHA256" "$MOUNT_KUBE/images/shim/DefaultImageList"

"$MOUNT_KUBE/bin/kubeadm" version -o short | grep -Fx "v$KUBERNETES_VERSION" >/dev/null \
  || fail "kubeadm in cache is not v$KUBERNETES_VERSION"
"$MOUNT_KUBE/bin/kubelet" --version | grep -F "v$KUBERNETES_VERSION" >/dev/null \
  || fail "kubelet in cache is not v$KUBERNETES_VERSION"
"$MOUNT_KUBE/bin/kubectl" version --client=true 2>/dev/null | grep -F "v$KUBERNETES_VERSION" >/dev/null \
  || fail "kubectl in cache is not v$KUBERNETES_VERSION"

# Resolve lvscare once for this build and record the immutable digest in provenance.
# After the first VERIFIED runtime build this value will be promoted into the runtime build lock.
LVSCARE_DIGEST="$(skopeo inspect --creds "$GHCR_USER:$GHCR_TOKEN" "docker://$LVSCARE_IMAGE" | jq -r '.Digest')"
[[ "$LVSCARE_DIGEST" == sha256:* ]] || fail "unable to resolve lvscare digest for $LVSCARE_IMAGE"
LVSCARE_REF="${LVSCARE_IMAGE}@${LVSCARE_DIGEST}"
log "lvscare=$LVSCARE_REF"

# Assemble the Docker rootfs overlay while retaining the upstream Sealos lifecycle scripts/configuration.
cp -a "$REPO_ROOT/docker/." "$ROOT/"
cp -a "$REPO_ROOT/registry/." "$ROOT/"
cp -a "$REPO_ROOT/k8s/." "$ROOT/"
mkdir -p "$ROOT/bin" "$ROOT/cri" "$ROOT/opt" "$ROOT/images/shim" "$ROOT/etc/archinfra"

# Use the exact Sealos binary from the verified cache as the builder and ship its runtime helpers.
sudo install -m 0755 "$MOUNT_SEALOS/sealos/sealos" /usr/local/bin/sealos
install -m 0755 "$MOUNT_SEALOS/sealos/image-cri-shim" "$ROOT/cri/image-cri-shim"
install -m 0755 "$MOUNT_SEALOS/sealos/sealctl" "$ROOT/opt/sealctl"
sealos version | grep -F "$SEALOS_VERSION" >/dev/null || fail "Sealos builder is not $SEALOS_VERSION"

# Docker profile payload.
cp -a "$MOUNT_DOCKER/cri/docker.tgz" "$ROOT/cri/docker.tgz"
cp -a "$MOUNT_DOCKER/cri/cri-dockerd.tgz" "$ROOT/cri/cri-dockerd.tgz"
install -m 0755 "$MOUNT_DOCKER/cri/registry" "$ROOT/cri/registry"
install -m 0755 "$MOUNT_DOCKER/cri/conntrack" "$ROOT/bin/conntrack"
install -m 0755 "$MOUNT_DOCKER/cri/lsof" "$ROOT/opt/lsof"

# CRI client aligned with Kubernetes 1.36.
tar -xzf "$MOUNT_CRICTL/cri/crictl.tar.gz" -C "$ROOT/bin" crictl
chmod 0755 "$ROOT/bin/crictl"

# Keep a human-readable immutable release record inside the final Cluster Image.
cat > "$ROOT/etc/archinfra/release.env" <<EOF
RELEASE_VERSION=$RELEASE_VERSION
ARCH=$ARCH
RUNTIME_PROFILE=$RUNTIME_PROFILE
KUBERNETES_VERSION=$KUBERNETES_VERSION
SEALOS_VERSION=$SEALOS_VERSION
DOCKER_VERSION=$DOCKER_VERSION
CRI_DOCKERD_VERSION=$CRI_DOCKERD_VERSION
CRICTL_VERSION=$CRICTL_VERSION
REGISTRY_VERSION=$REGISTRY_VERSION
DOCKER_BUNDLED_CONTAINERD_VERSION=$DOCKER_BUNDLED_CONTAINERD_VERSION
DOCKER_BUNDLED_RUNC_VERSION=$DOCKER_BUNDLED_RUNC_VERSION
EOF

cat > "$ROOT/etc/archinfra/cache-lock.env" <<EOF
CACHE_BUILD_RUN_ID=$CACHE_BUILD_RUN_ID
CACHE_BUILD_GIT_SHA=$CACHE_BUILD_GIT_SHA
SEALOS_CACHE_REF=$SEALOS_CACHE_REF
DOCKER_CACHE_REF=$DOCKER_CACHE_REF
CRICTL_CACHE_REF=$CRICTL_CACHE_REF
KUBERNETES_CACHE_REF=$KUBERNETES_CACHE_REF
LVSCARE_REF=$LVSCARE_REF
EOF

# The Kubernetes cache is the immutable base layer containing kubeadm/kubelet/kubectl
# and the offline registry. The Docker/runtime files above are the rootfs overlay.
sed -E "s#^FROM .+#FROM $KUBERNETES_CACHE_REF#" "$ROOT/Kubefile" > "$ROOT/Kubefile.tmp"
mv "$ROOT/Kubefile.tmp" "$ROOT/Kubefile"

grep -F "FROM $KUBERNETES_CACHE_REF" "$ROOT/Kubefile" >/dev/null \
  || fail "Kubefile base image was not pinned to Kubernetes cache digest"

pauseImage="$(grep '/pause:' "$MOUNT_KUBE/images/shim/DefaultImageList" | head -n1)"
[[ -n "$pauseImage" ]] || fail "pause image not found in Kubernetes image list"
echo "$LVSCARE_REF" > "$ROOT/images/shim/LvscareImageList"

# Normalize executable bits for rootfs scripts and binaries.
find "$ROOT" -type f -exec file {} \; \
  | grep -E '(executable,|/ld-)' \
  | awk -F: '{print $1}' \
  | grep -vE '\.so' \
  | xargs -r chmod a+x

log "build final Sealos Cluster Image: $FINAL_IMAGE"
sudo sealos build \
  --platform "linux/$ARCH" \
  --label "sealos.io.type=rootfs" \
  --label "sealos.io.version=v1beta1" \
  --label "version=v$KUBERNETES_VERSION" \
  --label "image=$LVSCARE_REF" \
  --label "io.archinfra.release=$RELEASE_VERSION" \
  --label "io.archinfra.runtime=$RUNTIME_PROFILE" \
  --label "io.archinfra.cache.build-sha=$CACHE_BUILD_GIT_SHA" \
  --label "io.archinfra.cache.kubernetes=$KUBERNETES_CACHE_DIGEST" \
  --label "io.archinfra.cache.docker=$DOCKER_CACHE_DIGEST" \
  --label "io.archinfra.cache.crictl=$CRICTL_CACHE_DIGEST" \
  --label "io.archinfra.cache.sealos=$SEALOS_CACHE_DIGEST" \
  --env "defaultVIP=10.103.97.2" \
  --env "sandboxImage=${pauseImage#*/}" \
  -t "$FINAL_IMAGE" \
  "$ROOT"

# Verify target architecture before publishing.
arch_inspect="$(sudo buildah inspect "$FINAL_IMAGE" | jq -r '.OCIv1.architecture // .Docker.architecture // empty')"
[[ "$arch_inspect" == "$ARCH" ]] || fail "final image architecture mismatch: expected=$ARCH actual=$arch_inspect"

log "push final Cluster Image"
sudo sealos login -u "$GHCR_USER" -p "$GHCR_TOKEN" ghcr.io >/dev/null
sudo sealos push "$FINAL_IMAGE"
sudo sealos logout ghcr.io >/dev/null || true

FINAL_DIGEST="$(skopeo inspect --creds "$GHCR_USER:$GHCR_TOKEN" "docker://$FINAL_IMAGE" | jq -r '.Digest')"
[[ "$FINAL_DIGEST" == sha256:* ]] || fail "unable to resolve final image digest"

PROVENANCE="$OUT_DIR/runtime-v1.36.4-r1.provenance.env"
cat > "$PROVENANCE" <<EOF
BUILD_STATUS=VERIFIED_BUILD_ONLY
RELEASE_VERSION=$RELEASE_VERSION
BUILD_GIT_REPOSITORY=${GITHUB_REPOSITORY:-local}
BUILD_GIT_SHA=${GITHUB_SHA:-local}
BUILD_RUN_ID=${GITHUB_RUN_ID:-local}
ARCH=$ARCH
RUNTIME_PROFILE=$RUNTIME_PROFILE
FINAL_IMAGE=$FINAL_IMAGE
FINAL_DIGEST=$FINAL_DIGEST
KUBERNETES_VERSION=$KUBERNETES_VERSION
SEALOS_VERSION=$SEALOS_VERSION
DOCKER_VERSION=$DOCKER_VERSION
CRI_DOCKERD_VERSION=$CRI_DOCKERD_VERSION
CRICTL_VERSION=$CRICTL_VERSION
REGISTRY_VERSION=$REGISTRY_VERSION
DOCKER_BUNDLED_CONTAINERD_VERSION=$DOCKER_BUNDLED_CONTAINERD_VERSION
DOCKER_BUNDLED_RUNC_VERSION=$DOCKER_BUNDLED_RUNC_VERSION
SEALOS_CACHE_REF=$SEALOS_CACHE_REF
DOCKER_CACHE_REF=$DOCKER_CACHE_REF
CRICTL_CACHE_REF=$CRICTL_CACHE_REF
KUBERNETES_CACHE_REF=$KUBERNETES_CACHE_REF
LVSCARE_REF=$LVSCARE_REF
KUBERNETES_IMAGE_LIST_SHA256=$KUBERNETES_IMAGE_LIST_SHA256
EOF

log "SUCCESS final=$FINAL_IMAGE@$FINAL_DIGEST"
cat "$PROVENANCE"
