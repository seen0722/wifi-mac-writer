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

write_mac_to_device() {
    local mac_normalized="$1"
    local content="Intf0MacAddress=${mac_normalized}"
    echo "${content}" > "${MAC_FILE_PATH}" || return 1
    return 0
}

verify_mac_written() {
    local mac_normalized="$1"
    local expected="Intf0MacAddress=${mac_normalized}"
    local actual
    actual=$(cat "${MAC_FILE_PATH}") || return 1
    if [ "$actual" = "$expected" ]; then
        return 0
    fi
    echo "$actual"
    return 1
}

reload_wlan_driver() {
    if ! rmmod wlan 2>/dev/null; then
        ifconfig ${WLAN_INTERFACE} down 2>/dev/null || true
        rmmod wlan || return 1
    fi

    sleep "$DRIVER_RELOAD_WAIT"

    insmod "${WLAN_MODULE_PATH}" || return 1
    return 0
}

wait_for_wlan_interface() {
    local elapsed=0
    while [ $elapsed -lt $WLAN_UP_TIMEOUT ]; do
        if ip link show ${WLAN_INTERFACE} >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

get_interface_mac() {
    local mac
    mac=$(cat /sys/class/net/${WLAN_INTERFACE}/address) || return 1
    echo "$mac"
}

verify_interface_mac() {
    local mac_normalized="$1"
    local interface_mac
    interface_mac=$(get_interface_mac) || return 1
    local interface_normalized
    interface_normalized=$(normalize_mac "$interface_mac")
    if [ "$interface_normalized" = "$mac_normalized" ]; then
        echo "$interface_mac"
        return 0
    fi
    echo "$interface_mac"
    return 1
}

# --- Source-only guard (for testing on host) ---
if [ "${1:-}" = "--source-only" ]; then
    return 0 2>/dev/null || exit 0
fi
