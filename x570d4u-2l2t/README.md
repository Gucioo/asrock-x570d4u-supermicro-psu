# ASRock Rack X570D4U-2L2T + Supermicro PMBus PSU (stock BMC firmware)

Making a Supermicro PMBus power supply show up in the **stock ASRock (AMI MegaRAC)**
BMC firmware on the **X570D4U-2L2T**, by patching the firmware.

This applies the method [Mrkvak worked out for the B650D4U](../README.md) to a different
board. If you would rather replace the firmware entirely, there is a full **OpenBMC** port
for this board that supports the PSU out of the box, along with sensors, fan control and a
dark web UI: <https://github.com/Gucioo/openbmc> (branch `x570d4u-2l2t-support`). This page
is for people who want to stay on ASRock's firmware.

Tested against a **Supermicro PWS-441P-1H**. The approach is plain PMBus, so it should
carry to other Supermicro PMBus supplies, but only that model has been tried.

## The short version

The X570D4U-2L2T's firmware already probes the **correct I2C bus** for the PSU — bus 2,
which is where the Supermicro lives. The **only** thing wrong is the address: ASRock expects
`0xB0` (7-bit `0x58`), the Supermicro answers at `0x78` (7-bit `0x3c`). Two binaries hold
that address hardcoded; patch both and the PSU appears.

This is simpler than the B650D4U case, where the bus itself (12) also had to be worked out.

## How the config was found

`/info/X570D4U-2L2T_K5.PRJ` inside the rootfs squashfs:

```
CONFIG_SPX_FEATURE_ASRR_PSU_INFO=YES
CONFIG_SPX_FEATURE_ASRR_PSU_INFO_I2C_BUS=2
CONFIG_SPX_FEATURE_ASRR_PSU_INFO_SLAVE_ADDR1=0xB0
CONFIG_SPX_FEATURE_ASRR_PSU_INFO_SLAVE_ADDR2=0xB2
CONFIG_SPX_FEATURE_ASRR_PSU_INFO_SLAVE_ADDR3=0xB4
CONFIG_SPX_FEATURE_ASRR_PSU_INFO_SLAVE_ADDR4=0xB6
```

Bus 2, addresses `0xB0/0xB2/0xB4/0xB6` (7-bit `0x58`–`0x5b`). As Mrkvak found on the
B650D4U, editing the `.PRJ` does nothing — the values are compiled into the libraries.

## Firmware layout (64 MiB, MX25L51245G)

AMI `$MODULE$` / FMH modules on 64 KiB boundaries:

| Offset | Module | Contents |
|---|---|---|
| `0x07FF00` | boot | u-boot |
| `0x0A0000` | conf | jffs2 config |
| `0x2A0000` | conf | jffs2 backup config |
| `0x4A0000` | dtb | device tree |
| `0x4B0000` | root | **rootfs squashfs @ `0x4C0000`** (xz, 128 KiB blocks) |
| `0x17E0000` | osimage | **FIT kernel — RSA/sha256 signed, do not touch** |
| `0x1AD0000` | www | web UI squashfs @ `0x1AE0000` |
| `0x3FF0000` | wolfpass# | — |

u-boot verifies the **FIT kernel** signature, not the rootfs squashfs. The kernel mounts the
squashfs from its MTD partition with no external signature check, which is why a modified,
**raw-flashed** rootfs boots. Keep the flashing raw (SPI programmer, or writing `/dev/mtd`
directly) — do not go through ASRock's own update tool, which validates module checksums.

## The two patches

Both are byte swaps; neither changes any file size.

### 1. `usr/local/lib/libpsuaccess.so.1.0.0` — the web UI PSU panel

At file offset `0x2048` sits the address array, followed by the PMBus command list it reads:

```
0x2048:  58 59 5a 5b | 88 89 97 8b 8c 96 8d 8e 90 91 a5 a6 a7 | 99 9a 9b 9e
         addresses     VIN IIN PIN VOUT IOUT POUT T1 T2 F1 F2 status...  MFR_ID/MODEL/REV/SN
```

Patch the first address: **`0x58` → `0x3c`** (one byte).

### 2. `usr/local/lib/ipmi/1U4LW-X570/2L2T-RPSU/libipmipar.so.1.0.0` — `ipmitool sensor`

The compiler optimised the literal `0xB0` into `mvn r3, #0x4f` (`~0x4f = 0xB0`), exactly as
Mrkvak saw on the B650D4U. Bytes `4f 30 e0 e3`, 8 occurrences in the PSU read functions
(paired with `mvn r3, #0x4d` → `0xB2` for PSU2). Replace with `mvn r3, #0x87`
(`~0x87 = 0x78` = 7-bit `0x3c`): bytes **`4f 30 e0 e3` → `87 30 e0 e3`**.

> The 8 sites were patched in bulk. They cluster in the PSU functions and pair with the
> PSU2 constant, so confidence is high, but they were not each confirmed in a disassembler.
> If a non-PSU IPMI reading looks wrong afterwards, that is the place to check. The web UI
> panel (patch 1) is independent of this.

Pick the `libipmipar.so` under **your** board/SKU directory. `1U4LW-X570/2L2T-RPSU` is the
2L2T board with redundant-PSU support; other SKUs have their own copy.

## Why no register remap or rescale is needed

With a hardware address translator (LTC4316) in the path, voltage and temperature read as
garbage. That was the translator corrupting the SMBus data, **not** a scaling problem. Read
directly at `0x3c`, the Supermicro speaks textbook PMBus. Every register decodes with the
standard LINEAR11 (11-bit two's-complement mantissa, 5-bit exponent) and LINEAR16 (with
`VOUT_MODE`) formats — captured live from the running board:

```
VIN  (0x88) raw 0xf9e2  -> 241.0  V     PIN  (0x97) raw 0x002f  ->  47 W
VOUT (0x8b) raw 0x1866  ->  12.20 V     POUT (0x96) raw 0x001a  ->  26 W
IOUT (0x8c) raw 0xd08c  ->   2.19 A     TEMP (0x8d) raw 0x0021  ->  33 C
FAN  (0x90) raw 0x285f  -> 3040  RPM    VOUT_MODE exponent = -9
```

(see [`pmbus-ground-truth.txt`](pmbus-ground-truth.txt)). ASRock's code reads these same
registers with standard decoding, so once the address is right the numbers come out right —
no remapping. Keep this table to compare against after flashing; a mismatch would point at a
scaling bug, but none is expected.

## What works, what does not

* **Web UI PSU panel** and **`ipmitool sensor`**: voltage, current, power, temperature, fan.
* **Model / ID / Revision / Serial: blank.** They come from the PMBus `MFR_*` commands
  (`0x99`/`0x9a`/`0x9b`/`0x9e`), and this PSU does not answer them. The real identity is in
  the FRU EEPROM at `0x38`, but ASRock's PSU code only reads the PMBus device at `0x3c`, not
  the FRU. Same result Mrkvak had — read it off the label.

## Building and flashing

[`make_patched_x570d4u.sh`](make_patched_x570d4u.sh) does the whole thing: carve the rootfs
squashfs, apply both patches, rebuild it (checking it still fits its slot), and splice it
back into a copy of your dump with everything else — including the signed kernel —
byte-identical.

```
sudo ./make_patched_x570d4u.sh <original_dump.bin> x570d4u-asrock-psu3c.bin
```

Run it as root so squashfs ownership and permissions survive. Then flash
`x570d4u-asrock-psu3c.bin` raw.

**Before you flash, verify your original dump reads back clean** — that dump plus an SPI
programmer is the whole recovery story. Nothing here is one-way: a bad flash is rewritten
with the original.

### Getting a root shell (optional)

Stock firmware gives no root shell: `sysadmin` is uid 0 but its login shell is the
restricted `defshell`, and SSH drops "No Access Privilege". You do **not** need a shell for
the PSU fix. If you want one to poke the PSU live with `i2cget`/`pmbus-test`, the script has
a commented-out block that changes the `sysadmin` login shell to `/bin/sh`; set your own
password on first login. That un-restricts an account you already own — review it before
enabling.

## Credits

* [Mrkvak/homelab](https://github.com/Mrkvak/homelab) — the original B650D4U reverse
  engineering this follows.
* [Gucioo/openbmc](https://github.com/Gucioo/openbmc) — the OpenBMC port of this board,
  where the PMBus behaviour and the ground-truth table came from.

## Status: web UI WORKS; IPMI/ipmitool path still gated (open)

Flashed and booted on hardware. The address patches are confirmed in the running
firmware, and the general IPMI/sensor stack works (motherboard fans and rails read). **But
the PSU still does not read:** `ipmitool sensor get "PSU1 VIN"` returns *"Unable to read
sensor: Device Not Present"*, and the web UI panel stays empty.

So on this board's **`2L2T-RPSU`** SKU there is a **presence-detection gate ahead of the
read** that the address patch does not satisfy -- the firmware concludes no PSU is present
and never issues the PMBus read. This differs from Mrkvak's B650D4U, where the address patch
alone was sufficient. The presence mechanism is not yet identified (candidates: a probe in
`compmanager`, an unpatched address reference -- there are 4 literal `mov r3,#0xB0` in
`libipmipar` left unpatched -- or a hardware PRESENT# signal from the redundant-PSU
backplane). Pinning it down needs a root shell on the running ASRock firmware (`i2cdetect`,
tracing `compmanager`), which needs a debug-shell image flashed with an SPI programmer.

If you just want the PSU working on this board today, the OpenBMC port
(<https://github.com/Gucioo/openbmc>) does it fully -- this stock-firmware route has hit a
harder layer.

### Live diagnosis on the running ASRock firmware (root shell)

With a debug root shell (sysadmin/superuser after flashing an image that swaps sysadmin's
login shell to /bin/sh -- see `make_debug_x570d4u.sh`), the following was established on the
running stock firmware:

* **The PSU is fully reachable and readable at bus 2 / 0x3c.** `i2c-test -b 2 --scan` finds
  `0x78` (7-bit 0x3c, PMBus) and `0x70` (0x38, FRU). `pmbus-test -b 2 -s 0x3c -r -c READ_VIN`
  and friends return correct standard values (VIN 241 V, VOUT 12.2 V, temp, fan, PIN, and
  `STATUS_WORD` 0x0000). `CAPABILITY` = 0x90 (PEC supported), `PMBUS_REVISION` = 0x22.
* **Both address patches are confirmed live** in the running libraries (`libpsuaccess`
  byte 0x2048 = 0x3c; `libipmipar` 8x patched `mvn`).
* **Yet every PSU sensor reports "Device Not Present"** (`ipmitool sensor get "PSU1 VIN"`).
  Because *all* PSU sensors are gated, not just VOUT, this is a **global PSU-presence
  determination that fails**, upstream of the reads -- not a per-register problem.
* Anomaly: `VOUT_MODE` (0x20) consistently **fails PEC** (`Bad PEC 0x00 vs 0xff`) while every
  other register passes PEC. Noted as a lead, but since it would only affect VOUT scaling it
  is probably not the global presence gate.
* No kernel i2c/pmbus errors (reads are pure userspace via libi2c, not the kernel pmbus
  driver); no obvious PSU "present" flag in redis.

**Open question / next step:** the presence gate lives in `IPMIMain` + `libipmipar`
(`dev_asrr_psu_*`) or `compmanager`, and locating exactly what it probes to decide "present"
(a register the Supermicro NAKs, e.g. MFR_ID; a PEC-checked read; or a hardware PRESENT#
GPIO) requires disassembling those binaries (Ghidra). That is where this stands. The
`make_debug_x570d4u.sh` image gives the root shell needed to keep iterating.

### UPDATE: the web UI PSU page works

After flashing, the stock ASRock web UI **System Information -> Power Source** shows the PSU
correctly -- the `libpsuaccess` patch does its job:

```
Power Supply Status  Power Supply OK
AC Input Voltage     240.5 V     DC 12V Output Voltage  12.19 V
AC Input Current     0.23 A      DC 12V Output Current  1.59 A
AC Input Power       46 W        DC 12V Output Power    19 W
Temperature 1        41 C        Temperature 2          49 C
Fan 1                224 RPM     DC 12V Max Output Power 480 W
ID / Model / Revision / Serial   N/A
```

All live values correct (match the PMBus ground truth); ID/Model/Serial N/A because the PSU
does not answer `MFR_*`, as expected -- the same result Mrkvak got on the B650D4U. **This is
the primary goal, reached.**

Still open is only the **IPMI / `ipmitool sensor` path** (`libipmipar`, separate from
`libpsuaccess`): PSU value sensors read "Device Not Present". Confirmed live that the PSU is
readable at bus 2 / 0x3c, so it is a presence/init gate in `libipmipar`'s `dev_asrr_psu_*`
path. Read params are compiled into `libipmipar` (not in the editable `IPMI.conf`, which
only holds IPMB/SMBUS buses), so finishing it needs a Ghidra pass on `libipmipar` to find
what the PSU init probes for presence (candidate: the `VOUT_MODE` read, which fails PEC on
this PSU) and make it tolerate the failure. The web UI does not depend on that path.

### Deep dive: why the IPMI path fails (disassembled), and where it stands

The PSU sensors are not merely "unreadable" -- in the web UI **Sensor Reading** page they sit
under **Disabled Sensors**, in the same bucket as empty fan headers (FAN1/FAN2) and
unpopulated DIMM slots (DDR4_A2/B2). So the firmware's PSU **presence detection decided the
PSU is absent at boot and disabled its sensors**, a persistent state -- not a live read
failure.

Disassembled `libipmipar` with the OpenBMC ARM cross-objdump to trace it:

* `dev_asrr_psu_v0dot1_presence1_read` (@0xf094) writes `STATUS_WORD` (0x79) to the PSU at
  the (patched) address 0x78/0x3c on bus 2, reads 2 bytes, and sets present=1 iff the
  transaction returns success (`*(struct+0)==0`).
* `dev_asrr_psu_vin_v0dot1_vin1_read` (@0xf1cc) reads `READ_VIN` (0x88) at 0x3c and does a
  correct LINEAR11 decode.
* Both funnel through `dev_ast2500_i2c_2_rwi2c` -> libi2c `i2c_writeread`; the web UI's
  `libpsuaccess` uses `i2c_writeread_on_bus`, and the two are the same transaction (same
  worker), differing only in how the device path is obtained -- **no PEC difference**.
* Confirmed on the running board that the patched address (`87 30 e0 e3` -> 0x78) is live at
  both `presence1_read` and `vin1_read`, and that `STATUS_WORD` and `READ_VIN` both read
  correctly via `pmbus-test` at bus 2 / 0x3c.

So the read code is correct and the PSU is readable -- yet boot-time presence detection still
disabled the sensors. Leading theory: the detection runs early in boot, before the PSU's
PMBus is responsive (or a subtle difference in that one transaction), fails, and the sensors
are latched disabled with no retry. Forcing a re-detection by restarting the IPMI stack
(`/etc/init.d/ipmistack restart`) **segfaults** and corrupts the shared i2c semaphore
(recovered by a reboot), so a clean re-detect from userspace is not available.

**Status: the web UI works; the IPMI/ipmitool path remains blocked at this boot-time
presence-disable, and cracking it further needs either the ability to re-run detection
cleanly or deeper tracing of the boot detection (a genuinely deep RE task).** The debug
shell (sysadmin/superuser) is in place for anyone continuing it.

### BREAKTHROUGH via kernel ftrace: the runtime uses the OLD address

The AMI kernel has i2c tracepoints. Enabling them (`echo 1 >
/sys/kernel/debug/tracing/events/i2c/enable`) and watching while IPMIMain polls shows the
decisive fact:

```
SensorMonitorTa-327 i2c_write: i2c-2 a=058 f=0200 l=1 [88]   <- READ_VIN at address 0x58
SensorMonitorTa-327 i2c_read:  i2c-2 a=058 l=2
```

**IPMIMain reads the PSU at 7-bit `0x58` (= 8-bit 0xB0, the ORIGINAL ASRock address), not
`0x3c`** -- even though every address immediate in the running `libipmipar` is confirmed
patched to 0x3c (`presence1_read`, `vin1_read`, and all 4 literal `mov #0xB0` sites read back
as 0x78 on the live board). Nothing is at 0x58 on this bus, so every PSU read NAKs and the
sensors report "reading unavailable" (scanning is enabled; the read simply fails).

So the sensor-monitor's PSU address does **not** come from the code we patched. It comes from
a source that still holds 0xB0 -- most likely a **sensor table built at the original first
boot and persisted in `/conf`, which survived the reflash** (this port deliberately preserves
`/conf`). It is not a plain byte in `SDR.dat`/`IPMI.conf` (the visible 0x58/0xB2 there are a
string's 'X' and a pointer low-byte), so it is encoded, or built at init from a source not
yet found.

This is why the straight lib-patch that worked on Mrkvak's B650D4U is **necessary but not
sufficient** here: the web UI path (`libpsuaccess`, no persisted table) works, but the IPMI
sensor path reads a stale 0xB0.

**Open next steps** (need a root shell, which is in place): (a) dynamically trace IPMIMain's
`ioctl(I2C_SLAVE)`/read to catch the exact call site and its address source (LD_PRELOAD shim
cross-compiled with the OpenBMC ARM toolchain, injected via `/etc/ld.so.preload` + reboot to
avoid the live-restart segfault); or (b) force the sensor config to regenerate from the
patched code (clear the relevant `/conf` cache / factory-default the config) so the 0x3c
address is used; or (c) Ghidra-trace the SensorMonitor read path to the address source.

Diagnostic method that cracked this (reusable): `i2c-test -b N --scan`, `pmbus-test -b N -s
ADDR -r -c CMD`, and kernel `events/i2c` ftrace to see who reads what where.
