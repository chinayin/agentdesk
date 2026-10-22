# AgentDesk

English | [简体中文](README_CN.md)

Turn a fresh Ubuntu/Debian cloud server into a ready-to-use remote desktop for AI coding, with one command.

## Features

- **Remote desktop**: XFCE + xrdp, connect with any RDP client, directly or through an SSH tunnel.
- **Chinese ready**: CJK fonts and Fcitx5 Pinyin input, English or Chinese desktop locale.
- **AI coding CLIs**: Claude Code, Codex and pi, ready in every terminal.
- **Dev tools**: Node 26, Python 3.14, Go, pnpm, uv, ripgrep, fd, jq, shellcheck, direnv, tmux and more, managed by [mise](https://mise.jdx.dev/).
- **Cloud and Git CLIs**: AWS CLI, Aliyun CLI, cloudflared, GitHub CLI (`gh`) and GitLab CLI (`glab`).
- **Desktop apps**: Google Chrome and VS Code from their official APT repositories.
- **Your own software**: `agentdesk install kubectl` / `apt:htop`, recorded in your personal mise config and upgraded with one command.
- **Safe to re-run**: keeps passwords, desktop layout, input settings and software lists; reset only when you ask.

## Requirements

Ubuntu 22.04 / 24.04 / 26.04 or Debian 12 / 13, amd64 or arm64, systemd, root or a sudo user.

For new servers use **Ubuntu 26.04 or Debian 13** (XFCE 4.20, xrdp 0.10). Ubuntu 22.04 works but ships XFCE 4.16 and xrdp 0.9.17; use the SSH tunnel there. See [choosing a system](docs/USER_GUIDE.md).

## Install

Run on the server:

```bash
curl -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh | sudo bash
```

This installs the latest release for the user running the command (`desk` when run as plain root). If the installer did not ask for a desktop password, set one with `sudo passwd $USER`.

Options go after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh | sudo bash -s -- --rdp-mode tunnel --locale zh_CN.UTF-8
```

| Option | Default | Description |
|---|---|---|
| `--user NAME` | the user running the command | Desktop account; created if missing |
| `--rdp-mode tunnel` | `direct` | Listen on 127.0.0.1 only, reach it through an SSH tunnel |
| `--locale zh_CN.UTF-8` | `en_US.UTF-8` | Desktop language |
| `--proxy URL` | | HTTP(S) proxy for this run only, see below |

Options are saved and reused when you re-run the installer or `agentdesk update`. All options are in the [User Guide](docs/USER_GUIDE.md).

If the server needs a proxy to reach GitHub, give it to both `curl` and the installer (`sudo` drops exported proxy variables):

```bash
PROXY=http://127.0.0.1:7890
curl -x "$PROXY" -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh | sudo bash -s -- --proxy "$PROXY"
```

## Connect

- **Direct (default)**: RDP to `SERVER:3389`, session `Xorg`. Allow only your IP in the security group or firewall first: cloud default users usually have passwordless sudo.
- **SSH tunnel** (installed with `--rdp-mode tunnel`): `ssh -N -L 13389:127.0.0.1:3389 USER@SERVER`, then RDP to `127.0.0.1:13389`.

## Usage

```bash
agentdesk --version                  # show the installed version
agentdesk verify                     # check packages, services and the RDP listener
agentdesk install gemini kubectl     # add personal tools (Gemini CLI, Kubernetes CLI)
agentdesk install apt:htop           # add a system package from apt
agentdesk upgrade                    # upgrade your personal software
agentdesk upgrade --system           # upgrade shared tools and apps (admin)
agentdesk run TASK                   # run a task from your personal mise config
agentdesk desktop-reset --force      # reset your desktop to the defaults
agentdesk update                     # update AgentDesk itself to the latest release
agentdesk --help
```

`update` and `upgrade` follow Homebrew: `update` refreshes AgentDesk and the config it maintains, `upgrade` upgrades installed software.

Software lists are plain mise config, merged natively by mise:

| File | Maintained by |
|---|---|
| `/etc/mise/config.toml` | AgentDesk, replaced on `agentdesk update` |
| `/etc/mise/config.local.toml` | the host admin (`agentdesk install --system NAME`) |
| `~/.config/mise/config.toml` | each user (`agentdesk install NAME`) |

See [mise.example.toml](mise.example.toml) and the [mise configuration docs](https://mise.jdx.dev/configuration.html).

## Documentation

Documents are written in Chinese.

| Document | Content |
|---|---|
| [USER_GUIDE](docs/USER_GUIDE.md) | Install options, connecting, input, desktop and software management |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | Design, file layout, software scopes, permissions |
| [TESTING_GUIDE](docs/TESTING_GUIDE.md) | Offline tests, Docker E2E, real-machine checks |
| [ROADMAP](docs/ROADMAP.md) | Open items with acceptance criteria |
| [agentdesk-create skill](skills/agentdesk-create/SKILL.md) | Create and verify a cloud desktop on AWS / Alibaba Cloud |

## Development

```bash
sudo bash install.sh  # install from a source checkout
bash test.sh          # offline tests, about 10 seconds
bash tests/e2e.sh     # Docker install test (default: Ubuntu 26.04, native architecture)
```

## License

[Apache License 2.0](LICENSE). Third-party software installed by AgentDesk (XFCE, xrdp, Chrome, VS Code, mise, Claude Code and others) keeps its own license.
