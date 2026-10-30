---
name: agentdesk-create
description: Create and verify an AgentDesk cloud desktop on AWS or Alibaba Cloud with the providers' native CLIs - create the instance and a dedicated security group, install AgentDesk, and run the acceptance checks. Use when the user wants to spin up, deploy or POC-test a remote desktop / AgentDesk environment in the cloud, e.g. "create a cloud desktop", "set up an AgentDesk test machine", "run a POC on AWS or Aliyun", "deploy and verify the remote desktop".
---

# Create an AgentDesk Environment

One skill; the cloud, region, image, size and access mode are parameters. Call the provider CLI directly; do not add a provider framework or a config format of your own.

## Inputs and preparation

Determine from the request, existing deployment records and native CLI queries:

- Provider, profile, region, instance count, CPU/memory, OS version and architecture, disk.
- VPC/subnet, SSH key pair name, local private key path or SSH agent identity.
- SSH user, desktop user, locale, theme; direct RDP, private network/VPN, or SSH tunnel.
- Source CIDR for direct access, and whether to keep or delete the resources afterwards.

Unless the user names an OS, use Ubuntu 26.04 LTS or Debian 13 (newest XFCE and xrdp); use Ubuntu 22.04 only on request, with SSH tunnel access. Stay within the scope the user authorized. Ask only for required values that cannot be derived. Do not confuse the cloud key pair name with the local private key path. Check public key fingerprints or real SSH authentication only; never read, copy or print private key contents.

Check the native CLI, the credential identity and the target region first. If the CLI is missing, give the official install link and stop the dependent steps; do not install it silently:

- AWS: `command -v aws`, then read [the AWS flow](references/aws.md).
- Alibaba Cloud: `command -v aliyun`, then read [the Alibaba Cloud flow](references/aliyun.md).

Keep this run's parameters, native request JSON, create responses and acceptance logs in a subdirectory of the git-ignored `local/` (directory 700, files 600). Never write host addresses, accounts, resource IDs or key paths back into this skill or its templates. Replace every placeholder in a template with a queried value before use.

## Create and connect

Follow the provider flow. Use distinct, recognizable resource names/tags and record the IDs of the instance and its attached resources. Fix one ClientToken per create request; on a timeout, query by token/tag first and never retry blindly with a new token. Clean up only resources recorded in this run, and only as authorized.

Direct RDP needs a new security group limited to the source CIDR; a tunnel opens SSH only; private network/VPN uses the real internal route. The host installer does not manage security groups. Do not modify the original machine or shared security groups to test a new one.

Take the address from the cloud API and wait for SSH. Verify the host key against the fingerprint in the cloud console output, then write a dedicated known_hosts with strict checking. When the connection fails, separate boot, route/allowlist, host key and user key problems.

## Deploy

1. Wait for cloud-init to finish so it does not race with apt.
2. Install AgentDesk on the new host, passing this run's options (`--user`, `--rdp-mode`, `--rdp-port`, `--locale`, `--theme`):
   - Published code: `curl -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh | sudo bash -s -- --user "$DESKTOP_USER"`. Add `--ref BRANCH_OR_TAG` to test something other than the latest release. Without `--user`, use the saved desktop account or default to `agentdesk`. If the host cannot reach GitHub directly, pass the proxy to both curl (`-x URL`) and the installer (`--proxy URL`): HTTP(S) only, not saved, and never record a proxy password in the run logs.
   - Unpublished local changes: in the repository root, pack only the program, `tar -czf agentdesk.tar.gz agentdesk.sh install.sh mise.toml resources`, upload and extract it into a fresh temporary directory on the host, then run `sudo bash install.sh --user "$DESKTOP_USER"`. Never pack the whole working tree, `local/`, personal mise config, `.env` or SSH directories.
3. `init` installs the program to `/usr/local/lib/agentdesk`, the AgentDesk-maintained software list to `/etc/mise/config.toml`, the desktop defaults to `/etc/xdg/agentdesk`, and saves the options to `/etc/agentdesk/agentdesk.yaml`. Tool locks are generated on the host. It writes nothing into users' home directories.
4. Log in again as the desktop user. Check that `agentdesk install NAME` and native `mise use -g` both write `~/.config/mise/config.toml`, and that `agentdesk install --system NAME` writes `/etc/mise/config.local.toml` without touching `/etc/mise/config.toml`. Never run personal tasks as root. Old POC hosts are not migrated; clean up old deployment files only when this run explicitly includes a reinstall.
5. A non-interactive install sets no desktop password. Set it with an interactive `sudo passwd "$DESKTOP_USER"`. If automated GUI tests really need a temporary password, get explicit approval to generate and store it first, then pass it through a restricted local file and stdin; never put it in arguments, cloud user-data, logs or delivered documents. Never overwrite an existing password, and confirm SSH still enforces the intended key authentication afterwards.

## Verify and deliver

Run `agentdesk verify`: it reads the user from `/etc/agentdesk/agentdesk.yaml` and the listener from `xrdp.ini`, and prints `[PASS]/[FAIL]` to stdout. Check the versions of every tool in `mise.toml` and every preinstalled desktop app. Use `agentdesk upgrade --system --dry-run` to review the upgrade flow; run real upgrades only within this run's scope. Re-run `agentdesk init` without options and confirm the saved settings and user configuration are kept. Reboot the new POC and check services, SSH and RDP again. Never reboot the original machine.

After a real RDP login, check XFCE, the theme, Chinese fonts and input, app launch, the terminal PATH, reconnecting after a disconnect, and logging in again after a reboot. An active service, a reachable port or an installed package does not replace GUI acceptance; without a client or a human tester, record the item as "pending".

Run `agentdesk info` on the host for the connection steps; it reads the public address from AWS and Alibaba Cloud instance metadata, so replace a remaining `SERVER` placeholder with the address from the cloud API. Give the user a ready `.rdp` file with `ssh USER@HOST agentdesk rdp > agentdesk.rdp`. Report the instance ID, region, size, OS, SSH command, RDP address and user name, access mode, password setup steps, passed/failed/pending items, and whether the resources are kept. An SSH config snippet may be attached; never overwrite the user's local config. Private keys and passwords never appear in the output.
