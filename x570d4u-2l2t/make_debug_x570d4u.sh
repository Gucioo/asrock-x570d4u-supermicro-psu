#!/bin/bash
# ---------------------------------------------------------------------------
# make_debug_x570d4u.sh
#
# Like make_patched_x570d4u.sh, but ALSO enables a root shell on the stock
# ASRock firmware so the PSU presence-detection problem can be diagnosed live
# (i2cdetect, tracing compmanager, reading logs).
#
# Stock firmware ships sysadmin (uid 0) with the restricted /usr/local/bin/defshell
# and no usable root shell. This adds a boot-time init script that, on the real
# board, switches sysadmin's login shell to /bin/sh and sets the password YOU
# choose. Nothing is baked in here -- you pass the password at build time:
#
#   sudo DEBUG_PW='choose-your-own' ./make_debug_x570d4u.sh original-dump.bin out.bin
#
# It also applies the two PSU address patches AND, as leads for the presence
# problem, the 4 literal mov r3,#0xB0 in libipmipar (set NO_EXTRA=1 to skip).
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

# carve + extract rootfs
python3 - "$SRC" "$SQ_OFF" "$W/r.sqsh" <<'PY'
import sys,struct
d=open(sys.argv[1],"rb").read(); off=int(sys.argv[2])
assert d[off:off+4]==b"hsqs"
used=struct.unpack_from("<Q",d,off+40)[0]
open(sys.argv[3],"wb").write(d[off:off+used])
PY
unsquashfs -q -d "$W/rootfs" "$W/r.sqsh" >/dev/null
echo "[*] rootfs extracted"

# PSU address patches (+ optional extra literals)
python3 - "$W/rootfs" "${NO_EXTRA:-0}" <<'PY'
import sys,os
root,noextra=sys.argv[1],sys.argv[2]=="1"
p=os.path.join(root,"usr/local/lib/libpsuaccess.so.1.0.0")
d=bytearray(open(p,"rb").read())
if d[0x2048]==0x58: d[0x2048]=0x3c; open(p,"wb").write(d); print("[+] libpsuaccess 0x2048 -> 0x3c")
import glob
tot_n=tot_m=0
for q in glob.glob(os.path.join(root,"usr/local/lib/ipmi/wolfpass*/libipmipar.so.*")):  # IPMIMain loads wolfpass; patching all variants overflows mtd3
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
PY

# debug root shell: boot-time init that gives sysadmin a real shell + your password
cat > "$W/rootfs/etc/init.d/zdbgshell" <<EOF
#!/bin/sh
# Debug shell for PSU diagnosis. Remove this file to restore the stock restricted shell.
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
echo "[+] debug shell init installed (sysadmin -> /bin/sh, your password)"

# repack, size-check, splice, keep signed kernel byte-identical
mksquashfs "$W/rootfs" "$W/rn.sqsh" -comp xz -b 131072 -noappend -no-progress -no-xattrs >/dev/null 2>&1
newsz=$(stat -c%s "$W/rn.sqsh")
MTD3=20021248  # /sys/class/mtd/mtd3/size on this board (the "root" partition)
[ "$newsz" -le "$MTD3" ] || { echo "!! squashfs $newsz > mtd3 root partition $MTD3 -- will not mount ($newsz > $slot)"; exit 1; }
cp "$SRC" "$OUT"
python3 - "$OUT" "$W/rn.sqsh" "$SQ_OFF" "$SQ_END" <<'PY'
import sys
img=bytearray(open(sys.argv[1],"rb").read()); sq=open(sys.argv[2],"rb").read()
off,end=int(sys.argv[3]),int(sys.argv[4])
img[off:end]=b"\xff"*(end-off); img[off:off+len(sq)]=sq
open(sys.argv[1],"wb").write(img)
PY
echo "[done] $OUT"; sha256sum "$OUT"
echo "Flash raw with the SPI programmer, then: ssh sysadmin@<bmc>  (password: the DEBUG_PW you set)"
