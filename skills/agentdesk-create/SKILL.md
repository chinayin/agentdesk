---
name: agentdesk-create
description: Create and verify an AgentDesk cloud desktop on AWS (Lightsail by default, or EC2) or Alibaba Cloud with the providers' native CLIs - create the instance, a source-limited firewall and a static IP, install AgentDesk, run the acceptance checks, and refresh the source allowlist when the user's IP changes. Use when the user wants to spin up, deploy or POC-test a remote desktop / AgentDesk environment in the cloud, e.g. "create a cloud desktop", "set up an AgentDesk test machine", "run a POC on AWS or Aliyun", "deploy and verify the remote desktop".
---

# Create an AgentDesk Environment

One skill; the cloud, region, image, size and access mode are parameters. Call the provider CLI directly; do not add a provider framework or a config format of your own.

## Inputs and preparation

Determine from the request, existing deployment records and native CLI queries:

- Provider, profile, region, instance count, CPU/memory, OS version and architecture, disk.
- VPC/subnet, SSH key pair name, local private key path or SSH agent identity.
- SSH user, desktop user, locale, theme; direct RDP, private network/VPN, or SSH tunnel.
- Source CIDR for direct access, and whether to keep or delete the resources afterwards.

On Alibaba Cloud the initial SSH user is `root` with key-pair authentication. The AgentDesk work account defaults to `agentdesk`, overridden by `--user`.

On AWS, default to Lightsail with Debian 13 and the 2 vCPU / 8 GB plan, which costs a third to a half less than the equivalent EC2 setup. Use EC2 only when the user asks for it, needs Ubuntu 26.x (Lightsail has no 26.x image), needs arm64, or will keep the desktop stopped most of the time (Lightsail bills stopped instances in full; EC2 then bills only disk and IP). Unless the user names an OS, use Debian 13 everywhere; use Ubuntu 26.10 when the user asks for Ubuntu. These two are verified; other Debian/Ubuntu releases also work but are unverified, so use one only when the user asks and record it as unverified. Stay within the scope the user authorized. Ask only for required values that cannot be derived. Do not confuse the cloud key pair name with the local private key path. Check public key fingerprints or real SSH authentication only; never read, copy or print private key contents.

Check the native CLI, the credential identity and the target region first. If the CLI is missing, give the official install link and stop the dependent steps; do not install it silently:

- AWS Lightsail (default): `command -v aws`, then read [the Lightsail flow](references/aws-lightsail.md).
- AWS EC2: `command -v aws`, then read [the EC2 flow](references/aws-ec2.md).
- Alibaba Cloud: `command -v aliyun`, then read [the Alibaba Cloud flow](references/aliyun-ecs.md).

Keep this run's parameters, native request JSON, create responses and acceptance logs in a subdirectory of the git-ignored `local/` (directory 700, files 600). Never write host addresses, accounts, resource IDs or key paths back into this skill or its templates. Replace every placeholder in a template with a queried value before use.

## Create and connect

Follow the provider flow. Use distinct, recognizable resource names/tags and record the IDs of the instance and its attached resources. Fix one ClientToken per create request; on a timeout, query by token/tag first and never retry blindly with a new token. Clean up only resources recorded in this run, and only as authorized.

Direct RDP needs a new security group (Lightsail: the instance firewall) limited to the source CIDR; a tunnel opens SSH only; private network/VPN uses the real internal route. The host installer does not manage security groups. Do not modify the original machine or shared security groups to test a new one.

Give every desktop that will be kept a static address: a Lightsail static IP (free while attached) or an EC2 Elastic IP (billed like any public IPv4, so no extra cost). Short POCs that will be deleted may use the automatic public address.

Take the address from the cloud API and wait for SSH. Verify the host key against the fingerprint from the cloud API (console output, or Lightsail's instance access details), then write a dedicated known_hosts with strict checking. When the connection fails, separate boot, route/allowlist, host key and user key problems.

## Deploy

1. Wait for cloud-init to finish so it does not race with apt.
2. Install AgentDesk on the new host, passing this run's options (`--user`, `--rdp-mode`, `--rdp-port`, `--locale`, `--theme`):
   - Published code: `curl -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh | sudo bash -s -- --user "$DESKTOP_USER"`. Add `--ref BRANCH_OR_TAG` to test something other than the latest release. Without `--user`, use the saved desktop account or default to `agentdesk`. If the host cannot reach GitHub directly, pass the proxy to both curl (`-x URL`) and the installer (`--proxy URL`): HTTP(S) only, not saved, and never record a proxy password in the run logs.
   - Unpublished local changes: in the repository root, pack only the program, `tar -czf agentdesk.tar.gz agentdesk.sh install.sh mise.toml resources`, upload and extract it into a fresh temporary directory on the host, then run `sudo bash install.sh --user "$DESKTOP_USER"`. Never pack the whole working tree, `local/`, personal mise config, `.env` or SSH directories.
3. `init` installs the program to `/usr/local/lib/agentdesk`, the AgentDesk-maintained software list to `/etc/mise/config.toml`, the desktop defaults to `/etc/xdg/agentdesk`, and saves the options to `/etc/agentdesk/agentdesk.yaml`. Tool locks are generated on the host. It writes nothing into users' home directories.
4. Log in again as the desktop user. Check that `agentdesk install NAME` and native `mise use -g` both write `~/.config/mise/config.toml`, and that `agentdesk install --system NAME` writes `/etc/mise/config.local.toml` without touching `/etc/mise/config.toml`. Never run personal tasks as root. Old POC hosts are not migrated; clean up old deployment files only when this run explicitly includes a reinstall.
5. Installation enables SSH password authentication for the desktop user; SSH and RDP share that account and password. Set a missing password with an interactive `sudo passwd "$DESKTOP_USER"`; installation never resets an existing password. If automated GUI tests really need a temporary password, get explicit approval to generate and store it first, then pass it through a restricted local file and stdin; never put it in arguments, cloud user-data, logs or delivered documents. Verify SSH password login as the desktop user and confirm the original administrator's key login still works.

## Refresh the source allowlist

When the user's outbound IP changes (SSH or RDP times out from their side while the instance is running), update only the rules this skill created:

1. Get the current outbound IPv4 with `curl -fsS https://checkip.amazonaws.com` and show it to the user before changing anything; if they connect through several exits (office, VPN, proxy), ask for each `/32` or their published CIDR. Never open SSH or RDP to `0.0.0.0/0`.
2. Save the current rules to this run's `local/` directory, then change them:
   - Lightsail: `put-instance-public-ports` with the full new list; it replaces all rules in one call.
   - EC2: `authorize-security-group-ingress` for the new CIDR first, then `revoke-security-group-ingress` by the old rule IDs from `describe-security-group-rules --filters Name=group-id,Values=$GROUP_ID`, so access is never cut off in between.
   - Alibaba Cloud: `AuthorizeSecurityGroup` for the new CIDR, then `RevokeSecurityGroup` for the old one.
3. Query the rules again, test SSH, and save the result. Touch only the dedicated security group or instance firewall recorded for this run.

## Verify and deliver

Run `agentdesk verify`: it reads the user from `/etc/agentdesk/agentdesk.yaml` and the listener from `xrdp.ini`, and prints `[PASS]/[FAIL]` to stdout. Check the versions of every tool in `mise.toml` and every preinstalled desktop app. Use `agentdesk upgrade --system --dry-run` to review the upgrade flow; run real upgrades only within this run's scope. Re-run `agentdesk init` without options and confirm the saved settings and user configuration are kept. Reboot the new POC and check services, SSH and RDP again. Never reboot the original machine.

After a real RDP login, check XFCE, the theme, Chinese fonts and input, app launch, the terminal PATH, reconnecting after a disconnect, and logging in again after a reboot. An active service, a reachable port or an installed package does not replace GUI acceptance; without a client or a human tester, record the item as "pending".

Run `agentdesk info` on the host for the connection steps; it reads the public address from AWS and Alibaba Cloud instance metadata. If unavailable, query the address from the cloud API. Give the user the macOS `open 'rdp://…'` command or Windows `mstsc /v:HOST:PORT` command. Report the platform (Lightsail or EC2), the instance ID or name, region, size and its monthly price, OS, static IP, SSH command, RDP address and user name, access mode, password setup steps, passed/failed/pending items, and whether the resources are kept. An SSH config snippet may be attached; never overwrite the user's local config. Private keys and passwords never appear in the output.
