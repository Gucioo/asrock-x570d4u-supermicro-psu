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

## Firmware versions — read first

This work was reverse-engineered on one dump and then checked against ASRock's current
release. **Two version numbers matter and they are not the same thing:**

| | Our dump | Current ASRock download |
|---|---|---|
| Package / zip name | — | `X570D4U-2L2T(03.09.00)BMC.zip` |
| Internal `FW_VERSION` (web-UI "BMC Firmware Version") | **1.35.00** | **3.09.00** |
| Build date | Jul 12 2022 | Apr 24 2026 |
| MegaRAC core (`FW_CODEBASEVERSION`) | `5.X` | `5.X` |

ASRock **renumbered** the BMC line: older builds were `1.xx.00` (our dump, `1.35.00`),
current builds are `3.xx.00` (`3.09.00`). For the current release the zip name and the GUI
version match (`3.09.00`); the confusion is only if your board still runs an old `1.xx.00`
build while the site now offers `3.09.00`. (The `5.X` you also see is the MegaRAC SPX *core*,
not the package version.) Both are downloadable from ASRock — `X570D4U-2L2T(01.35.00)BMC.zip`
and `X570D4U-2L2T(03.09.00)BMC.zip` — and in each the zip name equals the internal
`FW_VERSION`, so what you download is what the GUI will show.

**Good news — the PSU patches are portable across both versions.** The key library is
identical:

- `usr/local/lib/libpsuaccess.so.1.0.0` — **byte-for-byte identical** in 1.35.00 and 3.09.00
  (md5 `f2f0697d…`). So the sensor-address patch **and the Option-E FRU model/serial
  injection** apply unchanged to either.
- wolfpass `libipmipar.so.6.31.0` — the file differs between versions, but both contain the
  same **9× `mvn r3,#0x4f` + 4× `mov r3,#0xB0`**, and the patch is pattern-based, so it works
  on both.

**Only the flash *packaging* differs.** The rootfs squashfs is at `0x4C0000` in both, but the
next module (the signed FIT kernel, "osimage") moved:

| | 1.35.00 | 3.09.00 |
|---|---|---|
| squashfs start | `0x4C0000` | `0x4C0000` |
| osimage (do-not-touch) | `0x17E0000` | `0x17C0000` |

So the build scripts here use `SQ_END=0x17E0000` for **1.35.00**. For **3.09.00**, set
`SQ_END=0x17C0000` (and confirm the mtd3 "root" size on your board). Everything else is the
same.

**Before you patch, regardless of version:** **dump _your own_ SPI flash** and work from
that. Confirm `libpsuaccess` md5 = `f2f0697d9e5fd1ae3498b81382b5a032` (proves the offsets
`0x2048` / injected routine at `0x1d80` / hook at `0x12a4` line up), confirm the wolfpass
pattern counts, and confirm your osimage offset before flashing.

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

## What works

* **Web UI PSU panel** and **`ipmitool sensor`**: voltage, current, power, temperature, fan.
* **Model / ID / Revision / Serial** — now populated too, live from the PSU's FRU EEPROM.
  See **Option E** below. (Mrkvak stopped short of this — "read it off the label".)

## Option E — PSU model / serial from the FRU EEPROM (SOLVED, confirmed on hardware)

The identity strings come from the PMBus `MFR_*` commands (`0x99` ID, `0x9a` MODEL, `0x9b`
REVISION, `0x9e` SERIAL) — and this Supermicro PSU **does not implement them** (all four NAK,
returning `0xff`; verified with a proper block read, first byte = count = `0xff`). Those
commands are *optional* in PMBus, and the supply reports `PMBUS_REVISION 0x98 = 0x22` (PMBus
1.2) while simply omitting them. So there is nothing to fix on the PMBus side.

Instead, the real identity lives in a **standard IPMI FRU EEPROM at i2c bus 2 / 7-bit `0x38`**
(the bus scan shows two devices: `0x78`=PMBus `0x3c`, `0x70`=FRU `0x38`). Reading it directly:

```
i2c-test -b 2 -s 0x38 -rc 32 -m 1 -d 0x00   ->  01 01 00 00 03 0b 00 f0 ... ca 'SUPERMICRO' cb 'PWS-441P-1H' ...
```

decodes as a textbook FRU Product Info area: Manufacturer `SUPERMICRO`, Product `PWS-441P-1H`,
Version `1.1`, Serial `P441PAG05HN0815`. **The stock firmware never reads it** (no FRU Device
Locator SDR for the PSU; a 70 s i2c trace shows zero reads to `0x38`).

`libpsuaccess` can't be fixed with a byte swap here: `CollectPsuInfo`/`RetrievePsuInfo` read a
fixed 1–2 bytes per `MFR_*` command via a jump table — no block read, no loop — so repointing
the command bytes would only ever fetch one character. The fix is a small **code injection**:

* A 292-byte ARM routine (`fru/fru_fill.c`) is placed in `libpsuaccess.so`'s spare exec-segment
  padding at VMA `0x1d80` (the executable `LOAD` is grown `0x1d80`→`0x1ee0` to cover it). It
  reads the `0x38` FRU EEPROM, walks the Product Info type/length fields, and writes the four
  strings into `CollectPsuInfo`'s 64-byte MFR fields.
* `CollectPsuInfo`'s MFR loop at `0x12a4` is replaced with `mov r0,r6 / bl 0x1d80 /
  add r5,r5,r0 / b 0x131c`, so it rides the existing "compliant PSU answered" path and the
  Redfish/web backend renders the fields normally.

Result in the web UI **System Information → Power Source**:

```
ID  SUPERMICRO   Model  PWS-441P-1H   Revision  1.1   Serial Number  P441PAG05HN0815
```

It reads the EEPROM live every poll, so a different Supermicro PSU shows its own strings. Safe
failure mode: if the FRU read ever fails, the fields stay blank (no crash).

### Bonus: reading the FRU without any patch

ASRock's IPMI stack implements **Master Write-Read** (`ASRRMasterWriteRead`), so a remote host
can read the same EEPROM with no firmware change once LAN IPMI auth is set up:

```
ipmitool -I lanplus -H <bmc> -U <user> -P <pw> raw 0x06 0x52 <bus> 0x70 0x40 0x00
```

(sweep `<bus>` to find the one mapping to i2c-2). Useful for Zabbix; it does **not** populate
the web-UI panel (that needs Option E).

## PSU fan control (optional)

By default the Supermicro PSU runs its fan on its **own** internal thermal curve — the BMC
only reads the speed (`FAN_COMMAND_1` = 0). At idle it sits around ~220 RPM. But the fan is
in duty-cycle mode and **responds to PMBus `FAN_COMMAND_1` (0x3b)**, so you can drive it:
writing 30% duty ramps Fan 1 to ~2600 RPM, and the PSU sets `STATUS_FANS` bit "Fan 1 Speed
Overridden" while you hold it. (This PSU is single-fan — `FAN_CONFIG_1_2 = 0x80` — so the
web UI's "Fan 2 = 0" is normal, not a fault.)

[`psu-fanctl.sh`](psu-fanctl.sh) is a tiny busybox-shell daemon that turns that into a
temperature curve driven by the PSU's own sensors (`READ_TEMPERATURE_1/2`), with a floor:

```
temp <= 50 C          -> 30 %   (floor: guaranteed airflow)
50 C < temp < 70 C    -> linear 30..100 %
temp >= 70 C          -> 100 %
```

The knobs (`FLOOR`, `TMIN`, `TMAX`, `INTERVAL`) are variables at the top of the script. It
reads `max(T1, T2)`, ignores bad/absent-PSU reads, and self-regulates (more airflow cools the
PSU, so the duty drops back to the floor). Verified on hardware: at 52 C it commanded 37%
(~3600 RPM), which cooled the PSU to 50 C and settled at the 30% floor (~2750 RPM).

**Install** (the daemon lives in `/conf`, which is jffs2 and persists — it does *not* fit in
the mtd3-full rootfs squashfs):

```
# copy it onto the BMC's /conf (via the root shell), then:
chmod 755 /conf/psu-fanctl.sh
( trap "" HUP; /conf/psu-fanctl.sh >/dev/null 2>&1 </dev/null & )   # start now
```

For **boot-persistence**, `make_fru_x570d4u.sh` adds a one-line launcher to the boot hook
(`[ -x /conf/psu-fanctl.sh ] && ( trap "" HUP; /conf/psu-fanctl.sh & )`), so once
`/conf/psu-fanctl.sh` is present the daemon **auto-starts on every reboot**. To stop it: kill
the process and write `FAN_COMMAND_1 = 0x0000` (`i2c-test -b 2 -s 0x3c -w -d 0x3b 0x00 0x00`)
to hand the fan back to the PSU's autonomous control.

> **Important — a full SPI flash wipes `/conf`.** The `/conf` jffs2 partition survives
> *reboots* but **not** a whole-chip programmer flash: the image you flash carries the
> original dump's `/conf`, so it overwrites `psu-fanctl.sh` (and any `/conf/timeouts` change).
> After each reflash, re-install the daemon (and re-apply the session timeout if you set one):
> ```
> cat > /conf/psu-fanctl.sh   # paste the script, then Ctrl-D
> chmod 755 /conf/psu-fanctl.sh
> sed -i 's/:10:0:0:0/:1440:0:0:0/' /conf/timeouts   # optional: 24h web timeout
> ```
> The boot hook then auto-starts it from that point on. (The root shell itself is re-applied
> every boot by the hook, so SSH access survives the `/conf` reset.)

## Building and flashing

Each script carves the rootfs squashfs, applies the patches, rebuilds it (checking it still
fits its partition), and splices it back into a copy of the flash with everything else —
including the signed kernel — byte-identical. Run as root so squashfs ownership survives, then
flash the output **raw** (SPI programmer or `/dev/mtd`), never through ASRock's update tool.

Pick the script for your situation:

| Script | BMC version | Sensors | Model/serial (Option E) | Debug shell |
|---|---|---|---|---|
| [`make_patched_x570d4u.sh`](make_patched_x570d4u.sh) | 1.35.00 | ✅ | — | — |
| [`make_fru_x570d4u.sh`](make_fru_x570d4u.sh) | 1.35.00 | ✅ | ✅ | ✅ (needs `DEBUG_PW`) |
| [`make_fru_x570d4u_309.sh`](make_fru_x570d4u_309.sh) | **3.09.00** (current download) | ✅ | ✅ | ✗ (mtd3 full) |

```
# 1.35.00, full build (sensors + FRU model/serial + a root shell for diagnosis):
sudo DEBUG_PW='choose-one' ./make_fru_x570d4u.sh original-dump.bin x570d4u-fru.bin

# 3.09.00 (the version you download from ASRock today; input can be the .ima or a dump):
sudo ./make_fru_x570d4u_309.sh 'X570D4U-2L2T_3.09.00.ima' x570d4u-309-fru.bin
```

The injected FRU routine is `fru/fru_fill.c` (compiled to `fru/fru_fill.bin`, embedded in the
scripts); `fru/patch_libpsuaccess.py` is the standalone library patcher. Both `make_fru`
scripts verify `libpsuaccess` md5 = `f2f0697d9e5fd1ae3498b81382b5a032` before patching, so
they refuse to run against a lib whose offsets they don't know.

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

## Status: SOLVED -- web UI AND IPMI/ipmitool both read the PSU

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

### SOLVED (root cause): IPMIMain loads the WOLFPASS libipmipar, not this SKU's

The final piece, from IPMIMain's memory map (`/proc/<pid>/maps`):

```
/usr/local/lib/ipmi/wolfpass/libipmipar.so.6.31.0
```

**IPMIMain loads the `wolfpass` variant of `libipmipar`, not
`1U4LW-X570/2L2T-RPSU/libipmipar.so` -- so all along we patched the wrong file.** The web UI
worked because `libpsuaccess` (a single shared file) was patched; the IPMI sensor path uses
this wolfpass lib, which still held the original `0xB0` at all 13 sites (9 `mvn #0x4f`, 4
`mov #0xB0`) and so read the PSU at `0x58` -- exactly what the ftrace showed.

**Fix: patch every `libipmipar.so` variant, not just this board's.** The build scripts here
now loop over `usr/local/lib/ipmi/*/libipmipar.so.*` and apply `mvn #0x4f -> #0x87` and
`mov #0xB0 -> #0x78` to each. wolfpass has 9+4 sites; other SKUs vary (0-11 `mvn`, 4 `mov`).

Live-test the fix without reflashing (needs the debug root shell): copy a patched wolfpass
lib to `/tmp`, `mount --bind` it over the original, `killall -9 IPMIMain` and relaunch
`/usr/local/bin/IPMIMain --daemonize --reg-with-procmgr`, then
`ipmitool sensor get "PSU1 VIN"`. Permanent fix: rebuild the image with the updated scripts
(which patch all variants) and reflash.

Why wolfpass? ASRock's firmware ships many SKU trees (wolfpass is an Intel Purley base) and
IPMIMain resolves to it at runtime on this board; the Supermicro PSU sits at the same nominal
`0xB0` Purley PSUs use, so only the address is wrong -- same one-line conceptual fix, just in
the file that is actually loaded.

### CONFIRMED WORKING on hardware

After bind-mounting the patched **wolfpass** `libipmipar` and restarting IPMIMain, the IPMI
sensors read correctly over the network (`ipmitool -I lanplus ... sensor`):

```
PSU1 VIN   238 V     PSU1 PIN   47 W
PSU1 IOUT  1.5 A     PSU1 POUT  19 W
PSU1 Temp  41 C      PSU1 Fan   200 RPM     (all state "ok")
```

matching the PMBus ground truth. On restart the console prints `PSU MFR err: PSUNum=0,
cmd=99/9a/9b/9e` -- IPMIMain now reaches the PSU and only the `MFR_*` identity commands fail
(the Supermicro does not answer them), which is why Model/Serial stay N/A. Both the web UI
and IPMI/ipmitool paths now work -- the full result, same as Mrkvak's B650D4U.

**Make it permanent:** the bind-mount is a live test (lost on reboot). Rebuild the image with
the updated `make_patched_x570d4u.sh` / `make_debug_x570d4u.sh` here (they patch every
`libipmipar.so` variant, wolfpass included) and reflash. Then both paths work from a clean
boot with no runtime surgery.
