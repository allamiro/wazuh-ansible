---
name: wazuh-airgap-bundle
description: Build, check or extend the offline bundle (Wazuh packages, OS dependencies, Python wheels, Ansible collections and this repository) that deploys Wazuh on air-gapped hosts. Use on the internet-connected side, when asked to build, rebuild or update the airgap bundle, add a target OS or architecture to it, or find out why a bundle build fails.
---

# Build the Wazuh offline bundle

The `airgap` branch deploys the stable Wazuh release it is pinned to, entirely from an internal
mirror. That mirror comes from one bundle built here, on a host with internet access, and carried
across the air gap. `tools/airgap/build-bundle.sh` builds it, reading every version from the
roles, so a bundle always matches the commit it ships.

## What the bundle holds

| Path in the bundle | Contents | Used by |
|---|---|---|
| `mirror/key/GPG-KEY-WAZUH` | Wazuh signing key (fingerprint checked) | every role |
| `mirror/<os>/<arch>/wazuh/` | manager, indexer, dashboard, filebeat, agent packages + repo metadata | roles, via `wazuh_repo` |
| `mirror/<os>/<arch>/deps/` | OS packages the roles and Ansible need, resolved on that OS | `playbooks/airgap-prepare.yml` |
| `mirror/<certs tool version>/wazuh-certs-tool.sh` | certificates tool | indexer role, on the control node |
| `mirror/filebeat/` | Wazuh Filebeat module + alerts template | filebeat role |
| `mirror/windows/`, `mirror/checksums/`, `mirror/macos/` | Windows MSI (+ SHA512), macOS pkgs | agent role |
| `ansible/wheels/` | ansible-core and its dependencies, binary wheels | control node venv |
| `ansible/collections/` | `ansible.windows` (needed even for Linux-only runs) | control node |
| `wazuh-ansible-<commit>.tar.gz` | this repository at HEAD | control node |
| `MANIFEST.txt`, `SHA256SUMS` | versions, package lists, checksums | import check |

## Before building, ask or decide

1. **Target OS ids**: one per OS release the airgapped hosts run: `el8`, `el9`, `amazon2023`,
   `ubuntu20`, `ubuntu22`, `ubuntu24`, `debian11`, `debian12`. A host whose OS is not in the
   bundle cannot install anything. `airgap-prepare.yml` stops on such a host.
2. **Architectures**: `x86_64` by default. `aarch64` on an x86_64 build host needs
   `qemu-user-static` (binfmt) for the container engine.
3. **Control node Python** (`--control-python`): the `python3` version of the airgapped control
   node. ansible-core 2.16 needs 3.10 to 3.12. On RHEL 9 that means installing `python3.11` or
   `python3.12` there, not the default 3.9. The wheels are for x86_64 Linux with glibc 2.17 or
   newer, so EL8 and later work.
4. **RHEL or Rocky**: EL targets resolve against Rocky Linux images by default. For RHEL hosts
   that must only get Red Hat-signed packages, set `IMAGE_el9=registry.access.redhat.com/ubi9/ubi`
   (UBI lacks some packages, which then show in `MISSING.txt`) or a subscribed RHEL image.

## Build

```bash
git status            # the bundle ships HEAD: commit first
tools/airgap/build-bundle.sh --targets el9,ubuntu22 --control-python 3.12
```

Needs `podman` or `docker`, `curl`, `git`, `python3` with `venv`, `sha256sum`, and `gpg` to check
the key fingerprint. Rerunning is cheap: files already downloaded are kept, and each OS
repository is rebuilt from scratch. Output goes to `dist/` (git-ignored):

- `dist/wazuh-airgap-<version>.tar` and `dist/wazuh-airgap-<version>.tar.sha256` go across
- `dist/wazuh-airgap-<version>/` is the unpacked tree, for checking

## Check the result before carrying it across

1. Read `MANIFEST.txt`. Every target needs five Wazuh packages (manager, indexer, dashboard,
   filebeat, agent) and a non-zero count of OS dependencies.
2. Read the "not available on this release" lines. `libopenscap8` is missing on Ubuntu 22.04+
   and Debian 12. That is expected, because the roles only install it when openscap is enabled,
   which is off by default. Any other missing name needs a look.
3. `cd dist/wazuh-airgap-<version> && sha256sum -c --quiet SHA256SUMS`
4. Prove it installs offline: `tools/airgap/test-bundle.sh dist/wazuh-airgap-<version>`. For
   every target in the bundle, it removes all of a fresh container's own repositories, configures
   only the bundle's (as `repo_airgap.yml` and `airgap-prepare.yml` do), and installs the server
   stack, the OS packages the roles install, and the agent. Do not carry a bundle across that
   fails this. On Debian/Ubuntu the OS packages are only resolved (`apt-get -s`), because
   `software-properties-common` pulls in systemd, whose scripts cannot run in a container.

## How packages are trusted

- RPMs: downloaded from the signed Wazuh and distribution repositories, then checked with
  `rpm -K`. The build stops on any package without a valid signature. Targets check them again
  (`gpgcheck`), against the Wazuh key and against the distribution keys shipped as
  `deps/RPM-GPG-KEY-DEPS`.
- DEBs: apt checks every file against the signed repository indexes at download time. The
  internal apt repositories are flat and unsigned (`[trusted=yes]`), so on the airgapped side
  `SHA256SUMS` is what protects them. Check it on import, and keep the mirror writable only by
  the people who import bundles.

## When the build fails

| Symptom | Cause, fix |
|---|---|
| `does not have a compatible architecture` (dnf) | an arch filter is missing in `build-os-repo.sh`: downloads must keep `--arch $(uname -m) --arch noarch` |
| `<pkg> <version> not found in the Wazuh repository` | that version was never published for that OS/arch, or the roles were bumped to an unreleased version |
| `Unexpected Wazuh GPG key fingerprint` | the key changed, or the download was intercepted. Stop and check before trusting a new key |
| `BAD SIGNATURE` | a mirror served a corrupted or tampered package. Rerun. If it repeats, report it, never skip the check |
| image pull fails | set `IMAGE_<target>` to an image the build host can pull |
| test: `nothing provides <lib>` / `<pkg> ... is not installable` | a package the build container already had was not downloaded. `build-os-repo.sh` downloads whatever its own tooling (dnf-plugins-core, ca-certificates) added. Anything else must come from the image itself: add the package to `RPM_DEPS`/`DEB_DEPS` |
| wheels missing for the control node | `--control-python` does not match a Python that has binary wheels for every dependency. Use a newer Python on the control node |

## Extending it

- A new file the roles download, for example after an upgrade: make its URL a variable, override
  it in `roles/wazuh/vars/repo_airgap.yml`, and add a `fetch` for it in `build-bundle.sh`.
- A new OS dependency: add it to `RPM_DEPS` or `DEB_DEPS` in `tools/airgap/build-os-repo.sh`.
- A new target OS: add it to `IMAGES` in `tools/airgap/images.sh`. Its id must match what
  `wazuh_airgap_os` computes from the facts (`el<major>` for EL, `<distribution><major>` otherwise),
  or the hosts must set `wazuh_airgap_os_id`.

Commit as the user, never with Claude as author or co-author.
