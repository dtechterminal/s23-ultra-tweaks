# s23-ultra-tweaks, phone side. Two ways it gets onto the phone:
#  - the KernelSU module: code in /data/adb/modules/s23_ultra_tweaks (this folder has module.prop)
#  - install.sh (adb): code in /data/adb/s23tweaks
# State (picks, logs, backups) always lives in /data/adb/s23tweaks, so module updates keep it.
# Everything runs as root. "start" runs "apply" detached in init's mount namespace, because the
# framework restart kills the caller (adb shell, KernelSU's WebUI):
#   su -c "sh <this folder>/tweaks.sh start 'airdrop battery'"
# Commands:
#   start "<tweaks>"  apply the listed tweaks in the background; follow tweaks.log in the state folder
#   apply "<tweaks>"  the same in the foreground (what start runs)
#   probe             one line of JSON: phone, which tweaks it can take and why not, what's active
#   status            print what is active
#   unflag            remove the two Play services flag overrides that the airdrop tweak adds
#   autostart on|off  re-apply the saved tweaks at every boot. DFRoot roots the phone by itself at
#                     boot, then KernelSU runs the module's service.sh (module) or a script in
#                     /data/adb/service.d (install.sh). Both call "boot".
#   boot              (internal) the automatic apply at boot
#   wifi7page         open Samsung's hidden "Wi-Fi 7 mode" settings page (Wi-Fi Labs)
#   loop | guard      (internal) keep mosey_server running / reboot cleanly on a Wi-Fi firmware crash
# Tweaks: airdrop battery features callrec india hotspot6g wifi7 display logvideo vulkan
#         camerahdr audioeraser colortone galaxyai camextras autoframe settingssearch bargein
#         callscreen  (see README.md; the categories they're grouped in are in install.sh and the WebUI)
#
# Nothing here writes to a partition. Every change is a module load, an overlay, a bind mount or a
# runtime setting, so a reboot always returns the phone to stock. The files themselves stay on storage
# (/data/adb/s23tweaks), not in RAM: the kernel won't build an overlay from /data, so each overlay holds
# only empty placeholders in tmpfs and the real file is bind-mounted over its placeholder (pbind). The one exception is
# the airdrop tweak's two Play services flag overrides, stored in Play services' own database
# (harmless without the rest; "unflag" removes them), camextras' camera app setting, and callscreen,
# which installs Samsung Language Core as an ordinary app (undo: pm uninstall <package>).
# Never touched: the sales code (mps_code.dat, sales_code.dat, omc.info, persist.sys.matched_code).
# Changing those can factory-reset the phone.

# KernelSU runs boot scripts in BusyBox standalone mode; make sure every tool here is Android's own
unset ASH_STANDALONE; export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
D=$(cd "$(dirname "$0")" && pwd)            # code: this script and files/
V=${S23T_STATE:-/data/adb/s23tweaks}         # state: choices, logs, backups, autostart flag
mkdir -p $V; L=$V/tweaks.log; R=$V/run
[ -f $D/module.prop ] && MODULE=1 || MODULE=0
APPLY_LOCK=/dev/s23tweaks_apply.lock         # /dev is tmpfs: locks never survive a reboot
TWEAK_IDS="airdrop battery features callrec india hotspot6g wifi7 display logvideo vulkan camerahdr audioeraser colortone galaxyai camextras autoframe settingssearch bargein callscreen"
GMS_MIN=261125000                            # Play services 26.11, the first with Mosey support
# Firmware the AirDrop/Wi-Fi 7 kernel modules are checked against (one line each, read by customize.sh).
# All are One UI 9 build GZIF on GKI kernel 34343818, and their whole Wi-Fi stack (cnss2, mhi, cfg80211,
# mac80211, ipa) has the same code and symbol CRCs as S918WVLU8GZIF, which the modules are built on.
AIRDROP_KBASE=5.15.197-android13-8-34343818-ab
AIRDROP_FW="S918WVLU8GZIF S918BXXUAGZIF S918U1UEU8GZIF S918USQU8GZIF S918NKSU8GZIF"
kernel_supported() { for f in $AIRDROP_FW; do [ "$(uname -r)" = "$AIRDROP_KBASE$f" ] && return 0; done; return 1; }
STOCK_KO=/vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko
FF=/system/etc/floating_feature.xml
CF=/system/cameradata/camera-feature.xml
# Files made on the phone (edited configs) that binds point at, on storage: one folder per boot, since a
# boot's mounts keep using its files. ly_init deletes the earlier boots' folders the first time in a boot.
LY=$V/layers/$(cat /proc/sys/kernel/random/boot_id)
ly_init() { [ -d $LY ] || { rm -rf $V/layers; mkdir -p $LY; }; }
PL=$V/payload; T24=/dev/s23tweaks_layers    # per-tweak downloads (unpacked in payload/<tweak>/); tmpfs for the layers' placeholders
# pbind <file on storage> <target> <SELinux type> [exec]: bind a downloaded file over a path (over its
# placeholder, for a file an overlay adds). A bind keeps /data's nosuid, which would stop a program
# from entering its own SELinux domain, so for programs BusyBox clears it (toybox mount can't).
pbind() {
  if [ -n "$4" ]; then chmod 755 "$1"; else chmod 644 "$1"; fi; chcon u:object_r:$3:s0 "$1"
  mount -o bind,ro "$1" "$2" || fail "bind $2"
  [ -n "$4" ] || return 0
  for bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox; do [ -x $bb ] && { $bb mount -o remount,bind,ro,suid "$2"; break; }; done
  grep " $2 " /proc/mounts | grep -q nosuid && { umount "$2"; fail "couldn't clear nosuid on $2"; }
  return 0
}
AIR=$PL/airdrop                              # the airdrop/wifi7 download: kernel modules, firmware, Mosey, tools
# The module zip holds only scripts. Every tweak that needs files downloads them from the GitHub release
# $PAYLOAD_URL when it's picked: tweak, file, SHA-256. A tweak with several lines is one tar split into
# parts (GitHub caps a file at 2 GB), joined on the phone. A copy in $V/dl/ (the installer can push one)
# is used first.
PAYLOAD_URL=https://github.com/dtechterminal/s23-ultra-tweaks/releases/download/payloads-S918WVLU8GZIF
PAYLOADS="airdrop airdrop-S918WVLU8GZIF.tar.gz 84787b2527d71cbb6cb23ba04a51e3539e1f466e6ab6fe1e489fc67b04879202
camerahdr camerahdr-S918WVLU8GZIF.tar.gz ed4d9be902918d1d014b91d3fd53cec42512f58744a398ec4e0888be04116bcc
audioeraser audioeraser-S918WVLU8GZIF.tar.gz a11d2868b3d8ba0121554ea2a31bb65256e0c141c6033c4e6ddb4770f4d11704
colortone colortone-S918WVLU8GZIF.tar.gz 4be28f16e3631f1e377ecec9ad2b5b78d1abf8c6a9b971435c7ac12604f75e40
galaxyai galaxyai-S918WVLU8GZIF.tar.gz 5619aaee7580b985df300dcfca1fadc56bc774f60ebb2af9db975876dfe01c0e
settingssearch settingssearch-S918WVLU8GZIF.tar.gz bddfa32a08def256b7497730a0e7faecf7b1621655ce0cc85bec423843357042
callscreen callscreen-S918WVLU8GZIF.tar.partaa 6a8d141557050e738b3a805d741463aae46b9322732bdd3039d836c0d116af9a
callscreen callscreen-S918WVLU8GZIF.tar.partab 3335ea84794746040513e4297175736d792a19f378187d7b970c4058bc421025"
SETTINGS=/system/priv-app/SecSettings/SecSettings.apk
# colortone: firmware, md5 of its SecSettings.apk, md5 with files/SecSettings-ead-<firmware>.patch applied
# (tools/eadpatch.py makes the patch and prints both for another firmware's APK)
SETTINGS_EAD="S918WVLU8GZIF 5b8afa24f17e090d57380b8ebbd3dcee f499f2e574a47eca0414f470e1ae20e8
S918BXXUAGZIF 5b20b1a68f94d01bba5a776e15ffdc30 de6d142d238849198810dfe70fada8dd"
ead_row() { echo "$SETTINGS_EAD" | awk -v b="$(getprop ro.build.PDA)" '$1 == b'; }
ead_builds() { echo "$SETTINGS_EAD" | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//; s/ / or /g'; }
XAC=/optics/configs/carriers/XAC/conf; PRISM=/prism/etc/carriers/XAC
# md5 of the stock (encoded) XAC files on S918WVLU8GZIF: the CSC tweaks replace them, so they only
# run when the phone has exactly these
XAC_CSC_MD5=4921cc4fa8a85213856630d0bf7b661a
XAC_CCF_MD5=71e37a386615cc5db6b4e94fef72bea3
XAC_CUST_MD5=8d2f19740e35a0d0f30759bebd033043
# callrec on other sales codes: sales code, firmware, its stock (encoded) cscfeature.xml, that file's md5,
# and the folder in files/ with the decoded file plus the recording keys (in every FeatureSet: these
# multi-country files have one per country)
CALLREC_CSC="EUX S918BXXUAGZIF /optics/configs/carriers/single/EUX/conf/system/cscfeature.xml fe43ce0679d14cb57dde71cff6475a81 eux-callrec"
callrec_row() { echo "$CALLREC_CSC" | awk -v c="$(getprop ro.csc.sales_code)" '$1 == c'; }
NEARBY_FLAGS="45704091 45723015"   # Nearby Sharing: enableExternalProviders + the provider-registry gate

log() { m="$(cut -d' ' -f1 /proc/uptime) $*"; echo "$m" >> $L; echo "s23tweaks: $*" > /dev/kmsg; sync; }
fail() { log "FAILED: $*"; exit 1; }
wait_for() { n=$1; shift; while [ $n -gt 0 ]; do "$@" && return 0; n=$((n-1)); sleep 1; done; return 1; }
mounted() { mount | grep -q " $1 type $2"; }
bound() { mount | grep -q " $1 "; }
running() { ps -A -o ARGS | grep -q "[t]weaks.sh $1"; }
has() { case " $TWEAKS " in *" $1 "*) return 0 ;; esac; return 1; }
md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
# The apply lock is a directory holding the owner's pid. A lock whose owner is gone (killed apply)
# counts as free, so a crash can't block every later apply until the next reboot.
lock_alive() { lp=$(cat $APPLY_LOCK/pid 2>/dev/null); [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; }
take_lock() {
  if ! mkdir $APPLY_LOCK 2>/dev/null; then
    lock_alive && return 1
    rm -rf $APPLY_LOCK; mkdir $APPLY_LOCK 2>/dev/null || return 1
  fi
  echo $$ > $APPLY_LOCK/pid
}
# Started from KernelSU's app (module page, action button), this shell sits in that app's cgroup
# (/apps/uid_N/pid_M). Android freezes or kills that whole group when the app is cached or dies,
# which the framework restart in apply guarantees. Move to the root cgroup first; children follow.
to_root_cgroup() { echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null; }

# kallsyms address of a symbol in a module (kptr_restrict is lowered only for the read)
ksym() {
  o=$(cat /proc/sys/kernel/kptr_restrict); echo 1 > /proc/sys/kernel/kptr_restrict
  # lines are "<address> <type> <name>\t[<module>]": match the name and module fields exactly
  a=$(awk -v s="$1" -v m="[$2]" '$3 == s && $4 == m {print $1; exit}' /proc/kallsyms)
  echo $o > /proc/sys/kernel/kptr_restrict
  [ -n "$a" ] && [ "$a" != 0000000000000000 ] && echo $a
}
# ksect <module> <section>: a module section's address (hidden, like kallsyms, unless kptr_restrict <= 1)
ksect() {
  o=$(cat /proc/sys/kernel/kptr_restrict); echo 1 > /proc/sys/kernel/kptr_restrict
  a=$(cat /sys/module/$1/sections/$2 2>/dev/null)
  echo $o > /proc/sys/kernel/kptr_restrict
  [ -n "$a" ] && [ "$a" != 0x0000000000000000 ] && echo $a
}

# ---------- airdrop: kernel side ----------
wlan_up() { [ -e /sys/class/net/wlan0 ] && [ $(( $(cat /sys/class/net/wlan0/flags) & 1 )) = 1 ]; }
hal_stopped() { [ "$(getprop init.svc.vendor.wifi_hal_legacy)" = stopped ]; }
hostapd_stopped() { [ "$(getprop init.svc.hostapd)" != running ]; }
wifi_off() { cmd wifi status | grep -q "Wifi is disabled"; }
sup_stopped() { [ "$(getprop init.svc.wpa_supplicant)" != running ]; }
wifi_down() {
  # Samsung turns Wi-Fi back on by itself right after a hotspot stops, so stop the hotspot first,
  # let that settle, and make sure Wi-Fi stays off before the driver is unloaded.
  if [ "$(getprop init.svc.hostapd)" = running ]; then
    cmd wifi stop-softap >/dev/null 2>&1; wait_for 15 hostapd_stopped || log "hotspot did not stop"; sleep 5
  fi
  cmd wifi set-scan-always-available disabled
  for i in 1 2 3; do cmd wifi set-wifi-enabled disabled; wait_for 10 wifi_off && sleep 4 && wifi_off && break; done
  wifi_off || { cmd wifi set-wifi-enabled enabled; cmd wifi set-scan-always-available enabled; fail "Wi-Fi keeps turning itself back on"; }
  wait_for 20 sup_stopped || log "wpa_supplicant still running after Wi-Fi off"
  [ -d /sys/module/wonder ] && { rmmod wonder || log "could not unload wonder"; }
  stop wpa_supplicant; stop vendor.wifi_hal_legacy; stop vendor.wifi_hal_ext
  wait_for 20 hal_stopped || log "Wi-Fi HAL did not stop"
  rmmod kiwi_v2 || { wifi_up; fail "could not unload the stock Wi-Fi driver"; }
}
wifi_up() {
  start vendor.wifi_hal_ext; start vendor.wifi_hal_legacy; start wpa_supplicant
  cmd wifi set-wifi-enabled enabled
  wait_for 45 wlan_up && log "Wi-Fi back on" || log "Wi-Fi did not come back by itself"
  cmd wifi set-scan-always-available enabled
}
back_to_stock() {   # the firmware binds sit on the overlay, so they come off first
  for m in $(awk '$2 ~ "^/vendor/firmware/kiwi/" {print $2}' /proc/mounts); do umount $m; done
  mounted /vendor/firmware/kiwi overlay && umount /vendor/firmware/kiwi; insmod $STOCK_KO; wifi_up
}

airdrop_kernel() {
  A=$AIR
  if [ -d /sys/module/wonder ] && [ -d /sys/module/bwfix ]; then log "airdrop: kernel side already loaded"; AK_LOADED=1; return 0; fi
  log "airdrop: swapping in the S24 Wi-Fi driver and firmware (Wi-Fi drops for ~30 s)"
  wifi_down
  # cnss2/MHI keep buffers sized for the boot-time firmware; mhifix frees them so the bigger S24
  # firmware gets correctly sized ones. It needs the address of cnss2's static plat_env pointer.
  pe=$(ksym plat_env cnss2) || { back_to_stock; fail "plat_env not found in kallsyms"; }
  b=$(ksect cnss2 .bss) || { back_to_stock; fail "cnss2 .bss address not readable"; }; d=$(( 0x$pe - b ))
  [ $d -ge 0 ] && [ $d -lt 1048576 ] || { back_to_stock; fail "plat_env 0x$pe is not in cnss2 .bss"; }
  insmod $A/mhifix.ko mode=1 plat_env=0x$pe; r=$(dmesg | grep mhifix | tail -4 | tr '\n' ' ')
  case "$r" in *"tables freed"*"fw_mem DDR freed"*) ;; *) back_to_stock; fail "mhifix: $r" ;; esac
  # S24 firmware over /vendor/firmware/kiwi: an overlay of placeholders, each bound to the downloaded file
  # (the S23 board file stays)
  T=/dev/s23tweaks_fw; FW="amss20.bin phy_ucode20.elf regdb.bin"
  mkdir -p $T; mounted $T tmpfs || mount -t tmpfs -o mode=755 s23tweaks_fw $T
  for f in $FW; do : > $T/$f; done; chmod 644 $T/*; chcon u:object_r:vendor_firmware_file:s0 $T $T/*
  mount -t overlay s23tweaks_fwov -o ro,lowerdir=$T:/vendor/firmware/kiwi /vendor/firmware/kiwi || { back_to_stock; fail "firmware overlay"; }
  for f in $FW; do chmod 644 $A/fw/$f; chcon u:object_r:vendor_firmware_file:s0 $A/fw/$f
    mount -o bind,ro $A/fw/$f /vendor/firmware/kiwi/$f || { back_to_stock; fail "firmware bind $f"; }; done
  insmod $A/kiwi_v2.ko || { back_to_stock; fail "S24 Wi-Fi driver: $(dmesg | tail -2 | tr '\n' ' ')"; }
  wifi_up; sleep 5
  # bwfix: the S24 firmware asks for a PCIe Gen3 link when AirDrop starts; the S23 refuses (Gen2
  # max) and the firmware crashes on the refusal. bwfix sets Gen2 and acknowledges.
  cb=$(ksym cnss_mhi_bw_scale.cfi_jt cnss2)
  [ -d /sys/module/bwfix ] || insmod $A/bwfix.ko ${cb:+orig=0x$cb} || fail "bwfix: $(dmesg | tail -2 | tr '\n' ' ')"
  insmod $A/wonder.ko || fail "wonder: $(dmesg | tail -3 | tr '\n' ' ')"
  log "airdrop: kernel side loaded ($(dmesg | grep -o 'wonder: connected to wlan.*' | tail -1))"
}

# ---------- wifi7: Wi-Fi 7 multi-link (MLO) as a Wi-Fi client ----------
# The S24 driver (airdrop) has MLO built in, but the S23's wpa_supplicant has no 802.11be/MLO code
# and the S23's driver config doesn't turn MLO on. Use the S24's wpa_supplicant (same Samsung HAL
# extensions; it needs one AIDL library the S23 vendor image lacks, added to /vendor/lib64 with a
# read-only RAM overlay) and the S23's own driver config plus the S24's four MLO lines.
W7=$LY/mlo; INI=/vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini; WPAS=/vendor/bin/hw/wpa_supplicant
MLO_INI="mlo_support_link_num=2 mlo_5gl_5gh_mlsr=1 oem_eht_mlo_crypto_bitmap=0 epcs_support_enable=1"
wifi7_bind() {   # sets W7_INI_NEW=1 when the driver has to be reloaded to read the config
  A=$AIR/wifi7
  ly_init; mkdir -p $W7
  if ! bound $WPAS; then
    pbind $A/wpa_supplicant $WPAS hal_wifi_supplicant_default_exec exec
  fi
  if ! mounted /vendor/lib64 overlay; then
    WL=/dev/s23tweaks_mlolib; SO=android.hardware.wifi.supplicant-V2-ndk.so
    mkdir -p $WL; mounted $WL tmpfs || mount -t tmpfs -o mode=755 s23tweaks_mlolib $WL
    : > $WL/$SO; chmod 644 $WL/$SO; chcon u:object_r:vendor_file:s0 $WL $WL/$SO
    mount -t overlay s23tweaks_mlolib -o ro,lowerdir=$WL:/vendor/lib64 /vendor/lib64 || { umount $WPAS; fail "wifi7: library overlay"; }
    pbind $A/$SO /vendor/lib64/$SO vendor_file
  fi
  if ! bound $INI; then
    lab=$(ls -Z $INI | cut -d' ' -f1); cp $INI $W7/ini
    for kv in $MLO_INI; do grep -q "^${kv%%=*}=" $W7/ini || sed -i "/^END$/i $kv" $W7/ini; done
    grep -q "^mlo_support_link_num=" $W7/ini || fail "wifi7: no END marker in $INI"
    chmod 644 $W7/ini; chcon $lab $W7/ini; mount --bind $W7/ini $INI || fail "wifi7: bind driver config"
    W7_INI_NEW=1
  fi
  log "wifi7: S24 wpa_supplicant and MLO driver settings in place"
}
wifi7_unbind_sup() { bound $WPAS && umount $WPAS; mounted /vendor/lib64 overlay && umount /vendor/lib64; }
wifi7_reload() {   # the AirDrop driver was already loaded before the config was bound
  log "wifi7: reloading the Wi-Fi driver so it reads the MLO settings (Wi-Fi drops for ~15 s)"
  wifi_down
  insmod $AIR/kiwi_v2.ko || { back_to_stock; fail "wifi7: kiwi_v2 reload: $(dmesg | tail -2 | tr '\n' ' ')"; }
  wifi_up
  insmod $AIR/wonder.ko || fail "wonder: $(dmesg | tail -3 | tr '\n' ' ')"
}
wifi7_check() {
  # If Wi-Fi can't run with the S24 supplicant, go back to the S23's and carry on without MLO
  wait_for 60 wlan_up; wait_for 90 connected
  if [ "$(getprop init.svc.wpa_supplicant)" = running ] && cmd wifi status | grep -q "Wifi is enabled" &&
     [ "$(md5 /proc/$(pidof wpa_supplicant)/exe)" = "$(md5 $AIR/wifi7/wpa_supplicant)" ]; then
    log "wifi7: Wi-Fi running with the S24 supplicant ($(cmd wifi status | grep -oE 'Wi-Fi standard: [^,]*' | head -1))"
  else
    log "wifi7: warning: Wi-Fi didn't come up with the S24 supplicant; switching back to the S23 one (no MLO)"
    cmd wifi set-wifi-enabled disabled; wait_for 15 wifi_off; wait_for 20 sup_stopped; wifi7_unbind_sup
    cmd wifi set-wifi-enabled enabled; wait_for 60 wlan_up
  fi
}
connected() { cmd wifi status | grep -q "Supplicant state: COMPLETED"; }

# ---------- airdrop: Mosey (Google's AirDrop stack from the S24) ----------
airdrop_overlays() {
  bound /system_ext/bin && { log "airdrop: Mosey already in /system_ext"; return 1; }
  M=$AIR/mosey; T=/dev/s23tweaks_mosey
  mkdir -p $T; mounted $T tmpfs || mount -t tmpfs -o mode=755 s23tweaks_mosey $T
  mkdir -p $T/bin $T/lib64 $T/priv-app/MoseyApp $T/perm $T/sysconfig $T/vintf
  # the three big files are placeholders here, bound to the download below; the XMLs are a few KB
  : > $T/bin/mosey_server; : > $T/lib64/libmosey_daemon_ffi.so; : > $T/priv-app/MoseyApp/MoseyApp.apk
  cp $M/privapp-permissions-com.google.android.mosey.xml $T/perm/
  cp $M/preinstalled-packages-com.google.android.mosey.xml $M/hiddenapi-allowlist-mosey.xml $T/sysconfig/
  cp $M/manifest_mosey.xml $T/vintf/
  chmod -R 755 $T; find $T -type f -exec chmod 644 {} +; chmod 755 $T/bin/mosey_server
  chcon -R u:object_r:system_file:s0 $T
  chcon u:object_r:system_lib_file:s0 $T/lib64 $T/lib64/libmosey_daemon_ffi.so
  chcon u:object_r:mosey_server_exec:s0 $T/bin/mosey_server
  for p in "bin /system_ext/bin" "lib64 /system_ext/lib64" "priv-app /system_ext/priv-app" \
           "perm /system_ext/etc/permissions" "sysconfig /system_ext/etc/sysconfig" "vintf /system_ext/etc/vintf/manifest"; do
    set -- $p
    mount -t overlay s23tweaks_$1 -o ro,lowerdir=$T/$1:$2 $2 || fail "overlay on $2"
  done
  pbind $M/mosey_server /system_ext/bin/mosey_server mosey_server_exec exec
  pbind $M/libmosey_daemon_ffi.so /system_ext/lib64/libmosey_daemon_ffi.so system_lib_file
  pbind $M/MoseyApp.apk /system_ext/priv-app/MoseyApp/MoseyApp.apk system_file
  log "airdrop: Mosey added to /system_ext (overlay)"
}

airdrop_post() {
  # On the S24 a default-permissions file pre-grants these; Quick Share only starts Mosey when
  # every dangerous permission Mosey asks for is granted.
  for p in BLUETOOTH_SCAN BLUETOOTH_ADVERTISE NEARBY_WIFI_DEVICES ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION \
           ACCESS_BACKGROUND_LOCATION ACCESS_MEDIA_LOCATION ACCESS_LOCAL_NETWORK READ_MEDIA_VISUAL_USER_SELECTED; do
    pm grant --user 0 com.google.android.mosey android.permission.$p 2>/dev/null
  done
  den=$(dumpsys package com.google.android.mosey | sed -n '/User 0:/,/User [1-9]/p' | grep -c granted=false)
  [ "$den" = 0 ] || log "airdrop: warning: $den Mosey permissions are still denied"
  # libvintf caches the VINTF manifests keyed on this file's mtime; touching it makes servicemanager
  # pick up manifest_mosey.xml (IMoseyService/default). Never restart servicemanager itself: Android
  # then reboots with "checkpoint_commit_failed".
  touch /apex/apex-info-list.xml
  running loop || setsid sh $D/tweaks.sh loop </dev/null >/dev/null 2>&1 &
  running guard || setsid sh $D/tweaks.sh guard </dev/null >/dev/null 2>&1 &
  n=20; until service check com.google.android.moseyservice.IMoseyService/default | grep -q found; do
    n=$((n-1)); [ $n = 0 ] && fail "IMoseyService did not register"; sleep 1; done
  log "airdrop: mosey_server running"
  gms_flags
}

# Play services only binds Mosey when two server-side Nearby flags are on. Add them as local
# overrides (account 0 = the device) and patch the current flag snapshot so they apply right away.
gms_flags() {
  G=/data/data/com.google.android.gms; DB=$G/databases/phenotype.db
  SNAP=$G/files/phenotype/shared/com.google.android.gms.nearby.pb
  SQ=$AIR/sqlite3; W=$R/gms; rm -rf $W; mkdir -p $W $V/backup
  if [ ! -f $DB ]; then
    # Before the first unlock after a boot, app storage is still encrypted. The overrides set on an
    # earlier run are stored in Play services' database and stay in effect, so nothing is lost.
    if [ "${S23T_BOOT:-0}" = 1 ]; then log "airdrop: Play services storage is locked until first unlock; flags from the earlier run stay on"
    else log "airdrop: Play services database not found; flags not set"; fi
    return
  fi
  # edit a copy (opening the live WAL database as root would leave root-owned -wal/-shm files)
  am force-stop com.google.android.gms
  cp $DB $W/p.db; [ -f $DB-wal ] && cp $DB-wal $W/p.db-wal
  [ -f $V/backup/phenotype.db ] || cp $W/p.db* $V/backup/ 2>/dev/null
  id=$($SQ $W/p.db "select config_package_id from config_packages where name='com.google.android.gms.nearby'")
  [ -n "$id" ] || { log "airdrop: Play services has no Nearby config yet; open Quick Share once and run again"; return; }
  sql="PRAGMA integrity_check;"
  for f in $NEARBY_FLAGS; do
    sql="$sql INSERT OR IGNORE INTO flag_overrides (config_package_id, account_id, name, value, type, source) VALUES ($id, 0, '$f', 1, 2, 0);"
  done
  sql="$sql INSERT OR IGNORE INTO experiment_states_to_overrides (experiment_state_id, override_id)
    SELECT s.experiment_state_id, o.override_id FROM experiment_states s, flag_overrides o
    WHERE s.config_package_id=$id AND o.config_package_id=$id AND o.name IN ('${NEARBY_FLAGS% *}', '${NEARBY_FLAGS#* }');
    PRAGMA wal_checkpoint(TRUNCATE);"
  ok=$($SQ $W/p.db "$sql" | head -1)
  [ "$ok" = ok ] || { log "airdrop: Play services database check failed ($ok); flags not set"; return; }
  n=$($SQ $W/p.db "select count(*) from flag_overrides where config_package_id=$id and name in ('${NEARBY_FLAGS% *}', '${NEARBY_FLAGS#* }') and value=1")
  am force-stop com.google.android.gms
  cat $W/p.db > $DB && rm -f $DB-wal $DB-shm    # cat keeps the file's owner and SELinux label
  if [ -f $SNAP ]; then
    cp $SNAP $W/s0.pb
    $AIR/pbflag $W/s0.pb $W/s1.pb ${NEARBY_FLAGS% *} 1 >/dev/null && \
    $AIR/pbflag $W/s1.pb $W/s2.pb ${NEARBY_FLAGS#* } 1 >/dev/null && cat $W/s2.pb > $SNAP
  fi
  rm -rf $W
  log "airdrop: Play services Nearby flags on ($n of 2 overrides present)"
}

# ---------- Samsung feature flags (battery, features, display, logvideo) ----------
# ff_tags: tags turned on (TRUE), added if the stock file lacks them or set TRUE if it has them as FALSE.
# ff_set TAG VALUE: set a tag to a value, replacing the stock one (values may contain spaces).
ff_tags=""; ff_kv=""
ff_set() { case "$2" in *'&'*|*'
'*) fail "ff_set $1: value has & or a newline" ;; esac; ff_kv="$ff_kv$1=$2
"; }
ff_apply() {
  [ -z "$ff_tags" ] && [ -z "$ff_kv" ] && return 1
  mkdir -p $R; bound $FF && umount $FF       # rebuild from the stock file each time
  for t in $ff_tags; do grep -q "<SEC_FLOATING_FEATURE_$t>TRUE<" $FF || ff_set $t TRUE; done
  printf '%s' "$ff_kv" > $R/ff.kv
  # replace the values of tags the file has; add the rest before the closing tag
  awk -v kvf=$R/ff.kv '
    BEGIN { while ((getline l < kvf) > 0) { i = index(l, "="); k = substr(l, 1, i - 1); val[k] = substr(l, i + 1); ord[++n] = k } }
    match($0, /<SEC_FLOATING_FEATURE_[A-Z0-9_]+>/) { k = substr($0, RSTART + 22, RLENGTH - 23)
      if (k in val) { $0 = substr($0, 1, RSTART + RLENGTH - 1) val[k] "</SEC_FLOATING_FEATURE_" k ">"; seen[k] = 1 } }
    /<\/SecFloatingFeatureSet>/ { for (i = 1; i <= n; i++) if (!(ord[i] in seen))
      print "    <SEC_FLOATING_FEATURE_" ord[i] ">" val[ord[i]] "</SEC_FLOATING_FEATURE_" ord[i] ">" }
    { print }' $FF > $R/ff.new
  grep -q '</SecFloatingFeatureSet>' $R/ff.new || fail "floating_feature edit"
  mv $R/ff.new $R/floating_feature.xml; chmod 644 $R/floating_feature.xml
  chcon u:object_r:system_file:s0 $R/floating_feature.xml
  mount --bind $R/floating_feature.xml $FF || fail "floating_feature bind mount"
  log "feature flags on: $(printf '%s' "$ff_kv" | cut -d= -f1 | tr '\n' ' ')"
}

# Camera settings added on top of the phone's own camera-feature.xml (rebuilt from stock each apply):
#  logvideo: the S24's Log recording and LUT preview in Pro video (the S23's sensor/HAL already
#            records 10-bit Log)
#  camextras: Super steady's horizontal lock (a third Super steady option, recorded fine on the S23)
# Never add SUPPORT_BACK_WIDE_NORMAL_DUAL_PORTRAIT_VIDEO, SUPPORT_BACK_PORTRAIT_VIDEO_TELE_DUAL or
# CAMERA_SUPPORT_SEAMLESS_PORTRAITVIDEO: on the S23 they crash the camera ("Zoom is not supported").
CF_LOG='<local name="SUPPORT_LOG_VIDEO" value="true"/>
<local name="SUPPORT_PREVIEW_LUT" value="true"/>'
CF_HLOCK='<local name="SUPPORT_SUPER_STEADY_HORIZONTAL_LOCK" value="true"/>'
cf_add=""
camfeat_apply() {
  [ -n "$cf_add" ] || return 1
  mkdir -p $R; bound $CF && umount $CF
  grep -q '</resources>' $CF || { log "camera: $CF has no </resources>; camera settings skipped"; return 1; }
  grep -v '</resources>' $CF > $R/cf.new
  printf '%s\n' "$cf_add" | while read -r l; do
    [ -n "$l" ] || continue
    n=$(echo "$l" | sed 's/.*name="\([^"]*\)".*/\1/'); grep -q "name=\"$n\"" $CF || echo "    $l" >> $R/cf.new
  done
  echo '</resources>' >> $R/cf.new
  mv $R/cf.new $R/camera-feature.xml; chmod 644 $R/camera-feature.xml
  chcon u:object_r:system_file:s0 $R/camera-feature.xml
  mount --bind $R/camera-feature.xml $CF || fail "camera-feature bind mount"
  log "camera settings on: $(printf '%s\n' "$cf_add" | sed -n 's/.*name="\([^"]*\)".*/\1/p' | tr '\n' ' ')"
}

# Director's view (front and back camera at once; the S23 had it in 2023). One UI 9 still ships the
# mode but hides it: modes marked enable="false" show only when the camera's own settings hold
# <mode>=1. A camera app setting, kept in its data folder (a reboot doesn't undo it; Camera > More >
# edit can hide the mode again). Not dual_recording_mode: the S24's Dual rec can't open the S23's
# cameras ("Unable to open Camera").
CAM_PREFS=/data/user/0/com.sec.android.app.camera/shared_prefs/com.sec.android.app.camera_preferences.xml
directorsview_pref() {
  if [ ! -f $CAM_PREFS ]; then
    if [ "${S23T_BOOT:-0}" = 1 ]; then log "camextras: app storage is locked until first unlock; Director's view stays as the last apply left it"
    else log "camextras: open the Camera app once, then apply again to show Director's view"; fi
    return
  fi
  grep -q '<string name="directors_view_mode">1</string>' $CAM_PREFS && { log "camextras: Director's view already shown"; return; }
  am force-stop com.sec.android.app.camera
  mkdir -p $R $V/backup $V/undo; [ -f $V/backup/camera_preferences.xml ] || cp $CAM_PREFS $V/backup/camera_preferences.xml
  # for "cleanup": the value before the first change, or "absent"
  [ -f $V/undo/directors_view ] || { v=$(sed -n 's|.*<string name="directors_view_mode">\([^<]*\)</string>.*|\1|p' $CAM_PREFS); echo "${v:-absent}" > $V/undo/directors_view; }
  if grep -q 'name="directors_view_mode"' $CAM_PREFS; then
    sed 's|<string name="directors_view_mode">[^<]*</string>|<string name="directors_view_mode">1</string>|' $CAM_PREFS > $R/camprefs.new
  else
    awk '/<\/map>/ { print "    <string name=\"directors_view_mode\">1</string>" } { print }' $CAM_PREFS > $R/camprefs.new
  fi
  grep -q '<string name="directors_view_mode">1</string>' $R/camprefs.new && grep -q '</map>' $R/camprefs.new ||
    { rm -f $R/camprefs.new; log "camextras: couldn't edit the camera settings; Director's view skipped"; return; }
  cat $R/camprefs.new > $CAM_PREFS; rm -f $R/camprefs.new   # cat keeps the file's owner and label
  log "camextras: Director's view shown (Camera > More)"
}

# ---------- Payload tweaks: camerahdr, audioeraser, colortone, galaxyai (files in $D/payload/<tweak>) ----------
# Linux stacks at most two overlays on a path, so the tweaks don't mount their own. Each one stages the
# files the phone doesn't show yet into $T24/new/<folder> (stage, stage_text); layers_mount then puts one
# overlay per folder on /system/<folder>. Overlays merge subfolders, so etc/permissions rides on the
# /system/etc layer. An overlay hides whatever is mounted inside its folder, so layers_mount puts
# those mounts back on top (keep_mounts), and the tweaks' own single-file binds come after it. Each step checks what the phone shows, not the mount table, so a re-apply only adds what's
# missing.
tlayer() { mkdir -p $T24; mounted $T24 tmpfs || mount -t tmpfs -o mode=755 s23tweaks_layers $T24; }
same_size() { [ "$(stat -c %s "$1" 2>/dev/null)" = "$(stat -c %s "$2" 2>/dev/null)" ]; }
# stage <folder under /system> <source file>: add the file to the next layer unless /system shows it. The
# layer gets an empty placeholder; layers_mount binds the downloaded file over it (no copy in RAM).
stage() {
  [ -e /system/$1/${2##*/} ] && return 1; tlayer; mkdir -p $T24/new/$1
  : > $T24/new/$1/${2##*/} && echo "$2 /system/$1/${2##*/}" >> $T24/new.binds || fail "stage $2"
}
# stage_text <file under /system>: write stdin to the next layer in place of that file
stage_text() { tlayer; mkdir -p $T24/new/${1%/*}; cat > $T24/new/$1; }
# An overlay on a folder hides whatever is mounted inside it (other modules' files, earlier binds).
# keep_mounts parks each such mount on a spare path first; keep_restore mounts it back on top of the
# new layer, parents before children, in the order the kernel lists them.
keep_mounts() {
  K=$T24/keep; rm -rf $K; mkdir -p $K; i=0
  awk -v p="$1/" 'index($2, p) == 1 && $2 !~ /\\/ && !seen[$2]++ {print $2}' /proc/mounts > $T24/keep.list
  while read m; do i=$((i+1))
    if [ -d "$m" ]; then mkdir $K/$i; else : > $K/$i; fi
    mount --bind "$m" $K/$i || fail "keep $m"
  done < $T24/keep.list
}
keep_restore() {
  i=0
  while read m; do i=$((i+1))
    mount --bind $K/$i "$m" || fail "put back $m"
    umount $K/$i
  done < $T24/keep.list
  [ $i = 0 ] || log "kept $i mounts inside the new layer: $(tr '\n' ' ' < $T24/keep.list)"
  rm -rf $K $T24/keep.list
}
layers_mount() {
  [ -d $T24/new ] || return 1
  n=1; while [ -e $T24/L$n ]; do n=$((n+1)); done
  mv $T24/new $T24/L$n; LD=$T24/L$n   # not L: that is the log file
  [ -f $T24/new.binds ] && mv $T24/new.binds $LD.binds
  find $LD -type d -exec chmod 755 {} +; find $LD -type f -exec chmod 644 {} +
  chcon -R u:object_r:system_file:s0 $LD; [ -d $LD/lib64 ] && chcon -R u:object_r:system_lib_file:s0 $LD/lib64
  for d in $LD/*; do d=${d##*/}
    [ -d /system/$d ] || fail "no /system/$d"
    keep_mounts /system/$d
    mount -t overlay s23tweaks_$d$n -o ro,lowerdir=$LD/$d:/system/$d /system/$d ||
      { keep_restore; fail "overlay on /system/$d (if tweaks were already added since the last reboot, reboot and apply again)"; }
    keep_restore
    log "layer on /system/$d: $(cd $LD/$d && find . -type f | sed 's|^\./||' | tr '\n' ' ')"
  done
  [ -f $LD.binds ] && while read src dst; do
    case "$dst" in /system/lib64/*) ty=system_lib_file ;; *) ty=system_file ;; esac
    pbind "$src" "$dst" $ty
  done < $LD.binds
  return 0
}
pl_check() {   # pl_check <tweak> <file>...: all present in payload/<tweak>?
  t=$1; shift
  for f in "$@"; do [ -f $PL/$t/$f ] || { log "$t: its download is missing $f; skipped"; return 1; }; done
}
# bind_file <source> <target> <label>: bind one file unless the target already shows the same size
bind_file() {
  same_size "$2" "$1" && return 1
  chmod 644 "$1"; chcon u:object_r:$3:s0 "$1"
  mount -o bind,ro "$1" "$2" || fail "bind $2"
}

# Camera HDR processing (untested; see docs/findings.md). One UI 9 dropped the S23's ArcSoft
# multi-frame HDR and low-light HDR steps: their entries in CAMERA_CONFIG_VENDOR_LIB_INFO and both
# libraries. The camera app still has both steps and, with them unlisted, runs a pass-through dummy
# instead. Put back the 2023 (One UI 6, S918WVLS2BWKA) libraries, their public-library lines and the
# two list entries. The flag file is cached per process, so this goes through the framework restart.
CH_LIBS="libhigh_dynamic_range.arcsoft.so liblow_light_hdr.arcsoft.so"
CH_MD5="c6b7aa034c3704dcfccc87ca32582dc6 656c3c400bb9ebf74a05e23865c334cb"
CH_PUB=public.libraries-arcsoft.txt
CH_KEY=CAMERA_CONFIG_VENDOR_LIB_INFO
camerahdr_stage() {
  set -- $CH_MD5
  for f in $CH_LIBS; do
    [ "$(md5sum $PL/camerahdr/$f 2>/dev/null | cut -d' ' -f1)" = "$1" ] || { log "camerahdr: its download is missing $f (or it's damaged); skipped"; return 1; }
    shift
  done
  v=$(grep -o "<SEC_FLOATING_FEATURE_$CH_KEY>[^<]*" $FF | cut -d'>' -f2)
  [ -n "$v" ] || { log "camerahdr: $FF has no $CH_KEY; skipped"; return 1; }
  case ",$v," in *,mfhdr.arcsoft.v4,*) ;; *) v="$v,mfhdr.arcsoft.v4" ;; esac
  case ",$v," in *,llhdr.arcsoft.v4,*) ;; *) v="$v,llhdr.arcsoft.v4" ;; esac
  ff_set $CH_KEY "$v"
  for f in $CH_LIBS; do stage lib64 $PL/camerahdr/$f; done
  if [ -f /system/etc/$CH_PUB ] && ! grep -q '^liblow_light_hdr.arcsoft.so' /system/etc/$CH_PUB; then
    { cat /system/etc/$CH_PUB; printf '%s\n' $CH_LIBS; } | stage_text etc/$CH_PUB
  fi
  am force-stop com.sec.android.app.camera
  log "camerahdr: One UI 6 multi-frame HDR and low-light HDR on"
  return 0   # the list entry needs the framework restart that follows the flag file
}

# Audio Eraser (Gallery > video > Edit > Audio eraser). The S23's video editor engine was built with
# its audio scanner compiled out ("AudioScanner is not supported"), and the S23 lacks the S24's
# sound-separation libraries and models. Only Gallery's video editor loads the engine.
AE_LIBS="libsbs.so libtensorflowlite_gpu_delegate.so libmultisourceseparator.so libmultisourceseparator.audio.samsung.so"
AE_ETC="public.libraries-audio.samsung.txt mss_v0.23.0_VMWO_2_fp32.sorione fastScanner.tflite"
VE=libveframework.videoeditor.samsung.so
audioeraser_stage() {
  pl_check audioeraser $AE_LIBS $AE_ETC $VE || return 1
  ff_set AUDIO_CONFIG_MULTISOURCE_SEPARATOR '{FastScanning_6, SourceSeparator_4, Version_1.3.0}'
  for f in $AE_LIBS; do stage lib64 $PL/audioeraser/$f; done
  for f in $AE_ETC; do stage etc $PL/audioeraser/$f; done
  return 0
}
audioeraser_bind() {
  bind_file $PL/audioeraser/$VE /system/lib64/$VE system_lib_file && am force-stop com.sec.android.app.vepreload
  log "audioeraser: S24 video editor engine, sound-separation libraries and models on"
}

# Adaptive Color Tone (Settings > Display). Samsung compiled the S23's Settings to report it as
# unsupported (SecEADPreferenceController.getAvailabilityStatus() returns 3): patch that byte in a RAM
# copy of Settings, and add the S24's colour-tone service (com.samsung.android.sead), which drives the
# display from the S23's own colour light sensor.
EAD=EnvironmentAdaptiveDisplay
EAD_PERM=privapp-permissions-com.samsung.android.sead.xml
colortone_stage() {
  pl_check colortone $EAD.apk $EAD_PERM || return 1
  [ -z "$(ead_row)" ] || [ -f $D/files/SecSettings-ead-$(getprop ro.build.PDA).patch ] || fail "colortone: files/SecSettings-ead-$(getprop ro.build.PDA).patch missing"
  [ -f /system/priv-app/$EAD/$EAD.apk ] || stage priv-app/$EAD $PL/colortone/$EAD.apk
  stage etc/permissions $PL/colortone/$EAD_PERM
  return 0
}
colortone_bind() {
  sm=$(md5sum $SETTINGS | cut -d' ' -f1)
  set -- $(ead_row); eb=$1; SETTINGS_STOCK_MD5=${2:-none}; SETTINGS_EAD_MD5=${3:-none}
  if [ "$sm" = $SETTINGS_EAD_MD5 ]; then :   # already patched (an earlier apply this boot)
  elif [ "$sm" != $SETTINGS_STOCK_MD5 ]; then
    log "colortone: Settings isn't the $(ead_builds) build, so the Adaptive color tone switch stays hidden"; return
  else
    P=$PL/colortone/SecSettings.apk   # the patched copy stays on storage and is reused at the next boot
    if [ "$(md5sum $P 2>/dev/null | cut -d' ' -f1)" != $SETTINGS_EAD_MD5 ]; then
      cp $SETTINGS $P.new
      grep -v '^#' $D/files/SecSettings-ead-$eb.patch | while read off oct; do
        printf "\\$oct" | dd of=$P.new bs=1 seek=$off conv=notrunc 2>/dev/null; done
      [ "$(md5sum $P.new | cut -d' ' -f1)" = $SETTINGS_EAD_MD5 ] || { rm -f $P.new; fail "colortone: Settings patch gave the wrong file"; }
      mv $P.new $P
    fi
    chmod 644 $P; chcon u:object_r:system_file:s0 $P
    mount -o bind,ro $P $SETTINGS || fail "colortone: bind $SETTINGS"
    am force-stop com.android.settings
  fi
  log "colortone: Adaptive color tone on (Settings > Display)"
}

# Now Brief, Creative Studio, Call Assist: the S24 firmware ships newer builds of these three apps.
# Bind each S24 APK over the S23 firmware copy and drop its parse-cache entry (the cache is keyed on
# the folder's time, so the new APK would be ignored), then the framework restart rescans them.
# Samsung's installer refuses these platform-signed builds as normal updates. Side effect: a newer
# firmware copy replaces any Galaxy Store update of Personal Data Intelligence; after a reboot without
# this tweak, Galaxy Store offers its update again.
GAI_APPS="priv-app/SamsungSmartSuggestions app/SketchBook priv-app/CallAssistant"
galaxyai_stage() {
  for p in $GAI_APPS; do n=${p#*/}
    pl_check galaxyai $n.apk || return 1
    [ -f /system/$p/$n.apk ] || { log "galaxyai: this phone has no /system/$p/$n.apk; skipped"; return 1; }
  done
  ff_set FRAMEWORK_SUPPORT_PERSONALIZED_DATA_CORE TRUE; ff_set FRAMEWORK_CONFIG_NOW_NUDGE_VERSION 2
  ff_set COMMON_CONFIG_AI_VERSION 20263
  return 0
}
galaxyai_bind() {
  for p in $GAI_APPS; do n=${p#*/}
    bind_file $PL/galaxyai/$n.apk /system/$p/$n.apk system_file && rm -f /data/system/package_cache/*/$n-16-*
  done
  log "galaxyai: S24 Now Brief (Personal Data Intelligence), Creative Studio and Call Assist on"
}
# Settings search: the S24's Settings search app (com.android.settings.intelligence, same signature).
# Its new search bar shows; the semantic ("natural language") answers stay off, because they need
# Samsung's Semantic Search Core 4.x and both phones ship only a 1.0 stub.
SSI=priv-app/SecSettingsIntelligence
settingssearch_stage() {
  pl_check settingssearch SecSettingsIntelligence.apk || return 1
  [ -f /system/$SSI/SecSettingsIntelligence.apk ] || { log "settingssearch: this phone has no /system/$SSI; skipped"; return 1; }
  return 0
}
settingssearch_bind() {
  bind_file $PL/settingssearch/SecSettingsIntelligence.apk /system/$SSI/SecSettingsIntelligence.apk system_file &&
    rm -f /data/system/package_cache/*/SecSettingsIntelligence-16-*
  log "settingssearch: S24 Settings search on"
}

# Call screening (Phone app). Needs Samsung Language Core (com.samsung.android.offline.languagemodel);
# the S23 firmware has none and Galaxy Store refuses the S23 (9908). Install the real one (Samsung-signed)
# as an ordinary app. Persistent (survives reboot); undo with pm uninstall $LC_PKG (not
# uninstall-system-updates: it isn't an update of a system app here). Its 3.1 GB download comes in two parts (GitHub caps a file at 2 GB)
# and is deleted once installed. What works: screening, the greeting,
# the voice message. What doesn't: the AI summary and AI replies, since Samsung's model only exists for
# the S26's NPU; on the S23 it fails safely (no V73 stub, nothing reaches the DSP). See docs/findings.md.
LC_PKG=com.samsung.android.offline.languagemodel
LC_APK=languagecore-4.0.01.24.apk
LC_MD5=994620f3071706391d17ff132ea16c42
lc_ok() { [ "$(lc_installed)" -ge 400000000 ] 2>/dev/null; }
lc_installed() { dumpsys package $LC_PKG 2>/dev/null | grep -m1 -oE 'versionCode=[0-9]+' | cut -d= -f2; }
callscreen_apply() {
  lc_ok && { log "callscreen: Language Core $(lc_installed) already installed"; return 0; }
  A=$PL/callscreen/$LC_APK
  [ -f $A ] || { log "callscreen: its download isn't there; skipped"; return 1; }
  [ "$(md5 $A)" = $LC_MD5 ] || { rm -rf $PL/callscreen; log "callscreen: the download is damaged; deleted, apply again to fetch it"; return 1; }
  log "callscreen: installing Samsung Language Core 4.0.01.24 (a minute or two)"
  # streamed through stdin: the installer can't read files under /data/adb
  r=$(pm install -r -S $(stat -c %s $A) < $A 2>&1)
  case "$r" in
    *Success*) rm -rf $PL/callscreen; mkdir -p $V/undo; touch $V/undo/languagecore; log "callscreen: Language Core installed; turn on Phone > Settings > Call screening" ;;
    *) log "callscreen: install failed: $r" ;;
  esac
}

# payload_fetch: download and unpack the files of each picked tweak that has them, unless the
# unpacked copy already matches the pinned checksum. A failed download skips that tweak, not the rest.
dl() {   # dl <url> <file>: curl if the phone has it, else KernelSU's busybox wget
  if command -v curl >/dev/null; then curl -fsSL --retry 2 -o "$2" "$1"
  else for b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox; do [ -x $b ] && { $b wget -q -O "$2" "$1"; return; }; done; return 1; fi
}
payload_fetch() {
  for t in $(echo "$PAYLOADS" | awk '{print $1}' | uniq); do
    has $t || continue
    [ $t = callscreen ] && lc_ok && continue      # installed already; its 3.1 GB isn't kept
    sums=$(echo "$PAYLOADS" | awk -v t=$t '$1 == t {print $3}' | tr '\n' ' ' | sed 's/ $//')
    [ "$(cat $PL/$t/.sha256 2>/dev/null)" = "$sums" ] && continue
    mkdir -p $V/dl
    [ $t = callscreen ] && [ "$(df -k /data | awk 'NR == 2 {print $4}')" -lt 7340032 ] &&
      { log "$t: needs 7 GB free on the phone for its download; skipped"; continue; }
    parts=""; ok=1
    for f in $(echo "$PAYLOADS" | awk -v t=$t '$1 == t {print $2}'); do
      sum=$(echo "$PAYLOADS" | awk -v f=$f '$2 == f {print $3}'); z=$V/dl/$f
      if [ "$(sha256sum $z 2>/dev/null | cut -d' ' -f1)" != "$sum" ]; then
        log "$t: downloading $f"
        rm -f $z; dl "$PAYLOAD_URL/$f" $z.part && mv $z.part $z || { rm -f $z.part; log "$t: download failed (no internet?); skipped"; ok=0; break; }
        [ "$(sha256sum $z | cut -d' ' -f1)" = "$sum" ] || { rm -f $z; log "$t: $f doesn't match its checksum; skipped"; ok=0; break; }
      fi
      parts="$parts $z"
    done
    [ $ok = 1 ] || continue
    rm -rf $PL/$t $PL/$t.new; mkdir -p $PL/$t.new
    case "$parts" in
      *.tar.gz) tar -xzf $parts -C $PL/$t.new ;;
      *) cat $parts | tar -xf - -C $PL/$t.new ;;
    esac || { rm -rf $PL/$t.new; log "$t: couldn't unpack its download; skipped"; continue; }
    echo "$sums" > $PL/$t.new/.sha256; mv $PL/$t.new $PL/$t; rm -f $parts
    if [ $t = airdrop ]; then
      chmod 755 $AIR/moseyrun $AIR/sqlite3 $AIR/pbflag
      chcon u:object_r:system_file:s0 $AIR/moseyrun   # its exec into mosey_server's domain needs this label
    fi
    log "$t: files ready"
  done
}

# stage everything, mount the layers, then the single-file binds; returns 0 if any payload tweak ran
payload_apply() {
  ran=1
  has camerahdr && camerahdr_stage && ran=0
  has audioeraser && audioeraser_stage && { ran=0; ae=1; }
  has colortone && colortone_stage && { ran=0; ct=1; }
  has galaxyai && galaxyai_stage && { ran=0; gai=1; }
  has settingssearch && settingssearch_stage && { ran=0; ssi=1; }
  layers_mount
  [ "${ae:-0}" = 1 ] && audioeraser_bind
  [ "${ct:-0}" = 1 ] && colortone_bind
  [ "${gai:-0}" = 1 ] && galaxyai_bind
  [ "${ssi:-0}" = 1 ] && settingssearch_bind
  return $ran
}

# Settings > Battery > Battery information shows health only when an authenticated battery IC
# (sec_auth) exists. Present one whose values mirror /efs/FactoryApp, so syncs are no-ops.
# batt_full_status_usage is optional: Android uses it only when the kernel reports BFSU, and some
# phones (e.g. an S918B) don't have it. Without it the auth IC simply has no such node.
BATT_EFS="HwParamBattQR batt_beginning_date asoc batt_discharge_level"
battery_auth() {
  PS=/sys/class/power_supply; T=/dev/s23tweaks_ps; E=/efs/FactoryApp
  mounted $PS tmpfs && { log "battery: auth IC already present"; return 0; }
  for f in $BATT_EFS; do
    [ -f $E/$f ] || { log "battery: $E/$f missing; skipping the battery health page"; return 1; }
  done
  [ -e $PS/sec_auth ] && { log "battery: this phone already has a battery auth IC"; return 0; }
  mkdir -p $T
  mount -t tmpfs -o mode=755,context=u:object_r:sysfs:s0 s23tweaks_ps $T
  for e in $(ls $PS); do ln -s "$(readlink $PS/$e)" $T/$e; done
  mkdir $T/sec_auth
  mount -t tmpfs -o mode=755,uid=1000,gid=1000,context=u:object_r:sysfs_battery:s0 s23tweaks_auth $T/sec_auth
  w() { printf '%s' "$1" > $T/sec_auth/$2; }
  w "$(cat $E/HwParamBattQR)" qr_code; w 1 presence; w 1 batt_auth
  w "$(cat $E/batt_beginning_date)" first_use_date; w 0 fai_expired; w "$(cat $E/asoc)" asoc
  w "$(cat $E/batt_discharge_level)" batt_discharge_level
  [ -f $E/batt_full_status_usage ] && w "$(cat $E/batt_full_status_usage)" batt_full_status_usage
  chown 1000:1000 $T/sec_auth/*; chmod 664 $T/sec_auth/*
  mount --rbind $T $PS || fail "power_supply overlay"
  log "battery: auth IC presented"
}

# ---------- CSC: india is XAC firmware only; callrec is XAC or a CALLREC_CSC sales code ----------
csc_check() {
  [ "$(getprop ro.csc.sales_code)" = XAC ] || { log "$1: needs XAC (Canadian) firmware; skipped"; return 1; }
  for p in "$XAC/system/cscfeature.xml $XAC_CSC_MD5" "$XAC/system/customer_carrier_feature.json $XAC_CCF_MD5" "$XAC/customer.xml $XAC_CUST_MD5"; do
    set -- $p; bound $1 && umount $1
    [ "$(md5 $1)" = $2 ] || { log "csc: $1 differs from S918WVLU8GZIF; skipped"; return 1; }
  done
  bound $PRISM && umount $PRISM
  return 0
}
csc_bind() { cp "$1" $R/$3; chmod 644 $R/$3; chcon u:object_r:vendor_configs_file:s0 $R/$3; mount --bind $R/$3 "$2" || fail "bind $2"; }
callrec_apply() {
  set -- $(callrec_row)
  if [ -n "$1" ]; then
    bound $3 && umount $3
    [ "$(md5 $3)" = $4 ] || { log "callrec: $3 differs from $2; skipped"; return 1; }
    mkdir -p $R; csc_bind $D/files/$5/cscfeature.xml $3 csc_callrec.xml
  else
    csc_check callrec || return 1; mkdir -p $R
    csc_bind $D/files/xac-callrec/cscfeature.xml $XAC/system/cscfeature.xml csc_xac.xml
  fi
  log "callrec: call recording on (Phone app > Settings > Record calls)"
}
india_apply() {
  csc_check india || return 1; mkdir -p $R; I=$D/files/ins
  csc_bind $I/cscfeature.xml $XAC/system/cscfeature.xml csc_ins.xml
  csc_bind $I/customer_carrier_feature.json $XAC/system/customer_carrier_feature.json ccf_ins.json
  csc_bind $I/customer.xml $XAC/customer.xml customer_ins.xml
  # prism: full copy of the XAC folder (sales_code.dat etc. unchanged) plus INS keystrings/images
  rm -rf $R/prism; mkdir $R/prism; cp -p $PRISM/* $R/prism/; cp $I/prism/* $R/prism/
  chmod 755 $R/prism; chmod 644 $R/prism/*; chcon -R u:object_r:vendor_configs_file:s0 $R/prism
  mount --bind $R/prism $PRISM || fail "bind $PRISM"
  log "india: INS carrier config on (sales code stays XAC)"
}

# Samsung's Mobile Hotspot only offers 6 GHz when the firmware's CSC country is on its list
# (SemWifiApServiceImpl.isRegionFor6GCountry). Most S23 CSCs aren't, though the hardware and the
# stock hostapd run a 6 GHz hotspot fine. IN passes on every Qualcomm phone. Runtime property only;
# the sales code is untouched. The radio still follows the real regulatory country.
hotspot6g_apply() {
  RP=/data/adb/ksu/bin/resetprop; [ -x $RP ] || { log "hotspot6g: KernelSU resetprop not found; skipped"; return 1; }
  c=$(getprop ro.csc.countryiso_code); [ "$c" = IN ] && { log "hotspot6g: already on"; return 0; }
  $RP ro.csc.countryiso_code IN && log "hotspot6g: CSC country $c -> IN; Mobile hotspot > Band now offers 6 GHz (needs WPA3)"
}

restart_framework() {
  old=$(pidof system_server); log "restarting the Android framework (screen goes black for ~30 s)"
  setprop ctl.restart zygote
  n=150; until p=$(pidof system_server) && [ -n "$p" ] && [ "$p" != "$old" ] && pm path android >/dev/null 2>&1; do
    n=$((n-1)); [ $n = 0 ] && fail "framework did not come back"; sleep 1; done
  sleep 10; log "framework back"
  # The restart parsed the bound APKs and cached the result in package_cache, under the stock app's name
  # and newer than the stock file. After a reboot (binds gone) Android would keep using that parse for
  # the stock app, and the app crashes looking for the other build's resources. Drop those entries so
  # the next boot parses the stock app again.
  for a in $(awk '$2 ~ /\.apk$/ {print $2}' /proc/mounts | sort -u); do
    n=${a%/*}; n=${n##*/}; rm -f /data/system/package_cache/*/$n-[0-9]*
  done
}

# ---------- Why a tweak can't run on this phone, and whether it's on (probe, apply log) ----------
phone_facts() {
  model=$(getprop ro.product.model); build=$(getprop ro.build.PDA); csc=$(getprop ro.csc.sales_code)
  gms=$(dumpsys package com.google.android.gms 2>/dev/null | grep -m1 -oE 'versionCode=[0-9]+' | cut -d= -f2)
  lcv=$(lc_installed)
}
# the XAC files the carrier tweaks replace must be S918WVLU8GZIF's (a bound one is the module's own)
csc_stock_ok() {
  for p in "$XAC/system/cscfeature.xml $XAC_CSC_MD5" "$XAC/system/customer_carrier_feature.json $XAC_CCF_MD5" "$XAC/customer.xml $XAC_CUST_MD5"; do
    set -- $p; bound $1 || [ "$(md5 $1)" = $2 ] || return 1
  done
}
# why_not TWEAK: print why it can't run on this phone (nothing if it can). Needs phone_facts.
why_not() {
  case "$model" in SM-S918*) ;; *) echo "this is for the Galaxy S23 Ultra (SM-S918*), not $model"; return ;; esac
  case $1 in
    airdrop|wifi7)
      kernel_supported || { echo "needs firmware $(echo $AIRDROP_FW | sed 's/ /, /g') (this phone runs $build)"; return; }
      [ "${gms:-0}" -ge $GMS_MIN ] || echo "needs Google Play services 26.11 or newer" ;;
    callrec|india)
      set -- $1 $(callrec_row)
      if [ $1 = callrec ] && [ -n "$2" ]; then
        bound $4 || [ "$(md5 $4)" = $5 ] || echo "needs the $2 carrier file of $3 (this phone runs $build)"; return
      fi
      [ $1 = callrec ] && [ "$csc" != XAC ] && { echo "needs XAC (Canadian) or EUX (European) firmware (this phone is $csc)"; return; }
      [ "$csc" = XAC ] || { echo "needs XAC (Canadian) firmware (this phone is $csc)"; return; }
      csc_stock_ok || echo "needs the XAC carrier files of S918WVLU8GZIF (this phone runs $build)" ;;
    battery)
      for f in $BATT_EFS; do [ -f /efs/FactoryApp/$f ] || { echo "this phone has no $f in /efs/FactoryApp"; return; }; done ;;
    colortone)
      [ -n "$(ead_row)" ] || echo "needs firmware $(ead_builds) (it patches that build's Settings app; this phone runs $build)" ;;
    hotspot6g) [ -x /data/adb/ksu/bin/resetprop ] || echo "needs KernelSU's resetprop" ;;
    camerahdr) grep -q "<SEC_FLOATING_FEATURE_$CH_KEY>[^<]" $FF 2>/dev/null || echo "this firmware has no $CH_KEY camera setting to add the HDR steps to" ;;
    logvideo|camextras) grep -q '</resources>' $CF 2>/dev/null || echo "this firmware's $CF can't be edited" ;;
    galaxyai)
      for p in $GAI_APPS; do [ -f /system/$p/${p#*/}.apk ] || { echo "this phone has no /system/$p/${p#*/}.apk to replace"; return; }; done ;;
    settingssearch) [ -f /system/$SSI/SecSettingsIntelligence.apk ] || echo "this phone has no /system/$SSI to replace" ;;
    callscreen)
      [ "${lcv:-0}" -ge 400000000 ] 2>/dev/null || [ "$(df -k /data | awk 'NR == 2 {print $4}')" -ge 7340032 ] ||
        echo "needs about 7 GB free on the phone for its 3.1 GB download" ;;
  esac
}
# is_on TWEAK: is it in effect right now?
is_on() {
  case $1 in
    airdrop) [ -d /sys/module/wonder ] && bound /system_ext/bin ;;
    battery) mounted /sys/class/power_supply tmpfs ;;
    features) bound $FF && grep -q SETTINGS_SUPPORT_AUTO_POWER_ON_OFF $FF 2>/dev/null ;;
    india) bound $PRISM ;;
    callrec) set -- $(callrec_row); bound ${3:-$XAC/system/cscfeature.xml} && ! bound $PRISM ;;
    hotspot6g) [ "$(getprop ro.csc.countryiso_code)" = IN ] ;;
    wifi7) bound $WPAS && bound $INI ;;
    display) bound $FF && grep -q "<SEC_FLOATING_FEATURE_LCD_CONFIG_VIVIDNESS>1<" $FF 2>/dev/null ;;
    logvideo) bound $CF && grep -q SUPPORT_LOG_VIDEO $CF 2>/dev/null ;;
    camextras) bound $CF && grep -q SUPPORT_SUPER_STEADY_HORIZONTAL_LOCK $CF 2>/dev/null ;;
    autoframe) grep -q "<SEC_FLOATING_FEATURE_CAMERA_CONFIG_AUTOFRAMING>uhd<" $FF 2>/dev/null ;;
    bargein) grep -q "<SEC_FLOATING_FEATURE_BIXBY_CONFIG_BARGEIN_PARAM_MODE>2<" $FF 2>/dev/null ;;
    settingssearch) bound /system/$SSI/SecSettingsIntelligence.apk ;;
    callscreen) [ "$(lc_installed)" -ge 400000000 ] 2>/dev/null ;;
    vulkan) [ "$(getprop debug.hwui.renderer)" = skiavk ] ;;
    camerahdr) grep -q 'mfhdr.arcsoft.v4' $FF 2>/dev/null && [ -f /system/lib64/liblow_light_hdr.arcsoft.so ] ;;
    audioeraser) [ -f /system/etc/fastScanner.tflite ] ;;
    colortone) bound $SETTINGS ;;
    galaxyai) bound /system/priv-app/SamsungSmartSuggestions/SamsungSmartSuggestions.apk ;;
    *) return 1 ;;
  esac
}

case "$1" in
apply)
  [ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }
  to_root_cgroup
  if [ "${S23T_LOCKED:-0}" = 1 ] && [ -d $APPLY_LOCK ]; then echo $$ > $APPLY_LOCK/pid   # handed over by start
  else take_lock || { echo "another apply is already running (see $L)" >&2; exit 3; }; fi
  trap 'rm -rf $APPLY_LOCK' EXIT
  TWEAKS=" $2 "; : > $L
  log "applying:$TWEAKS"
  for x in $2; do case " $TWEAK_IDS " in *" $x "*) ;; *) fail "unknown tweak: $x" ;; esac; done
  echo "$2" > $V/choices
  has wifi7 && ! has airdrop && fail "wifi7 needs airdrop (the S24 Wi-Fi driver)"
  phone_facts; keep=""
  for x in $2; do
    w=$(why_not $x); if [ -n "$w" ]; then log "$x: skipped: $w"; else keep="$keep $x"; fi
  done
  TWEAKS=" $keep "
  payload_fetch   # before the AirDrop driver swap takes Wi-Fi down
  if has airdrop; then
    has wifi7 && wifi7_bind   # before the driver loads, so it reads the MLO settings
    airdrop_kernel
    if has wifi7; then [ "${AK_LOADED:-0}" = 1 ] && [ "${W7_INI_NEW:-0}" = 1 ] && wifi7_reload; wifi7_check; fi
  fi
  restart=0
  has airdrop && airdrop_overlays && restart=1
  payload_apply && restart=1   # camerahdr audioeraser colortone galaxyai: before the flag file
  has battery && { ff_tags="$ff_tags BATTERY_SUPPORT_BSOH_SETTINGS SETTINGS_ENABLE_EU_BATTERY_REGULATORY"; battery_auth; }
  has features && ff_tags="$ff_tags SETTINGS_SUPPORT_AUTO_POWER_ON_OFF AUDIO_SUPPORT_VOIP_SOUND_LOUDER"
  if has display; then  # Vividness slider (Screen mode > Advanced settings) and full-screen AOD wallpaper
    ff_set LCD_CONFIG_VIVIDNESS 1; ff_set LCD_CONFIG_VIVIDPLUS 1
    ff_set LCD_CONFIG_AOD_FULLSCREEN 1
    # Not the S24's LCD_CONFIG_AOD_BRIGHTNESS_ANIMATION: on the S23 the AOD wallpaper then stays
    # bright for a few seconds and drops sharply, instead of dimming smoothly
  fi
  if has logvideo; then
    ff_set CAMERA_CONFIG_LOG_VIDEO V1.0; ff_set GALLERY_SUPPORT_LOG_CORRECT_COLOR TRUE
    cf_add="$cf_add
$CF_LOG"
  fi
  has camextras && cf_add="$cf_add
$CF_HLOCK"
  camfeat_apply && restart=1
  # 4K auto framing (untested): the S24's UHD setting for auto framing in video
  has autoframe && ff_set CAMERA_CONFIG_AUTOFRAMING uhd
  # Bixby barge-in (untested): talk over Bixby while it answers, as on the S24
  has bargein && ff_set BIXBY_CONFIG_BARGEIN_PARAM_MODE 2
  # Draw apps with Vulkan instead of OpenGL (Samsung's libhwui ignores ro.hwui.use_vulkan)
  has vulkan && { setprop debug.hwui.renderer skiavk; log "vulkan: apps render with Skia on Vulkan"; restart=1; }
  ff_apply && restart=1
  if has india; then india_apply && { setprop ctl.restart ril-daemon; log "india: mobile network restarting"; restart=1; }
  elif has callrec; then callrec_apply && restart=1; fi
  [ $restart = 1 ] && restart_framework
  has hotspot6g && hotspot6g_apply
  has camextras && directorsview_pref
  has callscreen && callscreen_apply
  has airdrop && airdrop_post
  on=""; off=""; for x in $2; do if is_on $x; then on="$on $x"; else off="$off $x"; fi; done
  log "on:${on:- none}"
  [ -n "$off" ] && log "not on:$off (the reason is in the lines above)"
  touch /dev/s23tweaks_applied   # lets the boot apply know this boot already has them
  log "DONE"
  ;;
start)
  [ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }
  [ -n "$2" ] || { echo "usage: tweaks.sh start \"<tweaks>\"" >&2; exit 2; }
  to_root_cgroup
  # take the lock here and hand it to apply, so two quick starts can't both go ahead
  take_lock || { echo "another apply is already running (see $L)" >&2; exit 3; }
  : > $L
  S23T_LOCKED=1 nsenter -t 1 -m -- setsid sh $D/tweaks.sh apply "$2" </dev/null >/dev/null 2>&1 &
  n=30; while [ $n -gt 0 ] && [ "$(cat $APPLY_LOCK/pid 2>/dev/null)" = $$ ]; do n=$((n-1)); sleep 0.1; done
  echo "started; progress in $L"
  ;;
probe)
  # One line of JSON for the WebUI and install.sh. Values never contain quotes or backslashes.
  phone_facts; kern=$(uname -r); android=$(getprop ro.build.version.release)
  ver=$( [ $MODULE = 1 ] && grep -m1 '^version=' $D/module.prop | cut -d= -f2 || echo script)
  j() { w=$(why_not $1); printf '{"id":"%s","available":%s,"why":"%s","active":%s}' "$1" \
          "$( [ -z "$w" ] && echo true || echo false)" "$w" "$(is_on $1 && echo true || echo false)"; }
  sim=$(getprop gsm.sim.operator.numeric | cut -d, -f1)   # MCC+MNC of the first SIM; 404/405 = India
  printf '{"version":"%s","module":%s,"phone":{"model":"%s","firmware":"%s","csc":"%s","android":"%s","kernel":"%s","gms":%s,"sim":"%s"},' \
    "$ver" "$( [ $MODULE = 1 ] && echo true || echo false)" "$model" "$build" "$csc" "$android" "$kern" "${gms:-0}" "$sim"
  printf '"picked":"%s","autostart":%s,"applying":%s,"tweaks":[' "$(cat $V/choices 2>/dev/null)" \
    "$( [ -f $V/autostart ] && echo true || echo false)" "$( lock_alive && echo true || echo false)"
  sep=""; for x in $TWEAK_IDS; do printf '%s%s' "$sep" "$(j $x)"; sep=","; done
  printf ']}\n'
  ;;
loop)
  # init can't start mosey_server (its .rc isn't loaded on this boot). moseyrun starts it the way
  # mosey.rc does: uid system, groups system+inet, ambient NET_ADMIN/NET_RAW, u:r:mosey_server:s0
  # (as root it fails to open /dev/tun). It's a lazy service that exits when idle: restart it.
  while true; do $AIR/moseyrun; sleep 1; done
  ;;
guard)
  # If the Wi-Fi firmware ever crashes, the S24 driver's recovery leaks the AirDrop interface and
  # ~50 s later the phone hard-resets. Stop the daemon, keep the log, and reboot cleanly instead.
  hangs() { dmesg | grep -c "Received firmware hang event"; }
  base=$(hangs)
  while sleep 1; do
    [ "$(hangs)" -gt "$base" ] || continue
    log "Wi-Fi firmware crashed: saving the kernel log and rebooting"
    echo "the Wi-Fi firmware crashed before the last reboot (log saved in $V)" > $V/boot.skip
    ps -A -o PID,ARGS | grep "[t]weaks.sh loop" | while read pid rest; do kill $pid; done
    pkill mosey_server; sleep 3; dmesg > $V/fwcrash_$(cut -d. -f1 /proc/uptime).txt; sync
    reboot
  done
  ;;
status)
  echo "saved choices: $(cat $V/choices 2>/dev/null); $(sh $D/tweaks.sh autostart)"
  echo "airdrop:  modules [$(grep -oE '^(wonder|bwfix) ' /proc/modules | tr -d '\n')]," \
       "Mosey $(bound /system_ext/bin && echo on || echo off), daemon $(running loop && echo running || echo stopped)," \
       "$(service check com.google.android.moseyservice.IMoseyService/default | sed 's/.*: //')"
  echo "features: $(bound $FF && grep -oE 'SEC_FLOATING_FEATURE_(BATTERY_SUPPORT_BSOH_SETTINGS|SETTINGS_SUPPORT_AUTO_POWER_ON_OFF|AUDIO_SUPPORT_VOIP_SOUND_LOUDER)>' $FF | sed 's/SEC_FLOATING_FEATURE_//; s/>//' | tr '\n' ' ' || echo off)"
  echo "battery:  auth IC $(mounted /sys/class/power_supply tmpfs && echo presented || { [ -e /sys/class/power_supply/sec_auth ] && echo "real (presence $(cat /sys/class/power_supply/sec_auth/presence 2>/dev/null), auth $(cat /sys/class/power_supply/sec_auth/batt_auth 2>/dev/null))" || echo off; }),"\
       "flags [$(grep -oE '<SEC_FLOATING_FEATURE_(BATTERY_SUPPORT_BSOH_SETTINGS|SETTINGS_ENABLE_EU_BATTERY_REGULATORY)>[A-Z]*' $FF | sed 's/<SEC_FLOATING_FEATURE_//; s/>/=/' | tr '\n' ' ')]"
  echo "display:  $(bound $FF && grep -q '<SEC_FLOATING_FEATURE_LCD_CONFIG_VIVIDNESS>1<' $FF && echo on || echo off)"
  echo "logvideo: $(bound $CF && grep -q SUPPORT_LOG_VIDEO $CF && echo on || echo off)"
  echo "camextras: horizon lock $(bound $CF && grep -q SUPPORT_SUPER_STEADY_HORIZONTAL_LOCK $CF && echo on || echo off), Director's view $(grep -q '<string name="directors_view_mode">1</string>' $CAM_PREFS 2>/dev/null && echo shown || echo hidden)"
  echo "autoframe: $(grep -o '<SEC_FLOATING_FEATURE_CAMERA_CONFIG_AUTOFRAMING>[^<]*' $FF | cut -d'>' -f2 | grep . || echo stock)"
  echo "bargein:  $(grep -q '<SEC_FLOATING_FEATURE_BIXBY_CONFIG_BARGEIN_PARAM_MODE>2<' $FF && echo on || echo off)"
  echo "settingssearch: $(bound /system/$SSI/SecSettingsIntelligence.apk && echo S24 || echo stock)"
  echo "callscreen: Language Core $(dumpsys package $LC_PKG 2>/dev/null | grep -m1 -oE 'versionName=[^ ]+' | cut -d= -f2)"
  echo "camerahdr: libraries $([ -f /system/lib64/liblow_light_hdr.arcsoft.so ] && echo on || echo off), list entries $(grep -q 'mfhdr.arcsoft.v4' $FF && echo on || echo off)"
  echo "audioeraser: $([ -f /system/etc/fastScanner.tflite ] && echo on || echo off), engine $(same_size /system/lib64/$VE $PL/audioeraser/$VE && echo S24 || echo stock)"
  echo "colortone: Settings $(bound $SETTINGS && echo patched || echo stock), service $([ -f /system/priv-app/$EAD/$EAD.apk ] && echo on || echo off)"
  echo "galaxyai: $(for p in $GAI_APPS; do n=${p#*/}; printf '%s=%s ' $n "$(same_size /system/$p/$n.apk $PL/galaxyai/$n.apk && echo S24 || echo stock)"; done)"
  echo "vulkan:   renderer $(getprop debug.hwui.renderer | grep . || echo default)"
  echo "wifi7:    wpa_supplicant $(bound $WPAS && echo S24 || echo stock), driver MLO settings $(bound $INI && echo on || echo off)"
  echo "6ghz ap:  CSC country $(getprop ro.csc.countryiso_code)"
  set -- $(callrec_row); f=${3:-$XAC/system/cscfeature.xml}
  echo "csc:      $(bound $f && grep -m1 -oE '<SalesCode>[A-Z]+' $f | cut -c12- || echo stock)"
  ;;
cleanup)
  # Undo everything that outlives a reboot, then delete the state folder. module/uninstall.sh runs this
  # from a copy in /dev when the module is removed. It waits for Android and the first unlock, since
  # the Play services database and the Camera settings sit in app storage that's locked until then.
  n=0; until [ "$(getprop sys.boot_completed)" = 1 ] && [ "$(getprop sys.user.0.ce_available)" = true ] &&
    pm path android >/dev/null 2>&1; do n=$((n+1)); [ $n -gt 4320 ] && exit 1; sleep 5; done
  say() { /system/bin/log -t s23tweaks "cleanup: $*" 2>/dev/null; echo "$*"; }   # Android's log: log() here is ours
  [ -x $AIR/sqlite3 ] && sh "$0" unflag >/dev/null 2>&1 && say "Play services flag overrides removed"
  if [ -f $V/undo/languagecore ] && pm path $LC_PKG >/dev/null 2>&1; then
    pm uninstall $LC_PKG >/dev/null 2>&1 && say "Language Core uninstalled"
    for k in call_screening call_screening_auto_screening_onoff call_screening_voice call_screening_voice_speech_rate; do
      settings delete system $k >/dev/null 2>&1; done
  fi
  if [ -f $V/undo/directors_view ] && [ -f $CAM_PREFS ]; then
    v=$(cat $V/undo/directors_view); am force-stop com.sec.android.app.camera; mkdir -p $R
    if [ "$v" = absent ]; then grep -v 'name="directors_view_mode"' $CAM_PREFS > $R/camprefs.new
    else sed "s|<string name=\"directors_view_mode\">[^<]*</string>|<string name=\"directors_view_mode\">$v</string>|" $CAM_PREFS > $R/camprefs.new; fi
    grep -q '</map>' $R/camprefs.new && cat $R/camprefs.new > $CAM_PREFS && say "Camera setting restored"
  fi
  # parsed manifests of the apps the tweaks swap, in case a restart cached one; Android re-parses them
  for n in SamsungSmartSuggestions SketchBook CallAssistant SecSettingsIntelligence SecSettings EnvironmentAdaptiveDisplay MoseyApp; do
    rm -f /data/system/package_cache/*/$n-[0-9]*; done
  rm -f /data/adb/service.d/s23tweaks.sh
  cd /; rm -rf $V
  say "done; the next reboot removes what's still mounted"
  case "$0" in /dev/*) rm -f "$0" ;; esac
  exit 0
  ;;
unflag)
  G=/data/data/com.google.android.gms; DB=$G/databases/phenotype.db; SQ=$AIR/sqlite3; W=$R/gms
  [ -x $SQ ] || { echo "the AirDrop download (with its sqlite3) isn't on the phone; pick AirDrop once to fetch it" >&2; exit 1; }
  rm -rf $W; mkdir -p $W; am force-stop com.google.android.gms
  cp $DB $W/p.db; [ -f $DB-wal ] && cp $DB-wal $W/p.db-wal
  $SQ $W/p.db "DELETE FROM experiment_states_to_overrides WHERE override_id IN (SELECT override_id FROM flag_overrides WHERE name IN ('${NEARBY_FLAGS% *}', '${NEARBY_FLAGS#* }') AND account_id=0);
    DELETE FROM flag_overrides WHERE name IN ('${NEARBY_FLAGS% *}', '${NEARBY_FLAGS#* }') AND account_id=0; PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
  am force-stop com.google.android.gms; cat $W/p.db > $DB && rm -f $DB-wal $DB-shm; rm -rf $W
  echo "Play services flag overrides removed"
  ;;
autostart)
  S=/data/adb/service.d/s23tweaks.sh
  case "$2" in
  on)
    # the module's own service.sh does the boot call; install.sh needs a service.d script
    rm -f $V/boot.skip $V/boot.pending
    if [ $MODULE = 1 ]; then rm -f $S; touch $V/autostart; echo "autostart on: the saved tweaks ($(cat $V/choices 2>/dev/null)) re-apply at every boot"; exit 0; fi
    mkdir -p /data/adb/service.d
    cat > $S <<EOF
#!/system/bin/sh
# s23-ultra-tweaks: re-apply the saved tweaks at boot. KernelSU runs this once DFRoot has rooted the
# phone. Remove with: sh $D/tweaks.sh autostart off
unset ASH_STANDALONE
[ -f $V/autostart ] && /system/bin/nsenter -t 1 -m -- /system/bin/setsid /system/bin/sh $D/tweaks.sh boot </dev/null >/dev/null 2>&1 &
EOF
    chmod 700 $S; touch $V/autostart; echo "autostart on: the saved tweaks ($(cat $V/choices 2>/dev/null)) re-apply at every boot" ;;
  off) rm -f $S $V/autostart $V/boot.pending $V/boot.skip; echo "autostart off" ;;
  *) [ -f $V/autostart ] && { [ $MODULE = 1 ] || [ -f $S ]; } && echo "autostart on" || echo "autostart off" ;;
  esac
  ;;
boot)
  B=$V/boot.log
  blog() { echo "$(date '+%F %T') $*" >> $B; }
  note() { cmd notification post -S bigtext -t "S23 tweaks" s23tweaks "$1" >/dev/null 2>&1; }
  [ -f $V/autostart ] || exit 0
  t=$(cat $V/choices 2>/dev/null); [ -n "$t" ] || exit 0
  # KernelSU can run boot scripts more than once per boot (seen with DFRoot's late load): only the
  # first call goes on
  mkdir /dev/s23tweaks_boot.lock 2>/dev/null || exit 0
  to_root_cgroup
  # The module replaces an earlier computer install: drop that copy's code (not its state). Safe
  # only now, at boot, when nothing can still be running from it.
  if [ $MODULE = 1 ] && [ "$D" != "$V" ] && [ -f $V/tweaks.sh ]; then
    rm -rf $V/tweaks.sh $V/files $V/airdrop; rm -f /data/adb/service.d/s23tweaks.sh
  fi
  n=600; until [ "$(getprop sys.boot_completed)" = 1 ]; do n=$((n-1)); [ $n = 0 ] && break; sleep 1; done
  sleep 30   # let Wi-Fi, Play services and the launcher settle before swapping the driver
  # Fail-safe against a boot loop: if the last boot's apply never finished (the phone rebooted in the
  # middle) or the Wi-Fi firmware crashed, skip this boot once and say so.
  why=""
  [ -f $V/boot.pending ] && why="the last automatic apply didn't finish"
  [ -f $V/boot.skip ] && why=$(cat $V/boot.skip)
  if [ -n "$why" ]; then
    rm -f $V/boot.pending $V/boot.skip; blog "skipped: $why"
    note "Tweaks not applied at this boot: $why. Apply them from KernelSU > Modules > S23 Ultra Tweaks (or the installer), or reboot to try again."
    exit 0
  fi
  [ -f /dev/s23tweaks_applied ] && { blog "skipped: already applied in this boot"; exit 0; }
  touch $V/boot.pending; sync; blog "applying: $t"
  S23T_BOOT=1 sh $D/tweaks.sh apply "$t"; rc=$?
  rm -f $V/boot.pending
  [ $rc = 3 ] && { blog "skipped: an apply was already running"; exit 0; }
  if grep -q DONE $L; then blog "done"; note "Applied: $t"
  else f=$(grep FAILED $L | tail -1 | cut -d' ' -f2-); blog "failed: $f"; note "Applying the tweaks failed: $f. Details: $L"; fi
  ;;
wifi7page)
  # Samsung ships this page on the S23, but its entry in Wi-Fi Labs is hard-coded as unsupported
  # (WifiLabs7ModeSettingsController.getAvailabilityStatus() returns 3). The page itself has no
  # check. SubSettings isn't exported, so it can only be opened as root/system.
  am start -n com.android.settings/.SubSettings \
    --es :settings:show_fragment com.samsung.android.settings.wifi.develop.WifiLabs7ModeSettingsFragment
  ;;
*) echo "usage: tweaks.sh start|apply \"<tweaks>\" | probe | status | unflag | autostart on|off | wifi7page"; exit 2 ;;
esac
