# WiFi MAC Address 生產線寫入腳本實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立一個 bash 腳本 `write_mac.sh`，在 QCS6490+QCA6750 Android tablet 生產線上透過 ADB 寫入 WiFi MAC address 並完成驗證與連線測試。

**Architecture:** 單一 bash 腳本，包含 helper functions 處理各階段邏輯（MAC 驗證、寫入、driver 重載、連線測試）。腳本輸出結構化 key=value 格式供 PC 端管理系統解析。搭配 bats 測試框架驗證純邏輯函式（格式轉換、驗證），裝置相關功能透過手動測試。

**Tech Stack:** Bash, ADB, bats-core (testing)

---

## File Structure

| File | Responsibility |
|------|---------------|
| `write_mac.sh` | 主腳本：MAC 寫入、驗證、連線測試的完整流程 |
| `tests/test_write_mac.bats` | 單元測試：MAC 格式驗證、轉換等純邏輯函式 |
| `backups/` | 目錄：存放寫入前備份的原始 MAC 檔案（由腳本自動建立） |

---

### Task 1: 腳本骨架與 MAC 格式驗證

**Files:**
- Create: `write_mac.sh`
- Create: `tests/test_write_mac.bats`

- [ ] **Step 1: 安裝 bats 測試框架**

```bash
brew install bats-core
```

- [ ] **Step 2: 建立測試檔案，撰寫 MAC 格式驗證的 failing tests**

```bash
#!/usr/bin/env bats
# tests/test_write_mac.bats

setup() {
    source ./write_mac.sh --source-only
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
```

- [ ] **Step 3: 執行測試，確認失敗**

Run: `bats tests/test_write_mac.bats`
Expected: FAIL — `write_mac.sh` 不存在或函式未定義

- [ ] **Step 4: 建立腳本骨架與 MAC 格式驗證函式**

```bash
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
```

- [ ] **Step 5: 設定執行權限並執行測試**

Run: `chmod +x write_mac.sh && bats tests/test_write_mac.bats`
Expected: All 9 tests PASS

- [ ] **Step 6: Commit**

```bash
git add write_mac.sh tests/test_write_mac.bats
git commit -m "feat: add script skeleton with MAC validation and normalization"
```

---

### Task 2: ADB 連線檢查與 MAC 寫入

**Files:**
- Modify: `write_mac.sh`

- [ ] **Step 1: 在 `write_mac.sh` 的 source-only guard 之後，加入 ADB 與寫入相關函式**

在 `# --- Source-only guard ---` 區塊之前插入：

```bash
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
```

- [ ] **Step 2: 在裝置上手動測試 ADB 函式**

```bash
source ./write_mac.sh --source-only
check_adb_connection
# Expected: 輸出裝置序號，如 DBB260100011
```

- [ ] **Step 3: Commit**

```bash
git add write_mac.sh
git commit -m "feat: add ADB connection check, backup, write, and verify functions"
```

---

### Task 3: Driver 重載與 MAC 介面驗證

**Files:**
- Modify: `write_mac.sh`

- [ ] **Step 1: 在 `verify_mac_written` 函式之後加入 driver 重載函式**

```bash
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
```

- [ ] **Step 2: 在裝置上手動測試 driver 重載**

```bash
source ./write_mac.sh --source-only
reload_wlan_driver && echo "RELOAD OK" || echo "RELOAD FAIL"
wait_for_wlan_interface && echo "WLAN UP" || echo "WLAN TIMEOUT"
get_interface_mac
# Expected: 重載成功，wlan0 出現，輸出目前 MAC
```

- [ ] **Step 3: Commit**

```bash
git add write_mac.sh
git commit -m "feat: add wlan driver reload and interface MAC verification"
```

---

### Task 4: WiFi 連線測試

**Files:**
- Modify: `write_mac.sh`

- [ ] **Step 1: 在 `verify_interface_mac` 函式之後加入 WiFi 連線測試函式**

```bash
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
```

- [ ] **Step 2: 在裝置上手動測試 WiFi 連線（需要測試 AP）**

```bash
source ./write_mac.sh --source-only
wifi_connect_test "YOUR_TEST_SSID" "YOUR_TEST_PASSWORD"
# Expected: 輸出取得的 IP 位址
```

- [ ] **Step 3: Commit**

```bash
git add write_mac.sh
git commit -m "feat: add WiFi connection test and cleanup"
```

---

### Task 5: 主流程與結構化輸出

**Files:**
- Modify: `write_mac.sh`

- [ ] **Step 1: 在 source-only guard 之後加入輸出函式與主流程**

```bash
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

    # Step 8: WiFi connection test (optional)
    if [[ -n "$test_ssid" && -n "$test_password" ]]; then
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

- [ ] **Step 2: 在裝置上執行完整流程測試（不含 WiFi 連線）**

```bash
./write_mac.sh AA:BB:CC:DD:EE:FF
```

Expected output:
```
SERIAL=DBB260100011
MAC_WRITTEN=AABBCCDDEEFF
MAC_READBACK=AABBCCDDEEFF
DRIVER_RELOAD=PASS
MAC_INTERFACE=aa:bb:cc:dd:ee:ff
WIFI_CONNECT=SKIP
IP_OBTAINED=SKIP
RESULT=PASS
```

- [ ] **Step 3: 在裝置上執行完整流程測試（含 WiFi 連線）**

```bash
./write_mac.sh AA:BB:CC:DD:EE:FF "TEST_SSID" "TEST_PASSWORD"
```

Expected output:
```
SERIAL=DBB260100011
MAC_WRITTEN=AABBCCDDEEFF
MAC_READBACK=AABBCCDDEEFF
DRIVER_RELOAD=PASS
MAC_INTERFACE=aa:bb:cc:dd:ee:ff
WIFI_CONNECT=PASS
IP_OBTAINED=192.168.x.x
RESULT=PASS
```

- [ ] **Step 4: 恢復裝置原始 MAC**

```bash
./write_mac.sh 48:21:0B:96:F6:35
```

- [ ] **Step 5: Commit**

```bash
git add write_mac.sh
git commit -m "feat: add main flow with structured output and exit codes"
```

---

### Task 6: 執行所有測試並最終驗證

**Files:**
- Review: `write_mac.sh`
- Review: `tests/test_write_mac.bats`

- [ ] **Step 1: 執行 bats 單元測試**

Run: `bats tests/test_write_mac.bats`
Expected: All 9 tests PASS

- [ ] **Step 2: 執行 shellcheck 靜態分析**

```bash
brew install shellcheck  # if not installed
shellcheck write_mac.sh
```

Expected: No errors (warnings acceptable)

- [ ] **Step 3: 修復 shellcheck 發現的問題（如有）**

根據 shellcheck 輸出修正腳本中的問題。

- [ ] **Step 4: 在裝置上執行完整端到端測試**

```bash
# 用一個測試 MAC 執行完整流程
./write_mac.sh AA:BB:CC:DD:EE:FF

# 確認輸出 RESULT=PASS

# 恢復原始 MAC
./write_mac.sh 48:21:0B:96:F6:35
```

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "chore: final verification and shellcheck fixes"
```
