# PVE Quick Setup

用于 Proxmox VE 宿主机的 LXC 快速克隆、SSH 初始化、TUN/Tailscale 配置和状态检查脚本。

## 功能

- 从现有 LXC Template 进行 Full Clone。
- 初始化容器中的 OpenSSH，并从宿主机 `/root/.ssh/authorized_keys` 增量同步公钥。
- 启动并检查 `tailscaled`，执行 `tailscale up` 并显示注册链接（如果返回）。
- 检查 LXC 的 SSH、TUN 和 Tailscale 状态。
- 对已有 TUN 配置进行提示和对照，不自动覆盖未知配置。

## 文件

- `quick_ct.sh`：交互式克隆并初始化一个新的 LXC。
- `quick_check_ct.sh`：检查非模板 LXC；检测到问题后逐个询问是否修补。
- `ssh-menu.ps1`：Windows PowerShell SSH/PVE 节点选择器。
- `networks.example.json`：SSH 节点配置示例；真实的 `networks.json` 不包含在仓库中。

## 设计说明

- `quick_ct.sh` 负责创建新容器，`quick_check_ct.sh` 负责检查和修复已有容器，职责分离，便于重复执行。
- SSH 公钥采用增量同步，不会重复追加已有 Key。
- TUN 配置采用保守策略：创建容器时写入缺失配置；检查已有容器时发现未知配置只提示，不自动覆盖。
- 服务检查兼容常见的 `systemd`、SysV init 和 Alpine `OpenRC` 环境。

## 使用前提

- 在 Proxmox VE 宿主机上以 `root` 运行。
- 已安装并可用 `pct`。
- 已准备好可用的 LXC Template。
- 如需同步 SSH 公钥，宿主机应存在 `/root/.ssh/authorized_keys`。
- 容器需要能够访问软件包仓库和 Tailscale 服务。

## 使用

```bash
chmod +x quick_ct.sh quick_check_ct.sh
./quick_ct.sh
./quick_check_ct.sh
```

也可以通过环境变量指定模板 CTID：

```bash
TEMPLATE_ID=<template-ctid> ./quick_ct.sh
```

## Windows SSH 菜单

仓库不包含真实的 `networks.json`。首次使用时复制示例配置，并按自己的环境修改：

```powershell
Copy-Item .\networks.example.json .\networks.json
.\ssh-menu.ps1
```

配置支持两种节点：

- `direct`：直接执行 SSH，例如 `user@pve-host`。
- `pve_cts`：通过 PVE API 自动发现非模板 LXC，并使用 `pct enter` 进入容器。

`networks.json` 已加入 `.gitignore`。它只应保留在本机，不要把真实节点配置提交到公开仓库。

## TUN 配置说明

Tailscale 在 LXC 中运行通常需要将宿主机的 TUN 设备映射到容器。脚本支持以下常见配置形式：

```text
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file 0 0
```

部分环境也使用：

```text
dev0: /dev/net/tun
```

`quick_check_ct.sh` 不会自动清洗或覆盖已有的未知 TUN 配置。发现配置差异时，它会显示当前内容和标准写法，由管理员确认后手动调整，避免破坏已有容器配置。

## 安全注意事项

- 先阅读脚本内容，再运行。
- `quick_ct.sh` 会创建容器、修改容器配置、启动/重启容器，并可能安装或修改 OpenSSH。
- 当前 SSH 初始化逻辑会设置 `PermitRootLogin yes`。建议仅在可信内网使用，并优先改为公钥认证及更严格的 SSH 策略。
- 脚本会读取宿主机的 `/root/.ssh/authorized_keys`，请勿将该文件内容提交到仓库。
- Tailscale 注册链接具有敏感性，不要将终端输出或日志公开发布。
- 不要把 API Token、Auth Key、私钥、密码或真实环境配置写入脚本、Issue 或日志。

## 免责声明

本项目面向个人实验和运维自动化场景。脚本会修改 PVE 和 LXC 配置，运行前请备份重要数据，并先在非生产环境验证。作者不对误操作、配置冲突、网络故障或数据损失负责。

---

# PVE Quick Setup (English)

Helper scripts for fast LXC provisioning on a Proxmox VE host: clone, SSH bootstrap, TUN/Tailscale setup and status checks.

## Features

- Full clone from an existing LXC template.
- Initializes OpenSSH inside the container and incrementally syncs public keys from the host's `/root/.ssh/authorized_keys`.
- Starts and checks `tailscaled`, runs `tailscale up` and prints the registration URL when returned.
- Checks SSH, TUN and Tailscale status of LXCs.
- Reports existing TUN configuration differences without silently overwriting unknown settings.

## Files

- `quick_ct.sh` — interactive clone and initialization of a new LXC.
- `quick_check_ct.sh` — checks non-template LXCs and asks before patching each detected issue.
- `ssh-menu.ps1` — Windows PowerShell SSH / PVE node picker.
- `networks.example.json` — sample SSH node configuration. The real `networks.json` is not committed.

## Design notes

- `quick_ct.sh` creates containers; `quick_check_ct.sh` audits and repairs existing ones. Separate responsibilities make both safe to re-run.
- SSH keys are synced incrementally — existing keys are never appended twice.
- TUN configuration is conservative: missing entries are written when creating a container, but unknown settings in existing containers are only reported, never overwritten.
- Service checks work across `systemd`, SysV init and Alpine `OpenRC` environments.

## Requirements

- Run as `root` on the Proxmox VE host.
- `pct` available.
- A working LXC template.
- `/root/.ssh/authorized_keys` on the host if you want key sync.
- Containers must be able to reach package repositories and Tailscale.

## Usage

```bash
chmod +x quick_ct.sh quick_check_ct.sh
./quick_ct.sh
./quick_check_ct.sh
```

You can also pass the template CTID via environment variable:

```bash
TEMPLATE_ID=<template-ctid> ./quick_ct.sh
```

## Windows SSH menu

The real `networks.json` is not committed. Copy the example and adapt it:

```powershell
Copy-Item .\networks.example.json .\networks.json
.\ssh-menu.ps1
```

Two node types are supported:

- `direct` — plain SSH, e.g. `user@pve-host`.
- `pve_cts` — discovers non-template LXCs through the PVE API and enters them with `pct enter`.

`networks.json` is in `.gitignore`. Keep it local; never commit real node configuration to a public repository.

## TUN configuration

Running Tailscale inside an LXC usually requires mapping the host TUN device into the container. The scripts support the common forms:

```text
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file 0 0
```

Some environments use:

```text
dev0: /dev/net/tun
```

`quick_check_ct.sh` never cleans up or overwrites unknown TUN settings. When it finds a difference it prints both the current content and the canonical form, leaving the decision to the administrator.

## Security notes

- Read the scripts before running them.
- `quick_ct.sh` creates containers, modifies their configuration, starts/restarts them and may install or modify OpenSSH.
- The SSH bootstrap sets `PermitRootLogin yes`. Use it only on a trusted internal network and prefer key-only authentication with a stricter SSH policy.
- The scripts read `/root/.ssh/authorized_keys`; never commit that file.
- Tailscale registration URLs are sensitive — do not publish terminal output or logs.
- Never put API tokens, auth keys, private keys, passwords or real environment configuration into scripts, issues or logs.

## Disclaimer

This project targets personal experiments and operations automation. The scripts modify PVE and LXC configuration. Back up important data and test in a non-production environment first. The author is not responsible for misconfiguration, conflicts, network failures or data loss.

## License

MIT