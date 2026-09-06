#!/bin/bash
# ---------------------------------------------------------------------------
# make_fru_x570d4u_309.sh  --  same PSU mod as make_fru_x570d4u.sh, but for the
# CURRENT ASRock BMC release 3.09.00 (internal FW_VERSION=3.09.00, Apr 2026),
# the version you download today as X570D4U-2L2T(03.09.00)BMC.zip.
#
# Why a separate script: libpsuaccess.so is BYTE-IDENTICAL between 1.35.00 and
# 3.09.00 (md5 f2f0697d...), so all the libpsuaccess patches (PSU address +
# Option-E FRU model/serial injection) apply verbatim. Only the flash PACKAGING
# moved: the signed kernel ("osimage") is at 0x17C0000 in 3.09.00 (was 0x17E0000),
# and the mtd3 "root" partition is 0x12F2000. The rootfs nearly fills mtd3, so
# there is NO room for the debug shell here (use the 1.35.00 debug build for that).
#
# Input can be either ASRock's .ima (64 MiB + 264-byte footer) or a raw 64 MiB
# SPI dump; output is always a raw 64 MiB image to flash with an SPI programmer.
#
#   sudo ./make_fru_x570d4u_309.sh 'X570D4U-2L2T_3.09.00.ima' out.bin
#
# Recovery: the stock .ima / your own dump + programmer.
# ---------------------------------------------------------------------------
set -euo pipefail
SRC="${1:?usage: sudo $0 <3.09.00 .ima or dump> <out.bin>}"
OUT="${2:?usage: sudo $0 <3.09.00 .ima or dump> <out.bin>}"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
command -v mksquashfs >/dev/null || { echo "need squashfs-tools"; exit 1; }

FLASH=67108864                       # 64 MiB raw flash
SQ_OFF=$((0x4C0000)); SQ_END=$((0x17C0000)); MTD3=$((0x12F2000))   # 3.09.00 geometry
slot=$((SQ_END-SQ_OFF))
LIBMD5=f2f0697d9e5fd1ae3498b81382b5a032   # libpsuaccess.so.1.0.0 in 1.35.00 AND 3.09.00

sz=$(stat -c%s "$SRC")
[ "$sz" = "$FLASH" ] || [ "$sz" = 67109128 ] || { echo "source is neither a 64MiB dump nor the 3.09 .ima (got $sz)"; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
# take the first 64 MiB (drops the .ima's 264-byte footer if present)
head -c "$FLASH" "$SRC" > "$W/flash.bin"

python3 - "$W/flash.bin" "$SQ_OFF" "$W/r.sqsh" <<'PY'
import sys,struct
d=open(sys.argv[1],"rb").read(); off=int(sys.argv[2])
assert d[off:off+4]==b"hsqs", "no squashfs at 0x%x"%off
used=struct.unpack_from("<Q",d,off+40)[0]; open(sys.argv[3],"wb").write(d[off:off+used])
PY
unsquashfs -q -d "$W/rootfs" "$W/r.sqsh" >/dev/null
echo "[*] rootfs extracted"

# guard: the whole method relies on this exact libpsuaccess binary
got=$(md5sum "$W/rootfs/usr/local/lib/libpsuaccess.so.1.0.0" | awk '{print $1}')
[ "$got" = "$LIBMD5" ] || { echo "!! libpsuaccess md5 $got != expected $LIBMD5 -- ASRock changed the lib; offsets must be re-derived"; exit 1; }
echo "[+] libpsuaccess md5 verified ($LIBMD5)"

FRU_BLOB_B64='ADCg4/BALekQcKDjAWCg44zQTeIDQKDhGDCN5XYwgOI2IIDiFDCN5bYwgOL2AIDiKFCN4hAgjeUcMI3lIACN5QUwoOE4EKDjAgCg48AAjegPII3iD0DN5X76/+sAAFDjEECE4iEAALpgAFTjEFCF4vL//xooMN3lAQBT4xsAABosMN3lgzGg4QggQ+JIAFLjFgAAigMwg+IoII3iAyCC4BAAjeIkYI3iADDS5f8AU+PBAFMTCgAACgRAkOQ/MAPiAABU4wIAAAoBEEPiPQBR4wkAAJoBMIPiBgBQ4QMgguDw//8aBACg44zQjeLwgL3oAACg44zQjeLwgL3oAhCg4QHAROIDUILgAeDx5QUAUeEB4Ozl+///GgAQoOMDEMTn6///6g=='

# libpsuaccess: sensor addr + Option-E FRU injection (identical to the 1.35 build)
python3 - "$W/rootfs" "$FRU_BLOB_B64" <<'PY'
import sys,struct,os,base64
root=sys.argv[1]; blob=base64.b64decode(sys.argv[2])
p=os.path.join(root,"usr/local/lib/libpsuaccess.so.1.0.0"); d=bytearray(open(p,"rb").read())
CAVE=0x1d80; CE=0x1ee0
if   d[0x2048]==0x58: d[0x2048]=0x3c; print("[+] psuaccessAddr 0x58->0x3c")
elif d[0x2048]==0x3c: print("[=] already 0x3c")
ph=struct.unpack_from("<I",d,0x1c)[0]; es=struct.unpack_from("<H",d,0x2a)[0]; pn=struct.unpack_from("<H",d,0x2c)[0]
for i in range(pn):
    o=ph+i*es; t,off,va,pa,fs,ms,fl,al=struct.unpack_from("<8I",d,o)
    if t==1 and off==0 and fl&1:
        assert fs==0x1d80, "unexpected LOAD 0x%x"%fs
        struct.pack_into("<I",d,o+16,CE); struct.pack_into("<I",d,o+20,CE)
if all(b==0 for b in d[CAVE:CAVE+len(blob)]): d[CAVE:CAVE+len(blob)]=blob; print("[+] fru_fill blob @0x1d80")
def bl(f,t):return 0xeb000000|(((t-f-8)>>2)&0xffffff)
def br(f,t):return 0xea000000|(((t-f-8)>>2)&0xffffff)
h=0x12a4; o=struct.unpack_from("<I",d,h)[0]
if (o>>16)==0xe59f:
    for j,v in enumerate([0xe1a00006,bl(h+4,CAVE),0xe0855000,br(h+12,0x131c)]): struct.pack_into("<I",d,h+4*j,v)
    print("[+] hooked CollectPsuInfo @0x12a4")
open(p,"wb").write(d); print("[+] libpsuaccess Option-E patched")
PY

# wolfpass libipmipar (ipmitool sensor path)
python3 - "$W/rootfs" <<'PY'
import sys,os,glob
root=sys.argv[1]; tn=tm=0
for q in glob.glob(os.path.join(root,"usr/local/lib/ipmi/wolfpass*/libipmipar.so.*")):
    if os.path.islink(q): continue
    e=bytearray(open(q,"rb").read()); n=e.count(b"\x4f\x30\xe0\xe3"); m=e.count(b"\xb0\x30\xa0\xe3")
    e=e.replace(b"\x4f\x30\xe0\xe3",b"\x87\x30\xe0\xe3").replace(b"\xb0\x30\xa0\xe3",b"\x78\x30\xa0\xe3")
    if n or m: open(q,"wb").write(e); tn+=n; tm+=m
print("[+] wolfpass libipmipar: mvn x%d mov x%d"%(tn,tm))
PY

# optional debug shell -- only if DEBUG_PW set (WARNING: 3.09 mtd3 is nearly full)
if [ -n "${DEBUG_PW:-}" ]; then
  HASH="$(openssl passwd -6 "$DEBUG_PW")"
  cat > "$W/rootfs/etc/init.d/zdbgshell" <<EOF
#!/bin/sh
H='$HASH'
[ -f /conf/passwd ] || exit 0
grep -q '^sysadmin:x:0:0:sysadmin:/root:/bin/sh\$' /conf/passwd || {
  grep -v '^sysadmin:' /conf/passwd > /tmp/.p; echo 'sysadmin:x:0:0:sysadmin:/root:/bin/sh' >> /tmp/.p; cp /tmp/.p /conf/passwd; rm -f /tmp/.p; }
[ -f /conf/shadow ] && {
  grep -v '^sysadmin:' /conf/shadow > /tmp/.s; echo "sysadmin:\${H}:17823:0:99999:7:::" >> /tmp/.s; cp /tmp/.s /conf/shadow; rm -f /tmp/.s; }
exit 0
EOF
  chown 0:0 "$W/rootfs/etc/init.d/zdbgshell"; chmod 0755 "$W/rootfs/etc/init.d/zdbgshell"
  ln -sf ../init.d/zdbgshell "$W/rootfs/etc/rc3.d/S14zdbgshell"
  echo "[+] debug shell installed (may not fit -- see size check)"
fi

# repack, size check against 3.09 mtd3, splice, output 64 MiB raw
mksquashfs "$W/rootfs" "$W/rn.sqsh" -comp xz -b 131072 -noappend -no-progress -no-xattrs >/dev/null 2>&1
newsz=$(stat -c%s "$W/rn.sqsh")
if [ "$newsz" -gt "$MTD3" ]; then
  echo "!! squashfs $newsz > 3.09 mtd3 $MTD3 (over by $((newsz-MTD3)) B)."
  [ -n "${DEBUG_PW:-}" ] && echo "   The debug shell doesn't fit on 3.09 -- rerun WITHOUT DEBUG_PW."
  exit 1
fi
[ "$newsz" -le "$slot" ] || { echo "!! squashfs $newsz > slot $slot"; exit 1; }
echo "[*] new squashfs $newsz bytes (<= mtd3 $MTD3, margin $((MTD3-newsz)) B)"
cp "$W/flash.bin" "$OUT"
python3 - "$OUT" "$W/rn.sqsh" "$SQ_OFF" "$SQ_END" <<'PY'
import sys
img=bytearray(open(sys.argv[1],"rb").read()); sq=open(sys.argv[2],"rb").read()
off,end=int(sys.argv[3]),int(sys.argv[4])
img[off:end]=b"\xff"*(end-off); img[off:off+len(sq)]=sq
open(sys.argv[1],"wb").write(img)
PY
echo "[done] $OUT ($(stat -c%s "$OUT") bytes, raw 64 MiB)"; sha256sum "$OUT"
echo "Flash raw with the SPI programmer. PSU model/serial appear in the web UI."
