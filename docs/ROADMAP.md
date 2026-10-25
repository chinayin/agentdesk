# AgentDesk 路线图

> 记录：只列未完成的事项，每项带验收标准；完成后直接删除该项。现状以代码和契约文档（[ARCHITECTURE](ARCHITECTURE.md)、[USER_GUIDE](USER_GUIDE.md)、[TESTING_GUIDE](TESTING_GUIDE.md)）为准，变更历史以 git 和 Release 说明为准，不在本文维护。

## 概述

当前版本为 `0.2.0`。CI 中离线测试与 Ubuntu 26.04 amd64、arm64 的 Docker E2E 均已通过。下面列出 CI 覆盖不到的验收项，以及已确认但尚未开始的功能。

## 1. 待验收

- [ ] **Ubuntu 26.04 真机验收。** 用 README 的一行安装命令在新机上安装（应解析到最新发布版本），随后 `agentdesk update` 提示已是最新。逐项记录通过、失败或待人工验证：RDP 登录、断线重连、重启后重新登录、中文输入、主题、Chrome、VS Code（不加 `--no-sandbox` 能从菜单打开，即 AppArmor `vscode` 配置生效）、`mise.toml` 中的全部命令行工具与 tmux，以及 SSH、RDP 终端和菜单启动时的工具路径。系统级桌面配置要重点确认：`/etc/xdg/agentdesk` 的默认值被 xfconf 读取、面板启动器按 desktop ID 打开应用、rdp0 背景生效、`dbus-launch` 独立会话下重连正常、Fcitx5 自启动、XFCE 终端以登录 shell 加载 `mise activate` 和 direnv hook。不承诺重启后保留内存状态。
- [ ] **代理实测。** 在只能经代理访问外网的真实网络中，用 `--proxy` 完成安装和 `agentdesk update`。验收：代理传到 apt（含厂商源）、mise 和 git，全程没有直连失败。
- [ ] **Debian 默认 awk（mawk）。** 验证 `settings_read` 对注释、引号、两层键的解析。验收：与 macOS awk 的单元测试结果一致。
- [ ] **系统矩阵。** 用 `bash tests/e2e.sh --image IMAGE --arch ARCH` 依次验收 Debian 13、Ubuntu 24.04、Ubuntu 22.04、Debian 12，amd64 与 arm64 各至少一个系统；只为实际发现的差异补代码（Ubuntu 22.04 的 XFCE 4.16 较旧，重点看面板配置；其 xrdp 0.9.17 自带的 xrdp.ini 已写明支持 `port=tcp://地址:端口`）。验收：每个组合都完成 E2E，最少一次真机 RDP 登录。
- [ ] **阿里云分支 POC。** 用 `agentdesk-create` 的阿里云流程创建、部署、验收并按授权回收。验收：输出与 AWS 分支相同的交付信息；`agentdesk info` 能从阿里云实例元数据取到公网地址（EIP 或固定公网 IP）。
- [ ] **剪贴板与快捷键。** 人工验证远程到本地的反向复制，以及常用组合快捷键。验收：在至少一种 macOS 和一种 Windows RDP 客户端上记录结果。

## 2. 功能

### 近期

- [ ] **用户软件示例。** 以一个具体软件演示 `agentdesk install`、`upgrade` 和失败后重试；需要额外部署步骤的软件才写 `[tasks]`，需要常驻时附 systemd 示例。验收：首次安装、重复执行、升级、失败重试都保留用户配置和数据；后台服务额外检查状态、日志和重启恢复。

### 之后

- [ ] **编辑器连接。** `agentdesk-create` 输出可供 VS Code 等 Remote-SSH 使用的 SSH 配置片段。验收：实际打开远端目录和终端；不改写用户已有的 SSH 配置。
- [ ] **云镜像复用。** `agentdesk-create` 增加镜像/快照参数，先在已通过 POC 的云上验证。验收：从不含个人凭据和登录态的模板创建第二台机器，核查身份、软件和桌面；记录部署耗时；脚本仍能从干净系统重建。
- [ ] **人和 Agent 共用一个桌面。** 在 XFCE/RDP 中让 Agent 启动可见浏览器，由人观察、接管后再交还。验收：会话与目标用户一致，浏览器 profile、控制权和断线行为明确，不出现双方同时输入的冲突。之后再按需要评估浏览器访问桌面的网关。

## 3. 边界

不增加宿主机虚拟化依赖。若以后需要一台大服务器承载多套 AgentDesk，参考设计稿 [KVM_HOSTING_GUIDE](KVM_HOSTING_GUIDE.md) 和 [KVM_MICROVM_FIRECRACKER](KVM_MICROVM_FIRECRACKER.md)，在虚拟机内复用同一个安装器。
