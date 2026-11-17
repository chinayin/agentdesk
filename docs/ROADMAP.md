# AgentDesk 路线图

> 记录：只列未完成的事项，每项带验收标准，完成后直接删除。现状以代码和契约文档（[ARCHITECTURE](ARCHITECTURE.md)、[USER_GUIDE](USER_GUIDE.md)、[TESTING_GUIDE](TESTING_GUIDE.md)）为准，变更历史以 git 和 Release 说明为准。

## 1. 待验收

- [ ] **Ubuntu 26.10 人工 RDP 验收。** EC2 真机上的一行安装、`update`、`verify`、重启和 `info` 公网地址读取已通过；仍需人工用 RDP 客户端确认：登录、断线重连、重启后重新登录、主题与面板、中文输入、本地与远程互相复制粘贴和常用快捷键、从菜单打开 Chrome 和 VS Code（不加 `--no-sandbox`）、XFCE 终端里的工具路径，以及日志中的实际 GFX/H.264 编码协商。验收：每项记录通过或失败，至少覆盖一种 macOS 和一种 Windows 客户端。

## 2. 功能

- [ ] **用户软件示例。** 以一个具体软件演示 `agentdesk install`、`upgrade` 和失败后重试；需要额外部署步骤的才写 `[tasks]`。验收：首次安装、重复执行、升级、失败重试都保留用户配置和数据。
- [ ] **编辑器连接。** `agentdesk-create` 输出可供 VS Code Remote-SSH 使用的 SSH 配置片段。验收：能打开远端目录和终端；不改写用户已有的 SSH 配置。
- [ ] **云镜像复用。** `agentdesk-create` 支持从镜像或快照创建。验收：从不含个人凭据的模板建出第二台机器并通过验收；脚本仍能从干净系统重建。
- [ ] **人和 Agent 共用桌面。** Agent 在 XFCE/RDP 中启动可见浏览器，人观察、接管后再交还。验收：会话用户、浏览器 profile、控制权和断线行为明确，不出现双方同时输入的冲突。

## 3. 改进

- [ ] **发布自动化（待定）。** 推送 `v*` 标签时检查标签与 `VERSION` 一致、跑离线测试、创建 Release。验收：标签与 `VERSION` 不符时工作流失败。

## 4. 边界

不增加宿主机虚拟化依赖。一台大服务器要承载多套 AgentDesk 时，在虚拟机里复用同一个安装器。
