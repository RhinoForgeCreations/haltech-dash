# Haltech Dash

A Flutter Android app that connects to a **WiCAN** Wi-Fi CAN adapter and displays real-time engine data from a **Haltech Elite ECU**. Designed as a mobile dashboard replacement for use in-car — inspired by the IC-7 dash style.

---

## Features

- **Real-time CAN data** — RPM, boost (psi), ECT, IAT, AFR, ignition angle, TPS, injector duty, fuel flow, knock level, oil temp, fuel temp, STFT/LTFT, battery voltage, gear
- **Tachometer** with gear indicator and boost arc
- **Mini gauge row** — secondary channels displayed in a compact strip
- **AVI output control** — toggle AVI1/AVI2 outputs on the Haltech IO Box (e.g. boost control solenoids, fans)
- **CSV data logging** — one-tap log start/stop, exports via Android share sheet
- **IC-7 inspired dark UI** — high-contrast, readable at a glance

---

## Requirements

| Component | Details |
|-----------|---------|
| Android phone | Android 7.0+ |
| WiCAN adapter | Wi-Fi mode, WebSocket on port 80 |
| ECU | Haltech Elite series (tested on Elite 1500) |
| IO Box | Haltech CAN IO Box (for AVI outputs) |
| Flutter | 3.x SDK (for building from source) |

---

## Installation

### Pre-built APK

1. Download `app-release.apk` from [Releases](../../releases)
2. Enable **Install unknown apps** in Android settings
3. Install the APK

### Build from source

```bash
git clone https://github.com/RhinoForgeCreations/haltech-dash.git
cd haltech-dash
flutter pub get
flutter build apk --release
# APK output: build/app/outputs/flutter-apk/app-release.apk
```

---

## Usage

### Connecting

1. Connect your phone to the **WiCAN Wi-Fi hotspot** (default SSID: `WiCAN_XXXXXX`)
2. Open Haltech Dash
3. Enter the WiCAN IP address (default: `192.168.80.1`) and tap **CONNECT**
4. Status indicator turns green when live data is flowing

### Dashboard (DASH tab)

- Large tachometer with RPM, boost arc, and gear number
- Top row: RPM · BOOST · ECT · IAT · AFR · IGN · TPS
- Bottom row: OIL · FUEL · STFT · LTFT · KNOCK · BATT

### Controls (CTRL tab)

- **AVI1 / AVI2** — tap to toggle Haltech auxiliary outputs (latches on/off, sends continuously while active)
- **LOG** button — tap once to start recording, tap again to stop and share the CSV file

### CSV Log format

```
time_ms,rpm,map_kpa,tps,ect,iat,afr,ign_angle,inj_duty,fuel_flow,knock,...
0,850,101.5,0.0,85.2,22.4,14.7,12.0,8.5,1.2,0.0,...
```

---

## How It Works

### CAN → WiCAN → WebSocket

The WiCAN adapter bridges the car's CAN bus to Wi-Fi. The app connects via WebSocket and communicates using **SLCAN text format** (`tIIIDLLDDDD...\r`).

### Haltech CAN channels decoded

| CAN ID | Content |
|--------|---------|
| `0x360` | RPM, MAP, TPS |
| `0x362` | Injector duty, ignition angle |
| `0x364` | Fuel flow |
| `0x368` | Lambda 1 & 2 (converted to AFR × 14.7) |
| `0x36A` | Knock level & count |
| `0x372` | Battery voltage, target boost, barometric pressure |
| `0x3E0` | ECT, IAT |
| `0x3E2` | Oil temp, fuel temp |
| `0x3E3` | Short-term & long-term fuel trim |
| `0x3E4` | Switch byte |
| `0x470` | Gear |
| `0x473` | Status byte |

### AVI outputs (IO Box)

AVI frames use CAN ID `0x2C0`, 8 bytes, big-endian. `ON = 0x0FFF`, `OFF = 0x0000`.  
**Critical:** a keepalive frame (`0x2C6`) must be sent every 100ms or the Elite ignores all AVI commands.

---

## Troubleshooting

**App connects but no data**  
→ Confirm the Haltech CAN stream is enabled in NSP (`CAN → CAN Configuration → Enable CAN Stream`)

**AVI buttons do nothing**  
→ Confirm the CAN IO Box is enabled in NSP and the correct AVI channel is assigned

**WebSocket drops immediately**  
→ Phone must be connected to WiCAN's Wi-Fi network, not your home network

**Build fails**  
→ Run `flutter pub get` first; requires Flutter 3.x

---

## License

MIT — see [LICENSE](LICENSE)
