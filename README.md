# Permanent SIM unlock - T-Mobile-locked Pixel 10 Pro XL (mustang), locked bootloader

**Repo contents:**

| File | Purpose |
|---|---|
| `README.md` | This guide |
| `CarrierUnlock.java` | Reflection helper: clears the modem `CarrierRestrictionRules` whitelist via `ITelephony` |
| `service.sh` + `module.prop` | KernelSU module (`tmo-unlock`) that re-clears the whitelist at every boot |

---


**Device tested:** Google Pixel 10 Pro XL (`mustang`), SKU `GUL82` (T-Mobile), Android 17 QPR2, build `CP4A.261105.040.A1`, kernel `6.12.81-android16-6-g4a1a020d156e-ab16388316-4k`, 4K pages, bootloader **locked**, OEM unlocking greyed out.

**Result:** any eSIM (tested with a Jio India profile) and any physical SIM work, **persist across reboots and OTAs**, on a bootloader that stays locked. Root available on demand (per-boot). No IMEI/blacklist/financing status is changed; this only removes local lock enforcement.

Use this only on hardware you own or are authorized to service. Removing local enforcement does not cancel financing or a server-side carrier registration.

---

## How the T-Mobile lock actually works on Pixel 10

Three separate layers, and each needs different treatment:

| Layer | Where it lives | What blocks | Fix |
|---|---|---|---|
| 1. Enforcer app | `com.google.android.apps.work.oobconfig` ("Device Setup"), `/product/priv-app/OTAConfigNoZeroTouchPrebuilt` | Queries Google's lock database on first network contact, stores the result in its cache, and pushes it into the modem | Uninstall for user 0 by patching `package-restrictions.xml` (pm refuses: it's a protected package) |
| 2. Modem whitelist | Modem storage, re-asserted at every boot | `CarrierRestrictionRules` with the T-Mobile USA PLMN list. The eUICC service refuses to **activate** any profile outside the list | Clear live via `ITelephony.setAllowedCarriers(empty)` with a reflection helper run as root |
| 3. OEM/bootloader bit | TEE/RPMB, carrier-signed | OEM unlocking toggle | **Not locally fixable.** This guide does not unlock the bootloader |

The critical insight that makes the fix permanent: the whitelist only gates profile **activation**. An **active** profile is never killed by the re-applied whitelist once the enforcer app is gone. So: clear once, activate the eSIM in the same session, remove the enforcer, and the profile survives everything.

## Prerequisites

- PC with `adb` and Python 3
- A JDK + `android.jar` (API 34+) + `d8` (or the build.sh from the Root-My-Pixel-Pixel6a project) to compile the 2 KB helper jar
- **TimerRoot** - use the **`beta` release** (rolling `timer-p7a` beta), not the `bingchiling` release: the beta binary's reliability fixes matter enormously. On the 6.6.127 (Oct) kernel and the 6.12.81 (Nov) kernel, the stable binary missed the plant burst 12/12 runs across every condition; the beta binary hit 7 of 8.
- **KernelSU manager** v3.3.1+ installed (for the `fake` mode / permissive stage)
- Your phone on build `CP4A.261105.040.A1` (or a build with a matching TimerRoot profile). **Do not go past the November 2026 patch** if you want the root chain to keep working. The SIM fix itself survives future OTAs.

## Step 1 - root with the reliable recipe

The conditions that decide the race, in order of importance:

1. **Beta binary, not stable.**
2. **Run BFU** - before first unlock after boot. AFU (after unlock) runs fail far more often; background apps win the reclaim race.
3. Fresh boot, device settled 2-3 minutes, screen can stay at the lockscreen.
4. One run per boot. A miss parks a zombie - reboot before retrying.

```
adb shell uname -r          # must match the conf exactly
adb shell getconf PAGESIZE  # 4096

adb shell "cd /data/local/tmp && timeout 110 ./timer \
  --conf timer-conf/6.12.81-android16-6-g4a1a020d156e-ab16388316-4k.conf shell"
```

Success ends with `uid=0(root)` and `ROOT_SHELL_OK`. For the KernelSU + permissive stage (needed for the package-state surgery):

```
adb shell "cd /data/local/tmp && timeout 110 ./timer \
  --conf timer-conf/6.12.81-android16-6-g4a1a020d156e-ab16388316-4k.conf fake"
# then: adb shell "su -c id"  ->  uid=0(root) context=u:r:ksu:s0
# then: adb shell "su -c 'setenforce 0'"
```

## Step 2 - build the carrier whitelist helper

`CarrierUnlock.java` calls the hidden `ITelephony` methods through reflection:

```
javac -source 8 -target 8 -classpath android.jar -d classes CarrierUnlock.java
d8 --min-api 26 --lib android.jar --output dex classes/CarrierUnlock.class
(cd dex && zip -q ../carrier-unlock.jar classes.dex)
adb push carrier-unlock.jar /data/local/tmp/
```

Inspect first, clear second:

```
# inspect (prints the current CarrierRestrictionRules)
adb shell "su -c 'CLASSPATH=/data/local/tmp/carrier-unlock.jar app_process / CarrierUnlock'"

# clear (setAllCarriersAllowed + setAllowedCarriers, 2.5s readback)
adb shell "su -c 'CLASSPATH=/data/local/tmp/carrier-unlock.jar app_process / CarrierUnlock clear'"
```

Expected: `setAllowedCarriers -> 0` and a readback of `allowed:[]`. **The list returns at the next boot** - that is expected and does not matter once the enforcer is gone.

## Step 3 - remove the enforcer (the permanent part)

`pm clear / uninstall / disable-user` are all rejected for `oobconfig` even as root (protected package). Patch the per-user package state instead. With KSU root active:

```sh
#!/system/bin/sh
set -eu
PKG=com.google.android.apps.work.oobconfig
SD=/data/system/users/0
T=/data/local/tmp/oobfix

svc wifi disable
svc data disable
am force-stop $PKG || true
mkdir -p $T
cp $SD/package-restrictions.xml $SD/package-restrictions.oobconfig.bak
[ -f $SD/package-restrictions.xml.reservecopy ] && \
  cp $SD/package-restrictions.xml.reservecopy $SD/package-restrictions.reservecopy.bak
abx2xml $SD/package-restrictions.xml $T/package-restrictions.xml
```

Then on the PC, patch the single `<pkg name="com.google.android.apps.work.oobconfig">` entry:

```xml
inst="false" stopped="true" nl="true"
```

Push back and finish (the atomic `mv` matters: the state files carry fs-verity, in-place writes fail with EPERM; a rename swaps the inode like Android's own AtomicFile):

```sh
xml2abx $T/package-restrictions.patched.xml $T/package-restrictions.patched.abx
abx2xml $T/package-restrictions.patched.abx $T/verify.xml
grep -q "name=\"$PKG\".*inst=\"false\"" $T/verify.xml

pid=$(pidof $PKG || true); [ -z "$pid" ] || kill -9 $pid
CLASSPATH=/data/local/tmp/carrier-unlock.jar app_process / CarrierUnlock clear

cp $T/package-restrictions.patched.abx $SD/package-restrictions.oobconfig-new
cp $T/package-restrictions.patched.abx $SD/package-restrictions.oobconfig-reserve-new
chown system:system $SD/package-restrictions.oobconfig-new $SD/package-restrictions.oobconfig-reserve-new
chmod 660 $SD/package-restrictions.oobconfig-new $SD/package-restrictions.oobconfig-reserve-new
restorecon $SD/package-restrictions.oobconfig-new $SD/package-restrictions.oobconfig-reserve-new
mv -f $SD/package-restrictions.oobconfig-new $SD/package-restrictions.xml
mv -f $SD/package-restrictions.oobconfig-reserve-new $SD/package-restrictions.xml.reservecopy
sync
reboot
```

**The reboot must happen immediately** - PackageManager still holds the old installed state in memory.

## Step 4 - activate the eSIM during a live clear

This is the moment that made everything work: the profile download works even locked, but **activation** needs the whitelist cleared in the same session:

1. Root (Step 1), clear the whitelist (Step 2), keep the session alive
2. On the phone: Settings > SIMs > toggle the eSIM on
3. The activation check now passes, the profile becomes active - **and stays active forever**, because the whitelist can no longer kill active profiles (the enforcer is gone)

For a second eSIM later: same dance - clear once, activate during the session. Active profiles never need it again.

## Step 5 (optional) - self-healing boot chain

If you want root to come back automatically at every boot, and the whitelist to be re-cleared as insurance:

**TimerRoot auto-root channel** (run once, with root active):

```sh
setprop persist.adb.tcp.port 5555
settings put global adb_allowed_connection_time 0
cat your_adbkey.pub >> /data/misc/adb/adb_keys
# and write /data/data/com.kpgc.timerroot/shared_prefs/auto_root.xml:
#   <boolean name="enabled" value="true" />
#   <boolean name="channel_installed" value="true" />
#   <int name="adb_port" value="5555" />
#   <string name="private_key">BASE64-PKCS8-OF-THE-SAME-KEY</string>
```

**KernelSU module** `tmo-unlock` (in this repository): on every successful KSU load, waits for boot, retries `CarrierUnlock clear` up to 6 times, logs to the module dir. Install to `/data/adb/modules/tmo-unlock/`.

The chain fires at `LOCKED_BOOT_COMPLETED` before you unlock the phone. The exploit is a ~1-in-3 race per burst; a missed boot just means no root that boot - the SIM does not care.

## Verification checklist (after any reboot)

```
adb shell getprop gsm.sim.state          # LOADED
adb shell getprop gsm.operator.alpha     # your carrier
adb shell pm list packages --user 0 | grep -c oobconfig   # 0
adb shell pidof com.google.android.apps.work.oobconfig    # none
adb shell 'logcat -b radio -d | grep -c SET_ALLOWED_CARRIERS'  # 0 (no enforcer activity)
```

## What this does NOT do

- **No bootloader/OEM unlock.** The carrier bit in the TEE requires T-Mobile's signature. Official unlock (paid off + 40 days on network) or a paid remote unlock service remain the only paths.
- **No financing/account changes.** If the device is on an installment plan, that obligation is untouched.
- **Not SIM-blacklist related.** A blocked IMEI stays blocked.

## Warnings

- Do not delete the eSIM profile expecting to re-download casually - re-activation needs a live whitelist clear again.
- Keep the `package-restrictions.oobconfig.bak` backups until you are sure. Rollback = convert, restore entry, atomic replace, reboot.
- The December 2026 patch kills the kernel exploit. The SIM fix survives OTA; root availability depends on a new TimerRoot profile for the new kernel.

## Credits

- **TimerRoot** (kpgc/MVN123123123123123) - the CVE-2026-98260 exploit and app, and the beta binary that made it reliable
- **DurkaEbanaya/Root-My-Pixel-Pixel6a** - the oobconfig surgery procedure (`docs/carrier-lock.md`) and `CarrierUnlock` helper this guide adapts
- The XDA carrier-unlock threads and the GrapheneOS forum GUL82 case for the unlock architecture


---

## OEM unlock: what we actually tested (Nov 2026, build CP4A.261105.040.A1)

A widely shared write-up claims the greyed OEM unlock switch is just the last byte of the `frp` partition and that root can flip it. Tested end to end on `mustang`, SKU `GUL82`:

| Step | Result |
|---|---|
| Locate the byte | `frp` partition, 524288 bytes; OEM flag is byte 524287, value `0x00` when locked |
| `dumpsys persistent_data_block` baseline | `OEM unlock state: false`, bootloader lock `1` |
| Write `0x01` at 524287 with root | Android immediately reports `OEM unlock state: true` |
| Reboot to bootloader, `get_unlock_ability` | **still `0`** |
| `fastboot flashing unlock` with byte at `01` | **`FAILED (remote: 'flashing unlock is not allowed')`** |

The Android-side API confirms a second, separate gate:

```
oem_lock service, serial 01.01
isOemUnlockAllowed             = false
isOemUnlockAllowedByCarrier    = false     <-- the real block
isOemUnlockAllowedByUser       = false

setOemUnlockAllowedByUser(true)     -> SecurityException: Carrier does not allow OEM unlock
setOemUnlockAllowedByCarrier(true)  -> IllegalArgumentException: Signature required for carrier unlock
                                       (VendorLockAidl)
```

So the mechanism in the write-up is correct but **incomplete for a carrier-locked unit**. There are two halves: a user byte (writable with root) and a carrier flag in RPMB that needs a Google-signed challenge. The byte flip is a prerequisite, not a solution. Nothing on `/persist` holds it (the lock name `01.01` is an RPMB slot).

Practical ordering that follows from this: signed unlock service first, or an OOBE that never lets the carrier flag be written. Do not expect a raw byte flip to open `flashing unlock` on a T-Mobile SKU.

### Undo / restore

Back up first: `dd if=/dev/block/by-name/frp of=/sdcard/frp_stock.img`, pull it, and keep it off-device. To restore the stock state just write `0x00` back at 524287 (Android also rewrites it to `0` on the next boot while the user flag is false).
