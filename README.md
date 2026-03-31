# WiFi MAC Writer

Production line tool for writing WiFi MAC addresses to Android tablets based on **QCS6490 + QCA6750** platform.

## Features

- Write WiFi MAC address to persist partition (survives factory reset)
- Reload WiFi driver and verify MAC at interface level
- Update Android Settings UI to display correct MAC
- Optional WiFi connectivity test
- Structured key=value output for management system integration

## Two Versions

| Version | Script | Runs on | Best for |
|---------|--------|---------|----------|
| **Device-side** | `device/write_wifi_mac.sh` | Android device | Production line (recommended) |
| **Host-side** | `write_mac.sh` | PC via ADB | Quick testing |

The device-side version runs entirely on the device with a single `adb shell` trigger, making it faster and more stable during framework restarts.

## Quick Start

### Device-side (recommended)

```bash
# Push to device (one-time setup)
adb push device/write_wifi_mac.sh /data/local/tmp/write_wifi_mac.sh
adb shell chmod 755 /data/local/tmp/write_wifi_mac.sh

# Write MAC
adb shell /data/local/tmp/write_wifi_mac.sh AA:BB:CC:DD:EE:FF

# Write MAC + WiFi connection test
adb shell /data/local/tmp/write_wifi_mac.sh AA:BB:CC:DD:EE:FF "TestAP" "password"
```

### Host-side

```bash
./write_mac.sh AA:BB:CC:DD:EE:FF
```

## Output

```
SERIAL=DBB260100011
MAC_WRITTEN=AABBCCDDEEFF
MAC_READBACK=AABBCCDDEEFF
DRIVER_RELOAD=PASS
MAC_INTERFACE=aa:bb:cc:dd:ee:ff
FRAMEWORK_MAC=PASS
WIFI_CONNECT=SKIP
IP_OBTAINED=SKIP
RESULT=PASS
```

Check `RESULT` field: `PASS` = success, `FAIL` = see `ERROR` field.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All passed |
| 2 | Invalid MAC format |
| 3 | Write failed |
| 4 | Read-back mismatch |
| 5 | Driver reload failed |
| 6 | Interface MAC mismatch |
| 7 | WiFi connection test failed |
| 8 | Framework MAC update failed |

## Platform Details

| Item | Value |
|------|-------|
| SoC | Qualcomm QCS6490 |
| WiFi chip | QCA6750 |
| WiFi module | `/vendor/lib/modules/qca_cld3_qca6750.ko` |
| MAC file | `/mnt/vendor/persist/qca6750/wlan_mac.bin` |
| MAC format | `Intf0MacAddress=XXXXXXXXXXXX` |

## Documentation

- [User Guide](USER_GUIDE.md) - Detailed usage, troubleshooting, and integration guide
- [Design Spec (Host-side)](docs/superpowers/specs/2026-03-31-wifi-mac-write-design.md)
- [Design Spec (Device-side)](docs/superpowers/specs/2026-03-31-wifi-mac-device-side-design.md)

## Running Tests

```bash
brew install bats-core   # one-time
bats tests/              # run all tests
```

## License

Internal use only.
