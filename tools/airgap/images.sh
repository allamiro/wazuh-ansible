# shellcheck shell=bash
# Container image of each target OS id, sourced by build-bundle.sh and test-bundle.sh. The id is
# what roles/wazuh/vars/repo_airgap.yml computes from the facts of a host (wazuh_airgap_os).
# Override one with IMAGE_<target>, for example IMAGE_el9=registry.access.redhat.com/ubi9/ubi to
# resolve against RHEL instead of Rocky Linux.
# shellcheck disable=SC2034
declare -A IMAGES=(
  [el8]=docker.io/rockylinux/rockylinux:8
  [el9]=docker.io/rockylinux/rockylinux:9
  [amazon2023]=docker.io/library/amazonlinux:2023
  [ubuntu20]=docker.io/library/ubuntu:20.04
  [ubuntu22]=docker.io/library/ubuntu:22.04
  [ubuntu24]=docker.io/library/ubuntu:24.04
  [debian11]=docker.io/library/debian:11
  [debian12]=docker.io/library/debian:12
)

image_for() {  # image_for <target>: the image, IMAGE_<target> first
  local override="IMAGE_$1"
  printf '%s' "${!override:-${IMAGES[$1]:-}}"
}
