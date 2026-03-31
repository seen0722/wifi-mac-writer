# WiFi MAC Address 生產線寫入方案設計

## 概述

在 QCS6490 + QCA6750 平台的 Android tablet 生產線上，透過 ADB 將自有 OUI block 的 WiFi MAC address 寫入裝置，並完成驗證與連線測試。

## 平台資訊

| 項目 | 值 |
|------|------|
| SoC | Qualcomm QCS6490 |
| WiFi 晶片 | QCA6750（獨立模組） |
| wlan driver | kernel module（可 rmmod/insmod） |
| MAC 檔案路徑 | `/mnt/vendor/persist/qca6750/wlan_mac.bin` |
| MAC 檔案格式 | `Intf0MacAddress=XXXXXXXXXXXX`（無冒號、大寫 hex） |
| BSP 設定 | `read_mac_addr_from_mac_file=1`（已啟用） |
| persist 分區 | ext4, rw, factory reset 不清除 |

## 架構

```
┌──────────────┐      ADB       ┌──────────────────────────┐
│   PC 端      │ ──────────────▶│   Android Tablet         │
│  管理系統     │   傳送 MAC     │   (QCS6490 + QCA6750)    │
│  (MAC DB)    │◀────────────── │                          │
│              │   回傳驗證結果  │  /mnt/vendor/persist/    │
└──────────────┘                │    └─ qca6750/           │
                                │        └─ wlan_mac.bin   │
                                │                          │
                                │  CNSS Driver 載入時      │
                                │  自動讀取 wlan_mac.bin    │
                                │  → 設定 WiFi MAC         │
                                └──────────────────────────┘
```

## PC 端寫入腳本

### 介面

```
write_mac.sh <MAC_ADDRESS> [TEST_AP_SSID] [TEST_AP_PASSWORD]
```

- `MAC_ADDRESS`：必填，支援 `AA:BB:CC:DD:EE:FF` 或 `AABBCCDDEEFF` 格式
- `TEST_AP_SSID` / `TEST_AP_PASSWORD`：可選，提供時執行 WiFi 連線測試

### 流程

1. 檢查 ADB 連線
2. 驗證 MAC 格式（轉為 12 位大寫 hex）
3. 備份原始 `wlan_mac.bin` 到 PC 端（以裝置序號命名）
4. 寫入 `/mnt/vendor/persist/qca6750/wlan_mac.bin`
5. 讀回檔案內容，比對是否一致
6. 重載 wlan driver（rmmod + insmod）
7. 等待 wlan0 介面出現
8. 讀取 wlan0 MAC，比對是否一致
9. （可選）連線測試 AP，確認能取得 IP
10. 輸出結果

### 退出碼

| 碼 | 意義 |
|----|------|
| 0 | 全部通過 |
| 1 | ADB 連線失敗 |
| 2 | MAC 格式錯誤 |
| 3 | 寫入失敗 |
| 4 | 讀回驗證失敗 |
| 5 | driver 重載失敗 |
| 6 | MAC 比對失敗 |
| 7 | WiFi 連線測試失敗 |

## wlan_mac.bin 寫入細節

- **檔案路徑：** `/mnt/vendor/persist/qca6750/wlan_mac.bin`
- **檔案格式：** `Intf0MacAddress=XXXXXXXXXXXX`（無冒號、大寫 hex）
- **檔案權限：** `-rw-rw-rw-` (666)，owner root:root
- **預期大小：** 約 29 bytes

### 防呆機制

- 寫入前備份原始 MAC 檔案到 PC 端（以裝置序號命名）
- 寫入後讀回比對，確保檔案內容正確
- 檢查檔案大小是否合理

### MAC 格式轉換

腳本接受 `AA:BB:CC:DD:EE:FF` 或 `AABBCCDDEEFF`，內部統一轉為無冒號大寫後寫入。

## Driver 重載與 MAC 驗證

### 重載流程

1. `adb shell rmmod wlan`
2. 等待 1 秒
3. `adb shell insmod /vendor/lib/modules/wlan.ko`
4. 輪詢等待 wlan0 出現（最多 10 秒，每秒檢查一次）
5. `adb shell cat /sys/class/net/wlan0/address`
6. 比對讀回的 MAC 與寫入的 MAC

### 容錯處理

- `rmmod` 失敗 → 嘗試 `adb shell ifconfig wlan0 down` 後再 `rmmod`
- `insmod` 失敗 → 記錄錯誤，退出碼 5
- `wlan0` 超時未出現 → 退出碼 5
- MAC 不一致 → 退出碼 6

## WiFi 連線測試

僅在提供 SSID 和密碼參數時執行。

### 連線流程

1. `adb shell cmd wifi set-wifi-enabled enabled`
2. `adb shell cmd wifi connect-network <SSID> wpa2 <PASSWORD>`
3. 輪詢等待連線成功（最多 15 秒，檢查 CONNECTED 狀態）
4. 檢查是否取得 IP（`ip addr show wlan0` 檢查 inet 欄位）
5. 測試完成後清除：
   - `adb shell cmd wifi forget-network <SSID>`
   - `adb shell cmd wifi set-wifi-enabled disabled`

### 注意事項

- 生產線需部署專用測試 AP
- 測試完成後清除連線紀錄，避免出貨時殘留

## 已知限制

- **Locally Administered Bit：** QCA6750 驅動會清除 MAC 第一個 byte 的 bit 1（IEEE locally administered bit）。從 OUI block 分配的正式 MAC 不受影響（bit 1 本來就是 0），但若使用 `AA:BB:CC:DD:EE:FF` 等測試地址可能導致驗證失敗。
- **wlan module 路徑：** 實際模組路徑為 `/vendor/lib/modules/qca_cld3_qca6750.ko`，非通用的 `wlan.ko`。不同 BSP 版本可能路徑不同。

## 輸出格式

腳本輸出 key=value 格式到 stdout，供管理系統解析：

### 成功範例

```
SERIAL=DBB260100011
MAC_WRITTEN=48210B96F635
MAC_READBACK=48210B96F635
MAC_INTERFACE=48:21:0b:96:f6:35
DRIVER_RELOAD=PASS
WIFI_CONNECT=PASS
IP_OBTAINED=192.168.1.100
RESULT=PASS
```

### 失敗範例

```
SERIAL=DBB260100011
MAC_WRITTEN=48210B96F635
MAC_READBACK=48210B96F635
MAC_INTERFACE=aa:bb:cc:dd:ee:ff
DRIVER_RELOAD=PASS
WIFI_CONNECT=FAIL
IP_OBTAINED=NONE
RESULT=FAIL
ERROR=WiFi connection test failed
```

管理系統透過 `RESULT` 欄位快速判斷，細部欄位用於故障排查。
