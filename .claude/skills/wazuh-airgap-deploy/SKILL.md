---
name: wazuh-airgap-deploy
description: Deploy Wazuh (indexer, manager, dashboard, agents) on air-gapped hosts from an offline bundle, using the airgap branch of this wazuh-ansible fork. Use on the airgapped side, when asked to import a bundle, set up the internal mirror or control node, write the airgap inventory, run the deployment, add agents, or troubleshoot an airgapped run.
---

# Deploy Wazuh from the offline bundle

Everything comes from the bundle built by the `wazuh-airgap-bundle` skill: no host, including
the control node, reaches the internet. On this branch `packages_repository` defaults to `airgap`
(`roles/wazuh/vars/repo_vars.yml`), so every role reads its URLs from
`roles/wazuh/vars/repo_airgap.yml`, which points them at the internal mirror.

## 1. Import and check the bundle

```bash
sha256sum -c wazuh-airgap-<version>.tar.sha256
sudo mkdir -p /srv && sudo tar -C /srv -xf wazuh-airgap-<version>.tar
cd /srv/wazuh-airgap-<version> && sha256sum -c --quiet SHA256SUMS && cat MANIFEST.txt
```

Stop if a checksum fails. Check that `MANIFEST.txt` lists every OS release and architecture the
hosts run.

## 2. Serve the mirror

Every target, and the control node (certificates tool), fetches from the mirror over HTTP(S). The
agent role keeps using it for later enrollments, so a lasting web server is better than a
one-off one:

- Quick, for the duration of a deployment:
  `python3 -m http.server 8080 --directory /srv/wazuh-airgap-<version>/mirror`
- Lasting: an nginx or httpd vhost whose root is `.../mirror` (directory listing not needed).
  On SELinux hosts: `semanage fcontext -a -t httpd_sys_content_t '/srv/wazuh-airgap(/.*)?' && restorecon -R /srv`.

Open the port in the firewall to the targets only. HTTPS with an internal CA works too: the
targets then need that CA in their trust store, or set `wazuh_airgap_validate_certs: false` for
the prepare playbook only.

## 3. Set up the control node offline

Needs Python 3.10 to 3.12 (the version the bundle was built for: `control python` in
`MANIFEST.txt`), `openssl`, and `python3-venv` on Debian/Ubuntu.

```bash
B=/srv/wazuh-airgap-<version>
tar -xzf $B/wazuh-ansible-*.tar.gz -C ~ && cd ~/wazuh-ansible
python3 -m venv .venv
.venv/bin/pip install --no-index --find-links $B/ansible/wheels -r $B/ansible/requirements.txt
(cd $B/ansible/collections && ~/wazuh-ansible/.venv/bin/ansible-galaxy collection install --offline -r requirements.yml)
. .venv/bin/activate && ansible --version     # core 2.16.x
```

## 4. Inventory

`playbooks/ansible.cfg` sets `hash_behaviour=merge`, so run `ansible-playbook` from `playbooks/`.
Put the inventory next to it, with a `group_vars/all.yml`:

```yaml
# playbooks/inventory/group_vars/all.yml
wazuh_airgap_mirror_url: "http://10.0.0.5:8080"   # the mirror from step 2
# Only for a host whose OS id differs from what the facts give (el9, ubuntu22...):
# wazuh_airgap_os_id: el9
```

Hosts and groups follow the playbook you run:

- `wazuh-single.yml`: one host in group `aio`.
- `wazuh-production-ready.yml`: `wi1`, `wi2`, `wi3` (in `wi_cluster`), `manager`, `worker`,
  `dashboard`, each with `private_ip`, and the indexers with `indexer_node_name` (`node-1`...).
- `wazuh-agent.yml`: its `hosts:` is a placeholder (`<your wazuh agents hosts>`) and it sets
  `wazuh_managers` as play vars, which beat the inventory. Edit both in the playbook (or a copy
  of it), and set `wazuh_agent_authd.registration_address` to the manager to enroll with authd.

Before a real deployment, replace what the playbooks ship as defaults: the passwords
(`indexer_admin_password`, `dashboard_password`, the password in `wazuh_api_credentials`, all
`changeme` or `wazuh-wui`) and, in `wazuh-production-ready.yml`, the cluster `key`
(`openssl rand -hex 16`), which is the same in every copy of this repository. Keep them in an
`ansible-vault` file.

## 5. Run

```bash
cd ~/wazuh-ansible/playbooks
ansible-playbook -i inventory airgap-prepare.yml       # mirror reachable, OS deps repo added
ansible-playbook -i inventory wazuh-single.yml         # or wazuh-production-ready.yml
ansible-playbook -i inventory wazuh-agent.yml
```

`airgap-prepare.yml` must run first on every new host, including agents added later. The
certificates are generated on the control node in `playbooks/indexer/certificates/` (git-ignored).
They hold the private keys of the deployment, so back them up and restrict access.

## 6. Verify

- Indexer: `curl -k -u admin:<pw> https://<indexer>:9200/_cluster/health?pretty` returns green
  (yellow on a single node).
- Manager: `systemctl status wazuh-manager filebeat` and `filebeat test output` on the manager.
- Dashboard: `https://<dashboard>` and log in.
- Agents: `/var/ossec/bin/agent_control -l` on the manager.

## Checking that nothing reaches the internet

In airgap mode only `repo_airgap.yml` is loaded. Every other URL in the roles is either in
`repo.yml`, `repo_pre-release.yml` or `repo_staging.yml` (not loaded), or built from inventory
hosts. To review after an upgrade:

```bash
git grep -nE 'https?://' -- roles playbooks | grep -vE 'vars/repo(_pre-release|_staging)?\.yml|Mailing list|README'
```

Blocking egress at the firewall during the first run proves it. A task that tries to reach the
internet then fails at once instead of quietly succeeding.

## Troubleshooting

| Symptom | Cause, fix |
|---|---|
| `Set wazuh_airgap_mirror_url...` | the variable is not in the inventory, or the play does not load that `group_vars` |
| `The mirror has no packages for <os>/<arch>` | rebuild the bundle with that target, or set `wazuh_airgap_os_id` |
| apt/dnf fails on other repositories (`Failed to fetch`, `Cannot download repomd.xml`) | the host still lists internet repositories. Point them at the internal OS mirror, or disable them (`dnf config-manager --set-disabled <id>`, or move the apt `.list` files aside) |
| `couldn't resolve module/action 'win_service'` | `ansible.windows` is not installed: run the offline collection install of step 3 |
| dnf `GPG check FAILED` on an OS package | the host's OS does not match the image the deps were resolved on (for example Rocky packages on RHEL). Rebuild with `IMAGE_el9` set to a RHEL image |
| a dependency is missing on install | it is not in `RPM_DEPS`/`DEB_DEPS` and the host lacks it. Add it, rebuild, re-import |
| certificates tool fails on the control node | `openssl` missing, or the control node cannot reach the mirror |

Commit as the user, never with Claude as author or co-author.
