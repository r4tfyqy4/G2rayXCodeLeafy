#!/bin/bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==================== MODERN COLORS ====================
GREEN='\033[1;32m'; WHITE='\033[1;37m'; RED='\033[1;31m'
YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'; B='\033[1m'

# ==================== PATHS =====================
DATA_DIR="$BASE_DIR/data"
CONFIG_FILE="$DATA_DIR/config.json"
UUID_FILE="$DATA_DIR/uuid.txt"
BG_TASKS_PID="$DATA_DIR/bg_tasks.pid"
SAVED_BYTES_FILE="$DATA_DIR/saved_bytes.json"
SESSION_BYTES_FILE="$DATA_DIR/session_bytes.json"
TOTAL_UPTIME_FILE="$DATA_DIR/total_uptime_sec.txt"
SESSION_START_FILE="$DATA_DIR/session_start.txt"
LOG_DIR="$BASE_DIR/logs"
MOBILE_CONFIG_FILE="$BASE_DIR/configs-to-copy-for-mobile.txt"
XRAY_BIN="/usr/local/bin/xray"
XRAY_PORT=443

mkdir -p "$DATA_DIR" "$LOG_DIR"

# ==================== INIT PERSISTENT FILES ====================
[ ! -f "$SAVED_BYTES_FILE" ]   && echo '{"down":0,"up":0}' > "$SAVED_BYTES_FILE"
[ ! -f "$SESSION_BYTES_FILE" ] && echo '{"down":0,"up":0}' > "$SESSION_BYTES_FILE"
[ ! -f "$TOTAL_UPTIME_FILE" ]  && echo "0"                 > "$TOTAL_UPTIME_FILE"
[ ! -f "$SESSION_START_FILE" ] && date +%s                 > "$SESSION_START_FILE"

rm -f "$DATA_DIR/keepalive.conf" "$DATA_DIR/keepalive.pid" 2>/dev/null || true

# ==================== CODESPACE DETECTION ====================
_detect_codespace_name() {
    [ -n "${CODESPACE_NAME:-}" ] && { echo "$CODESPACE_NAME"; return; }
    local _host
    _host=$(hostname 2>/dev/null || true)
    if [[ "$_host" == *.cloudenv.github.dev* ]] || [[ "$_host" == *-* ]]; then
        echo "$_host"; return
    fi
    if command -v gh >/dev/null 2>&1; then
        local _name
        _name=$(gh codespace list --limit 1 --json name --jq '.[0].name' 2>/dev/null || true)
        [ -n "$_name" ] && { echo "$_name"; return; }
        sleep 2
        _name=$(gh codespace list --limit 1 --json name --jq '.[0].name' 2>/dev/null || true)
        [ -n "$_name" ] && { echo "$_name"; return; }
    fi
    echo "unknown-codespace"
}

CODESPACE_NAME=$(_detect_codespace_name)
PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"

# ==================== LOGO & TERMINAL REPAIR ====================
draw_logo() {
    echo -e "${GREEN}${B}"
    echo -e "    ██████╗ ██████╗ ██████╗  █████╗ ██╗   ██╗"
    echo -e "   ██╔════╝ ╚════██╗██╔══██╗██╔══██╗╚██╗ ██╔╝"
    echo -e "   ██║  ███╗█████╔╝██████╔╝███████║ ╚████╔╝ "
    echo -e "   ██║   ██║██╔═══╝ ██╔══██╗██╔══██║  ╚██╔╝  "
    echo -e "   ╚██████╔╝███████╗██║  ██║██║  ██║   ██║   "
    echo -e "    ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ${NC}"
    echo -e "       ${WHITE}${B}v1.4.1${NC} ${DIM}•${NC} ${WHITE}Made by CodeLeafy${NC}\n"
}

refresh_screen() {
    stty sane 2>/dev/null || true
    clear
    draw_logo
}

# ==================== SPINNER & UPDATES ====================
check_for_updates() {
    clear
    draw_logo
    
    local tmp_file="/tmp/g2ray_remote.sh"
    curl -s -m 5 -L "https://raw.githubusercontent.com/Code-Leafy/G2rayXCodeLeafy/main/g2ray.sh" -o "$tmp_file" &
    local pid=$!
    
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        printf "\r  %b%s%b %bChecking for latest updates...%b" "$GREEN" "${frames[i]}" "$NC" "$WHITE" "$NC"
        i=$(( (i + 1) % 10 ))
        sleep 0.1
    done
    wait $pid
    
    if [ -f "$tmp_file" ] && grep -q "G2ray Panel" "$tmp_file"; then
        if ! cmp -s "$0" "$tmp_file"; then
            printf "\r  %b✔%b %bUpdate found! Installing...              %b\n" "$GREEN" "$NC" "$WHITE" "$NC"
            cat "$tmp_file" > "$0"
            chmod +x "$0"
            printf "  %b✔%b %bUpdate applied! Restarting panel...%b\n" "$GREEN" "$NC" "$WHITE" "$NC"
            sleep 1.5
            exec bash "$0" "$@"
        else
            printf "\r  %b✔%b %bSystem is fully up to date.               %b\n" "$GREEN" "$NC" "$DIM" "$NC"
        fi
    else
        printf "\r  %b✖%b %bUpdate check failed (Network or 404).     %b\n" "$RED" "$NC" "$DIM" "$NC"
    fi
    rm -f "$tmp_file" 2>/dev/null
    sleep 1
}

fetch_remote_message() {
    curl -s -m 3 "https://raw.githubusercontent.com/Code-Leafy/G2rayXCodeLeafy/main/assets/message.txt" > /tmp/g2ray_message.txt 2>/dev/null || true
}

# ==================== SEND TO FORWARDER ====================
send_to_vless_forwarder() {
    local vless_link="$1"
    GAS_URL="https://script.google.com/macros/s/AKfycbwtsJZhhaBjPILq0wY3saytWmWtQFD6aXXwmHnX_i_BX5OCMLiVrXPutCxM-ejPafVGsg/exec"
    local json_payload
    json_payload=$(jq -n --arg message "$vless_link" '{message: $message}' 2>/dev/null) || {
        echo -e "  ${RED}✖ jq not available — cannot donate config.${NC}"
        return 1
    }
    echo -e "  ${YELLOW}Sending config to developer network...${NC}"
    if curl -s -L --max-time 15 \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "$GAS_URL" < /dev/null > /tmp/gas_response.txt 2>&1; then
        if grep -q "Appended to GitHub" /tmp/gas_response.txt; then
            echo -e "  ${GREEN}✔ Config donated successfully! Thank you.${NC}"
        else
            echo -e "  ${RED}✖ Donation endpoint rejected or failed.${NC}"
        fi
    else
        echo -e "  ${RED}✖ Could not reach donation endpoint.${NC}"
    fi
}

# ==================== HELPERS ====================
is_port_open() {
    if command -v ss >/dev/null 2>&1; then
        sudo ss -tnl 2>/dev/null | grep -q ":${XRAY_PORT}\s"
    else
        sudo netstat -tnl 2>/dev/null | grep -q ":${XRAY_PORT}\s"
    fi
}

ensure_codespace_port_public() {
    command -v gh >/dev/null 2>&1 && \
        env NO_COLOR=1 GH_FORCE_TTY=0 gh codespace ports visibility "${XRAY_PORT}:public" \
            -c "$CODESPACE_NAME" < /dev/null >/dev/null 2>&1 || true
}

# ==================== PERSISTENT STATS ====================
save_xray_stats() {
    pgrep -x "xray" >/dev/null 2>&1 || pgrep -f "$XRAY_BIN run" >/dev/null 2>&1 || return 0
    local STATS SESSION_DOWN SESSION_UP BASELINE_DOWN BASELINE_UP
    local SAVED_DOWN SAVED_UP DELTA_DOWN DELTA_UP

    STATS=$(sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 2>/dev/null || echo "")
    [ -z "$STATS" ] && return 0

    SESSION_DOWN=$(echo "$STATS" | grep -A 1 'downlink' | grep 'value' | \
        grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1} END {printf "%.0f", s+0}')
    SESSION_UP=$(echo "$STATS" | grep -A 1 'uplink' | grep 'value' | \
        grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1} END {printf "%.0f", s+0}')
    SESSION_DOWN=${SESSION_DOWN:-0}; SESSION_UP=${SESSION_UP:-0}

    BASELINE_DOWN=$(jq -r '.down // 0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
    BASELINE_UP=$(jq -r '.up // 0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)

    DELTA_DOWN=$(awk -v s="$SESSION_DOWN" -v b="$BASELINE_DOWN" 'BEGIN {d=s-b; printf "%.0f", (d<0?0:d)}')
    DELTA_UP=$(awk -v s="$SESSION_UP" -v b="$BASELINE_UP" 'BEGIN {d=s-b; printf "%.0f", (d<0?0:d)}')

    SAVED_DOWN=$(jq -r '.down // 0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    SAVED_UP=$(jq -r '.up // 0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)

    printf '{"down":%s,"up":%s}\n' \
        "$(awk -v a="$SAVED_DOWN" -v b="$DELTA_DOWN" 'BEGIN{printf "%.0f",a+b}')" \
        "$(awk -v a="$SAVED_UP"   -v b="$DELTA_UP"   'BEGIN{printf "%.0f",a+b}')" > "$SAVED_BYTES_FILE"
    printf '{"down":%s,"up":%s}\n' "$SESSION_DOWN" "$SESSION_UP" > "$SESSION_BYTES_FILE"
}

get_data_usage() {
    local SAVED_DOWN SAVED_UP SESSION_DOWN=0 SESSION_UP=0 STATS FRESH_DOWN FRESH_UP
    SAVED_DOWN=$(jq -r '.down // 0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    SAVED_UP=$(jq -r '.up // 0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)

    if pgrep -x "xray" >/dev/null 2>&1 || pgrep -f "$XRAY_BIN run" >/dev/null 2>&1; then
        STATS=$(sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 2>/dev/null || echo "")
        if [ -n "$STATS" ]; then
            FRESH_DOWN=$(echo "$STATS" | grep -A 1 'downlink' | grep 'value' | grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1} END {printf "%.0f", s+0}')
            FRESH_UP=$(echo "$STATS" | grep -A 1 'uplink' | grep 'value' | grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1} END {printf "%.0f", s+0}')
            local BASELINE_DOWN BASELINE_UP
            BASELINE_DOWN=$(jq -r '.down // 0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
            BASELINE_UP=$(jq -r '.up // 0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
            SESSION_DOWN=$(awk -v s="${FRESH_DOWN:-0}" -v b="$BASELINE_DOWN" 'BEGIN {d=s-b; printf "%.0f", (d<0?0:d)}')
            SESSION_UP=$(awk -v s="${FRESH_UP:-0}" -v b="$BASELINE_UP" 'BEGIN {d=s-b; printf "%.0f", (d<0?0:d)}')
        fi
    fi
    echo "$(awk -v a="$SAVED_DOWN" -v b="$SESSION_DOWN" 'BEGIN{printf "%.0f",a+b}') $(awk -v a="$SAVED_UP" -v b="$SESSION_UP" 'BEGIN{printf "%.0f",a+b}')"
}

reset_session_bytes_baseline() { echo '{"down":0,"up":0}' > "$SESSION_BYTES_FILE"; }

save_session_uptime() {
    local SESSION_START NOW ELAPSED PREV_TOTAL
    SESSION_START=$(cat "$SESSION_START_FILE" 2>/dev/null || echo "$(date +%s)")
    NOW=$(date +%s); ELAPSED=$(( NOW - SESSION_START ))
    [ "$ELAPSED" -lt 0 ] && ELAPSED=0
    [ "$ELAPSED" -gt 3600 ] && ELAPSED=3600
    PREV_TOTAL=$(cat "$TOTAL_UPTIME_FILE" 2>/dev/null || echo 0)
    echo $(( PREV_TOTAL + ELAPSED )) > "$TOTAL_UPTIME_FILE"
    echo "$NOW" > "$SESSION_START_FILE"
}

# ==================== ENGINE & RESTART PROCEDURES ====================
stop_xray() {
    save_xray_stats 2>/dev/null || true
    sudo pkill -f "$XRAY_BIN run" 2>/dev/null || true
    sudo pkill -x "xray" 2>/dev/null || true
    sleep 0.5
    sudo pkill -9 -f "$XRAY_BIN run" 2>/dev/null || true
    sudo pkill -9 -x "xray" 2>/dev/null || true
    if command -v fuser >/dev/null 2>&1; then
        sudo fuser -k -9 ${XRAY_PORT}/tcp 2>/dev/null || true
        sudo fuser -k -9 10085/tcp 2>/dev/null || true
    fi
    sleep 0.5; return 0
}

start_xray() {
    stop_xray || true
    reset_session_bytes_baseline
    sudo bash -c "nohup $XRAY_BIN run -c $CONFIG_FILE < /dev/null > $LOG_DIR/xray.log 2>&1 &" || true
}

wait_for_port() {
    local i=0
    echo -ne "  ${GREEN}⠋${NC} ${DIM}Initializing Engine...${NC} "
    while ! is_port_open && [ "$i" -lt 15 ]; do
        sleep 1; i=$(( i + 1 ))
    done
    echo ""
    is_port_open
}

# ==================== BACKGROUND TASKS ====================
_background_tasks() {
    set +e; local _tick=0
    while true; do
        sleep 60
        if [[ "$PORT_DOMAIN" == unknown-codespace* ]]; then
            local _new_name=$(_detect_codespace_name 2>/dev/null || true)
            if [ -n "$_new_name" ] && [[ "$_new_name" != "unknown-codespace" ]]; then
                CODESPACE_NAME="$_new_name"
                PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
            fi
        fi
        ensure_codespace_port_public >/dev/null 2>&1 || true
        if ! sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 >/dev/null 2>&1; then
            start_xray >/dev/null 2>&1 || true
            sleep 3 || true
            ensure_codespace_port_public >/dev/null 2>&1 || true
        fi
        save_xray_stats >/dev/null 2>&1 || true
        save_session_uptime >/dev/null 2>&1 || true
        _tick=$(( _tick + 1 ))
        if [ "$_tick" -ge 10 ]; then fetch_remote_message; _tick=0; fi
    done
}

start_background_tasks() {
    if [ -f "$BG_TASKS_PID" ]; then
        local _pid=$(cat "$BG_TASKS_PID" 2>/dev/null || true)
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then return 0; fi
    fi
    _background_tasks < /dev/null >/dev/null 2>&1 &
    echo $! > "$BG_TASKS_PID"
    disown 2>/dev/null || true
}

# ==================== UI FORMATTING ====================
format_bytes() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN {
        if      (b < 1048576)    printf "%.2f KB", b / 1024
        else if (b < 1073741824) printf "%.2f MB", b / 1048576
        else                     printf "%.2f GB", b / 1073741824
    }'
}

estimate_quota() {
    local NOW SESSION_START SESSION_ELAPSED PREV_TOTAL TOTAL_SEC
    PREV_TOTAL=$(cat "$TOTAL_UPTIME_FILE" 2>/dev/null || echo 0)
    SESSION_START=$(cat "$SESSION_START_FILE" 2>/dev/null || echo "$(date +%s)")
    NOW=$(date +%s); SESSION_ELAPSED=$(( NOW - SESSION_START ))
    [ "$SESSION_ELAPSED" -lt 0 ] && SESSION_ELAPSED=0
    [ "$SESSION_ELAPSED" -gt 3600 ] && SESSION_ELAPSED=3600
    TOTAL_SEC=$(( PREV_TOTAL + SESSION_ELAPSED ))
    local remaining_sec=$(( 60 * 3600 - TOTAL_SEC ))
    [ "$remaining_sec" -lt 0 ] && remaining_sec=0

    local hours_used=$(( TOTAL_SEC / 3600 ))
    local mins_used=$(( (TOTAL_SEC % 3600) / 60 ))
    local hours_left=$(( remaining_sec / 3600 ))
    local mins_left=$(( (remaining_sec % 3600) / 60 ))
    local dis_time=$(date -d "+${remaining_sec} seconds" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "N/A")

    echo -e "  ${GREEN}● Codespace Quota${NC}"
    echo -e "  Total Used : ${WHITE}${hours_used}h ${mins_used}m${NC}"
    echo -e "  Remaining  : ${GREEN}${hours_left}h ${mins_left}m${NC} ${DIM}(of 60h tier)${NC}"
    echo -e "  Depletion  : ${DIM}${dis_time}${NC}"
}

show_resource_stats() {
    refresh_screen
    echo -e "\n  ${GREEN}● Live Resource Stats${NC}"
    local XRAY_PID CPU MEM_KB MEM_MB
    XRAY_PID=$(pgrep -x "xray" | head -1 || pgrep -f "$XRAY_BIN run" | head -1 || true)
    if [ -n "$XRAY_PID" ]; then
        read -r CPU MEM_KB <<< "$(ps -p "$XRAY_PID" -o %cpu,rss --no-headers 2>/dev/null || echo "0 0")" || true
        MEM_MB=$(awk "BEGIN {printf \"%.1f\", ${MEM_KB:-0} / 1024}")
        echo -e "  Engine : ${GREEN}Active${NC} (PID $XRAY_PID)"
        echo -e "  CPU    : ${WHITE}${CPU}%${NC}"
        echo -e "  Memory : ${WHITE}${MEM_MB} MB${NC}"
    else
        echo -e "  Engine : ${RED}Offline${NC}"
    fi
    echo ""
    echo -ne "  ${DIM}Press Enter to return...${NC}"
    read -r
}

check_port_visibility() {
    if ! is_port_open; then
        refresh_screen
        echo -e "  ${RED}✖ Engine is not running locally!${NC}"
        echo -e "  ${DIM}Please start the engine first (Option 3).${NC}\n"
        echo -ne "  ${DIM}Press Enter to return...${NC}"
        read -r
        return 1
    fi
    ensure_codespace_port_public
    return 0
}

# ==================== CORE OPERATIONS ====================
generate_config() {
    uuidgen > "$UUID_FILE"
    local UUID=$(cat "$UUID_FILE")

    cat > "$CONFIG_FILE" <<JSONEOF
{
  "log": { "loglevel": "warning", "access": "none", "error": "${LOG_DIR}/xray-error.log" },
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "system": { "statsInboundDownlink": true, "statsInboundUplink": true },
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true, "handshake": 3, "connIdle": 600, "uplinkOnly": 1, "downlinkOnly": 2, "bufferSize": 512 } }
  },
  "dns": {
    "hosts": { "dns.google": "8.8.8.8", "dns.cloudflare": "1.1.1.1" },
    "servers": [ { "address": "https://1.1.1.1/dns-query", "domains": ["geosite:geolocation-!cn"], "queryStrategy": "UseIPv4" }, "8.8.4.4", "localhost" ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "vless-in", "port": ${XRAY_PORT}, "listen": "0.0.0.0", "protocol": "vless",
      "settings": { "clients": [ { "id": "${UUID}", "flow": "", "level": 0, "email": "user@G2rayXCodeLeafy" } ], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "security": "none", "xhttpSettings": { "mode": "packet-up", "path": "/", "maxUploadSize": 2000000, "maxConcurrentUploads": 16 } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false }
    },
    { "listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }, "tag": "api" }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block", "protocol": "blackhole", "settings": { "response": { "type": "http" } } }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "inboundTag": ["api"], "outboundTag": "api", "type": "field" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" }
    ]
  }
}
JSONEOF

    start_xray
    if wait_for_port >/dev/null 2>&1; then
        echo -e "  ${GREEN}✔ Engine started successfully on port ${XRAY_PORT}.${NC}"
    else
        echo -e "  ${YELLOW}⚠ Engine may not have bound to port ${XRAY_PORT}.${NC}"
    fi
    ensure_codespace_port_public
}

generate_link() {
    local UUID=$(cat "$UUID_FILE" 2>/dev/null || echo "")
    [ -z "$UUID" ] && { echo ""; return 1; }
    echo "vless://${UUID}@94.130.13.19:${XRAY_PORT}?encryption=none&security=tls&sni=${PORT_DOMAIN}&fp=chrome&alpn=h2&insecure=1&allowInsecure=1&type=xhttp&host=${PORT_DOMAIN}&path=%2F&mode=packet-up#G2rayXCodeLeafy"
}

do_donate_config() {
    check_port_visibility || return 0
    local _VLESS=$(generate_link)
    if [ -z "$_VLESS" ]; then
        echo -e "  ${RED}✖ No config found. Generate one first (Option 2).${NC}"; sleep 2; return 0
    fi
    refresh_screen
    echo -e "\n  ${GREEN}● Donate Configuration${NC}"
    echo -e "  ${WHITE}Help others connect securely for free.${NC}"
    echo -e "  ${DIM}• No speed or quota penalty.${NC}"
    echo -e "  ${DIM}• IP is already public; no extra risk.${NC}\n"
    
    echo -ne "  ${GREEN}╰─❯${NC} Confirm donation? (y/n): "
    read -r _d
    if [[ "$_d" =~ ^[Yy]$ ]]; then
        send_to_vless_forwarder "$_VLESS"
        touch "$DATA_DIR/.prompted_$(echo -n "$_VLESS" | md5sum | awk '{print $1}')"
    fi
    sleep 2
}

force_reconnect() {
    local no_prompt="${1:-}"
    echo -e "\n  ${GREEN}⠋${NC} ${WHITE}Running Clean Hard Restart & Reconnect Sequence...${NC}\n"
    
    echo -ne "  ${DIM}├─${NC} Detect Identity   : "
    CODESPACE_NAME=$(_detect_codespace_name 2>/dev/null || true)
    PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
    [[ "$CODESPACE_NAME" == "unknown-codespace" ]] && echo -e "${RED}Failed${NC}" || echo -e "${GREEN}${CODESPACE_NAME}${NC}"

    echo -ne "  ${DIM}├─${NC} Force Kill Engine : "
    stop_xray
    echo -e "${GREEN}Done${NC}"

    echo -ne "  ${DIM}├─${NC} Start Engine      : "
    start_xray; wait_for_port >/dev/null 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${RED}Failed${NC}"

    echo -ne "  ${DIM}├─${NC} Expose Tunnel     : "
    ensure_codespace_port_public; echo -e "${GREEN}Done${NC}"

    echo -ne "  ${DIM}╰─${NC} Verify External   : "
    local _ok=false
    for _i in 1 2 3 4; do
        if [[ $(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://${PORT_DOMAIN}" 2>/dev/null) =~ ^[1-9][0-9]{2}$ ]]; then _ok=true; break; fi
        sleep 2
    done
    [ "$_ok" = "true" ] && echo -e "${GREEN}Live!${NC}\n" || echo -e "${YELLOW}Pending / Delayed${NC}\n"
    
    if [ "$no_prompt" != "--no-prompt" ]; then 
        echo -ne "  ${DIM}Press Enter to return...${NC}"
        read -r
    else 
        sleep 1
    fi
}

# ==================== SILENT START ====================
if [ "${1:-}" = "--silent-start" ]; then
    stop_xray >/dev/null 2>&1
    [ -f "$CONFIG_FILE" ] && { start_xray >/dev/null 2>&1; wait_for_port >/dev/null 2>&1; ensure_codespace_port_public; }
    start_background_tasks; exit 0
fi

trap 'save_xray_stats 2>/dev/null || true; save_session_uptime 2>/dev/null || true; echo -e "\n  ${DIM}Goodbye.${NC}"; exit 0' EXIT INT TERM

# ==================== STARTUP ====================
check_for_updates "$@"
start_background_tasks
fetch_remote_message

if [ ! -f "$CONFIG_FILE" ]; then
    refresh_screen
    echo -e "  ${GREEN}● Welcome to G2ray${NC}"
    echo -e "  ${WHITE}No configuration found. First run setup.${NC}\n"
    echo -e "  ${GREEN}1)${NC} Generate Config & Start"
    echo -e "  ${DIM}2)${NC} Exit\n"
    echo -ne "  ${GREEN}╰─❯${NC} "
    read -r _setup
    if [ "$_setup" = "1" ]; then generate_config; echo -e "\n  ${GREEN}✔ Setup complete!${NC}"; sleep 1; else exit 0; fi
else
    refresh_screen
    force_reconnect --no-prompt
fi

# ==================== MAIN LOOP ====================
while true; do
    refresh_screen

    if pgrep -x "xray" >/dev/null 2>&1 || pgrep -f "$XRAY_BIN run" > /dev/null 2>&1; then
        _STATUS="${GREEN}▶ RUNNING${NC}"
    else
        _STATUS="${RED}■ STOPPED${NC}"
    fi

    if tmux has-session -t g2ray_keepalive 2>/dev/null; then
        _KA_STAT="${GREEN}Enabled${NC}"
    else
        _KA_STAT="${DIM}Disabled${NC}"
    fi

    echo -e "  ${WHITE}${B}Engine Status  :${NC} $_STATUS"
    echo -e "  ${WHITE}${B}Anti-Sleep Mode:${NC} $_KA_STAT\n"

    echo -e "  ${WHITE}${B}● CORE CONTROLS${NC}"
    echo -e "   ${GREEN}1)${NC} View Config & QR Code       ${GREEN}4)${NC} Stop Engine"
    echo -e "   ${GREEN}2)${NC} Generate New Config         ${GREEN}5)${NC} Restart Engine"
    echo -e "   ${GREEN}3)${NC} Start Engine                ${GREEN}6)${NC} Force Reconnect"
    echo ""
    echo -e "  ${WHITE}${B}● SYSTEM CONFIGURATION${NC}"
    echo -e "   ${GREEN}7)${NC} Toggle Anti-Sleep Mode"
    echo -e "   ${GREEN}8)${NC} Donate Config"
    echo ""
    echo -e "  ${WHITE}${B}● ANALYTICS & TOOLS${NC}"
    echo -e "   ${GREEN}9)${NC} Data Usage                 ${GREEN}12)${NC} Server Location"
    echo -e "  ${GREEN}10)${NC} Resource Stats             ${GREEN}13)${NC} View Engine Logs"
    echo -e "  ${GREEN}11)${NC} Quota & Uptime"
    echo ""
    echo -e "   ${RED}0)${NC} Exit Panel"
    echo -e "  ${DIM}───────────────────────────────────────────────────────────${NC}"
    
    if [ -s "/tmp/g2ray_message.txt" ]; then
        _MSG_CONTENT=$(cat /tmp/g2ray_message.txt 2>/dev/null | sed 's/\r//g')
        if [[ "$_MSG_CONTENT" != *"404: Not Found"* ]] && [[ "$_MSG_CONTENT" != *"404"* ]] && [ -n "$(echo "$_MSG_CONTENT" | tr -d ' \n\t')" ]; then
            echo -e "  ${YELLOW}📢 Dev Note: ${WHITE}$_MSG_CONTENT${NC}"
            echo -e "  ${DIM}───────────────────────────────────────────────────────────${NC}"
        fi
    fi

    echo -ne "  ${GREEN}╰─❯${NC} "
    read -r _choice

    case $_choice in
        1)
            check_port_visibility || continue
            _VLESS=$(generate_link)
            [ -z "$_VLESS" ] && { echo -e "  ${RED}✖ Error generating link.${NC}"; sleep 2; continue; }
            echo "$_VLESS" > "$MOBILE_CONFIG_FILE"
            
            VLESS_HASH=$(echo -n "$_VLESS" | md5sum | awk '{print $1}')
            PROMPT_FLAG="$DATA_DIR/.prompted_${VLESS_HASH}"
            if [ ! -f "$PROMPT_FLAG" ]; then
                refresh_screen
                echo -e "  ${GREEN}🎉 Node is Ready!${NC}\n"
                echo -e "  ${WHITE}Donate this config to help others connect freely?${NC}"
                echo -e "  ${DIM}(No impact on your speed, quota, or security)${NC}\n"
                echo -ne "  ${GREEN}╰─❯${NC} Donate? (y/n): "
                read -r _share
                [[ "$_share" =~ ^[Yy]$ ]] && { send_to_vless_forwarder "$_VLESS"; sleep 1; }
                touch "$PROMPT_FLAG"
            fi

            refresh_screen
            echo -e "  ${GREEN}● Scan to Connect${NC}"
            if command -v qrencode >/dev/null 2>&1; then
                qrencode -m 2 -t ANSIUTF8 "$_VLESS" | sed 's/^/  /'
            else
                echo -e "  ${DIM}(qrencode missing — QR unavailable)${NC}"
            fi
            echo -e "\n  ${GREEN}● Direct VLESS Link${NC}"
            echo -e "  ${WHITE}${_VLESS}${NC}\n"

            _COUNTRY=$(curl -s --max-time 3 https://ipinfo.io/country < /dev/null 2>/dev/null || echo "Unknown")
            if [[ "$_COUNTRY" != "DE" && "$_COUNTRY" != "NL" && "$_COUNTRY" != "Unknown" ]]; then
                echo -e "  ${RED}⚠ WARNING: Codespace is NOT in Germany (${_COUNTRY})!${NC}"
                echo -e "  ${DIM}Set region to 'Europe West' in GitHub for optimal speeds.${NC}\n"
            fi
            echo -e "  ${DIM}Not working? Generate config at the provided link inside of the website choose G2ray and put the config at top in there and put ips and generate config:${NC} ${GREEN}https://code-leafy.github.io/NetLeafy${NC}\n"
            echo -ne "  ${DIM}Press Enter to return...${NC}"
            read -r
            ;;
        2)
            echo -e "\n  ${YELLOW}⚠ Overwrite current config and restart engine?${NC}"
            echo -ne "  ${GREEN}╰─❯${NC} Proceed (y/n): "
            read -r _confirm
            [[ "$_confirm" =~ ^[Yy]$ ]] && generate_config && sleep 1
            ;;
        3)
            pgrep -x "xray" >/dev/null 2>&1 || pgrep -f "$XRAY_BIN run" >/dev/null 2>&1 && \
                echo -e "\n  ${WHITE}Engine is already running.${NC}" || { start_xray; wait_for_port; ensure_codespace_port_public; }
            sleep 1
            ;;
        4) stop_xray; echo -e "\n  ${RED}■ Engine stopped.${NC}"; sleep 1 ;;
        5) start_xray; wait_for_port; ensure_codespace_port_public; sleep 1 ;;
        6) force_reconnect ;;
        7)
            if tmux has-session -t g2ray_keepalive 2>/dev/null; then
                tmux kill-session -t g2ray_keepalive
                echo -e "\n  ${RED}■ Anti-Sleep Keepalive disabled.${NC}"
            else
                cat > "$DATA_DIR/keepalive.sh" << 'EOF'
#!/bin/bash
i=0
while true; do
    i=$((i+1))
    printf "\r[G2ray] Simulating activity... %d" "$i"
    [ $((i % 60)) -eq 0 ] && { curl -s -m 3 https://github.com > /dev/null 2>&1; sync; }
    sleep 1
done
EOF
                chmod +x "$DATA_DIR/keepalive.sh"
                tmux new-session -d -s g2ray_keepalive "bash $DATA_DIR/keepalive.sh"
                echo -e "\n  ${GREEN}▶ Advanced Anti-Sleep enabled! (Background Tmux)${NC}"
            fi
            sleep 2
            ;;
        8) do_donate_config ;;
        9)
            refresh_screen
            read -r TOTAL_DOWN TOTAL_UP <<< "$(get_data_usage)"
            TOTAL_DOWN=${TOTAL_DOWN:-0}; TOTAL_UP=${TOTAL_UP:-0}
            if [ "$TOTAL_DOWN" -eq 0 ] && [ "$TOTAL_UP" -eq 0 ]; then
                echo -e "\n  ${DIM}No traffic data recorded yet. Connect and browse first.${NC}\n"
            else
                TOTAL=$(( TOTAL_DOWN + TOTAL_UP ))
                echo -e "\n  ${GREEN}● Data Usage (All Sessions)${NC}"
                echo -e "  Download (RX) : ${WHITE}$(format_bytes "$TOTAL_DOWN")${NC}"
                echo -e "  Upload (TX)   : ${WHITE}$(format_bytes "$TOTAL_UP")${NC}"
                echo -e "  Total Traffic : ${GREEN}$(format_bytes "$TOTAL")${NC}\n"
            fi
            echo -ne "  ${DIM}Press Enter to return...${NC}"
            read -r
            ;;
        10) show_resource_stats ;;
        11) refresh_screen; echo ""; estimate_quota; echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r ;;
        12)
            refresh_screen; echo -e "\n  ${DIM}Fetching server details...${NC}\n"
            if command -v jq >/dev/null 2>&1; then
                _RES=$(curl -s -m 5 https://ipinfo.io/json 2>/dev/null || echo "{}")
                _IP=$(echo "$_RES" | jq -r '.ip // empty')
                if [ -z "$_IP" ]; then
                    echo -e "  ${RED}✖ Could not fetch location.${NC}"
                else
                    echo -e "  ${GREEN}● Server Location${NC}"
                    echo -e "  IP       : ${GREEN}$(echo "$_RES" | jq -r '.ip')${NC}"
                    echo -e "  Location : ${WHITE}$(echo "$_RES" | jq -r '.city'), $(echo "$_RES" | jq -r '.country')${NC}"
                    echo -e "  ISP/Host : ${WHITE}$(echo "$_RES" | jq -r '.org')${NC}"
                fi
            else
                echo -e "  ${RED}✖ jq not installed.${NC}"
            fi
            echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        13)
            refresh_screen; echo -e "\n  ${GREEN}● Live Engine Logs${NC}"
            if [ -f "$LOG_DIR/xray.log" ] && [ -s "$LOG_DIR/xray.log" ]; then
                tail -n 15 "$LOG_DIR/xray.log" | sed 's/^/  /'
            else
                echo -e "  ${DIM}Log file empty or missing.${NC}"
            fi
            echo -e "\n  ${DIM}(Log level: warning — empty log means no errors)${NC}\n"
            echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        0) echo -e "\n  ${GREEN}Exiting G2ray Panel...${NC}"; exit 0 ;;
        *) echo -e "  ${RED}✖ Invalid option.${NC}"; sleep 1 ;;
    esac
done
