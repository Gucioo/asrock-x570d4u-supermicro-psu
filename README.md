# homelab
Hi everyone,
this repository should contain most public stuff from my homleab projects. For now, it will be mostly about ASRock B650D4U in SuperMicro SC813 1U chassis. What can you look forward to? 3D models and some reverse engineering.

## Related boards

* **ASRock Rack X570D4U-2L2T** with a Supermicro PMBus PSU: same idea, different
  board -- see [`x570d4u-2l2t/`](x570d4u-2l2t/). On that board only the PSU I2C
  address is wrong (the bus is already correct), so it is a smaller patch.

## 3D models
In the "3d" directory, you'll find .stl and .FCStd (FreeCAD) files for IO shield SC813 and B650D4U.

## Reverse engineering
After I connected everything up, I've noticed PSU is not detected in either BMC web interface or `ipmitool sensors` command output. To me, it wasn't really understandable -  PMbus should be standardized, so what's the problem?
So I've downloaded the latest BMC firmware from ASRock website and decided to update it - _maybe they fixed it in the last release_ I've thought. Well, my browser crashed after I selected firmware file, and the BMC controller become unresponsive since then. After an hour of googling, I managed to find socflash binary (even for Linux) that manages to flash the BMC firmware from the host via VGA MMIO registers. Yeah, that means CVE-2019-6260 is still not fixed - root access to the machine means full and unlimited access to the BMC controller, but it really helped me here.

### Hunting for backdoors
Since the PMbus wasn't working with latest version either, I decided to look at the firmware more closely. At this point I wasn't still sure whether I can work with the image and read/flash it, soI went looking for (obvious) backdoors on network. Full port scan revealed opened VNC, SNMP, HTTPS and SSH. I tried logging over ssh with my credentials (default is`admin`:`admin`), however it dropped into restricted SMASH interface, with no easy way to gain system shell). So I gave up on the network, and decided to focus on the firmware image file.
I got the original `B650D4U_6.09.00.ima` extracted with binwalk with no problems. I got two DTBs (suggesting there's kernel one and u-boot one), two identical jffs2 filesystems (used for certain config files with failover) and two squashfs images (one for web interface, one for rootfs).

At first I decided to check rootfs and JFFS2 (mounted at `/conf/` and `/bkupconf/`). First thing I've noticed was hardcoded password for `root`  user (that's called `sysadmin`) in `/etc/passwd`. At this time I found CVE-2022-40242, which mentioned `sysadmin` account but no specific password. So I used John the Ripper and probable wordlist and in few minutes cracked the password `superuser`. However, attempting to login as `sysadmin`/`superuser` over SSH lead to just `No Access Privilege  ! Exiting...!` error message.

I decided to disassemble the `defshell` binary. It turns out it can spawn `/bin/ash` (along with executing some init scripts) if it's executed with `MFG_MODE` as its first argument, however as `sshd` adds `-c` as first argument if you specify the command, there's no easy way to trigger it from the outside.
At this moment, I decided to try to modify the source image, I replaced `sysadmin` account shell`/usr/local/sbin/defshell` with `/bin/ash`:

```
modprobe mtdram total_size=2048 erase_size=128
modprobe mtdblock
dd if=B650D4U/B650D4U_6.09.00.ima of=/dev/mtdblock0 bs=512 skip=2176 count=3841
mount -t jffs2 /dev/mtdblock0 /mnt/image
vim /mnt/image/passwd
dd if=/dev/mtdblock0 of=B650D4U/B650D4U_6.09.00-patched.ima bs=1 seek=3211264 count=1966092 conv=notrunc
```
I tried flashing it with the `socflash` utility, which didn't fail, then I went for `ssh sysadmin@BMC_IP` and I got dropped into shell! Clearly it doesn't verify the authenticity of the code. It's great to see CVE-2019-6260 is not fixed even in 2025.

### Exploring live system
So, I decided to troubleshoot the PMbus issues from the live system. First thing I've noticed was that `pmbus` was not included in kernel at all:
```
zcat /proc/config.gz | grep PMBUS
# CONFIG_PMBUS is not set
```

After a couple of random `grep`s (PSU, supply, power...), I ran into `/info/B650D4U.PRJ` with some interesting stuff:
```
CONFIG_SPX_FEATURE_ASRR_PSU_INFO_I2C_BUS=12
CONFIG_SPX_FEATURE_ASRR_PSU_INFO_SLAVE_ADDR1=0xB0
CONFIG_SPX_FEATURE_ASRR_PSU_INFO_SLAVE_ADDR2=0xB2
CONFIG_SPX_FEATURE_ASRR_PSU_INFO_SLAVE_ADDR3=0xB4
CONFIG_SPX_FEATURE_ASRR_PSU_INFO_SLAVE_ADDR4=0xB6
```
Now we can safely assume it assumes PMbus is on I2C bus #12 and it assumes PSU has one of these four addresses. Now here's a catch - I2C works with 7bit addresses, not 8bit, and 0xB0 has 8th bit set to 1. So the addresses will more likely be  0x58, 0x59, 0x5a and 0x5b). Well, fortunately, there are `i2c-tools` in the image already present, and `i2cdetect -y 12` actually finds something:
```
~ # i2cdetect -y 12
     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f
00:          -- -- -- -- -- -- -- -- -- -- -- -- --
10: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
20: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
30: -- -- -- -- -- -- -- -- 38 -- -- -- 3c -- -- --
40: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
50: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
60: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
70: -- -- -- -- -- -- -- --
```
I've even found reddit post (https://www.reddit.com/r/ASRock/comments/qq6s8n/pmbus_and_supermicro_pdb/) mentioning the same addresses.  But changing these values in the .PRJ file doesn't make it work, though. The only obvious cause is this is just some C `#define` directives (or like) and they got baked in the code.

Few more finds and greps and I noticed there's a `pmbus` library and binary present on the system:
```
$ ~/B650D4U/extractions/B650D4U_6.09.00.ima.extracted $ find . |grep pmbus
./510000/squashfs-root/usr/local/lib/libpmbus.so
./510000/squashfs-root/usr/local/lib/libpmbus.so.13.0.0
./510000/squashfs-root/usr/local/lib/libpmbus.so.13
./510000/squashfs-root/usr/local/lib/libpmbus.so.13.0
./510000/squashfs-root/usr/local/bin/pmbus-test
```
But it doesn't appear to be used at all.
At this point, I was getting desperate and was looking for anything seemingly related, then I got lucky:
```
$ ~/B650D4U/extractions/B650D4U_6.09.00.ima.extracted $ find . |grep -i psu
./510000/squashfs-root/usr/local/lib/libpsuaccess.so.1.0
./510000/squashfs-root/usr/local/lib/libpsuaccess.so.1
./510000/squashfs-root/usr/local/lib/libpsufw.so.1.1
./510000/squashfs-root/usr/local/lib/libpsufw.so.1
./510000/squashfs-root/usr/local/lib/libpsuaccess.so
./510000/squashfs-root/usr/local/lib/libpsufw.so
./510000/squashfs-root/usr/local/lib/libpsuaccess.so.1.0.0
./510000/squashfs-root/usr/local/lib/libpsufw.so.1.1.0
./510000/squashfs-root/usr/local/lib/compmanager/libpsufw.so.1.1.0
./510000/squashfs-root/usr/local/sync-agent/extensions/ami/sync-helpers_ami/psu_update.lua
```

After disassembling, I saw suspicious symbol `psuaccessAddr` in `libpsuaccess.so` with hardcoded bytes 0x58 0x59, 0x5a, 0x5b, which are our addresses from .PRJ files bitshifted to right by one byte!
So I decided to test it by regenerating squashfs image, replacing it in the .ima file and reflashing the firmware.
And behold - I got real PSU data in web interface:
![IPMI - PSU screenshot](/doc/ipmi-screenshot.png)
Yes, ID, Model, Revision and Serial Number do not work, but who cares? I can read that on the label.

However, `ipmitool sensor` command on the host still haven't returned anything usable. After spending some time looking into redis and decompiled backend Lua scripts I went through all running processes on the system, its dependencies, and I ended up at `libipmipar.so` loaded by `IPMIMain` binary, which had functions `dev_asrr_ast2600_v03_i2c_12_*` (with the suspicious *12*). These places were found in functions like `dev_asrrpsuvinv02_vin1_read` which set one of the fields in the passed parameter to `0xb0`, and function `dev_asrrpsuvinv02_vin2_read` that set the parameter to `0xb2`. Coincidence? I don't think so.
Let's patch it then.. But for some reason I couldn't find 0xb0 anywhere in the code. It turns out the instruction that "generated" that 0xb0 value was was `mvn r3,#0x4f"` (opcode `4f 30 e0 e3`) - probably because of compiler optimization rather than deliberate obfuscation. Ghidra was huge help here. After I checked all occurrences of the opcode for false positives and replacing them with `87 30 e0 e3` (NOT of 0x3c shifted to left by one bit), and flashing the modified firmware I finally got PSU values both in the web UI and `ipmitool` output. And with the attached zabbix template (`zabbix-ipmi.yaml` and `zabbix-ipmi.conf`) I can now get those values in Zabbix as well. *** FIXME - add triggers ***
![Zabbix - PSU screenshot](/doc/zabbix-screenshot.png)


## AI benchmark on socflash reimplementation
(This is related to state of LLM tools as of early December 2025). I've decided to ask most popular AI coding models (codex with GPT5.1, Claude Opus 4.5 and Gemini 3 pro) to reimplement socflash based on binary, disassembled binary and ghidra decompiled code. Results:
* Claude burned through allocated 20EUR, producing not working code (it falsely detected SPI chip as 16MB and reading failed), but generated nice, well structured C project with `Makefile`
* Gemini got farthest costing approximately the same, and after a few nudges managed to produce code that succeeded in reading the SPI flash, but after several tries didn't manage to write to the flash. It produced nicely organized C++ project with its own `Makefile`
* Codex tossed everything into one C file, repeatedly refused to do the work (kept saying "reimplementing whole thing is too much, so I did just function x").


