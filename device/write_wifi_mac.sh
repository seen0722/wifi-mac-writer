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

wait_for_framework() {
    local retries=0
    while [ $retries -lt 30 ]; do
        if getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
            break
        fi
        sleep 1
        retries=$((retries + 1))
    done
    sleep "$FRAMEWORK_RESTART_WAIT"
}

update_framework_mac() {
    local mac_coloned="$1"

    if [ ! -f "${WIFI_CONFIG_STORE}" ]; then
        # XML doesn't exist — restart framework to clear factory MAC cache
        # and let it regenerate XML with correct MAC from driver
        stop
        start
        wait_for_framework

        # After restart, wait for XML to be generated
        local wait=0
        while [ $wait -lt 10 ]; do
            if [ -f "${WIFI_CONFIG_STORE}" ]; then
                break
            fi
            sleep 1
            wait=$((wait + 1))
        done

        # If XML exists now, update it; otherwise driver MAC will be used
        if [ ! -f "${WIFI_CONFIG_STORE}" ]; then
            return 0
        fi
    fi

    local old_mac
    old_mac=$(grep 'wifi_sta_factory_mac_address' "${WIFI_CONFIG_STORE}" | \
        sed 's/.*>\(.*\)<.*/\1/')

    if [ -z "$old_mac" ]; then
        return 0
    fi

    # MAC already correct, no restart needed
    local expected_lower
    expected_lower=$(echo "$mac_coloned" | tr '[:upper:]' '[:lower:]')
    local old_lower
    old_lower=$(echo "$old_mac" | tr '[:upper:]' '[:lower:]')
    if [ "$old_lower" = "$expected_lower" ]; then
        return 0
    fi

    sed -i "s/${old_mac}/${mac_coloned}/g" "${WIFI_CONFIG_STORE}" || return 1

    # Restart framework again to pick up the updated XML
    stop
    start
    wait_for_framework
    return 0
}

verify_framework_mac() {
    local mac_coloned="$1"
    local expected_lower
    expected_lower=$(echo "$mac_coloned" | tr '[:upper:]' '[:lower:]')

    # Ensure WiFi is enabled — factory_mac only appears in dumpsys after WiFi starts
    cmd wifi set-wifi-enabled enabled 2>/dev/null || true
    sleep 3

    # Retry a few times — dumpsys wifi may briefly fail after framework restart
    local attempt=0
    while [ $attempt -lt 5 ]; do
        local factory_mac
        factory_mac=$(dumpsys wifi 2>/dev/null | grep wifi_sta_factory_mac_address | \
            sed 's/.*=//' | tr '[:upper:]' '[:lower:]')
        if [ "$factory_mac" = "$expected_lower" ]; then
            # Disable WiFi after verification
            cmd wifi set-wifi-enabled disabled 2>/dev/null || true
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    cmd wifi set-wifi-enabled disabled 2>/dev/null || true
    echo "$factory_mac"
    return 1
}

wifi_connect_test() {
    local ssid="$1"
    local password="$2"

    cmd wifi set-wifi-enabled enabled || return 1
    sleep 2

    cmd wifi connect-network "${ssid}" wpa2 "${password}" || return 1

    local elapsed=0
    while [ $elapsed -lt $WIFI_CONNECT_TIMEOUT ]; do
        local wifi_status
        wifi_status=$(cmd wifi status 2>/dev/null)
        if echo "$wifi_status" | grep -q "CONNECTED"; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ $elapsed -ge $WIFI_CONNECT_TIMEOUT ]; then
        wifi_cleanup "$ssid"
        return 1
    fi

    local ip
    ip=$(ip addr show ${WLAN_INTERFACE} | grep "inet " | awk '{print $2}' | cut -d/ -f1)

    if [ -z "$ip" ]; then
        wifi_cleanup "$ssid"
        echo "NONE"
        return 1
    fi

    echo "$ip"
    wifi_cleanup "$ssid"
    return 0
}

wifi_cleanup() {
    local ssid="$1"
    cmd wifi forget-network "${ssid}" 2>/dev/null || true
    cmd wifi set-wifi-enabled disabled 2>/dev/null || true
}

# --- Source-only guard (for testing on host) ---
if [ "${1:-}" = "--source-only" ]; then
    return 0 2>/dev/null || exit 0
fi

# --- Main ---

main() {
    local mac_input="${1:-}"
    local test_ssid="${2:-}"
    local test_password="${3:-}"

    # Step 1: Validate MAC
    if [ -z "$mac_input" ]; then
        echo "Usage: $0 <MAC_ADDRESS> [TEST_AP_SSID] [TEST_AP_PASSWORD]" >&2
        exit 2
    fi

    if ! validate_mac "$mac_input"; then
        output_result "RESULT" "FAIL"
        output_result "ERROR" "Invalid MAC format: ${mac_input}"
        exit 2
    fi

    local mac_normalized
    mac_normalized=$(normalize_mac "$mac_input")

    # Step 2: Get device serial
    local serial
    serial=$(getprop ro.serialno)
    output_result "SERIAL" "$serial"
    output_result "MAC_WRITTEN" "$mac_normalized"

    # Step 3: Write MAC
    if ! write_mac_to_device "$mac_normalized"; then
        output_result "RESULT" "FAIL"
        output_result "ERROR" "Failed to write MAC file"
        exit 3
    fi

    # Step 4: Read-back verify
    local verify_output
    if ! verify_output=$(verify_mac_written "$mac_normalized"); then
        output_result "MAC_READBACK" "MISMATCH"
        output_result "RESULT" "FAIL"
        output_result "ERROR" "Read-back verification failed: ${verify_output}"
        exit 4
    fi
    output_result "MAC_READBACK" "$mac_normalized"

    # Step 5: Reload driver
    if ! reload_wlan_driver; then
        output_result "DRIVER_RELOAD" "FAIL"
        output_result "RESULT" "FAIL"
        output_result "ERROR" "Driver reload failed"
        exit 5
    fi

    if ! wait_for_wlan_interface; then
        output_result "DRIVER_RELOAD" "FAIL"
        output_result "RESULT" "FAIL"
        output_result "ERROR" "wlan0 interface did not appear within ${WLAN_UP_TIMEOUT}s"
        exit 5
    fi
    output_result "DRIVER_RELOAD" "PASS"

    # Step 6: Verify interface MAC
    local interface_mac
    interface_mac=$(verify_interface_mac "$mac_normalized") || {
        output_result "MAC_INTERFACE" "$interface_mac"
        output_result "RESULT" "FAIL"
        output_result "ERROR" "Interface MAC mismatch: expected ${mac_normalized}, got ${interface_mac}"
        exit 6
    }
    output_result "MAC_INTERFACE" "$interface_mac"

    # Step 7: Update framework factory MAC
    local mac_coloned
    mac_coloned=$(format_mac_coloned "$mac_normalized")
    if ! update_framework_mac "$mac_coloned"; then
        output_result "FRAMEWORK_MAC" "FAIL"
        output_result "RESULT" "FAIL"
        output_result "ERROR" "Failed to update WifiConfigStore.xml"
        exit 8
    fi

    if ! verify_framework_mac "$mac_coloned"; then
        output_result "FRAMEWORK_MAC" "FAIL"
        output_result "RESULT" "FAIL"
        output_result "ERROR" "Framework factory MAC verification failed"
        exit 8
    fi
    output_result "FRAMEWORK_MAC" "PASS"

    # Step 8: WiFi connection test (optional)
    if [ -n "$test_ssid" ] && [ -n "$test_password" ]; then
        local ip
        ip=$(wifi_connect_test "$test_ssid" "$test_password") || {
            output_result "WIFI_CONNECT" "FAIL"
            output_result "IP_OBTAINED" "NONE"
            output_result "RESULT" "FAIL"
            output_result "ERROR" "WiFi connection test failed"
            exit 7
        }
        output_result "WIFI_CONNECT" "PASS"
        output_result "IP_OBTAINED" "$ip"
    else
        output_result "WIFI_CONNECT" "SKIP"
        output_result "IP_OBTAINED" "SKIP"
    fi

    # All passed
    output_result "RESULT" "PASS"
    exit 0
}

main "$@"
