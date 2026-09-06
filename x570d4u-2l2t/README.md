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

## Status: partially working -- presence detection blocks it (open)

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
