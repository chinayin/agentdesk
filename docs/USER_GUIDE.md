# AgentDesk 使用指南

> 契约：只写现状，必须与代码一致。

## 概述

README 之外的使用细节，包括系统选择、安装参数、远程连接、输入与剪贴板、桌面维护、软件管理、更新和退出码。设计原理见 [ARCHITECTURE](ARCHITECTURE.md)。

## 1. 系统与安装参数

### 选择系统

XFCE 和 xrdp 使用系统官方源中的版本，AgentDesk 不单独升级它们；想要更新的桌面和远程协议，就选更新的系统。下表是 2026-10 官方源中的版本：

| 系统 | XFCE | xrdp | 建议 |
|---|---|---|---|
| Ubuntu 26.04 LTS | 4.20 | 0.10.1 | **推荐** |
| Debian 13 | 4.20 | 0.10.1 | **推荐** |
| Ubuntu 24.04 LTS | 4.18 | 0.9.24 | 可用 |
| Debian 12 | 4.18 | 0.9.21 | 可用 |
| Ubuntu 22.04 LTS | 4.16 | 0.9.17 | 能用，不推荐 |

- 两种架构都支持：amd64 和 arm64（如 AWS Graviton）。
- Ubuntu 22.04 的桌面较旧，官方渠道（含 backports）无法升级；xrdp 有一部分安全补丁只通过 Ubuntu Pro 提供。仍要用它时，建议 `--rdp-mode tunnel`，不对外开放 RDP 端口。
- 不建议用第三方 PPA 升级 XFCE 或 xrdp：来源不可信，后续安全更新没有保证。
- 其他 Debian 系（更新的版本或衍生版）会警告后继续安装；更早的版本和非 Debian 系会被拒绝。

### 安装参数

```bash
curl -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh | sudo bash -s -- [--ref REF] [INIT 参数]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--ref REF` | 最新发布标签 | 远程安装时下载的分支或标签，例如 `--ref main`；只对 install.sh 和 `agentdesk update` 生效 |
| `--user NAME` | 执行命令的用户 | sudo 运行时取 `SUDO_USER`，普通用户取自己，直接以 root 运行时为 `desk`；不能是 root，UID 须 ≥ 1000；不存在时创建并加入 sudo 组 |
| `--theme whitesur\|none` | `whitesur` | `none` 使用 Greybird/Adwaita |
| `--rdp-mode direct\|tunnel` | `direct` | `tunnel` 只监听 127.0.0.1 |
| `--rdp-port PORT` | `3389` | |
| `--locale en_US.UTF-8\|zh_CN.UTF-8` | `en_US.UTF-8` | 两种都安装中文字体和拼音输入法；不修改系统语言和时区 |
| `--proxy URL` | | 本次运行使用的 HTTP(S) 代理，见下文；不保存 |
| `--dry-run` | | 只打印操作，不写入、不下载、不提权 |

init 会把这些参数保存到 `/etc/agentdesk/agentdesk.yaml`，之后的 `init`、`verify`、`desktop-reset`、`update` 都以它为默认值，所以重跑时不必再传。优先级为：命令行 > 设置文件 > 默认值；不使用额外的环境变量。

```yaml
# /etc/agentdesk/agentdesk.yaml
user: ubuntu
theme: whitesur
locale: en_US.UTF-8
rdp:
  mode: tunnel
  port: 3389
```

### 代理

所有会下载的命令（install.sh、`init`、`update`、`install`、`upgrade`）都接受 `--proxy http://[用户:密码@]主机:端口`：

```bash
curl -x http://127.0.0.1:7890 -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh \
  | sudo bash -s -- --proxy http://127.0.0.1:7890
agentdesk upgrade --system --proxy http://127.0.0.1:7890
```

- 只对本次运行生效：设置 `http_proxy`、`https_proxy`、`all_proxy`，本机地址直连；透传给 sudo、桌面用户、mise、apt（含 Chrome 等厂商源）和 git。不保存到设置文件，也不写入 `/etc/environment` 或 apt 配置，桌面应用自己的上网方式不受影响。
- `curl … | sudo bash` 时必须用参数：sudo 会清空调用者 export 的代理变量。其他 agentdesk 命令也可以先在自己的 shell 里 `export https_proxy=...`，AgentDesk 调用 sudo 时会自己透传。
- 只支持 HTTP(S) 代理（apt 不支持 SOCKS）。`run` 任务名之后的 `--proxy` 属于任务自己的参数。

## 2. 密码与登录

- 默认把执行安装的用户作为桌面账户，SSH 和 RDP 共用同一个家目录。云镜像的默认用户（如 `ubuntu`、`admin`）通常配置了免密 sudo，给它设置密码后，RDP 密码泄露就等于 root 权限泄露：直连模式务必在安全组中限制来源 IP，或改用 `--rdp-mode tunnel`。想与登录用户分开时，以 `--user NAME` 指定一个新账户，新账户的 sudo 需要输入密码。
- 安装器只在交互终端、且账户还没有密码时提示设置；非交互运行时，安装完成后执行 `sudo passwd USER`。不会自动生成密码，也不修改 SSH 认证。
- 安装完成后重新登录 SSH 或 RDP。当前终端如需立即生效：`. /etc/profile.d/agentdesk.sh`。

## 3. 远程连接

- **直连**：RDP 连接 `服务器:端口`，会话选 Xorg，使用桌面账户和密码登录。先在安全组或防火墙中只放行你的 IP/CIDR；已有内网或 VPN 时同样直连。
- **SSH 隧道**：`ssh -N -L 13389:127.0.0.1:3389 SSH_USER@SERVER`，RDP 连接 `127.0.0.1:13389`。SSH 用户可以是云镜像自带的用户。
- 修改 RDP 配置不会断开现有会话。退出桌面后，在维护窗口执行 `sudo systemctl restart xrdp`。

## 4. 输入与剪贴板

- XFCE 终端复制/粘贴用 `Ctrl+Shift+C` / `Ctrl+Shift+V`，`Ctrl+C` 用于中断命令。组合键不生效时，先试远程应用的右键菜单，区分是键盘映射问题还是剪贴板通道问题。
- macOS 的 Microsoft Remote Desktop 可以在 `Connections → Keyboard Mode` 切换 Scancode 或 Unicode。符号输入丢失 Shift 时，改用 Unicode。模式说明见 [Microsoft 文档](https://learn.microsoft.com/en-us/windows-app/input-keyboard-mouse-touch-pen?tabs=macos)。
- 中文用 Fcitx5 拼音，可从顶栏输入法菜单切换 `Keyboard - English (US)` 和 `Pinyin`。

## 5. 检查与桌面维护

这些命令默认使用 `/etc/agentdesk/agentdesk.yaml` 中保存的用户和参数。

```bash
agentdesk verify                                # 检查结果 [PASS]/[FAIL] 输出到 stdout
agentdesk init --theme none                     # 重新执行；换主题或语言也用它，个人设置保留
agentdesk desktop-reset --force                 # 先退出该用户的全部图形会话
```

- 桌面的主题、面板、背景、输入法都是系统默认值，全机用户共用；用户自己在 XFCE 设置里改过的项目优先，重新执行 init 不会覆盖。
- 主题和桌面语言是全机设置：用新的 `--theme` 或 `--locale` 重新执行 init，在下次登录时生效；已经自己改过外观的用户，保留自己的设置。
- 想放弃个人修改、回到默认外观：`desktop-reset --force`。它直接删除面板、外观、窗口管理器、背景、终端这几项个人设置（不做备份），其他个人设置保留；不加 `--force` 会拒绝执行。XFCE 配置由 dotfiles 以符号链接管理时也会拒绝，避免改到 dotfiles 本身。
- 默认背景是 XFCE 自带的深蓝渐变，已为 RDP 的前四个显示器预置；不满意可以在 Desktop Settings 中修改。
- XFCE 终端默认以登录 shell 启动，会加载 mise 的工具路径、`mise activate` 和 direnv hook；项目目录里的 `mise.toml` 按 mise 原生规则切换版本。

## 6. 软件管理

```bash
agentdesk install gemini kubectl apt:htop      # 记录到个人清单并安装
agentdesk install                              # 按个人清单补齐
agentdesk upgrade                              # 在版本范围内升级个人软件
agentdesk install --system kubectl apt:tree    # 管理员：写入 /etc/mise/config.local.toml 并安装
agentdesk install --system                     # 管理员：按系统清单补齐
agentdesk upgrade --system                     # 管理员：升级全机共享的工具和应用
```

| 文件 | 谁改 | 说明 |
|---|---|---|
| `/etc/mise/config.toml` | AgentDesk | 通用软件清单，随 AgentDesk 版本发布，`agentdesk update` 和重跑 init 时直接覆盖；**不要手改**，手改的内容会丢失 |
| `/etc/mise/config.local.toml` | 本机管理员 | 本机增补，或用同名条目覆盖通用清单的版本（如 `node = "22"`）；AgentDesk 不会改动 |
| `~/.config/mise/config.toml` | 每个用户 | 个人软件；AgentDesk 不会改动 |

- 三份清单由 mise 原生合并，`install` 自动补装差异；local 文件优先于通用清单，个人清单再叠加在上面。
- 个人清单是 `~/.config/mise/config.toml`，与原生 `mise use -g` 写的是同一个文件；你自己设置的 `XDG_CONFIG_HOME`、`MISE_CONFIG_DIR`、`MISE_GLOBAL_CONFIG_FILE` 按 mise 原生规则生效。示例见 [mise.example.toml](../mise.example.toml)，完整语法见 [mise configuration](https://mise.jdx.dev/configuration.html)。
- `apt:` 写在个人清单里只是记录需求，软件仍装在全机；需要 sudo 的步骤由 mise 提权。
- `upgrade` 不接受软件名。要单独升级某个工具，用原生命令（例如 `mise lock --bump NAME` 再 `mise install --locked`）。`node = "26"` 保持在 26.x，`latest` 可能跨大版本。
- 需要额外部署步骤的软件，在个人清单里写 `[tasks]`，用 `agentdesk run TASK` 执行；任务的幂等和恢复由任务作者负责。
- 项目自己的 `mise.toml` 保持原生优先级；agentdesk 的软件命令固定在 `/` 下执行，不会读到当前项目的配置。

## 7. 默认软件说明

- 预装清单以 [mise.toml](../mise.toml) 为准，按用途分组：语言运行时、AI 编程 CLI、代码托管 CLI、云厂商 CLI、通用工具；tmux 与桌面应用经 apt 安装。
- 需要账号的工具由每位用户登录或配置自己的凭据：Claude Code、Codex、pi，`gh auth login`、`glab auth login`、`aws configure`、`aliyun configure`、`cloudflared tunnel login`。AgentDesk 不保存任何凭据。
- direnv 已为全机的交互式 bash 启用：项目目录里的 `.envrc` 首次需要 `direnv allow` 才会加载。
- AI 工具只预装命令行版本，Claude Desktop、ChatGPT 等桌面客户端不预装。ChatGPT Linux preview 需要时按[官方说明](https://learn.chatgpt.com/docs/linux/linux-app)安装（Debian 12 不在其官方支持范围内）：

```bash
curl -fLO https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb
sudo apt install ./chatgpt_amd64.deb
```

## 8. 更新 AgentDesk 本身

命令参照 Homebrew：`update` 更新 AgentDesk 自己，`upgrade` 升级软件。

```bash
agentdesk --version              # 当前版本
agentdesk update                 # 更新到最新发布版本（相当于 brew update）
agentdesk update --ref main      # 跟随开发分支，或 --ref v0.3.0 指定版本
agentdesk update --dry-run       # 只打印计划
agentdesk upgrade --system       # 之后按需升级软件（相当于 brew upgrade）
```

- update 下载新版本后，按 `/etc/agentdesk/agentdesk.yaml` 重跑新版本的 init：替换程序、通用软件清单和桌面默认值，补装新版本新增的软件；不升级已装软件，不改动 `config.local.toml`、个人清单、密码和用户自己的桌面设置。
- 已是最新版本时只提示，不重装；显式指定 `--ref` 时总是重装。
- 没有设置文件（0.2.0 之前安装的主机）时，update 会拒绝执行。先带上原来的参数重新执行一次安装命令，生成设置文件。

## 9. 退出码

`agentdesk` 和 `install.sh` 的退出码含义固定，供脚本和 agent 判断：

| 退出码 | 含义 |
|---|---|
| 0 | 成功；不带参数或 `--help` 显示帮助也是 0 |
| 1 | 用法错误或执行失败；`verify` 有检查未通过时也是 1 |
| 2 | 缺少前置条件，如系统或架构不支持、没有 mise、`update` 找不到设置文件 |

底层命令（apt、mise 等）失败时，可能直接返回它们自己的退出码。
