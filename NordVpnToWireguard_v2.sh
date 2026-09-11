#!/usr/bin/env bash

set -u

VERSION="2"
API_URL="https://api.nordvpn.com/v1/servers?limit=16384"
TOP_CANDIDATES=10
PING_COUNT=5
PING_TIMEOUT=2

# Optional UniFi UDM SE integration.
# Override these with environment variables if your setup changes.
UDM_HOST="${UDM_HOST:-}"
UDM_USER="${UDM_USER:-root}"
UDM_SSH_KEY="${UDM_SSH_KEY:-$HOME/.ssh/id_ed25519_udm_nordvpn}"
UDM_CREDS_FILE="${UDM_CREDS_FILE:-/root/.unifi_nordvpn_api}"

TMP_SERVERS=""
SELECTED_HOST=""
SELECTED_SHORT=""
SELECTED_LOAD=""
SELECTED_PING=""

# Interactive workflow state
OPERATION_MODE="generate"
UDM_UPDATE_MODE="false"
UDM_SELECTED_ID=""
UDM_SELECTED_NAME=""
UDM_SELECTED_IP=""
UDM_SELECTED_WGID=""
UDM_SELECTED_ENABLED=""

cleanup() {
    if [ -n "${TMP_SERVERS:-}" ] && [ -f "$TMP_SERVERS" ]; then
        rm -f "$TMP_SERVERS"
    fi
}
trap cleanup EXIT

die() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command '$1' was not found."
}

show_help() {
    cat <<EOF
NordVPN WireGuard Config Generator v$VERSION

Usage:
  $(basename "$0")
      Start interactive mode.

  $(basename "$0") <NordVPN arguments>
      Direct mode. Arguments are passed to "nordvpn connect".

Examples:
  $(basename "$0") it459
  $(basename "$0") Italy
  $(basename "$0") Italy Milan

Interactive mode:

  1) Generate WireGuard configuration only
     - Select Standard or P2P
     - Select country
     - Optionally select city
     - Benchmark the least-loaded candidate servers
     - Generate a WireGuard .conf file

  2) Generate configuration and update an existing UDM WireGuard profile
     - Enter the UDM IP address or hostname, unless UDM_HOST is already set
     - Discover existing WireGuard VPN Client profiles on the UDM
     - Select the profile to update
     - Preserve the current profile IP by default
     - Select Standard or P2P
     - Select country and optionally city
     - Benchmark candidate servers
     - Generate the new WireGuard configuration
     - Back up the existing UniFi profile
     - Update the same UniFi profile object
     - Disable the profile and wait until the runtime wgcltX interface disappears
     - Re-enable the profile
     - Verify the runtime endpoint and WireGuard handshake

Server selection:
  - Only online NordVPN servers are considered
  - Candidates are sorted by current NordVPN load
  - The $TOP_CANDIDATES least-loaded candidates are tested with ping
  - The server with the lowest average latency is selected
  - Load is used as a tie-breaker
  - Benchmarking is always performed outside an active NordVPN tunnel

WireGuard address:
  - Generated client addresses always use /32
  - Generate-only mode proposes the NordVPN-assigned address
  - UDM mode proposes the current address of the selected UDM profile
  - The last IP octet can be changed manually

UDM integration:
  - UDM host can be entered interactively or provided with UDM_HOST
  - SSH user defaults to: root
  - SSH key defaults to: \$HOME/.ssh/id_ed25519_udm_nordvpn
  - UniFi API credentials are read on the UDM from:
      /root/.unifi_nordvpn_api
  - No UDM password is stored in this script

Requirements:
  nordvpn, curl, jq, ping, wg, ip or ifconfig

Additional requirements for UDM integration:
  ssh, scp

Options:
  -h, --help       Show this help
  -v, --version    Show version
EOF
}

check_dependencies() {
    require_cmd nordvpn
    require_cmd curl
    require_cmd jq
    require_cmd ping
    require_cmd wg

    if command -v ip >/dev/null 2>&1; then
        :
    elif command -v ifconfig >/dev/null 2>&1; then
        :
    else
        die "Neither 'ip' nor 'ifconfig' is installed."
    fi
}

check_login() {
    if ! nordvpn account >/dev/null 2>&1; then
        die "NordVPN CLI is not logged in or its daemon is unavailable."
    fi
}

ensure_disconnected_for_benchmark() {
    local status
    status="$(nordvpn status 2>/dev/null || true)"

    if printf '%s\n' "$status" | grep -qi '^Status: Connected'; then
        echo
        echo "NordVPN connection detected."
        echo "Disconnecting before server benchmark..."
        if ! nordvpn disconnect >/dev/null 2>&1; then
            die "Unable to disconnect NordVPN before latency tests."
        fi
        sleep 1
    fi
}

fetch_servers() {
    TMP_SERVERS="$(mktemp)"
    echo "Downloading NordVPN server list..."
    if ! curl -fsSL "$API_URL" -o "$TMP_SERVERS"; then
        die "Unable to download NordVPN server data."
    fi

    if ! jq -e 'type == "array"' "$TMP_SERVERS" >/dev/null 2>&1; then
        die "NordVPN API returned an unexpected response."
    fi
}

choose_from_array() {
    local prompt="$1"
    shift
    local items=("$@")
    local choice

    [ "${#items[@]}" -gt 0 ] || return 1

    while true; do
        echo
        echo "$prompt"
        local i
        for ((i = 0; i < ${#items[@]}; i++)); do
            printf "  %2d) %s\n" "$((i + 1))" "${items[$i]}"
        done

        read -r -p "Choice: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           [ "$choice" -ge 1 ] &&
           [ "$choice" -le "${#items[@]}" ]; then
            CHOSEN_ITEM="${items[$((choice - 1))]}"
            return 0
        fi

        echo "Invalid choice."
    done
}

choose_operation_mode() {
    local choice

    while true; do
        echo
        echo "Operation:"
        echo "  1) Generate WireGuard configuration only"
        echo "  2) Generate configuration and update an existing UDM WireGuard profile"
        read -r -p "Choice: " choice

        case "$choice" in
            1)
                OPERATION_MODE="generate"
                UDM_UPDATE_MODE="false"
                return 0
                ;;
            2)
                OPERATION_MODE="udm"
                UDM_UPDATE_MODE="true"
                return 0
                ;;
            *)
                echo "Invalid choice."
                ;;
        esac
    done
}

choose_server_type() {
    local choice

    while true; do
        echo
        echo "Server type:"
        echo "  1) Standard (non-P2P)"
        echo "  2) P2P"
        read -r -p "Choice: " choice

        case "$choice" in
            1)
                SERVER_MODE="standard"
                return 0
                ;;
            2)
                SERVER_MODE="p2p"
                return 0
                ;;
            *)
                echo "Invalid choice."
                ;;
        esac
    done
}

list_countries() {
    jq -r '
        .[]
        | select(.status == "online")
        | .locations[]?.country.name
    ' "$TMP_SERVERS" | sort -fu
}

list_cities() {
    local country="$1"
    local mode="$2"

    if [ "$mode" = "p2p" ]; then
        jq -r --arg country "$country" '
            .[]
            | select(.status == "online")
            | select(any(.groups[]?; .title == "P2P"))
            | select((any(.groups[]?; .title == "Onion Over VPN")) | not)
            | select((any(.groups[]?; .title == "Double VPN")) | not)
            | select((any(.groups[]?; .title == "Dedicated IP")) | not)
            | select(any(.locations[]?; .country.name == $country))
            | .locations[]?
            | select(.country.name == $country)
            | .country.city.name // empty
        ' "$TMP_SERVERS" | sort -fu
    else
        jq -r --arg country "$country" '
            .[]
            | select(.status == "online")
            | select(any(.groups[]?; .title == "Standard VPN servers"))
            | select((any(.groups[]?; .title == "Onion Over VPN")) | not)
            | select((any(.groups[]?; .title == "Double VPN")) | not)
            | select((any(.groups[]?; .title == "Dedicated IP")) | not)
            | select(any(.locations[]?; .country.name == $country))
            | .locations[]?
            | select(.country.name == $country)
            | .country.city.name // empty
        ' "$TMP_SERVERS" | sort -fu
    fi
}

build_candidates() {
    local country="$1"
    local city="$2"
    local mode="$3"

    if [ "$mode" = "p2p" ]; then
        jq -r --arg country "$country" --arg city "$city" '
            .[]
            | select(.status == "online")
            | select(any(.groups[]?; .title == "P2P"))
            | select((any(.groups[]?; .title == "Onion Over VPN")) | not)
            | select((any(.groups[]?; .title == "Double VPN")) | not)
            | select((any(.groups[]?; .title == "Dedicated IP")) | not)
            | select(any(.locations[]?;
                .country.name == $country
                and ($city == "" or (.country.city.name // "") == $city)
              ))
            | [.hostname, (.load // 100)]
            | @tsv
        ' "$TMP_SERVERS"
    else
        jq -r --arg country "$country" --arg city "$city" '
            .[]
            | select(.status == "online")
            | select(any(.groups[]?; .title == "Standard VPN servers"))
            | select((any(.groups[]?; .title == "Onion Over VPN")) | not)
            | select((any(.groups[]?; .title == "Double VPN")) | not)
            | select((any(.groups[]?; .title == "Dedicated IP")) | not)
            | select(any(.locations[]?;
                .country.name == $country
                and ($city == "" or (.country.city.name // "") == $city)
              ))
            | [.hostname, (.load // 100)]
            | @tsv
        ' "$TMP_SERVERS"
    fi
}

average_ping() {
    local host="$1"
    local result

    result="$(
        ping -n -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" 2>/dev/null |
        awk -F'=' '/^(rtt|round-trip)/ {
            gsub(/ /, "", $2)
            split($2, a, "/")
            print a[2]
        }'
    )"

    if [ -n "$result" ]; then
        printf '%s\n' "$result"
    else
        printf '%s\n' "999999"
    fi
}

select_best_server() {
    local country="$1"
    local city="$2"
    local mode="$3"

    local candidates
    candidates="$(
        build_candidates "$country" "$city" "$mode" |
        sort -t $'\t' -k2,2n |
        head -n "$TOP_CANDIDATES"
    )"

    [ -n "$candidates" ] || die "No matching online servers were found."

    echo
    if [ "$mode" = "p2p" ]; then
        printf "Testing P2P servers in %s" "$country"
    else
        printf "Testing Standard non-P2P servers in %s" "$country"
    fi
    [ -n "$city" ] && printf " / %s" "$city"
    echo "..."
    echo
    printf "%-28s %8s %12s\n" "Server" "Load" "Avg ping"
    printf "%-28s %8s %12s\n" "----------------------------" "--------" "------------"

    local best_ping="999999"
    local best_load="999"
    local host load ping_ms

    while IFS=$'\t' read -r host load; do
        [ -n "$host" ] || continue

        ping_ms="$(average_ping "$host")"

        if [ "$ping_ms" = "999999" ]; then
            printf "%-28s %7s%% %12s\n" "$host" "$load" "timeout"
            continue
        fi

        printf "%-28s %7s%% %9s ms\n" "$host" "$load" "$ping_ms"

        if awk -v p="$ping_ms" -v bp="$best_ping" -v l="$load" -v bl="$best_load" \
            'BEGIN { exit !((p < bp) || (p == bp && l < bl)) }'; then
            best_ping="$ping_ms"
            best_load="$load"
            SELECTED_HOST="$host"
        fi
    done <<< "$candidates"

    [ -n "$SELECTED_HOST" ] || die "None of the candidate servers responded to ping."

    SELECTED_SHORT="${SELECTED_HOST%%.*}"
    SELECTED_LOAD="$best_load"
    SELECTED_PING="$best_ping"

    echo
    echo "Selected server: $SELECTED_HOST"
    echo "Load: ${SELECTED_LOAD}%"
    echo "Average ping: ${SELECTED_PING} ms"
}

interactive_selection() {
    fetch_servers

    SERVER_MODE=""
    choose_server_type
    local mode="$SERVER_MODE"

    mapfile -t countries < <(list_countries)
    [ "${#countries[@]}" -gt 0 ] || die "No countries were returned by the NordVPN API."

    local country
    CHOSEN_ITEM=""
    choose_from_array "Select country:" "${countries[@]}"
    country="$CHOSEN_ITEM"

    mapfile -t cities < <(list_cities "$country" "$mode")

    local city=""
    if [ "${#cities[@]}" -gt 0 ]; then
        echo
        read -r -p "Restrict the search to a city? [y/N]: " answer
        case "${answer,,}" in
            y|yes)
                CHOSEN_ITEM=""
                choose_from_array "Select city:" "${cities[@]}"
                city="$CHOSEN_ITEM"
                ;;
        esac
    fi

    select_best_server "$country" "$city" "$mode"
    INTERACTIVE_SELECTED="$SELECTED_SHORT"
}

get_tunnel_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show dev nordlynx 2>/dev/null |
            awk '/inet / {print $2; exit}'
    else
        ifconfig nordlynx 2>/dev/null |
            awk '/inet / {
                for (i = 1; i <= NF; i++) {
                    if ($i == "inet") {
                        print $(i + 1) "/32"
                        exit
                    }
                }
            }'
    fi
}


prompt_output_filename() {
    local default_name="$1"
    local entered

    echo
    read -r -p "Output filename [${default_name}.conf]: " entered

    if [ -z "$entered" ]; then
        OUTPUT_FILENAME="${default_name}.conf"
    else
        entered="${entered##*/}"
        case "$entered" in
            *.conf) OUTPUT_FILENAME="$entered" ;;
            *)      OUTPUT_FILENAME="${entered}.conf" ;;
        esac
    fi
}

choose_wireguard_address() {
    local assigned="$1"
    local assigned_base profile_base current_base last_octet choice new_octet

    assigned_base="${assigned%/*}"

    if [ "$UDM_UPDATE_MODE" = "true" ] && [ -n "$UDM_SELECTED_IP" ]; then
        profile_base="${UDM_SELECTED_IP%/*}"
        current_base="$profile_base"
        last_octet="${profile_base##*.}"

        echo
        echo "NordVPN assigned WireGuard address: $assigned"
        echo
        echo "Selected UDM profile: $UDM_SELECTED_NAME"
        echo "Current UDM profile address: $UDM_SELECTED_IP"
        echo
        echo "Which address should be written to the new configuration?"
        echo "  1) Keep current UDM profile address: ${profile_base}/32"
        echo "  2) Change only the last octet"

        while true; do
            read -r -p "Choice: " choice
            case "$choice" in
                1)
                    FINAL_WG_ADDRESS="${profile_base}/32"
                    echo "WireGuard address set to: $FINAL_WG_ADDRESS"
                    return 0
                    ;;
                2)
                    while true; do
                        read -r -p "Enter new last octet (1-254) [current: $last_octet]: " new_octet
                        if [[ "$new_octet" =~ ^[0-9]+$ ]] &&
                           [ "$new_octet" -ge 1 ] &&
                           [ "$new_octet" -le 254 ]; then
                            FINAL_WG_ADDRESS="${profile_base%.*}.${new_octet}/32"
                            echo "WireGuard address set to: $FINAL_WG_ADDRESS"
                            return 0
                        fi
                        echo "Invalid value. Enter a number from 1 to 254."
                    done
                    ;;
                *)
                    echo "Invalid choice."
                    ;;
            esac
        done
    fi

    current_base="$assigned_base"
    last_octet="${assigned_base##*.}"

    echo
    echo "NordVPN assigned WireGuard address: $assigned"
    echo "The generated configuration will use a /32 prefix."
    echo
    echo "Which address should be written to the new configuration?"
    echo "  1) Use NordVPN address: ${assigned_base}/32"
    echo "  2) Change only the last octet"

    while true; do
        read -r -p "Choice: " choice
        case "$choice" in
            1)
                FINAL_WG_ADDRESS="${assigned_base}/32"
                echo "WireGuard address set to: $FINAL_WG_ADDRESS"
                return 0
                ;;
            2)
                while true; do
                    read -r -p "Enter new last octet (1-254) [current: $last_octet]: " new_octet
                    if [[ "$new_octet" =~ ^[0-9]+$ ]] &&
                       [ "$new_octet" -ge 1 ] &&
                       [ "$new_octet" -le 254 ]; then
                        FINAL_WG_ADDRESS="${assigned_base%.*}.${new_octet}/32"
                        echo "WireGuard address set to: $FINAL_WG_ADDRESS"
                        return 0
                    fi
                    echo "Invalid value. Enter a number from 1 to 254."
                done
                ;;
            *)
                echo "Invalid choice."
                ;;
        esac
    done
}


prompt_udm_host() {
    if [ -n "$UDM_HOST" ]; then
        echo
        echo "Using UDM host from environment: $UDM_HOST"
        return 0
    fi

    echo
    while true; do
        read -r -p "Enter UDM IP address or hostname: " UDM_HOST
        if [ -n "$UDM_HOST" ]; then
            return 0
        fi
        echo "UDM IP address or hostname cannot be empty."
    done
}

udm_check_access() {
    command -v ssh >/dev/null 2>&1 || {
        echo "SSH client not found; UDM update is unavailable." >&2
        return 1
    }
    command -v scp >/dev/null 2>&1 || {
        echo "SCP client not found; UDM update is unavailable." >&2
        return 1
    }

    [ -f "$UDM_SSH_KEY" ] || {
        echo "UDM SSH key not found: $UDM_SSH_KEY" >&2
        return 1
    }

    echo "Checking SSH connection to UDM at $UDM_HOST..."

    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$UDM_SSH_KEY" "$UDM_USER@$UDM_HOST" \
        "test -r '$UDM_CREDS_FILE' && command -v curl >/dev/null && command -v jq >/dev/null && command -v wg >/dev/null"; then
        echo "Unable to access the UDM or required UDM tools/credentials are missing." >&2
        return 1
    fi
}

udm_list_wireguard_profiles() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$UDM_SSH_KEY" "$UDM_USER@$UDM_HOST" \
        bash -s -- "$UDM_CREDS_FILE" <<'REMOTE'
set -eu
CREDS_FILE="$1"
COOKIE="$(mktemp)"
HEADERS="$(mktemp)"
trap 'rm -f "$COOKIE" "$HEADERS"' EXIT

U="$(sed -n '1p' "$CREDS_FILE")"
P="$(sed -n '2p' "$CREDS_FILE")"
PAYLOAD="$(jq -nc --arg username "$U" --arg password "$P" \
    '{username:$username,password:$password}')"

CODE="$(curl -sk -D "$HEADERS" -c "$COOKIE" \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" \
    -o /dev/null -w '%{http_code}' \
    https://127.0.0.1/api/auth/login)"

[ "$CODE" = "200" ] || {
    echo "UniFi API login failed with HTTP $CODE" >&2
    exit 1
}

curl -sk -b "$COOKIE" \
    https://127.0.0.1/proxy/network/api/s/default/rest/networkconf |
jq -r '
    .data[]
    | select(.purpose == "vpn-client" and .vpn_type == "wireguard-client")
    | [
        ._id,
        .name,
        (.ip_subnet // ""),
        (.wireguard_id // ""),
        (.enabled // false)
      ]
    | @tsv
'
REMOTE
}

udm_apply_wireguard_profile() {
    local profile_id="$1"
    local profile_name="$2"
    local remote_conf="$3"
    local config_filename="$4"

    ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$UDM_SSH_KEY" "$UDM_USER@$UDM_HOST" \
        bash -s -- \
        "$UDM_CREDS_FILE" "$profile_id" "$profile_name" \
        "$remote_conf" "$config_filename" <<'REMOTE'
set -eu
umask 077

CREDS_FILE="$1"
PROFILE_ID="$2"
PROFILE_NAME="$3"
CONFIG_PATH="$4"
CONFIG_FILENAME="$5"

COOKIE="$(mktemp)"
HEADERS="$(mktemp)"
CURRENT="$(mktemp)"
UPDATED="$(mktemp)"
DISABLED="$(mktemp)"
PUT_BODY="$(mktemp)"

cleanup() {
    rm -f "$COOKIE" "$HEADERS" "$CURRENT" "$UPDATED" "$DISABLED" "$PUT_BODY"
    rm -f "$CONFIG_PATH"
}
trap cleanup EXIT

U="$(sed -n '1p' "$CREDS_FILE")"
P="$(sed -n '2p' "$CREDS_FILE")"
PAYLOAD="$(jq -nc --arg username "$U" --arg password "$P" \
    '{username:$username,password:$password}')"

LOGIN_CODE="$(curl -sk -D "$HEADERS" -c "$COOKIE" \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" \
    -o /dev/null -w '%{http_code}' \
    https://127.0.0.1/api/auth/login)"

[ "$LOGIN_CODE" = "200" ] || {
    echo "Error: UniFi API login failed with HTTP $LOGIN_CODE." >&2
    exit 1
}

CSRF="$(awk -F': ' 'tolower($1)=="x-csrf-token" {gsub("\\r","",$2); print $2}' "$HEADERS")"
[ -n "$CSRF" ] || {
    echo "Error: UniFi API did not return a CSRF token." >&2
    exit 1
}

GET_CODE="$(curl -sk -b "$COOKIE" \
    -o "$PUT_BODY" -w '%{http_code}' \
    "https://127.0.0.1/proxy/network/api/s/default/rest/networkconf/$PROFILE_ID")"

[ "$GET_CODE" = "200" ] || {
    echo "Error: unable to read UniFi profile (HTTP $GET_CODE)." >&2
    exit 1
}

jq '.data[0]' "$PUT_BODY" > "$CURRENT"

[ "$(jq -r '.vpn_type' "$CURRENT")" = "wireguard-client" ] || {
    echo "Error: selected profile is not a WireGuard client." >&2
    exit 1
}

ACTUAL_NAME="$(jq -r '.name' "$CURRENT")"
[ "$ACTUAL_NAME" = "$PROFILE_NAME" ] || {
    echo "Error: profile name changed while updating." >&2
    exit 1
}

ADDRESS="$(awk -F' = ' '/^Address =/{print $2; exit}' "$CONFIG_PATH")"
ENDPOINT="$(awk -F' = ' '/^Endpoint =/{print $2; exit}' "$CONFIG_PATH")"

[ -n "$ADDRESS" ] && [ -n "$ENDPOINT" ] || {
    echo "Error: Address or Endpoint missing from WireGuard configuration." >&2
    exit 1
}

case "$ADDRESS" in
    */32) ;;
    *)
        echo "Error: UniFi WireGuard client address must use /32; got $ADDRESS." >&2
        exit 1
        ;;
esac

SAFE_NAME="$(printf '%s' "$ACTUAL_NAME" | tr -cs 'A-Za-z0-9._-' '_')"
BACKUP="/root/nordvpn-wireguard-${SAFE_NAME}-$(date +%Y%m%d-%H%M%S).json"
cp "$CURRENT" "$BACKUP"
chmod 600 "$BACKUP"

ORIGINAL_ENABLED="$(jq -r '.enabled // false' "$CURRENT")"
WG_ID="$(jq -r '.wireguard_id // empty' "$CURRENT")"

jq --rawfile conf "$CONFIG_PATH" \
   --arg filename "$CONFIG_FILENAME" \
   --arg ip "$ADDRESS" \
   '.wireguard_client_configuration_file=$conf
    | .wireguard_client_configuration_filename=$filename
    | .ip_subnet=$ip' \
   "$CURRENT" > "$UPDATED"

api_put() {
    local json_file="$1"
    local code

    code="$(curl -sk -X PUT \
        -b "$COOKIE" \
        -H "X-CSRF-Token: $CSRF" \
        -H 'Content-Type: application/json' \
        --data-binary @"$json_file" \
        -o "$PUT_BODY" -w '%{http_code}' \
        "https://127.0.0.1/proxy/network/api/s/default/rest/networkconf/$PROFILE_ID")"

    [ "$code" = "200" ] || {
        echo "Error: UniFi profile update failed with HTTP $code." >&2
        cat "$PUT_BODY" >&2
        exit 1
    }
}

api_put "$UPDATED"

IFACE=""
if [ -n "$WG_ID" ]; then
    IFACE="wgclt${WG_ID}"
fi

if [ "$ORIGINAL_ENABLED" = "true" ]; then
    jq '.enabled=false' "$UPDATED" > "$DISABLED"
    api_put "$DISABLED"

    if [ -n "$IFACE" ]; then
        echo "Waiting for runtime interface $IFACE to disappear..."
        i=0
        while wg show "$IFACE" >/dev/null 2>&1; do
            sleep 1
            i=$((i + 1))
            if [ "$i" -ge 30 ]; then
                echo "Error: $IFACE did not disappear within 30 seconds." >&2
                echo "Re-enabling the UniFi profile before aborting..." >&2
                api_put "$UPDATED"
                exit 1
            fi
        done
        echo "Runtime interface $IFACE has been removed."
    else
        echo "Warning: wireguard_id is unavailable; waiting 2 seconds before re-enabling." >&2
        sleep 2
    fi

    api_put "$UPDATED"
fi

STORED="$(curl -sk -b "$COOKIE" \
    "https://127.0.0.1/proxy/network/api/s/default/rest/networkconf/$PROFILE_ID")"

STORED_FILENAME="$(printf '%s' "$STORED" | jq -r '.data[0].wireguard_client_configuration_filename')"
STORED_IP="$(printf '%s' "$STORED" | jq -r '.data[0].ip_subnet')"
STORED_ENDPOINT="$(printf '%s' "$STORED" |
    jq -r '.data[0].wireguard_client_configuration_file
        | capture("Endpoint = (?<e>[^\\n]+)").e')"

echo
echo "UniFi profile updated successfully."
echo "Profile: $ACTUAL_NAME"
echo "Backup: $BACKUP"
echo "Configuration file: $STORED_FILENAME"
echo "Address: $STORED_IP"
echo "Stored endpoint: $STORED_ENDPOINT"

if [ "$ORIGINAL_ENABLED" != "true" ]; then
    echo "Profile was disabled before the update and has been left disabled."
    exit 0
fi

if [ -z "$WG_ID" ]; then
    echo "Warning: unable to determine the runtime WireGuard interface ID."
    exit 0
fi

IFACE="${IFACE:-wgclt${WG_ID}}"
HANDSHAKE="0"
RUNTIME_ENDPOINT=""

i=0
while [ "$i" -lt 15 ]; do
    if wg show "$IFACE" >/dev/null 2>&1; then
        RUNTIME_ENDPOINT="$(wg show "$IFACE" endpoints 2>/dev/null | awk 'NR==1 {print $2}')"
        HANDSHAKE="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')"
        [ -n "$HANDSHAKE" ] || HANDSHAKE="0"
        if [ "$HANDSHAKE" -gt 0 ] 2>/dev/null; then
            break
        fi
    fi
    sleep 1
    i=$((i + 1))
done

echo "Runtime interface: $IFACE"
[ -n "$RUNTIME_ENDPOINT" ] && echo "Runtime endpoint: $RUNTIME_ENDPOINT"

if [ "$HANDSHAKE" -gt 0 ] 2>/dev/null; then
    NOW="$(date +%s)"
    AGE=$((NOW - HANDSHAKE))
    echo "WireGuard handshake: active (${AGE}s ago)"
else
    echo "Warning: no WireGuard handshake detected yet."
fi
REMOTE
}

select_udm_profile_for_update() {
    prompt_udm_host

    if ! udm_check_access; then
        die "Unable to access the UDM SE. Cannot continue with UDM update mode."
    fi

    local profiles_output
    if ! profiles_output="$(udm_list_wireguard_profiles)"; then
        die "Unable to retrieve WireGuard VPN profiles from the UDM."
    fi

    mapfile -t profiles <<< "$profiles_output"
    [ "${#profiles[@]}" -gt 0 ] || die "No WireGuard VPN client profiles found on the UDM."

    local ids=()
    local names=()
    local ips=()
    local wgids=()
    local enableds=()
    local line id name ip wgid enabled

    for line in "${profiles[@]}"; do
        IFS=$'	' read -r id name ip wgid enabled <<< "$line"
        ids+=("$id")
        names+=("$name")
        ips+=("$ip")
        wgids+=("$wgid")
        enableds+=("$enabled")
    done

    echo
    echo "WireGuard VPN profiles found on UDM:"
    local i
    for ((i = 0; i < ${#names[@]}; i++)); do
        printf "  %2d) %s [%s]
" "$((i + 1))" "${names[$i]}" "${ips[$i]}"
    done
    printf "  %2d) Cancel
" "$(( ${#names[@]} + 1 ))"

    local choice
    while true; do
        read -r -p "Select profile to update: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           [ "$choice" -ge 1 ] &&
           [ "$choice" -le $(( ${#names[@]} + 1 )) ]; then
            break
        fi
        echo "Invalid choice."
    done

    if [ "$choice" -eq $(( ${#names[@]} + 1 )) ]; then
        echo "UDM update cancelled."
        exit 0
    fi

    local idx=$((choice - 1))
    UDM_SELECTED_ID="${ids[$idx]}"
    UDM_SELECTED_NAME="${names[$idx]}"
    UDM_SELECTED_IP="${ips[$idx]}"
    UDM_SELECTED_WGID="${wgids[$idx]}"
    UDM_SELECTED_ENABLED="${enableds[$idx]}"

    echo
    echo "Selected UDM profile: $UDM_SELECTED_NAME [$UDM_SELECTED_IP]"
}

update_selected_udm_profile() {
    [ "$UDM_UPDATE_MODE" = "true" ] || return 0
    [ -n "$UDM_SELECTED_ID" ] || die "No UDM profile has been selected."

    local generated_ip
    generated_ip="$(awk -F' = ' '/^Address =/{print $2; exit}' "$OUTPUT_FILENAME")"

    echo
    echo "UDM profile to update: $UDM_SELECTED_NAME"
    echo "Current profile address: $UDM_SELECTED_IP"
    echo "New configuration address: $generated_ip"

    local remote_conf="/tmp/nordvpn-wireguard-upload-$$.conf"

    echo
    echo "Uploading configuration to UDM..."

    if ! scp -q -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$UDM_SSH_KEY" \
        "$OUTPUT_FILENAME" \
        "$UDM_USER@$UDM_HOST:$remote_conf"; then
        die "Unable to upload configuration to UDM."
    fi

    echo "Updating UniFi profile '$UDM_SELECTED_NAME'..."
    if ! udm_apply_wireguard_profile \
        "$UDM_SELECTED_ID" "$UDM_SELECTED_NAME" \
        "$remote_conf" "$(basename "$OUTPUT_FILENAME")"; then
        die "UDM profile update failed."
    fi
}

generate_config() {
    local connect_args=("$@")

    echo
    echo "Connecting to NordVPN to gather WireGuard parameters..."

    if ! nordvpn connect "${connect_args[@]}"; then
        die "Unable to connect to NordVPN."
    fi

    # Give the interface/status a moment to settle.
    sleep 1

    local myip private pubkey endpoint default_name

    myip="$(get_tunnel_ip)"
    private="$(wg show nordlynx private-key 2>/dev/null || true)"
    pubkey="$(wg show nordlynx 2>/dev/null | awk '/^peer:/ {print $2; exit}')"
    endpoint="$(nordvpn status | awk -F': ' '/^Hostname:/ {print $2; exit}')"

    if [ -z "$myip" ] || [ -z "$private" ] || [ -z "$pubkey" ] || [ -z "$endpoint" ]; then
        nordvpn disconnect >/dev/null 2>&1 || true
        die "Unable to gather all NordLynx/WireGuard parameters."
    fi

    choose_wireguard_address "$myip"

    default_name="NordVPN-${endpoint%%.*}"
    prompt_output_filename "$default_name"

    if ! nordvpn disconnect >/dev/null 2>&1; then
        die "Unable to disconnect from NordVPN after gathering parameters."
    fi

    cat > "$OUTPUT_FILENAME" <<EOF
[Interface]
Address = ${FINAL_WG_ADDRESS}
PrivateKey = ${private}
ListenPort = 51820
DNS = 103.86.96.100, 103.86.99.100

[Peer]
PublicKey = ${pubkey}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${endpoint}:51820
PersistentKeepalive = 25
EOF

    chmod 600 "$OUTPUT_FILENAME"

    echo
    echo "WireGuard configuration file '$OUTPUT_FILENAME' created successfully."

    update_selected_udm_profile
}

main() {
    case "${1:-}" in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "Wireguard Config Files for NordVPN v$VERSION"
            exit 0
            ;;
    esac

    check_dependencies
    check_login

    if [ "$#" -eq 0 ]; then
        choose_operation_mode

        if [ "$UDM_UPDATE_MODE" = "true" ]; then
            # Select the destination profile first so its current IP can be
            # proposed later when building the new WireGuard configuration.
            select_udm_profile_for_update
        fi

        # Server benchmarking must always happen outside an active NordVPN tunnel.
        ensure_disconnected_for_benchmark

        INTERACTIVE_SELECTED=""
        interactive_selection
        generate_config "$INTERACTIVE_SELECTED"
    else
        # Backward-compatible/direct mode:
        # explicit NordVPN arguments generate a configuration only.
        OPERATION_MODE="generate"
        UDM_UPDATE_MODE="false"
        generate_config "$@"
    fi
}

main "$@"
