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
readonly WIFI_CONFIG_STORE="/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml"
readonly FRAMEWORK_RESTART_WAIT=10

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

wait_for_adb_framework() {
    adb wait-for-device 2>/dev/null || true
    sleep "$FRAMEWORK_RESTART_WAIT"
    local retries=0
    while [[ $retries -lt 5 ]]; do
        if adb shell "getprop sys.boot_completed" 2>/dev/null | grep -q "1"; then
            break
        fi
        sleep 2
        ((retries++))
    done
}

update_framework_mac() {
    local mac_coloned="$1"

    # First boot: XML doesn't exist. No action needed — framework will
    # read factory MAC from driver (which has correct MAC from wlan_mac.bin).
    local file_exists
    file_exists=$(adb shell "[ -f ${WIFI_CONFIG_STORE} ] && echo yes || echo no" | tr -d '\r')
    if [[ "$file_exists" != "yes" ]]; then
        echo "SKIP_FIRST_BOOT"
        return 0
    fi

    local old_mac
    old_mac=$(adb shell "grep 'wifi_sta_factory_mac_address' ${WIFI_CONFIG_STORE}" | \
        sed 's/.*>\(.*\)<.*/\1/' | tr -d '\r')

    if [[ -z "$old_mac" ]]; then
        echo "SKIP_NO_TAG"
        return 0
    fi

    # MAC already correct, no restart needed
    local expected_lower old_lower
    expected_lower=$(echo "$mac_coloned" | tr '[:upper:]' '[:lower:]')
    old_lower=$(echo "$old_mac" | tr '[:upper:]' '[:lower:]')
    if [[ "$old_lower" == "$expected_lower" ]]; then
        return 0
    fi

    adb shell "sed -i 's/${old_mac}/${mac_coloned}/g' ${WIFI_CONFIG_STORE}" || return 1

    # Restart Android framework to reload the config
    adb shell "stop; start" || return 1
    wait_for_adb_framework
    return 0
}

verify_framework_mac() {
    local mac_coloned="$1"
    local factory_mac
    factory_mac=$(adb shell "dumpsys wifi | grep wifi_sta_factory_mac_address" | \
        sed 's/.*=//' | tr -d '\r' | tr '[:upper:]' '[:lower:]') || return 1
    local expected_lower
    expected_lower=$(echo "$mac_coloned" | tr '[:upper:]' '[:lower:]')
    if [[ "$factory_mac" == "$expected_lower" ]]; then
        return 0
    fi
    echo "$factory_mac"
    return 1
}

# --- Source-only guard ---
# When sourced with --source-only, only export functions (for testing)
# shellcheck disable=SC2317
if [[ "${1:-}" == "--source-only" ]]; then
    return 0 2>/dev/null || exit 0
fi

# --- Output helpers ---

output_result() {
    local key="$1"
    local value="$2"
    echo "${key}=${value}"
}

# --- Main ---

main() {
    local mac_input="${1:-}"
    local test_ssid="${2:-}"
    local test_password="${3:-}"

    # Step 1: Validate MAC
    if [[ -z "$mac_input" ]]; then
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

    # Step 2: Check ADB
    local serial
    serial=$(check_adb_connection) || {
        output_result "RESULT" "FAIL"
        output_result "ERROR" "ADB connection failed"
        exit 1
    }
    output_result "SERIAL" "$serial"
    output_result "MAC_WRITTEN" "$mac_normalized"

    # Step 3: Backup original MAC
    backup_original_mac "$serial" >/dev/null

    # Step 4: Write MAC
    if ! write_mac_to_device "$mac_normalized"; then
        output_result "RESULT" "FAIL"
        output_result "ERROR" "Failed to write MAC file"
        exit 3
    fi

    # Step 5: Read-back verify
    local verify_output
    if ! verify_output=$(verify_mac_written "$mac_normalized"); then
        output_result "MAC_READBACK" "MISMATCH"
        output_result "RESULT" "FAIL"
        output_result "ERROR" "Read-back verification failed: ${verify_output}"
        exit 4
    fi
    output_result "MAC_READBACK" "$mac_normalized"

    # Step 6: Reload driver
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

    # Step 7: Verify interface MAC
    local interface_mac
    interface_mac=$(verify_interface_mac "$mac_normalized") || {
        output_result "MAC_INTERFACE" "$interface_mac"
        output_result "RESULT" "FAIL"
        output_result "ERROR" "Interface MAC mismatch: expected ${mac_normalized}, got ${interface_mac}"
        exit 6
    }
    output_result "MAC_INTERFACE" "$interface_mac"

    # Step 8: Update framework factory MAC in WifiConfigStore.xml
    local mac_coloned
    mac_coloned=$(echo "$mac_normalized" | sed 's/\(..\)/\1:/g; s/:$//' | tr '[:upper:]' '[:lower:]')
    local fw_result
    if ! fw_result=$(update_framework_mac "$mac_coloned"); then
        output_result "FRAMEWORK_MAC" "FAIL"
        output_result "RESULT" "FAIL"
        output_result "ERROR" "Failed to update WifiConfigStore.xml"
        exit 8
    fi

    case "$fw_result" in
        SKIP_FIRST_BOOT)
            output_result "FRAMEWORK_MAC" "SKIP_FIRST_BOOT"
            ;;
        SKIP_NO_TAG)
            output_result "FRAMEWORK_MAC" "SKIP_NO_TAG"
            ;;
        *)
            if ! verify_framework_mac "$mac_coloned"; then
                output_result "FRAMEWORK_MAC" "FAIL"
                output_result "RESULT" "FAIL"
                output_result "ERROR" "Framework factory MAC verification failed"
                exit 8
            fi
            output_result "FRAMEWORK_MAC" "PASS"
            ;;
    esac

    # Step 9: WiFi connection test (optional)
    if [[ -n "$test_ssid" && -n "$test_password" ]]; then
        local ip
        ip=$(wifi_connect_test "$test_ssid" "$test_password") || {
            output_result "WIFI_CONNECT" "FAIL"
            output_result "IP_OBTAINED" "NONE"
            output_result "RESULT" "FAIL"
            output_result "ERROR" "WiFi connection test failed"
            exit 9
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
