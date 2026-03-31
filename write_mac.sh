#!/usr/bin/env bash
# write_mac.sh — WiFi MAC address 生產線寫入工具
# 平台：QCS6490 + QCA6750
# 用法：./write_mac.sh <MAC_ADDRESS> [TEST_AP_SSID] [TEST_AP_PASSWORD]

set -euo pipefail

# shellcheck disable=SC2034 # Constants used by functions in Tasks 2-5
readonly MAC_FILE_PATH="/mnt/vendor/persist/qca6750/wlan_mac.bin"
readonly WLAN_MODULE_PATH="/vendor/lib/modules/qca_cld3_qca6750.ko"
readonly WLAN_INTERFACE="wlan0"
readonly DRIVER_RELOAD_WAIT=1
readonly WLAN_UP_TIMEOUT=10
readonly WIFI_CONNECT_TIMEOUT=15

# --- Helper Functions ---

validate_mac() {
    local mac="$1"
    # Accept AA:BB:CC:DD:EE:FF or AABBCCDDEEFF (case insensitive)
    if [[ "$mac" =~ ^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$ ]]; then
        return 0
    elif [[ "$mac" =~ ^[0-9A-Fa-f]{12}$ ]]; then
        return 0
    fi
    return 1
}

normalize_mac() {
    local mac="$1"
    # Remove colons and convert to uppercase
    echo "${mac}" | tr -d ':' | tr '[:lower:]' '[:upper:]'
}

check_adb_connection() {
    local serial
    serial=$(adb get-serialno 2>/dev/null) || return 1
    if [[ "$serial" == "unknown" || -z "$serial" ]]; then
        return 1
    fi
    echo "$serial"
    return 0
}

backup_original_mac() {
    local serial="$1"
    local backup_dir="backups"
    mkdir -p "$backup_dir"
    local backup_file="${backup_dir}/${serial}_wlan_mac.bin.bak"
    adb shell "cat ${MAC_FILE_PATH}" > "$backup_file" 2>/dev/null || true
    echo "$backup_file"
}

write_mac_to_device() {
    local mac_normalized="$1"
    local content="Intf0MacAddress=${mac_normalized}"
    adb shell "echo '${content}' > ${MAC_FILE_PATH}" || return 1
    return 0
}

verify_mac_written() {
    local mac_normalized="$1"
    local expected="Intf0MacAddress=${mac_normalized}"
    local actual
    actual=$(adb shell "cat ${MAC_FILE_PATH}" | tr -d '\r') || return 1
    if [[ "$actual" == "$expected" ]]; then
        return 0
    fi
    echo "$actual"
    return 1
}

reload_wlan_driver() {
    # Try rmmod; if it fails, bring interface down first
    if ! adb shell "rmmod wlan" 2>/dev/null; then
        adb shell "ifconfig ${WLAN_INTERFACE} down" 2>/dev/null || true
        adb shell "rmmod wlan" || return 1
    fi

    sleep "$DRIVER_RELOAD_WAIT"

    adb shell "insmod ${WLAN_MODULE_PATH}" || return 1
    return 0
}

wait_for_wlan_interface() {
    local elapsed=0
    while [[ $elapsed -lt $WLAN_UP_TIMEOUT ]]; do
        if adb shell "ip link show ${WLAN_INTERFACE}" &>/dev/null; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    return 1
}

get_interface_mac() {
    local mac
    mac=$(adb shell "cat /sys/class/net/${WLAN_INTERFACE}/address" | tr -d '\r') || return 1
    echo "$mac"
}

verify_interface_mac() {
    local mac_normalized="$1"
    local interface_mac
    interface_mac=$(get_interface_mac) || return 1
    # Convert interface MAC (aa:bb:cc:dd:ee:ff) to normalized form for comparison
    local interface_normalized
    interface_normalized=$(normalize_mac "$interface_mac")
    if [[ "$interface_normalized" == "$mac_normalized" ]]; then
        echo "$interface_mac"
        return 0
    fi
    echo "$interface_mac"
    return 1
}

wifi_connect_test() {
    local ssid="$1"
    local password="$2"

    # Enable WiFi
    adb shell "cmd wifi set-wifi-enabled enabled" || return 1
    sleep 2

    # Connect to test AP
    adb shell "cmd wifi connect-network \"${ssid}\" wpa2 \"${password}\"" || return 1

    # Wait for connection
    local elapsed=0
    while [[ $elapsed -lt $WIFI_CONNECT_TIMEOUT ]]; do
        local status
        status=$(adb shell "cmd wifi status" 2>/dev/null | tr -d '\r')
        if echo "$status" | grep -q "CONNECTED"; then
            break
        fi
        sleep 1
        ((elapsed++))
    done

    if [[ $elapsed -ge $WIFI_CONNECT_TIMEOUT ]]; then
        wifi_cleanup "$ssid"
        return 1
    fi

    # Check IP
    local ip
    ip=$(adb shell "ip addr show ${WLAN_INTERFACE}" | grep "inet " | awk '{print $2}' | cut -d/ -f1 | tr -d '\r')

    if [[ -z "$ip" ]]; then
        wifi_cleanup "$ssid"
        echo "NONE"
        return 1
    fi

    echo "$ip"

    # Cleanup
    wifi_cleanup "$ssid"
    return 0
}

wifi_cleanup() {
    local ssid="$1"
    adb shell "cmd wifi forget-network \"${ssid}\"" 2>/dev/null || true
    adb shell "cmd wifi set-wifi-enabled disabled" 2>/dev/null || true
}

# --- Source-only guard ---
# When sourced with --source-only, only export functions (for testing)
if [[ "${1:-}" == "--source-only" ]]; then
    return 0 2>/dev/null || exit 0 # shellcheck disable=SC2317
fi
