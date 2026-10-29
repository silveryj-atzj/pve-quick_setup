#!/usr/bin/env bash

set -u

TEMPLATE_ID="${TEMPLATE_ID:-}"
HOST_KEYS="/root/.ssh/authorized_keys"
NEW_ID=""
CT_NAME=""

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "错误：请使用 root 运行此脚本。"
    exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
    echo "错误：未找到 pct，请在 Proxmox VE 宿主机上运行。"
    exit 1
fi

bold="\033[1m"
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
reset="\033[0m"

info() {
    printf "%b\n" "${green}✔${reset} $*"
}

warn() {
    printf "%b\n" "${yellow}⚠${reset} $*"
}

error() {
    printf "%b\n" "${red}✖${reset} $*" >&2
}

select_template() {
    local id hostname choice index=1
    local -a template_ids

    if [ -n "$TEMPLATE_ID" ]; then
        if [ ! -f "/etc/pve/lxc/${TEMPLATE_ID}.conf" ] ||
            ! grep -Eq '^template:[[:space:]]*1[[:space:]]*$' "/etc/pve/lxc/${TEMPLATE_ID}.conf"; then
            error "指定的 CT $TEMPLATE_ID 不是有效的 LXC 模板。"
            return 1
        fi
        info "使用环境变量指定的模板 CT $TEMPLATE_ID。"
        return 0
    fi

    while IFS= read -r id; do
        [ -z "$id" ] && continue
        if [ -f "/etc/pve/lxc/${id}.conf" ] &&
            grep -Eq '^template:[[:space:]]*1[[:space:]]*$' "/etc/pve/lxc/${id}.conf"; then
            template_ids+=("$id")
        fi
    done < <(pct list | awk 'NR > 1 {print $1}')

    if [ "${#template_ids[@]}" -eq 0 ]; then
        error "当前节点没有检测到 LXC 模板。"
        return 1
    fi

    echo "检测到以下 LXC 模板："
    for id in "${template_ids[@]}"; do
        hostname=$(pct config "$id" 2>/dev/null | awk -F': ' '$1 == "hostname" {print $2; exit}')
        printf "  %d) CT %s" "$index" "$id"
        [ -n "$hostname" ] && printf " (%s)" "$hostname"
        printf "\n"
        index=$((index + 1))
    done

    while true; do
        read -r -p "请选择模板编号 [1-${#template_ids[@]}]：" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
            [ "$choice" -ge 1 ] &&
            [ "$choice" -le "${#template_ids[@]}" ]; then
            TEMPLATE_ID="${template_ids[$((choice - 1))]}"
            return 0
        fi
        warn "请输入列表中的有效编号。"
    done
}

confirm() {
    local answer
    read -r -p "$1 [Y/n] " answer
    case "${answer:-y}" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

configure_tun() {
    local conf_file="/etc/pve/lxc/${NEW_ID}.conf"

    if [ ! -f "$conf_file" ]; then
        error "找不到 CT $NEW_ID 的配置文件：$conf_file"
        return 1
    fi

    if ! grep -q "lxc.mount.entry: /dev/net/tun" "$conf_file"; then
        printf '\n# Auto-added TUN device for Tailscale\n' >> "$conf_file"
        printf 'lxc.cgroup2.devices.allow: c 10:200 rwm\n' >> "$conf_file"
        printf 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file\n' >> "$conf_file"
        info "已为 CT $NEW_ID 注入 TUN 设备配置。"
    else
        info "CT $NEW_ID 已存在 TUN 设备配置，跳过。"
    fi
}

sync_keys() {
    local id="$1"
    local key added_count=0

    if [ ! -f "$HOST_KEYS" ]; then
        warn "未找到 $HOST_KEYS，跳过 SSH 公钥同步。"
        return 0
    fi

    pct exec "$id" -- mkdir -p /root/.ssh
    pct exec "$id" -- chmod 700 /root/.ssh
    pct exec "$id" -- touch /root/.ssh/authorized_keys
    pct exec "$id" -- chmod 600 /root/.ssh/authorized_keys

    while IFS= read -r key || [ -n "$key" ]; do
        case "$key" in
            ""|\#*) continue ;;
        esac

        if ! pct exec "$id" -- grep -qF -- "$key" /root/.ssh/authorized_keys; then
            printf '%s\n' "$key" | pct exec "$id" -- tee -a /root/.ssh/authorized_keys >/dev/null
            added_count=$((added_count + 1))
        fi
    done < "$HOST_KEYS"

    info "SSH 公钥同步完成：新增 $added_count 个 Key。"
}

repair_ssh() {
    local id="$1"

    info "CT $id 正在检查 OpenSSH；未安装时将自动安装。"
    if ! pct exec "$id" -- bash -c '
        set -e
        sshd_path=""

        if ! command -v sshd >/dev/null 2>&1; then
            echo "未检测到 sshd，开始安装 OpenSSH 服务端..."
            if command -v apt-get >/dev/null 2>&1; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update
                apt-get install -y openssh-server
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y openssh-server
            elif command -v yum >/dev/null 2>&1; then
                yum install -y openssh-server
            elif command -v apk >/dev/null 2>&1; then
                apk add openssh
            else
                echo "错误：未识别容器的包管理器，无法自动安装 OpenSSH。" >&2
                exit 1
            fi
        fi

        sshd_path="$(command -v sshd)"
        [ -x "$sshd_path" ]

        ensure_sshd_runtime_dir() {
            mkdir -p /run/sshd /var/run/sshd
            chmod 0755 /run/sshd /var/run/sshd
            chown root:root /run/sshd /var/run/sshd
            if [ ! -d /run/sshd ]; then
                echo "错误：无法创建 /run/sshd，当前状态：" >&2
                ls -ld /run /run/sshd /var/run /var/run/sshd 2>&1 || true
                return 1
            fi
        }

        ensure_sshd_runtime_dir
        if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
            ssh-keygen -A
        fi
        if [ -f /etc/ssh/sshd_config ]; then
            if grep -qE "^[#]*PermitRootLogin" /etc/ssh/sshd_config; then
                sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
            else
                printf "\nPermitRootLogin yes\n" >> /etc/ssh/sshd_config
            fi
        fi
        ensure_sshd_runtime_dir
        "$sshd_path" -t
        if ! (
            systemctl restart ssh 2>/dev/null ||
            systemctl restart sshd 2>/dev/null ||
            service ssh restart 2>/dev/null ||
            service sshd restart 2>/dev/null
        ); then
            ensure_sshd_runtime_dir
            "$sshd_path"
        fi
    '; then
        error "CT $id 的 OpenSSH 安装或服务修复失败，请检查容器网络和包管理器。"
        return 1
    fi

    info "SSH 服务已检查并重启。"
}

start_tailscaled() {
    local id="$1"

    if ! pct exec "$id" -- sh -c 'command -v tailscaled' >/dev/null 2>&1; then
        error "CT $id 找不到 tailscaled，无法执行 tailscale up。"
        return 1
    fi

    info "正在启动 CT $id 的 tailscaled 后台服务..."
    if ! pct exec "$id" -- sh -c '
        set -e
        if command -v timeout >/dev/null 2>&1 &&
            timeout 5s tailscale status >/dev/null 2>&1; then
            exit 0
        elif ! command -v timeout >/dev/null 2>&1 &&
            tailscale status >/dev/null 2>&1; then
            exit 0
        fi
        if command -v systemctl >/dev/null 2>&1 &&
            (systemctl start tailscaled 2>/dev/null || systemctl restart tailscaled 2>/dev/null); then
            exit 0
        fi
        if command -v service >/dev/null 2>&1 &&
            (service tailscaled start 2>/dev/null || service tailscale start 2>/dev/null); then
            exit 0
        fi
        if command -v rc-service >/dev/null 2>&1 &&
            rc-service tailscaled start 2>/dev/null; then
            exit 0
        fi
        mkdir -p /var/run/tailscale /var/lib/tailscale
        nohup tailscaled \
            --state=/var/lib/tailscale/tailscaled.state \
            --socket=/var/run/tailscale/tailscaled.sock \
            >/var/log/tailscaled.log 2>&1 &
        sleep 2
        tailscale --socket=/var/run/tailscale/tailscaled.sock status >/dev/null 2>&1
    '; then
        error "CT $id 的 tailscaled 启动失败。请检查 /var/log/tailscaled.log。"
        return 1
    fi
}

run_tailscale_up() {
    local id="$1"
    local output exit_code registration_url

    if ! pct exec "$id" -- sh -c 'command -v tailscale' >/dev/null 2>&1; then
        error "CT $id 未安装 Tailscale，无法执行 tailscale up。"
        return 1
    fi

    if ! start_tailscaled "$id"; then
        return 1
    fi

    info "正在向 CT $id 执行 tailscale up，等待注册链接..."
    if command -v timeout >/dev/null 2>&1; then
        output=$(timeout 30s pct exec "$id" -- tailscale up 2>&1)
        exit_code=$?
    else
        warn "宿主机未找到 timeout，将直接等待 tailscale up 返回。"
        output=$(pct exec "$id" -- tailscale up 2>&1)
        exit_code=$?
    fi

    printf '%s\n' "$output"
    registration_url=$(printf '%s\n' "$output" |
        grep -Eo 'https://login\.tailscale\.com/[A-Za-z0-9._?=&/%-]+' |
        head -n 1 || true)

    if [ -n "$registration_url" ]; then
        echo
        printf "%b\n" "${bold}Tailscale 注册链接：${reset}"
        printf "%s\n" "$registration_url"
        echo
        info "请在浏览器打开上面的链接完成注册。"
        return 0
    fi

    if [ "$exit_code" -eq 124 ]; then
        warn "CT $id：tailscale up 超时，继续流程。"
        show_tailscale_log "$id"
    elif [ "$exit_code" -eq 0 ]; then
        info "CT $id：tailscale up 已完成（当前可能已经注册）。"
    else
        warn "CT $id：tailscale up 失败（退出码：$exit_code）。"
        show_tailscale_log "$id"
    fi
    return 0
}

show_tailscale_log() {
    local id="$1"

    echo "  Tailscale 最后 10 行日志（CT $id）："
    if ! pct exec "$id" -- sh -c '
        if command -v journalctl >/dev/null 2>&1 &&
            journalctl -u tailscaled -n 10 --no-pager 2>/dev/null | grep -q .; then
            journalctl -u tailscaled -n 10 --no-pager
        elif [ -f /var/log/tailscaled.log ]; then
            tail -n 10 /var/log/tailscaled.log
        else
            echo "未找到 tailscaled 日志（journalctl 或 /var/log/tailscaled.log）。"
            exit 1
        fi
    '; then
        warn "CT $id：无法读取 Tailscale 日志"
    fi
}

echo
printf "%b\n" "${bold}=== PVE LXC 快速克隆与初始化 ===${reset}"
if ! select_template; then
    exit 1
fi
echo "模板：$TEMPLATE_ID"
echo

read -r -p "请输入新容器的 CTID（例如 601）： " NEW_ID
if ! [[ "$NEW_ID" =~ ^[0-9]+$ ]] || [ -z "$NEW_ID" ]; then
    error "CTID 必须是数字，且不能为空。"
    exit 1
fi

if pct status "$NEW_ID" >/dev/null 2>&1; then
    error "CTID $NEW_ID 已经被占用。"
    exit 1
fi

read -r -p "请输入新容器名称（例如 LXC-Homepage）： " CT_NAME
if [ -z "$CT_NAME" ]; then
    error "容器名称不能为空。"
    exit 1
fi

echo
echo "即将执行："
echo "  • 从模板 $TEMPLATE_ID 克隆 CT $NEW_ID（$CT_NAME）"
echo "  • 克隆完成后暂停，等待你确认是否开始初始化"
echo

if ! confirm "确认开始克隆？"; then
    echo "已取消，未创建容器。"
    exit 0
fi

echo
echo "[1/3] 正在克隆容器..."
if ! pct clone "$TEMPLATE_ID" "$NEW_ID" --hostname "$CT_NAME" --full 1; then
    error "克隆失败。"
    exit 1
fi
info "CT $NEW_ID 克隆完成。"

echo
printf "%b\n" "${bold}容器已成功克隆，但目前尚未启动。${reset}"
echo "接下来将配置 TUN、启动容器、修复 SSH 并同步宿主机公钥。"
if ! confirm "现在开始执行初始化？"; then
    warn "已保留 CT $NEW_ID，未启动或修改容器。"
    echo "之后可重新运行初始化，或手动执行：pct start $NEW_ID"
    exit 0
fi

echo
echo "[2/4] 正在配置 TUN 并启动容器..."
if ! configure_tun; then
    error "TUN 配置失败，容器尚未启动。"
    exit 1
fi

if ! pct start "$NEW_ID"; then
    error "容器启动失败。"
    exit 1
fi
info "CT $NEW_ID 已启动，等待 5 秒让服务完成初始化..."
sleep 5

# 重启一次，让 PVE 真正把 TUN 节点挂载进容器
info "正在执行物理重启以强制加载 TUN 设备..."
if ! pct reboot "$NEW_ID"; then
    error "容器重启失败。"
    exit 1
fi
info "重启完成后等待 5 秒..."
sleep 5
info "CT $NEW_ID 已成功开机并挂载 TUN。"

echo
echo "[3/4] 正在初始化 SSH..."
ssh_failed=0
repair_ssh "$NEW_ID" || ssh_failed=1
sync_keys "$NEW_ID" || ssh_failed=1

echo
echo "[4/4] 正在启动 Tailscale..."
tailscale_failed=0
run_tailscale_up "$NEW_ID" || tailscale_failed=1

echo
if [ "$ssh_failed" -eq 0 ] && [ "$tailscale_failed" -eq 0 ]; then
    printf "%b\n" "${green}=== CT $NEW_ID（$CT_NAME）创建并初始化完成！ ===${reset}"
else
    printf "%b\n" "${yellow}=== CT $NEW_ID 已创建并启动，但部分初始化存在问题。 ===${reset}"
    echo "请检查上面的错误信息后重试。"
fi