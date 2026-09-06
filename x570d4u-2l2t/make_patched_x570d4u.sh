#!/bin/bash
# ---------------------------------------------------------------------------
# make_patched_x570d4u.sh
#
# Patch the ASRock Rack X570D4U-2L2T stock (AMI MegaRAC) BMC firmware so it
# reads a Supermicro PMBus power supply that answers at I2C 7-bit 0x3c, instead
# of the ASRock default 0x58 (8-bit 0xB0).
#
# Same principle as Mrkvak's B650D4U work (github.com/Mrkvak/homelab), adapted
# for the X570D4U-2L2T. Only the PSU I2C ADDRESS is wrong on this board -- the
# firmware already probes I2C bus 2, which is where the PSU lives, and it reads
# standard PMBus registers. The supply speaks textbook PMBus LINEAR11/16 (see
# the ground-truth table in the README), so no register remap or rescale is
# needed; the address is the only fix.
#
# What it patches (both are byte swaps, no size change):
#   1. libpsuaccess.so.1.0.0            @ file offset 0x2048:  0x58 -> 0x3c
#      (drives the PSU panel in the BMC web UI)
#   2. .../1U4LW-X570/2L2T-RPSU/libipmipar.so.1.0.0
#      mvn r3,#0x4f (4f 30 e0 e3) -> mvn r3,#0x87 (87 30 e0 e3), x8
#      (0xB0 -> 0x78 = 7-bit 0x3c; drives `ipmitool sensor`)
#
# It rebuilds ONLY the rootfs squashfs and rewrites just its flash region.
# The signed FIT kernel (osimage) and everything else stay byte-identical, so
# u-boot's signature check is untouched.
#
# Run as root (mksquashfs/unsquashfs must preserve ownership and perms):
#   sudo ./make_patched_x570d4u.sh <original_dump.bin> <output_patched.bin>
#
# Recovery: keep the original dump and an SPI programmer. A bad flash is
# rewritten with the original -- nothing here is one-way.
# ---------------------------------------------------------------------------
set -euo pipefail

SRC="${1:?usage: $0 <original_dump.bin> <output.bin>}"
OUT="${2:?usage: $0 <original_dump.bin> <output.bin>}"

# Flash layout of this board's firmware (64 KiB-aligned AMI modules):
ROOT_HDR=0x004B0000     # "root" FMH module header
SQ_OFF=0x004C0000       # rootfs squashfs payload start
SQ_END=0x017E0000       # next module ("osimage", the signed FIT kernel)
FLASH_SZ=67108864       # 64 MiB (MX25L51245G)

sq_off=$((SQ_OFF)); sq_end=$((SQ_END)); slot=$((sq_end - sq_off))

command -v unsquashfs >/dev/null || { echo "need squashfs-tools"; exit 1; }
command -v mksquashfs  >/dev/null || { echo "need squashfs-tools"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root (ownership/perms must be preserved)"; exit 1; }
[ "$(stat -c%s "$SRC")" = "$FLASH_SZ" ] || { echo "source is not a 64 MiB dump"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo "[*] work dir: $WORK"

# --- read the squashfs superblock size, carve it, extract -------------------
python3 - "$SRC" "$sq_off" "$WORK/root.sqsh" <<'PY'
import sys,struct
src,off,out=sys.argv[1],int(sys.argv[2]),sys.argv[3]
d=open(src,"rb").read()
assert d[off:off+4]==b"hsqs", "no squashfs at 0x%x"%off
used=struct.unpack_from("<Q",d,off+40)[0]
open(out,"wb").write(d[off:off+used])
print("[*] squashfs bytes_used = %d"%used)
PY

rm -rf "$WORK/rootfs"
unsquashfs -q -d "$WORK/rootfs" "$WORK/root.sqsh" >/dev/null
echo "[*] extracted rootfs"

# --- apply the two address patches ------------------------------------------
python3 - "$WORK/rootfs" <<'PY'
import sys,os
root=sys.argv[1]
# 1) libpsuaccess.so
p=os.path.join(root,"usr/local/lib/libpsuaccess.so.1.0.0")
d=bytearray(open(p,"rb").read())
if d[0x2048]==0x58:
    d[0x2048]=0x3c; open(p,"wb").write(d); print("[+] libpsuaccess.so 0x2048 0x58 -> 0x3c")
elif d[0x2048]==0x3c:
    print("[=] libpsuaccess.so already 0x3c")
else:
    raise SystemExit("!! libpsuaccess 0x2048 unexpected: 0x%02x"%d[0x2048])
# 2) libipmipar.so for the 2L2T-RPSU variant
import glob
tot_n=tot_m=0
for q in glob.glob(os.path.join(root,"usr/local/lib/ipmi/**/libipmipar.so.*"),recursive=True):
    if os.path.islink(q): continue
    e=bytearray(open(q,"rb").read()); n=0;i=0
    while True:
        i=e.find(b"\x4f\x30\xe0\xe3",i)
        if i<0: break
        e[i:i+4]=b"\x87\x30\xe0\xe3"; n+=1; i+=4
    m=0;i=0
    while True:
        i=e.find(b"\xb0\x30\xa0\xe3",i)
        if i<0: break
        e[i:i+4]=b"\x78\x30\xa0\xe3"; m+=1; i+=4
    if n or m:
        open(q,"wb").write(e); tot_n+=n; tot_m+=m
        print("[+] "+os.path.basename(os.path.dirname(q))+"/libipmipar: mvn x%d mov x%d"%(n,m))
print("[+] libipmipar ALL variants: mvn#0x4f->#0x87 x%d, mov#0xB0->#0x78 x%d"%(tot_n,tot_m))
print("[+] libipmipar.so mvn#0x4f -> #0x87  x%d"%n)
if n==0 and e.count(b"\x87\x30\xe0\xe3")>=8: print("[=] libipmipar already patched")
PY

# --- OPTIONAL debug root shell (disabled by default) ------------------------
# The PSU fix does NOT need a shell. If a value comes out wrong and you want to
# poke the PSU live with i2cget/pmbus-test, uncomment this block to give the
# existing sysadmin (uid 0) account a real /bin/sh instead of the restricted
# defshell. Set your OWN password on first login. This edits the login shell
# of an account you already own; it does not add a new backdoor account.
#
#   sed -i 's#^sysadmin:x:0:0:sysadmin:/root:/usr/local/bin/defshell#sysadmin:x:0:0:sysadmin:/root:/bin/sh#' \
#       "$WORK/rootfs/etc/defconfig/passwd"
#   # /conf/passwd persists in jffs2 and may already exist; to force it, add a
#   # small rc3.d script yourself after reviewing it.

# --- repack, size-check, splice into a copy of the flash ---------------------
rm -f "$WORK/root_new.sqsh"
mksquashfs "$WORK/rootfs" "$WORK/root_new.sqsh" -comp xz -b 131072 \
    -noappend -no-progress -no-xattrs >/dev/null 2>&1
newsz=$(stat -c%s "$WORK/root_new.sqsh")
echo "[*] rebuilt squashfs = $newsz bytes (slot $slot)"
[ "$newsz" -le "$slot" ] || { echo "!! squashfs too big for slot"; exit 1; }

cp "$SRC" "$OUT"
python3 - "$OUT" "$WORK/root_new.sqsh" "$sq_off" "$sq_end" <<'PY'
import sys
out,new,off,end=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
img=bytearray(open(out,"rb").read())
sq=open(new,"rb").read()
# fill the whole slot with 0xFF (erased flash) then lay the squashfs at the start
img[off:end]=b"\xff"*(end-off)
img[off:off+len(sq)]=sq
open(out,"wb").write(img)
print("[+] spliced squashfs into 0x%x..0x%x, rest byte-identical"%(off,end))
PY

echo "[*] sha256:"; sha256sum "$OUT"
echo "[done] $OUT   (flash raw; keep the original dump + programmer for recovery)"
