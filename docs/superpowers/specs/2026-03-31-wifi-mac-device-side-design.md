# WiFi MAC Address 生產線寫入方案（Device-Side）設計

## 概述

將 WiFi MAC 寫入邏輯從 PC 端搬到裝置端執行。腳本預先燒錄在出廠映像的 `/vendor/bin/` 中，Host 端只需一行 `adb shell` 觸發，結果透過 stdout 回傳。

## 動機

Host-side 方案的痛點：
- 每個操作都透過 `adb shell` 遠端執行，累積延遲明顯
- framework restart 後 ADB 斷線需要重連邏輯，增加複雜度和失敗風險
- 生產線上 ADB 連線不穩定會導致中途失敗

Device-side 方案解決以上問題：一次 ADB 呼叫、本地執行、framework restart 不影響腳本。

## 平台資訊

| 項目 | 值 |
|------|------|
| SoC | Qualcomm QCS6490 |
| WiFi 晶片 | QCA6750 |
| wlan driver | kernel module（`qca_cld3_qca6750.ko`） |
| MAC 檔案路徑 | `/mnt/vendor/persist/qca6750/wlan_mac.bin` |
| MAC 檔案格式 | `Intf0MacAddress=XXXXXXXXXXXX`（無冒號、大寫 hex） |
| WifiConfigStore | `/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml` |
| adb shell 權限 | root（userdebug build） |

## 架構

```
PC 端（管理系統）                    Android Device（QCS6490）
┌──────────────┐                    ┌──────────────────────────┐
│              │  一次 adb shell    │  /vendor/bin/            │
│  管理系統     │ ─────────────────▶│    write_wifi_mac.sh     │
│  (MAC DB)    │                    │                          │
│              │◀───── stdout ──── │  本地執行：               │
│  解析結果     │  key=value 輸出   │  1. 驗證 MAC 格式         │
└──────────────┘                    │  2. 寫入 wlan_mac.bin    │
                                    │  3. 讀回驗證             │
                                    │  4. reload driver        │
                                    │  5. 驗證 interface MAC   │
                                    │  6. 更新 WifiConfigStore │
                                    │  7. restart framework    │
                                    │  8. 驗證 framework MAC   │
                                    │  9. (選) WiFi 連線測試    │
                                    └──────────────────────────┘
```

## Host 端呼叫方式

```bash
# 僅寫入 + 驗證
adb shell write_wifi_mac.sh AA:BB:CC:DD:EE:FF

# 寫入 + 驗證 + WiFi 連線測試
adb shell write_wifi_mac.sh AA:BB:CC:DD:EE:FF TEST_SSID TEST_PASSWORD
```

## Device-Side 腳本

### 檔案資訊

- **路徑：** `/vendor/bin/write_wifi_mac.sh`
- **權限：** 755 (rwxr-xr-x)
- **Owner：** root:shell

### 與 Host-side 方案的指令對照

| 操作 | Host-side (現有) | Device-side (新) |
|------|-----------------|------------------|
| 寫入 MAC | `adb shell "echo '...' > file"` | `echo '...' > file` |
| 讀回驗證 | `adb shell "cat file" \| tr -d '\r'` | `cat file` |
| rmmod/insmod | `adb shell "rmmod wlan"` | `rmmod wlan` |
| 讀 interface MAC | `adb shell "cat /sys/..."` | `cat /sys/...` |
| 更新 XML | `adb shell "sed -i ..."` | `sed -i ...` |
| framework restart | `adb shell "stop; start"` + ADB 重連 | `stop; start` + 本地 getprop 輪詢 |
| 取得序號 | `adb get-serialno` | `getprop ro.serialno` |
| WiFi 操作 | `adb shell "cmd wifi ..."` | `cmd wifi ...` |

### 不再需要

- `tr -d '\r'`（沒有 ADB 的 carriage return 問題）
- ADB 重連邏輯
- `check_adb_connection()` 函式

### Framework MAC 更新策略

不直接修改 `WifiConfigStore.xml`，而是刪除它讓 framework 重建：

1. 若 XML 中的 MAC 已正確 → 跳過 framework restart（~5 秒）
2. 否則：刪除 XML → restart framework → 等待 `boot_completed` → 等待 WiFi service 就緒 → 開啟 WiFi → framework 自動從 driver 讀取正確 MAC 並重建 XML → 驗證

```bash
# 刪除 XML（強制 framework 重建）
rm "${WIFI_CONFIG_STORE}"

# Restart framework（清除記憶體中的 factory MAC 快取）
stop; start

# 等待 boot_completed
while ...; do getprop sys.boot_completed; done

# 等待 WiFi service 就緒（boot_completed 後仍需 5-10 秒）
while ...; do cmd wifi status; done

# 開啟 WiFi（觸發 framework 從 driver 讀取 factory MAC 並生成 XML）
cmd wifi set-wifi-enabled enabled
```

**重要發現：** `boot_completed=1` 不代表所有 service 就緒，WiFi service 需要額外等待 5-10 秒。`factory_mac` 只有在 WiFi 啟用後才出現在 `dumpsys wifi` 中。

## 流程

1. 驗證 MAC 格式（轉為 12 位大寫 hex）
2. 取得裝置序號（`getprop ro.serialno`）
3. 寫入 `/mnt/vendor/persist/qca6750/wlan_mac.bin`
4. 讀回檔案內容，比對是否一致
5. 重載 wlan driver（`rmmod wlan` + `insmod qca_cld3_qca6750.ko`）
6. 等待 wlan0 介面出現（最多 10 秒）
7. 讀取 wlan0 MAC，比對是否一致
8. 更新 framework factory MAC（刪除 XML → restart framework → 開 WiFi → 等 framework 重建 XML）
9. 驗證 `dumpsys wifi` 中的 factory MAC
10. （可選）WiFi 連線測試
11. 輸出結果

### 耗時參考

| 場景 | 耗時 |
|------|------|
| XML 不存在或 MAC 不同 | ~25 秒 |
| MAC 已相同（跳過 framework restart） | ~5 秒 |

## 退出碼

| 碼 | 意義 |
|----|------|
| 0 | 全部通過 |
| 2 | MAC 格式錯誤 |
| 3 | 寫入失敗 |
| 4 | 讀回驗證失敗 |
| 5 | driver 重載失敗 |
| 6 | MAC 比對失敗 |
| 7 | WiFi 連線測試失敗 |
| 8 | framework MAC 更新失敗 |

## 輸出格式

腳本輸出 key=value 格式到 stdout，與 Host-side 方案相容：

### 成功範例

```
SERIAL=DBB260100011
MAC_WRITTEN=48210B000005
MAC_READBACK=48210B000005
DRIVER_RELOAD=PASS
MAC_INTERFACE=48:21:0b:00:00:05
FRAMEWORK_MAC=PASS
WIFI_CONNECT=SKIP
IP_OBTAINED=SKIP
RESULT=PASS
```

### 失敗範例

```
SERIAL=DBB260100011
MAC_WRITTEN=48210B000005
MAC_READBACK=48210B000005
DRIVER_RELOAD=PASS
MAC_INTERFACE=48:21:0b:00:00:05
FRAMEWORK_MAC=FAIL
RESULT=FAIL
ERROR=Framework factory MAC verification failed
```

## 出廠映像整合

在 BSP device tree 中加入：

```makefile
# device/<vendor>/<device>/device.mk
PRODUCT_COPY_FILES += \
    device/<vendor>/<device>/factory/write_wifi_mac.sh:$(TARGET_COPY_OUT_VENDOR)/bin/write_wifi_mac.sh
```

### SELinux

裝置為 userdebug build，adb shell 以 root 執行。若遇到 SELinux denied，需在 vendor sepolicy 加入對應的 allow rule。

## 已知限制

- **Locally Administered Bit：** QCA6750 驅動會清除 MAC 第一個 byte 的 bit 1（IEEE locally administered bit）。從 OUI block 分配的正式 MAC 不受影響。
- **wlan module 路徑：** 實際模組路徑為 `/vendor/lib/modules/qca_cld3_qca6750.ko`，不同 BSP 版本可能路徑不同。
- **framework restart：** `stop; start` 會重啟所有 Android 服務，生產線上不會有使用者影響。
- **WiFi service 就緒延遲：** `boot_completed=1` 後 WiFi service 仍需 5-10 秒才就緒，腳本會輪詢等待。
- **factory_mac 快取：** Android framework 會快取 factory MAC，僅 restart framework 才能清除。單純 reload WiFi driver 不會更新 framework 快取。
