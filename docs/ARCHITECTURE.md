# AgentDesk 架构设计

> 契约：只写现状，必须与代码一致；改代码时同步修改。未完成事项见 [ROADMAP](ROADMAP.md)。

## 概述

AgentDesk 是一个 Bash CLI，把 Ubuntu/Debian 云主机初始化为 XFCE/xrdp 远程桌面。`agentdesk.sh` 负责系统、账户、桌面和程序安装；软件全部交给原生 mise；云主机由 `agentdesk-create` skill 调用云厂商原生 CLI 创建。不引入自定义配置格式、插件框架、软件别名表或状态数据库。

声明支持 Debian 13（推荐）和 Ubuntu 26.10，amd64 与 arm64，E2E 默认使用 Debian 13；系统选择与验证状态见 [USER_GUIDE](USER_GUIDE.md#选择系统)。其他 Debian 系警告后继续，由用户自行验证；更早的版本、非 Debian 系和其他架构直接拒绝。架构差异交给 apt 和 mise 按本机架构选包。

## 1. 组成

| 文件 | 作用 |
|---|---|
| `install.sh` | 安装入口。管道运行时下载最新发布标签（或 `--ref`）的 GitHub 源码包；在源码目录内直接用本地文件（`--remote` 强制下载）。默认执行 `init`；`--update-only` 只复制程序 |
| `agentdesk.sh` | 全部逻辑：`init`、`verify`、`info`、`rdp`、`desktop-reset`、`update`，以及分派给原生 mise 的 `install`、`upgrade`、`outdated`、`run` |
| `resources/` | 安装到主机的配置：`xdg/`（XFCE、Fcitx5 默认值）、`Xsession.d/`（图形会话环境）、`profile.d/`（登录环境）、`security/`（密码规则） |
| `mise.toml` | AgentDesk 维护的全机软件清单，init 时覆盖为 `/etc/mise/config.toml` |
| `mise.example.toml` | 本地清单示例，不安装到主机 |
| `skills/agentdesk-create/` | 用云厂商原生 CLI 创建、部署、验收云主机；skill 里不写主机地址、账号或资源 ID，运行记录放在被忽略的 `local/` |
| `test.sh`、`tests/`、`.github/workflows/` | 离线测试、Docker E2E 和 CI，见 [TESTING_GUIDE](TESTING_GUIDE.md) |

安装到主机的程序固定为 `agentdesk.sh`、`install.sh`、`mise.toml` 加 `resources/`（见 `program_files`），不另设文件清单。

## 2. 安装流程

```mermaid
flowchart TD
    A["install.sh"] -->|源码目录内| C["agentdesk.sh init"]
    A -->|curl 管道| B["解析最新发布标签（或 --ref），下载 GitHub 源码包"] --> C
    C --> P["参数：命令行 > /etc/agentdesk/agentdesk.yaml > 默认值；检查系统，非 root 时经 sudo 重新执行"]
    P --> L["进度与错误同时写入 /var/log/agentdesk/init-时间戳.log"]
    L --> M["首次安装临时 mask xrdp，监听配置写好前不对外开放"]
    M --> K["apt 安装基础包、XFCE、xrdp、字体、输入法、pwquality（不做全机升级）；Debian 13 的 xrdp/xorgxrdp 取自 trixie-backports"]
    K --> Q["写入全机密码规则"]
    Q --> U["创建或复用 SSH/桌面账户；启用该账户的 SSH 密码认证，密码由用户手动设置"]
    U --> G["生成 en_US、zh_CN locale"]
    G --> Z["extrepo 启用 mise 官方 apt 源，安装或升级 mise"]
    Z --> R["写 xrdp.ini 监听地址与端口"]
    R --> I["程序复制到临时目录后整体替换 /usr/local/lib/agentdesk；覆盖 /etc/mise/config.toml"]
    I --> S["agentdesk install --system：安装共享工具和桌面应用"]
    S --> D["安装主题；写入桌面默认值、Xsession.d、profile.d"]
    D --> E["unmask、enable、start xrdp（不重启已运行的服务）"]
    E --> W["保存参数到 /etc/agentdesk/agentdesk.yaml，打印连接方式"]
```

重复执行 `init`（不带参数时沿用 `agentdesk.yaml`）按当前版本重写 AgentDesk 维护的文件，保留 `config.local.toml` 与锁、个人清单、密码和用户自己的桌面设置；已装软件只补缺，不升级。

## 3. 主机文件布局

```text
/usr/local/bin/agentdesk -> /usr/local/lib/agentdesk/agentdesk.sh
/usr/local/lib/agentdesk/            # 程序，root 所有
/etc/agentdesk/agentdesk.yaml        # init 保存的参数
/etc/ssh/sshd_config.d/00-agentdesk.conf # 工作账户的 SSH 密码认证
/etc/security/pwquality.conf.d/agentdesk.conf # 全机密码规则
/var/log/agentdesk/init-*.log         # init 日志，root 可读，保留最近 5 份
/etc/xdg/agentdesk/                  # 桌面系统默认值（XFCE、Fcitx5、自启动）
/etc/X11/Xsession.d/21agentdesk      # 图形会话：XDG_CONFIG_DIRS、语言、独立 D-Bus
/etc/X11/Xsession.d/90agentdesk-input
/etc/profile.d/agentdesk.sh          # 登录环境：工具路径、mise activate、direnv hook
/usr/share/themes/WhiteSur-Dark/     # 主题（--theme whitesur）
/etc/mise/config.toml                # AgentDesk 维护，随版本覆盖
/etc/mise/config.local.toml          # 本机管理员的增补与覆盖
/etc/mise/mise.lock、mise.local.lock # 两份系统清单各自的锁，在本机生成
/usr/local/share/mise/installs/      # 共享工具
~/.config/mise/config.toml           # 个人清单（与 mise use -g 同一文件）
~/.local/share/mise/installs/        # 个人工具
```

AgentDesk 不在用户家目录保存自己的文件；所有改动直接写入，不做备份。

## 4. 软件

| 层 | 文件 | 谁维护 | `agentdesk init` 时 |
|---|---|---|---|
| 通用 | `/etc/mise/config.toml` | AgentDesk（仓库里的 `mise.toml`） | 直接覆盖 |
| 本机 | `/etc/mise/config.local.toml` | 本机管理员 | 不动 |
| 个人 | `~/.config/mise/config.toml` | 每个用户 | 不动 |

mise 原生按 `conf.d/*.toml` → `config.toml` → `config.local.toml` 加载系统目录，后者覆盖前者，再叠加个人目录；AgentDesk 不做自己的合并逻辑。

| 命令 | 作用域 | 行为 |
|---|---|---|
| `agentdesk install NAME...` | 个人 | `mise use --global` 记录并安装；`apt:` 前缀写入 `[bootstrap.packages]` |
| `agentdesk install` | 个人 | 按清单和锁补齐 |
| `agentdesk upgrade` | 个人 | `lock --bump` 在版本范围内刷新锁，再 `install --locked`；apt 包执行 upgrade |
| `agentdesk outdated` | 个人 | `mise outdated`：列出 upgrade 会更新的工具（不含 apt 包），范围与 upgrade 相同 |
| `agentdesk install/upgrade/outdated --system` | 系统 | 同上；带名称时写入 `config.local.toml`；需要管理员权限 |
| `agentdesk run TASK [ARGS]` | 个人 | 执行个人清单中的 mise 任务 |

- **作用域隔离**用 mise 原生的 `MISE_IGNORED_CONFIG_PATHS`。个人操作只在锁定和 apt 包命令上忽略 `/etc/mise`，不改系统锁，也不替用户升级共享应用；`use`、`install`、`reshim` 照常加载系统清单，与直接运行 mise 一致。原因：mise 在共享安装目录里为每个工具维护 `global` 链接，指向当前用户的全局与系统配置所选的版本，忽略系统清单会让它去改这些链接，而那需要 root。个人锁通过 `MISE_LOCKFILE=1` 开启，不依赖系统清单里的设置。
- **`--system` 在干净环境中运行**：`env -i`、`HOME=/root`，只透传代理变量，忽略 `/root/.config/mise`；成功后两份清单和锁设为 0644。不设 `MISE_SYSTEM_CONFIG_FILE`，否则 mise 只读单个文件，`config.local.toml` 会被忽略。root 执行个人命令会被拒绝。
- **版本与锁**：仓库不分发锁文件，在目标主机按本机平台（linux-x64 或 linux-arm64）生成。版本经 mise 的版本服务（`use_versions_host = true`）解析，下载地址按 aqua 注册表拼出，不调用 GitHub API，没有 token 的新主机不会撞上每 IP 每小时 60 次的匿名限额。使用 mise 默认的 `generate` 锁模式，兼容性基线为 2026.11.7；普通用户安装时保留未变化的系统锁，已弃用的 `merge` 不再配置。install 沿用锁，upgrade 才刷新，不删除旧版本。
- **mise 本身**由官方 apt 源安装（`/usr/bin/mise`，apt 按签名校验），每次 init 升到最新版，`upgrade --system` 也会升级；不设最低版本。
- **预装**以 `mise.toml` 为准：命令行工具交给 mise，Chrome、VS Code、tmux 经 apt。AI 工具只装命令行版本，不装桌面客户端。

## 5. 桌面

- **全部是系统级默认值，不写用户家目录。** 默认值写在 `/etc/xdg/agentdesk/`，由 `21agentdesk` 放到 `XDG_CONFIG_DIRS` 最前（与 Xubuntu 相同），不覆盖软件包自带的 `/etc/xdg`。用户 `~/.config` 中的设置优先，所以所有用户（含之后新增的）共用一份默认值，个人修改自然保留。
- **配置内容全部在 `resources/`，脚本里只有逻辑。** 随参数变化的值写成占位符（`@THEME_NAME@`、`@ICON_THEME@`、`@LOCALE@`），init 复制时替换；取值都是校验过的固定选项。
- 覆盖的 XFCE 频道：面板、外观、窗口管理器、背景、终端。左侧 Dock 的启动器引用软件包的 desktop ID，布局与调整方式见[桌面维护](USER_GUIDE.md#4-桌面维护)；背景是 XFCE 原生渐变，为 xorgxrdp 的显示器 rdp0–rdp3 预置。
- `21agentdesk` 排在 `20dbus_xdg-runtime` 之后、`75dbus_dbus-launch` 之前，取消共享用户总线，让每个 RDP 会话有独立 D-Bus；仅在有语言覆盖值时设置桌面语言（见[安装参数](USER_GUIDE.md#参数)）。`90agentdesk-input` 排在 im-config 之后，设置 Fcitx5 变量。
- `profile.d/agentdesk.sh` 对非 root 用户生效：加入 mise shims 和已安装工具路径（离线解析），交互式 bash 再依次执行 `mise activate` 和 `direnv hook`。XFCE 终端以登录 shell 启动，所以会加载它；`ssh 主机 命令` 这类非登录 shell 不加载。
- WhiteSur 主题按固定提交装到 `/usr/share`：上游安装脚本以 `nobody` 在临时目录运行，root 只复制检查过的产物；`--theme none` 用 Greybird/Adwaita。
- `desktop-reset` 必须加 `--force`：要求该用户先退出全部会话，删除上述频道文件和 `panel/` 目录，不做备份；配置中有符号链接（dotfiles）时拒绝。
- 不修改系统时区（云镜像默认 UTC）。

## 6. 远程连接

- Debian 13 的 xrdp/xorgxrdp 来自官方 trixie-backports（0.10.6.1，带 H.264，与 Ubuntu 26.10 同代）：系统未配置该源时写入 `/etc/apt/sources.list.d/agentdesk-backports.sources`，只这两个包指定 backports，依赖仍来自 stable。backports 不受 Debian 安全团队覆盖，所以 init 对它们例外地升级到最新版（会重启 xrdp），其余包仍只补缺。
- `direct`（默认）监听 `0.0.0.0:PORT`，由用户在安全组或防火墙中限制来源 IP；`tunnel` 只监听 `127.0.0.1`，经 SSH 端口转发访问。
- `verify` 检查软件包（含 Chrome、VS Code）、共享清单中的 mise 工具是否装齐、SSH 服务或 socket 及 `sshd -T` 中全部端口的监听、工作账户的有效认证配置、密码状态和密码规则，以及 xrdp 服务与 `xrdp.ini` 的实际监听；`[PASS]/[FAIL]` 输出到 stdout，外部 SSH/RDP 登录仍需实测。自动安全更新（unattended-upgrades）未启用时输出 `[WARN]` 和启用命令，不计入失败：AgentDesk 不做全机升级，xrdp 等对外服务的补丁依赖它。
- SSH 用 `00-agentdesk.conf` 中的 `Match User` 只为工作账户启用密码认证、禁止空密码；切换 `--user` 会替换旧规则。要求主配置在首个 `Match` 前全局 Include 受管文件或 `sshd_config.d/*.conf`，写入后先检查语法和有效配置，再 reload，失败恢复原文件。其他账户的认证配置保留。
- `info` 按当前模式分组输出连接信息和 xrdp 证书的 SHA-256 指纹（`[Globals]` 的 `certificate`，未设置时为 `/etc/xrdp/cert.pem`），`rdp` 输出 `rdp://` 链接，都写 stdout、不需要 root、不输出凭据。公网地址只读对应云平台元数据：AWS 和阿里云均携带令牌，请求绕过代理，其他厂商不发请求。取不到地址时，`info` 提示手动查找，`rdp` 报错退出。macOS 用 `open` 打开链接，参数值中的冒号编码为 `%3A`。

## 7. 权限与安全

- 支持 root 或 sudo 用户运行：参数先标准化，再经 `sudo /usr/bin/env` 重新执行；系统操作以 root 执行，桌面和个人文件通过 `runuser` 降权、在干净环境中创建。
- 代理只透传已设置的 `http_proxy`、`https_proxy`、`all_proxy`、`no_proxy`。`--proxy URL` 只在本次运行导出这些变量，不保存（地址可能含密码，而设置文件所有人可读）；只接受 `http(s)://`（apt 不支持 SOCKS）。
- 不提供下载镜像：网络不通时用 `--proxy`，它一次覆盖全部下载；镜像只能覆盖 AgentDesk 自己的文件。
- `agentdesk.yaml` 由 root 写入，0644，不含凭据，按行解析，不当作脚本执行。
- 默认 SSH/桌面账户为 `agentdesk`，已有设置优先，`--user` 可覆盖。新账户加入 sudo 组（需要密码），SSH 和直连 RDP 须限制来源 IP。
- 密码规则用系统自带的 pam_pwquality：`/etc/security/pwquality.conf.d/agentdesk.conf` 要求至少 10 位、小写/大写/数字/符号中至少三类，并开启 `enforce_for_root`（管理员用 `sudo passwd` 设置时同样强制）。规则全机生效，只约束之后设置的密码。
- init 日志只记录 stderr（进度与错误），代理只在环境变量中，不进入日志；连接信息写 stdout，不记录。
- 拒绝符号链接形式、非 root 所有或组/其他可写的安装目录和系统配置；`/usr/local/bin/agentdesk` 不是受管软链时拒绝覆盖。
- 不自动生成密码，不修改防火墙或云安全组，不自动重启运行中的 xrdp。

## 8. 版本与更新

- **版本号**只在 `agentdesk.sh` 的 `VERSION`。发版提交写正式版本（如 `0.3.0`）、打 `v0.3.0` 标签并发布 GitHub Release；发版后的第一个改动把它改为下一个开发版本（如 `0.3.1-dev`）。
- **命令语义参照 Homebrew**；与 Homebrew 不同，`upgrade` 不会先执行 `update`，因为 update 需要 root、会改动整台机器。

| Homebrew | AgentDesk | 作用 |
|---|---|---|
| `brew update` | `agentdesk update [--ref REF]` | 只更新 AgentDesk 程序与随附资源：由 `install.sh --remote --update-only` 下载，复制到同级临时目录后整体替换程序目录（不保留旧版本，失败时原程序不变），不执行 init、install 或 upgrade；显式 `--ref` 总是更新 |
| `brew outdated` | `agentdesk outdated [--system]` | 列出 upgrade 会更新的工具 |
| `brew upgrade` | `agentdesk upgrade [--system]` | 在声明的版本范围内升级软件 |
| `brew install` | `agentdesk install [--system] [NAME...]` | 记录并安装软件，或补齐清单 |

- `update` 不读写主机设置；需要应用新配置时显式运行 `init`。旧版更新命令需用新版 `install.sh --update-only` 迁移；目标源码没有独立更新入口时，在加载前拒绝。
- **设置文件** `agentdesk.yaml` 记录用户、主题、语言和 RDP 模式与端口；优先级为命令行 > 设置文件 > 默认值，不使用额外的环境变量。选 YAML 是因为团队 Go 配置规范（gox/config）读取 `<app>.yaml`；Bash 侧由 `settings_read` 用 awk 只解析两层 `key: value`。

## 9. 不做的事

- 不支持 RHEL、Fedora、openSUSE、Arch 等非 apt 系统。
- 不做自定义配置格式、profile 继承、软件别名表或每个应用一个安装脚本。
- 不做回滚框架、状态数据库，不对用户任务承诺幂等；更新不保留旧版本程序。
- 不做全机升级、操作系统升级或后台自动更新。
- 不管理防火墙、云安全组和密码。
