#!/system/bin/sh
# write_wifi_mac.sh — WiFi MAC address 生產線寫入工具（device-side）
# 平台：QCS6490 + QCA6750
# 用法：write_wifi_mac.sh <MAC_ADDRESS> [TEST_AP_SSID] [TEST_AP_PASSWORD]
# 部署：/vendor/bin/write_wifi_mac.sh

MAC_FILE_PATH="/mnt/vendor/persist/qca6750/wlan_mac.bin"
WLAN_MODULE_PATH="/vendor/lib/modules/qca_cld3_qca6750.ko"
WLAN_INTERFACE="wlan0"
DRIVER_RELOAD_WAIT=1
WLAN_UP_TIMEOUT=10
WIFI_CONNECT_TIMEOUT=15
WIFI_CONFIG_STORE="/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml"
FRAMEWORK_RESTART_WAIT=10

# --- Helper Functions ---

validate_mac() {
    local mac="$1"
    case "$mac" in
        [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f])
            return 0 ;;
        [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
            return 0 ;;
    esac
    return 1
}

normalize_mac() {
    local mac="$1"
    echo "${mac}" | tr -d ':' | tr '[:lower:]' '[:upper:]'
}

format_mac_coloned() {
    local mac="$1"
    echo "$mac" | sed 's/\(..\)/\1:/g; s/:$//' | tr '[:upper:]' '[:lower:]'
}

output_result() {
    local key="$1"
    local value="$2"
    echo "${key}=${value}"
}

# --- Source-only guard (for testing on host) ---
if [ "${1:-}" = "--source-only" ]; then
    return 0 2>/dev/null || exit 0
fi
