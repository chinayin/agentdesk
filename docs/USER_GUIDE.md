# AgentDesk 使用指南

> 契约：只写现状，必须与代码一致。

## 概述

README 之外的使用细节：安装、连接、桌面维护、软件管理、更新和退出码。设计原理见 [ARCHITECTURE](ARCHITECTURE.md)。

## 1. 安装

### 选择系统

XFCE 和 xrdp 用系统官方源的版本，AgentDesk 不单独升级它们；要更新的桌面和远程协议，就选更新的系统。2026-10 官方源中的版本：

| 系统 | XFCE | xrdp | 建议 |
|---|---|---|---|
| Ubuntu 26.04 LTS | 4.20 | 0.10.1 | **推荐** |
| Debian 13 | 4.20 | 0.10.1 | **推荐** |
| Ubuntu 24.04 LTS | 4.18 | 0.9.24 | 可用 |
| Debian 12 | 4.18 | 0.9.21 | 可用 |
| Ubuntu 22.04 LTS | 4.16 | 0.9.17 | 能用，不推荐 |

- amd64 和 arm64（如 AWS Graviton）都支持。
- Ubuntu 22.04 的桌面较旧，官方渠道无法升级，xrdp 的部分安全补丁只在 Ubuntu Pro 中提供；仍要用时建议 `--rdp-mode tunnel`。不建议用第三方 PPA 升级 XFCE 或 xrdp。
- 其他 Debian 系会警告后继续安装；更早的版本和非 Debian 系会被拒绝。

### 参数

```bash
curl -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh | sudo bash -s -- [--ref REF] [INIT 参数]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--ref REF` | 最新发布标签 | 下载的分支或标签，如 `--ref main`；只对 install.sh 和 `agentdesk update` 生效 |
| `--user NAME` | `agentdesk` | 不能是 root，UID ≥ 1000；不存在时创建并加入 sudo 组 |
| `--theme whitesur\|none` | `whitesur` | `none` 用 Greybird/Adwaita |
| `--rdp-mode direct\|tunnel` | `direct` | `tunnel` 只监听 127.0.0.1 |
| `--rdp-port PORT` | `3389` | |
| `--locale en_US.UTF-8\|zh_CN.UTF-8` | `en_US.UTF-8` | 桌面语言；两种都装中文字体和拼音输入法 |
| `--proxy URL` | | 本次运行的 HTTP(S) 代理，不保存 |
| `--dry-run` | | 只打印操作，不写入、不下载、不提权 |

init 把参数保存到 `/etc/agentdesk/agentdesk.yaml`，之后的命令都以它为默认值，重跑时不必再传。优先级：命令行 > 设置文件 > 默认值。

```yaml
user: agentdesk
theme: whitesur
locale: en_US.UTF-8
rdp:
  mode: tunnel
  port: 3389
```

### 代理

会下载的命令（install.sh、`init`、`update`、`install`、`upgrade`）都接受 `--proxy http://[用户:密码@]主机:端口`：

```bash
curl -x http://127.0.0.1:7890 -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh \
  | sudo bash -s -- --proxy http://127.0.0.1:7890
agentdesk upgrade --system --proxy http://127.0.0.1:7890
```

- 只对本次运行生效，透传给 sudo、桌面用户、mise、apt（含厂商源）和 git；不写设置文件、`/etc/environment` 或 apt 配置。
- `curl … | sudo bash` 必须用参数，因为 sudo 会清空已 export 的代理变量；其他命令也可以先 `export https_proxy=...`。
- 只支持 HTTP(S)（apt 不支持 SOCKS）。`run` 任务名之后的 `--proxy` 属于任务自己。

## 2. 密码与登录

- 桌面账户默认 `agentdesk`，可用 `--user NAME` 指定；SSH 仍使用原账户。
- 安装器保留已有密码；没有密码时，安装后手动执行 `sudo passwd USER`。不修改 SSH 认证。
- 装完重新登录 SSH 或 RDP；当前终端要立即生效可执行 `. /etc/profile.d/agentdesk.sh`。

## 3. 连接

- `agentdesk info` 打印账户、地址和当前模式的连接命令；init 结束时也会打印，普通用户可运行。
- 公网地址从 AWS、阿里云实例元数据读取；读取失败时提示手动查找地址，不输出带占位符的命令。
- macOS 执行 `info` 给出的 `open 'rdp://…'` 命令；Windows 用 `mstsc /v:地址`。`agentdesk rdp` 只输出链接，也可在 Mac 上运行 `open "$(ssh 用户@服务器 agentdesk rdp)"`。隧道模式使用 `127.0.0.1:13389`；直连且取不到公网地址时报错退出。
- **直连**：RDP 连 `服务器:端口`，会话选 Xorg；先在安全组或防火墙中只放行你的 IP。
- **SSH 隧道**：`ssh -N -L 13389:127.0.0.1:3389 SSH_USER@SERVER`，RDP 连 `127.0.0.1:13389`。
- 修改 RDP 配置不会断开现有会话；退出桌面后执行 `sudo systemctl restart xrdp` 生效。
- **输入**：XFCE 终端复制粘贴用 `Ctrl+Shift+C/V`。Mac 上的 Windows App 可以把键盘模式切换为 Scancode 或 Unicode，符号输入丢失 Shift 时改用 Unicode（见 [Microsoft 文档](https://learn.microsoft.com/en-us/windows-app/input-keyboard-mouse-touch-pen?tabs=macos)）。中文用 Fcitx5 拼音，从顶栏输入法菜单切换。

## 4. 桌面维护

命令默认使用 `agentdesk.yaml` 中保存的用户和参数。

```bash
agentdesk verify                   # [PASS]/[FAIL] 输出到 stdout
agentdesk init --theme none        # 重新执行；换主题或语言也用它，个人设置保留
agentdesk desktop-reset --force    # 先退出该用户的全部图形会话
```

- 主题、面板、背景、输入法都是全机默认值；用户在 XFCE 设置里改过的项目优先，重跑 init 不覆盖。换 `--theme` 或 `--locale` 后在下次登录生效。
- `desktop-reset --force` 删除面板、外观、窗口管理器、背景、终端这几项个人设置（不备份），其他设置保留；XFCE 配置由 dotfiles 软链管理时拒绝执行。
- 时区：AgentDesk 不修改系统时区，云镜像默认是 UTC。需要本地时间时执行 `sudo timedatectl set-timezone Asia/Shanghai`，重新登录后生效。
- XFCE 终端以登录 shell 启动，会加载 mise 工具路径、`mise activate` 和 direnv hook；`ssh 主机 命令` 这类非登录 shell 不加载，需要时写成 `bash -lc '命令'`。

## 5. 软件管理

```bash
agentdesk install gemini kubectl apt:htop     # 记录到个人清单并安装
agentdesk install                             # 按个人清单补齐
agentdesk upgrade                             # 在版本范围内升级个人软件
agentdesk install --system kubectl apt:tree   # 管理员：写入 /etc/mise/config.local.toml 并安装
agentdesk upgrade --system                    # 管理员：升级全机共享的工具和应用
```

| 文件 | 谁改 | 说明 |
|---|---|---|
| `/etc/mise/config.toml` | AgentDesk | 通用清单，`update` 和重跑 init 时直接覆盖，**不要手改** |
| `/etc/mise/config.local.toml` | 本机管理员 | 增补，或用同名条目覆盖通用清单的版本（如 `node = "22"`） |
| `~/.config/mise/config.toml` | 每个用户 | 个人软件，与 `mise use -g` 同一文件 |

- 三份清单由 mise 原生合并；示例见 [mise.example.toml](../mise.example.toml)，语法见 [mise configuration](https://mise.jdx.dev/configuration.html)。
- `apt:` 写在个人清单里只是记录需求，软件仍装在全机，需要 sudo 的步骤由 mise 提权。
- `upgrade` 不接受软件名；单独升级用原生命令（`mise lock --bump NAME` 再 `mise install --locked`）。`node = "26"` 保持在 26.x，`latest` 可能跨大版本。
- 需要额外部署步骤的软件，在个人清单里写 `[tasks]`，用 `agentdesk run TASK` 执行。
- 软件命令固定在 `/` 下执行，不读当前项目的 `mise.toml`；项目里的版本按 mise 原生规则切换。
- 已知限制：mise 2026.10.17 在个人清单覆盖全机预装工具的版本时（如个人写 `node = "22"`），会去改共享目录的链接并报 `runtime symlink repair(s) failed`。需要别的版本时写在项目的 `mise.toml` 里，或由管理员写进 `config.local.toml`。

## 6. 预装软件

- 清单以 [mise.toml](../mise.toml) 为准：语言运行时、AI 编程 CLI、代码托管 CLI、云厂商 CLI、通用工具；tmux 与桌面应用经 apt 安装。
- 需要账号的工具由每位用户自己登录：Claude Code、Codex、pi，`gh auth login`、`glab auth login`、`aws configure`、`aliyun configure`、`cloudflared tunnel login`。AgentDesk 不保存凭据。
- direnv 已为交互式 bash 启用，项目里的 `.envrc` 首次需要 `direnv allow`。
- 只预装 AI 工具的命令行版本；ChatGPT 等桌面客户端需要时按[官方说明](https://learn.chatgpt.com/docs/linux/linux-app)自行安装。

## 7. 更新 AgentDesk

```bash
agentdesk --version            # 当前版本
agentdesk update               # 更新到最新发布版本（相当于 brew update）
agentdesk update --ref main    # 跟随开发分支，或 --ref vX.Y.Z 指定版本
agentdesk update --dry-run     # 只打印计划
```

- update 按 `agentdesk.yaml` 重跑新版本的 init：替换程序、通用清单和桌面默认值，补装新增软件；不升级已装软件（那是 `upgrade`），不改 `config.local.toml`、个人清单、密码和个人桌面设置。
- 已是最新时只提示；显式 `--ref` 时总是重装。没有设置文件时拒绝执行，先带原参数重跑一次安装命令。

## 8. 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 成功；不带参数或 `--help` 显示帮助也是 0 |
| 1 | 用法错误或执行失败；`verify` 有检查未通过也是 1 |
| 2 | 缺少前置条件，如系统或架构不支持、没有 mise、未初始化 |

底层命令（apt、mise 等）失败时，可能直接返回它们自己的退出码。
