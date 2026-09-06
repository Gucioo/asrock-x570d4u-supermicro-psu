#!/bin/sh
# psu-fanctl -- temp-based fan curve for the Supermicro PMBus PSU on the
# ASRock X570D4U-2L2T stock BMC (PSU at i2c bus 2 / 0x3c, Fan 1 in duty mode).
#
# Stock firmware leaves the PSU fan on its own thermal curve (idles ~224 RPM).
# This drives FAN_COMMAND_1 (0x3b) from the PSU's own temperature so there is a
# guaranteed airflow floor and a controlled ramp under heat.
#
# Curve (edit the four knobs):
#   temp <= TMIN        -> FLOOR %
#   TMIN < temp < TMAX  -> linear FLOOR..100 %
#   temp >= TMAX        -> 100 %
# Control temp = max(READ_TEMPERATURE_1 0x8d, READ_TEMPERATURE_2 0x8e).
FLOOR=30      # minimum duty %
TMIN=50       # start ramping above this (deg C)
TMAX=70       # full speed at/above this (deg C)
INTERVAL=10   # seconds between updates
BUS=2; ADDR=0x3c; I2C=/usr/local/bin/i2c-test

rdword(){  # $1=cmd -> decimal word (LINEAR11, exp 0); -1 on read failure
  o=$($I2C -b $BUS -s $ADDR -rc 2 -m 1 -d $1 2>/dev/null | sed -n 2p)
  lo=$(echo $o | cut -d' ' -f1); hi=$(echo $o | cut -d' ' -f2)
  case "$lo" in ''|*[!0-9a-fA-F]*) echo -1; return;; esac
  echo $(( (0x$hi << 8) | 0x$lo ))
}
setduty(){ $I2C -b $BUS -s $ADDR -w -d 0x3b $(printf '0x%02x' $1) 0x00 >/dev/null 2>&1; }

while :; do
  t1=$(rdword 0x8d); t2=$(rdword 0x8e)
  Tc=$t1; [ "$t2" -gt "$Tc" ] 2>/dev/null && Tc=$t2
  # reject bad/garbage reads (PSU absent or 0xffff): valid PSU temp 1..120 C
  if [ "$Tc" -ge 1 ] 2>/dev/null && [ "$Tc" -le 120 ] 2>/dev/null; then
    if   [ "$Tc" -le "$TMIN" ]; then duty=$FLOOR
    elif [ "$Tc" -ge "$TMAX" ]; then duty=100
    else duty=$(( FLOOR + (Tc-TMIN)*(100-FLOOR)/(TMAX-TMIN) )); fi
    [ "$duty" -lt "$FLOOR" ] && duty=$FLOOR
    [ "$duty" -gt 100 ] && duty=100
    setduty $duty
    [ -n "$FANCTL_VERBOSE" ] && echo "T1=${t1} T2=${t2} Tc=${Tc}C -> duty ${duty}%"
  fi
  sleep $INTERVAL
done
