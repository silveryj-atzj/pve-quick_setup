#!/usr/bin/env bash

set -u -o pipefail

bold="\033[1m"
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
cyan="\033[36m"
reset="\033[0m"

ok_count=0
warn_count=0
error_count=0
skip_count=0
modified_count=0
repaired_count=0
ct_tun_issue=0
ct_ssh_issue=0
ct_keys_issue=0
ct_tailscale_issue=0

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    printf "%b\n" "${red}错误：请使用 root 运行此脚本。${reset}" >&2
    exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
    printf "%b\n" "${red}错误：未找到 pct，请在 Proxmox VE 宿主机上运行。${reset}" >&2
    exit 1
fi

ok() {
    ok_count=$((ok_count + 1))
    printf "  %b\n" "${green}✔${reset} $*"
}

warn() {
    warn_count=$((warn_count + 1))
    printf "  %b\n" "${yellow}⚠${reset} $*"
}

error() {
    error_count=$((error_count + 1))
    printf "  %b\n" "${red}✖${reset} $*"
}

info() {
    printf "  %b\n" "${green}✔${reset} $*"
}

skip() {
    skip_count=$((skip_count + 1))
    printf "  %b\n" "${cyan}－${reset} $*"
}

confirm() {
    local answer
    read -r -p "$1 [y/N] " answer
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

show_tun_config() {
    local id="$1"
    local conf_file="/etc/pve/lxc/${id}.conf"
    local existing

    existing="$(grep -ini 'tun' "$conf_file" 2>/dev/null || true)"
    echo
    warn "CT $id：检测到 TUN 相关配置，本脚本不会自动覆盖或清洗。"
    echo "  当前配置（包含 tun 的行）："
    if [ -n "$existing" ]; then
        printf '%s\n' "$existing" | sed 's/^/    /'
    else
        echo "    （未找到，可能是容器内部 TUN 设备缺失）"
    fi
    echo "  本脚本标准配置（仅供对照，不会自动写入）："
    echo "    lxc.cgroup2.devices.allow: c 10:200 rwm"
    echo "    lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file 0 0"
    echo "    dev0: /dev/net/tun"
    warn "CT $id：请确认现有配置的语义后，再由管理员手动调整；TUN 项已跳过自动修补。"
}

repair_running_ct() {
    local id="$1"
    local output

    if ! output=$(pct exec "$id" -- sh -c '
        set -e
        needs_ssh_restart=0

        if ! command -v sshd >/dev/null 2>&1; then
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
                echo "无法识别包管理器，不能安装 OpenSSH。" >&2
                exit 1
            fi
            needs_ssh_restart=1
        fi

        sshd_path="$(command -v sshd)"
        if [ ! -d /run/sshd ] && [ ! -d /var/run/sshd ]; then
            needs_ssh_restart=1
        fi
        if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
            needs_ssh_restart=1
        fi
        mkdir -p /run/sshd /var/run/sshd /root/.ssh
        chmod 0755 /run/sshd /var/run/sshd
        chmod 0700 /root/.ssh
        chown root:root /run/sshd /var/run/sshd /root/.ssh

        if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
            ssh-keygen -A
        fi
        "$sshd_path" -t

        if [ "$needs_ssh_restart" -eq 0 ]; then
            exit 0
        elif command -v systemctl >/dev/null 2>&1 &&
            (systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null); then
            :
        elif command -v service >/dev/null 2>&1 &&
            (service ssh restart 2>/dev/null || service sshd restart 2>/dev/null); then
            :
        else
            "$sshd_path"
        fi
    ' 2>&1); then
        modified_count=$((modified_count + 1))
        info "CT $id：SSH 运行环境已补齐（未改写 sshd_config）"
    else
        error "CT $id：SSH 修补失败：$output"
        return 1
    fi
}

repair_keys() {
    local id="$1"
    local key
    local added_count=0

    if [ ! -f "/root/.ssh/authorized_keys" ]; then
        warn "宿主机缺少 /root/.ssh/authorized_keys，CT $id 跳过公钥补充"
        return 1
    fi

    if ! pct exec "$id" -- sh -c '
        mkdir -p /root/.ssh
        touch /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
    '; then
        error "CT $id：无法准备 /root/.ssh/authorized_keys"
        return 1
    fi

    while IFS= read -r key || [ -n "$key" ]; do
        case "$key" in
            ""|\#*) continue ;;
        esac
        if ! pct exec "$id" -- grep -qF -- "$key" /root/.ssh/authorized_keys 2>/dev/null; then
            if printf '%s\n' "$key" | pct exec "$id" -- tee -a /root/.ssh/authorized_keys >/dev/null; then
                added_count=$((added_count + 1))
            else
                error "CT $id：追加公钥失败"
                return 1
            fi
        fi
    done < /root/.ssh/authorized_keys

    if [ "$added_count" -gt 0 ]; then
        modified_count=$((modified_count + 1))
    fi
    info "CT $id：公钥仅追加缺失项，共新增 $added_count 个 Key"
}

repair_tailscale() {
    local id="$1"

    if ! pct exec "$id" -- sh -c 'command -v tailscale >/dev/null 2>&1 &&
        command -v tailscaled >/dev/null 2>&1'; then
        return
    fi
    if pct exec "$id" -- tailscale status >/dev/null 2>&1; then
        return
    fi

    if pct exec "$id" -- sh -c '
        if command -v systemctl >/dev/null 2>&1 &&
            (systemctl start tailscaled 2>/dev/null || systemctl restart tailscaled 2>/dev/null); then
            exit 0
        elif command -v service >/dev/null 2>&1 &&
            (service tailscaled start 2>/dev/null || service tailscale start 2>/dev/null); then
            exit 0
        elif command -v rc-service >/dev/null 2>&1 &&
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
        modified_count=$((modified_count + 1))
        info "CT $id：tailscaled 已启动"
    else
        error "CT $id：tailscaled 启动失败，请检查容器日志"
        return 1
    fi
}

run_tailscale_up() {
    local id="$1"
    local output exit_code registration_url

    if ! pct exec "$id" -- sh -c 'command -v tailscale >/dev/null 2>&1'; then
        warn "CT $id：未安装 Tailscale，跳过 tailscale up"
        return
    fi

    echo "  → CT $id：执行 tailscale up..."
    if command -v timeout >/dev/null 2>&1; then
        output=$(timeout 30s pct exec "$id" -- tailscale up 2>&1)
        exit_code=$?
    else
        output=$(pct exec "$id" -- tailscale up 2>&1)
        exit_code=$?
    fi

    registration_url=$(printf '%s\n' "$output" |
        grep -Eo 'https://login\.tailscale\.com/[A-Za-z0-9._?=&/%-]+' |
        head -n 1 || true)

    if [ -n "$registration_url" ]; then
        modified_count=$((modified_count + 1))
        printf "%b\n" "${bold}  Tailscale 注册链接（CT $id）：${reset}"
        printf "  %s\n" "$registration_url"
    elif [ "$exit_code" -eq 0 ]; then
        modified_count=$((modified_count + 1))
        info "CT $id：tailscale up 已完成（当前可能已经注册）"
    elif [ "$exit_code" -eq 124 ]; then
        warn "CT $id：tailscale up 超时，继续检查下一个 CT"
        show_tailscale_log "$id"
    else
        warn "CT $id：tailscale up 失败（退出码：$exit_code），继续检查下一个 CT"
        show_tailscale_log "$id"
    fi

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

repair_ct() {
    local id="$1"
    local status="$2"
    local repair_status=0

    if [ "$status" != "running" ]; then
        return
    fi

    if [ "$ct_ssh_issue" -eq 1 ]; then
        if ! repair_running_ct "$id"; then
            repair_status=1
        fi
    fi
    if [ "$ct_keys_issue" -eq 1 ]; then
        if ! repair_keys "$id"; then
            repair_status=1
        fi
    fi
    if [ "$ct_tailscale_issue" -eq 1 ]; then
        if ! repair_tailscale "$id"; then
            repair_status=1
        fi
        if ! run_tailscale_up "$id"; then
            repair_status=1
        fi
    fi
    return "$repair_status"
}

start_ct_for_check() {
    local id="$1"

    if confirm "CT $id 当前未运行，是否启动后继续检测？"; then
        if pct start "$id"; then
            info "CT $id：已启动，继续进行容器内部检测"
            return 0
        fi
        error "CT $id：启动失败，跳过容器内部检测"
    else
        skip "CT $id：用户选择不启动，跳过容器内部检测"
    fi
    return 1
}

check_running_ct() {
    local id="$1"
    local result key value

    if result=$(pct exec "$id" -- sh -c '
        has_command() {
            command -v "$1" >/dev/null 2>&1
        }

        if has_command sshd; then
            echo "sshd=present"
            sshd_path="$(command -v sshd)"
            if [ -x "$sshd_path" ]; then
                echo "sshd_executable=yes"
            else
                echo "sshd_executable=no"
            fi
            if "$sshd_path" -t >/dev/null 2>&1; then
                echo "sshd_config=valid"
            else
                echo "sshd_config=invalid"
            fi
        else
            echo "sshd=missing"
        fi

        if command -v pgrep >/dev/null 2>&1; then
            if pgrep -x sshd >/dev/null 2>&1; then
                echo "sshd_running=yes"
            else
                echo "sshd_running=no"
            fi
        elif ps 2>/dev/null | grep -q '[s]shd'; then
            echo "sshd_running=yes"
        else
            echo "sshd_running=no"
        fi

        if [ -d /run/sshd ] || [ -d /var/run/sshd ]; then
            echo "sshd_runtime=present"
        else
            echo "sshd_runtime=missing"
        fi

        if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
            echo "ssh_host_keys=present"
        else
            echo "ssh_host_keys=missing"
        fi

        if [ -s /root/.ssh/authorized_keys ]; then
            echo "authorized_keys=present"
        else
            echo "authorized_keys=missing"
        fi

        if [ -c /dev/net/tun ]; then
            echo "tun_device=present"
        else
            echo "tun_device=missing"
        fi

        if has_command tailscale; then
            echo "tailscale=present"
            if has_command tailscaled; then
                echo "tailscaled=present"
            else
                echo "tailscaled=missing"
            fi
            if command -v timeout >/dev/null 2>&1 &&
                timeout 5s tailscale status >/dev/null 2>&1; then
                echo "tailscale_status=connected"
            elif ! command -v timeout >/dev/null 2>&1 &&
                tailscale status >/dev/null 2>&1; then
                echo "tailscale_status=connected"
            else
                echo "tailscale_status=not_connected"
            fi
        else
            echo "tailscale=missing"
        fi
    ' 2>&1); then
        while IFS='=' read -r key value; do
            case "$key" in
                sshd)
                    if [ "$value" = "present" ]; then
                        ok "OpenSSH 服务端已安装"
                    else
                        ct_ssh_issue=1
                        error "缺少 OpenSSH 服务端（sshd）"
                    fi
                    ;;
                sshd_executable)
                    if [ "$value" = "yes" ]; then
                        ok "sshd 可执行文件正常"
                    else
                        ct_ssh_issue=1
                        error "sshd 文件不可执行"
                    fi
                    ;;
                sshd_config)
                    if [ "$value" = "valid" ]; then
                        ok "sshd 配置检查通过"
                    else
                        ct_ssh_issue=1
                        error "sshd 配置检查失败"
                    fi
                    ;;
                sshd_running)
                    if [ "$value" = "yes" ]; then
                        ok "sshd 进程正在运行"
                    else
                        ct_ssh_issue=1
                        warn "sshd 进程未运行"
                    fi
                    ;;
                sshd_runtime)
                    if [ "$value" = "present" ]; then
                        ok "SSH privilege separation 目录存在"
                    else
                        ct_ssh_issue=1
                        warn "缺少 /run/sshd 或 /var/run/sshd"
                    fi
                    ;;
                ssh_host_keys)
                    if [ "$value" = "present" ]; then
                        ok "SSH Host keys 已生成"
                    else
                        ct_ssh_issue=1
                        warn "缺少 SSH Host keys"
                    fi
                    ;;
                authorized_keys)
                    if [ "$value" = "present" ]; then
                        ok "root authorized_keys 存在"
                    else
                        ct_keys_issue=1
                        warn "root authorized_keys 为空或不存在"
                    fi
                    ;;
                tun_device)
                    if [ "$value" = "present" ]; then
                        ok "TUN 设备可用"
                    else
                        ct_tun_issue=1
                        error "容器内缺少 /dev/net/tun"
                    fi
                    ;;
                tailscale)
                    if [ "$value" = "present" ]; then
                        ok "Tailscale 客户端已安装"
                    else
                        ct_tailscale_issue=1
                        warn "未安装 Tailscale 客户端"
                    fi
                    ;;
                tailscaled)
                    if [ "$value" = "present" ]; then
                        ok "tailscaled 已安装"
                    else
                        ct_tailscale_issue=1
                        warn "未安装 tailscaled"
                    fi
                    ;;
                tailscale_status)
                    if [ "$value" = "connected" ]; then
                        ok "Tailscale 当前已连接"
                    else
                        ct_tailscale_issue=1
                        warn "Tailscale 未连接或 tailscaled 未运行"
                    fi
                    ;;
            esac
        done <<< "$result"
        return 0
    fi

    error "无法进入 CT $id 检查容器内部状态：$result"
}

echo
printf "%b\n" "${bold}=== PVE LXC 全量状态检查（只读） ===${reset}"
echo "初始检查阶段为只读；每个 CT 发现问题后会询问是否修补。"
echo

ct_ids=()
if ! pct_list="$(pct list)"; then
    error "无法获取 LXC 容器列表"
    exit 1
fi
while IFS= read -r id; do
    [ -n "$id" ] && ct_ids+=("$id")
done < <(printf '%s\n' "$pct_list" | awk 'NR > 1 {print $1}')

if [ "${#ct_ids[@]}" -eq 0 ]; then
    warn "当前节点没有检测到 LXC 容器。"
    exit 0
fi

for id in "${ct_ids[@]}"; do
    conf_file="/etc/pve/lxc/${id}.conf"
    hostname="$(pct config "$id" 2>/dev/null | awk -F': ' '$1 == "hostname" {print $2; exit}')"
    status="$(pct status "$id" 2>/dev/null | awk -F': ' '$1 == "status" {print $2; exit}')"
    ct_tun_issue=0
    ct_ssh_issue=0
    ct_keys_issue=0
    ct_tailscale_issue=0

    if grep -Eq '^template:[[:space:]]*1[[:space:]]*$' "$conf_file" 2>/dev/null; then
        printf "%b\n" "${cyan}[CT $id${hostname:+ / $hostname}] 模板，跳过运行时检查${reset}"
        continue
    fi

    echo
    printf "%b\n" "${bold}[CT $id${hostname:+ / $hostname}] 状态：${status:-unknown}${reset}"

    tun_lines="$(grep -ini 'tun' "$conf_file" 2>/dev/null || true)"
    if [ -z "$tun_lines" ]; then
        ct_tun_issue=1
        warn "CT $id：未检测到 TUN 配置；建议对照标准配置手动确认"
    elif (grep -Eq '^[[:space:]]*lxc\.cgroup2\.devices\.allow:[[:space:]]*c[[:space:]]+10:200[[:space:]]+rwm[[:space:]]*$' "$conf_file" &&
        grep -Eq '^[[:space:]]*lxc\.mount\.entry:[[:space:]]*/dev/net/tun[[:space:]]+dev/net/tun[[:space:]]+none[[:space:]]+bind,create=file([[:space:]]+0[[:space:]]+0)?[[:space:]]*$' "$conf_file") ||
        grep -Eq '^[[:space:]]*dev[0-9]+:[[:space:]]*/dev/net/tun([[:space:]]|,|$)' "$conf_file"; then
        ok "TUN 配置符合脚本标准，未发现需要调整的配置"
    else
        ct_tun_issue=1
        show_tun_config "$id"
    fi

    runtime_warn_before=0
    runtime_error_before=0
    if [ "$status" = "running" ]; then
        runtime_warn_before=$warn_count
        runtime_error_before=$error_count
        check_running_ct "$id"
    elif [ "$status" = "stopped" ]; then
        if start_ct_for_check "$id"; then
            status="running"
            runtime_warn_before=$warn_count
            runtime_error_before=$error_count
            check_running_ct "$id"
        fi
    else
        skip "CT 状态为 ${status:-unknown}，无法安全启动，跳过容器内部检测"
    fi

    if [ "$ct_ssh_issue" -eq 1 ] || [ "$ct_keys_issue" -eq 1 ] ||
        [ "$ct_tailscale_issue" -eq 1 ]; then
        echo
        if confirm "CT $id 检查完成，是否修补 CT 发现的问题？"; then
            runtime_warn_issues=$((warn_count - runtime_warn_before))
            runtime_error_issues=$((error_count - runtime_error_before))
            if repair_ct "$id" "$status"; then
                warn_count=$((warn_count - runtime_warn_issues))
                error_count=$((error_count - runtime_error_issues))
                repaired_count=$((repaired_count + runtime_warn_issues + runtime_error_issues))
            fi
        else
            echo "已跳过 CT $id 修补，继续检查下一个 CT。"
        fi
    fi
done

echo
printf "%b\n" "${bold}=== 检查汇总 ===${reset}"
printf "正常：%d  | 警告：%d  | 缺失/错误：%d  | 已修补：%d  | 跳过：%d\n" \
    "$ok_count" "$warn_count" "$error_count" "$repaired_count" "$skip_count"
if [ "$repaired_count" -gt 0 ]; then
    echo "本次运行已将已成功修补的运行时问题计入“已修补”，未继续计入警告或错误。"
fi
if [ "$error_count" -gt 0 ]; then
    echo "部分 CT 存在缺失或错误；未确认修补的项目保持不变。"
elif [ "$warn_count" -gt 0 ] && [ "$modified_count" -eq 0 ]; then
    echo "存在需要关注的警告；本脚本未修改任何内容。"
elif [ "$warn_count" -gt 0 ]; then
    echo "存在需要关注的警告；本次运行已完成部分修补。"
fi

if [ "$error_count" -gt 0 ]; then
    exit 1
fi
exit 0