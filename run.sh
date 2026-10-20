#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/jd-node
BIN_DIR="$APP_DIR/bin"
STATE_DIR="$APP_DIR/state"
CONFIG_DIR="$APP_DIR/config"
SYSTEMD_DIR=/etc/systemd/system
SNI=www.bing.com

trap 'printf "\n错误：第 %s 行执行失败。请查看 systemctl status jd-argo jd-xray jd-hy2。\n" "$LINENO" >&2' ERR

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 运行；查看节点可执行 sudo jd。'
}

require_system() {
  command -v systemctl >/dev/null || die '仅支持使用 systemd 的 Linux 发行版。'
  [[ -r /etc/os-release ]] || die '无法识别操作系统。'
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die '目前只支持 Ubuntu 和 Debian。' ;;
  esac
  case "$(uname -m)" in
    x86_64) ARCH=amd64; XRAY_ARCH=64 ;;
    aarch64|arm64) ARCH=arm64; XRAY_ARCH=arm64-v8a ;;
    *) die '目前只支持 x86_64 和 ARM64。' ;;
  esac
}

prepare() {
  require_root
  require_system
  local missing=() item
  for item in curl unzip openssl python3; do
    command -v "$item" >/dev/null || missing+=("$item")
  done
  if ((${#missing[@]})); then
    info "安装依赖：${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates "${missing[@]}"
  fi
  umask 077
  mkdir -p "$BIN_DIR" "$STATE_DIR" "$CONFIG_DIR"
  chmod 700 "$APP_DIR" "$STATE_DIR" "$CONFIG_DIR"
  install_self
}

install_self() {
  local command_path source_file temp_source=''
  for command_path in /usr/local/bin/jd /usr/local/bin/jdxz; do
    if [[ -e $command_path || -L $command_path ]] \
      && ! grep -q 'jd-node-managed' "$command_path" 2>/dev/null; then
      die "$command_path 已被其他程序占用，请先处理命令冲突。"
    fi
  done
  source_file=$0
  # `bash <(curl ...)` executes from a pipe. Reading $0 again copies only the
  # unread tail, so fetch a complete copy for the persistent jd/jdxz commands.
  if [[ ! -f $source_file || -L $source_file || $source_file == /dev/fd/* ]]; then
    temp_source=$(mktemp)
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 60 \
      -o "$temp_source" \
      'https://raw.githubusercontent.com/viperoooiii/JD-Argo-hy2/main/run.sh'; then
      rm -f "$temp_source"
      die '无法下载完整管理脚本。'
    fi
    source_file=$temp_source
  fi
  [[ -s $source_file ]] || die '管理脚本为空，已停止安装。'
  bash -n "$source_file" || die '管理脚本语法检查失败，已停止安装。'
  install -m 755 "$source_file" "$APP_DIR/run.sh"
  [[ -z $temp_source ]] || rm -f "$temp_source"
  cat >/usr/local/bin/jd <<'EOF'
#!/usr/bin/env bash
# jd-node-managed
exec /opt/jd-node/run.sh --show "$@"
EOF
  chmod 755 /usr/local/bin/jd
  cat >/usr/local/bin/jdxz <<'EOF'
#!/usr/bin/env bash
# jd-node-managed
exec /opt/jd-node/run.sh --uninstall "$@"
EOF
  chmod 755 /usr/local/bin/jdxz
}

download() {
  local url=$1 target=$2 temp
  temp=$(mktemp "$BIN_DIR/.download.XXXXXX")
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 -o "$temp" "$url"; then
    rm -f "$temp"
    die "下载失败：$url"
  fi
  [[ -s $temp ]] || { rm -f "$temp"; die "下载文件为空：$url"; }
  install -m 755 "$temp" "$target"
  rm -f "$temp"
}

install_xray() {
  [[ -x $BIN_DIR/xray ]] && return
  info '下载 Xray'
  local temp
  temp=$(mktemp -d)
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
    -o "$temp/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"; then
    rm -rf "$temp"
    die 'Xray 下载失败。'
  fi
  unzip -q "$temp/xray.zip" xray -d "$temp"
  install -m 755 "$temp/xray" "$BIN_DIR/xray"
  rm -rf "$temp"
}

install_cloudflared() {
  [[ -x $BIN_DIR/cloudflared ]] && return
  info '下载 cloudflared'
  download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" "$BIN_DIR/cloudflared"
}

install_hysteria() {
  [[ -x $BIN_DIR/hysteria ]] && return
  info '下载 Hysteria2'
  download "https://download.hysteria.network/app/latest/hysteria-linux-${ARCH}" "$BIN_DIR/hysteria"
}

random_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
}

udp_port_available() {
  python3 - "$1" <<'PY'
import socket, sys
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    try:
        sock.bind(('0.0.0.0', int(sys.argv[1])))
    except OSError:
        sys.exit(1)
PY
}

public_ipv4() {
  local ip
  ip=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org || true)
  if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$ip"
  else
    hostname -I | awk '{print $1}'
  fi
}

install_argo() {
  if [[ -f $STATE_DIR/argo.env ]] \
    && systemctl is-active --quiet jd-xray.service \
    && systemctl is-active --quiet jd-argo.service; then
    info 'Argo 已安装并运行，保留现有节点。'
    return
  fi
  install_xray
  install_cloudflared
  local ARGO_UUID ARGO_PATH ARGO_PORT
  if [[ -f $STATE_DIR/argo.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/argo.env"
  else
    ARGO_UUID=$(cat /proc/sys/kernel/random/uuid)
    ARGO_PATH="/$(openssl rand -hex 12)"
    ARGO_PORT=$(random_port)
    printf 'ARGO_UUID=%s\nARGO_PATH=%s\nARGO_PORT=%s\n' \
      "$ARGO_UUID" "$ARGO_PATH" "$ARGO_PORT" >"$STATE_DIR/argo.env"
  fi

  cat >"$CONFIG_DIR/xray.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": $ARGO_PORT,
    "protocol": "vless",
    "settings": {"clients": [{"id": "$ARGO_UUID"}], "decryption": "none"},
    "streamSettings": {"network": "ws", "wsSettings": {"path": "$ARGO_PATH"}}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF
  "$BIN_DIR/xray" run -test -config "$CONFIG_DIR/xray.json"

  cat >"$SYSTEMD_DIR/jd-xray.service" <<EOF
# jd-node-managed
[Unit]
Description=JD Xray Argo origin
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/xray run -config $CONFIG_DIR/xray.json
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  cat >"$SYSTEMD_DIR/jd-argo.service" <<EOF
# jd-node-managed
[Unit]
Description=JD Cloudflare Quick Tunnel
After=network-online.target jd-xray.service
Wants=network-online.target
Requires=jd-xray.service

[Service]
Type=simple
Environment=HOME=$APP_DIR
ExecStart=$BIN_DIR/cloudflared tunnel --url http://127.0.0.1:$ARGO_PORT --no-autoupdate
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now jd-xray.service jd-argo.service
  systemctl is-active --quiet jd-xray.service || die 'Xray 服务启动失败。'
  systemctl is-active --quiet jd-argo.service || die 'Argo 隧道服务启动失败。'
  info '等待临时隧道分配域名（最多 45 秒）'
  local i
  for ((i=0; i<23; i++)); do
    [[ -n $(current_argo_host) ]] && break
    sleep 2
  done
}

current_argo_host() {
  local invocation
  invocation=$(systemctl show -P InvocationID jd-argo.service 2>/dev/null || true)
  [[ -n $invocation ]] || return 0
  journalctl "_SYSTEMD_INVOCATION_ID=$invocation" --no-pager -o cat 2>/dev/null \
    | grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -n 1 | sed 's#https://##' || true
}

install_hy2() {
  if [[ -f $STATE_DIR/hy2.env ]] && systemctl is-active --quiet jd-hy2.service; then
    info 'Hysteria2 已安装并运行，保留现有节点。'
    return
  fi
  install_hysteria
  local HY2_PORT HY2_PASSWORD HY2_PIN requested
  if [[ -f $STATE_DIR/hy2.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/hy2.env"
  else
    read -r -p 'Hysteria2 UDP 端口 [443]：' requested
    HY2_PORT=${requested:-443}
    [[ $HY2_PORT =~ ^[0-9]+$ ]] && ((HY2_PORT >= 1 && HY2_PORT <= 65535)) \
      || die '端口必须是 1 到 65535 之间的数字。'
    udp_port_available "$HY2_PORT" || die "UDP $HY2_PORT 已被占用，请重新运行并选择其他端口。"
    HY2_PASSWORD=$(openssl rand -hex 24)
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "$CONFIG_DIR/hy2.key" -out "$CONFIG_DIR/hy2.crt" \
      -days 3650 -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1
    HY2_PIN=$(openssl x509 -in "$CONFIG_DIR/hy2.crt" -noout -fingerprint -sha256 | cut -d= -f2)
    printf 'HY2_PORT=%s\nHY2_PASSWORD=%s\nHY2_PIN=%s\n' \
      "$HY2_PORT" "$HY2_PASSWORD" "$HY2_PIN" >"$STATE_DIR/hy2.env"
  fi

  cat >"$CONFIG_DIR/hy2.yaml" <<EOF
listen: :$HY2_PORT
tls:
  cert: $CONFIG_DIR/hy2.crt
  key: $CONFIG_DIR/hy2.key
auth:
  type: password
  password: $HY2_PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
  cat >"$SYSTEMD_DIR/jd-hy2.service" <<EOF
# jd-node-managed
[Unit]
Description=JD Hysteria2 server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/hysteria server -c $CONFIG_DIR/hy2.yaml
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now jd-hy2.service
  systemctl is-active --quiet jd-hy2.service || die 'Hysteria2 服务启动失败。'
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active' \
    && ! ufw status | grep -Eq "^${HY2_PORT}/udp[[:space:]]+ALLOW"; then
    ufw allow "$HY2_PORT/udp" comment 'jd-node'
    printf 'HY2_UFW_MANAGED=1\n' >>"$STATE_DIR/hy2.env"
  fi
}

uninstall_all() {
  require_root
  command -v systemctl >/dev/null || die '找不到 systemctl，无法安全停止服务。'
  local service unit command_path managed=0 HY2_UFW_MANAGED=0

  # Only stop units created by this project. Older releases had no marker,
  # so their ExecStart path is also accepted as proof of ownership.
  for service in jd-argo jd-xray jd-hy2; do
    unit="$SYSTEMD_DIR/$service.service"
    if [[ -f $unit ]] && grep -Fq "$APP_DIR/" "$unit"; then
      systemctl stop "$service.service" || die "无法停止 $service，未继续删除其文件。"
      if systemctl is-active --quiet "$service.service"; then
        die "$service 仍在运行，已停止卸载。"
      fi
      systemctl disable "$service.service" >/dev/null
      rm -f -- "$unit"
      managed=1
    elif [[ -f $unit ]]; then
      printf '保留非本脚本创建的服务：%s\n' "$unit" >&2
    fi
  done
  systemctl daemon-reload
  systemctl reset-failed jd-argo.service jd-xray.service jd-hy2.service >/dev/null 2>&1 || true

  if [[ -f $STATE_DIR/hy2.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/hy2.env"
    if [[ ${HY2_UFW_MANAGED:-0} == 1 ]] && command -v ufw >/dev/null; then
      ufw --force delete allow "$HY2_PORT/udp" >/dev/null 2>&1 || \
        printf '未能移除 UFW 的 UDP %s 规则，请手动检查。\n' "$HY2_PORT" >&2
    fi
  fi

  [[ $APP_DIR == /opt/jd-node ]] || die '应用目录不符合预期，停止删除。'
  if [[ -d $APP_DIR || -L $APP_DIR ]]; then
    rm -rf -- "$APP_DIR"
    managed=1
  fi
  for command_path in /usr/local/bin/jd /usr/local/bin/jdxz; do
    if [[ -f $command_path ]] && grep -q 'jd-node-managed' "$command_path" 2>/dev/null; then
      rm -f -- "$command_path"
      managed=1
    fi
  done
  if ((managed)); then
    printf 'JD 节点服务、文件和命令已卸载。\n'
  else
    printf '未找到由本脚本安装的内容。\n'
  fi
}

show_nodes() {
  require_root
  local found=0 host ip
  if [[ -f $STATE_DIR/argo.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/argo.env"
    host=$(current_argo_host)
    printf '\nArgo：%s\n' "$(systemctl is-active jd-argo.service 2>/dev/null || true)"
    if [[ -n $host ]]; then
      printf 'vless://%s@%s:443?encryption=none&type=ws&path=%%2F%s&host=%s&security=tls&sni=%s#JD-Argo\n' \
        "$ARGO_UUID" "$host" "${ARGO_PATH#/}" "$host" "$host"
    else
      printf '暂未取得临时域名。请稍后执行 jd，或检查 journalctl -u jd-argo。\n'
    fi
    found=1
  fi
  if [[ -f $STATE_DIR/hy2.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/hy2.env"
    ip=$(public_ipv4)
    printf '\nHysteria2：%s\n' "$(systemctl is-active jd-hy2.service 2>/dev/null || true)"
    if [[ -n $ip ]]; then
      printf 'hysteria2://%s@%s:%s?insecure=1&sni=%s&pinSHA256=%s#JD-HY2\n' \
        "$HY2_PASSWORD" "$ip" "$HY2_PORT" "$SNI" "$HY2_PIN"
    else
      printf '无法识别公网 IPv4；请检查网络后重试 jd。\n'
    fi
    found=1
  fi
  ((found)) || printf '尚未安装节点。\n'
}

main() {
  if [[ ${1:-} == --uninstall ]]; then
    [[ $# -eq 1 ]] || die 'jdxz 不接受额外参数。'
    uninstall_all
    return
  fi
  if [[ ${1:-} == --show ]]; then
    show_nodes
    return
  fi
  if [[ ${1:-} == --help ]]; then
    printf '用法：bash run.sh（交互菜单）；安装后执行 sudo jd 查看节点，sudo jdxz 完全卸载。\n'
    return
  fi
  [[ $# -eq 0 ]] || die '未知参数。运行 bash run.sh --help 查看用法。'
  require_root
  printf '\nJD 节点部署\n  1) Argo 临时隧道 (VLESS)\n  2) Hysteria2\n  3) 安装全部\n  0) 退出\n\n'
  local choice
  read -r -p '请选择 [1/2/3/0]：' choice
  case "$choice" in
    0) return ;;
    1|2|3) prepare ;;
    *) die '无效选项。' ;;
  esac
  case "$choice" in
    1) install_argo ;;
    2) install_hy2 ;;
    3) install_argo; install_hy2 ;;
  esac
  show_nodes
  printf '\n以后运行 sudo jd 可查看当前节点链接。\n'
}

main "$@"
