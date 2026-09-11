#!/usr/bin/env bash

set -u

VERSION="2"
API_URL="https://api.nordvpn.com/v1/servers?limit=16384"
TOP_CANDIDATES=10
PING_COUNT=5
PING_TIMEOUT=2

TMP_SERVERS=""
SELECTED_HOST=""
SELECTED_SHORT=""
SELECTED_LOAD=""
SELECTED_PING=""

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
      Interactive mode: choose Standard or P2P, country and optionally city.
      The script disconnects any active NordVPN tunnel before benchmarking,
      finds the least-loaded candidates, tests their latency and generates a
      WireGuard configuration for the best server. After connecting, it lets
      you keep the NordVPN-assigned WireGuard address or change only its last
      octet, and asks for the output filename.

  $(basename "$0") <country|server|country_code|city|group|country city>
      Legacy/direct mode. Arguments are passed directly to:
          nordvpn connect <arguments>

Examples:
  $(basename "$0")
  $(basename "$0") it462
  $(basename "$0") Italy
  $(basename "$0") Italy Milan
  $(basename "$0") P2P

Options:
  -h, --help       Show this help.
  -v, --version    Show version.

Interactive selection:
  Standard
      Requires the "Standard VPN servers" group. Servers may also support P2P;
      only special categories such as Onion Over VPN, Double VPN and Dedicated IP
      are excluded.

  P2P
      Requires the "P2P" group.

Selection algorithm:
  1. Keep only online servers in the selected country/city and category.
  2. Sort by current NordVPN load.
  3. Keep the $TOP_CANDIDATES least-loaded servers.
  4. Ping each candidate $PING_COUNT times.
  5. Choose the candidate with the lowest average latency.
     Load is used as a tie-breaker.
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
    local base_ip prefix last_octet choice new_octet

    base_ip="${assigned%/*}"
    prefix="${assigned#*/}"
    last_octet="${base_ip##*.}"

    echo
    echo "NordVPN assigned WireGuard address: $assigned"
    echo "Do you want to use this address?"
    echo "  1) Yes"
    echo "  2) No, change only the last octet"

    while true; do
        read -r -p "Choice: " choice
        case "$choice" in
            1)
                FINAL_WG_ADDRESS="$assigned"
                return 0
                ;;
            2)
                while true; do
                    read -r -p "Enter new last octet (1-254) [current: $last_octet]: " new_octet
                    if [[ "$new_octet" =~ ^[0-9]+$ ]] &&
                       [ "$new_octet" -ge 1 ] &&
                       [ "$new_octet" -le 254 ]; then
                        FINAL_WG_ADDRESS="${base_ip%.*}.${new_octet}/${prefix}"
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
        ensure_disconnected_for_benchmark
        INTERACTIVE_SELECTED=""
        interactive_selection
        generate_config "$INTERACTIVE_SELECTED"
    else
        # Backward-compatible/direct mode: pass arguments to NordVPN CLI.
        generate_config "$@"
    fi
}

main "$@"
