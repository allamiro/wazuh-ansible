#!/usr/bin/env bash
# Builds the offline bundle that deploys this branch on hosts without internet access. Run it on a
# host that has internet access and a container engine (podman or docker). The versions come from
# the roles, so the bundle always matches the code it ships with.
#
# The bundle holds:
#   mirror/    the internal package mirror (see roles/wazuh/vars/repo_airgap.yml for its layout)
#   ansible/   Python wheels and Ansible collections for the airgapped control node
#   wazuh-ansible-<commit>.tar.gz   this repository at HEAD
#   MANIFEST.txt, SHA256SUMS
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT_DIR="$ROOT/dist"
TARGETS="el9,ubuntu22"
ARCHES="x86_64"
CONTROL_PY=""
WITH_WINDOWS=true
WITH_MACOS=true
ENGINE="${CONTAINER_ENGINE:-}"

# Container image of each target OS id (IMAGE_<target> overrides one).
# shellcheck source=tools/airgap/images.sh
. "$ROOT/tools/airgap/images.sh"
WAZUH_GPG_FINGERPRINT="0DCFCA5547B19D2A6099506096B3EE5F29111145"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  -t, --targets LIST         Target OS ids, comma-separated (default: $TARGETS)
                             Known: $(printf '%s ' "${!IMAGES[@]}" | tr ' ' '\n' | sort | tr '\n' ' ')
  -a, --arch LIST            Architectures, comma-separated: x86_64, aarch64 (default: $ARCHES).
                             A foreign architecture needs qemu-user-static on this host.
  -p, --control-python X.Y   Python version of the airgapped control node (default: this host's)
  -o, --output DIR           Output directory (default: $OUT_DIR)
  -e, --engine CMD           Container engine (default: podman, else docker)
      --no-windows           Leave out the Windows agent
      --no-macos             Leave out the macOS agents
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--targets) TARGETS="$2"; shift 2 ;;
    -a|--arch) ARCHES="$2"; shift 2 ;;
    -p|--control-python) CONTROL_PY="$2"; shift 2 ;;
    -o|--output) OUT_DIR="$2"; shift 2 ;;
    -e|--engine) ENGINE="$2"; shift 2 ;;
    --no-windows) WITH_WINDOWS=false; shift ;;
    --no-macos) WITH_MACOS=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

value_of() {  # value_of <key> <file>: a scalar from a YAML vars file, quotes stripped
  sed -n "/^$1:/{s/^$1:[[:space:]]*//p;q;}" "$ROOT/$2" | tr -d "\"'"
}

fetch() {  # fetch <url> <dest>: downloads once, atomically
  [ -s "$2" ] && return 0
  mkdir -p "$(dirname "$2")"
  curl -fsSL --retry 3 -o "$2.part" "$1" || die "Download failed: $1"
  mv "$2.part" "$2"
}

# --- Versions, read from the roles ------------------------------------------------------------------
WAZUH_VERSION=$(value_of wazuh_manager_version roles/wazuh/ansible-wazuh-manager/defaults/main.yml)
FILEBEAT_VERSION=$(value_of filebeat_version roles/wazuh/ansible-filebeat-oss/defaults/main.yml)
FB_MODULE=$(value_of filebeat_module_package_name roles/wazuh/ansible-filebeat-oss/defaults/main.yml)
TEMPLATE_BRANCH=$(value_of wazuh_template_branch roles/wazuh/ansible-filebeat-oss/defaults/main.yml)
CERTS_TOOL_VERSION=$(value_of certs_gen_tool_version roles/wazuh/vars/repo.yml)
WAZUH_MAJOR="${WAZUH_VERSION%%.*}.x"
for v in WAZUH_VERSION FILEBEAT_VERSION FB_MODULE TEMPLATE_BRANCH CERTS_TOOL_VERSION; do
  [ -n "${!v}" ] || die "Could not read $v from the roles"
done

CONTROL_PY="${CONTROL_PY:-$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')}"
if [ -z "$ENGINE" ]; then ENGINE=$(command -v podman || command -v docker || true); fi
[ -n "$ENGINE" ] || die "No container engine found: install podman or docker, or pass --engine"
for cmd in curl git python3 sha256sum sha512sum tar; do
  command -v "$cmd" >/dev/null || die "$cmd is required"
done

IFS=, read -r -a target_list <<< "$TARGETS"
IFS=, read -r -a arch_list <<< "$ARCHES"
for target in "${target_list[@]}"; do
  [ -n "$(image_for "$target")" ] || die "Unknown target '$target'. Known: ${!IMAGES[*]} (or set IMAGE_${target})"
done
for arch in "${arch_list[@]}"; do
  case "$arch" in x86_64|aarch64) ;; *) die "Unknown architecture '$arch'" ;; esac
done

BUNDLE_NAME="wazuh-airgap-${WAZUH_VERSION}"
BUNDLE="$OUT_DIR/$BUNDLE_NAME"
MIRROR="$BUNDLE/mirror"
mkdir -p "$MIRROR"
log "Building $BUNDLE_NAME (targets: $TARGETS, arch: $ARCHES, control node Python $CONTROL_PY)"

# --- Files the roles download directly --------------------------------------------------------------
log "Wazuh GPG key"
fetch https://packages.wazuh.com/key/GPG-KEY-WAZUH "$MIRROR/key/GPG-KEY-WAZUH"
if command -v gpg >/dev/null; then
  fprs=$(gpg --show-keys --with-colons "$MIRROR/key/GPG-KEY-WAZUH" 2>/dev/null | awk -F: '!found && $1 == "fpr" { print $10; found = 1 }')
  [ "$fprs" = "$WAZUH_GPG_FINGERPRINT" ] \
    || die "Unexpected Wazuh GPG key fingerprint '$fprs' (expected $WAZUH_GPG_FINGERPRINT)"
else
  echo "WARNING: gpg not found, the fingerprint of the Wazuh GPG key is not checked" >&2
fi

log "Certificates tool, Filebeat module and alerts template"
fetch "https://packages.wazuh.com/${CERTS_TOOL_VERSION}/wazuh-certs-tool.sh" "$MIRROR/${CERTS_TOOL_VERSION}/wazuh-certs-tool.sh"
fetch "https://packages.wazuh.com/${WAZUH_MAJOR}/filebeat/${FB_MODULE}" "$MIRROR/filebeat/${FB_MODULE}"
fetch "https://raw.githubusercontent.com/wazuh/wazuh/${TEMPLATE_BRANCH}/extensions/elasticsearch/7.x/wazuh-template.json" \
  "$MIRROR/filebeat/wazuh-template.json"
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$MIRROR/filebeat/wazuh-template.json" \
  || die "wazuh-template.json is not valid JSON"

if $WITH_WINDOWS; then
  log "Windows agent"
  msi="wazuh-agent-${WAZUH_VERSION}-1.msi"
  fetch "https://packages.wazuh.com/${WAZUH_MAJOR}/windows/$msi" "$MIRROR/windows/$msi"
  fetch "https://packages.wazuh.com/${WAZUH_MAJOR}/checksums/wazuh/${WAZUH_VERSION}/$msi.sha512" \
    "$MIRROR/checksums/wazuh/${WAZUH_VERSION}/$msi.sha512"
  expected=$(awk '{ print $1; exit }' "$MIRROR/checksums/wazuh/${WAZUH_VERSION}/$msi.sha512")
  actual=$(sha512sum "$MIRROR/windows/$msi" | awk '{ print $1 }')
  [ "$expected" = "$actual" ] || die "SHA512 mismatch for $msi"
fi

if $WITH_MACOS; then
  log "macOS agents"
  for flavor in intel64 arm64; do
    pkg="wazuh-agent-${WAZUH_VERSION}-1.${flavor}.pkg"
    fetch "https://packages.wazuh.com/${WAZUH_MAJOR}/macos/$pkg" "$MIRROR/macos/$pkg"
  done
fi

# --- Package repositories, one per target OS and architecture ---------------------------------------
engine_is_podman=false
"$ENGINE" --version 2>/dev/null | grep -qi podman && engine_is_podman=true

for target in "${target_list[@]}"; do
  image=$(image_for "$target")
  for arch in "${arch_list[@]}"; do
    case "$arch" in
      x86_64) platform=linux/amd64 ;;
      aarch64) platform=linux/arm64 ;;
      *) die "Unknown architecture '$arch'" ;;
    esac
    log "Package repositories for $target/$arch ($image)"
    dest="$MIRROR/$target/$arch"
    mkdir -p "$dest"
    owner_env=()
    # A rootful engine writes the files as root: hand them back. Rootless podman maps root to us.
    if ! $engine_is_podman; then owner_env=(-e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)"); fi
    "$ENGINE" run --rm --pull=missing --platform "$platform" \
      -e WAZUH_VERSION="$WAZUH_VERSION" -e FILEBEAT_VERSION="$FILEBEAT_VERSION" -e WAZUH_MAJOR="$WAZUH_MAJOR" \
      "${owner_env[@]}" \
      -v "$dest:/out:Z" \
      -v "$MIRROR/key:/bundle-key:ro,Z" \
      -v "$ROOT/tools/airgap/build-os-repo.sh:/build-os-repo.sh:ro,Z" \
      "$image" bash /build-os-repo.sh
  done
done

# --- Control node: Python wheels and Ansible collections --------------------------------------------
log "Python wheels for the control node (Python $CONTROL_PY)"
WHEELS="$BUNDLE/ansible/wheels"
mkdir -p "$WHEELS"
# Binary wheels only, for the control node's Python and for glibc 2.28 or older, whatever this host
# runs: left to itself pip picks wheels for this host's glibc (cryptography needs 2.34 then), which
# an EL8 control node (glibc 2.28) cannot install.
rm -f "$WHEELS"/*.whl
python3 -m pip download --quiet --only-binary=:all: -d "$WHEELS" -r "$ROOT/requirements.txt" \
  --python-version "$CONTROL_PY" --implementation cp \
  --platform manylinux2014_x86_64 --platform manylinux_2_17_x86_64 --platform manylinux_2_28_x86_64
cp "$ROOT/requirements.txt" "$BUNDLE/ansible/requirements.txt"

log "Ansible collections"
BUILD_VENV=$(mktemp -d)
trap 'rm -rf "$BUILD_VENV"' EXIT
python3 -m venv "$BUILD_VENV"
"$BUILD_VENV/bin/pip" install --quiet -r "$ROOT/requirements.txt"
rm -rf "$BUNDLE/ansible/collections"
"$BUILD_VENV/bin/ansible-galaxy" collection download -r "$ROOT/requirements.yml" -p "$BUNDLE/ansible/collections" >/dev/null
# The offline install the airgapped control node will run, tried here first. The requirements file
# that 'collection download' writes names the tarballs relative to the current directory.
(cd "$BUNDLE/ansible/collections" \
  && "$BUILD_VENV/bin/ansible-galaxy" collection install --offline -r requirements.yml -p "$BUILD_VENV/collections" >/dev/null)

# --- This repository --------------------------------------------------------------------------------
log "wazuh-ansible code"
commit=$(git -C "$ROOT" rev-parse --short HEAD)
branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
  echo "WARNING: the working tree has uncommitted changes; the bundle ships HEAD ($commit) without them" >&2
fi
rm -f "$BUNDLE"/wazuh-ansible-*.tar.gz
git -C "$ROOT" archive --format=tar.gz --prefix=wazuh-ansible/ -o "$BUNDLE/wazuh-ansible-${commit}.tar.gz" HEAD

# --- Manifest and checksums -------------------------------------------------------------------------
log "Manifest and checksums"
{
  echo "bundle:            $BUNDLE_NAME"
  echo "built:             $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname)"
  echo "wazuh-ansible:     $branch @ $(git -C "$ROOT" rev-parse HEAD)"
  echo "wazuh:             $WAZUH_VERSION"
  echo "filebeat:          $FILEBEAT_VERSION (module $FB_MODULE, template $TEMPLATE_BRANCH)"
  echo "certs tool:        $CERTS_TOOL_VERSION"
  echo "targets:           $TARGETS ($ARCHES)"
  echo "control python:    $CONTROL_PY"
  echo
  echo "Python wheels:"
  find "$WHEELS" -name '*.whl' -printf '  %f\n' | sort
  echo "Collections:"
  find "$BUNDLE/ansible/collections" -name '*.tar.gz' -printf '  %f\n' | sort
  for target in "${target_list[@]}"; do
    for arch in "${arch_list[@]}"; do
      echo "$target/$arch:"
      find "$MIRROR/$target/$arch/wazuh" -maxdepth 1 \( -name '*.rpm' -o -name '*.deb' \) -printf '  %f\n' | sort
      echo "  + $(find "$MIRROR/$target/$arch/deps" -maxdepth 1 \( -name '*.rpm' -o -name '*.deb' \) | wc -l) OS dependency packages"
      if [ -s "$MIRROR/$target/$arch/MISSING.txt" ]; then
        echo "  not available on this release: $(tr '\n' ' ' < "$MIRROR/$target/$arch/MISSING.txt")"
      fi
    done
  done
} > "$BUNDLE/MANIFEST.txt"

(cd "$BUNDLE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

log "Archive"
tar -C "$OUT_DIR" -cf "$OUT_DIR/$BUNDLE_NAME.tar" "$BUNDLE_NAME"
(cd "$OUT_DIR" && sha256sum "$BUNDLE_NAME.tar" > "$BUNDLE_NAME.tar.sha256")

cat "$BUNDLE/MANIFEST.txt"
echo
log "Done: $OUT_DIR/$BUNDLE_NAME.tar ($(du -h "$OUT_DIR/$BUNDLE_NAME.tar" | cut -f1))"
echo "Carry it across with $BUNDLE_NAME.tar.sha256, and check it on the other side before use."
