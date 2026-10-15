---
name: wazuh-stable-upgrade
description: Move the airgap or commercial branch of this wazuh-ansible fork to a newer stable (GA) Wazuh release. Use when asked to upgrade, bump, or rebase onto the latest stable Wazuh version, or to check whether the branch is on the latest stable release.
---

# Upgrade a deployment branch to a newer stable Wazuh release

This fork keeps two deployment branches, both cut from an upstream **GA tag** of
`wazuh/wazuh-ansible`, never from `main` (which carries the next, unreleased version):

- `airgap`: deploys from an internal mirror built from an offline bundle
- `commercial`: deploys from the public Wazuh repositories

## Rules

- Only GA tags count as stable: `vX.Y.Z` with no `-alpha`, `-beta` or `-rc` suffix. A
  version branch upstream (for example `4.14.11`) is work in progress, not a release.
- `VERSION.json` can say `"stage": "rcN"` even on a GA tag. The tag decides, not that field.
- Do not jump to a new major version (4.x to 5.x) through this skill. 5.x is a different
  code base (roles, variables and playbooks all change), so it needs its own branch and plan.
- Never add Claude as author or co-author of a commit.

## Steps

1. Find the latest GA tag:

   ```bash
   git remote get-url upstream || git remote add upstream https://github.com/wazuh/wazuh-ansible.git
   git ls-remote --tags upstream | grep -v '\^{}' | sed 's#.*refs/tags/##' \
     | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -5
   ```

2. Compare with the branch's version:
   `grep -h '_version:' roles/wazuh/ansible-wazuh-manager/defaults/main.yml`

3. Fetch the tag and merge it into the branch (a merge, not a rebase, keeps the history
   that is already pushed intact):

   ```bash
   git fetch upstream tag vX.Y.Z --no-tags
   git switch <airgap|commercial>
   git merge --no-ff vX.Y.Z -m "Merge upstream stable vX.Y.Z"
   ```

4. Conflicts appear where this fork changed upstream files. Keep the fork's changes:
   - `roles/wazuh/ansible-filebeat-oss/tasks/config.yml`: the template `url` must stay
     `"{{ wazuh_template_url }}"`.
   - `roles/wazuh/*/tasks/main.yml` (airgap only): keep the
     `repo_airgap.yml` include for `packages_repository == 'airgap'`.
   - `roles/wazuh/vars/repo_vars.yml` (airgap only): keep `packages_repository: airgap`.

5. Look for new internet downloads the release added, which an airgapped run would miss:

   ```bash
   git diff <old-tag> vX.Y.Z -- roles playbooks | grep -E '^\+.*https?://'
   ```

   Every new URL needs to be a variable that `roles/wazuh/vars/repo_airgap.yml`
   overrides, and a file that `tools/airgap/build-bundle.sh` downloads.

6. Check `requirements.txt` and `requirements.yml` still work with the new release, then
   run a syntax check of every playbook:

   ```bash
   python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
   .venv/bin/ansible-galaxy collection install -r requirements.yml
   cd playbooks && for p in *.yml; do ../.venv/bin/ansible-playbook -i localhost, --syntax-check "$p"; done
   ```

7. On the airgap branch, build a new bundle (skill `wazuh-airgap-bundle`). An old bundle
   cannot deploy the new version.

8. Commit as the user, then push the branch only after the user confirms.
