#!/usr/bin/env bash
# Proves that a bundle installs without internet access, before it is carried across. For every
# target OS and architecture in the bundle, starts a fresh container of that OS with all its own
# repositories removed, configures only the bundle's repositories (the way repo_airgap.yml and
# playbooks/airgap-prepare.yml do), and installs the Wazuh server stack with the OS packages the
# roles install, then the agent in a second container (the two conflict).
#
#   tools/airgap/test-bundle.sh dist/wazuh-airgap-<version>
#
# Needs podman or docker. The mirror is served on 127.0.0.1 for the duration of the test.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tools/airgap/images.sh
. "$ROOT/tools/airgap/images.sh"

BUNDLE=${1:?Usage: $(basename "$0") <bundle directory> [port]}
PORT=${2:-18080}
MIRROR="$(cd "$BUNDLE" && pwd)/mirror"
ENGINE="${CONTAINER_ENGINE:-$(command -v podman || command -v docker)}"
[ -d "$MIRROR" ] || { echo "No mirror/ in $BUNDLE" >&2; exit 2; }
[ -n "$ENGINE" ] || { echo "Install podman or docker" >&2; exit 2; }

# Versions, from the packages in the bundle.
WAZUH_VERSION=$(find "$MIRROR" -name 'wazuh-manager*' \( -name '*.rpm' -o -name '*.deb' \) -printf '%f\n' \
  | sed -E 's/^wazuh-manager[-_]([0-9.]+)-.*/\1/' | sort -u | head -n 1)
[ -n "$WAZUH_VERSION" ] || { echo "No wazuh-manager package in $MIRROR" >&2; exit 2; }

# Same lists the roles install (see build-os-repo.sh for what the bundle carries).
RPM_ROLE_DEPS="acl openscap-scanner unzip wget"
DEB_ROLE_DEPS="acl adduser apt-transport-https ca-certificates curl debconf gnupg procps python3-apt software-properties-common unzip wget"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$MIRROR" >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null' EXIT
URL="http://127.0.0.1:$PORT"
for _ in $(seq 20); do curl -fs -o /dev/null "$URL/key/GPG-KEY-WAZUH" && break; sleep 0.5; done

install_rpm() {  # install_rpm <image> <base url> <packages...>
  local image=$1 base=$2; shift 2
  "$ENGINE" run --rm --network=host "$image" bash -ec "
    rm -f /etc/yum.repos.d/*.repo
    printf '[wazuh_repo]\nname=Wazuh\nbaseurl=%s/wazuh/\ngpgcheck=1\ngpgkey=%s/key/GPG-KEY-WAZUH\n' '$base' '$URL' \
      > /etc/yum.repos.d/wazuh_repo.repo
    printf '[wazuh_airgap_deps]\nname=Deps\nbaseurl=%s/deps/\ngpgcheck=1\ngpgkey=%s/deps/RPM-GPG-KEY-DEPS\nmodule_hotfixes=1\n' \
      '$base' '$base' > /etc/yum.repos.d/wazuh_airgap_deps.repo
    dnf -y -q install $* >/dev/null 2>/tmp/err || { cat /tmp/err; exit 1; }
  "
}

install_deb() {  # install_deb <image> <base url> <packages...>; SIMULATE=1 only resolves them
  local image=$1 base=$2 mode=""; shift 2
  [ -n "${SIMULATE:-}" ] && mode="-s"
  "$ENGINE" run --rm --network=host -e DEBIAN_FRONTEND=noninteractive "$image" bash -ec "
    rm -rf /etc/apt/sources.list /etc/apt/sources.list.d/* /var/lib/apt/lists/*
    echo 'deb [trusted=yes] $base/deps/ ./' > /etc/apt/sources.list.d/wazuh-airgap-deps.list
    echo 'deb [trusted=yes] $base/wazuh/ ./' > /etc/apt/sources.list.d/wazuh.list
    apt-get update -q >/dev/null 2>/tmp/err || { cat /tmp/err; exit 1; }
    apt-get install -y -q --no-install-recommends $mode $* >/dev/null 2>/tmp/err || { cat /tmp/err; exit 1; }
  "
}

resolve_deb() { SIMULATE=1 install_deb "$@"; }

rc=0
check() {  # check <label> <command...>
  printf '%-48s' "$1"
  local out
  if out=$("${@:2}" 2>&1); then echo OK; else echo FAILED; echo "$out" | sed 's/^/    /'; rc=1; fi
}

for dir in "$MIRROR"/*/*/wazuh; do
  base_dir=$(dirname "$dir")
  arch=$(basename "$base_dir")
  target=$(basename "$(dirname "$base_dir")")
  image=$(image_for "$target")
  [ -n "$image" ] || { echo "$target: no image known, skipped"; continue; }
  [ "$arch" = "$(uname -m)" ] || { echo "$target/$arch: foreign architecture, skipped"; continue; }
  base="$URL/$target/$arch"
  if [ -f "$dir/repodata/repomd.xml" ]; then
    check "$target/$arch server stack" install_rpm "$image" "$base" \
      "wazuh-manager-$WAZUH_VERSION" "wazuh-indexer-$WAZUH_VERSION" "wazuh-dashboard-$WAZUH_VERSION" filebeat $RPM_ROLE_DEPS
    check "$target/$arch agent" install_rpm "$image" "$base" "wazuh-agent-$WAZUH_VERSION"
  else
    check "$target/$arch server stack" install_deb "$image" "$base" wazuh-manager wazuh-indexer wazuh-dashboard filebeat
    # Resolved only: software-properties-common pulls in systemd, whose scripts cannot run in a
    # container (systemd-resolved replaces the bind-mounted /etc/resolv.conf). Hosts have it already.
    check "$target/$arch OS packages the roles install" resolve_deb "$image" "$base" $DEB_ROLE_DEPS
    check "$target/$arch agent" install_deb "$image" "$base" python3-apt gnupg acl ca-certificates wazuh-agent
  fi
done

[ "$rc" -eq 0 ] && echo "The bundle installs offline on every target it holds." || echo "Some targets cannot install offline: fix the bundle before carrying it across."
exit "$rc"
