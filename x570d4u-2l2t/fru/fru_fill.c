/* Injected into libpsuaccess.so at VMA 0x1d80.
 * Fills the four PSU MFR fields of CollectPsuInfo's output struct
 * (ID/Manufacturer, Model, Revision, Serial) from the PSU's IPMI FRU
 * EEPROM at i2c bus 2 / 7-bit 0x38, instead of the PMBus MFR commands
 * (0x99/0x9a/0x9b/0x9e) that this Supermicro PSU NAKs.
 *
 * base = CollectPsuInfo output struct; fields at base+0x36/+0x76/+0xB6/+0xF6.
 * Rides the existing "compliant PSU answered" path: writes null-terminated
 * strings into the 64-byte, memset-zeroed fields the redfish backend reads.
 */
extern int i2c_writeread_on_bus(int bus, int addr,
                                unsigned char *wbuf, unsigned char *rbuf,
                                int wlen, int rlen);

int psu_fru_fill(unsigned char *base)
{
    unsigned char buf[96];
    unsigned char off;
    int i, f, k, len, prod;
    unsigned char *p;
    unsigned char tl;
    /* destinations by FRU product-field index:
       0 Manufacturer -> ID field (+0x36)
       1 Product Name -> Model    (+0x76)
       2 Part/Model   -> (skip)
       3 Version      -> Revision (+0xB6)
       4 Serial       -> Serial   (+0xF6) */
    unsigned char *dst[5];
    dst[0] = base + 0x36;
    dst[1] = base + 0x76;
    dst[2] = 0;
    dst[3] = base + 0xB6;
    dst[4] = base + 0xF6;

    /* read 96 bytes of the FRU (covers common header + product area) */
    for (i = 0; i < 96; i += 16) {
        off = (unsigned char)i;
        if (i2c_writeread_on_bus(2, 0x38, &off, buf + i, 1, 16) < 0)
            return 0;
    }
    if (buf[0] != 1)          /* not an IPMI FRU common header */
        return 0;
    prod = buf[4] * 8;        /* product info area byte offset */
    if (prod < 8 || prod > 80)
        return 0;
    p = buf + prod + 3;       /* skip format, length, language */

    for (f = 0; f < 5; f++) {
        tl = *p;
        if (tl == 0xC1 || tl == 0xFF) break;   /* end / empty */
        len = tl & 0x3F;
        p++;
        if (dst[f] && len > 0 && len < 63) {
            for (k = 0; k < len; k++)
                dst[f][k] = p[k];
            dst[f][len] = 0;
        }
        p += len;
    }
    return 4;
}
