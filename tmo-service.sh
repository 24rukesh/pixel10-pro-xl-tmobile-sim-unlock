#!/system/bin/sh
# T-Mobile whitelist clearer - runs at every KernelSU load
# Clears the modem carrier restriction so the Jio eSIM stays usable.
MODDIR=${0%/*}
LOG="$MODDIR/service.log"
{
  echo "$(date) tmo-unlock service start"
  # wait for Android boot to finish
  i=0
  until [ "$(getprop sys.boot_completed)" = "1" ] || [ $i -ge 60 ]; do
    sleep 2
    i=$((i+1))
  done
  # wait a little more for telephony/radio to settle
  sleep 10
  # clear whitelist, retry up to 6 times, spaced 15s
  n=0
  while [ $n -lt 6 ]; do
    OUT=$(CLASSPATH="$MODDIR/carrier-unlock.jar" app_process / CarrierUnlock clear 2>&1)
    echo "$OUT" | grep -q "setAllowedCarriers -> 0" && echo "$OUT" | grep -q "readback: CarrierRestrictionRules(allowed:\[\]," && {
      echo "$(date) attempt $((n+1)): CLEARED OK"
      echo "$OUT" | tail -3
      break
    }
    echo "$(date) attempt $((n+1)): failed, retrying"
    n=$((n+1))
    sleep 15
  done
} >> "$LOG" 2>&1
