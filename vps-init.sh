#!/usr/bin/env bash
#
# VPS 小白友好初始化脚本
# Version: 1.0.1
#
# 设计目标：
# - 面向 VPS 新手，中文交互，所有重要操作先预览再确认。
# - 优先保证 SSH 不锁机。
# - 可重复运行，尽量只撤销本脚本明确管理的配置。

# 交互式脚本不启用 set -e：很多“条件为否”是正常交互分支。
# 关键命令均在对应模块内显式检查返回值，避免严格模式导致静默退出。
set -Euo pipefail
IFS=$' \t\n'

SCRIPT_VERSION="1.0.1"
STATE_VERSION="1"

STATE_DIR="/var/lib/vps-init"
STATE_FILE="$STATE_DIR/state.env"
BACKUP_DIR="/var/backups/vps-init"
LOG_FILE="/var/log/vps-init.log"
LOCK_DIR="/var/lock/vps-init.lock"

SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSH_DROPIN_FILE="$SSH_DROPIN_DIR/99-vps-init.conf"
SSH_MAIN_CONFIG="/etc/ssh/sshd_config"
SSH_KEY_BEGIN="# BEGIN VPS-INIT SSH KEY"
SSH_KEY_END="# END VPS-INIT SSH KEY"

F2B_FILE="/etc/fail2ban/jail.d/99-vps-init.conf"
BBR_FILE="/etc/sysctl.d/99-vps-init-bbr.conf"

OS_ID=""
OS_VERSION_ID=""
OS_FAMILY="unknown"
PKG_MANAGER=""
ARCH_RAW=""
ARCH_FAMILY="unknown"
HAS_SYSTEMD=0
SSH_SERVICE=""
FIREWALL_BACKEND="none"
SELINUX_STATUS="disabled"
VIRT_TYPE="unknown"
MEM_TOTAL_MB=0
MEM_AVAILABLE_MB=0
SWAP_TOTAL_MB=0
DISK_FREE_MB=0
TMP_FREE_MB=0
CPU_CORES=1
LOAD_AVG="unknown"
DEFAULT_IPV4=""
PUBLIC_IPV4=""
NAT_MODE=0
IPV6_AVAILABLE=0
SSH_PORTS="22"
SSH_PASSWORD_AUTH="unknown"
SSH_ROOT_LOGIN="unknown"
SSH_MATCH_PRESENT=0
APT_UPDATED=0
RUN_REPORT=()

color_red() { printf '\033[31m%s\033[0m\n' "$*"; }
color_green() { printf '\033[32m%s\033[0m\n' "$*"; }
color_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
color_blue() { printf '\033[34m%s\033[0m\n' "$*"; }

say() { printf '%s\n' "$*"; }
info() { color_blue "ℹ $*"; log "INFO" "$*"; }
ok() { color_green "✅ $*"; log "OK" "$*"; }
warn() { color_yellow "⚠ $*"; log "WARN" "$*"; }
fail() { color_red "❌ $*"; log "ERROR" "$*"; }

log() {
  local level="$1"
  shift || true
  local msg="$*"
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
  if [ -w "$(dirname "$LOG_FILE")" ] || touch "$LOG_FILE" 2>/dev/null; then
    printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$msg" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

add_report() {
  RUN_REPORT+=("$*")
  log "REPORT" "$*"
}

pause() {
  printf '\n按回车继续...'
  read -r _ || true
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    fail "请使用 root 权限运行本脚本。"
    say
    say "请执行："
    say "  sudo bash vps-init.sh"
    exit 1
  fi
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "检测到另一个 vps-init 实例正在运行：$LOCK_DIR"
    say "如果你确认没有脚本在运行，可以手动删除该目录后重试。"
    exit 1
  fi
  trap 'release_lock' EXIT
}

release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

init_storage() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 700 "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
  if [ ! -f "$STATE_FILE" ]; then
    {
      echo "SCRIPT_VERSION=$SCRIPT_VERSION"
      echo "STATE_VERSION=$STATE_VERSION"
    } >"$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
  fi
}

load_state_value() {
  local key="$1"
  if [ -f "$STATE_FILE" ]; then
    awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; found=1 } END { if (!found) exit 1 }' "$STATE_FILE" 2>/dev/null || true
  fi
}

set_state_value() {
  local key="$1"
  local value="$2"
  mkdir -p "$STATE_DIR"
  touch "$STATE_FILE"
  chmod 600 "$STATE_FILE" 2>/dev/null || true
  local tmp
  tmp="$(mktemp)"
  if grep -qE "^${key}=" "$STATE_FILE" 2>/dev/null; then
    awk -F= -v k="$key" -v v="$value" 'BEGIN{OFS="="} $1==k {$0=k"="v} {print}' "$STATE_FILE" >"$tmp"
  else
    cat "$STATE_FILE" >"$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$STATE_FILE"
}

append_state_list() {
  local key="$1"
  local item="$2"
  local current
  current="$(load_state_value "$key")"
  case " $current " in
    *" $item "*) return 0 ;;
  esac
  set_state_value "$key" "${current:+$current }$item"
}

backup_file() {
  local file="$1"
  [ -e "$file" ] || return 0
  local base dest
  base="$(basename "$file")"
  dest="$BACKUP_DIR/${base}.bak_$(date '+%Y%m%d_%H%M%S')"
  cp -a "$file" "$dest"
  log "INFO" "备份 $file 到 $dest"
}

confirm_action() {
  local prompt="${1:-确认执行？}"
  local default="${2:-yes}"
  local hint
  if [ "$default" = "yes" ]; then
    hint="【是 y / 否 n / 0 返回 / 回车默认：是】"
  else
    hint="【是 y / 否 n / 0 返回 / 回车默认：否】"
  fi
  local ans
  while true; do
    printf '%s%s: ' "$prompt" "$hint"
    read -r ans || ans=""
    if [ -z "$ans" ]; then
      [ "$default" = "yes" ] && return 0 || return 1
    fi
    case "$ans" in
      0) warn "已返回上一级。"; return 1 ;;
      y|Y|yes|YES|Yes|yES|是) return 0 ;;
      n|N|no|NO|No|nO|否) return 1 ;;
      *) say "请输入 y/yes/是、n/no/否，或 0 返回；直接回车使用默认值。" ;;
    esac
  done
}

danger_confirm() {
  local prompt="$1"
  local ans
  say
  color_yellow "危险操作：$prompt"
  say "如果你确认继续，请输入完整 yes 或 是。输入 0 返回上一级；回车、y、Y 都不会继续。"
  printf '请输入 yes / 是 / 0: '
  read -r ans || ans=""
  case "$ans" in
    yes|YES|Yes|yES|是) return 0 ;;
    0) warn "已返回上一级。"; return 1 ;;
    *) warn "已取消危险操作。"; return 1 ;;
  esac
}

read_nonempty() {
  local prompt="$1"
  local value
  while true; do
    printf '%s' "$prompt" >&2
    read -r value || value=""
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
    say "输入不能为空，请重新输入。" >&2
  done
}

is_private_ipv4() {
  local ip="$1"
  case "$ip" in
    10.*|192.168.*) return 0 ;;
    172.*)
      local second
      second="$(printf '%s' "$ip" | cut -d. -f2)"
      [ "$second" -ge 16 ] 2>/dev/null && [ "$second" -le 31 ] 2>/dev/null && return 0
      ;;
    100.*)
      local second
      second="$(printf '%s' "$ip" | cut -d. -f2)"
      [ "$second" -ge 64 ] 2>/dev/null && [ "$second" -le 127 ] 2>/dev/null && return 0
      ;;
  esac
  return 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
  fi

  case "$OS_ID" in
    debian|ubuntu) OS_FAMILY="debian" ;;
    rhel|centos|rocky|almalinux|fedora|ol) OS_FAMILY="rhel" ;;
    *) OS_FAMILY="unknown" ;;
  esac

  if command_exists apt-get; then
    PKG_MANAGER="apt"
  elif command_exists dnf; then
    PKG_MANAGER="dnf"
  elif command_exists yum; then
    PKG_MANAGER="yum"
  else
    PKG_MANAGER="unknown"
  fi

  ARCH_RAW="$(uname -m 2>/dev/null || echo unknown)"
  case "$ARCH_RAW" in
    x86_64|amd64) ARCH_FAMILY="amd64" ;;
    aarch64|arm64) ARCH_FAMILY="arm64" ;;
    *) ARCH_FAMILY="unsupported" ;;
  esac

  if command_exists systemctl && [ -d /run/systemd/system ]; then
    HAS_SYSTEMD=1
  else
    HAS_SYSTEMD=0
  fi
  return 0
}

detect_hardware() {
  MEM_TOTAL_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  MEM_AVAILABLE_MB="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  SWAP_TOTAL_MB="$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  DISK_FREE_MB="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
  TMP_FREE_MB="$(df -Pm /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
  CPU_CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  LOAD_AVG="$(awk '{print $1","$2","$3}' /proc/loadavg 2>/dev/null || echo unknown)"

  if command_exists systemd-detect-virt; then
    VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo none)"
  elif [ -f /proc/user_beancounters ]; then
    VIRT_TYPE="openvz"
  else
    VIRT_TYPE="unknown"
  fi
  return 0
}

hardware_tier() {
  if [ "$MEM_TOTAL_MB" -lt 256 ]; then
    echo "极低配"
  elif [ "$MEM_TOTAL_MB" -lt 512 ]; then
    echo "低配"
  elif [ "$MEM_TOTAL_MB" -lt 1024 ]; then
    echo "标准"
  else
    echo "完整"
  fi
}

detect_network() {
  DEFAULT_IPV4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  if ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
    IPV6_AVAILABLE=1
  else
    IPV6_AVAILABLE=0
  fi

  PUBLIC_IPV4=""
  if command_exists curl; then
    PUBLIC_IPV4="$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  elif command_exists wget; then
    PUBLIC_IPV4="$(wget -4 -qO- --timeout=3 https://api.ipify.org 2>/dev/null || true)"
  fi

  NAT_MODE=0
  if [ -n "$DEFAULT_IPV4" ] && is_private_ipv4 "$DEFAULT_IPV4"; then
    NAT_MODE=1
  fi
  if [ -n "$PUBLIC_IPV4" ] && [ -n "$DEFAULT_IPV4" ] && [ "$PUBLIC_IPV4" != "$DEFAULT_IPV4" ]; then
    NAT_MODE=1
  fi
  local saved_nat
  saved_nat="$(load_state_value NAT_MODE)"
  [ "$saved_nat" = "1" ] && NAT_MODE=1
  return 0
}

detect_selinux() {
  if command_exists getenforce; then
    SELINUX_STATUS="$(getenforce 2>/dev/null || echo disabled)"
  elif [ -e /sys/fs/selinux/enforce ]; then
    if [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = "1" ]; then
      SELINUX_STATUS="Enforcing"
    else
      SELINUX_STATUS="Permissive"
    fi
  else
    SELINUX_STATUS="disabled"
  fi
  return 0
}

detect_ssh() {
  SSH_SERVICE=""
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    if systemctl list-unit-files sshd.service >/dev/null 2>&1; then
      SSH_SERVICE="sshd"
    elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then
      SSH_SERVICE="ssh"
    fi
  fi
  if [ -z "$SSH_SERVICE" ]; then
    if [ -x /etc/init.d/sshd ]; then
      SSH_SERVICE="sshd"
    elif [ -x /etc/init.d/ssh ]; then
      SSH_SERVICE="ssh"
    else
      SSH_SERVICE="sshd"
    fi
  fi

  SSH_PORTS="22"
  SSH_PASSWORD_AUTH="unknown"
  SSH_ROOT_LOGIN="unknown"
  if command_exists sshd; then
    local output
    output="$(sshd -T 2>/dev/null || true)"
    SSH_PORTS="$(printf '%s\n' "$output" | awk '$1=="port"{print $2}' | sort -n | xargs 2>/dev/null || true)"
    [ -z "$SSH_PORTS" ] && SSH_PORTS="22"
    SSH_PASSWORD_AUTH="$(printf '%s\n' "$output" | awk '$1=="passwordauthentication"{print $2; exit}')"
    SSH_ROOT_LOGIN="$(printf '%s\n' "$output" | awk '$1=="permitrootlogin"{print $2; exit}')"
    [ -z "$SSH_PASSWORD_AUTH" ] && SSH_PASSWORD_AUTH="unknown"
    [ -z "$SSH_ROOT_LOGIN" ] && SSH_ROOT_LOGIN="unknown"
  elif [ -r "$SSH_MAIN_CONFIG" ]; then
    SSH_PORTS="$(awk 'tolower($1)=="port"{print $2}' "$SSH_MAIN_CONFIG" | sort -n | xargs 2>/dev/null || true)"
    [ -z "$SSH_PORTS" ] && SSH_PORTS="22"
  fi

  SSH_MATCH_PRESENT=0
  if [ -r "$SSH_MAIN_CONFIG" ] && grep -Eiq '^[[:space:]]*Match[[:space:]]+' "$SSH_MAIN_CONFIG"; then
    SSH_MATCH_PRESENT=1
  fi
  return 0
}

detect_firewall() {
  FIREWALL_BACKEND="none"
  if command_exists ufw; then
    FIREWALL_BACKEND="ufw"
  elif command_exists firewall-cmd; then
    FIREWALL_BACKEND="firewalld"
  elif command_exists nft; then
    FIREWALL_BACKEND="nftables"
  elif command_exists iptables; then
    FIREWALL_BACKEND="iptables"
  fi
  return 0
}

refresh_detection() {
  detect_os
  detect_hardware
  detect_network
  detect_selinux
  detect_ssh
  detect_firewall
  return 0
}

print_header() {
  clear 2>/dev/null || true
  say "=========================================="
  say "        VPS 小白友好初始化脚本"
  say "              v$SCRIPT_VERSION"
  say "=========================================="
}

show_system_brief() {
  local tier
  tier="$(hardware_tier)"
  say "系统：$OS_ID $OS_VERSION_ID ($OS_FAMILY) | 架构：$ARCH_RAW ($ARCH_FAMILY)"
  say "资源：${MEM_TOTAL_MB}MB RAM（可用 ${MEM_AVAILABLE_MB}MB）/ ${SWAP_TOTAL_MB}MB Swap / ${CPU_CORES} vCPU / 根分区可用 ${DISK_FREE_MB}MB / 负载 ${LOAD_AVG} | 档位：$tier"
  say "网络：默认 IPv4=${DEFAULT_IPV4:-未知} 公网 IPv4=${PUBLIC_IPV4:-未知} IPv6=$([ "$IPV6_AVAILABLE" -eq 1 ] && echo 可用 || echo 未检测到) NAT=$([ "$NAT_MODE" -eq 1 ] && echo 疑似NAT || echo 未检测到)"
  say "SSH：服务=$SSH_SERVICE 端口=[$SSH_PORTS] 密码登录=$SSH_PASSWORD_AUTH Root登录=$SSH_ROOT_LOGIN"
  say "防火墙：$FIREWALL_BACKEND | SELinux：$SELINUX_STATUS | 虚拟化：$VIRT_TYPE"
  [ "$SSH_MATCH_PRESENT" -eq 1 ] && warn "检测到 sshd_config 中存在 Match 块，最终策略可能因用户或来源 IP 不同。"
  return 0
}

print_preview() {
  local title="$1"
  local packages="${2:-无}"
  local files="${3:-无}"
  local ports="${4:-无}"
  local services="${5:-无}"
  local impacts="${6:-无}"
  local reversible="${7:-部分可撤销}"
  local ssh_risk="${8:-通常不影响当前 SSH 连接}"
  say
  color_blue "========== 执行预览：$title =========="
  say "将安装/检查依赖：$packages"
  say "将写入/修改/删除文件：$files"
  say "将新增/移除端口规则：$ports"
  say "将重启/启用服务：$services"
  say "关联影响/提醒：$impacts"
  say "撤销能力：$reversible"
  say "SSH 连接风险：$ssh_risk"
  say "=========================================="
}

network_precheck() {
  local bad=0
  if ! getent hosts deb.debian.org >/dev/null 2>&1 && ! getent hosts mirrors.rockylinux.org >/dev/null 2>&1 && ! getent hosts google.com >/dev/null 2>&1; then
    warn "DNS 解析可能不可用，安装包可能失败。"
    bad=1
  fi
  if [ "$DISK_FREE_MB" -gt 0 ] && [ "$DISK_FREE_MB" -lt 500 ]; then
    warn "根分区可用空间低于 500MB，安装包可能失败。"
    bad=1
  fi
  if [ "$TMP_FREE_MB" -gt 0 ] && [ "$TMP_FREE_MB" -lt 100 ]; then
    warn "/tmp 可用空间低于 100MB，部分安装或生成操作可能失败。"
    bad=1
  fi
  return "$bad"
}

package_installed() {
  local pkg="$1"
  case "$PKG_MANAGER" in
    apt) dpkg -s "$pkg" >/dev/null 2>&1 ;;
    dnf|yum) rpm -q "$pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

map_package() {
  local pkg="$1"
  case "$OS_FAMILY:$pkg" in
    debian:openssh-server) echo "openssh-server" ;;
    rhel:openssh-server) echo "openssh-server" ;;
    debian:cron) echo "cron" ;;
    rhel:cron) echo "cronie" ;;
    debian:dnsutils) echo "dnsutils" ;;
    rhel:dnsutils) echo "bind-utils" ;;
    debian:net-tools) echo "net-tools" ;;
    rhel:net-tools) echo "net-tools" ;;
    debian:policycoreutils-python-utils) echo "policycoreutils-python-utils" ;;
    rhel:policycoreutils-python-utils) echo "policycoreutils-python-utils" ;;
    debian:unattended-upgrades) echo "unattended-upgrades" ;;
    rhel:unattended-upgrades) echo "dnf-automatic" ;;
    *) echo "$pkg" ;;
  esac
}

missing_packages() {
  local result=()
  local pkg mapped
  for pkg in "$@"; do
    mapped="$(map_package "$pkg")"
    [ -z "$mapped" ] && continue
    if ! package_installed "$mapped"; then
      result+=("$mapped")
    fi
  done
  printf '%s\n' "${result[@]}" | awk 'NF && !seen[$0]++' | xargs 2>/dev/null || true
}

package_manager_busy() {
  pgrep -x apt >/dev/null 2>&1 && return 0
  pgrep -x apt-get >/dev/null 2>&1 && return 0
  pgrep -x dpkg >/dev/null 2>&1 && return 0
  pgrep -x dnf >/dev/null 2>&1 && return 0
  pgrep -x yum >/dev/null 2>&1 && return 0
  return 1
}

install_packages() {
  local packages=("$@")
  [ "${#packages[@]}" -eq 0 ] && return 0

  if [ "$PKG_MANAGER" = "unknown" ]; then
    fail "未识别包管理器，无法自动安装依赖。"
    return 1
  fi

  if package_manager_busy; then
    fail "检测到包管理器正在运行或被锁定，请稍后重试。"
    return 1
  fi

  network_precheck || warn "环境预检查存在风险，但你仍可选择继续。"

  say "准备安装依赖：${packages[*]}"
  if ! confirm_action "是否安装这些依赖？" "yes"; then
    warn "用户取消依赖安装。"
    return 1
  fi

  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      if [ "$APT_UPDATED" -eq 0 ]; then
        info "正在更新 apt 软件源索引..."
        if ! apt-get update; then
          fail "apt-get update 失败。"
          return 1
        fi
        APT_UPDATED=1
      fi
      if ! apt-get install -y --no-install-recommends "${packages[@]}"; then
        fail "apt 安装依赖失败。"
        return 1
      fi
      ;;
    dnf)
      if ! dnf install -y --setopt=install_weak_deps=False "${packages[@]}"; then
        fail "dnf 安装依赖失败。"
        return 1
      fi
      ;;
    yum)
      if ! yum install -y "${packages[@]}"; then
        fail "yum 安装依赖失败。"
        return 1
      fi
      ;;
  esac
  ok "依赖安装完成。"
}

ensure_packages() {
  local needed
  needed="$(missing_packages "$@")"
  if [ -n "$needed" ]; then
    # shellcheck disable=SC2206
    local arr=($needed)
    install_packages "${arr[@]}"
  fi
}

restart_service() {
  local svc="$1"
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    systemctl restart "$svc"
  else
    service "$svc" restart
  fi
}

enable_service() {
  local svc="$1"
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    systemctl enable --now "$svc"
  else
    service "$svc" start
  fi
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]
}

select_target_user() {
  local default_user="${SUDO_USER:-root}"
  say "请输入要配置的 Linux 用户名。输入 0 返回上一级。" >&2
  say "默认：$default_user" >&2
  printf '用户名: ' >&2
  local user
  read -r user || user=""
  [ "$user" = "0" ] && return 1
  user="${user:-$default_user}"
  if ! id "$user" >/dev/null 2>&1; then
    color_red "❌ 用户不存在：$user" >&2
    return 1
  fi
  printf '%s\n' "$user"
}

user_home() {
  getent passwd "$1" | cut -d: -f6
}

user_group() {
  id -gn "$1"
}

valid_ssh_pubkey() {
  local key="$1"
  [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]
}

authorized_keys_path() {
  local user="$1"
  local home
  home="$(user_home "$user")"
  printf '%s/.ssh/authorized_keys\n' "$home"
}

prepare_ssh_dir() {
  local user="$1"
  local home group
  home="$(user_home "$user")"
  group="$(user_group "$user")"
  mkdir -p "$home/.ssh"
  chmod 700 "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
  chown -R "$user:$group" "$home/.ssh"
}

remove_managed_key_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v begin="$SSH_KEY_BEGIN" -v end="$SSH_KEY_END" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

write_managed_key() {
  local user="$1"
  local key="$2"
  prepare_ssh_dir "$user"
  local auth group
  auth="$(authorized_keys_path "$user")"
  group="$(user_group "$user")"
  if grep -Fxq -- "$key" "$auth" 2>/dev/null; then
    ok "该公钥已经存在，无需重复写入。"
  else
    remove_managed_key_block "$auth"
    {
      echo "$SSH_KEY_BEGIN"
      echo "$key"
      echo "$SSH_KEY_END"
    } >>"$auth"
    ok "公钥已写入 $user 的 authorized_keys。"
  fi
  chmod 600 "$auth"
  chown "$user:$group" "$auth"
  set_state_value "SSH_KEY_USER" "$user"
  set_state_value "SSH_KEY_MANAGED" "1"
  add_report "已配置 SSH key 登录：用户 $user"
}

ssh_key_paste() {
  local user="$1"
  say "请粘贴你的 .pub 公钥内容。"
  say "示例开头：ssh-ed25519 或 ssh-rsa"
  local key
  key="$(read_nonempty "公钥: ")"
  if ! valid_ssh_pubkey "$key"; then
    fail "公钥格式看起来不正确，已取消。"
    return 1
  fi
  print_preview "写入 SSH 公钥" "openssh-server" "$(authorized_keys_path "$user")" "无" "无" "将允许用户 $user 使用该 key 登录" "可通过撤销菜单删除脚本管理的 key" "不影响当前 SSH 连接"
  confirm_action "是否写入该公钥？" "yes" || return 0
  ensure_packages openssh-server || return 1
  write_managed_key "$user" "$key"
}

ssh_key_generate_on_vps() {
  local user="$1"
  local key_dir="/root/vps-init-keys"
  local key_file
  key_file="$key_dir/id_ed25519_vps_init_$(date '+%Y%m%d_%H%M%S')"

  print_preview "VPS 临时生成 SSH keypair" "openssh-server" "$key_file, $(authorized_keys_path "$user")" "无" "无" "私钥会短暂保存在 VPS；请保存到本地后删除 VPS 副本" "公钥可撤销；私钥删除后不可恢复" "不影响当前 SSH 连接"
  say "安全提示：更推荐在你自己的电脑生成 key 后粘贴公钥。"
  say "如果继续，私钥可能被终端日志、服务商面板记录或录屏泄露。"
  danger_confirm "在 VPS 上临时生成并展示 SSH 私钥" || return 0

  ensure_packages openssh-server || return 1
  mkdir -p "$key_dir"
  chmod 700 "$key_dir"
  ssh-keygen -t ed25519 -N "" -C "vps-init-$(hostname)-$(date '+%Y%m%d')" -f "$key_file"
  chmod 600 "$key_file"
  write_managed_key "$user" "$(cat "$key_file.pub")"

  say
  color_yellow "下面是你的 SSH 私钥，请现在完整复制保存到你的本地电脑。"
  color_yellow "从 -----BEGIN OPENSSH PRIVATE KEY----- 到 -----END OPENSSH PRIVATE KEY----- 必须全部保存。"
  say
  cat "$key_file"
  say
  say "Windows 保存后建议在 PowerShell 执行："
  say '  icacls .\你的私钥文件 /inheritance:r'
  # shellcheck disable=SC2016
  say '  icacls .\你的私钥文件 /grant:r "$env:USERNAME:R"'
  say
  say "保存后，你可以这样连接："
  say "  ssh -i 你的私钥文件 -p $(printf '%s' "$SSH_PORTS" | awk '{print $1}') $user@服务器IP"
  say
  if danger_confirm "我已经把私钥保存到本地，现在删除 VPS 上的临时私钥"; then
    if command_exists shred; then
      shred -u "$key_file" "$key_file.pub" 2>/dev/null || rm -f "$key_file" "$key_file.pub"
    else
      rm -f "$key_file" "$key_file.pub"
    fi
    ok "VPS 上的临时私钥已删除。"
    say "说明：因为已经删除，所以 $key_file 现在不能再 cat，这是正常的。"
  else
    warn "临时私钥仍保留在 $key_file。请尽快保存到本地并手动删除。"
    say "你稍后仍可执行下面命令查看："
    say "  cat $key_file"
  fi
}

module_ssh_key() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "配置 SSH Key 登录"
  say "这个功能会把 SSH 公钥写入服务器用户的 authorized_keys。"
  say "之后你可以用对应私钥登录 VPS，后续再考虑关闭密码登录。"
  say
  say "推荐给小白的选择："
  say "  1. 如果你已经有 id_ed25519.pub / id_rsa.pub，选 1 粘贴公钥。"
  say "  2. 如果你完全不知道 SSH Key 是什么，选 2，由脚本临时生成并提示你保存私钥。"
  say "     注意：更安全的做法仍然是在你自己的电脑本地生成 key。"
  say
  say "1. 更安全：粘贴本地生成的 .pub 公钥"
  say "2. 简单：脚本在 VPS 临时生成 keypair"
  say "3. 删除脚本添加的 SSH key"
  say "0. 返回"
  printf '请选择: '
  local choice user auth key_count
  read -r choice || choice=""
  case "$choice" in
    1)
      user="$(select_target_user)" || return 0
      auth="$(authorized_keys_path "$user")"
      key_count=0
      [ -f "$auth" ] && key_count="$(grep -Ec '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-|sk-)' "$auth" 2>/dev/null || echo 0)"
      say "目标用户：$user"
      say "authorized_keys：$auth"
      say "当前检测到 key 数量：$key_count"
      say
      ssh_key_paste "$user"
      ;;
    2)
      user="$(select_target_user)" || return 0
      auth="$(authorized_keys_path "$user")"
      key_count=0
      [ -f "$auth" ] && key_count="$(grep -Ec '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-|sk-)' "$auth" 2>/dev/null || echo 0)"
      say "目标用户：$user"
      say "authorized_keys：$auth"
      say "当前检测到 key 数量：$key_count"
      say
      ssh_key_generate_on_vps "$user"
      ;;
    3)
      user="$(select_target_user)" || return 0
      auth="$(authorized_keys_path "$user")"
      print_preview "删除脚本管理的 SSH key" "无" "$auth" "无" "无" "将删除 $SSH_KEY_BEGIN 与 $SSH_KEY_END 之间的 key" "不可自动恢复，除非你有原公钥" "不影响当前已建立 SSH 连接，但会影响后续 key 登录"
      if danger_confirm "删除脚本添加的 SSH key"; then
        remove_managed_key_block "$auth"
        set_state_value "SSH_KEY_MANAGED" "0"
        ok "脚本管理的 SSH key 已删除。"
        add_report "已删除脚本管理的 SSH key"
      fi
      ;;
    0) return 0 ;;
    *) warn "无效选择。" ;;
  esac
  pause
}

supports_sshd_dropin() {
  [ -d "$SSH_DROPIN_DIR" ] && return 0
  grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSH_MAIN_CONFIG" 2>/dev/null
}

ensure_sshd_dropin_enabled() {
  mkdir -p "$SSH_DROPIN_DIR"
  if grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSH_MAIN_CONFIG" 2>/dev/null; then
    return 0
  fi

  backup_file "$SSH_MAIN_CONFIG"
  local tmp
  tmp="$(mktemp)"
  {
    echo "Include /etc/ssh/sshd_config.d/*.conf"
    cat "$SSH_MAIN_CONFIG"
  } >"$tmp"
  cat "$tmp" >"$SSH_MAIN_CONFIG"
  rm -f "$tmp"
  warn "当前 sshd_config 未启用 drop-in，已在文件顶部加入 Include。"
}

get_managed_ssh_value() {
  local key="$1"
  [ -f "$SSH_DROPIN_FILE" ] || return 1
  awk -v k="$key" 'tolower($1)==tolower(k) {$1=""; sub(/^ /,""); print; exit}' "$SSH_DROPIN_FILE"
}

render_sshd_config() {
  local ports="${1:-}"
  local root_login="${2:-}"
  local password_auth="${3:-}"
  local max_auth="${4:-}"
  local grace="${5:-}"

  ensure_sshd_dropin_enabled
  backup_file "$SSH_DROPIN_FILE"

  {
    echo "# Managed by vps-init $SCRIPT_VERSION"
    echo "# 删除本文件可撤销脚本管理的 SSH 加固配置。"
    if [ -n "$ports" ]; then
      local p
      for p in $ports; do
        echo "Port $p"
      done
    fi
    [ -n "$root_login" ] && echo "PermitRootLogin $root_login"
    [ -n "$password_auth" ] && echo "PasswordAuthentication $password_auth"
    [ -n "$password_auth" ] && echo "KbdInteractiveAuthentication $password_auth"
    echo "PubkeyAuthentication yes"
    echo "PermitEmptyPasswords no"
    [ -n "$max_auth" ] && echo "MaxAuthTries $max_auth"
    [ -n "$grace" ] && echo "LoginGraceTime $grace"
  } >"$SSH_DROPIN_FILE"

  chmod 644 "$SSH_DROPIN_FILE"
  set_state_value "SSH_MANAGED" "1"
}

validate_sshd_config() {
  if ! command_exists sshd; then
    fail "找不到 sshd 命令，无法校验 SSH 配置。"
    return 1
  fi
  if ! sshd -t; then
    fail "sshd -t 校验失败。不会重启 SSH。"
    return 1
  fi
  ok "sshd -t 校验通过。"
}

show_sshd_effective() {
  command_exists sshd || return 0
  say
  say "当前 sshd -T 关键生效值："
  sshd -T 2>/dev/null | awk '$1=="port" || $1=="passwordauthentication" || $1=="kbdinteractiveauthentication" || $1=="permitrootlogin" || $1=="pubkeyauthentication" || $1=="maxauthtries" || $1=="logingracetime" {print "  "$0}' || true
}

restart_ssh_safe() {
  validate_sshd_config || return 1
  restart_service "$SSH_SERVICE"
  ok "SSH 服务已重启：$SSH_SERVICE"
  show_sshd_effective
}

configure_selinux_ssh_port() {
  local port="$1"
  case "$SELINUX_STATUS" in
    Enforcing|Permissive)
      ensure_packages policycoreutils-python-utils || return 1
      if ! command_exists semanage; then
        warn "semanage 不可用，无法配置 SELinux SSH 端口。"
        return 1
      fi
      if semanage port -l | awk '$1=="ssh_port_t"{print $0}' | grep -qw "$port"; then
        ok "SELinux 已允许 SSH 端口 $port。"
      else
        semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$port"
        append_state_list "SSH_SELINUX_PORTS" "$port"
        ok "SELinux 已配置 ssh_port_t/tcp:$port。"
      fi
      ;;
  esac
}

open_firewall_port() {
  local port="$1"
  local proto="${2:-tcp}"
  local note="${3:-vps-init}"
  detect_firewall
  case "$FIREWALL_BACKEND" in
    ufw)
      ensure_packages ufw || return 1
      ufw allow "${port}/${proto}" comment "$note"
      append_state_list "FIREWALL_RULES" "${port}/${proto}"
      ;;
    firewalld)
      ensure_packages firewalld || return 1
      enable_service firewalld || true
      firewall-cmd --permanent --add-port="${port}/${proto}"
      firewall-cmd --add-port="${port}/${proto}" || true
      append_state_list "FIREWALL_RULES" "${port}/${proto}"
      ;;
    *)
      warn "未检测到可自动管理的防火墙后端，跳过端口放行。"
      return 1
      ;;
  esac
  ok "已尝试放行端口 ${port}/${proto}。"
}

has_non_root_sudo_user() {
  if command_exists visudo && ! visudo -cf /etc/sudoers >/dev/null 2>&1; then
    warn "sudoers 校验失败，暂不认为 sudo 用户环境安全。"
    return 1
  fi
  local u
  while IFS=: read -r u _ uid _ _ _ _; do
    [ "$u" = "root" ] && continue
    [ "$u" = "nobody" ] && continue
    [ "$uid" -lt 1000 ] 2>/dev/null && continue
    if id -nG "$u" 2>/dev/null | grep -Eq '(^| )(sudo|wheel)( |$)'; then
      return 0
    fi
  done </etc/passwd
  return 1
}

target_user_has_key() {
  local user="${1:-${SUDO_USER:-root}}"
  local auth
  auth="$(authorized_keys_path "$user")"
  [ -f "$auth" ] && grep -Eq '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-|sk-)' "$auth"
}

select_user_for_key_check() {
  local default_user
  default_user="$(load_state_value SSH_KEY_USER)"
  default_user="${default_user:-${SUDO_USER:-root}}"
  say "关闭密码登录前，需要确认你将使用哪个 Linux 用户通过 SSH key 登录。" >&2
  say "默认：$default_user" >&2
  printf '用户名: ' >&2
  local user
  read -r user || user=""
  [ "$user" = "0" ] && return 1
  user="${user:-$default_user}"
  if ! id "$user" >/dev/null 2>&1; then
    color_red "❌ 用户不存在：$user" >&2
    return 1
  fi
  printf '%s\n' "$user"
}

rescue_prompt() {
  local new_port="${1:-}"
  say
  color_yellow "SSH 救援提示"
  say "当前 SSH 用户：${USER:-unknown}"
  say "当前 SSH 来源：${SSH_CONNECTION:-未检测到 SSH_CONNECTION}"
  say "当前 SSH 端口：$SSH_PORTS"
  [ -n "$new_port" ] && say "新端口连接命令示例：ssh -p $new_port 用户名@服务器IP"
  say "如果新连接失败，请不要关闭当前终端；可从 VPS 控制台恢复 /etc/ssh/sshd_config.d/99-vps-init.conf。"
  say
  return 0
}

module_ssh_hardening() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "SSH 安全加固"
  say "1. 修改 SSH 端口（两阶段迁移）"
  say "2. 修改 Root 登录策略"
  say "3. 修改密码登录策略"
  say "4. 设置基础 SSH 限制（MaxAuthTries/LoginGraceTime/禁用空密码）"
  say "0. 返回"
  printf '请选择: '
  local choice
  read -r choice || choice=""
  case "$choice" in
    1) ssh_change_port ;;
    2) ssh_root_policy ;;
    3) ssh_password_policy ;;
    4) ssh_basic_limits ;;
  esac
  pause
}

ssh_change_port() {
  if [ "$NAT_MODE" -eq 1 ]; then
    warn "检测到疑似 NAT 环境。公网外部端口变化通常不需要修改 sshd_config。"
    say "1. 只记录外部连接端口"
    say "2. 修改服务器内部 SSH 监听端口"
    printf '请选择: '
    local nat_choice
    read -r nat_choice || nat_choice=""
    if [ "$nat_choice" = "1" ]; then
      local ext
      ext="$(read_nonempty "请输入公网外部 SSH 端口: ")"
      set_state_value "NAT_SSH_EXTERNAL_PORT" "$ext"
      set_state_value "NAT_MODE" "1"
      ok "已记录 NAT 外部 SSH 端口：$ext"
      add_report "已记录 NAT 外部 SSH 端口：$ext"
      return 0
    fi
  fi

  local new_port
  new_port="$(read_nonempty "请输入新的 SSH 内部监听端口 (1024-65535): ")"
  if ! validate_port "$new_port"; then
    fail "端口无效。"
    return 1
  fi

  local current_ports="$SSH_PORTS"
  case " $current_ports " in
    *" $new_port "*) warn "端口 $new_port 已经在当前 SSH 配置中。"; return 0 ;;
  esac

  local pkg_note="openssh-server"
  case "$SELINUX_STATUS" in Enforcing|Permissive) pkg_note="$pkg_note policycoreutils-python-utils" ;; esac
  print_preview "SSH 端口两阶段迁移" "$pkg_note" "$SSH_DROPIN_FILE" "$new_port/tcp" "$SSH_SERVICE" "将保留旧端口 [$current_ports]，新增端口 $new_port；请同步云安全组或 NAT 面板" "可删除脚本 drop-in 撤销" "会重启 SSH，但保留旧端口以降低锁机风险"
  rescue_prompt "$new_port"
  danger_confirm "新增 SSH 监听端口并重启 SSH" || return 0

  ensure_packages openssh-server || return 1
  configure_selinux_ssh_port "$new_port" || true
  if confirm_action "是否同步放行本机防火墙端口 $new_port/tcp？" "yes"; then
    open_firewall_port "$new_port" tcp "vps-init ssh" || true
  fi

  local ports="$current_ports $new_port"
  local root_login password_auth max_auth grace
  root_login="$(get_managed_ssh_value PermitRootLogin || true)"
  password_auth="$(get_managed_ssh_value PasswordAuthentication || true)"
  max_auth="$(get_managed_ssh_value MaxAuthTries || true)"
  grace="$(get_managed_ssh_value LoginGraceTime || true)"
  render_sshd_config "$ports" "$root_login" "$password_auth" "$max_auth" "$grace"
  if restart_ssh_safe; then
    set_state_value "SSH_PORTS" "$ports"
    add_report "已新增 SSH 内部端口 $new_port，旧端口仍保留。"
    say
    say "请新开一个终端测试：ssh -p $new_port 用户名@服务器IP"
    if danger_confirm "我已经确认新端口可登录，现在移除旧 SSH 端口"; then
      render_sshd_config "$new_port" "$root_login" "$password_auth" "$max_auth" "$grace"
      restart_ssh_safe && set_state_value "SSH_PORTS" "$new_port" && add_report "已移除旧 SSH 端口，仅保留 $new_port。"
    else
      warn "旧端口已保留。你可稍后再次运行脚本移除。"
    fi
  fi
}

ssh_root_policy() {
  say "Root 登录策略："
  say "1. 禁止 root 登录 (no)"
  say "2. 仅允许 root 使用密钥登录 (prohibit-password)"
  say "3. 保持/恢复为 yes"
  printf '请选择: '
  local c value
  read -r c || c=""
  case "$c" in
    1) value="no" ;;
    2) value="prohibit-password" ;;
    3) value="yes" ;;
    *) return 0 ;;
  esac
  if [ "$value" = "no" ] && ! has_non_root_sudo_user; then
    fail "未检测到非 root sudo 用户，禁止 root 登录可能锁机。请先创建 sudo 用户。"
    return 1
  fi
  print_preview "修改 Root 登录策略" "openssh-server" "$SSH_DROPIN_FILE" "无" "$SSH_SERVICE" "PermitRootLogin 将设置为 $value" "可通过撤销脚本 SSH 配置恢复" "会重启 SSH；当前连接通常不受影响"
  rescue_prompt
  if [ "$value" = "no" ]; then
    danger_confirm "禁用 root SSH 登录" || return 0
  else
    confirm_action "是否应用该 Root 登录策略？" "yes" || return 0
  fi
  ensure_packages openssh-server || return 1
  render_sshd_config "$(get_managed_ports_or_current)" "$value" "$(get_managed_ssh_value PasswordAuthentication || true)" "$(get_managed_ssh_value MaxAuthTries || true)" "$(get_managed_ssh_value LoginGraceTime || true)"
  restart_ssh_safe && add_report "Root 登录策略已设置为 $value"
}

ssh_password_policy() {
  say "密码登录策略："
  say "1. 关闭密码登录，仅允许 SSH key"
  say "2. 恢复密码登录"
  say "0. 返回"
  printf '请选择: '
  local c value user
  read -r c || c=""
  case "$c" in
    1) value="no" ;;
    2) value="yes" ;;
    *) return 0 ;;
  esac
  if [ "$value" = "no" ]; then
    user="$(select_user_for_key_check)" || return 1
    if ! target_user_has_key "$user"; then
      fail "未检测到用户 $user 的 SSH key。请先配置 SSH Key 登录。"
      return 1
    fi
  else
    user=""
  fi
  print_preview "修改密码登录策略" "openssh-server" "$SSH_DROPIN_FILE" "无" "$SSH_SERVICE" "PasswordAuthentication 与 KbdInteractiveAuthentication 将设置为 $value" "可通过撤销脚本 SSH 配置恢复" "会重启 SSH；关闭密码登录会影响后续登录方式"
  rescue_prompt
  if [ "$value" = "no" ]; then
    danger_confirm "关闭 SSH 密码登录" || return 0
  else
    confirm_action "是否恢复 SSH 密码登录？" "yes" || return 0
  fi
  ensure_packages openssh-server || return 1
  render_sshd_config "$(get_managed_ports_or_current)" "$(get_managed_ssh_value PermitRootLogin || true)" "$value" "$(get_managed_ssh_value MaxAuthTries || true)" "$(get_managed_ssh_value LoginGraceTime || true)"
  restart_ssh_safe && add_report "SSH 密码登录策略已设置为 $value"
}

ssh_basic_limits() {
  local max_auth grace
  printf '最大认证尝试次数 MaxAuthTries [默认 3]: '
  read -r max_auth || max_auth=""
  max_auth="${max_auth:-3}"
  printf '登录宽限时间 LoginGraceTime [默认 30]: '
  read -r grace || grace=""
  grace="${grace:-30}"
  if ! [[ "$max_auth" =~ ^[0-9]+$ ]] || [ "$max_auth" -lt 1 ] || [ "$max_auth" -gt 10 ]; then
    fail "MaxAuthTries 应为 1-10。"
    return 1
  fi
  if ! [[ "$grace" =~ ^[0-9]+$ ]]; then
    fail "LoginGraceTime 应为秒数。"
    return 1
  fi
  print_preview "设置 SSH 基础限制" "openssh-server" "$SSH_DROPIN_FILE" "无" "$SSH_SERVICE" "设置 MaxAuthTries=$max_auth, LoginGraceTime=${grace}, PermitEmptyPasswords=no" "可通过撤销脚本 SSH 配置恢复" "会重启 SSH；通常不影响当前连接"
  confirm_action "是否应用 SSH 基础限制？" "yes" || return 0
  ensure_packages openssh-server || return 1
  render_sshd_config "$(get_managed_ports_or_current)" "$(get_managed_ssh_value PermitRootLogin || true)" "$(get_managed_ssh_value PasswordAuthentication || true)" "$max_auth" "$grace"
  restart_ssh_safe && add_report "已设置 SSH 基础限制"
}

get_managed_ports_or_current() {
  local ports
  ports="$(get_managed_ssh_value Port || true)"
  if [ -f "$SSH_DROPIN_FILE" ]; then
    ports="$(awk 'tolower($1)=="port"{print $2}' "$SSH_DROPIN_FILE" | xargs 2>/dev/null || true)"
  fi
  [ -n "$ports" ] && echo "$ports" || echo "$SSH_PORTS"
}

module_fail2ban() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "fail2ban SSH 防爆破"
  if [ "$MEM_TOTAL_MB" -lt 256 ]; then
    warn "当前内存低于 256MB，不推荐安装 fail2ban。"
    danger_confirm "低内存环境强制安装 fail2ban" || { pause; return; }
  elif [ "$MEM_TOTAL_MB" -lt 512 ]; then
    warn "当前为低配机器，fail2ban 会增加常驻内存占用。"
  fi
  local maxretry bantime findtime ignoreip backend
  printf '最大失败次数 maxretry [默认 5]: '
  read -r maxretry || maxretry=""
  maxretry="${maxretry:-5}"
  printf '封禁时间 bantime 秒 [默认 3600]: '
  read -r bantime || bantime=""
  bantime="${bantime:-3600}"
  printf '检测窗口 findtime 秒 [默认 600]: '
  read -r findtime || findtime=""
  findtime="${findtime:-600}"
  ignoreip="$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $1}')"
  if [ -n "$ignoreip" ]; then
    say "检测到当前 SSH 来源 IP：$ignoreip，将加入 fail2ban 白名单。"
  else
    printf '未检测到当前 SSH 来源 IP，可手动输入白名单 IP（可留空）: '
    read -r ignoreip || ignoreip=""
  fi
  if [ "$HAS_SYSTEMD" -eq 1 ]; then backend="systemd"; else backend="auto"; fi
  print_preview "配置 fail2ban SSH jail" "fail2ban" "$F2B_FILE" "无" "fail2ban" "只启用 SSH jail；监听内部端口 [$SSH_PORTS]；ignoreip=${ignoreip:-无}" "可删除 $F2B_FILE 撤销" "不影响当前 SSH 连接，但误配置可能误封来源 IP"
  confirm_action "是否安装并配置 fail2ban？" "yes" || { pause; return; }
  ensure_packages fail2ban || { pause; return; }
  mkdir -p "$(dirname "$F2B_FILE")"
  backup_file "$F2B_FILE"
  {
    echo "# Managed by vps-init $SCRIPT_VERSION"
    echo "[sshd]"
    echo "enabled = true"
    echo "backend = $backend"
    echo "port = $SSH_PORTS"
    echo "maxretry = $maxretry"
    echo "bantime = $bantime"
    echo "findtime = $findtime"
    [ -n "$ignoreip" ] && echo "ignoreip = 127.0.0.1/8 ::1 $ignoreip"
  } >"$F2B_FILE"
  enable_service fail2ban || restart_service fail2ban
  set_state_value "FAIL2BAN_MANAGED" "1"
  ok "fail2ban 已配置。"
  add_report "已配置 fail2ban SSH jail"
  pause
}

module_firewall() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "防火墙配置"
  if [ "$NAT_MODE" -eq 1 ]; then
    warn "NAT VPS：本机防火墙控制内部端口，公网访问还取决于服务商 NAT 映射。"
  fi
  if command_exists docker; then
    warn "检测到 Docker。Docker 可能绕过或影响 UFW/firewalld 规则，本脚本不会深度接管 Docker 防火墙模型。"
  fi
  say "1. 启用防火墙并放行当前 SSH 端口"
  say "2. 放行自定义端口"
  say "3. 查看防火墙状态"
  say "0. 返回"
  printf '请选择: '
  local c
  read -r c || c=""
  case "$c" in
    1) firewall_enable_ssh ;;
    2) firewall_custom_rule ;;
    3) firewall_status ;;
  esac
  pause
}

firewall_enable_ssh() {
  local pkg="ufw"
  [ "$OS_FAMILY" = "rhel" ] && pkg="firewalld"
  print_preview "启用防火墙并放行 SSH" "$pkg" "防火墙规则" "$SSH_PORTS/tcp" "$pkg" "请确认云安全组或 NAT 面板也放行了对应端口" "脚本记录的端口规则可尝试撤销" "若 SSH 端口未放行，可能导致新连接失败"
  danger_confirm "启用本机防火墙" || return 0
  ensure_packages "$pkg" || return 1
  local p
  for p in $SSH_PORTS; do
    open_firewall_port "$p" tcp "vps-init ssh" || true
  done
  case "$FIREWALL_BACKEND" in
    ufw)
      ufw --force enable
      ;;
    firewalld)
      enable_service firewalld
      ;;
  esac
  ok "防火墙已启用/更新。"
  add_report "已启用防火墙并放行 SSH 端口：$SSH_PORTS"
}

firewall_custom_rule() {
  local port proto ipver note
  port="$(read_nonempty "请输入要放行的内部端口: ")"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    fail "端口无效。"
    return 1
  fi
  printf '协议 tcp/udp/both [默认 tcp]: '
  read -r proto || proto=""
  proto="${proto:-tcp}"
  printf 'IP 版本 ipv4/ipv6/both [默认 both]: '
  read -r ipver || ipver=""
  ipver="${ipver:-both}"
  printf '备注名称 [默认 vps-init custom]: '
  read -r note || note=""
  note="${note:-vps-init custom}"
  print_preview "放行自定义端口" "防火墙后端依赖包" "防火墙规则" "$port/$proto ($ipver)" "防火墙服务" "NAT 场景还需服务商面板映射公网端口" "脚本记录的规则可尝试撤销" "不影响当前 SSH，除非规则误操作"
  confirm_action "是否放行该端口？" "yes" || return 0
  local protocols=("$proto")
  [ "$proto" = "both" ] && protocols=(tcp udp)
  local pr
  for pr in "${protocols[@]}"; do
    open_firewall_port "$port" "$pr" "$note" || true
  done
  add_report "已放行自定义端口：$port/$proto"
}

firewall_status() {
  case "$FIREWALL_BACKEND" in
    ufw) ufw status verbose ;;
    firewalld) firewall-cmd --state 2>/dev/null || true; firewall-cmd --list-all 2>/dev/null || true ;;
    nftables) nft list ruleset ;;
    iptables) iptables -S ;;
    *) warn "未检测到防火墙后端。" ;;
  esac
}

module_bbr() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "BBR 网络优化"
  local available current qdisc
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  say "可用算法：${available:-未知}"
  say "当前算法：${current:-未知}"
  say "当前 qdisc：${qdisc:-未知}"
  if ! printf '%s' "$available" | grep -qw bbr; then
    warn "当前内核可能不支持 BBR。OpenVZ/LXC 受限环境也可能无法修改。"
  fi
  if [ "$current" = "bbr" ]; then
    ok "当前 TCP 拥塞控制算法已经是 bbr，无需重复启用。"
    if [ -z "$qdisc" ]; then
      warn "当前环境无法读取 net.core.default_qdisc，这在受限容器/NAT 小机里很常见。"
    fi
    if ! confirm_action "是否仍写入持久化 BBR 配置文件？" "no"; then
      add_report "BBR 已启用，未重复写入配置"
      pause
      return 0
    fi
  fi
  print_preview "启用 BBR" "无" "$BBR_FILE" "无" "sysctl -w BBR相关键" "NAT VPS 可尝试启用，但不承诺加速效果；受限内核失败不是脚本问题" "删除 $BBR_FILE 后可撤销" "不影响 SSH 连接"
  confirm_action "是否启用 BBR？" "yes" || { pause; return; }
  backup_file "$BBR_FILE"
  {
    echo "# Managed by vps-init $SCRIPT_VERSION"
    echo "net.core.default_qdisc=fq"
    echo "net.ipv4.tcp_congestion_control=bbr"
  } >"$BBR_FILE"
  local qdisc_ok=0
  local cc_ok=0
  if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
    qdisc_ok=1
  else
    warn "无法设置 net.core.default_qdisc=fq，可能是容器/虚拟化限制。"
  fi
  if sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    cc_ok=1
  else
    warn "无法设置 net.ipv4.tcp_congestion_control=bbr，可能是容器/虚拟化限制。"
  fi
  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  if [ "$current" = "bbr" ]; then
    set_state_value "BBR_MANAGED" "1"
    ok "BBR 配置已应用。"
    say "当前算法：$current"
    say "当前 qdisc：${qdisc:-未知/无权限读取}"
    [ "$qdisc_ok" -eq 0 ] && warn "qdisc 未成功设置，但当前算法已经是 bbr。"
    add_report "已启用 BBR 配置"
  else
    fail "BBR 未能启用，可能是虚拟化或内核限制。"
    say "当前算法：${current:-未知}"
    [ "$cc_ok" -eq 0 ] && warn "tcp_congestion_control 写入失败。"
  fi
  pause
}

module_system_init() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "系统基础初始化"
  say "1. 安装最小工具"
  say "2. 安装常用工具"
  say "3. 安装诊断工具"
  say "4. 设置时区"
  say "5. 配置 chrony/NTP"
  say "6. 配置自动安全更新"
  say "0. 返回"
  printf '请选择: '
  local c
  read -r c || c=""
  case "$c" in
    1) install_tool_tier "最小" curl wget ca-certificates sudo ;;
    2) install_tool_tier "常用" nano vim git unzip tar htop ;;
    3) install_tool_tier "诊断" lsof net-tools dnsutils ;;
    4) set_timezone ;;
    5) configure_chrony ;;
    6) configure_auto_updates ;;
  esac
  pause
}

install_tool_tier() {
  local name="$1"
  shift
  print_preview "安装${name}工具" "$*" "无" "无" "无" "低内存机器会分批安装，失败后返回菜单" "可手动卸载包，脚本不自动卸载通用工具" "不影响 SSH 连接"
  confirm_action "是否安装${name}工具？" "yes" || return 0
  ensure_packages "$@" && add_report "已安装${name}工具"
}

set_timezone() {
  local tz
  printf '请输入时区 [默认 Asia/Shanghai]: '
  read -r tz || tz=""
  tz="${tz:-Asia/Shanghai}"
  print_preview "设置时区" "无" "/etc/localtime" "无" "systemd-timesync/cron 可能感知时间变化" "日志显示时间会变化" "可再次设置其他时区" "不影响 SSH 连接"
  confirm_action "是否设置时区为 $tz？" "yes" || return 0
  if command_exists timedatectl; then
    timedatectl set-timezone "$tz"
  else
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
  fi
  set_state_value "TIMEZONE_MANAGED" "$tz"
  ok "时区已设置为 $tz。"
  add_report "已设置时区：$tz"
}

configure_chrony() {
  print_preview "配置 chrony/NTP" "chrony" "chrony 配置" "无" "chronyd/chrony" "时间同步有助于日志和证书有效性" "可手动禁用服务" "不影响 SSH 连接"
  confirm_action "是否安装并启用 chrony？" "yes" || return 0
  ensure_packages chrony || return 1
  if systemctl list-unit-files chronyd.service >/dev/null 2>&1; then
    enable_service chronyd
  else
    enable_service chrony
  fi
  add_report "已配置 chrony/NTP"
}

configure_auto_updates() {
  if [ "$MEM_TOTAL_MB" -lt 512 ]; then
    warn "当前内存低于 512MB，不推荐启用自动安全更新。"
    danger_confirm "低内存环境启用自动安全更新" || return 0
  fi
  local pkg service
  if [ "$OS_FAMILY" = "debian" ]; then
    pkg="unattended-upgrades"
    service="unattended-upgrades"
  else
    pkg="dnf-automatic"
    service="dnf-automatic.timer"
  fi
  print_preview "配置自动安全更新" "$pkg" "系统自动更新配置" "无" "$service" "默认不启用自动重启；低配机器可能后台占用资源" "可手动禁用服务" "不影响当前 SSH 连接"
  confirm_action "是否启用自动安全更新？" "yes" || return 0
  ensure_packages "$pkg" || return 1
  if [ "$OS_FAMILY" = "debian" ]; then
    dpkg-reconfigure -f noninteractive unattended-upgrades 2>/dev/null || true
    enable_service unattended-upgrades || true
  else
    systemctl enable --now dnf-automatic.timer
  fi
  add_report "已启用自动安全更新"
}

module_optional() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "可选组件"
  say "1. Docker（高级功能）"
  say "2. Swap/Zram"
  say "3. Hostname"
  say "4. sudo 用户"
  say "0. 返回"
  printf '请选择: '
  local c
  read -r c || c=""
  case "$c" in
    1) optional_docker ;;
    2) optional_swap ;;
    3) optional_hostname ;;
    4) optional_sudo_user ;;
  esac
  pause
}

optional_docker() {
  if [ "$ARCH_FAMILY" != "amd64" ] && [ "$ARCH_FAMILY" != "arm64" ]; then
    fail "当前架构 $ARCH_RAW 不在 Docker 支持清单内，跳过。"
    return 1
  fi
  if [ "$MEM_TOTAL_MB" -lt 1024 ]; then
    warn "Docker 建议至少 1GB RAM，当前仅 ${MEM_TOTAL_MB}MB。"
    danger_confirm "低内存环境强制安装 Docker" || return 0
  fi
  warn "Docker 可能改写 iptables/nftables，并影响 UFW/firewalld 规则。"
  local pkg
  if [ "$OS_FAMILY" = "debian" ]; then
    pkg="docker.io"
  else
    pkg="docker"
  fi
  print_preview "安装 Docker（发行版包）" "$pkg" "Docker 服务配置" "Docker 端口由容器发布决定" "docker" "本脚本使用发行版包；如需官方仓库，请按 Docker 官方文档处理" "不提供深度卸载，仅给风险提示" "不影响 SSH，但可能影响防火墙行为"
  danger_confirm "安装 Docker 高级组件" || return 0
  ensure_packages "$pkg" || return 1
  enable_service docker || true
  if confirm_action "是否将某个 sudo 用户加入 docker 组？" "no"; then
    local user
    user="$(select_target_user)" || return 1
    usermod -aG docker "$user"
    add_report "已将 $user 加入 docker 组（重新登录后生效）"
  fi
  add_report "已安装 Docker（发行版包）"
}

optional_swap() {
  say "当前 swap：${SWAP_TOTAL_MB}MB"
  say "1. 创建/调整 /swapfile"
  say "2. 删除脚本创建的 /swapfile"
  say "0. 返回"
  printf '请选择: '
  local c
  read -r c || c=""
  case "$c" in
    1)
      local size
      if [ "$MEM_TOTAL_MB" -lt 256 ]; then size=512; elif [ "$MEM_TOTAL_MB" -lt 512 ]; then size=1024; else size=1024; fi
      printf '请输入 swap 大小 MB [默认 %s]: ' "$size"
      read -r input || input=""
      size="${input:-$size}"
      print_preview "创建/调整 swapfile" "无" "/swapfile, /etc/fstab" "无" "swapon" "虚拟化可能禁止 swapfile；swap 只能缓解低内存，不适合跑重服务" "脚本可删除 /swapfile 并移除 fstab 记录" "不影响 SSH 连接"
      confirm_action "是否创建/调整 /swapfile？" "yes" || return 0
      if [ "$DISK_FREE_MB" -lt "$((size + 200))" ]; then
        fail "磁盘空间不足，无法创建 ${size}MB swap。"
        return 1
      fi
      swapoff /swapfile 2>/dev/null || true
      rm -f /swapfile
      if command_exists fallocate; then
        fallocate -l "${size}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$size"
      else
        dd if=/dev/zero of=/swapfile bs=1M count="$size"
      fi
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
      set_state_value "SWAPFILE" "/swapfile"
      add_report "已创建/启用 /swapfile ${size}MB"
      ;;
    2)
      print_preview "删除 swapfile" "无" "/swapfile, /etc/fstab" "无" "swapoff" "删除后低内存机器更容易 OOM" "删除后需重新创建" "不影响 SSH 连接"
      danger_confirm "删除脚本创建的 /swapfile" || return 0
      swapoff /swapfile 2>/dev/null || true
      sed -i.bak '/^\/swapfile[[:space:]]/d' /etc/fstab
      rm -f /swapfile
      set_state_value "SWAPFILE" ""
      add_report "已删除 /swapfile"
      ;;
  esac
}

optional_hostname() {
  local current new
  current="$(hostname)"
  say "当前 hostname：$current"
  new="$(read_nonempty "请输入新的 hostname: ")"
  if ! [[ "$new" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]]; then
    fail "hostname 格式无效。"
    return 1
  fi
  print_preview "修改 hostname" "无" "/etc/hostname" "无" "hostnamectl" "可能影响日志、shell 提示符和部分服务显示名" "可再次修改" "不影响 SSH 连接"
  confirm_action "是否修改 hostname？" "yes" || return 0
  set_state_value "OLD_HOSTNAME" "$current"
  if command_exists hostnamectl; then
    hostnamectl set-hostname "$new"
  else
    echo "$new" >/etc/hostname
    hostname "$new"
  fi
  add_report "已修改 hostname：$current -> $new"
}

optional_sudo_user() {
  say "1. 创建新 sudo 用户"
  say "2. 给已有用户添加 sudo 权限"
  say "0. 返回"
  printf '请选择: '
  local c user group
  read -r c || c=""
  case "$c" in
    1)
      user="$(read_nonempty "请输入新用户名: ")"
      if ! [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
        fail "用户名格式无效。"
        return 1
      fi
      if id "$user" >/dev/null 2>&1; then
        warn "用户已存在，将只添加 sudo 权限。"
      fi
      ;;
    2)
      user="$(select_target_user)" || return 1
      ;;
    *) return 0 ;;
  esac
  group="sudo"
  [ "$OS_FAMILY" = "rhel" ] && group="wheel"
  print_preview "创建/加固 sudo 用户" "sudo" "/etc/passwd, /etc/group, sudoers 校验" "无" "无" "禁用 root 登录前需要至少一个可用 sudo 用户" "用户创建不会自动删除" "不影响 SSH 连接"
  confirm_action "是否创建/加固 sudo 用户 $user？" "yes" || return 0
  ensure_packages sudo || return 1
  if ! id "$user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$user"
    passwd "$user"
  fi
  usermod -aG "$group" "$user"
  if ! visudo -cf /etc/sudoers >/dev/null; then
    fail "sudoers 校验失败，请手动检查。"
    return 1
  fi
  add_report "已创建/加固 sudo 用户：$user"
}

module_nat_settings() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "NAT/端口映射设置"
  say "脚本无法修改服务商 NAT 面板；这里只记录映射信息，用于提示和生成连接命令。"
  local internal external note
  printf 'SSH 内部端口 [默认 %s]: ' "$SSH_PORTS"
  read -r internal || internal=""
  internal="${internal:-$SSH_PORTS}"
  external="$(read_nonempty "SSH 公网外部连接端口: ")"
  printf '服务商面板备注（可留空）: '
  read -r note || note=""
  print_preview "记录 NAT 端口映射" "无" "$STATE_FILE" "无" "无" "只记录信息，不修改系统端口或服务商面板" "可重复运行修改" "不影响 SSH 连接"
  confirm_action "是否保存 NAT 设置？" "yes" || { pause; return; }
  set_state_value "NAT_MODE" "1"
  set_state_value "NAT_SSH_INTERNAL_PORT" "$internal"
  set_state_value "NAT_SSH_EXTERNAL_PORT" "$external"
  set_state_value "NAT_NOTE" "$note"
  add_report "已记录 NAT 映射：内部 $internal -> 外部 $external"
  pause
}

module_minimal_security() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "极简安全初始化"
  say "适合 128MB RAM、NAT VPS、临时机器。不会安装 fail2ban、Docker、firewalld，不做全量升级。"
  say "将逐项预览和确认：SSH key、sudo 用户检查、SSH 基础限制、可选关闭密码登录。"
  confirm_action "是否进入极简安全初始化向导？" "yes" || { pause; return; }
  module_ssh_key
  optional_sudo_user
  ssh_basic_limits
  if confirm_action "是否考虑关闭 SSH 密码登录？" "no"; then
    ssh_password_policy
  fi
  pause
}

module_recommended() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "一键推荐初始化（推荐向导，不是静默批处理）"
  say "推荐执行："
  say "  [建议] 配置 SSH Key 登录"
  say "  [建议] 创建/确认非 root sudo 用户"
  say "  [建议] SSH 基础加固"
  if [ "$MEM_TOTAL_MB" -ge 512 ]; then say "  [建议] fail2ban SSH 防爆破"; else say "  [跳过] fail2ban：当前内存低于 512MB"; fi
  say "  [建议] 防火墙放行当前 SSH 端口"
  say "  [建议] BBR（若内核支持）"
  say "  [建议] 最小工具、时区、chrony"
  if [ "$SWAP_TOTAL_MB" -eq 0 ] && [ "$MEM_TOTAL_MB" -lt 1024 ]; then say "  [建议] 创建 swap"; fi
  if [ "$NAT_MODE" -eq 1 ]; then say "  [跳过] 修改 SSH 端口：检测到 NAT 环境"; else say "  [跳过] 修改 SSH 端口：推荐向导默认不改端口"; fi
  say "  [跳过] Docker、全量升级、关闭密码登录、禁用 root、移除 22 端口"
  say
  confirm_action "是否开始逐项推荐向导？" "yes" || { pause; return; }

  if confirm_action "第 1 项：配置 SSH Key 登录？" "yes"; then module_ssh_key; fi
  if confirm_action "第 2 项：创建/确认 sudo 用户？" "yes"; then optional_sudo_user; fi
  if confirm_action "第 3 项：设置 SSH 基础限制？" "yes"; then ssh_basic_limits; fi
  if [ "$MEM_TOTAL_MB" -ge 512 ] && confirm_action "第 4 项：配置 fail2ban？" "yes"; then module_fail2ban; fi
  if confirm_action "第 5 项：配置防火墙放行 SSH？" "yes"; then firewall_enable_ssh; fi
  if confirm_action "第 6 项：启用 BBR？" "yes"; then module_bbr; fi
  if confirm_action "第 7 项：安装最小工具？" "yes"; then install_tool_tier "最小" curl wget ca-certificates sudo; fi
  if confirm_action "第 8 项：设置时区？" "yes"; then set_timezone; fi
  if confirm_action "第 9 项：配置 chrony/NTP？" "yes"; then configure_chrony; fi
  if [ "$SWAP_TOTAL_MB" -eq 0 ] && [ "$MEM_TOTAL_MB" -lt 1024 ] && confirm_action "第 10 项：创建 swap？" "yes"; then optional_swap; fi
  add_report "推荐初始化向导已完成"
  pause
}

module_status() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "脚本状态"
  say "状态文件：$STATE_FILE"
  if [ -f "$STATE_FILE" ]; then
    sed 's/SSH_KEY=.*/SSH_KEY=<hidden>/' "$STATE_FILE" || true
  fi
  say
  say "脚本配置文件："
  for f in "$SSH_DROPIN_FILE" "$F2B_FILE" "$BBR_FILE"; do
    if [ -e "$f" ]; then say "  存在：$f"; else say "  不存在：$f"; fi
  done
  pause
}

module_restore() {
  print_header
  refresh_detection
  show_system_brief
  say
  color_blue "撤销本脚本做过的配置"
  say "1. 删除脚本 SSH 加固配置"
  say "2. 删除脚本添加的 SSH key"
  say "3. 删除 fail2ban 脚本 jail"
  say "4. 删除 BBR 配置"
  say "5. 删除脚本记录的防火墙规则"
  say "6. 删除 /swapfile"
  say "0. 返回"
  printf '请选择: '
  local c
  read -r c || c=""
  case "$c" in
    1)
      print_preview "撤销 SSH 加固配置" "无" "$SSH_DROPIN_FILE" "无" "$SSH_SERVICE" "删除脚本 drop-in 后重启 SSH" "只删除脚本配置，不恢复系统原始默认" "会重启 SSH"
      danger_confirm "删除脚本 SSH 配置并重启 SSH" || return 0
      rm -f "$SSH_DROPIN_FILE"
      restart_ssh_safe || true
      set_state_value "SSH_MANAGED" "0"
      add_report "已撤销脚本 SSH 加固配置"
      ;;
    2)
      local user auth
      user="$(load_state_value SSH_KEY_USER)"
      user="${user:-${SUDO_USER:-root}}"
      auth="$(authorized_keys_path "$user")"
      print_preview "删除脚本 SSH key" "无" "$auth" "无" "无" "删除标记块内 key" "不可自动恢复" "可能影响后续 key 登录"
      danger_confirm "删除脚本添加的 SSH key" || return 0
      remove_managed_key_block "$auth"
      set_state_value "SSH_KEY_MANAGED" "0"
      add_report "已删除脚本添加的 SSH key"
      ;;
    3)
      print_preview "删除 fail2ban jail" "无" "$F2B_FILE" "无" "fail2ban" "删除脚本 jail 并重启 fail2ban" "只删除脚本 jail" "不影响 SSH"
      confirm_action "是否删除 fail2ban 脚本配置？" "yes" || return 0
      rm -f "$F2B_FILE"
      restart_service fail2ban || true
      set_state_value "FAIL2BAN_MANAGED" "0"
      add_report "已撤销 fail2ban 脚本 jail"
      ;;
    4)
      print_preview "删除 BBR 配置" "无" "$BBR_FILE" "无" "无" "删除脚本 sysctl 文件；不全量重载 sysctl，避免受限容器刷屏报错" "不保证恢复到镜像原始 qdisc" "不影响 SSH"
      confirm_action "是否删除 BBR 配置？" "yes" || return 0
      rm -f "$BBR_FILE"
      set_state_value "BBR_MANAGED" "0"
      add_report "已撤销 BBR 配置"
      ;;
    5)
      restore_firewall_rules
      ;;
    6)
      print_preview "删除 swapfile" "无" "/swapfile, /etc/fstab" "无" "swapoff" "删除后低内存机器可能 OOM" "删除后需重新创建" "不影响 SSH"
      danger_confirm "删除 /swapfile" || return 0
      swapoff /swapfile 2>/dev/null || true
      sed -i.bak '/^\/swapfile[[:space:]]/d' /etc/fstab
      rm -f /swapfile
      set_state_value "SWAPFILE" ""
      add_report "已删除 /swapfile"
      ;;
  esac
  pause
}

restore_firewall_rules() {
  local rules
  rules="$(load_state_value FIREWALL_RULES)"
  if [ -z "$rules" ]; then
    warn "状态文件中没有脚本记录的防火墙规则。"
    return 0
  fi
  print_preview "删除脚本记录的防火墙规则" "无" "防火墙规则" "$rules" "防火墙服务" "只尝试删除状态文件记录的规则" "可能需要手动检查" "误删 SSH 规则可能影响新连接"
  danger_confirm "删除脚本记录的防火墙规则" || return 0
  local rule port proto
  for rule in $rules; do
    port="${rule%/*}"
    proto="${rule#*/}"
    case "$FIREWALL_BACKEND" in
      ufw) ufw --force delete allow "$rule" || true ;;
      firewalld)
        firewall-cmd --permanent --remove-port="$rule" || true
        firewall-cmd --remove-port="$rule" || true
        ;;
      *) warn "当前防火墙后端 $FIREWALL_BACKEND 无自动删除实现。" ;;
    esac
  done
  set_state_value "FIREWALL_RULES" ""
  add_report "已尝试删除脚本记录的防火墙规则"
}

print_summary_report() {
  say
  color_blue "========== 本次执行总结 =========="
  if [ "${#RUN_REPORT[@]}" -eq 0 ]; then
    say "本次没有执行会改变系统的操作。"
  else
    local item
    for item in "${RUN_REPORT[@]}"; do
      say "- $item"
    done
  fi
  say
  say "当前 SSH 连接命令参考："
  local ext
  ext="$(load_state_value NAT_SSH_EXTERNAL_PORT)"
  if [ "$NAT_MODE" -eq 1 ] && [ -n "$ext" ]; then
    say "  NAT 外部端口：ssh -p $ext 用户名@公网IP"
  else
    local p
    p="$(printf '%s' "$SSH_PORTS" | awk '{print $1}')"
    say "  ssh -p ${p:-22} 用户名@服务器IP"
    [ "$IPV6_AVAILABLE" -eq 1 ] && say "  IPv6 示例：ssh -6 -p ${p:-22} 用户名@IPv6地址"
  fi
  say "日志路径：$LOG_FILE"
  say "备份路径：$BACKUP_DIR"
  say "状态文件：$STATE_FILE"
  say "建议：高风险 SSH 变更后，请先开新终端测试登录，再关闭当前终端。"
  say "=================================="
  return 0
}

main_menu() {
  while true; do
    refresh_detection
    print_header
    show_system_brief
    say
    if [ "$ARCH_FAMILY" = "unsupported" ]; then
      warn "当前架构 $ARCH_RAW 不在完整支持范围内；Docker 等组件会被跳过。"
    fi
    if [ "$MEM_TOTAL_MB" -lt 256 ]; then
      warn "极低内存机器：推荐使用菜单 9 极简安全初始化。"
    fi
    if [ "$NAT_MODE" -eq 1 ]; then
      warn "疑似 NAT VPS：端口相关功能会区分内部端口和外部映射端口。"
    fi
    say
    say "1. 配置 SSH Key 登录"
    say "2. 配置 SSH 安全加固"
    say "3. 配置基础安全组件（fail2ban 防爆破）"
    say "4. 配置防火墙"
    say "5. 启用 BBR 网络优化"
    say "6. 系统基础初始化"
    say "7. 可选组件（Docker、Swap/Zram、Hostname、sudo 用户）"
    say "8. NAT/端口映射设置"
    say "9. 极简安全初始化"
    say "10. 一键推荐初始化"
    say "11. 查看当前配置状态"
    say "12. 撤销本脚本做过的配置"
    say "0. 退出"
    say
    printf '请选择: '
    local choice
    read -r choice || choice=""
    case "$choice" in
      1) module_ssh_key ;;
      2) module_ssh_hardening ;;
      3) module_fail2ban ;;
      4) module_firewall ;;
      5) module_bbr ;;
      6) module_system_init ;;
      7) module_optional ;;
      8) module_nat_settings ;;
      9) module_minimal_security ;;
      10) module_recommended ;;
      11) module_status ;;
      12) module_restore ;;
      0)
        refresh_detection
        print_summary_report
        exit 0
        ;;
      *) warn "无效选择。" ; pause ;;
    esac
  done
}

main() {
  require_root
  acquire_lock
  init_storage
  log "INFO" "vps-init started, version $SCRIPT_VERSION"
  refresh_detection
  if [ "$OS_FAMILY" = "unknown" ]; then
    warn "当前系统未在完整支持列表中：$OS_ID $OS_VERSION_ID。部分功能可能不可用。"
    confirm_action "是否仍然进入菜单？" "yes" || exit 0
  fi
  main_menu
}

main "$@"
