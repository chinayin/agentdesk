# AgentDesk

[English](README.md) | 简体中文

一条命令，把一台全新的 Ubuntu/Debian 云服务器变成可直接用于 AI 编程的远程桌面。

## 功能

- **远程桌面**：XFCE + xrdp，任意 RDP 客户端直连，或经 SSH 隧道连接。
- **中文可用**：中文字体与 Fcitx5 拼音输入法，桌面语言可选英文或中文。
- **AI 编程命令行**：Claude Code、Codex、pi，在任何终端里直接可用。
- **开发工具**：Node 26、Python 3.14、Go、pnpm、uv、ripgrep、fd、jq、shellcheck、direnv、tmux 等，由 [mise](https://mise.jdx.dev/) 管理。
- **云与代码托管 CLI**：AWS CLI、阿里云 CLI、cloudflared、GitHub CLI（`gh`）、GitLab CLI（`glab`）。
- **桌面应用**：Google Chrome、VS Code，来自各自的官方 APT 源。
- **自己加软件**：`agentdesk install kubectl` / `apt:htop`，记录在个人 mise 配置中，一条命令升级。
- **可重复执行**：保留密码、桌面布局、输入法和软件清单；只有明确要求时才重置。

## 环境要求

Ubuntu 22.04 / 24.04 / 26.04 或 Debian 12 / 13，amd64 或 arm64，systemd，以 root 或有 sudo 权限的用户运行。

新机器推荐 **Ubuntu 26.04 或 Debian 13**（XFCE 4.20、xrdp 0.10）。Ubuntu 22.04 能用，但自带的是 XFCE 4.16 和 xrdp 0.9.17，建议用 SSH 隧道连接。详见[选择系统](docs/USER_GUIDE.md)。

## 安装

在服务器上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh | sudo bash
```

安装最新发布版本，桌面账户就是执行命令的用户（直接以 root 运行时新建 `desk`）。安装过程没有提示设置密码时，执行 `sudo passwd $USER`。

参数写在 `bash -s --` 之后：

```bash
curl -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh | sudo bash -s -- --rdp-mode tunnel --locale zh_CN.UTF-8
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--user NAME` | 执行命令的用户 | 桌面账户，不存在时创建 |
| `--rdp-mode tunnel` | `direct` | 只监听 127.0.0.1，经 SSH 隧道连接 |
| `--locale zh_CN.UTF-8` | `en_US.UTF-8` | 桌面语言 |
| `--proxy URL` | | 本次运行使用的 HTTP(S) 代理，见下文 |

参数会被保存，重跑安装命令或 `agentdesk update` 时沿用。全部参数见[使用指南](docs/USER_GUIDE.md)。

服务器需要代理才能访问 GitHub 时，`curl` 和安装器两处都要带上（`sudo` 会清空已 export 的代理变量）：

```bash
PROXY=http://127.0.0.1:7890
curl -x "$PROXY" -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh | sudo bash -s -- --proxy "$PROXY"
```

## 连接

- **直连（默认）**：RDP 连接 `服务器:3389`，会话选 `Xorg`。先在安全组或防火墙中只放行你的 IP：云镜像的默认用户通常可以免密 sudo。
- **SSH 隧道**（安装时加 `--rdp-mode tunnel`）：`ssh -N -L 13389:127.0.0.1:3389 用户@服务器`，再用 RDP 连接 `127.0.0.1:13389`。

## 使用

```bash
agentdesk --version                  # 查看已安装的版本
agentdesk verify                     # 检查软件包、服务和 RDP 监听
agentdesk install gemini kubectl     # 添加个人工具（Gemini CLI、Kubernetes CLI）
agentdesk install apt:htop           # 添加 apt 系统软件包
agentdesk upgrade                    # 升级个人软件
agentdesk upgrade --system           # 升级全机共享的工具和应用（管理员）
agentdesk run TASK                   # 运行个人 mise 配置中的任务
agentdesk desktop-reset --force      # 把桌面恢复为默认设置
agentdesk update                     # 把 AgentDesk 自己更新到最新发布版本
agentdesk --help
```

`update` 和 `upgrade` 参照 Homebrew：`update` 更新 AgentDesk 自己和它维护的配置，`upgrade` 升级已安装的软件。

软件清单都是原生 mise 配置，由 mise 自己合并：

| 文件 | 谁维护 |
|---|---|
| `/etc/mise/config.toml` | AgentDesk，`agentdesk update` 时覆盖 |
| `/etc/mise/config.local.toml` | 本机管理员（`agentdesk install --system NAME`） |
| `~/.config/mise/config.toml` | 每个用户（`agentdesk install NAME`） |

参考 [mise.example.toml](mise.example.toml) 和 [mise 配置文档](https://mise.jdx.dev/configuration.html)。

## 文档

| 文档 | 内容 |
|---|---|
| [USER_GUIDE](docs/USER_GUIDE.md) | 安装参数、连接、输入法、桌面与软件管理 |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | 设计、文件布局、软件作用域、权限 |
| [TESTING_GUIDE](docs/TESTING_GUIDE.md) | 离线测试、Docker E2E、真机验收 |
| [ROADMAP](docs/ROADMAP.md) | 未完成事项及验收标准 |
| [agentdesk-create skill](skills/agentdesk-create/SKILL.md) | 在 AWS / 阿里云创建并验收云桌面 |

## 开发

```bash
sudo bash install.sh  # 在源码目录内安装
bash test.sh          # 离线测试，约 10 秒
bash tests/e2e.sh     # 在 Docker 中做安装测试（默认 Ubuntu 26.04、本机架构）
```

## 许可

[Apache License 2.0](LICENSE)。AgentDesk 安装的第三方软件（XFCE、xrdp、Chrome、VS Code、mise、Claude Code 等）各自遵循其自身许可。
