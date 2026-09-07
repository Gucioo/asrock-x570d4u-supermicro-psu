#!/bin/bash
# ---------------------------------------------------------------------------
# make_fru24_x570d4u.sh  --  ASRock Rack X570D4U-2L2T stock BMC firmware
#
# Same as make_fru_x570d4u.sh (web-UI + ipmitool PSU sensors, debug shell, and
# "Option E": PSU model/serial/revision in the web UI from the FRU EEPROM at
# i2c bus 2 / 0x38) but instead of the PSU fan hook it bakes in a 24h web
# session timeout. The boot hook re-applies it every boot, so it survives the
# /conf reset a full reflash causes (idempotent: only bumps the default 10 min).
# No PSU fan control here -- the supply self-regulates its own fan.
#
# Why a code patch: this Supermicro PSU does NOT implement the PMBus MFR
# string commands (0x99/0x9a/0x9b/0x9e all NAK), which is the only way ASRock's
# firmware asks for identity. But the PSU DOES publish a standard IPMI FRU
# EEPROM at 0x38 (SUPERMICRO / PWS-441P-1H / REV 1.1 / serial). This injects a
# small routine into libpsuaccess.so that reads that EEPROM and fills the four
# MFR fields of CollectPsuInfo's output struct, riding the existing "compliant
# PSU answered" path so the redfish/web backend renders it normally.
#
#   sudo DEBUG_PW='choose-your-own' ./make_fru_x570d4u.sh original-dump.bin out.bin
#
# Flash out.bin with your SPI programmer. Recovery: the original dump.
# ---------------------------------------------------------------------------
set -euo pipefail
SRC="${1:?usage: sudo DEBUG_PW=... $0 <dump.bin> <out.bin>}"
OUT="${2:?usage: sudo DEBUG_PW=... $0 <dump.bin> <out.bin>}"
: "${DEBUG_PW:?set DEBUG_PW to the root password you want (e.g. DEBUG_PW=secret123)}"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
command -v mksquashfs >/dev/null || { echo "need squashfs-tools"; exit 1; }
[ "$(stat -c%s "$SRC")" = 67108864 ] || { echo "source not a 64 MiB dump"; exit 1; }

HASH="$(openssl passwd -6 "$DEBUG_PW")"
SQ_OFF=$((0x4C0000)); SQ_END=$((0x17E0000)); slot=$((SQ_END-SQ_OFF))
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# --- carve + extract rootfs ---
python3 - "$SRC" "$SQ_OFF" "$W/r.sqsh" <<'PY'
import sys,struct
d=open(sys.argv[1],"rb").read(); off=int(sys.argv[2])
assert d[off:off+4]==b"hsqs"
used=struct.unpack_from("<Q",d,off+40)[0]
open(sys.argv[3],"wb").write(d[off:off+used])
PY
unsquashfs -q -d "$W/rootfs" "$W/r.sqsh" >/dev/null
echo "[*] rootfs extracted"

# guard: every offset below assumes this exact libpsuaccess (same in 1.35.00 and 3.09.00)
LIBMD5=f2f0697d9e5fd1ae3498b81382b5a032
got=$(md5sum "$W/rootfs/usr/local/lib/libpsuaccess.so.1.0.0" | awk '{print $1}')
[ "$got" = "$LIBMD5" ] || { echo "!! libpsuaccess md5 $got != $LIBMD5 -- different build; re-derive offsets"; exit 1; }
echo "[+] libpsuaccess md5 verified"

# --- the injected FRU routine (ARM, 292 bytes, entry at VMA 0x1d80) ---
FRU_BLOB_B64='ADCg4/BALekQcKDjAWCg44zQTeIDQKDhGDCN5XYwgOI2IIDiFDCN5bYwgOL2AIDiKFCN4hAgjeUcMI3lIACN5QUwoOE4EKDjAgCg48AAjegPII3iD0DN5X76/+sAAFDjEECE4iEAALpgAFTjEFCF4vL//xooMN3lAQBT4xsAABosMN3lgzGg4QggQ+JIAFLjFgAAigMwg+IoII3iAyCC4BAAjeIkYI3iADDS5f8AU+PBAFMTCgAACgRAkOQ/MAPiAABU4wIAAAoBEEPiPQBR4wkAAJoBMIPiBgBQ4QMgguDw//8aBACg44zQjeLwgL3oAACg44zQjeLwgL3oAhCg4QHAROIDUILgAeDx5QUAUeEB4Ozl+///GgAQoOMDEMTn6///6g=='

# --- patch libpsuaccess.so.1.0.0: sensor addr + Option-E FRU injection ---
python3 - "$W/rootfs" "$FRU_BLOB_B64" <<'PY'
import sys,struct,os,base64
root=sys.argv[1]; blob=base64.b64decode(sys.argv[2])
p=os.path.join(root,"usr/local/lib/libpsuaccess.so.1.0.0")
d=bytearray(open(p,"rb").read())
CAVE=0x1d80; CAVE_END=0x1ee0
assert len(blob)<=(CAVE_END-CAVE), "blob too big"
# 1) sensor-value address 0x58->0x3c (idempotent)
if   d[0x2048]==0x58: d[0x2048]=0x3c; print("[+] psuaccessAddr 0x58->0x3c")
elif d[0x2048]==0x3c: print("[=] psuaccessAddr already 0x3c")
else: raise SystemExit("!! 0x2048 unexpected 0x%02x"%d[0x2048])
# 2) grow the executable LOAD segment to cover the cave
e_phoff=struct.unpack_from("<I",d,0x1c)[0]; e_phentsize=struct.unpack_from("<H",d,0x2a)[0]
e_phnum=struct.unpack_from("<H",d,0x2c)[0]; grown=False
for i in range(e_phnum):
    o=e_phoff+i*e_phentsize
    t,off,va,pa,fsz,msz,fl,al=struct.unpack_from("<8I",d,o)
    if t==1 and off==0 and (fl&1):
        assert fsz==0x1d80 and msz==0x1d80, "unexpected LOAD1 0x%x/0x%x"%(fsz,msz)
        struct.pack_into("<I",d,o+16,CAVE_END); struct.pack_into("<I",d,o+20,CAVE_END)
        print("[+] grew exec LOAD 0x1d80 -> 0x%x"%CAVE_END); grown=True
assert grown, "exec LOAD not found"
# 3) place blob (only if cave still free, i.e. not already patched)
if all(b==0 for b in d[CAVE:CAVE+len(blob)]):
    d[CAVE:CAVE+len(blob)]=blob; print("[+] fru_fill blob %d bytes @ 0x%x"%(len(blob),CAVE))
else:
    print("[=] cave already populated")
# 4) hook CollectPsuInfo @0x12a4 -> call blob, fill fields, return
def bl(frm,to): return 0xeb000000|(((to-frm-8)>>2)&0xffffff)
def br(frm,to): return 0xea000000|(((to-frm-8)>>2)&0xffffff)
h=0x12a4; orig=struct.unpack_from("<I",d,h)[0]
if (orig>>16)==0xe59f:   # original: ldr r4,[pc,..] (MFR loop head)
    for j,v in enumerate([0xe1a00006, bl(h+4,CAVE), 0xe0855000, br(h+12,0x131c)]):
        struct.pack_into("<I",d,h+4*j,v)
    print("[+] hooked CollectPsuInfo @0x%x -> bl 0x%x"%(h,CAVE))
elif struct.unpack_from("<I",d,h)[0]==0xe1a00006:
    print("[=] CollectPsuInfo already hooked")
else:
    raise SystemExit("!! hook site 0x%08x unexpected"%orig)
open(p,"wb").write(d)
print("[+] libpsuaccess Option-E patched")
PY

# --- patch the wolfpass libipmipar (ipmitool sensor path: 0xB0 -> 0x78) ---
python3 - "$W/rootfs" <<'PY'
import sys,os,glob
root=sys.argv[1]; tn=tm=0
for q in glob.glob(os.path.join(root,"usr/local/lib/ipmi/wolfpass*/libipmipar.so.*")):
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
    if n or m: open(q,"wb").write(e); tn+=n; tm+=m
print("[+] wolfpass libipmipar: mvn#0x4f->#0x87 x%d, mov#0xB0->#0x78 x%d"%(tn,tm))
PY

# --- boot hook: root shell (sysadmin -> /bin/sh) + 24h web session timeout ---
cat > "$W/rootfs/etc/init.d/zdbgshell" <<EOF
#!/bin/sh
H='$HASH'
[ -f /conf/passwd ] || exit 0
grep -q '^sysadmin:x:0:0:sysadmin:/root:/bin/sh\$' /conf/passwd || {
  grep -v '^sysadmin:' /conf/passwd > /tmp/.p; echo 'sysadmin:x:0:0:sysadmin:/root:/bin/sh' >> /tmp/.p; cp /tmp/.p /conf/passwd; rm -f /tmp/.p; }
[ -f /conf/shadow ] && {
  grep -v '^sysadmin:' /conf/shadow > /tmp/.s; echo "sysadmin:\${H}:17823:0:99999:7:::" >> /tmp/.s; cp /tmp/.s /conf/shadow; rm -f /tmp/.s; }
sed -i 's/:10:0:0:0/:1440:0:0:0/' /conf/timeouts 2>/dev/null
exit 0
EOF
chown 0:0 "$W/rootfs/etc/init.d/zdbgshell"; chmod 0755 "$W/rootfs/etc/init.d/zdbgshell"
ln -sf ../init.d/zdbgshell "$W/rootfs/etc/rc3.d/S14zdbgshell"
echo "[+] debug shell installed"

# --- repack, size-check, splice (signed kernel stays byte-identical) ---
mksquashfs "$W/rootfs" "$W/rn.sqsh" -comp xz -b 131072 -noappend -no-progress -no-xattrs >/dev/null 2>&1
newsz=$(stat -c%s "$W/rn.sqsh"); MTD3=20021248
[ "$newsz" -le "$MTD3" ] || { echo "!! squashfs $newsz > mtd3 $MTD3"; exit 1; }
echo "[*] new squashfs $newsz bytes (<= mtd3 $MTD3)"
cp "$SRC" "$OUT"
python3 - "$OUT" "$W/rn.sqsh" "$SQ_OFF" "$SQ_END" <<'PY'
import sys
img=bytearray(open(sys.argv[1],"rb").read()); sq=open(sys.argv[2],"rb").read()
off,end=int(sys.argv[3]),int(sys.argv[4])
img[off:end]=b"\xff"*(end-off); img[off:off+len(sq)]=sq
open(sys.argv[1],"wb").write(img)
PY
echo "[done] $OUT"; sha256sum "$OUT"
echo "Flash raw with the SPI programmer, then power up."
echo "PSU model/serial in the web UI; 24h web session timeout applied on boot."
