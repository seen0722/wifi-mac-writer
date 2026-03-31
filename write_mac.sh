#!/usr/bin/env bash
# write_mac.sh — WiFi MAC address 生產線寫入工具
# 平台：QCS6490 + QCA6750
# 用法：./write_mac.sh <MAC_ADDRESS> [TEST_AP_SSID] [TEST_AP_PASSWORD]

set -euo pipefail

readonly MAC_FILE_PATH="/mnt/vendor/persist/qca6750/wlan_mac.bin"
readonly WLAN_MODULE_PATH="/vendor/lib/modules/wlan.ko"
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

# --- Source-only guard ---
# When sourced with --source-only, only export functions (for testing)
if [[ "${1:-}" == "--source-only" ]]; then
    return 0 2>/dev/null || exit 0
fi
