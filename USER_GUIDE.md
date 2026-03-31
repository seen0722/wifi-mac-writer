# WiFi MAC Address Production Line Write Tool - User Guide

## Overview

This tool writes WiFi MAC addresses to QCS6490 + QCA6750 Android tablets during production. Two versions are provided:

| Version | Script | Runs on | Use case |
|---------|--------|---------|----------|
| **Host-side** | `write_mac.sh` | PC (via ADB) | Quick testing from PC |
| **Device-side** (recommended) | `device/write_wifi_mac.sh` | Device itself | Production line use |

The device-side version is recommended for production because it is faster and more stable (not affected by ADB disconnections during framework restart).

---

## Prerequisites

- Android tablet with QCS6490 + QCA6750, flashed with userdebug build
- USB cable connected between PC and tablet
- ADB enabled and authorized on the tablet
- MAC addresses from your IEEE OUI block (bit 1 of first byte must be 0)

---

## Device-Side Version (Recommended for Production)

### Setup (one-time)

**Option A: Build into factory image (recommended for mass production)**

Add to your BSP device tree:

```makefile
# device/<vendor>/<device>/device.mk
PRODUCT_COPY_FILES += \
    device/<vendor>/<device>/factory/write_wifi_mac.sh:$(TARGET_COPY_OUT_VENDOR)/bin/write_wifi_mac.sh
```

**Option B: Push manually (for testing)**

```bash
adb push device/write_wifi_mac.sh /data/local/tmp/write_wifi_mac.sh
adb shell chmod 755 /data/local/tmp/write_wifi_mac.sh
```

### Usage

```bash
# Write MAC only (no WiFi connection test)
adb shell write_wifi_mac.sh <MAC_ADDRESS>

# Write MAC + WiFi connection test
adb shell write_wifi_mac.sh <MAC_ADDRESS> <TEST_AP_SSID> <TEST_AP_PASSWORD>
```

If using Option B (manual push):
```bash
adb shell /data/local/tmp/write_wifi_mac.sh <MAC_ADDRESS>
```

### Examples

```bash
# Write a single MAC
adb shell write_wifi_mac.sh A0:BB:CC:00:00:01

# Write MAC and verify WiFi connectivity
adb shell write_wifi_mac.sh A0:BB:CC:00:00:01 "FactoryTestAP" "test1234"
```

---

## Host-Side Version

### Usage

```bash
# Write MAC only
./write_mac.sh <MAC_ADDRESS>

# Write MAC + WiFi connection test
./write_mac.sh <MAC_ADDRESS> <TEST_AP_SSID> <TEST_AP_PASSWORD>
```

### Examples

```bash
./write_mac.sh A0:BB:CC:00:00:01
./write_mac.sh A0:BB:CC:00:00:01 "FactoryTestAP" "test1234"
```

---

## MAC Address Format

Both formats are accepted:

- `AA:BB:CC:DD:EE:FF` (colon-separated)
- `AABBCCDDEEFF` (no separator)

Case insensitive. The tool automatically converts to the required format.

### Important: Locally Administered Bit

The QCA6750 driver clears bit 1 of the first byte (the IEEE "locally administered" bit). This means:

| First byte | Bit 1 | Result |
|-----------|-------|--------|
| `A0` (10100000) | 0 | Works correctly |
| `AA` (10101010) | 1 | Driver changes to `A8` - verification fails |
| `02` (00000010) | 1 | Driver changes to `00` - verification fails |

**Rule: Only use MAC addresses from your purchased IEEE OUI block.** OUI-registered addresses always have bit 1 = 0 and will work correctly.

---

## Output Format

The tool outputs structured key=value pairs to stdout:

### Success

```
SERIAL=DBB260100011
MAC_WRITTEN=A0BBCC000001
MAC_READBACK=A0BBCC000001
DRIVER_RELOAD=PASS
MAC_INTERFACE=a0:bb:cc:00:00:01
FRAMEWORK_MAC=PASS
WIFI_CONNECT=SKIP
IP_OBTAINED=SKIP
RESULT=PASS
```

### Failure

```
SERIAL=DBB260100011
MAC_WRITTEN=A0BBCC000001
MAC_READBACK=A0BBCC000001
DRIVER_RELOAD=PASS
MAC_INTERFACE=a0:bb:cc:00:00:01
FRAMEWORK_MAC=FAIL
RESULT=FAIL
ERROR=Framework factory MAC verification failed
```

**Your management system should check the `RESULT` field:** `PASS` = all good, `FAIL` = check `ERROR` field for details.

---

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| 0 | All passed | None |
| 2 | Invalid MAC format | Check MAC address format |
| 3 | Write failed | Check persist partition is mounted rw |
| 4 | Read-back mismatch | Re-run; if persistent, check storage |
| 5 | Driver reload failed | Check wlan module path; reboot device and retry |
| 6 | Interface MAC mismatch | Check locally administered bit (see above) |
| 7 | WiFi connection test failed | Check test AP SSID/password; check AP is powered on |
| 8 | Framework MAC update failed | Check WifiConfigStore.xml exists; retry after full reboot |

---

## What the Tool Does (Step by Step)

1. **Validates** the MAC address format
2. **Writes** `Intf0MacAddress=<MAC>` to `/mnt/vendor/persist/qca6750/wlan_mac.bin`
3. **Reads back** the file to verify it was written correctly
4. **Reloads** the WiFi driver (`rmmod wlan` + `insmod qca_cld3_qca6750.ko`)
5. **Waits** for the `wlan0` interface to come up (up to 10 seconds)
6. **Verifies** the interface MAC matches what was written
7. **Updates** `wifi_sta_factory_mac_address` in `WifiConfigStore.xml` (so Settings UI shows the correct MAC)
8. **Restarts** the Android framework (`stop` / `start`) and waits for it to be ready
9. **Verifies** the framework reports the correct factory MAC
10. **(Optional)** Connects to a test WiFi AP and verifies IP assignment

The MAC persists across factory reset (stored on persist partition).

---

## Troubleshooting

### "Driver reload failed" (exit code 5)

```bash
# Check if wlan module is loaded
adb shell lsmod | grep wlan

# Check module file exists
adb shell ls -la /vendor/lib/modules/qca_cld3_qca6750.ko

# Try manual reload
adb shell rmmod wlan
adb shell insmod /vendor/lib/modules/qca_cld3_qca6750.ko
```

### "Interface MAC mismatch" (exit code 6)

Most likely using a MAC with locally administered bit set. Use MACs from your OUI block only.

```bash
# Check current interface MAC
adb shell cat /sys/class/net/wlan0/address

# Check what's in the MAC file
adb shell cat /mnt/vendor/persist/qca6750/wlan_mac.bin
```

### "Framework MAC update failed" (exit code 8)

```bash
# Check if WifiConfigStore.xml exists
adb shell ls -la /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml

# Check current framework factory MAC
adb shell dumpsys wifi | grep factory_mac

# If file missing, reboot device fully and retry
adb reboot
```

### Settings UI still shows old MAC

The tool updates both the driver MAC and the Settings UI MAC. If Settings still shows the old value after a successful run (`RESULT=PASS`), try:

```bash
# Full reboot (not just framework restart)
adb reboot
```

---

## File Locations on Device

| File | Purpose |
|------|---------|
| `/mnt/vendor/persist/qca6750/wlan_mac.bin` | WiFi MAC storage (survives factory reset) |
| `/vendor/lib/modules/qca_cld3_qca6750.ko` | WiFi kernel module |
| `/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml` | WiFi framework config (Settings UI MAC) |
| `/vendor/etc/wifi/qca6750/WCNSS_qcom_cfg.ini` | WiFi driver config (`read_mac_addr_from_mac_file=1`) |
