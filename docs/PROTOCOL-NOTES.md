# ZUS / NONDA "OBDBLE" on Ford F-250 (diesel) — probe findings (19 Nov 2026, probe v0.3.0)

## Adapter
- GATT: service FFE0, characteristic FFE1 [read, writeWithoutResponse, notify]; 180A device info
- Model OBD10A0, firmware "TDA66 B201_2.X.22B6", maker NONDA, reports "ELM327 v1.5"
- Accepts: ATZ, ATE0, ATH0, ATRV, ATDPN, ATDP. Silent: ATL0, ATS0, ATI, AT@1. ATSP0 -> "Fail"
- No '>' prompt. Replies framed as: `ECU:n  CMD:xxxx  CNT:n\r\n<hex bytes>\r\n`, one block per ECU
- Prints `Connected nECU@6Z` when the bus wakes; `CMD:xxxx NULL` when no ECU answers

## Vehicle
- Protocol 6: ISO 15765-4 CAN 11-bit 500 kbps, 2 ECUs answer (ECU1 = PCM, ECU2 = TCM)
- Fuel type 0x04 = diesel. VIN year char K = 2019, plant E = Kentucky Truck; VIN tail ...4KEE14369 (head lost in BLE drop)
- CAL IDs (0904): ECU1 "K?204-AL?14D609-BD", ECU2 "TZCJ1VE.H32" (partial, BLE drop)
- Supported Mode 01 PIDs (union):
  01 04 05 0B 0C 0D 0F 10 1C 1E 1F 20 21 23 2C 2D 2F 30 31 33 40
  41 42 46 49 4A 51 59 5A 5C 5D 5E 60 61 62 63 64 65 66 67 68 69 6A 6B 6D 70 71 73 77 7F 80
  87 8E 9D 9E A0 A2
- Idle snapshot (engine running ~13 min): load 14%, ECT 61 C, MAP 79 kPa, RPM 599, IAT 20 C,
  MAF 23.86 g/s, rail 26820 kPa, baro 81 kPa, ECU V 14.44, ambient 16 C, oil 60 C, fuel rate 1.25 L/h,
  distance since DTC clear 15157 km, MIL off, no stored/pending/permanent DTCs

## Passive NONDA stream (1 Hz, always on once the ZUS app has enabled it)
`BD$V14.5;R00600;S000;P000.0;O014.1;C060;L046.6;XH008.072;M000000;F001.524;T0000680;A00;B00;D00;U32.5;GX-3;GY-27;GZ-65;@2`
| key | meaning (verified against OBD) |
|---|---|
| V | battery volts (= ATRV) |
| R | rpm (= 010C) |
| S | speed km/h |
| P | pedal/throttle % (0 at idle) — to confirm while driving |
| O | calculated load % (= 0104: 0x24 -> 14.1%) |
| C | coolant C (= 0105) |
| L | fuel level % (PID 2F supported) — to confirm |
| XH | MAF-based fuel-rate estimate L/h (wrong for diesel; use 015E instead) |
| F | trip fuel used L (rises ~XH/3600 per s) |
| T | trip seconds |
| M | trip distance (m) |
| A/B/D | event counters (harsh accel/brake/…) — to confirm |
| U | adapter internal temperature C (probable) |
| GX/GY/GZ | accelerometer, ~64 counts = 1 g |
| @ | frame counter 1–4 |

## Pitfalls for the app
- The stream interleaves with replies: parse by framing, never by position
- Long multi-frame replies (0902, 0904, 0900) lose 20-byte BLE packets while the stream runs:
  validate VIN with the ISO 3779 check digit and retry; never show an unvalidated VIN
- Don't send ATSP0; the adapter auto-detects protocol 6 by itself
