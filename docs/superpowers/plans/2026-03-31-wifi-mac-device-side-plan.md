# WiFi MAC Device-Side 寫入腳本實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立 device-side 版本的 `write_wifi_mac.sh`，在裝置上本地執行 WiFi MAC 寫入與驗證，Host 端只需一行 `adb shell` 觸發。

**Architecture:** 基於現有 host-side `write_mac.sh` 改寫，移除所有 `adb shell` wrapper 改為本地指令，移除 ADB 重連邏輯，改用本地 `getprop` 輪詢等待 framework 就緒。腳本放在 `/vendor/bin/write_wifi_mac.sh`，開發時在專案目錄下的 `device/write_wifi_mac.sh`。

**Tech Stack:** Bash, Android shell utilities (getprop, dumpsys, cmd, sed)

---

## File Structure

| File | Responsibility |
|------|---------------|
| `device/write_wifi_mac.sh` | Device-side 腳本：本地執行 MAC 寫入、驗證、連線測試 |
| `tests/test_write_wifi_mac.bats` | 單元測試：MAC 格式驗證、轉換等純邏輯函式 |

---

### Task 1: 建立 device-side 腳本骨架與純邏輯函式

**Files:**
- Create: `device/write_wifi_mac.sh`
- Create: `tests/test_write_wifi_mac.bats`

- [ ] **Step 1: 建立測試檔案**

```bash
#!/usr/bin/env bats
# tests/test_write_wifi_mac.bats

setup() {
    source ./device/write_wifi_mac.sh --source-only
}

@test "validate_mac accepts AA:BB:CC:DD:EE:FF format" {
    run validate_mac "AA:BB:CC:DD:EE:FF"
    [ "$status" -eq 0 ]
}

@test "validate_mac accepts AABBCCDDEEFF format" {
    run validate_mac "AABBCCDDEEFF"
    [ "$status" -eq 0 ]
}

@test "validate_mac accepts lowercase aa:bb:cc:dd:ee:ff" {
    run validate_mac "aa:bb:cc:dd:ee:ff"
    [ "$status" -eq 0 ]
}

@test "validate_mac rejects short MAC" {
    run validate_mac "AABBCCDDEE"
    [ "$status" -eq 1 ]
}

@test "validate_mac rejects invalid characters" {
    run validate_mac "GG:HH:II:JJ:KK:LL"
    [ "$status" -eq 1 ]
}

@test "validate_mac rejects empty string" {
    run validate_mac ""
    [ "$status" -eq 1 ]
}

@test "normalize_mac converts AA:BB:CC:DD:EE:FF to AABBCCDDEEFF" {
    run normalize_mac "AA:BB:CC:DD:EE:FF"
    [ "$output" = "AABBCCDDEEFF" ]
}

@test "normalize_mac converts lowercase to uppercase" {
    run normalize_mac "aa:bb:cc:dd:ee:ff"
    [ "$output" = "AABBCCDDEEFF" ]
}

@test "normalize_mac passes through already-normalized MAC" {
    run normalize_mac "AABBCCDDEEFF"
    [ "$output" = "AABBCCDDEEFF" ]
}

@test "format_mac_coloned converts AABBCCDDEEFF to aa:bb:cc:dd:ee:ff" {
    run format_mac_coloned "AABBCCDDEEFF"
    [ "$output" = "aa:bb:cc:dd:ee:ff" ]
}
```

- [ ] **Step 2: 執行測試，確認失敗**

Run: `bats tests/test_write_wifi_mac.bats`
Expected: FAIL — file not found

- [ ] **Step 3: 建立 device-side 腳本骨架**

```bash
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
```

**注意：** 使用 `#!/system/bin/sh` 而非 `#!/usr/bin/env bash`，因為 Android 裝置上的 shell 是 mksh，不支援 `[[ ]]` regex。`validate_mac` 改用 `case` glob pattern 做驗證。但 bats 測試在 host 上跑時會用 bash source，兩者相容。

- [ ] **Step 4: 設定執行權限並執行測試**

Run: `chmod +x device/write_wifi_mac.sh && bats tests/test_write_wifi_mac.bats`
Expected: All 10 tests PASS

- [ ] **Step 5: Commit**

```bash
git add device/write_wifi_mac.sh tests/test_write_wifi_mac.bats
git commit -m "feat: add device-side script skeleton with MAC validation"
```

---

### Task 2: 加入本地寫入與驗證函式

**Files:**
- Modify: `device/write_wifi_mac.sh`

- [ ] **Step 1: 在 source-only guard 之前加入寫入與驗證函式**

在 `output_result` 函式之後、source-only guard 之前插入：

```bash
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
```

- [ ] **Step 2: 驗證 bats 測試仍通過**

Run: `bats tests/test_write_wifi_mac.bats`
Expected: All 10 tests PASS

- [ ] **Step 3: Commit**

```bash
git add device/write_wifi_mac.sh
git commit -m "feat: add local write, verify, and driver reload functions"
```

---

### Task 3: 加入 framework MAC 更新與 WiFi 連線測試

**Files:**
- Modify: `device/write_wifi_mac.sh`

- [ ] **Step 1: 在 `verify_interface_mac` 之後、source-only guard 之前加入函式**

```bash
update_framework_mac() {
    local mac_coloned="$1"
    local old_mac
    old_mac=$(grep 'wifi_sta_factory_mac_address' "${WIFI_CONFIG_STORE}" | \
        sed 's/.*>\(.*\)<.*/\1/') || return 1

    if [ -z "$old_mac" ]; then
        return 1
    fi

    sed -i "s/${old_mac}/${mac_coloned}/g" "${WIFI_CONFIG_STORE}" || return 1

    # Restart Android framework
    stop
    start

    # Wait for framework to be ready (local polling, no ADB needed)
    local retries=0
    while [ $retries -lt 30 ]; do
        if getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
            break
        fi
        sleep 1
        retries=$((retries + 1))
    done
    sleep "$FRAMEWORK_RESTART_WAIT"
    return 0
}

verify_framework_mac() {
    local mac_coloned="$1"
    local factory_mac
    factory_mac=$(dumpsys wifi | grep wifi_sta_factory_mac_address | \
        sed 's/.*=//' | tr '[:upper:]' '[:lower:]') || return 1
    local expected_lower
    expected_lower=$(echo "$mac_coloned" | tr '[:upper:]' '[:lower:]')
    if [ "$factory_mac" = "$expected_lower" ]; then
        return 0
    fi
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
```

- [ ] **Step 2: 驗證 bats 測試仍通過**

Run: `bats tests/test_write_wifi_mac.bats`
Expected: All 10 tests PASS

- [ ] **Step 3: Commit**

```bash
git add device/write_wifi_mac.sh
git commit -m "feat: add framework MAC update and WiFi connection test"
```

---

### Task 4: 加入主流程

**Files:**
- Modify: `device/write_wifi_mac.sh`

- [ ] **Step 1: 在 source-only guard 之後加入主流程**

```bash
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
```

- [ ] **Step 2: 驗證 bats 測試仍通過**

Run: `bats tests/test_write_wifi_mac.bats`
Expected: All 10 tests PASS

- [ ] **Step 3: Commit**

```bash
git add device/write_wifi_mac.sh
git commit -m "feat: add main flow for device-side MAC write"
```

---

### Task 5: 推送到裝置並做端到端測試

**Files:**
- Review: `device/write_wifi_mac.sh`

- [ ] **Step 1: 推送腳本到裝置**

```bash
adb push device/write_wifi_mac.sh /vendor/bin/write_wifi_mac.sh
adb shell chmod 755 /vendor/bin/write_wifi_mac.sh
```

- [ ] **Step 2: 在裝置上執行完整流程（透過 adb shell 觸發）**

```bash
adb shell write_wifi_mac.sh 48:21:0B:00:00:07
```

Expected output:
```
SERIAL=DBB260100011
MAC_WRITTEN=48210B000007
MAC_READBACK=48210B000007
DRIVER_RELOAD=PASS
MAC_INTERFACE=48:21:0b:00:00:07
FRAMEWORK_MAC=PASS
WIFI_CONNECT=SKIP
IP_OBTAINED=SKIP
RESULT=PASS
```

- [ ] **Step 3: 恢復原始 MAC**

```bash
adb shell write_wifi_mac.sh 48:21:0B:96:F6:35
```

Expected: RESULT=PASS

- [ ] **Step 4: Commit final**

```bash
git add -A
git commit -m "test: verify device-side script on real device"
```
