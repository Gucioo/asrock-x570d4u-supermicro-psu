#!/usr/bin/env python3
# Patch libpsuaccess.so.1.0.0:  Option E -- fill PSU MFR fields from the FRU EEPROM (0x38).
# 1) psuaccessAddr 0x58->0x3c (sensor-value address; may already be patched)
# 2) grow exec LOAD1 filesz/memsz 0x1d80 -> 0x1ee0
# 3) place fru_fill blob at file/VMA 0x1d80
# 4) hook CollectPsuInfo @0x12a4: mov r0,r6; bl 0x1d80; add r5,r5,r0; b 0x131c
import sys,struct
lib, blobf, out = sys.argv[1], sys.argv[2], sys.argv[3]
d=bytearray(open(lib,"rb").read())
blob=open(blobf,"rb").read()
CAVE=0x1d80; CAVE_END=0x1ee0
assert len(blob) <= (CAVE_END-CAVE), "blob too big"

# --- 1) sensor address patch (idempotent) ---
if d[0x2048]==0x58: d[0x2048]=0x3c; print("[+] psuaccessAddr 0x58->0x3c")
elif d[0x2048]==0x3c: print("[=] psuaccessAddr already 0x3c")
else: raise SystemExit("!! 0x2048 unexpected 0x%02x"%d[0x2048])

# --- 2) grow LOAD1 (the r-x segment, off=0) to cover the cave ---
e_phoff=struct.unpack_from("<I",d,0x1c)[0]
e_phentsize=struct.unpack_from("<H",d,0x2a)[0]
e_phnum=struct.unpack_from("<H",d,0x2c)[0]
grown=False
for i in range(e_phnum):
    o=e_phoff+i*e_phentsize
    p_type,p_off,p_vaddr,p_paddr,p_filesz,p_memsz,p_flags,p_align=struct.unpack_from("<8I",d,o)
    if p_type==1 and p_off==0 and (p_flags & 1):  # PT_LOAD, file off 0, executable
        assert p_filesz==0x1d80 and p_memsz==0x1d80, "unexpected LOAD1 sz 0x%x/0x%x"%(p_filesz,p_memsz)
        struct.pack_into("<I",d,o+16,CAVE_END)  # p_filesz
        struct.pack_into("<I",d,o+20,CAVE_END)  # p_memsz
        print("[+] grew exec LOAD1 filesz/memsz 0x1d80 -> 0x%x"%CAVE_END); grown=True
assert grown, "exec LOAD1 not found"

# --- 3) place blob ---
assert all(b==0 for b in d[CAVE:CAVE+len(blob)]), "cave not empty!"
d[CAVE:CAVE+len(blob)]=blob
print("[+] blob %d bytes @ 0x%x"%(len(blob),CAVE))

# --- 4) hook CollectPsuInfo @0x12a4 ---
def bl(frm,to):  return 0xeb000000 | (((to-frm-8)>>2)&0xffffff)
def b(frm,to):   return 0xea000000 | (((to-frm-8)>>2)&0xffffff)
hook=0x12a4
ins=[0xe1a00006,        # mov r0,r6      (r0 = struct base = arg1)
     bl(hook+4,CAVE),   # bl  0x1d80
     0xe0855000,        # add r5,r5,r0
     b(hook+12,0x131c)] # b   0x131c     (function epilogue)
# sanity: what we overwrite currently starts the MFR loop (ldr r4,[pc,..])
orig=struct.unpack_from("<I",d,hook)[0]
assert (orig>>16)==0xe59f, "hook site 0x%08x not the expected ldr"%orig
for j,v in enumerate(ins): struct.pack_into("<I",d,hook+4*j,v)
print("[+] hooked CollectPsuInfo @0x%x -> bl 0x%x"%(hook,CAVE))
open(out,"wb").write(d)
print("[done]",out,len(d),"bytes")
