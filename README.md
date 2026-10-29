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
- `old/`：历史脚本，仅供参考，不建议直接运行。

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

脚本识别以下配置形式：

```text
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file 0 0
```

或：

```text
dev0: /dev/net/tun
```

`quick_check_ct.sh` 不会自动清洗或覆盖已有的未知 TUN 配置；发现差异时会显示当前配置和标准配置，建议确认后手动修改。

## 安全注意事项

- 先阅读脚本内容，再在生产节点运行。
- `quick_ct.sh` 会创建容器、修改容器配置、启动/重启容器，并可能安装或修改 OpenSSH。
- 当前 SSH 初始化逻辑会设置 `PermitRootLogin yes`。建议仅在可信内网使用，并优先改为公钥认证及更严格的 SSH 策略。
- 脚本会读取宿主机的 `/root/.ssh/authorized_keys`，请勿将该文件内容提交到仓库。
- Tailscale 注册链接具有敏感性，不要将终端输出或日志公开发布。
- 不要把 API Token、Auth Key、私钥、密码或真实环境配置写入脚本、Issue 或日志。

## 免责声明

脚本按当前项目环境编写，运行前请自行备份 PVE 配置和重要容器数据。作者不对误操作、配置冲突、网络故障或数据损失负责。
