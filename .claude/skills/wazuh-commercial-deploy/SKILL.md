---
name: wazuh-commercial-deploy
description: Deploy Wazuh (indexer, manager, dashboard, agents) on internet-connected hosts from the public Wazuh repositories, using the commercial branch of this wazuh-ansible fork pinned to a stable release. Use when asked to set up the control node, write the inventory, run preflight checks, deploy or extend a connected Wazuh installation, or troubleshoot a connected run.
---

# Deploy Wazuh from the public repositories

The `commercial` branch is the upstream stable release it was cut from (see the
`wazuh-stable-upgrade` skill), plus pinned control node tooling and a preflight check. Every
host installs from `packages.wazuh.com` (`packages_repository: production`), so targets need
outbound HTTPS to it, directly or through a proxy. For hosts without internet access use the
`airgap` branch instead.

## 1. Control node

Python 3.10 to 3.12, `openssl` and `gpg`. All versions are pinned, so the same commit always
installs the same tooling:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt                    # ansible-core 2.16.19
.venv/bin/ansible-galaxy collection install -r requirements.yml   # ansible.windows 3.8.0
. .venv/bin/activate
```

`ansible.windows` is required even for Linux-only deployments, because the agent role's
handlers reference `win_*` modules and the playbook fails to parse without it.

## 2. Inventory

`playbooks/ansible.cfg` sets `hash_behaviour=merge`, so run `ansible-playbook` from `playbooks/`.

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

## 3. Preflight

```bash
cd playbooks
ansible-playbook -i inventory preflight.yml
```

It stops when a target cannot reach `packages.wazuh.com`, when the Wazuh signing key does not
have its known fingerprint (`0DCFCA5547B19D2A6099506096B3EE5F29111145`), or when the control node
lacks `openssl`, `gpg` or `ansible.windows`. It warns when an indexer host has less than 4 GB of
memory. Behind a proxy, set `wazuh_preflight_proxy` for the check. apt/dnf on the targets need
the same proxy in their own configuration (`/etc/apt/apt.conf.d/`, `proxy=` in `/etc/dnf/dnf.conf`),
because the roles do not set one.

## 4. Deploy

```bash
ansible-playbook -i inventory wazuh-single.yml     # or wazuh-production-ready.yml
ansible-playbook -i inventory wazuh-agent.yml
```

The certificates are generated on the control node in `playbooks/indexer/certificates/`
(git-ignored). They hold the private keys of the deployment, so back them up and restrict access.

## 5. Verify

- Indexer: `curl -k -u admin:<pw> https://<indexer>:9200/_cluster/health?pretty` returns green
  (yellow on a single node).
- Manager: `systemctl status wazuh-manager filebeat` and `filebeat test output` on the manager.
- Dashboard: `https://<dashboard>` and log in.
- Agents: `/var/ossec/bin/agent_control -l` on the manager.

## Version pinning

- Wazuh packages: pinned by the role defaults (`wazuh_manager_version`, `indexer_version`,
  `dashboard_version`, `wazuh_agent_version`, `filebeat_version`). Do not override them per host:
  mixed versions break the cluster and the dashboard.
- Upgrading means moving the branch to a newer GA tag (`wazuh-stable-upgrade` skill) and
  rerunning the playbooks, never pointing a host at `pre-release` or `staging`.

## Troubleshooting

| Symptom | Cause, fix |
|---|---|
| `couldn't resolve module/action 'win_service'` | `ansible.windows` not installed: step 1 |
| `Failed to download ... packages.wazuh.com` | egress blocked or proxy not configured for apt/dnf on that host |
| apt `NO_PUBKEY 96B3EE5F29111145` | the key import failed on that host, often because of a proxy. Rerun once the preflight passes |
| indexer does not start | `vm.max_map_count` below 262144 or too little memory: check `journalctl -u wazuh-indexer` |

Commit as the user, never with Claude as author or co-author.
