#!/usr/bin/env bash
# Runs inside a container of one target OS (started by build-bundle.sh). Downloads the Wazuh packages
# and the OS packages that they and the roles need, resolved the way that OS resolves them, and builds
# two package repositories from them:
#
#   /out/wazuh/  wazuh-manager, wazuh-indexer, wazuh-dashboard, filebeat, wazuh-agent
#   /out/deps/   everything else
#
# The packages come from the signed Wazuh and distribution repositories. RPM signatures are checked
# again once downloaded, and the build stops on any package that is not signed by a trusted key.
#
# Environment: WAZUH_VERSION, FILEBEAT_VERSION, WAZUH_MAJOR (4.x), HOST_UID/HOST_GID (optional: give
# the files back to that owner, for a rootful container engine). The Wazuh GPG key is mounted at
# /bundle-key/GPG-KEY-WAZUH.
set -euo pipefail

: "${WAZUH_VERSION:?}" "${FILEBEAT_VERSION:?}" "${WAZUH_MAJOR:?}"
OUT=/out
DL=$(mktemp -d)
MISSING="$OUT/MISSING.txt"
WAZUH_REPO_URL="https://packages.wazuh.com/${WAZUH_MAJOR}"

# OS packages the roles install, plus what Ansible itself needs on the target. Names a release does
# not have are skipped and listed in MISSING.txt. No curl on EL: images ship curl-minimal, which
# conflicts with it, and the roles only install curl on Debian.
RPM_DEPS=(acl gnupg2 libcap openscap-scanner procps-ng python3 python3-libselinux tar unzip wget)
DEB_DEPS=(acl adduser apt-transport-https ca-certificates curl debconf gnupg libopenscap8 lsb-release
          procps python3 python3-apt software-properties-common tar unzip wget xsltproc)

# Names of the installed packages, sorted (the imported keys are not packages).
rpm_names() { rpm -qa --qf '%{NAME}\n' | grep -v '^gpg-pubkey$' | sort -u; }
deb_names() { dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" { print $2 }' | sort -u; }

log() { printf '[%s] %s\n' "${ID:-?}${VERSION_ID:+-$VERSION_ID}" "$*"; }

rm -rf "$OUT/wazuh" "$OUT/deps"
mkdir -p "$OUT/wazuh" "$OUT/deps"
: > "$MISSING"

# shellcheck source=/dev/null
. /etc/os-release

build_rpm() {
  local pm
  pm=$(command -v dnf || command -v yum)
  local baseline
  baseline=$(rpm_names)

  rpm --import /bundle-key/GPG-KEY-WAZUH
  for key in /etc/pki/rpm-gpg/RPM-GPG-KEY-*; do rpm --import "$key"; done
  cat > /etc/yum.repos.d/wazuh.repo <<EOF
[wazuh]
name=Wazuh
baseurl=${WAZUH_REPO_URL}/yum/
gpgcheck=1
gpgkey=file:///bundle-key/GPG-KEY-WAZUH
enabled=1
EOF

  log "Refreshing repository metadata"
  "$pm" -y -q makecache >/dev/null
  # 'dnf download' fetches a package even when the container already has it installed.
  "$pm" -y -q install dnf-plugins-core >/dev/null

  local deps=() p
  for p in "${RPM_DEPS[@]}"; do
    if [ -n "$("$pm" -q repoquery --latest-limit 1 "$p" 2>/dev/null)" ]; then deps+=("$p"); else echo "$p" >> "$MISSING"; fi
  done

  # Without it, every architecture of a name is requested (aarch64, i686...) and they conflict.
  local arch_opts=(--arch "$(uname -m)" --arch noarch)
  # The manager and the agent conflict, so they are resolved in separate transactions.
  log "Downloading the Wazuh server packages and the OS packages"
  "$pm" -y -q download --resolve "${arch_opts[@]}" --destdir "$DL" \
    "wazuh-manager-${WAZUH_VERSION}" "wazuh-indexer-${WAZUH_VERSION}" "wazuh-dashboard-${WAZUH_VERSION}" \
    "filebeat-${FILEBEAT_VERSION}" "${deps[@]}"
  log "Downloading the Wazuh agent package"
  "$pm" -y -q download --resolve "${arch_opts[@]}" --destdir "$DL" "wazuh-agent-${WAZUH_VERSION}"

  # What dnf-plugins-core brought into the container counted as installed above, and a target may
  # need it (openscap needs dbus-libs, for one): download it too.
  local added
  added=$(comm -13 <(echo "$baseline") <(rpm_names))
  if [ -n "$added" ]; then
    log "Downloading the packages the build tools added to the container: $(echo "$added" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    "$pm" -y -q download "${arch_opts[@]}" --destdir "$DL" $added
  fi

  log "Checking the package signatures"
  local bad=0 f
  for f in "$DL"/*.rpm; do
    rpm -K "$f" >/dev/null 2>&1 || { log "BAD SIGNATURE: $(basename "$f")"; bad=1; }
  done
  [ "$bad" -eq 0 ] || { log "Refusing to build a repository with unsigned or badly signed packages"; exit 1; }

  mv "$DL"/wazuh-*.rpm "$DL"/filebeat-*.rpm "$OUT/wazuh/"
  mv "$DL"/*.rpm "$OUT/deps/" 2>/dev/null || true

  # The keys that sign the OS packages, for the deps repository on the targets. Testing and beta
  # keys are left out.
  find /etc/pki/rpm-gpg -name 'RPM-GPG-KEY-*' ! -iname '*testing*' ! -iname '*beta*' -type f -print0 \
    | sort -z | xargs -0 cat > "$OUT/deps/RPM-GPG-KEY-DEPS"

  # Installed only now, so that it does not change what the downloads above resolved.
  log "Building the repository metadata"
  "$pm" -y -q install createrepo_c >/dev/null
  createrepo_c -q "$OUT/wazuh"
  createrepo_c -q "$OUT/deps"
}

build_deb() {
  export DEBIAN_FRONTEND=noninteractive
  local archives=/var/cache/apt/archives
  local baseline
  baseline=$(deb_names)

  log "Refreshing repository metadata"
  apt-get update -q >/dev/null
  # Needed to reach the Wazuh repository over HTTPS. Downloaded below again for the targets.
  apt-get install -y -q --no-install-recommends ca-certificates >/dev/null
  # apt reads an ASCII-armored key from a .asc file, so gnupg is not needed in the container.
  cp /bundle-key/GPG-KEY-WAZUH /usr/share/keyrings/wazuh.asc
  echo "deb [signed-by=/usr/share/keyrings/wazuh.asc] ${WAZUH_REPO_URL}/apt/ stable main" \
    > /etc/apt/sources.list.d/wazuh.list
  apt-get update -q >/dev/null

  local deps=() p
  for p in "${DEB_DEPS[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then deps+=("$p"); else echo "$p" >> "$MISSING"; fi
  done

  version_of() {
    # No early exit in awk: it would close the pipe on apt-cache, which pipefail reports as a failure.
    apt-cache madison "$1" | awk -v v="$2" '!found && ($3 == v || index($3, v "-") == 1) { print $3; found = 1 }'
  }
  local pkgs=() name ver
  for name in wazuh-manager wazuh-indexer wazuh-dashboard; do
    ver=$(version_of "$name" "$WAZUH_VERSION")
    [ -n "$ver" ] || { log "$name $WAZUH_VERSION not found in the Wazuh repository"; exit 1; }
    pkgs+=("$name=$ver")
  done
  ver=$(version_of filebeat "$FILEBEAT_VERSION")
  [ -n "$ver" ] || { log "filebeat $FILEBEAT_VERSION not found in the Wazuh repository"; exit 1; }
  pkgs+=("filebeat=$ver")

  # --reinstall downloads the packages the container already has too. apt checks every file
  # against the signed repository indexes.
  log "Downloading the Wazuh server packages and the OS packages"
  rm -f "$archives"/*.deb
  apt-get install -y -q --download-only --reinstall --no-install-recommends "${pkgs[@]}" "${deps[@]}" >/dev/null
  mv "$archives"/*.deb "$DL/"

  # The manager and the agent conflict, so they are resolved in separate transactions.
  log "Downloading the Wazuh agent package"
  ver=$(version_of wazuh-agent "$WAZUH_VERSION")
  [ -n "$ver" ] || { log "wazuh-agent $WAZUH_VERSION not found in the Wazuh repository"; exit 1; }
  apt-get install -y -q --download-only --reinstall --no-install-recommends "wazuh-agent=$ver" >/dev/null
  mv "$archives"/*.deb "$DL/"

  # What ca-certificates brought into the container counted as installed above, and a target that
  # lacks it could not install ca-certificates (openssl, for one): download it too.
  local added
  added=$(comm -13 <(echo "$baseline") <(deb_names))
  if [ -n "$added" ]; then
    log "Downloading the packages the build tools added to the container: $(echo "$added" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    (cd "$DL" && apt-get download -q $added >/dev/null 2>&1)
  fi

  mv "$DL"/wazuh-*.deb "$DL"/filebeat_*.deb "$OUT/wazuh/"
  mv "$DL"/*.deb "$OUT/deps/" 2>/dev/null || true

  # Installed only now, so that they do not change what the downloads above resolved.
  log "Building the repository metadata"
  apt-get install -y -q --no-install-recommends dpkg-dev apt-utils >/dev/null
  local repo
  for repo in "$OUT/wazuh" "$OUT/deps"; do
    (cd "$repo" && dpkg-scanpackages --multiversion . /dev/null 2>/dev/null > Packages \
      && gzip -9kf Packages && apt-ftparchive release . > Release)
  done
}

case " ${ID:-} ${ID_LIKE:-} " in
  *" rhel "*|*" fedora "*|*" centos "*|*" amzn "*) build_rpm ;;
  *" debian "*|*" ubuntu "*) build_deb ;;
  *) log "Unsupported OS: ${PRETTY_NAME:-unknown}"; exit 1 ;;
esac

if [ -n "${HOST_UID:-}" ]; then chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$OUT"; fi

log "wazuh: $(find "$OUT/wazuh" -maxdepth 1 -name '*.[rd][pe][mb]' | wc -l) packages, deps: $(find "$OUT/deps" -maxdepth 1 -name '*.[rd][pe][mb]' | wc -l) packages"
if [ -s "$MISSING" ]; then log "Not available on this release (skipped): $(tr '\n' ' ' < "$MISSING")"; fi
