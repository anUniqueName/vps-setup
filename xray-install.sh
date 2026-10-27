#!/usr/bin/env bash
# Debian/Ubuntu + systemd. Interactive terminal required, including when piped.
set -Eeuo pipefail
umask 077

log() { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
warning() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
urlencode() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g'; }
valid_domain() {
    local label
    [[ ${#1} -le 253 && "$1" == *.* && "$1" != *..* && "$1" != *. ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
    [[ ! "$1" =~ ^[0-9.]+$ ]]
}
valid_path() { [[ "$1" =~ ^/[a-zA-Z0-9/_-]+$ ]]; }

# Values interpolated below are generated locally or validated before use.
generate_config() {
    printf '{"log":{"loglevel":"warning"},"inbounds":['
    if [[ "$MODE" != 2 ]]; then
        cat <<EOF
{"tag":"vless-reality","listen":"0.0.0.0","port":443,"protocol":"vless",
 "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},
 "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
 "dest":"www.apple.com:443","serverNames":["www.apple.com"],
 "privateKey":"$PRIVATE_KEY","shortIds":["$SHORT_ID"]}},
 "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}}
EOF
    fi
    [[ "$MODE" != 3 ]] || printf ','
    if [[ "$MODE" != 1 ]]; then
        cat <<EOF
{"tag":"vless-ws-tls","listen":"0.0.0.0","port":$WS_PORT,"protocol":"vless",
 "settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
 "streamSettings":{"network":"ws","security":"tls",
 "wsSettings":{"path":"$WS_PATH"},
 "tlsSettings":{"minVersion":"1.2","alpn":["http/1.1"],"certificates":[{
 "certificateFile":"$TLS_DIR/origin.pem","keyFile":"$TLS_DIR/origin.key"}]}}}
EOF
    fi
    printf '],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]}\n'
}

ws_link() {
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s&alpn=http%%2F1.1#%s' \
        "$UUID" "$DOMAIN" "$WS_PORT" "$DOMAIN" "$DOMAIN" "$(urlencode "$WS_PATH")" "$(urlencode "$REMARK-WS-CF")"
}
reality_link() {
    printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
        "$UUID" "$SERVER_IP" "$PUBLIC_KEY" "$SHORT_ID" "$(urlencode "$REMARK-REALITY")"
}

main() {
    [[ $(id -u) == 0 ]] || die 'Please run with sudo bash.'
    command -v apt-get >/dev/null || die 'This script supports Debian/Ubuntu only.'
    command -v systemctl >/dev/null || die 'systemd is required.'
    printf '\n1) VLESS + TCP + REALITY (443, direct only)\n2) VLESS + WS + TLS (443, Cloudflare)\n3) Both: REALITY 443 + WS/TLS 8443\n'
    read -r -p 'Select [3]: ' MODE
    MODE=${MODE:-3}
    [[ "$MODE" =~ ^[123]$ ]] || die 'Choose 1, 2 or 3.'
    WS_PORT=443
    [[ "$MODE" != 3 ]] || WS_PORT=8443
    CONFIG_DIR=/usr/local/etc/xray
    CONFIG_FILE=$CONFIG_DIR/config.json
    if [[ -e "$CONFIG_FILE" ]]; then
        warning 'This replaces the complete Xray config and generates NEW client credentials.'
        warning 'Old nodes/custom routing will stop working; a config backup will be kept.'
        read -r -p 'Type REPLACE to continue: ' answer
        [[ "$answer" == REPLACE ]] || die 'Cancelled; config unchanged.'
    fi
    if [[ "$MODE" != 1 ]]; then
        read -r -p 'Cloudflare hostname (e.g. node.example.com): ' DOMAIN
        valid_domain "$DOMAIN" || die 'Enter a hostname only, without https://, path or port.'
        DOMAIN=${DOMAIN,,}
        read -r -p 'Origin certificate PEM file on this VPS: ' CERT_SOURCE
        read -r -p 'Origin private key PEM file on this VPS: ' KEY_SOURCE
        [[ -f "$CERT_SOURCE" && -r "$CERT_SOURCE" && -f "$KEY_SOURCE" && -r "$KEY_SOURCE" ]] || die 'Certificate/key file missing or unreadable.'
        read -r -p 'WebSocket path [random]: ' WS_PATH
        [[ -z "$WS_PATH" ]] || valid_path "$WS_PATH" || die 'Path must start with / and contain only letters, digits, /, _ or -.'
    fi
    read -r -p "Node remark [$(hostname)-$(date +%m%d)]: " REMARK
    REMARK=${REMARK:-$(hostname)-$(date +%m%d)}

    log 'Installing required packages...'
    apt-get update
    apt-get install -y curl ca-certificates openssl qrencode iproute2
    if [[ "$MODE" != 1 ]]; then
        openssl x509 -in "$CERT_SOURCE" -noout -checkend 0 >/dev/null || die 'Certificate is invalid or expired.'
        openssl x509 -in "$CERT_SOURCE" -noout -checkhost "$DOMAIN" | grep -q 'does match certificate' || die 'Certificate does not cover hostname.'
        cert_pub=$(openssl x509 -in "$CERT_SOURCE" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)
        key_pub=$(openssl pkey -in "$KEY_SOURCE" -passin pass: -pubout -outform DER | openssl dgst -sha256)
        [[ "$cert_pub" == "$key_pub" ]] || die 'Certificate and private key do not match.'
        WS_PATH=${WS_PATH:-/$(openssl rand -hex 12)}
    fi

    # Refuse to take ports from nginx, Apache or other services.
    local port listeners
    local -a ports=(443)
    [[ "$MODE" != 3 ]] || ports+=(8443)
    for port in "${ports[@]}"; do
        listeners=$(ss -H -ltnp "sport = :$port")
        if [[ -n "$listeners" ]] && printf '%s\n' "$listeners" | grep -v '"xray"' >/dev/null; then
            die "Port $port is used by another service. No service has been stopped."
        fi
    done

    WORK_DIR=$(mktemp -d /tmp/xray-setup.XXXXXXXX)
    trap 'rm -f -- "$WORK_DIR/install-release.sh"; rmdir -- "$WORK_DIR" 2>/dev/null || true' EXIT
    if [[ ! -x /usr/local/bin/xray ]]; then
        log 'Downloading official Xray installer (upstream code runs as root)...'
        curl -fSL --retry 3 --connect-timeout 15 --max-time 180 \
            https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh \
            -o "$WORK_DIR/install-release.sh"
        bash "$WORK_DIR/install-release.sh" install
    else
        log 'Reusing installed Xray; not upgrading the existing core.'
    fi
    XRAY=/usr/local/bin/xray
    [[ -x "$XRAY" ]] || die 'Xray installation failed.'
    systemctl cat xray >/dev/null || die 'xray.service not found.'
    # shortcut: custom systemd config paths are unsupported; use the standard installer service.
    service_cmd=$(systemctl show xray -p ExecStart --value)
    [[ "$service_cmd" == *"-config $CONFIG_FILE"* && "$service_cmd" != *'-confdir'* ]] || die 'Custom Xray service command detected; integrate manually.'
    SERVICE_USER=$(systemctl show xray -p User --value)
    SERVICE_USER=${SERVICE_USER:-root}
    SERVICE_GROUP=$(systemctl show xray -p Group --value)
    SERVICE_GROUP=${SERVICE_GROUP:-$(id -gn "$SERVICE_USER")}
    UUID=$("$XRAY" uuid)
    [[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die 'Invalid generated UUID.'
    if [[ "$MODE" != 2 ]]; then
        keys=$("$XRAY" x25519)
        PRIVATE_KEY=$(printf '%s\n' "$keys" | sed -nE 's/^(PrivateKey|Private key):[[:space:]]*([^[:space:]]+).*/\2/p')
        PUBLIC_KEY=$(printf '%s\n' "$keys" | sed -nE 's/^(Password|PublicKey|Public key):[[:space:]]*([^[:space:]]+).*/\2/p' | head -n 1)
        [[ "$PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ && "$PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] || die 'Cannot parse Xray x25519 output.'
        unset keys
        SHORT_ID=$(openssl rand -hex 8)
        SERVER_IP=$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org || true)
        read -r -p "Public IPv4 for REALITY link [$SERVER_IP]: " ip_input
        SERVER_IP=${ip_input:-$SERVER_IP}
        [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'A public IPv4 address is required.'
        IFS=. read -r -a octets <<< "$SERVER_IP"
        for octet in "${octets[@]}"; do
            (( 10#$octet <= 255 )) || die 'Invalid IPv4 address.'
        done
    fi

    install -d -m 755 "$CONFIG_DIR"
    if [[ "$MODE" != 1 ]]; then
        # Unique path keeps old certificates usable if config is rolled back.
        TLS_DIR=$(mktemp -d "$CONFIG_DIR/tls.XXXXXXXX")
        chown "root:$SERVICE_GROUP" "$TLS_DIR"
        chmod 750 "$TLS_DIR"
        install -m 640 -o root -g "$SERVICE_GROUP" "$CERT_SOURCE" "$TLS_DIR/origin.pem"
        install -m 640 -o root -g "$SERVICE_GROUP" "$KEY_SOURCE" "$TLS_DIR/origin.key"
    fi
    CANDIDATE=$(mktemp "$CONFIG_DIR/config.new.XXXXXXXX")
    generate_config > "$CANDIDATE"
    chown "root:$SERVICE_GROUP" "$CANDIDATE"
    chmod 640 "$CANDIDATE"
    if ! "$XRAY" run -test -config "$CANDIDATE"; then
        die "Config check failed. Live config unchanged. Candidate retained at $CANDIDATE"
    fi
    BACKUP=
    if [[ -e "$CONFIG_FILE" ]]; then
        BACKUP=$(mktemp "$CONFIG_DIR/config.backup.XXXXXXXX")
        cp -p -- "$CONFIG_FILE" "$BACKUP"
        log "Backup: $BACKUP"
    fi
    WAS_ACTIVE=false
    systemctl is-active --quiet xray && WAS_ACTIVE=true
    mv -f -- "$CANDIDATE" "$CONFIG_FILE"
    log 'Restarting Xray...'
    started=true
    systemctl restart xray || started=false
    sleep 2
    if [[ "$started" != true ]] || ! systemctl is-active --quiet xray; then
        if [[ -n "$BACKUP" ]]; then
            cp -p -- "$BACKUP" "$CONFIG_FILE"
            if [[ "$WAS_ACTIVE" == true ]]; then
                systemctl restart xray || warning 'Old config restored, but service still cannot start.'
            else
                systemctl stop xray || true
            fi
        else
            mv -- "$CONFIG_FILE" "$CONFIG_FILE.failed-$(date +%s)"
            systemctl stop xray || true
        fi
        die 'New config failed to start; rolled back. Check: journalctl -u xray -n 50 --no-pager'
    fi
    systemctl enable xray

    # Keep BBR optional: lack of kernel support must not fail a working setup.
    read -r -p 'Enable BBR if supported? [y/N]: ' enable_bbr
    if [[ "$enable_bbr" =~ ^[Yy]$ ]]; then
        modprobe tcp_bbr 2>/dev/null || true
        if sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
            printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-xray-bbr.conf
            sysctl -p /etc/sysctl.d/99-xray-bbr.conf || warning 'Could not apply BBR settings.'
        else
            warning 'Kernel does not support BBR; skipped.'
        fi
    fi
    RESULT_DIR=$(mktemp -d /root/xray-client.XXXXXXXX)
    if [[ "$MODE" != 2 ]]; then
        reality_link > "$RESULT_DIR/reality.txt"
        printf '\nREALITY (direct IP, NOT Cloudflare):\n%s\n' "$(cat "$RESULT_DIR/reality.txt")"
        qrencode -t ANSIUTF8 < "$RESULT_DIR/reality.txt" || warning 'Terminal QR rendering failed.'
        qrencode -s 10 -o "$RESULT_DIR/reality.png" < "$RESULT_DIR/reality.txt" || warning 'QR PNG failed.'
    fi
    if [[ "$MODE" != 1 ]]; then
        ws_link > "$RESULT_DIR/ws-cf.txt"
        printf '\nWS + TLS (Cloudflare):\n%s\n' "$(cat "$RESULT_DIR/ws-cf.txt")"
        qrencode -t ANSIUTF8 < "$RESULT_DIR/ws-cf.txt" || warning 'Terminal QR rendering failed.'
        qrencode -s 10 -o "$RESULT_DIR/ws-cf.png" < "$RESULT_DIR/ws-cf.txt" || warning 'QR PNG failed.'
        printf '\nCF: proxied A record -> VPS IPv4; SSL Full (strict); WebSockets ON.\n'
        printf 'Allow TCP %s in VPS firewall AND provider security group.\n' "$WS_PORT"
        printf 'Host/SNI: %s | WS path: %s | Flow: EMPTY\n' "$DOMAIN" "$WS_PATH"
        warning 'No firewall or Cloudflare account settings were changed. Origin CA requires the orange-cloud proxy.'
    fi
    log "Local Xray service running. Private client links/QR codes: $RESULT_DIR"
    warning 'Cloudflare end-to-end connectivity has NOT been verified. REALITY cannot rescue a blocked direct IP.'
    printf 'Status: systemctl status xray\nLogs: journalctl -u xray -n 50 --no-pager\n'
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    if ! (: </dev/tty) 2>/dev/null; then
        die 'An interactive terminal is required. Run from an SSH terminal, not a background job.'
    fi
    # Keep menu answers separate from the script stream in curl ... | sudo bash.
    main "$@" </dev/tty
fi
