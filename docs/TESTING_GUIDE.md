# AgentDesk 测试指南

> 契约：只写现状，必须与代码一致。

## 概述

测试分三层，逐层更慢、更接近真实环境，每层只覆盖下一层做不到或太慢的部分。前两层也在 GitHub Actions 上运行：`test.yml` 在每次推送和 PR 时跑离线测试；`e2e.yml` 手动触发，在 `ubuntu-26.04`（amd64）和 `ubuntu-26.04-arm`（arm64）上各跑一遍 E2E，日志和截图作为 artifact 上传。

| 层 | 入口 | 耗时 | 证明什么 |
|---|---|---|---|
| 离线 | `bash test.sh` | 约 10 秒 | 脚本逻辑、参数、作用域隔离和安全保护正确 |
| E2E | `bash tests/e2e.sh` | runner 上约 3 分钟；首次下载约 1.3 GB | 能在干净系统（默认 Ubuntu 26.04）上真实安装、重跑、升级、重启，桌面应用能打开窗口 |
| 真机 | `agentdesk-create` skill | 小时级 | 真实 RDP 登录、中文输入、剪贴板、断线重连 |

## 离线测试：`test.sh`

`test.sh` 是离线测试的唯一入口，按 gox shell 规范放在被测脚本旁边。依次执行，任一项失败即返回非 0：

1. `python3 -m unittest discover -s tests`；
2. `bash -n` 检查全部 `.sh`（不含 `local/`）；
3. `shellcheck`（未安装时警告并跳过）；
4. 花括号检查：`$VAR` 后紧跟非 ASCII 字符时报错。

| 文件 | 覆盖 |
|---|---|
| `tests/test_agentdesk.py` | 主脚本：参数与帮助、系统与架构判断、桌面默认值与模板、登录环境、desktop-reset、设置文件、`info`/`rdp`、自我更新、install.sh、代理 |
| `tests/test_software.py` | 软件命令：个人与 `--system` 作用域、忽略系统清单的范围、参数拒绝、退出码透传、代理传递 |
| `tests/test_mise_integration.py` | 真实 mise：配置写入与隔离、系统目录加载顺序、任务输出；不下载软件。需 `AGENTDESK_TEST_MISE="$(command -v mise)"` |

编写约定：

- **不碰主机**：临时 HOME；`mise`、`curl`、`git` 等外部命令用临时 `bin/` 里的替身，不调用真实 sudo、apt 或云 CLI，不联网。
- **测函数**：`source agentdesk.sh` 后直接调用函数；需要 root 或 Linux 的路径用 dry-run 或替身，真实效果留给 E2E。
- **测保护分支**：每个新行为至少覆盖正常路径和一个拒绝路径，并断言退出码（含义见 [USER_GUIDE](USER_GUIDE.md#8-退出码)）。
- **断言没写什么**：如 dry-run 后目录为空、个人操作不出现系统清单。
- **缺依赖时显式跳过**：`unittest.skipUnless` 并写明原因。

## Docker E2E：`tests/e2e.sh`

```bash
bash tests/e2e.sh                     # Ubuntu 26.04，Docker 本机架构
bash tests/e2e.sh --image debian:13   # 其他系统
bash tests/e2e.sh --arch amd64        # 指定架构（该架构须能运行 systemd 容器）
bash tests/e2e.sh --proxy URL         # 受限网络
bash tests/e2e.sh --keep              # 保留容器排错
bash tests/e2e.sh --dry-run           # 只打印计划
```

| 文件 | 作用 |
|---|---|
| `tests/e2e.sh` | 只接受本地 Docker；构建镜像，启动特权 systemd 容器，复制程序结构，分两阶段执行，导出日志到 `local/e2e/` |
| `tests/e2e.Dockerfile` | 基础镜像加 systemd、Xvfb 等测试工具；产品软件由真实 `install.sh` 安装 |
| `tests/e2e-container.sh` | `install` 阶段：安装 → verify → info → `install --system` → 不带参数重跑 init（清单、锁、密码、tunnel 不变）→ 手改通用清单后被覆盖 → `upgrade --system` → 个人安装与原生 `mise use -g` → `upgrade`；`check` 阶段：重启后 verify 并跑 GUI 冒烟 |
| `tests/e2e-gui.sh` | Xvfb 中启动 XFCE，检查回收站后端，打开 Chrome、VS Code 并截图；VS Code 带 `--no-sandbox`（本地 Docker 中其沙箱无法创建用户命名空间） |

- 容器不挂载宿主目录或 Docker socket，不开放端口，不读取任何凭据。`--proxy` 只进入镜像构建参数和容器环境。
- Apple Silicon 上用默认的 arm64；amd64 的 systemd 在模拟环境中会崩溃，入口检测到后以退出码 2 结束。
- 不覆盖：install.sh 的远程下载（由离线测试的假 curl 覆盖）、WhiteSur 主题下载（用 `--theme none`）、真实 RDP 登录、输入法与剪贴板、账号登录。其他系统按需用 `--image` 运行，不预先建矩阵。

## 真机验收

按 [agentdesk-create](../skills/agentdesk-create/SKILL.md) 创建云主机，用远程安装器安装并运行 `verify`，再人工检查 RDP 体验，结果记入 [ROADMAP](ROADMAP.md) 的待验收项。服务正常或包已安装都不能代替 GUI 验收。

## 新增测试放哪一层

| 改动 | 放哪一层 |
|---|---|
| 参数、校验、生成的文件内容、作用域、退出码 | 离线单元测试，必加 |
| 依赖真实 mise 行为（配置合并、隔离、锁） | `test_mise_integration.py` |
| apt 包、systemd 服务、安装顺序、重启后的状态 | `e2e-container.sh` |
| 应用能否打开窗口 | `e2e-gui.sh` |
| RDP 体验、输入法、剪贴板、云网络 | 真机验收 |
