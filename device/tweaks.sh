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
#   report            write a bug report (phone, tweaks, logs, crash summaries; no personal data) to Download
#   airdrop-test [S]  record S seconds (default 90) of AirDrop logs while the user tries a share, say which
#                     stage it reached, and save the log (personal data masked) to Download
#   unflag            remove the Play services flag overrides that the airdrop tweak adds
#   autostart on|off  re-apply the saved tweaks at every boot. DFRoot roots the phone by itself at
#                     boot, then KernelSU runs the module's service.sh (module) or a script in
#                     /data/adb/service.d (install.sh). Both call "boot".
#   boot              (internal) the automatic apply at boot
#   wifi7page         open Samsung's hidden "Wi-Fi 7 mode" settings page (Wi-Fi Labs)
#   loop | guard      (internal) keep mosey_server running / reboot cleanly on a Wi-Fi firmware crash
#   moseyheal         (internal) restart Mosey when its AirDrop network outlives mosey0
# Tweaks: airdrop battery features callrec india hotspot6g wifi7 display logvideo vulkan
#         camerahdr hdr2023 audioeraser colortone galaxyai highlights camextras autoframe settingssearch bargein
#         callscreen tenbit hideksu weather wideflash
#         prowbtint zoomrocker videosoftening afcontrol aelimit slowmoaf extstorage
#         anamorphic profps uhd60lenses dual5g nronly natroam rambler wearretry chargewatts  (see README.md; the categories they're grouped in are in install.sh and the WebUI)
#
# Nothing here writes to a partition. Every change is a module load, an overlay, a bind mount or a
# runtime setting, so a reboot always returns the phone to stock. The files themselves stay on storage
# (/data/adb/s23tweaks), not in RAM: the kernel won't build an overlay from /data, so each overlay holds
# only empty placeholders in tmpfs and the real file is bind-mounted over its placeholder (pbind). The one exception is
# the airdrop tweak's Play services flag overrides, stored in Play services' own database
# (harmless without the rest; "unflag" removes them), camextras' camera app setting, callscreen,
# which installs Samsung Language Core as an ordinary app (undo: pm uninstall <package>), and weather,
# which installs a 12 KB AI Core stub app and turns Samsung's live wallpaper app back on if it was off,
# natroam, which writes a carrier config override file in the Phone app's storage (removed on undo),
# and rambler, which writes Gboard's local flag override file (the original is put back on undo).
# dual5g is the one change inside the modem: it edits one policy file in the modem's own storage (EFS),
# which stays across reboots and module removal until it's put back. The original is backed up before
# the first write (state folder and Download/s23tweaks-modem-backup); un-picking dual5g, removing the
# module, or "dual5g-restore" puts it back.
# Never touched: the sales code (mps_code.dat, sales_code.dat, omc.info, persist.sys.matched_code).
# Changing those can factory-reset the phone.

# KernelSU runs boot scripts in BusyBox standalone mode; make sure every tool here is Android's own
unset ASH_STANDALONE; export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
D=$(cd "$(dirname "$0")" && pwd)            # code: this script and files/
V=${S23T_STATE:-/data/adb/s23tweaks}         # state: choices, logs, backups, autostart flag
mkdir -p $V; L=$V/tweaks.log; R=$V/run
[ -f $D/module.prop ] && MODULE=1 || MODULE=0
APPLY_LOCK=/dev/s23tweaks_apply.lock         # /dev is tmpfs: locks never survive a reboot
STAYS_TILL_REBOOT="airdrop wifi7 battery india callrec vulkan audioeraser hdr2023 colortone highlights tenbit galaxyai settingssearch hideksu profps"
TWEAK_IDS="airdrop battery features wearretry callrec india hotspot6g wifi7 display logvideo vulkan camerahdr hdr2023 audioeraser colortone galaxyai highlights camextras autoframe settingssearch bargein callscreen tenbit hideksu weather wideflash prowbtint zoomrocker videosoftening afcontrol aelimit slowmoaf extstorage anamorphic profps uhd60lenses dual5g nronly natroam rambler chargewatts"
GMS_MIN=261125000                            # Play services 26.11, the first with Mosey support
# Firmware the AirDrop/Wi-Fi 7 kernel modules are checked against (one line each, read by customize.sh).
# All are One UI 9 build GZIF on GKI kernel 34343818, and their whole Wi-Fi stack (cnss2, mhi, cfg80211,
# mac80211, ipa) has the same code and symbol CRCs as S918WVLU8GZIF, which the modules are built on.
AIRDROP_KBASE=5.15.197-android13-8-34343818-ab
AIRDROP_FW="S918WVLU8GZIF S918BXXUAGZIF S918U1UEU8GZIF S918USQU8GZIF S918NKSU8GZIF S9180ZHU8GZIF"
kernel_stock() { for f in $AIRDROP_FW; do [ "$(uname -r)" = "$AIRDROP_KBASE$f" ] && return 0; done; return 1; }
# Opt-in for custom kernels (issue #10): with the file $V/allow-any-kernel, a 5.15 android13 kernel on one
# of the supported firmwares is let through. The kernel itself still refuses the modules if any symbol CRC
# differs (CONFIG_MODVERSIONS), and airdrop_kernel then puts the stock Wi-Fi driver back.
kernel_override() {
  [ -f $V/allow-any-kernel ] || return 1
  case "$(uname -r)" in 5.15.*-android13-*) ;; *) return 1 ;; esac
  case " $AIRDROP_FW " in *" $(getprop ro.build.PDA) "*) return 0 ;; esac; return 1
}
kernel_supported() { kernel_stock || kernel_override; }
# A custom kernel that ships its own Wi-Fi stack (cfg80211.ko built for that kernel, not the stock GKI one)
# lays out cfg80211's structures differently. The S24 driver's modules still load, but wiphy_new/
# wiphy_register reject it (WARNs at core.c:431/772, err -5) and the phone froze during the driver swap
# (issue #21). The stock module's vermagic names the GKI build the airdrop modules are made for.
CFG80211_KO=/vendor_dlkm/lib/modules/cfg80211.ko
cfg80211_vermagic() { grep -a -o -m1 'vermagic=[^ ]*' $CFG80211_KO 2>/dev/null | head -n 1 | cut -d= -f2; }
cfg80211_stock() { case "$(cfg80211_vermagic)" in "$AIRDROP_KBASE"*) return 0 ;; esac; return 1; }
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
# is used first. "tweak:md5" lines are per stock file: only the one whose md5 matches this phone's is
# fetched (hideksu: one patched services.jar per stock services.jar, see hks_row).
PAYLOAD_URL=https://github.com/dtechterminal/s23-ultra-tweaks/releases/download/payloads-S918WVLU8GZIF
PAYLOADS="airdrop airdrop-S918WVLU8GZIF-2.tar.gz deed1ee54334dbbf6086d2aa0d194183006826913a662900377f3760d7966e1c
logvideo logvideo-luts.tar.gz ed688855d75d9ff964a2f9f904cb7189b6adb897940fb61fe3a4c8049c73ecbe
hideksu:30d17f5d60b0d42585b97a94412f6e12 hideksu-S918WVLU8GZIF.tar.gz 4732e4568d08254b80b60bbeeb1d03673dd259049303e5c43dcda6fe960fa647
hideksu:7dc62286f9f0675f84459943cdc397b6 hideksu-7dc62286.tar.gz 38d5719706ec67331fb9199b0934e9551ac814f5d2970c1cbfc3099dd286d4e2
hideksu:c438dd27a76486855d01e74379e13b5d hideksu-c438dd27.tar.gz 0b3f9991d5cb3e46cd8953d8d4e776005ff1a61b30f222aeb6af9ad919745dbf
camerahdr camerahdr-S918WVLU8GZIF.tar.gz ed4d9be902918d1d014b91d3fd53cec42512f58744a398ec4e0888be04116bcc
hdr2023 hdr2023-S918WVLU8GZIF.tar.gz 0f31937af2f04e2edcf1a2319298dfb97e3493aea558be6f3e0070fdb9b37eba
audioeraser audioeraser-S918WVLU8GZIF.tar.gz a11d2868b3d8ba0121554ea2a31bb65256e0c141c6033c4e6ddb4770f4d11704
colortone colortone-S918WVLU8GZIF.tar.gz 4be28f16e3631f1e377ecec9ad2b5b78d1abf8c6a9b971435c7ac12604f75e40
galaxyai galaxyai-S918WVLU8GZIF.tar.gz 5619aaee7580b985df300dcfca1fadc56bc774f60ebb2af9db975876dfe01c0e
settingssearch settingssearch-S918WVLU8GZIF.tar.gz bddfa32a08def256b7497730a0e7faecf7b1621655ce0cc85bec423843357042
callscreen callscreen-S918WVLU8GZIF.tar.partaa 6a8d141557050e738b3a805d741463aae46b9322732bdd3039d836c0d116af9a
callscreen callscreen-S918WVLU8GZIF.tar.partab 3335ea84794746040513e4297175736d792a19f378187d7b970c4058bc421025
chargewatts:adcea3e330bb75ab20c8a3602d5a3a65 chargewatts-S918WVLU8GZIF-4.tar.gz 8a7ceb04b7e2076de82edee10d6bd4ac92dbd25a9c9c4358078ec5bc8bf114c4
chargewatts:fbd2cd7e81ccce52bf1f4720f973ddb7 chargewatts-S918BXXUAGZIF-3.tar.gz 48cdf5c532cb881187a3b8c04340782c1974706e9976f7abcb11b6c3f12c9b4d"
SETTINGS=/system/priv-app/SecSettings/SecSettings.apk
# colortone: firmware, md5 of its SecSettings.apk, md5 with files/SecSettings-ead-<firmware>.patch applied
# (tools/eadpatch.py makes the patch and prints both for another firmware's APK)
SETTINGS_EAD="S918WVLU8GZIF 5b8afa24f17e090d57380b8ebbd3dcee f499f2e574a47eca0414f470e1ae20e8
S918BXXUAGZIF 5b20b1a68f94d01bba5a776e15ffdc30 de6d142d238849198810dfe70fada8dd"
ead_row() { echo "$SETTINGS_EAD" | awk -v b="$(getprop ro.build.PDA)" '$1 == b'; }
ead_builds() { echo "$SETTINGS_EAD" | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//; s/ / or /g'; }
# Patch files hold "<byte offset> <octal value>" lines and are LF in the repo; a CRLF checkout
# would hand read() a trailing CR, so the loops strip it.
# highlights: the Notification highlights page (Settings > Notifications > Advanced settings) is hidden
# while com.android.settings:bool/config_na_enable is false, which no S23 build allows. The patches flip
# SecNotificationIntelligenceController.getAvailabilityStatus()'s early "const/4 p0, 3" to 0. The ead one
# goes on top of the colortone patch, as both touch different bytes of the same APK's stored dex.
# firmware, stock md5, md5 with files/SecSettings-nh-<firmware>.patch, md5 with the colortone patch,
# md5 with both (tools/nhpatch.py makes them)
SETTINGS_NH="S918BXXUAGZIF 5b20b1a68f94d01bba5a776e15ffdc30 9d87d879ce01bd65c98cd7dfcf1063ab de6d142d238849198810dfe70fada8dd 854ca78b2a6c9cd2020d1326a0c5a13a"
nh_row() { echo "$SETTINGS_NH" | awk -v b="$(getprop ro.build.PDA)" '$1 == b'; }
nh_builds() { echo "$SETTINGS_NH" | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//; s/ / or /g'; }
CAM_APK=/system/priv-app/SamsungCamera/SamsungCamera.apk
# profps, keyed on the Camera APK itself, not the firmware: md5 of a stock SamsungCamera.apk, md5 once
# patched, the patch in files/, and the firmware it came from. Any firmware whose stock Camera APK is listed
# works; tools/cam24patch.py makes the patch and prints both md5s for another APK.
CAMERA_24FPS="174e38e111f53c92eea54fd8b9a8c1c6 b22942b22ec14896bc02277d319b7623 SamsungCamera-24fps-S918BXXUAGZIF.patch S918BXXUAGZIF
e7c89df10d6607ea1ddeedceee961903 650dc854741a92f54be455fc19cd4c89 SamsungCamera-24fps-17.0.00.43.patch S918WVLU8GZIF"
# the row for the Camera APK in place now (stock, or our patched copy bound over it)
cam24_row() { m=$(md5sum $CAM_APK 2>/dev/null | cut -d' ' -f1); echo "$CAMERA_24FPS" | awk -v m="$m" '$1 == m || $2 == m'; }
# the bound Camera APK is one whose patch also unhides the 10x (the patch header says so)
cam24_profps_on() { bound $CAM_APK || return 1; set -- $(cam24_row); [ -n "$1" ] && grep -q BACK_SECOND_TELE $D/files/$3 2>/dev/null; }
cam24_builds() { echo "$CAMERA_24FPS" | awk '{print $4}' | tr '\n' ' ' | sed 's/ $//; s/ / or /g'; }
# Carrier config (callrec, india), on any sales code. SemCscFeature reads <mdc.system.path>/cscfeature.xml
# (on multi-country firmware also that file's FeatureSet for the CSC country); customer_carrier_feature.json
# sits next to it, customer.xml one folder up, and the prism folder (keystrings, regulatory images) mirrors
# the optics path. Stock files are OMC-encoded; files/omcdec (src/omcdec) prints them as plain XML, which
# the parser also accepts.
csc_paths() {
  SC=$(getprop ro.csc.sales_code); CSYS=$(getprop mdc.system.path)
  CSCF=$CSYS/cscfeature.xml; CCF=$CSYS/customer_carrier_feature.json; CUST=${CSYS%/system}/customer.xml
  case "$CSYS" in /optics/configs/carriers/*/conf/system) _p=${CSYS%/conf/system}; PRISM=/prism/etc/carriers/${_p#/optics/configs/carriers/} ;; *) PRISM="" ;; esac
}
csc_paths
OMCDEC=$D/files/omcdec
# india also makes the phone report itself as the Indian S23 Ultra (SM-S918B / INS / country IN), so
# Samsung Wallet's India features (UPI, DigiLocker, transit) and the 6 GHz hotspot work. These are runtime
# resetprop overrides: they revert on reboot and never write the CSC partition files (mps_code.dat,
# sales_code.dat, omc.info), so there is no factory-reset risk. The reported model changes for every app
# while it's on, and adding bank payment cards may still fail (that path checks the real model by hardware).
IN_MODEL=SM-S918B
IN_MODEL_PROPS="ro.product.model ro.product.vendor.model ro.product.system.model ro.product.odm.model ro.product.product.model ro.product.system_ext.model ro.product.bootimage.model ro.product.system_dlkm.model ro.product.vendor_dlkm.model ro.boot.em.model"
IN_SALES_PROPS="ro.csc.sales_code ro.boot.sales_code persist.audio.sales_code ril.sales_code"
NEARBY_FLAGS="45704091 45723015 sharing_package_whitelist_check_bypass"   # Nearby Sharing: enableExternalProviders + provider-registry gate + GMS 26.46+ source-stamp bypass
# Play services 26.46 guards its own broadcasts (Dqjx.c): an implicit one (no target app) whose action isn't on a
# list throws IllegalStateException and crashes Play services. Incoming AirDrop shares hit it with
# nearby.sharing.TRANSFER_UPDATE (issue #41). The list is flag 45645310 of config package com.google.android.gms: a
# bytes flag holding a repeated string (field 1). The module adds the Nearby transfer actions to whatever list
# Play services already has (BCAST_STOCK is the list seen on a phone, used only when none is found).
# Found by @Ashraf12Nas.
BCAST_FLAG=45645310
BCAST_STOCK="com.ifpdos.systembar.action.HIDE_BAR com.seewo.freeform.TASK_MOVE_NO_RESIZE"
BCAST_NEARBY="com.google.android.gms.nearby.sharing.TRANSFER_UPDATE com.google.android.gms.nearby.sharing.TRANSFER_METADATA com.google.android.gms.nearby.sharing.TRANSFER_FINISHED"
BCAST_ACTIONS="$BCAST_STOCK $BCAST_NEARBY"   # gms_bcast_flag replaces it with the phone's own list plus BCAST_NEARBY

HIST=/dev/s23tweaks.history   # every apply's lines since boot (tweaks.log holds only the last apply)
# Set by cleanup when the module is removed after an apply in this boot. The binds that apply made stay
# until a reboot, but cleanup deleted the files behind them, so a reinstall would take its own binds for
# someone else's and leave them on (a camera driver restart then found no driver). Applying waits for the reboot.
REMOVED=/dev/s23tweaks_removed
REMOVED_MSG="the module was removed earlier in this boot and that install's changes are still mounted; reboot, then apply"
log() { m="$(cut -d' ' -f1 /proc/uptime) $*"; echo "$m" >> $L; echo "$m" >> $HIST 2>/dev/null; echo "s23tweaks: $*" > /dev/kmsg; sync; }
fail() { log "FAILED: $*"; exit 1; }
wait_for() { n=$1; shift; while [ $n -gt 0 ]; do "$@" && return 0; n=$((n-1)); sleep 1; done; return 1; }
mounted() { mount | grep -q " $1 type $2"; }
bound() { mount | grep -q " $1 "; }
running() { ps -A -o ARGS | grep -q "[t]weaks.sh $1"; }
# The recorder keeps the recent Android log (Info and up, 8 files of 4 MB) and the kernel's Wi-Fi/AirDrop
# lines in $REC, so a report made after something went wrong already holds what happened: no timed test
# needed. Root-only files; the report takes filtered, masked lines from them. A busy phone logs ~450 KB a
# minute at Info; the five UI tags silenced in REC_QUIET are a quarter of that, so 32 MB keeps 1.5 h or so.
REC=$V/rec
REC_CONF="4096 7"
REC_QUIET="View:S SurfaceFlinger:S NotifHistoryProto:S FASModelGlobal:S power_partial_wake_state:S"
rec_start() {
  # a recorder from an older version keeps its old size until stopped; restart it with the current one
  # (only its own session: the guard runs a dmesg -W of its own)
  if running recorder && [ "$(cat $REC/conf 2>/dev/null)" != "$REC_CONF" ]; then
    for s in $(pgrep -f "tweaks.sh recorder\$"); do
      [ "$(cut -d' ' -f6 /proc/$s/stat 2>/dev/null)" = $s ] && [ "$(tr '\0' ' ' < /proc/$s/cmdline)" = "sh $D/tweaks.sh recorder " ] && kill $(pgrep -s $s)
    done; sleep 1
  fi
  running recorder && return 0
  # exec, so no shell is left waiting on it with the caller's output open (a report read through a pipe
  # would never end)
  (exec setsid sh $D/tweaks.sh recorder </dev/null >/dev/null 2>&1) &
}
rec_files() { for i in 7 6 5 4 3 2 1; do [ -f $REC/log.$i ] && echo $REC/log.$i; done; [ -f $REC/log ] && echo $REC/log; }
has() { case " $TWEAKS " in *" $1 "*) return 0 ;; esac; return 1; }
# cam24fps and slowmo4k120 were folded into profps (they share the same Camera APK patch and
# camera-feature.xml edit). A saved picks list from an older module may still name them: map both
# to profps and drop duplicates.
migrate_choices() {
  mc_o=""; for mc_x in $1; do
    case "$mc_x" in cam24fps|slowmo4k120) mc_x=profps ;; esac
    case " $mc_o " in *" $mc_x "*) ;; *) mc_o="$mc_o${mc_o:+ }$mc_x" ;; esac
  done
  echo "$mc_o"
}
md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
# the kernel log. dmesg needs the syslog() system call, which an app's seccomp filter forbids (a root shell
# started from an app, such as a module page, can keep that filter: dmesg dies with SIGSYS and prints
# nothing); /dev/kmsg is read with plain read() calls
klog() { ( dmesg ) 2>/dev/null || timeout 1 cat /dev/kmsg 2>/dev/null | sed 's/^[^;]*;//'; }
# masks email, MAC addresses, IMEI-length numbers and quoted names (device and contact names in share logs)
scrub() {
  sed -E -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    -e 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<mac>/g' -e 's/(^|[^0-9])[0-9]{14,17}([^0-9]|$)/\1<number>\2/g' \
    -e 's/((device|account|profile|owner|user)[Nn]ame=|[(, ]name=)[^,)]+/\1<name>/g' -e 's/(account=)[^,)]+/\1<account>/g' |
    if [ -n "$sn" ]; then sed "s/$sn/<serial>/g"; else cat; fi
}
# Play services 26.45 also keeps flag snapshots in a newer store, app_phenotype_shared/<hash>/<hash>.pb
# (an 8-byte header, then the snapshot; flag names hashed, so it can't be patched). When the Nearby one
# exists Play services reads it instead of files/phenotype/shared/...nearby.pb, so the overrides read
# false and Mosey is never bound (#22). Lists those files; their header names the config package.
nearby_newstore() {
  # one grep over the files (a loop forked head and grep per file: minutes with ~3600 snapshots)
  grep -rlaF -m1 'com.google.android.gms.nearby ' --include='*.pb' \
    /data/data/com.google.android.gms/app_phenotype_shared /data/user_de/0/com.google.android.gms/app_phenotype_shared 2>/dev/null |
    while read -r f; do head -c 64 "$f" | grep -qaF 'com.google.android.gms.nearby ' && echo "$f"; done
}
# The same newer store also holds Play services' core config (com.google.android.gms, direct-boot aware, so in
# /data/user_de). That copy has no value for the broadcast guard's allowlist (BCAST_FLAG), so the guard used
# its built-in 2-entry default and crashed on every incoming AirDrop share although files/phenotype/shared/
# com.google.android.gms.pb had the list (seen with a hook on the guard: size=2, then size=5 once moved aside).
# A header's first token is its config package; "#" joins two (com.google.android.euicc#com.google.android.gms),
# so only an exact match counts. ~130-byte copies hold no flags and stay. A copy Play services rebuilds after
# the move has the allowlist (seen 2026-11-28, 26.45.31) and stays too, so apply doesn't move and restart
# Play services again for nothing.
gms_newstore() {
  grep -rlaF ' com.google.android.gms ' --include='*.pb' \
    /data/user_de/0/com.google.android.gms/app_phenotype_shared /data/data/com.google.android.gms/app_phenotype_shared 2>/dev/null |
    while read -r f; do
      [ "$(head -c 100 "$f" | grep -aoE ' [A-Za-z0-9_.#]+ -?[0-9]+' | head -1 | cut -d' ' -f2)" = com.google.android.gms ] || continue
      [ "$(wc -c < "$f")" -gt 1024 ] || continue
      grep -qF "$BCAST_FLAG" "$f" && grep -qF nearby.sharing.TRANSFER_UPDATE "$f" && continue
      echo "$f"
    done
}
# Nearby flags in Play services' live config (the snapshot Nearby reads), not just in its database:
# an override can sit in the database and still be missing here, which leaves Mosey unused
nearby_live() {
  f=/data/data/com.google.android.gms/files/phenotype/shared/com.google.android.gms.nearby.pb
  [ -f $f ] || { echo "no Nearby config file yet"; return; }
  [ -n "$(nearby_newstore)" ] && { echo "0 of 3 in effect: Play services reads a newer Nearby snapshot without them; apply again"; return; }
  c=0; t=0; for x in $NEARBY_FLAGS; do t=$((t + 1)); grep -qF "$x" $f && c=$((c + 1)); done
  echo "$c of $t in Play services' live Nearby config$([ $c -lt $t ] && echo "; apply again to put them back")"
}
# ad_verdict LOG KMSG "MOSEY_PIDS" "advice when nothing logged": counts one AirDrop attempt's stages in a
# logcat file (threadtime) and its kernel lines, and sets $v to which stage it reached. rel() then prints the
# relevant lines. Used by airdrop-test and, on the recorder's log, by the report.
ad_verdict() {
  # the Mosey app's processes (it starts only when Quick Share hands it a share). mosey_server is a lazy
  # service that the module's loop restarts every few seconds, so its start-up lines are left out of the counts
  apids=" $3 $(pidof com.google.android.mosey) $(awk '/am_proc_start/ && /com\.google\.android\.mosey[],]/ { sub(/.*am_proc_start[^[]*\[[0-9]+,/, ""); sub(/,.*/, ""); print }' $1 | tr '\n' ' ') "
  rel() { awk -v p="$apids" '{ if (($3 ~ /^[0-9]+$/ && index(p, " " $3 " ")) || $0 ~ /[Mm]osey|[Aa]irdrop|AirDrop|[Aa]wdl|AWDL|NearbySharing|ShareLive|QuickShare|Wonder/) print }' $1 | grep -v '	at '; }
  idle='AidlLazyServiceRegistrar|reset mosey network resources|Interface is gone, nothing to shutdown|Registering service com\.google\.android\.moseyservice'
  # Quick Share: its screens opening (activity events), and its log lines (it also logs in the background)
  nui=$(grep -E 'wm_on_(create|resume)_called|wm_(create|restart|resume)_activity|am_focused' $1 | grep -c sharelive)
  nsl=$(grep -cE 'ShareLive|QuickShare' $1)
  napp=$(awk -v p="$apids" '($3 ~ /^[0-9]+$/ && index(p, " " $3 " ")) || $6 ~ /^Mosey/' $1 | grep -c .)
  nsrv=$(grep -E ' (mosey_server|mosey_daemon)' $1 | grep -cvE "$idle")
  nst=$(grep -cE 'am_proc_start.*com\.google\.android\.mosey[],]' $1)
  nmo=$((napp + nst))   # the app is what runs a share; mosey_server alone logs housekeeping too
  nk=$(grep -ciE 'wonder|awdl|llw' $2)
  # Play services loading Mosey as a share target: its external provider registry, then the bind
  nreg=$(grep -cE 'NearbySharing: (Starting external provider registry|Bound to provider ComponentInfo\{com\.google\.android\.mosey)' $1)
  # an AirDrop share to this phone (Mosey's receive side) and Play services' Nearby starting over (a crash)
  nin=$(grep -c 'ContextTransferInitiated(context=.*clientName=ReceiveProvider' $1)
  nrs=$(grep -c 'NearbySharing: NearbySharingService onCreate' $1)
  nohand="the share never reached the AirDrop side (Share with Apple devices not shown or not tapped, or Play services didn't hand the share to Mosey)"
  if [ $nin -gt 0 ] && grep -q 'Unexpected implicit intent broadcast start.*nearby\.sharing\.TRANSFER_' $1; then
    v="An AirDrop share to this phone arrived ($nin), but Play services crashed on its own broadcast guard (issue #41), which cancels it: Play services $(dumpsys package com.google.android.gms 2>/dev/null | grep -m1 -oE 'versionName=[^ ]+' | cut -d= -f2) isn't using the module's AirDrop receive allowlist (Broadcast guard below says which config copies have it). Apply again, which rewrites it and restarts Play services, then retry"
  elif [ $nin -gt 0 ] && [ $nrs -gt 0 ]; then
    v="An AirDrop share to this phone arrived ($nin), but Play services' Nearby restarted $nrs times (a crash), which cancels it: the crash lines below show why"
  elif [ $nmo -gt 0 ]; then
    if [ $nk -gt 0 ]; then v="Mosey ran and the Wi-Fi driver logged AirDrop link activity: the log shows how far it got"
    else v="Mosey ran; the kernel log has no AirDrop link lines: the log shows how far Mosey got"; fi
  elif [ $nui -gt 0 ] && [ $nreg = 0 ]; then
    v="Quick Share opened, but Play services never loaded Mosey (no external provider registry): its Nearby flags aren't in effect. Apply again (it rewrites them and restarts Play services), then retry"
  elif [ $nui -gt 0 ]; then
    if [ $nsrv -gt 0 ]; then v="Quick Share opened, but the Mosey app never started (only mosey_server logged, $nsrv lines): $nohand"
    else v="Quick Share opened, but Mosey logged nothing: $nohand"; fi
  elif [ $nsl -gt 0 ]; then v="Mosey logged nothing. Quick Share logged $nsl lines but no screen of it opened; if you did share, $nohand"
  else v="Neither Quick Share nor Mosey logged anything: $4"; fi
}
# is the broadcast-guard allowlist (BCAST_FLAG) in Play services' live config?
# Play services keeps two copies (user_de, read before the first unlock, and data); check each, since a
# process can start from either.
bcast_live() {
  bl_n=0; bl_ok=0; bl_miss=""
  for f in $BCAST_SNAPS; do
    [ -f $f ] || continue; bl_n=$((bl_n + 1))
    if grep -qF "$BCAST_FLAG" $f && grep -qF "nearby.sharing.TRANSFER_UPDATE" $f; then bl_ok=$((bl_ok + 1))
    else case $f in /data/user_de/*) bl_miss="${bl_miss:+$bl_miss, }device-protected" ;; *) bl_miss="${bl_miss:+$bl_miss, }data" ;; esac; fi
  done
  [ $bl_n -gt 0 ] || { echo "no Play services config file yet"; return; }
  [ -n "$(gms_newstore)" ] && { echo "not in effect: Play services reads a newer core snapshot without it; apply again"; return; }
  if [ $bl_ok = $bl_n ]; then echo "AirDrop receive allowlist in the live config ($bl_ok of $bl_n copies)"
  elif [ $bl_ok -gt 0 ]; then echo "AirDrop receive allowlist in $bl_ok of $bl_n live config copies, missing from the $bl_miss copy; apply again"
  else echo "AirDrop receive allowlist missing from the live config; apply again"; fi
}
AD_SUM=$V/airdrop-test.summary   # the last airdrop-test's verdict, shown in the report
# what logcat holds: a busy phone fills the main buffer in minutes, so a missing line may just be old
log_span() { f=$(logcat -d -b main -v epoch 2>/dev/null | awk 'NF > 2 && $1 ~ /^[0-9]+\./ { print int($1); exit }')
  [ -n "$f" ] && echo "$((($(date +%s) - f) / 60)) min" || echo "unknown"; }
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
  # lines are "<address> <type> <name>\t[<module>]": match the name and module fields exactly. A kernel
  # built with ThinLTO may rename a static symbol to "<name>.llvm.<hash>" (issue #10): take that too.
  a=$(awk -v s="$1" -v m="[$2]" '($3 == s || index($3, s ".llvm.") == 1) && $4 == m {print $1; exit}' /proc/kallsyms)
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

# wonder's ieee80211_register_hw needs large contiguous allocations (mac80211's per-flow tables).
# After many hours up, memory can be too fragmented and the kernel's own compaction gives up: insmod
# fails with "Failed to register mac80211 hardware. Ret: -12" (issue #7). Then compact all memory and retry.
wonder_load() {
  for i in 1 2 3; do
    insmod $AIR/wonder.ko 2>/dev/null && return 0
    klog | tail -n 60 | grep -q 'mac80211 hardware. Ret: -12' || break
    log "airdrop: not enough contiguous memory for wonder (try $i of 3); compacting memory and retrying"
    sync; echo 1 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory; sleep 2
  done
  fail "wonder: $(klog | grep -E 'wonder|page allocation failure' | tail -n 3 | tr '\n' ' ')"
}

airdrop_kernel() {
  A=$AIR
  if [ -d /sys/module/wonder ] && [ -d /sys/module/bwfix ]; then log "airdrop: kernel side already loaded"; AK_LOADED=1; return 0; fi
  # An earlier apply in this boot swapped in the S24 driver but wonder didn't load: load just wonder
  if [ -d /sys/module/bwfix ] && [ -d /sys/module/kiwi_v2 ] && mounted /vendor/firmware/kiwi overlay; then
    log "airdrop: S24 Wi-Fi driver already in; loading wonder"
    wonder_load; log "airdrop: kernel side loaded"; return 0
  fi
  kernel_stock || log "airdrop: kernel $(uname -r) isn't Samsung's; trying anyway ($V/allow-any-kernel). If the kernel refuses the modules, the stock Wi-Fi driver goes back"
  log "airdrop: swapping in the S24 Wi-Fi driver and firmware (Wi-Fi drops for ~30 s)"
  wifi_down
  # cnss2/MHI keep buffers sized for the boot-time firmware; mhifix frees them so the bigger S24
  # firmware gets correctly sized ones. It needs the address of cnss2's static plat_env pointer.
  pe=$(ksym plat_env cnss2) || { back_to_stock; fail "plat_env not found in kallsyms"; }
  b=$(ksect cnss2 .bss) || { back_to_stock; fail "cnss2 .bss address not readable"; }; d=$(( 0x$pe - b ))
  [ $d -ge 0 ] && [ $d -lt 1048576 ] || { back_to_stock; fail "plat_env 0x$pe is not in cnss2 .bss"; }
  insmod $A/mhifix.ko mode=1 plat_env=0x$pe; r=$(klog | grep mhifix | tail -4 | tr '\n' ' ')
  case "$r" in *"tables freed"*"fw_mem DDR freed"*) ;; *) back_to_stock; fail "mhifix: $r" ;; esac
  # S24 firmware over /vendor/firmware/kiwi: an overlay of placeholders, each bound to the downloaded file
  # (the S23 board file stays)
  T=/dev/s23tweaks_fw; FW="amss20.bin phy_ucode20.elf regdb.bin"
  mkdir -p $T; mounted $T tmpfs || mount -t tmpfs -o mode=755 s23tweaks_fw $T
  for f in $FW; do : > $T/$f; done; chmod 644 $T/*; chcon u:object_r:vendor_firmware_file:s0 $T $T/*
  mount -t overlay s23tweaks_fwov -o ro,lowerdir=$T:/vendor/firmware/kiwi /vendor/firmware/kiwi || { back_to_stock; fail "firmware overlay"; }
  for f in $FW; do chmod 644 $A/fw/$f; chcon u:object_r:vendor_firmware_file:s0 $A/fw/$f
    mount -o bind,ro $A/fw/$f /vendor/firmware/kiwi/$f || { back_to_stock; fail "firmware bind $f"; }; done
  insmod $A/kiwi_v2.ko || { back_to_stock; fail "S24 Wi-Fi driver: $(klog | tail -2 | tr '\n' ' ')"; }
  wifi_up; sleep 5
  # Some custom kernels bring the S24 driver up fine alone but not with wifi7's MLO config and S24
  # supplicant (issue #21): drop wifi7 for this boot and retry, so AirDrop still works
  if ! wlan_up && { bound $INI || bound $WPAS; }; then
    log "airdrop: Wi-Fi didn't come up with the wifi7 settings; retrying without them (wifi7 off until a reboot)"
    wifi_down; wifi7_drop
    insmod $A/kiwi_v2.ko || { back_to_stock; fail "S24 Wi-Fi driver: $(klog | tail -2 | tr '\n' ' ')"; }
    wifi_up; sleep 5
  fi
  # bwfix: the S24 firmware asks for a PCIe Gen3 link when AirDrop starts; the S23 refuses (Gen2
  # max) and the firmware crashes on the refusal. bwfix sets Gen2 and acknowledges.
  cb=$(ksym cnss_mhi_bw_scale.cfi_jt cnss2)
  [ -d /sys/module/bwfix ] || insmod $A/bwfix.ko ${cb:+orig=0x$cb} || fail "bwfix: $(klog | tail -2 | tr '\n' ' ')"
  wonder_load
  log "airdrop: kernel side loaded ($(klog | grep -o 'wonder: connected to wlan.*' | tail -1))"
}

# ---------- wifi7: Wi-Fi 7 multi-link (MLO) as a Wi-Fi client ----------
# The S24 driver (airdrop) has MLO built in, but the S23's wpa_supplicant has no 802.11be/MLO code
# and the S23's driver config doesn't turn MLO on. Use the S24's wpa_supplicant (same Samsung HAL
# extensions; it needs one AIDL library the S23 vendor image lacks, added to /vendor/lib64 with a
# read-only RAM overlay) and the S23's own driver config plus the S24's four MLO lines.
W7=$LY/mlo; INI=/vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini; WPAS=/vendor/bin/hw/wpa_supplicant
MLO_INI="mlo_support_link_num=2 mlo_5gl_5gh_mlsr=1 oem_eht_mlo_crypto_bitmap=0 epcs_support_enable=1"
W7_FAIL=/dev/s23tweaks_w7fail   # set by wifi7_drop: Wi-Fi didn't come up with wifi7 this boot
wifi7_bind() {   # sets W7_INI_NEW=1 when the driver has to be reloaded to read the config
  A=$AIR/wifi7
  [ -e $W7_FAIL ] && { log "wifi7: skipped: Wi-Fi didn't come up with it earlier in this boot (custom kernel?); a reboot retries it"; W7_OFF=1; return 0; }
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
wifi7_drop() {   # undo wifi7's binds, with the supplicant stopped and the driver unloaded
  bound $INI && umount $INI; wifi7_unbind_sup; : > $W7_FAIL; W7_OFF=1; W7_INI_NEW=0
}
wifi7_reload() {   # the AirDrop driver was already loaded before the config was bound
  log "wifi7: reloading the Wi-Fi driver so it reads the MLO settings (Wi-Fi drops for ~15 s)"
  wifi_down
  insmod $AIR/kiwi_v2.ko || { back_to_stock; fail "wifi7: kiwi_v2 reload: $(klog | tail -2 | tr '\n' ' ')"; }
  wifi_up
  wonder_load
}
wifi7_check() {
  # If Wi-Fi can't run with the S24 supplicant, go back to the S23's and carry on without MLO.
  # Wi-Fi switched off before the apply: turn it on only for the check (no need to wait for a
  # network then), and off again afterwards.
  was_off=${WIFI_WAS_OFF:-0}
  wifi_off && cmd wifi set-wifi-enabled enabled
  wait_for 60 wlan_up; [ $was_off = 1 ] || wait_for 90 connected
  # The S24 supplicant only runs once the supplicant restarts. A driver reload does that, but when the
  # driver already has the MLO settings (an earlier apply this boot fell back to the S23 supplicant and
  # kept them) nothing restarts it, so cycle Wi-Fi once before deciding it failed.
  if bound $WPAS && [ "$(md5 /proc/$(pidof wpa_supplicant)/exe 2>/dev/null)" != "$(md5 $AIR/wifi7/wpa_supplicant)" ]; then
    log "wifi7: restarting Wi-Fi so the S24 supplicant takes over (Wi-Fi drops for a few seconds)"
    cmd wifi set-wifi-enabled disabled; wait_for 15 wifi_off; wait_for 20 sup_stopped
    cmd wifi set-wifi-enabled enabled; wait_for 60 wlan_up; [ $was_off = 1 ] || wait_for 90 connected
  fi
  if [ "$(getprop init.svc.wpa_supplicant)" = running ] && cmd wifi status | grep -q "Wifi is enabled" &&
     [ "$(md5 /proc/$(pidof wpa_supplicant)/exe)" = "$(md5 $AIR/wifi7/wpa_supplicant)" ]; then
    log "wifi7: Wi-Fi running with the S24 supplicant ($(cmd wifi status | grep -oE 'Wi-Fi standard: [^,]*' | head -1))"
  else
    log "wifi7: warning: Wi-Fi didn't come up with the S24 supplicant; switching back to the S23 one (no MLO)"
    cmd wifi set-wifi-enabled disabled; wait_for 15 wifi_off; wait_for 20 sup_stopped; wifi7_unbind_sup
    [ $was_off = 1 ] || { cmd wifi set-wifi-enabled enabled; wait_for 60 wlan_up; }
  fi
  [ $was_off = 1 ] && { cmd wifi set-wifi-enabled disabled; log "wifi7: Wi-Fi was off before the apply, so it's off again"; }
  return 0
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
  running loop || (exec setsid sh $D/tweaks.sh loop </dev/null >/dev/null 2>&1) &
  running guard || (exec setsid sh $D/tweaks.sh guard </dev/null >/dev/null 2>&1) &
  running moseyheal || (exec setsid sh $D/tweaks.sh moseyheal </dev/null >/dev/null 2>&1) &
  n=20; until service check com.google.android.moseyservice.IMoseyService/default | grep -q found; do
    n=$((n-1)); [ $n = 0 ] && fail "IMoseyService did not register"; sleep 1; done
  log "airdrop: mosey_server running"
  # Mosey 1.0.980159239 and later check for IMoseyService once, at boot, and disable their own
  # ExternalSharingService when it isn't there, which it never is yet: mosey_server only starts here.
  # Play services then finds no AirDrop provider. Enable it again now that the service is registered.
  pm enable --user 0 com.google.android.mosey/.ExternalSharingService >/dev/null 2>&1 &&
    log "airdrop: Mosey's sharing service enabled" || log "airdrop: warning: could not enable Mosey's sharing service"
  mosey_keep_mounts
  gms_flags
  gms_bcast_flag
  # mosey_hop_flag: not called until its override reaches Mosey (see the function)
}

# --- bytes for the allowlist flag: protobuf field 1 (string), repeated; built with printf octal escapes ---
pb_oct() { printf "\\$(printf '%03o' $1)"; }
pb_varint() { n=$1; while [ $n -ge 128 ]; do pb_oct $(( (n & 127) | 128 )); n=$((n >> 7)); done; pb_oct $n; }
bcast_value() { for a in $BCAST_ACTIONS; do pb_oct 10; pb_varint ${#a}; printf '%s' "$a"; done; }
# one Flag entry (name + bytes value) as the snapshot's repeated field 5
bcast_entry() {
  v=$1; inner=$W/inner.bin
  { pb_oct 10; pb_varint ${#BCAST_FLAG}; printf '%s' "$BCAST_FLAG"; pb_oct 50; pb_varint $(wc -c < $v); cat $v; } > $inner
  { pb_oct 42; pb_varint $(wc -c < $inner); cat $inner; }
}

# Where the broadcast guard reads BCAST_FLAG from. Play services builds config package com.google.android.gms as
# direct-boot aware (kavc: hmpu.c()/d() set), so its snapshot lives in DEVICE-PROTECTED storage (/data/user_de/0),
# not in /data/data. The /data/data copy normally doesn't exist, which is why only patching that path never took
# effect (v1.8.10: "no Play services config file yet" while Dqjx.c kept crashing). Patch whichever copies exist.
BCAST_SNAPS="/data/user_de/0/com.google.android.gms/files/phenotype/shared/com.google.android.gms.pb /data/data/com.google.android.gms/files/phenotype/shared/com.google.android.gms.pb"
# bcast_stock FILE: the actions already in FILE's entry for BCAST_FLAG, one per line (none if it has no entry).
# Snapshot entries are field 5 {1: name, other length-delimited field: value}; the value is repeated field 1 strings.
bcast_stock() {
  od -An -v -tx1 "$1" | tr -d ' \n' | awk -v fh="$(printf '%s' "$BCAST_FLAG" | od -An -v -tx1 | tr -d ' \n')" '
    function hv(c) { return index("0123456789abcdef", c) - 1 }
    function byte(k) { return hv(substr(h, 2 * k + 1, 1)) * 16 + hv(substr(h, 2 * k + 2, 1)) }
    function varint(   v, m, b) { v = 0; m = 1
      while (i < n) { b = byte(i); i++; v += (b % 128) * m; m *= 128; if (b < 128) break }
      return v }
    function str(p, l,   s, k) { s = ""; for (k = p; k < p + l; k++) s = s sprintf("%c", byte(k)); return s }
    { h = $0; n = length(h) / 2; i = 0
      while (i < n) {
        key = varint(); wt = key % 8; fn = int(key / 8)
        if (wt == 0) varint()
        else if (wt == 1) i += 8
        else if (wt == 5) i += 4
        else if (wt == 2) { len = varint(); p = i; e = p + len
          if (fn == 5) { name = ""; val = -1; vl = 0
            while (i < e) { k2 = varint(); w2 = k2 % 8
              if (w2 == 0) varint()
              else if (w2 == 1) i += 8
              else if (w2 == 5) i += 4
              else if (w2 == 2) { l2 = varint(); if (int(k2 / 8) == 1) name = substr(h, 2 * i + 1, 2 * l2); else if (val < 0) { val = i; vl = l2 }; i += l2 }
              else break }
            if (name == fh && val >= 0) { i = val; e2 = val + vl
              while (i < e2) { k3 = varint(); if (k3 % 8 != 2) break; l3 = varint(); if (int(k3 / 8) == 1) print str(i, l3); i += l3 }
              exit } }
          i = e }
        else exit
      } }'
}
# Remove every top-level snapshot entry (field 5) whose flag name is BCAST_FLAG from file $1, in place.
# A stale entry must go before the new one is appended: two entries with one name break the reader's map.
pb_drop_flag() {
  pd_f=$1; pd_fh=$(printf '%s' "${2:-$BCAST_FLAG}" | od -An -v -tx1 | tr -d ' \n'); pd_n=0
  while [ $pd_n -lt 8 ]; do
    pd_r=$(od -An -v -tx1 "$pd_f" | tr -d ' \n' | awk -v fh="$pd_fh" '
      function hv(c) { return index("0123456789abcdef", c) - 1 }
      function byte(k) { return hv(substr(h, 2 * k + 1, 1)) * 16 + hv(substr(h, 2 * k + 2, 1)) }
      function varint(   v, m, b) { v = 0; m = 1
        while (i < n) { b = byte(i); i++; v += (b % 128) * m; m *= 128; if (b < 128) break }
        return v }
      { h = $0; n = length(h) / 2; i = 0
        while (i < n) {
          st = i; key = varint(); wt = key % 8; fn = int(key / 8)
          if (wt == 0) varint()
          else if (wt == 1) i += 8
          else if (wt == 5) i += 4
          else if (wt == 2) { len = varint(); p = i; i += len
            if (fn == 5 && byte(p) == 10) { q = p + 1; save = i; i = q; nl = varint(); nstart = i; i = save
              if (substr(h, 2 * nstart + 1, 2 * nl) == fh && nl * 2 == length(fh)) { print st, i; exit } } }
          else exit
        } }')
    [ -n "$pd_r" ] || break
    set -- $pd_r
    head -c $1 "$pd_f" > "$pd_f.a" && tail -c +$(($2 + 1)) "$pd_f" > "$pd_f.b" && cat "$pd_f.a" "$pd_f.b" > "$pd_f" || break
    rm -f "$pd_f.a" "$pd_f.b"; pd_n=$((pd_n + 1))
  done
  rm -f "$pd_f.a" "$pd_f.b"
}

# Play services' broadcast guard (see BCAST_FLAG): override its allowlist so an incoming AirDrop share's
# TRANSFER_UPDATE no longer crashes Play services. Edits a copy of the database, like gms_flags.
gms_bcast_flag() {
  G=/data/data/com.google.android.gms; DB=$G/databases/phenotype.db
  SN=$G/files/phenotype/shared/com.google.android.gms.pb
  SQ=$AIR/sqlite3; W=$R/gms2; rm -rf $W; mkdir -p $W
  [ -f $DB ] || return
  am force-stop com.google.android.gms
  cp $DB $W/p.db; [ -f $DB-wal ] && cp $DB-wal $W/p.db-wal
  id=$($SQ $W/p.db "select config_package_id from config_packages where name='com.google.android.gms'")
  [ -n "$id" ] || { log "airdrop: Play services has no core config yet; AirDrop receive allowlist not set"; rm -rf $W; return; }
  # the phone's own list (from the live snapshot) plus the Nearby actions, so entries Google adds are kept
  stock=""; for SN in $BCAST_SNAPS; do [ -f $SN ] && stock="$stock $(bcast_stock $SN | grep -E '^[A-Za-z0-9_.]+$' | tr '\n' ' ')"; done
  [ -n "$(echo $stock)" ] || stock=$BCAST_STOCK
  BCAST_ACTIONS=$(printf '%s\n' $stock $BCAST_NEARBY | awk 'NF && !s[$0]++' | tr '\n' ' ')
  bcast_value > $W/val.bin
  hex=$(od -An -v -tx1 $W/val.bin | tr -d ' \n')
  # keep what Play services had for the flag (issue #41): the report shows it, so the list's format can be checked
  mkdir -p $V/backup
  for SN in $BCAST_SNAPS; do [ -f $SN ] && [ ! -f $V/backup/bcast_stock_snap.pb ] && ! grep -qF nearby.sharing.TRANSFER_UPDATE $SN && cp $SN $V/backup/bcast_stock_snap.pb; done
  $SQ $W/p.db "select 'flag-tables', group_concat(name) from sqlite_master where type='table'" > $V/backup/bcast_db.txt 2>&1
  [ -n "$hex" ] || { log "airdrop: could not build the AirDrop receive allowlist"; rm -rf $W; return; }
  ok=$($SQ $W/p.db "PRAGMA integrity_check;
    DELETE FROM experiment_states_to_overrides WHERE override_id IN (SELECT override_id FROM flag_overrides WHERE config_package_id=$id AND account_id=0 AND name='$BCAST_FLAG');
    DELETE FROM flag_overrides WHERE config_package_id=$id AND account_id=0 AND name='$BCAST_FLAG';
    INSERT INTO flag_overrides (config_package_id, account_id, name, value, type, source) VALUES ($id, 0, '$BCAST_FLAG', x'$hex', 5, 0);
    INSERT OR IGNORE INTO experiment_states_to_overrides (experiment_state_id, override_id)
      SELECT s.experiment_state_id, o.override_id FROM experiment_states s, flag_overrides o
      WHERE s.config_package_id=$id AND o.config_package_id=$id AND o.name='$BCAST_FLAG';
    PRAGMA wal_checkpoint(TRUNCATE);" | head -1)
  [ "$ok" = ok ] || { log "airdrop: Play services database check failed ($ok); AirDrop receive allowlist not set"; rm -rf $W; return; }
  am force-stop com.google.android.gms
  cat $W/p.db > $DB && rm -f $DB-wal $DB-shm
  # the live snapshot(s): put the entry in now so it applies without waiting for Play services to rebuild them.
  # An existing entry for the flag (the server's stock list) is cut out first: a duplicate name breaks the reader.
  bc_done=0
  for SN in $BCAST_SNAPS; do
    [ -f $SN ] || continue
    if grep -qF "$BCAST_FLAG" $SN && grep -qF "nearby.sharing.TRANSFER_UPDATE" $SN; then
      bc_done=$((bc_done + 1)); log "airdrop: AirDrop receive allowlist already in $SN"; continue
    fi
    cp $SN $W/s.pb && pb_drop_flag $W/s.pb && bcast_entry $W/val.bin >> $W/s.pb && cat $W/s.pb > $SN &&
      { bc_done=$((bc_done + 1)); log "airdrop: AirDrop receive allowlist on in $SN (Play services' broadcast guard lets Nearby's transfer updates through)"; } ||
      log "airdrop: warning: could not patch $SN"
  done
  [ $bc_done -gt 0 ] || log "airdrop: AirDrop receive allowlist is in the database; Play services has no live config file for it yet (looked in $BCAST_SNAPS)"
  # Mosey/Quick Share restart Play services between the DB write and the snapshot write above; a process started in
  # that window keeps the OLD list in memory and still crashes on TRANSFER_UPDATE (v1.8.11: files right, crash anyway).
  # move the newer store's core snapshot aside so the guard reads the patched list above
  ns=0; for f in $(gms_newstore); do
    [ -f $V/backup/core-newstore.pb ] || cp -p "$f" $V/backup/core-newstore.pb
    mv -f "$f" "$f.s23off" && ns=$((ns + 1))
  done
  [ $ns = 0 ] || log "airdrop: moved Play services' newer core snapshot aside ($ns file), so the AirDrop receive allowlist applies"
  # Stop it once more now that the files are final, let it come back, and check the entry survived.
  am force-stop com.google.android.gms
  sleep 4
  bc_ok=0
  for SN in $BCAST_SNAPS; do [ -f $SN ] && grep -qF "$BCAST_FLAG" $SN && grep -qF "nearby.sharing.TRANSFER_UPDATE" $SN && bc_ok=1; done
  gp=$(pidof com.google.android.gms 2>/dev/null | cut -d' ' -f1)
  if [ $bc_ok = 1 ]; then log "airdrop: AirDrop receive allowlist final; Play services restarted after it (pid ${gp:-not running yet})"
  else log "airdrop: warning: Play services dropped the AirDrop receive allowlist when it restarted"; fi
  rm -rf $W
}

# Mosey's own flag 45768305 (config mosey_app_android#com.google.android.mosey, Mosey 1.0.980159239+): when on,
# Mosey asks mosey_server whether the Wi-Fi chip can hop between the AirDrop channel and the router's, and if
# so it keeps Wi-Fi connected instead of "Disconnect Wi-Fi because STA and mosey are running on the same band"
# (issue #42). The S23's daemon reports hw_channel_hopping_supported: Some(true). Mosey reads its flags only from
# Play services' newer store, which can't be patched (names hashed), so the override goes in the database only.
# Don't move Mosey's snapshots aside: Play services never rebuilds them, and Mosey then logs "Unable to retrieve
# flag snapshot ... using defaults" and runs with every flag at its default (seen 2026-11-28, Mosey 1.0.980159239).
# The override is not in effect yet (5 GHz still disconnects), so airdrop_post doesn't call this; kept for the
# follow-up. Older Mosey builds ignore the flag.
MOSEY_CFG='mosey_app_android#com.google.android.mosey'; MOSEY_HOP=45768305
mosey_newstore() {
  grep -rlaF " $MOSEY_CFG " --include="*.pb$1" /data/data/com.google.android.gms/app_phenotype_shared \
    /data/user_de/0/com.google.android.gms/app_phenotype_shared 2>/dev/null |
    while read -r f; do
      [ "$(head -c 120 "$f" | grep -aoE ' [A-Za-z0-9_.#]+ -?[0-9]+' | head -1 | cut -d' ' -f2)" = "$MOSEY_CFG" ] && echo "$f"
    done
}
mosey_hop_flag() {
  G=/data/data/com.google.android.gms; DB=$G/databases/phenotype.db; SQ=$AIR/sqlite3; W=$R/gms3; rm -rf $W; mkdir -p $W
  [ -f $DB ] || return
  am force-stop com.google.android.gms
  cp $DB $W/p.db; [ -f $DB-wal ] && cp $DB-wal $W/p.db-wal
  id=$($SQ $W/p.db "select config_package_id from config_packages where name='$MOSEY_CFG'")
  [ -n "$id" ] || { log "airdrop: Play services has no Mosey config yet; Wi-Fi channel hopping not set (open Quick Share once, then apply again)"; rm -rf $W; return; }
  ok=$($SQ $W/p.db "PRAGMA integrity_check;
    INSERT OR IGNORE INTO flag_overrides (config_package_id, account_id, name, value, type, source) VALUES ($id, 0, '$MOSEY_HOP', 1, 2, 0);
    INSERT OR IGNORE INTO experiment_states_to_overrides (experiment_state_id, override_id)
      SELECT s.experiment_state_id, o.override_id FROM experiment_states s, flag_overrides o
      WHERE s.config_package_id=$id AND o.config_package_id=$id AND o.name='$MOSEY_HOP';
    PRAGMA wal_checkpoint(TRUNCATE);" | head -1)
  [ "$ok" = ok ] || { log "airdrop: Play services database check failed ($ok); Wi-Fi channel hopping not set"; rm -rf $W; return; }
  am force-stop com.google.android.gms; am force-stop com.google.android.mosey
  cat $W/p.db > $DB && rm -f $DB-wal $DB-shm
  # put back snapshots that v1.8.15-airdropfix moved aside
  ns=0; for f in $(mosey_newstore .s23off); do mv -f "$f" "${f%.s23off}" && ns=$((ns + 1)); done
  log "airdrop: Mosey Wi-Fi channel hopping override set in Play services' database (not in effect yet; $ns moved-aside snapshot(s) restored)"
  rm -rf $W
}

# wearretry: when a Wear OS watch (Galaxy Watch) drops off Bluetooth, Samsung's watch plugin sets Play
# services' retry strategy for it to OFF, but Play services overrides OFF to LOW_POWER unless its flag
# enable_off_retry_strategy (config com.google.android.gms.wearable) is on. Each plugin call also resets the
# retry backoff, so a watch that keeps coming and going, or answers without its Wear service (after a
# restart, before it's unlocked), gets retried every few seconds all night, with a wakelock each time.
# The flag lets OFF stay OFF; the plugin sets LOW_LATENCY again when the watch is back. Untested on a real
# disconnect. Needs the airdrop download's sqlite3; edits a copy of the database, like gms_flags.
WR_FLAG=enable_off_retry_strategy; WR_CFG=com.google.android.gms.wearable
WR_SNAP=/data/data/com.google.android.gms/files/phenotype/shared/$WR_CFG.pb
wr_live() { [ -f $WR_SNAP ] && grep -qF $WR_FLAG $WR_SNAP; }
wr_set() {   # wr_set on|off
  G=/data/data/com.google.android.gms; DB=$G/databases/phenotype.db; SQ=$AIR/sqlite3; W=$R/gmsw
  [ -x $SQ ] || { log "wearretry: needs the AirDrop download (its sqlite3); pick AirDrop and apply again"; return 1; }
  if [ ! -f $DB ]; then
    if [ "${S23T_BOOT:-0}" = 1 ]; then log "wearretry: Play services storage is locked until first unlock; the flag from the earlier run stays"
    else log "wearretry: Play services database not found; not changed"; fi
    return 1
  fi
  rm -rf $W; mkdir -p $W; am force-stop com.google.android.gms
  cp $DB $W/p.db; [ -f $DB-wal ] && cp $DB-wal $W/p.db-wal
  id=$($SQ $W/p.db "select config_package_id from config_packages where name='$WR_CFG'")
  [ -n "$id" ] || { log "wearretry: Play services has no Wear OS config yet (no watch paired); not changed"; rm -rf $W; return 1; }
  sql="PRAGMA integrity_check;
    DELETE FROM experiment_states_to_overrides WHERE override_id IN (SELECT override_id FROM flag_overrides WHERE config_package_id=$id AND account_id=0 AND name='$WR_FLAG');
    DELETE FROM flag_overrides WHERE config_package_id=$id AND account_id=0 AND name='$WR_FLAG';"
  [ $1 = on ] && sql="$sql INSERT INTO flag_overrides (config_package_id, account_id, name, value, type, source) VALUES ($id, 0, '$WR_FLAG', 1, 2, 0);
    INSERT OR IGNORE INTO experiment_states_to_overrides (experiment_state_id, override_id)
      SELECT s.experiment_state_id, o.override_id FROM experiment_states s, flag_overrides o
      WHERE s.config_package_id=$id AND o.config_package_id=$id AND o.name='$WR_FLAG';"
  ok=$($SQ $W/p.db "$sql PRAGMA wal_checkpoint(TRUNCATE);" | head -1)
  [ "$ok" = ok ] || { log "wearretry: Play services database check failed ($ok); not changed"; rm -rf $W; return 1; }
  am force-stop com.google.android.gms
  cat $W/p.db > $DB && rm -f $DB-wal $DB-shm    # cat keeps the file's owner and SELinux label
  # the live config, so it applies now: cut out any entry for the flag, then (on) append a field-5 entry
  # (name, boolean true)
  if [ -f $WR_SNAP ]; then
    cp $WR_SNAP $W/s.pb && pb_drop_flag $W/s.pb $WR_FLAG &&
      { [ $1 = off ] || printf "\\052\\$(printf '%03o' $(( ${#WR_FLAG} + 4 )))\\012\\$(printf '%03o' ${#WR_FLAG})%s\\030\\001" $WR_FLAG >> $W/s.pb; } &&
      cat $W/s.pb > $WR_SNAP
  fi
  am force-stop com.google.android.gms; rm -rf $W
}

# KernelSU Next's kernel_umount strips module mounts from every app without root, so Mosey's process
# sees the empty placeholder MoseyApp.apk under the overlay ("Failed to find magic") and crashes when
# Play services binds it; Quick Share then says it stopped. Keep the mounts for Mosey only.
mosey_keep_mounts() {
  K=/data/adb/ksud
  $K profile get com.google.android.mosey >/dev/null 2>&1 || return 0   # not KernelSU Next
  $K profile get com.google.android.mosey | grep -q '"umount_modules": false' && return 0
  uid=$(pm list packages -U com.google.android.mosey | sed -n 's/.*uid:\([0-9]*\).*/\1/p' | head -n 1)
  [ -n "$uid" ] || { log "airdrop: warning: Mosey's uid not found; KernelSU may hide its mounts"; return 0; }
  printf '{"key":"com.google.android.mosey","uid":%s,"allow_su":false,"non_root":{"use_default":false,"umount_modules":false}}' $uid |
    $K profile set - >/dev/null 2>&1 && log "airdrop: KernelSU keeps the module's mounts for Mosey (Umount modules off)" ||
    log "airdrop: warning: could not turn off KernelSU's Umount modules for Mosey"
}

# Play services only binds Mosey when server-side Nearby flags are on. Add them as local
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
  in_list=""; total=0; sql="PRAGMA integrity_check;"
  for f in $NEARBY_FLAGS; do
    in_list="${in_list:+$in_list, }'$f'"
    total=$((total + 1))
    sql="$sql INSERT OR IGNORE INTO flag_overrides (config_package_id, account_id, name, value, type, source) VALUES ($id, 0, '$f', 1, 2, 0);"
  done
  sql="$sql INSERT OR IGNORE INTO experiment_states_to_overrides (experiment_state_id, override_id)
    SELECT s.experiment_state_id, o.override_id FROM experiment_states s, flag_overrides o
    WHERE s.config_package_id=$id AND o.config_package_id=$id AND o.name IN ($in_list);
    PRAGMA wal_checkpoint(TRUNCATE);"
  ok=$($SQ $W/p.db "$sql" | head -1)
  [ "$ok" = ok ] || { log "airdrop: Play services database check failed ($ok); flags not set"; return; }
  n=$($SQ $W/p.db "select count(*) from flag_overrides where config_package_id=$id and name in ($in_list) and value=1")
  am force-stop com.google.android.gms
  cat $W/p.db > $DB && rm -f $DB-wal $DB-shm    # cat keeps the file's owner and SELinux label
  if [ -f $SNAP ]; then
    cp $SNAP $W/s.pb; pb_ok=1
    for f in $NEARBY_FLAGS; do
      if $AIR/pbflag $W/s.pb $W/s.next "$f" 1 >/dev/null 2>&1; then
        mv $W/s.next $W/s.pb
      else
        # Fallback for pre-existing airdrop tarballs whose pbflag binary only accepts numeric names:
        # append a valid protobuf field-5 boolean entry if the string flag isn't already in the snapshot.
        case "$f" in
          *[!0-9]*)
            if ! grep -Fq "$f" $W/s.pb; then
              nl=${#f}; el=$((nl + 4))
              if [ $nl -lt 128 ] && [ $el -lt 128 ]; then
                printf "\\$(printf '%03o' 42)\\$(printf '%03o' $el)\\$(printf '%03o' 10)\\$(printf '%03o' $nl)%s\\030\\001" "$f" >> $W/s.pb
              else
                pb_ok=0; break
              fi
            fi ;;
          *) pb_ok=0; break ;;
        esac
      fi
    done
    [ $pb_ok = 1 ] && cat $W/s.pb > $SNAP
  fi
  # move the newer store's Nearby snapshot aside so Play services falls back to the patched one above
  ns=0; for f in $(nearby_newstore); do
    [ -f $V/backup/nearby-newstore.pb ] || cp -p "$f" $V/backup/nearby-newstore.pb
    mv -f "$f" "$f.s23off" && ns=$((ns + 1))
  done
  [ $ns = 0 ] || log "airdrop: moved Play services' newer Nearby snapshot aside ($ns file), so the flags apply"
  rm -rf $W
  log "airdrop: Play services Nearby flags on ($n of $total overrides present)"
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
  o=$(for k in $(cut -d= -f1 $R/ff.kv); do grep -m1 -o "<SEC_FLOATING_FEATURE_$k>[^<]*" $FF | sed 's/<SEC_FLOATING_FEATURE_//; s/>/=/'; done | tr '\n' ' ')
  [ -n "$o" ] && log "feature flags: stock values $o"
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
#  logvideo: the S24's Log recording in Pro video (the S23's sensor/HAL already records 10-bit
#            Log). Not SUPPORT_PREVIEW_LUT: the LUT preview is drawn by the S24 camera HAL (its
#            LogConverter uniplugin); the S23 HAL has none, and the LUT button crashed the camera.
#  camextras: Super steady's horizontal lock (a third Super steady option; hlock_apply makes it level)
#  wideflash: the flash in Photo and the torch in Video on the 0.6x ultrawide, and Camera Assistant's
#             matching wide-flash option. Both are switches in camera-feature.xml; no APK or HAL patch.
#  prowbtint: the Tint slider next to the colour temperature in Pro and Pro video's white balance.
#  zoomrocker: the smooth zoom rocker/slider in the standard Video mode.
#  slowmoaf: tap-to-focus while recording in Slow motion (its Camera Assistant flag is set in apply).
#  extstorage: recording straight to a USB-C SSD/drive, in every video mode (camfeat_apply flips
#              external-storage-support="false" to "true" on the resolution map lines).
#  anamorphic: Camera Assistant's anamorphic lens desqueeze (1.33x / 1.55x / 2.0x).
#  profps: extra Pro video frame rates (4K 25/48/50/100/120, FHD 25/48/50/100, 8K 25 and the
#          21:9 Cinema rates), plus Slow motion 4K120 and FHD120 (slow_motion added to their
#          modes) and the FHD240 entry rebuilt so the resolution list is complete. The 10x tele
#          stays hidden in the Pro modes unless the Camera APK patch is bound (profps).
#          cam24fps (24 fps in standard Video, rear and front) and slowmo4k120 (4K120/FHD120 in
#          Slow motion, FHD240 rebuilt) are folded into this tweak: all three need the same Camera
#          APK patch and camera-feature.xml edit. slowmo4k120's own availability check ran before
#          camfeat_apply added the 4K120 entry, so a boot apply on stock firmware skipped it.
#  uhd60lenses: seamless-zoom-support on the stock BACK 3840X2160_60FPS map, so the 0.6x/1x/3x/10x
#               lens buttons remain available in UHD 60 Video instead of a remosaic-crop fallback.
#               The related feature tags (SUPPORT_SEAMLESS_ZOOM, the three 60 fps lens tags, the tele
#               zoom levels) are already true on the S23 Ultra firmware this tweak applies to.
# Never add SUPPORT_BACK_WIDE_NORMAL_DUAL_PORTRAIT_VIDEO, SUPPORT_BACK_PORTRAIT_VIDEO_TELE_DUAL or
# CAMERA_SUPPORT_SEAMLESS_PORTRAITVIDEO: on the S23 they crash the camera ("Zoom is not supported").
CF_LOG='<local name="SUPPORT_LOG_VIDEO" value="true"/>'
CF_HLOCK='<local name="SUPPORT_SUPER_STEADY_HORIZONTAL_LOCK" value="true"/>'
CF_WIDEFLASH='<local name="SUPPORT_FLASH_IN_WIDE_LENS" value="true"/>'
CF_WIDEFLASH_CA='<local name="SUPPORT_CAMERA_ASSISTANT_WIDE_FLASH_MENU" value="true"/>'
CF_PROWBTINT='<local name="SUPPORT_PRO_WHITE_BALANCE_TINT" value="true"/>'
CF_ZOOMROCKER='<local name="SUPPORT_VIDEO_MODE_ZOOM_ROCKER" value="true"/>'
CF_SLOWMOAF='<local name="SUPPORT_SLOW_MOTION_AF_DURING_RECORDING" value="true"/>'
CF_ANAMORPHIC='<local name="SUPPORT_CAMERA_ASSISTANT_ANAMORPHIC_LENS" value="true"/>'
CF_ANAMORPHIC_SCALER='<local name="SUPPORT_CAMERA_ASSISTANT_ANAMORPHIC_LENS_HW_SCALER" value="true"/>'
CF_SM_240FPS='<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1080_240FPS" value="true" hdr="true" hdr10="false" snapshot-support="false" snapshot-size="4000x2252" vdis="false" super-vdis="false" effect="false" object-tracking="false" seamless-zoom-support="false" physical-zoom-supported="false" external-storage-support="true" supported-mode="slow_motion"/>'
CF_PROFPS='<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_25FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x2252" vdis="true" super-vdis="false" effect="false" object-tracking="true" seamless-zoom-support="true" physical-zoom-supported="false" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_48FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x2252" vdis="true" super-vdis="false" effect="false" object-tracking="true" seamless-zoom-support="false" physical-zoom-supported="true" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_50FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x2252" vdis="true" super-vdis="false" effect="false" object-tracking="true" seamless-zoom-support="false" physical-zoom-supported="true" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1080_25FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x2252" vdis="true" super-vdis="true" effect="true" object-tracking="true" seamless-zoom-support="true" physical-zoom-supported="false" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1080_48FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x2252" vdis="true" super-vdis="true" effect="true" object-tracking="true" seamless-zoom-support="true" physical-zoom-supported="false" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1080_50FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x2252" vdis="true" super-vdis="true" effect="true" object-tracking="true" seamless-zoom-support="true" physical-zoom-supported="false" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1080_100FPS" value="true" hdr="true" hdr10="false" snapshot-support="false" snapshot-size="4000x2252" vdis="false" super-vdis="false" effect="false" object-tracking="false" seamless-zoom-support="false" physical-zoom-supported="false" external-storage-support="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_7680X4320_25FPS" value="true" hdr="true" hdr10="false" snapshot-support="true" snapshot-size="4000x2252" vdis="true" super-vdis="false" effect="false" object-tracking="false" seamless-zoom-support="false" physical-zoom-supported="false" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_120FPS" value="true" hdr="true" hdr10="false" snapshot-support="false" snapshot-size="4000x2252" vdis="false" super-vdis="false" effect="false" object-tracking="false" seamless-zoom-support="false" physical-zoom-supported="false" external-storage-support="true" supported-mode="pro_video,slow_motion"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_100FPS" value="true" hdr="true" hdr10="false" snapshot-support="false" snapshot-size="4000x2252" vdis="false" super-vdis="false" effect="false" object-tracking="false" seamless-zoom-support="false" physical-zoom-supported="false" external-storage-support="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X1644_25FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x1716" vdis="true" super-vdis="false" effect="false" object-tracking="true" seamless-zoom-support="true" physical-zoom-supported="false" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X1644_48FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x1716" vdis="true" super-vdis="false" effect="false" object-tracking="true" seamless-zoom-support="false" physical-zoom-supported="true" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X1644_50FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x1716" vdis="true" super-vdis="false" effect="false" object-tracking="true" seamless-zoom-support="false" physical-zoom-supported="true" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X1644_100FPS" value="true" hdr="true" hdr10="false" snapshot-support="false" snapshot-size="4000x1716" vdis="false" super-vdis="false" effect="false" object-tracking="false" seamless-zoom-support="false" physical-zoom-supported="false" external-storage-support="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X1644_120FPS" value="true" hdr="true" hdr10="false" snapshot-support="false" snapshot-size="4000x1716" vdis="false" super-vdis="false" effect="false" object-tracking="false" seamless-zoom-support="false" physical-zoom-supported="false" external-storage-support="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X824_25FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x1716" vdis="true" super-vdis="false" effect="true" object-tracking="true" seamless-zoom-support="true" physical-zoom-supported="false" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X824_48FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x1716" vdis="true" super-vdis="false" effect="true" object-tracking="true" seamless-zoom-support="true" physical-zoom-supported="false" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X824_50FPS" value="true" hdr="true" hdr10="true" snapshot-support="true" snapshot-size="4000x1716" vdis="true" super-vdis="false" effect="true" object-tracking="true" seamless-zoom-support="true" physical-zoom-supported="false" external-storage-support="true" touch-af="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X824_100FPS" value="true" hdr="true" hdr10="false" snapshot-support="false" snapshot-size="4000x1716" vdis="false" super-vdis="false" effect="false" object-tracking="false" seamless-zoom-support="false" physical-zoom-supported="false" external-storage-support="true" supported-mode="pro_video"/>
<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_7680X3296_25FPS" value="true" hdr="true" hdr10="false" snapshot-support="true" snapshot-size="4000x1716" vdis="true" super-vdis="false" effect="false" object-tracking="false" seamless-zoom-support="false" physical-zoom-supported="false" external-storage-support="true" supported-mode="pro_video"/>'
cf_add=""; cf_slowmo_modes=""; cf_seamless_modes=""
camfeat_apply() {
  [ -n "$cf_add" ] || [ -n "${cf_video_modes:-}" ] || [ -n "${cf_slowmo_modes:-}" ] || [ -n "${cf_seamless_modes:-}" ] || has extstorage || return 1
  mkdir -p $R; bound $CF && umount $CF
  grep -q '</resources>' $CF || { log "camera: $CF has no </resources>; camera settings skipped"; return 1; }
  grep -v '</resources>' $CF > $R/cf.new
  # a setting the stock file already has (possibly value="false" on some models) gets our line instead
  printf '%s\n' "$cf_add" | while read -r l; do
    [ -n "$l" ] || continue
    n=$(echo "$l" | sed 's/.*name="\([^"]*\)".*/\1/')
    o=$(grep -m1 "name=\"$n\"" $CF | sed 's/^ *//'); [ -n "$o" ] && log "camera: stock camera-feature.xml had $o"
    grep -v "name=\"$n\"" $R/cf.new > $R/cf.tmp && mv $R/cf.tmp $R/cf.new
    echo "    $l" >> $R/cf.new
  done
  # preserve all stock attributes (vdis, hdr, hdr10, seamless-zoom-support) when enabling video mode on 24 fps entries
  for n in ${cf_video_modes:-}; do
    o=$(grep -m1 "name=\"$n\"" $R/cf.new || true)
    [ -n "$o" ] || { log "profps: $n not found in $CF; skipped"; continue; }
    m=$(printf '%s' "$o" | sed -n 's/.*supported-mode="\([^"]*\)".*/\1/p')
    case ",$m," in
      *,video,*) nl=$o ;;
      ,,) nl=$(printf '%s' "$o" | sed 's|supported-mode=""|supported-mode="video"|') ;;
      *) nl=$(printf '%s' "$o" | sed "s|supported-mode=\"$m\"|supported-mode=\"video,$m\"|") ;;
    esac
    nl=$(printf '%s' "$nl" | sed 's|value="false"|value="true"|')
    grep -v "name=\"$n\"" $R/cf.new > $R/cf.tmp && mv $R/cf.tmp $R/cf.new
    printf '%s\n' "$nl" >> $R/cf.new
  done
  # 4K60 on every lens: stock keeps seamless-zoom-support="false" on the UHD 60 fps map, so the
  # camera falls back to a remosaic crop and the 0.6x/3x/10x lens buttons disappear in UHD 60.
  # Flip that one attribute in place (the same change the LSPosed camcorder-map hook makes) and keep
  # all the stock attributes untouched.
  for n in ${cf_seamless_modes:-}; do
    o=$(grep -m1 "name=\"$n\"" $R/cf.new || true)
    [ -n "$o" ] || { log "camera: $n not found in $CF; skipped"; continue; }
    case "$o" in
      *seamless-zoom-support=\"true\"*) nl=$o ;;
      *seamless-zoom-support=\"false\"*) nl=$(printf '%s' "$o" | sed 's/seamless-zoom-support="false"/seamless-zoom-support="true"/') ;;
      *) nl=$(printf '%s' "$o" | sed 's|/>| seamless-zoom-support="true"/>|') ;;
    esac
    grep -v "name=\"$n\"" $R/cf.new > $R/cf.tmp && mv $R/cf.tmp $R/cf.new
    printf '%s\n' "$nl" >> $R/cf.new
    log "camera: $n: seamless zoom on (lens switching at UHD 60)"
  done
  # Slow motion: profps adds the 4K120 entry above through cf_add, already with slow_motion in its
  # modes; add slow_motion to the FHD120 entry in place (keeping its position and stock attributes),
  # then put the rebuilt FHD240 entry last, as the working adb rebuild does.
  if has profps; then
    for n in ${cf_slowmo_modes:-}; do
      o=$(grep -m1 "name=\"$n\"" $R/cf.new || true)
      [ -n "$o" ] || { log "profps: $n not found in $CF; skipped"; continue; }
      m=$(printf '%s' "$o" | sed -n 's/.*supported-mode="\([^"]*\)".*/\1/p')
      case ",$m," in
        *,slow_motion,*) ;;
        ,,)
          if printf '%s' "$o" | grep -q 'supported-mode="'; then
            sed "/name=\"$n\"/ s|supported-mode=\"\"|supported-mode=\"slow_motion\"|" $R/cf.new > $R/cf.tmp && mv $R/cf.tmp $R/cf.new
          else
            sed "/name=\"$n\"/ s|/>| supported-mode=\"slow_motion\"/>|" $R/cf.new > $R/cf.tmp && mv $R/cf.tmp $R/cf.new
          fi ;;
        *)
          sed "/name=\"$n\"/ s|supported-mode=\"$m\"|supported-mode=\"$m,slow_motion\"|" $R/cf.new > $R/cf.tmp && mv $R/cf.tmp $R/cf.new ;;
      esac
    done
    grep -v 'name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1080_240FPS"' $R/cf.new > $R/cf.tmp && mv $R/cf.tmp $R/cf.new
    echo "    $CF_SM_240FPS" >> $R/cf.new
    log "profps: 4K120 and FHD120 in Slow motion, FHD240 menu entry rebuilt"
  fi
  # USB-C storage: allow recording straight to an external drive in every video mode
  if has extstorage; then
    sed '/<local name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_/ s/external-storage-support="false"/external-storage-support="true"/g' $R/cf.new > $R/cf.tmp &&
      mv $R/cf.tmp $R/cf.new
    sed '/<local name="FRONT_CAMCORDER_RESOLUTION_FEATURE_MAP_/ s/external-storage-support="false"/external-storage-support="true"/g' $R/cf.new > $R/cf.tmp &&
      mv $R/cf.tmp $R/cf.new
  fi
  echo '</resources>' >> $R/cf.new
  mv $R/cf.new $R/camera-feature.xml; chmod 644 $R/camera-feature.xml
  chcon u:object_r:system_file:s0 $R/camera-feature.xml
  mount -o bind,ro $R/camera-feature.xml $CF || fail "camera-feature bind mount"
  log "camera settings on: $(printf '%s\n' "$cf_add" | sed -n 's/.*name="\([^"]*\)".*/\1/p' | tr '\n' ' ')${cf_video_modes:-}${cf_seamless_modes:-}$(has extstorage && echo ' external-storage')"
  am force-stop com.sec.android.app.camera 2>/dev/null   # make the camera re-read the file, as the adb rebuild does
}

# Gallery's Log color correction (Edit > LUT, done by Samsung's video editor) reads the S24's LUTs
# from $LV. On the S23 that folder stays empty (init.rc copies them from /system/cameradata/logCubefiles,
# which One UI 9 ships empty for the S23), and its SELinux policy lacks the S24's
# LogVideofilters_data_file type, so the editor (platform_app) can't read vendor_data_file files there
# either: the LUT "loads" with no data and the video stays flat. Bind the S24's LUTs (S928BXXU6EZJB)
# over the folder, labelled system_file, which apps can read.
LV=/data/vendor/LogVideofilters
loglut_bind() {
  LS=$PL/logvideo
  [ -d $LS/preloadfilters ] || { log "logvideo: no LUT download; Log recording only"; return 1; }
  bound $LV && umount $LV
  [ -d $LV ] || { log "logvideo: $LV doesn't exist; LUTs skipped"; return 1; }
  if [ -s $LV/preloadfilters/SamsungLog_to_Rec709_3DLUT_v1.bcube ] &&
     grep -q LogVideofilters_data_file /vendor/etc/selinux/vendor_file_contexts 2>/dev/null; then
    log "logvideo: this firmware has its own LUTs; left alone"; return 1
  fi
  chown -R 1000:1000 $LS; chmod 775 $LS $LS/preloadfilters $LS/Thumbnails
  chmod 674 $LS/preloadfilters/* $LS/Thumbnails/*; chcon -R u:object_r:system_file:s0 $LS
  mount --bind $LS $LV || { log "logvideo: couldn't bind the LUT folder"; return 1; }
  log "logvideo: S24 LUTs for Gallery's Log color correction (Edit > LUT)"
}

# Samsung's low-light video pipeline (Video4kEisVIULL / VideoPreviewVIULL, active at <= 30 fps)
# has no Log10 tuning on the S23's CamX HAL: in dark scenes it spams IPE metadata errors and crushes
# the black floor to #000000 instead of keeping Samsung Log's lifted shadows (unlike 48/50/60/120 fps
# and 8K, which use standard Video4kEIS). Patch IsVIULLEnabled() in com.qti.chi.override.so via a
# cave at the end of the code segment: when recordingDrMode ([x0, #0xe6ac]) == 5 (Log), return 0
# before the cache/FPS checks; otherwise run the displaced instruction and continue normally so
# SDR/HDR10+ video keeps stock VIULL. Found by instructions, not fixed offsets.
LV_LIB=/vendor/lib64/hw/com.qti.chi.override.so
LV_CAVE="529cd588 b8686808 7100151f 54000081 52800000 d50323bf d65f03c0 d104c3ff"
lv_unbind() { while bound $LV_LIB; do umount $LV_LIB || return 1; done; }
lv_bind() { lv_unbind && mount -o bind,ro $V/logvideo_chi.so $LV_LIB; }
lv_find() {
  od -An -v -tx4 -w4 "$1" | awk '
    $1 == "7100603f" && w[5] == "528ca689" && w[12] == "910343fd" && w[13] == "a90d7bfd" && w[14] == "d104c3ff" && w[15] == "d503233f" {
      printf "0x%x\n", (NR - 16) * 4
    }
    { for (i = 15; i > 1; i--) w[i] = w[i-1]; w[1] = $1 }'
}
lv_patch() {
  F=$1; O=$2; m=$(lv_find $F)
  [ "$(echo "$m" | grep -c '^0x')" = 1 ] || { echo "its CHI override code differs (IsVIULLEnabled found $(echo "$m" | grep -c '^0x') times)"; return 1; }
  FN=$((m))
  ph=$((0x$(tb_rd $F 0x20 8))); n=$((0x$(tb_rd $F 0x38 2))); sz=$((0x$(tb_rd $F 0x36 2))); X=""
  while [ $n -gt 0 ]; do
    if [ $((0x$(tb_rd $F $ph 4))) = 1 ] && [ $((0x$(tb_rd $F $((ph + 4)) 4) & 1)) = 1 ]; then
      X=$((0x$(tb_rd $F $((ph + 8)) 8))); XE=$((X + 0x$(tb_rd $F $((ph + 0x20)) 8))); break; fi
    ph=$((ph + sz)); n=$((n - 1))
  done
  [ -n "$X" ] || { echo "no code segment found"; return 1; }
  [ $FN -ge $X ] && [ $((FN + 4)) -lt $XE ] || { echo "IsVIULLEnabled falls outside the code segment"; return 1; }
  K=$(((XE + 3) & ~3)); KE=$((K + 36))
  [ $KE -le $(((XE + 4095) & ~4095)) ] && [ "$(od -An -v -tx1 -j $K -N 36 $F | tr -s ' ' '\n' | grep -c '^00$')" = 36 ] ||
    { echo "no free room at the end of its code"; return 1; }
  cp $F $O || { echo "no room for a copy"; return 1; }
  tb_wr $O $((FN + 4)) $(tb_b $((FN + 4)) $K)   # sub sp, sp, #0x130 -> b cave (keeps paciasp at FN)
  o=$K; for x in $LV_CAVE; do tb_wr $O $o 0x$x; o=$((o + 4)); done
  tb_wr $O $o $(tb_b $o $((FN + 8)))           # back to stp x29, x30, [sp, #0xd0]
  printf 'IsVIULLEnabled 0x%x, cave 0x%x' $FN $K
}
logviull_apply() {
  [ -f $LV_LIB ] || { log "logvideo: $LV_LIB missing; VIULL Log fix skipped"; return 1; }
  if bound $LV_LIB; then
    [ "$(md5 $LV_LIB)" = "$(md5 $V/logvideo_chi.so)" ] && { log "logvideo: low-light Log fix (VIULL bypass) already on"; return 0; }
    log "logvideo: something else is bound over $LV_LIB; VIULL Log fix skipped"; return 1
  fi
  s=$(md5 $LV_LIB)
  if [ "$(cat $V/logvideo_chi.src 2>/dev/null)" != "$s" ] || [ ! -f $V/logvideo_chi.so ]; then
    rm -f $V/logvideo_chi.so $V/logvideo_chi.src
    r=$(lv_patch $LV_LIB $V/logvideo_chi.tmp) || { rm -f $V/logvideo_chi.tmp; log "logvideo: $r; VIULL Log fix skipped"; return 1; }
    mv $V/logvideo_chi.tmp $V/logvideo_chi.so; echo $s > $V/logvideo_chi.src; log "logvideo: patched CHI override made ($r)"
  fi
  chown 0:0 $V/logvideo_chi.so; chmod 644 $V/logvideo_chi.so; chcon u:object_r:vendor_file:s0 $V/logvideo_chi.so
  if tb_restart lv_bind && bound $LV_LIB; then
    log "logvideo: low-light Log fix on (VIULL bypassed when recordingDrMode=5)"
  else
    tb_restart lv_unbind
    log "logvideo: with the CHI patch the camera driver didn't stay up; stock driver back"
    return 1
  fi
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
# wideflash: Samsung Camera reads SUPPORT_FLASH_IN_WIDE_LENS only as the *default* of its own setting
# flash_in_wide_lens (Camera Assistant's wide-flash option toggles it). A camera that has been used saves
# that setting as 0, which keeps the 0.6x flash off however camera-feature.xml says. Turn it on once
# (remembering the value before, for unpicking and cleanup); after that a choice made in Camera
# Assistant is kept.
WF_UNDO=$V/undo/flash_in_wide
wideflash_pref() {
  # no settings file: storage still locked at boot (the last apply's edit stands), or the camera was
  # never opened, so its default comes from camera-feature.xml, which this tweak turns on
  [ -f $CAM_PREFS ] || return 0
  [ -f $WF_UNDO ] && return 0
  v=$(sed -n 's|.*<string name="flash_in_wide_lens">\([^<]*\)</string>.*|\1|p' $CAM_PREFS)
  [ "$v" = 1 ] && return 0
  am force-stop com.sec.android.app.camera
  mkdir -p $R $V/undo; echo "${v:-absent}" > $WF_UNDO
  if [ -n "$v" ]; then
    sed 's|<string name="flash_in_wide_lens">[^<]*</string>|<string name="flash_in_wide_lens">1</string>|' $CAM_PREFS > $R/camprefs.new
  else
    awk '/<\/map>/ { print "    <string name=\"flash_in_wide_lens\">1</string>" } { print }' $CAM_PREFS > $R/camprefs.new
  fi
  grep -q '<string name="flash_in_wide_lens">1</string>' $R/camprefs.new && grep -q '</map>' $R/camprefs.new ||
    { rm -f $R/camprefs.new $WF_UNDO; log "wideflash: couldn't edit the camera settings; turn on the wide-lens flash in Camera Assistant instead"; return; }
  cat $R/camprefs.new > $CAM_PREFS; rm -f $R/camprefs.new   # cat keeps the file's owner and label
  log "wideflash: Camera's wide-lens flash setting turned on (it was ${v:-unset})"
}
# put the setting back the way it was before wideflash_pref changed it
wideflash_unpref() {
  [ -f $WF_UNDO ] && [ -f $CAM_PREFS ] || return 1
  v=$(cat $WF_UNDO); am force-stop com.sec.android.app.camera; mkdir -p $R
  if [ "$v" = absent ]; then grep -v 'name="flash_in_wide_lens"' $CAM_PREFS > $R/camprefs.new
  else sed "s|<string name=\"flash_in_wide_lens\">[^<]*</string>|<string name=\"flash_in_wide_lens\">$v</string>|" $CAM_PREFS > $R/camprefs.new; fi
  grep -q '</map>' $R/camprefs.new && cat $R/camprefs.new > $CAM_PREFS && rm -f $R/camprefs.new $WF_UNDO
}

# ---------- Payload tweaks: camerahdr, hdr2023, audioeraser, colortone, galaxyai (files in $D/payload/<tweak>) ----------
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
  K=$T24/keep; rm -rf $K; mkdir -p $K; i=0; : > $T24/keep.ok
  awk -v p="$1/" 'index($2, p) == 1 && $2 !~ /\\/ && !seen[$2]++ {print $2}' /proc/mounts > $T24/keep.list
  while read m; do i=$((i+1))
    if [ -d "$m" ]; then mkdir $K/$i; else : > $K/$i; fi
    if e=$(mount --bind "$m" $K/$i 2>&1); then echo "$i $m" >> $T24/keep.ok; continue; fi
    case "$m" in
      # our own edited copies: camfeat_apply and ff_apply rebuild them from stock after the layers
      # (issue #26: a stale one left by applies of older versions in the same boot couldn't be bound)
      $FF|$CF) umount "$m" 2>/dev/null
        log "note: couldn't keep $m inside the new layer (${e:-mount failed}); it's rebuilt later in this apply" ;;
      *) fail "keep $m: ${e:-mount failed} (a reboot clears it; then apply again)" ;;
    esac
  done < $T24/keep.list
}
keep_restore() {
  n=0
  while read i m; do n=$((n+1))
    e=$(mount --bind $K/$i "$m" 2>&1) || fail "put back $m: ${e:-mount failed}"
    umount $K/$i
  done < $T24/keep.ok
  [ $n = 0 ] || log "kept $n mounts inside the new layer: $(cut -d' ' -f2- $T24/keep.ok | tr '\n' ' ')"
  rm -rf $K $T24/keep.list $T24/keep.ok
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

# 2023 ArcSoft HDR. The HDR the camera actually picks on One UI 9 is hybrid HDR (most daylight shots)
# and bracketed (AEB) HDR (backlit scenes). Both engines changed since One UI 6: hybrid HDR 4.2 build
# 1423 -> 1790, and bracketed HDR from ArcSoft HDR_ART 4.2 (build 1252) to a new AEBHDR 5.0 engine.
# Swap both engines and their Samsung wrappers (as pairs) for the 2023 S918WVLS2BWKA copies. The 2023
# wrappers export every function today's camera calls. Bracketed HDR was tested on S918WVLU8GZIF
# (engine version 900 runs, no errors); hybrid HDR loads but wasn't triggered in testing.
H23_LIBS="libhybrid_high_dynamic_range.arcsoft.so libae_bracket_hdr.arcsoft.so libhybridHDR_wrapper.camera.samsung.so libAEBHDR_wrapper.camera.samsung.so"
H23_MD5="2af454af1421426ee3ec3ea1462a30cf af98599bd1b23a44834626e60b1057bf dad377ec9ee2020c091fa739f798e597 c460aff39b2b929a804e2ac11ce9af69"
hdr2023_check() {
  set -- $H23_MD5
  for f in $H23_LIBS; do
    [ "$(md5sum $PL/hdr2023/$f 2>/dev/null | cut -d' ' -f1)" = "$1" ] || { log "hdr2023: its download is missing $f (or it's damaged); skipped"; return 1; }
    shift
  done
}
hdr2023_bind() {   # after layers_mount: an overlay on /system/lib64 would hide these binds
  for f in $H23_LIBS; do bind_file $PL/hdr2023/$f /system/lib64/$f system_lib_file; done
  am force-stop com.sec.android.app.camera
  log "hdr2023: 2023 ArcSoft hybrid HDR and bracketed HDR on"
}

# 10-bit HDR video from the front cameras for any app (Camera2 DYNAMIC_RANGE_TEN_BIT, HLG10). The camera
# driver (CamX, /vendor/lib64/hw/camera.qcom.so) builds the 10-bit profile list, the recommended profile
# and the TEN_BIT capability only for rear cameras, so Android refuses 10-bit streams on the selfie
# cameras, though their sensors and pipeline produce them (Samsung Camera records HDR10+ selfie video).
# Make a copy of the phone's own driver with 3 changes, found by their instructions (not fixed offsets,
# so any build with the same CamX code works): the profile list and recommended profile no longer skip
# front cameras, and a jump to 15 new instructions in the zero padding at the end of the code segment
# appends TEN_BIT (18) to a front camera's capability list (not the secure-only cameras, which list one
# capability). Bound from /data with the camera driver stopped. It stays only if the driver keeps
# running and a front camera then really lists TEN_BIT; otherwise the stock driver goes back.
TB_LIB=/vendor/lib64/hw/camera.qcom.so
TB_SVC=sec-camera-provider
# Cave code, in words: if facing ([x29-0xb0]) is front and the list (w10 entries at x19+0x2060) has
# 2..19 entries, append 18; then the replaced "mov w28, w10" (the jump back is added per file)
TB_CAVE="d102c3a9 b9400129 7100053f 54000141 7100095f 54000103 71004d5f 540000c8 91400a69 91018129 5280024b 382a492b 1100054a 2a0a03fc"
tb_pid() { pidof vendor.samsung.hardware.camera.provider-service_64; }
tb_restart() {   # stop the camera driver, run "$@" while it's down, start it, wait until it stays up
  am force-stop com.sec.android.app.camera
  setprop ctl.stop $TB_SVC; n=50; while [ -n "$(tb_pid)" ] && [ $n -gt 0 ]; do n=$((n-1)); sleep 0.1; done
  "$@"
  setprop ctl.start $TB_SVC; sleep 6; p=$(tb_pid); [ -n "$p" ] || return 1
  sleep 4; [ "$(tb_pid)" = "$p" ]
}
tb_unbind() { while bound $TB_LIB; do umount $TB_LIB || return 1; done; }
tb_bind() { tb_unbind && mount -o bind,ro $V/tenbit.so $TB_LIB; }
tb_front10() {   # does a front camera list DYNAMIC_RANGE_TEN_BIT right now?
  dumpsys media.camera | awk '
    function done_cam() { if (front && ten) ok = 1; front = 0; ten = 0 }
    /static information:/ { done_cam() }
    /android\.lens\.facing \(/ { getline l; front = (l ~ /FRONT/) }
    /android\.request\.availableCapabilities \(/ { getline l; ten = (l ~ /DYNAMIC_RANGE_TEN_BIT/) }
    END { done_cam(); exit !ok }'
}
tb_rd() { od -An -v -tx$3 -j $(($2)) -N $3 "$1" | tr -d ' \n'; }   # FILE OFFSET BYTES: little-endian value, hex
tb_wr() {   # FILE OFFSET WORD
  w=$(($3)); printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((w & 255)) $((w >> 8 & 255)) $((w >> 16 & 255)) $((w >> 24 & 255)))" |
    dd of="$1" bs=1 seek=$(($2)) conv=notrunc 2>/dev/null
}
tb_b() { echo $((0x14000000 | ((($2) - ($1)) / 4 & 0x3ffffff))); }   # FROM TO: "b TO" placed at FROM
# tb_find FILE: the offset of each change, as "A 0x..", "B 0x..", "C 0x..", one line for every match
#  A  ldr w3,[x21]; ldrsw x7,[x27,#0x2674]; cmp w3,#1; str x7,[x19,#0x2060]; b.ne    (recommended profile)
#  B  ldr w8,[x21]; mov w0,wzr; cmp w8,#1; b.eq; ldr w7,[x27,#0x2670]                (profile list)
#  C  mov w11,#8; mov w10,#1; strb w11,[x22]; mov w28,w10; add x2,x19,#2,lsl#12; adrp x4; add x2,x2,#0x60
tb_find() {
  od -An -v -tx4 -w4 "$1" | awk '
    $1 ~ /^54.....1$/ && p1 == "f9103267" && p2 == "7100047f" && p3 == "b9a67767" && p4 == "b94002a3" { printf "A 0x%x\n", (NR - 1) * 4 }
    $1 == "b9667367" && p1 ~ /^54.....0$/ && p2 == "7100051f" && p3 == "2a1f03e0" && p4 == "b94002a8" { printf "B 0x%x\n", (NR - 2) * 4 }
    $1 == "91018042" && p2 == "91400a62" && p3 == "2a0a03fc" && p4 == "390002cb" && p5 == "5280002a" && p6 == "5280010b" { printf "C 0x%x\n", (NR - 4) * 4 }
    { p6 = p5; p5 = p4; p4 = p3; p3 = p2; p2 = p1; p1 = $1 }'
}
# tb_patch STOCK OUT: write the patched copy; says why not on failure
tb_patch() {
  F=$1; O=$2; m=$(tb_find $F)
  for k in A B C; do [ "$(echo "$m" | grep -c "^$k ")" = 1 ] || { echo "its camera driver's code differs (change $k found $(echo "$m" | grep -c "^$k ") times)"; return 1; }; done
  set -- $m; A=$2; B=$4; C=$6
  # the code segment: the PT_LOAD with PF_X. The cave goes right after its file contents, in the zero
  # padding of its last page (mapped executable with it)
  ph=$((0x$(tb_rd $F 0x20 8))); n=$((0x$(tb_rd $F 0x38 2))); sz=$((0x$(tb_rd $F 0x36 2))); X=""
  while [ $n -gt 0 ]; do
    if [ $((0x$(tb_rd $F $ph 4))) = 1 ] && [ $((0x$(tb_rd $F $((ph + 4)) 4) & 1)) = 1 ]; then
      X=$((0x$(tb_rd $F $((ph + 8)) 8))); XE=$((X + 0x$(tb_rd $F $((ph + 0x20)) 8))); break; fi
    ph=$((ph + sz)); n=$((n - 1))
  done
  [ -n "$X" ] || { echo "no code segment found"; return 1; }
  for o in $A $B $C; do [ $((o)) -ge $X ] && [ $((o)) -lt $XE ] || { echo "a change falls outside the code segment"; return 1; }; done
  K=$(((XE + 3) & ~3)); KE=$((K + 60))
  [ $KE -le $(((XE + 4095) & ~4095)) ] && [ "$(od -An -v -tx1 -j $K -N 60 $F | tr -s ' ' '\n' | grep -c '^00$')" = 60 ] ||
    { echo "no free room at the end of its code"; return 1; }
  w=$((0x$(tb_rd $F $A 4))); i=$((w >> 5 & 0x7ffff)); [ $i -ge $((0x40000)) ] && i=$((i - 0x80000))
  cp $F $O || { echo "no room for a copy"; return 1; }
  tb_wr $O $A $(tb_b 0 $((i * 4)))            # b.ne -> b
  tb_wr $O $B 0xd503201f                       # b.eq -> nop
  tb_wr $O $C $(tb_b $C $K)                    # mov w28, w10 -> b cave
  o=$K; for x in $TB_CAVE; do tb_wr $O $o 0x$x; o=$((o + 4)); done
  tb_wr $O $o $(tb_b $o $((C + 4)))            # back
  printf 'changes at 0x%x 0x%x 0x%x, cave 0x%x' $A $B $C $K
}
tenbit_apply() {
  if bound $TB_LIB; then [ "$(md5 $TB_LIB)" = "$(md5 $V/tenbit.so)" ] && { log "tenbit: already on"; return 0; }
    log "tenbit: something else is bound over $TB_LIB; skipped"; return 1; fi
  tb_front10 && { log "tenbit: the front cameras already offer 10-bit; nothing to do"; return 0; }
  s=$(md5 $TB_LIB)
  if [ "$(cat $V/tenbit.src 2>/dev/null)" != "$s" ] || [ ! -f $V/tenbit.so ]; then   # (re)make it for this driver
    rm -f $V/tenbit.so $V/tenbit.src
    r=$(tb_patch $TB_LIB $V/tenbit.tmp) || { rm -f $V/tenbit.tmp; log "tenbit: $r; skipped"; return 1; }
    mv $V/tenbit.tmp $V/tenbit.so; echo $s > $V/tenbit.src; log "tenbit: patched copy made ($r)"
  fi
  chown 0:0 $V/tenbit.so; chmod 644 $V/tenbit.so; chcon u:object_r:vendor_file:s0 $V/tenbit.so
  if tb_restart tb_bind && bound $TB_LIB && tb_front10; then
    log "tenbit: front cameras offer 10-bit HDR (HLG10) video to apps"
  else
    tb_restart tb_unbind
    log "tenbit: with the change the camera driver didn't stay up or the front cameras still lacked 10-bit; stock driver back"
    return 1
  fi
}

# Super steady's horizontal lock (camextras). Samsung Camera asks for it with Super steady = 2, which the
# S23's camera driver treats as plain Super steady: the picture turns with the phone. The S23's EIS v3
# stabilizer (Qualcomm) has horizon levelling, switched on by the EIS tuning (off for Super steady here)
# or by an app's HorizonLevelControl tag, which the S23 build never reads (it looks up the
# EnableInsensorZoom tag ID instead), and Samsung's S23 driver maps nothing to it. Make a copy of the
# phone's own EIS v3 node where that tag check becomes: if CheckSuperSteadyMode() is 2, set the
# levelling enable field, else use the tuning. The algorithm then levels with the accelerometer (its
# default angles), but clamps the correction to the tuning's per-sensor maximum: 8 degrees on the S23,
# so a 30-degree tilt kept 22 (ha_patch lifts it to 30). Found by instructions, so any build with the
# same code works. Bound like tenbit's.
HL_LIB=/vendor/lib64/camera/components/com.qti.node.eisv3.so
# hl_find FILE: "S 0x.." the tag check, "F 0x.." its found branch (mov w8; mov w0,#enable; ...),
# "J 0x.." the use-tuning join (after a bl: mov w21,wzr; mov w19,#1), "C 0x.." in CheckSuperSteadyMode
hl_find() {
  od -An -v -tx4 -w4 "$1" | awk '
    { w[NR] = $1 }
    END {
      for (i = 1; i + 9 <= NR; i++) {
        if (w[i] ~ /^[9bdf]0....[02468ace]3$/ && w[i+1] == "f9405ac4" && w[i+2] ~ /^91...[048c]63$/ && w[i+3] == "aa1f03e0" &&
            w[i+4] == "52800042" && w[i+5] == "2a1f03e5" && w[i+6] == "b8414473" && w[i+7] == "32030261" &&
            w[i+8] ~ /^94/ && w[i+9] ~ /^b4/) printf "S 0x%x\n", (i - 1) * 4
        if (w[i] ~ /^52[89a-f]...[02468ace]8$/ && w[i+1] ~ /^52[89a-f]...[02468ace]0$/ && w[i+2] == "2a1f03f5" &&
            w[i+3] == "52800033" && w[i+4] == "b8286b96" && w[i+6] == "b8206b98") printf "F 0x%x\n", (i - 1) * 4
        if (w[i] ~ /^94/ && w[i+1] == "2a1f03f5" && w[i+2] == "52800033") printf "J 0x%x\n", i * 4
        if (w[i] == "b8410468" && w[i+1] == "f9405804" && w[i+2] == "aa1f03e0" && w[i+3] == "32040901" && w[i+4] ~ /^94/) {
          for (k = i; k > i - 24 && k > 0; k--) if (w[k] == "d503233f") break
          if (w[k] == "d503233f") printf "C 0x%x\n", (k - 1) * 4 }
      }
    }'
}
# hl_patch STOCK OUT: write the patched copy; says why not on failure
hl_patch() {
  F=$1; O=$2; m=$(hl_find $F)
  for k in S F C; do [ "$(echo "$m" | grep -c "^$k ")" = 1 ] || { echo "its EIS code differs (part $k found $(echo "$m" | grep -c "^$k ") times)"; return 1; }; done
  S=$(($(echo "$m" | awk '$1=="S"{print $2}'))); FB=$(($(echo "$m" | awk '$1=="F"{print $2}'))); C=$(($(echo "$m" | awk '$1=="C"{print $2}')))
  J=""; for j in $(echo "$m" | awk '$1=="J"{print $2}'); do [ $((j)) -gt $S ] && [ $((j)) -lt $((S + 0x200)) ] && [ $((j)) != $((FB + 8)) ] && J=$((j)); done
  [ -n "$J" ] && [ $FB -gt $S ] && [ $FB -lt $J ] || { echo "its EIS code is laid out differently"; return 1; }
  EN=$(((0x$(tb_rd $F $((FB + 4)) 4) >> 5) & 0xffff))   # the enable field's offset, from "mov w0, #offset"
  cp $F $O || { echo "no room for a copy"; return 1; }
  tb_wr $O $S 0xaa1603e0                                                   # mov x0, x22 (the node)
  tb_wr $O $((S + 4)) $((0x94000000 | ((C - S - 4) / 4 & 0x3ffffff)))      # bl CheckSuperSteadyMode
  tb_wr $O $((S + 8)) 0x7100081f                                           # cmp w0, #2
  tb_wr $O $((S + 12)) $((0x54000001 | (((J - S - 12) / 4 & 0x7ffff) << 5)))   # b.ne tuning
  tb_wr $O $((S + 16)) $((0x52800008 | (EN << 5)))                        # mov w8, #enable field
  tb_wr $O $((S + 20)) 0x52800029                                          # mov w9, #1
  tb_wr $O $((S + 24)) 0xb8286b89                                          # str w9, [x28, x8]
  tb_wr $O $((S + 28)) $(tb_b $((S + 28)) $J)                              # b tuning join
  printf 'check at 0x%x, enable field 0x%x' $S $EN
}
# The stabilizer itself (com.qti.eisv3.so) reads that maximum once per sensor slot while it starts:
# 16 loads of [xN, #596] in one tight run (the only other such load is in a debug dump, far away),
# each then turned into radians. ha_patch makes a copy where each load is "fmov sN, #30.0".
HA_LIB=/vendor/lib64/camera/components/com.qti.eisv3.so
# ha_patch STOCK OUT: write the copy with the 30-degree cap; says why not on failure
ha_patch() {
  F=$1; O=$2
  offs=$(od -An -v -tx4 -w4 "$F" | awk '
    /^ *bd425[4-7]/ { a = (NR - 1) * 4                       # ldr sN, [xM, #596]
      if (cnt && a - last > 128) { if (cnt == 16) print run; run = ""; cnt = 0 }
      run = run " " a; cnt++; last = a }
    END { if (cnt == 16) print run }')
  [ "$(echo "$offs" | grep -c .)" = 1 ] && [ "$(echo $offs | wc -w)" = 16 ] || { echo "its stabilizer code differs"; return 1; }
  cp $F $O || { echo "no room for a copy"; return 1; }
  for a in $offs; do tb_wr $O $a $((0x1e27d000 | (0x$(tb_rd $F $a 4) & 31))); done   # fmov sN, #30.0
  echo "levelling up to 30 degrees"
}
# The preview runs its own stabilizer pair (EIS v2: node and com.qti.eisv2.so). Its node is newer code:
# a GetHorizonLevelingOverride that copies the tag's enable and maximum into the per-sensor block if the
# tag is found, else only logs "Use tuning". hl2_patch replaces that log with: if CheckSuperSteadyMode()
# is 2, enable = 1 and maximum = 30. Its stabilizer takes ha_patch as is (same 16-load run).
HL2_LIB=/vendor/lib64/camera/components/com.qti.node.eisv2.so
HA2_LIB=/vendor/lib64/camera/components/com.qti.eisv2.so
# hl2_find FILE: "L 0x.." the tag lookup's "ldr x4,[x30,#144]" (then "P 0x.." the ldr x30,[sp,#..] before
# it), "F 0x.." the found path's two stores, "T 0x.." each tuning join, "C 0x.." CheckSuperSteadyMode
hl2_find() {
  od -An -v -tx4 -w4 "$1" | awk '
    { w[NR] = $1 }
    END {
      for (i = 1; i + 9 <= NR; i++) {
        if (w[i] == "f9404bc4" && w[i+1] ~ /^91...063$/ && w[i+2] == "aa1f03e0" && w[i+3] == "52800042" && w[i+4] == "2a1f03e5" &&
            w[i+5] ~ /^b84184/ && w[i+6] ~ /^320301/ && w[i+7] ~ /^94/ && w[i+8] ~ /^b4/) {
          printf "L 0x%x\n", (i - 1) * 4
          for (k = i - 1; k > i - 12; k--) if (w[k] ~ /^f94.....$/ && w[k] ~ /fe$/) { printf "P 0x%x\n", (k - 1) * 4; break } }
        if (w[i] ~ /^529....d$/ && w[i+1] ~ /^529....c$/ && w[i+2] == "f9006bff" && w[i+3] == "52800033" &&
            w[i+4] == "b82d6a99" && w[i+5] == "b82c6a95") printf "F 0x%x\n", (i - 1) * 4
        if (w[i] == "f9006bff" && w[i+1] == "52800033") printf "T 0x%x\n", (i - 1) * 4
        if (w[i] == "b8410468" && w[i+1] == "32040901" && w[i+2] ~ /^94/) {
          for (k = i; k > i - 24 && k > 0; k--) if (w[k] == "d503233f") break
          if (w[k] == "d503233f") printf "C 0x%x\n", (k - 1) * 4 }
      }
    }'
}
# hl2_patch STOCK OUT: write the patched copy; says why not on failure
hl2_patch() {
  F=$1; O=$2; m=$(hl2_find $F)
  for k in L P F C; do [ "$(echo "$m" | grep -c "^$k ")" = 1 ] || { echo "its preview EIS code differs (part $k found $(echo "$m" | grep -c "^$k ") times)"; return 1; }; done
  L=$(($(echo "$m" | awk '$1=="L"{print $2}'))); P=$(($(echo "$m" | awk '$1=="P"{print $2}')))
  FB=$(($(echo "$m" | awk '$1=="F"{print $2}'))); C=$(($(echo "$m" | awk '$1=="C"{print $2}')))
  cb=$((0x$(tb_rd $F $((L + 32)) 4)))                                     # cbz x0, N
  N=$(((cb >> 5) & 0x7ffff)); [ $N -ge 262144 ] && N=$((N - 524288)); N=$((L + 32 + N * 4))
  T=""; for t in $(echo "$m" | awk '$1=="T"{print $2}'); do [ -z "$T" ] && [ $((t)) -gt $N ] && [ $((t)) -lt $((N + 0x200)) ] && T=$((t)); done
  [ -n "$T" ] && [ $((T - N)) -ge 48 ] && [ $FB -gt $L ] && [ $FB -lt $N ] || { echo "its preview EIS code is laid out differently"; return 1; }
  SL=$((((0x$(tb_rd $F $P 4)) >> 10 & 0xfff) * 8))                        # the node's stack slot
  EN=$(((0x$(tb_rd $F $FB 4) >> 5) & 0xffff)); MX=$(((0x$(tb_rd $F $((FB + 4)) 4) >> 5) & 0xffff))
  cp $F $O || { echo "no room for a copy"; return 1; }
  tb_wr $O $N $((0xf94003e0 | (SL / 8) << 10))                            # ldr x0, [sp, #node]
  tb_wr $O $((N + 4)) 0xf9404800                                           # ldr x0, [x0, #144]
  tb_wr $O $((N + 8)) $((0x94000000 | ((C - N - 8) / 4 & 0x3ffffff)))      # bl CheckSuperSteadyMode
  tb_wr $O $((N + 12)) 0x7100081f                                          # cmp w0, #2
  tb_wr $O $((N + 16)) $((0x54000001 | (((T - N - 16) / 4 & 0x7ffff) << 5)))   # b.ne tuning
  tb_wr $O $((N + 20)) $((0x52800008 | (EN << 5)))                        # mov w8, #enable field
  tb_wr $O $((N + 24)) 0x52800029                                          # mov w9, #1
  tb_wr $O $((N + 28)) 0xb8286a89                                          # str w9, [x20, x8]
  tb_wr $O $((N + 32)) $((0x52800008 | (MX << 5)))                        # mov w8, #maximum field
  tb_wr $O $((N + 36)) 0x52a83e09                                          # mov w9, #30.0
  tb_wr $O $((N + 40)) 0xb8286a89                                          # str w9, [x20, x8]
  tb_wr $O $((N + 44)) $(tb_b $((N + 44)) $T)                              # b tuning
  printf 'check at 0x%x, enable field 0x%x' $N $EN
}
# target:copy:patcher. The record-side node copy is the one levelling needs; the others widen it
HL_SET="$HL_LIB:hlock:hl_patch $HA_LIB:hlalgo:ha_patch $HL2_LIB:hl2node:hl2_patch $HA2_LIB:hl2algo:ha_patch"
hl_unbind() {
  for e in $HL_SET; do t=${e%%:*}; while bound $t; do umount $t || return 1; done; done
}
hl_bind() {
  hl_unbind || return 1
  for e in $HL_SET; do t=${e%%:*}; c=${e#*:}; c=$V/${c%%:*}.so
    [ ! -f $c ] || mount -o bind,ro $c $t || return 1; done
}
# hl_ours: every copy we have is bound, and every target without a copy is stock and known not to patch
hl_ours() {
  for e in $HL_SET; do t=${e%%:*}; n=${e#*:}; n=${n%%:*}
    if [ -f $V/$n.so ]; then bound $t && [ "$(md5 $t)" = "$(md5 $V/$n.so)" ] || return 1
    else ! bound $t && [ "$(cat $V/$n.src 2>/dev/null)" = "$(md5 $t)" ] || return 1; fi
  done
}
hlock_apply() {
  [ -f $V/hlock.so ] && hl_ours && { log "camextras: horizontal lock levelling already on"; return 0; }
  for e in $HL_SET; do t=${e%%:*}; n=${e#*:}; n=${n%%:*}
    bound $t || continue
    [ -f $V/$n.so ] && [ "$(md5 $t)" = "$(md5 $V/$n.so)" ] ||
      { log "camextras: something else is bound over $t; horizontal lock won't level"; return 1; }
  done
  # some of our copies are on (an older version, or an earlier failure): take them off, then redo all
  if bound $HL_LIB || bound $HA_LIB || bound $HL2_LIB || bound $HA2_LIB; then
    tb_restart hl_unbind || { log "camextras: couldn't take the old levelling copies off"; return 1; }
  fi
  for e in $HL_SET; do t=${e%%:*}; n=${e#*:}; p=${n#*:}; n=${n%%:*}
    s=$(md5 $t); [ -n "$s" ] || continue
    [ "$(cat $V/$n.src 2>/dev/null)" = "$s" ] && continue   # (re)make a copy only for a new stock file; remember failures too
    rm -f $V/$n.so
    if r=$($p $t $V/$n.tmp); then mv $V/$n.tmp $V/$n.so; log "camextras: patched copy of ${t##*/} made ($r)"
    else rm -f $V/$n.tmp; log "camextras: ${t##*/}: $r"; fi
    echo $s > $V/$n.src
  done
  [ -f $V/hlock.so ] || { log "camextras: horizontal lock shows but won't level"; return 1; }
  for e in $HL_SET; do n=${e#*:}; c=$V/${n%%:*}.so
    [ -f $c ] && { chown 0:0 $c; chmod 644 $c; chcon u:object_r:vendor_file:s0 $c; }; done
  if tb_restart hl_bind && bound $HL_LIB; then
    log "camextras: Super steady's horizontal lock levels the horizon: $(hl_desc)"
  else
    tb_restart hl_unbind
    log "camextras: with the levelling change the camera driver didn't stay up; stock EIS back, horizontal lock won't level"
    return 1
  fi
}
hl_desc() {
  echo "recording up to $(bound $HA_LIB && echo 30 || echo 8) degrees, preview $(bound $HL2_LIB && { bound $HA2_LIB && echo "up to 30" || echo "up to 8"; } || echo "not levelled")"
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
  set -- $(nh_row); NHM=${3:-none}; NHE=${5:-none}   # highlights patches this same APK, on top of ours
  if [ "$sm" = $SETTINGS_EAD_MD5 ] || [ "$sm" = $NHE ]; then :   # an earlier apply this boot had the right layer
    :
  else
    if [ "$sm" = $NHM ]; then
      # a highlights-only bind from an earlier apply in this boot: drop it and rebuild from stock, so
      # highlights_bind can stack its patch on ours below (the two touch different bytes of the dex)
      umount $SETTINGS 2>/dev/null
      sm=$(md5sum $SETTINGS | cut -d' ' -f1)
    fi
    if [ "$sm" != $SETTINGS_STOCK_MD5 ]; then
      log "colortone: Settings isn't the $(ead_builds) build, so the Adaptive color tone switch stays hidden"; return
    fi
    P=$PL/colortone/SecSettings.apk   # the patched copy stays on storage and is reused at the next boot
    if [ "$(md5sum $P 2>/dev/null | cut -d' ' -f1)" != $SETTINGS_EAD_MD5 ]; then
      cp $SETTINGS $P.new
      grep -v '^#' $D/files/SecSettings-ead-$eb.patch | tr -d '\r' | while read off oct; do
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
# Its page is hidden because the bool that getAvailabilityStatus() reads is false, so patch the return
# value instead of the resource: the arsc differs per build, the dex differs only in that literal.
highlights_bind() {
  sm=$(md5sum $SETTINGS | cut -d' ' -f1)
  set -- $(nh_row); eb=$1; stock=${2:-none}; nhm=${3:-none}; ead=${4:-none}; nhe=${5:-none}
  [ -z "$eb" ] && { log "highlights: Settings isn't the $(nh_builds) build, so its page stays hidden"; return; }
  P=$PL/highlights/SecSettings.apk
  case $sm in
    $nhm|$nhe) return 0 ;;   # bound by an earlier apply this boot
    $stock) pf=$D/files/SecSettings-nh-$eb.patch; want=$nhm ;;
    $ead) pf=$D/files/SecSettings-nh-ead-$eb.patch; want=$nhe ;;   # colortone is bound under us
    *) log "highlights: Settings isn't the $eb or colortone build, so its page stays hidden"; return ;;
  esac
  if [ -n "${pf:-}" ]; then
    mkdir -p $PL/highlights
    rm -f $P.new; cp $SETTINGS $P.new
    grep -v '^#' $pf | tr -d '\r' | while read off oct; do
      printf "\\$oct" | dd of=$P.new bs=1 seek=$off conv=notrunc 2>/dev/null; done
    [ "$(md5sum $P.new | cut -d' ' -f1)" = $want ] || { rm -f $P.new; fail "highlights: Settings patch gave the wrong file"; }
    mv $P.new $P
  fi
  chmod 644 $P; chcon u:object_r:system_file:s0 $P
  mount -o bind,ro $P $SETTINGS || fail "highlights: bind $SETTINGS"
  am force-stop com.android.settings
  log "highlights: its page is on (Settings > Notifications > Advanced settings)"
}
cam24fps_bind() {
  set -- $(cam24_row)
  if [ -z "$1" ]; then
    log "profps: this Camera APK isn't one the frame-rate patch was made for (Camera 17.0.00.43 of $(cam24_builds)); the XML frame rates still apply, 24 fps and the 10x stay hidden"; return 0
  fi
  pm path com.sec.android.app.camera 2>/dev/null | grep -q "^package:$CAM_APK$" ||
    { log "profps: Samsung Camera is updated from the Galaxy Store; the XML frame rates still apply, 24 fps and the 10x stay hidden until its updates are uninstalled"; return 0; }
  CAM_STOCK_MD5=$1; CAM_PATCHED_MD5=$2; cpf=$3
  [ -f $D/files/$cpf ] || { log "profps: patch file $cpf is missing; the XML frame rates still apply, 24 fps and the 10x stay hidden"; return 0; }
  cm=$(md5sum $CAM_APK | cut -d' ' -f1)
  if [ "$cm" = $CAM_PATCHED_MD5 ]; then :   # already patched (an earlier apply this boot)
  else
    mkdir -p $PL/cam24fps
    P=$PL/cam24fps/SamsungCamera.apk   # patched copy stays on storage and is reused at the next boot
    if [ "$(md5sum $P 2>/dev/null | cut -d' ' -f1)" != $CAM_PATCHED_MD5 ]; then
      cp $CAM_APK $P.new
      grep -v '^#' $D/files/$cpf | tr -d '\r' | while read off oct; do
        printf "\\$oct" | dd of=$P.new bs=1 seek=$off conv=notrunc 2>/dev/null; done
      if [ "$(md5sum $P.new | cut -d' ' -f1)" != $CAM_PATCHED_MD5 ]; then
        rm -f $P.new
        log "profps: the Camera patch didn't match this APK; the XML frame rates still apply, 24 fps and the 10x stay hidden"; return 0
      fi
      mv $P.new $P
    fi
    chmod 644 $P; chcon u:object_r:system_file:s0 $P
    mount -o bind,ro $P $CAM_APK || fail "profps: bind $CAM_APK"
    am force-stop com.sec.android.app.camera
  fi
  if grep -q BACK_SECOND_TELE $D/files/$cpf 2>/dev/null; then
    log "profps: 24 fps in standard Video, extra Pro video rates, 10x at 25/48/50 and Slow motion 4K120/FHD120 on"
  else
    log "profps: 24 fps in standard Video, extra Pro video rates and Slow motion 4K120/FHD120 on; this Camera patch doesn't unhide the 10x"
  fi
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
  c2pa_stage
  return 0
}
# AI version 20263 also makes the S23's Visual Cloud Core pick its "V2" C2PA adapter (>= 20261), whose
# four natives the S23's V1 libC2paDps.camera.samsung.so lacks: it crashed with UnsatisfiedLinkError
# C2paLib.getVersion() (issue #19). floating_feature.xml is parsed in zygote, so the key can't be hidden
# from that one app. files/libC2paDps-shim.so (src/c2pashim) goes over the library instead: it maps the
# four V2 calls onto the V1 ones and forwards the rest to the original, added beside it as
# libC2paDps_s23.camera.samsung.so. Skipped when the phone's library already has the V2 calls.
C2PA=/system/lib64/libC2paDps.camera.samsung.so; C2PA_ORIG=$V/libC2paDps_s23.camera.samsung.so; C2PA_SHIM=$V/libC2paDps-shim.so
c2pa_stage() {
  c2pa=0
  [ -f $C2PA ] && [ -f $D/files/libC2paDps-shim.so ] || return 1
  if ! same_size $C2PA $D/files/libC2paDps-shim.so; then   # the firmware's library (not the shim of an earlier apply)
    grep -q C2paLib_getVersion $C2PA && { log "galaxyai: this firmware's C2PA library already has the V2 calls; left as is"; return 1; }
    cp $C2PA $C2PA_ORIG || return 1
  fi
  [ -s $C2PA_ORIG ] || return 1
  cp $D/files/libC2paDps-shim.so $C2PA_SHIM || return 1
  stage lib64 $C2PA_ORIG
  c2pa=1
}
galaxyai_bind() {
  for p in $GAI_APPS; do n=${p#*/}
    bind_file $PL/galaxyai/$n.apk /system/$p/$n.apk system_file && rm -f /data/system/package_cache/*/$n-16-*
  done
  [ "${c2pa:-0}" = 1 ] && [ -f /system/lib64/${C2PA_ORIG##*/} ] && bind_file $C2PA_SHIM $C2PA system_lib_file
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
# and is deleted once installed. What works: screening, the greeting, the voice message and the AI
# summary (with this exact build, the one on APKMirror; another build's summary failed). AI replies
# untested. See docs/findings.md.
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
  # The installer can't read files under /data/adb, and streaming it through stdin fails: pm's -S size
  # is a 32-bit int and the APK is 3.1 GB ("Failed transaction"). Install it from /data/local/tmp, as a
  # hard link (the same /data): a 3.1 GB copy next to the download left too little room for the
  # installed 3.1 GB, and that install failed with the same "Failed transaction".
  T=/data/local/tmp/s23t-languagecore.apk; rm -f $T
  if ln $A $T 2>/dev/null; then need=3500000; else need=6800000; fi
  [ "$(df -k /data | awk 'NR == 2 {print $4}')" -gt $need ] || { rm -f $T; log "callscreen: needs $((need / 1000000)).$((need / 100000 % 10)) GB free to install Language Core (its download is kept: free some space and apply again); skipped"; return 1; }
  { [ -f $T ] || cp $A $T; } && chmod 644 $T && chcon u:object_r:shell_data_file:s0 $T && r=$(pm install -r $T 2>&1) || r="couldn't put it in /data/local/tmp: $r"
  rm -f $T
  case "$r" in
    *Success*) rm -rf $PL/callscreen; mkdir -p $V/undo; touch $V/undo/languagecore; log "callscreen: Language Core installed; turn on Phone > Settings > Call screening" ;;
    *) log "callscreen: install failed: $r" ;;
  esac
}

# weather: the lock screen Weather effect (rain, snow, fog or sun over the wallpaper, following Samsung
# Weather). The effect is SpriteWallpaper's WeatherWallpaperService and runs on the S23 as is, but the
# wallpaper editor (DressRoom) hides its Weather button unless LOCKSCREEN_CONFIG_WALLPAPER_STYLE has
# GENWEATHER and Samsung AI Core reports FEATURE_WALLPAPER/FEATURE_DOWNLOAD and its "visionlvm" model
# as downloaded. The S23 has no AI Core, so files/aicore-stub.apk (src/aicorestub; WX_VER = its
# versionCode) answers just those checks and runs nothing; the model only feeds the S25's AI-generated
# weather images, which the S23 can't make. A real AI Core, if installed, is left alone. The effect
# also needs the live wallpaper app enabled: debloat lists often disable it, and then Android drops the
# wallpaper ("WeatherWallpaperService is unavailable") and the lock screen goes black.
WX_PKG=com.samsung.android.aicore; WX_LIVE=com.samsung.android.wallpaper.live; WX_VER=2
WX_KEY=LOCKSCREEN_CONFIG_WALLPAPER_STYLE
wx_style() {   # the stock value plus GENWEATHER (the file may be our own copy, which has it already)
  v=$(grep -m1 -o "<SEC_FLOATING_FEATURE_$WX_KEY>[^<]*" $FF | cut -d'>' -f2 | tr ',' '\n' | grep -vx GENWEATHER | grep . | tr '\n' ',')
  echo "${v}GENWEATHER"
}
wx_code() { dumpsys package $WX_PKG 2>/dev/null | grep -m1 -oE 'versionCode=[0-9]+' | cut -d= -f2; }
wx_stub() { dumpsys package $WX_PKG 2>/dev/null | grep -q 'versionName=[^ ]*-s23tweaks'; }
wx_real() { pm path $WX_PKG >/dev/null 2>&1 && ! wx_stub; }
wx_live_off() { pm list packages -d --user 0 2>/dev/null | grep -qx "package:$WX_LIVE"; }
weather_apply() {   # after the framework restart, so the package manager is settled
  if wx_live_off; then pm enable --user 0 $WX_LIVE >/dev/null 2>&1 && log "weather: Samsung's live wallpaper app was disabled; turned it back on"; fi
  # A real AI Core answers the editor itself on phones Samsung ships the weather model for. On the S23
  # it asks for an add-on download that fails ("Timeout or response error", issue #40), so say so.
  if wx_real; then log "weather: Samsung's own AI Core is installed, so the stub isn't; if the lock screen editor's Weather asks to download an add-on and fails, uninstall Samsung AI Core (Settings > Apps) if Android allows it and apply again (a built-in AI Core can't be replaced yet)"
  elif [ "$(wx_code)" = $WX_VER ] && wx_stub; then :
  else
    T=/data/local/tmp/s23t-aicore-stub.apk   # the installer can't read files under /data/adb
    cp $D/files/aicore-stub.apk $T && chmod 644 $T && chcon u:object_r:shell_data_file:s0 $T && r=$(pm install -r $T 2>&1)
    case "$r" in *UPDATE_INCOMPATIBLE*) pm uninstall $WX_PKG >/dev/null 2>&1; r=$(pm install $T 2>&1) ;; esac   # signed by another build
    rm -f $T
    case "$r" in *Success*) ;; *) log "weather: couldn't install the AI Core stub: $r"; return 1 ;; esac
  fi
  log "weather: on; pick it in the lock screen editor (Wallpaper and style > Lock screen > Weather)"
}

# helpers: apps the picked tweaks need but nobody opens. Samsung's Deep sleeping apps (Settings > Battery >
# Background usage limits) disables an app it holds (DISABLED_UNTIL_USED) until it's opened, so these stay
# off: the lock screen Weather button goes, call screening loses its voice, AirDrop doesn't start.
# Turn them back on; only taking them off that list stops it happening again (it has no shell command, and
# the module doesn't drive the screen).
helpers() {   # "package name" lines for the picked tweaks
  has weather && { echo "$WX_PKG AI_Core_stub_(Weather)"; echo "$WX_LIVE Samsung_live_wallpaper_(Weather)"; }
  has callscreen && echo "$LC_PKG Samsung_Language_Core_(call_screening)"
  has airdrop && echo "com.google.android.mosey Mosey_(AirDrop)"
}
helpers_off() {   # the helpers that are installed but disabled
  d=$(pm list packages -d --user 0 2>/dev/null)
  helpers | while read pk nm; do echo "$d" | grep -qx "package:$pk" && echo "$pk $nm"; done
}
helpers_wake() {
  helpers_off | while read pk nm; do
    pm enable --user 0 $pk >/dev/null 2>&1 &&
      log "$(echo $nm | tr _ ' ') was disabled (Samsung's Deep sleeping apps does this); turned it back on. Take it off Settings > Battery > Background usage limits > Deep sleeping apps, or it goes off again"
  done
}

# payload_fetch: download and unpack the files of each picked tweak that has them, unless the
# unpacked copy already matches the pinned checksum. A failed download skips that tweak, not the rest.
dl() {   # dl <url> <file>: curl if the phone has it, else KernelSU's busybox wget
  if command -v curl >/dev/null; then curl -fsSL --retry 2 -o "$2" "$1"
  else for b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox; do [ -x $b ] && { $b wget -q -O "$2" "$1"; return; }; done; return 1; fi
}
payload_fetch() {
  for k in $(echo "$PAYLOADS" | awk '{print $1}' | uniq); do
    t=${k%%:*}; has $t || continue
    case $k in *:*) case $t in
      hideksu) [ "${k#*:}" = "$(hks_row | cut -d' ' -f1)" ] ;;
      chargewatts) [ "${k#*:}" = "$(cw_row | cut -d' ' -f2)" ] ;;   # rows are "systemui <stock md5> ..."
      *) false ;;
    esac || continue ;; esac
    [ $t = callscreen ] && lc_ok && continue      # installed already; its 3.1 GB isn't kept
    sums=$(echo "$PAYLOADS" | awk -v k=$k '$1 == k {print $3}' | tr '\n' ' ' | sed 's/ $//')
    [ "$(cat $PL/$t/.sha256 2>/dev/null)" = "$sums" ] && continue
    mkdir -p $V/dl
    [ $t = callscreen ] && [ "$(df -k /data | awk 'NR == 2 {print $4}')" -lt 7340032 ] &&
      { log "$t: needs 7 GB free on the phone for its download; skipped"; continue; }
    parts=""; ok=1
    for f in $(echo "$PAYLOADS" | awk -v k=$k '$1 == k {print $2}'); do
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
  has hdr2023 && hdr2023_check && { ran=0; h23=1; }
  has audioeraser && audioeraser_stage && { ran=0; ae=1; }
  has colortone && colortone_stage && { ran=0; ct=1; }
  has highlights && { ran=0; nh=1; }
  has galaxyai && galaxyai_stage && { ran=0; gai=1; }
  has settingssearch && settingssearch_stage && { ran=0; ssi=1; }
  layers_mount
  [ "${h23:-0}" = 1 ] && hdr2023_bind
  [ "${ae:-0}" = 1 ] && audioeraser_bind
  return $ran   # the APKs are bound later, by apk_binds
}
# An app whose APK is swapped crashes if it starts before the framework restart: Android still has the
# stock APK's parsed manifest, and its resource IDs point at the wrong entries in the new APK
# (SmartSuggestions: "Failed to parse XML configuration from Canadian_dollar"). So bind the APKs
# right before the restart, not ahead of the ~30 s of camera driver restarts.
apk_binds() {
  [ "${ct:-0}" = 1 ] && colortone_bind
  [ "${nh:-0}" = 1 ] && highlights_bind   # after colortone: it patches on top of that bind
  [ "${gai:-0}" = 1 ] && galaxyai_bind
  [ "${ssi:-0}" = 1 ] && settingssearch_bind
  return 0
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

# ---------- CSC (callrec, india): any sales code; the paths come from csc_paths ----------
# csc_unbind: drop the module's binds so the stock files show again (an apply always starts from stock)
csc_unbind() {
  for f in $CSCF $CCF $CUST $PRISM; do
    [ -n "$f" ] || continue; n=0; while bound $f && [ $n -lt 5 ]; do umount $f; n=$((n+1)); done   # nronly may stack on india
  done
  return 0
}
csc_bind() { cp "$1" $R/$3; chmod 644 $R/$3; chcon u:object_r:vendor_configs_file:s0 $R/$3; mount --bind $R/$3 "$2" || fail "bind $2"; }
# callrec_make <out>: the phone's own stock cscfeature.xml, decoded, with call recording allowed in every
# FeatureSet (multi-country files have one per country). Refuses a layout it can't edit line by line.
REC_KEYS="<CscFeature_VoiceCall_ConfigRecording>RecordingAllowed</CscFeature_VoiceCall_ConfigRecording>
<CscFeature_VoiceCall_SupportVoiceRecordingDuringHoldCall>TRUE</CscFeature_VoiceCall_SupportVoiceRecordingDuringHoldCall>"
callrec_make() {
  chmod 755 $OMCDEC 2>/dev/null; $OMCDEC $CSCF > $1.dec 2>>$L || { log "callrec: couldn't decode $CSCF"; rm -f $1.dec; return 1; }
  sets=$(grep -c '</FeatureSet>' $1.dec); lines=$(grep -cE '^[[:space:]]*</FeatureSet>[[:space:]]*$' $1.dec)
  if ! grep -q '</SamsungMobileFeature>' $1.dec || [ "$sets" = 0 ] || [ "$sets" != "$lines" ] || grep -q '<CscFeature_.*<CscFeature_' $1.dec; then
    log "callrec: $CSCF isn't laid out one feature per line; skipped"; rm -f $1.dec; return 1
  fi
  echo "$REC_KEYS" | awk 'NR == FNR { k[++n] = $0; next }
    /<CscFeature_VoiceCall_ConfigRecording>|<CscFeature_VoiceCall_SupportVoiceRecordingDuringHoldCall>/ { next }
    /^[ \t]*<\/FeatureSet>/ { i = $0; sub(/<.*/, "", i); for (j = 1; j <= n; j++) print i "  " k[j] }
    { print }' - $1.dec > $1 && rm -f $1.dec
  [ "$(grep -c 'ConfigRecording>RecordingAllowed<' $1)" = "$sets" ] || { log "callrec: editing $CSCF failed"; rm -f $1; return 1; }
}
callrec_apply() {
  csc_unbind; mkdir -p $R
  callrec_make $R/csc_callrec.xml || return 1
  chmod 644 $R/csc_callrec.xml; chcon u:object_r:vendor_configs_file:s0 $R/csc_callrec.xml
  mount --bind $R/csc_callrec.xml $CSCF || fail "bind $CSCF"
  log "callrec: call recording on in $SC's carrier config (Phone app > Settings > Record calls)"
}
# india: the INS (India) files of S918BXXUAGZIF over the phone's own sales code's. Only the config files
# are swapped; the sales code (sales_code.dat, omc.info, mps_code.dat) is never touched.
# Present the phone as the Indian S23 Ultra so Samsung Wallet's India features and the 6 GHz hotspot
# work. Runtime only (see the IN_MODEL comment); the marker lets csc_paths/why_not tell our spoofed INS
# from a phone that is genuinely INS.
india_identity() {
  RP=/data/adb/ksu/bin/resetprop
  [ -x $RP ] || { log "india: KernelSU resetprop not found; device identity unchanged (Samsung Wallet may show 'not supported')"; return 1; }
  for p in $IN_MODEL_PROPS; do [ -n "$(getprop $p)" ] && $RP $p $IN_MODEL; done
  for p in $IN_SALES_PROPS; do [ -n "$(getprop $p)" ] && $RP $p INS; done
  $RP ro.csc.countryiso_code IN
  touch $V/india_identity
  for a in com.samsung.android.spay com.samsung.android.spayfw; do am force-stop $a 2>/dev/null; done
  log "india: device reported as $IN_MODEL / INS, country IN (Samsung Wallet India + 6 GHz hotspot)"
  log "india: if Samsung Wallet still says 'not supported', clear its storage (Settings > Apps > Samsung Wallet > Storage > Clear data) and reopen it"
}
# Samsung's CID Manager (com.samsung.android.cidmanager) pops "Switch to <carrier>?" when the SIM's
# carrier wants a different sales code than the phone reports. With india forcing INS on, that nags on
# every boot and the dialog won't dismiss. The dialog is drawn by the com.android.phone process (shared
# uid 1001) under this package's SYSTEM_ALERT_WINDOW appop, so disabling the package alone isn't enough -
# denying that appop is the lever that actually blocks it. We do both. pm/appops persist across reboots,
# so india_simprompt_on undoes it when india isn't picked. Marker: $V/india_simprompt (so we only
# restore what we disabled).
CIDMGR=com.samsung.android.cidmanager
india_simprompt_off() {
  pm disable-user --user 0 $CIDMGR 2>/dev/null
  appops set $CIDMGR SYSTEM_ALERT_WINDOW ignore 2>/dev/null
  for p in $(pidof $CIDMGR 2>/dev/null); do kill $p 2>/dev/null; done
  touch $V/india_simprompt
  log "india: carrier-switch prompt (CID Manager) suppressed"
}
india_simprompt_on() {
  [ -e $V/india_simprompt ] || return 0
  pm enable $CIDMGR 2>/dev/null
  appops set $CIDMGR SYSTEM_ALERT_WINDOW allow 2>/dev/null
  rm -f $V/india_simprompt
  log "india: carrier-switch prompt restored (india not picked)"
}
india_apply() {
  csc_unbind; mkdir -p $R; I=$D/files/ins
  csc_bind $I/cscfeature.xml $CSCF csc_ins.xml
  [ -f $CCF ] && csc_bind $I/customer_carrier_feature.json $CCF ccf_ins.json
  [ -f $CUST ] && csc_bind $I/customer.xml $CUST customer_ins.xml
  # prism: full copy of the phone's folder (its sales_code.dat etc. unchanged) plus INS keystrings/images
  if [ -n "$PRISM" ] && [ -d $PRISM ]; then
    rm -rf $R/prism; mkdir $R/prism; cp -p $PRISM/* $R/prism/
    for f in $I/prism/*; do n=${f##*/}; case $n in INS_keystrings.dat) n=${SC}_keystrings.dat ;; esac; cp $f $R/prism/$n; done
    chmod 755 $R/prism; chmod 644 $R/prism/*; chcon -R u:object_r:vendor_configs_file:s0 $R/prism
    mount --bind $R/prism $PRISM || fail "bind $PRISM"
  fi
  log "india: INS carrier config on (sales code stays $SC on disk)"
  india_identity
  india_simprompt_off
}

# nronly: "LTE only" and "5G only" in Network mode (Settings > Connections > Mobile networks). Samsung's
# TelephonyUI has both: after building its list it adds LTE only when the SIM's carrier features ask for it
# (CarrierFeature_Setting_CustNetworkSelMenu4 containing LTEONLY; Jio SIMs always get it), then 5G only
# when CarrierFeature_VoiceCall_ConfigNetworkList contains _Add5gOnly (j7.a.a()). Those are per-carrier
# keys in customer_carrier_feature.json that the S23's files don't set. Add them to every carrier block of
# the file in use (the phone's own, or india's INS one), encode it again (on retail builds
# SemCarrierFeature reads only OMC-encoded files) and bind it. Apps get the values from zygote, so the
# framework restarts. 5G only means 5G standalone: no LTE fallback, so no signal where SA isn't deployed.
CCF_NR=ccf_nr.json
nr_ours() { [ -n "$CCF" ] && grep " $CCF " /proc/self/mountinfo 2>/dev/null | tail -n 1 | grep -q "/$CCF_NR "; }
nronly_apply() {
  mkdir -p $R; n=0; while nr_ours && [ $n -lt 5 ]; do umount $CCF; n=$((n+1)); done   # rebuild from what's under ours
  chmod 755 $OMCDEC 2>/dev/null
  $OMCDEC $CCF > $R/ccf_nr.dec 2>>$L || { log "nronly: couldn't decode $CCF"; rm -f $R/ccf_nr.dec; return 1; }
  # every "feature": { ... } block holds one "key": "value" per line; anything else and we leave the file alone
  awk 'function v(l) { sub(/^[^:]*: *"/, "", l); sub(/" *,? *$/, "", l); return l }
    /"feature": *\{ *$/ { print; inb = 1; n = 0; next }
    inb && /^[ \t]*\}/ {
      nl = ""; sm = ""; k = 0; ind = ""
      for (i = 1; i <= n; i++) {
        if (b[i] !~ /^[ \t]*"[^"]+": *"[^"]*" *,? *$/) bad = 1
        if (ind == "") { ind = b[i]; sub(/[^ \t].*/, "", ind) }
        if (b[i] ~ /"CarrierFeature_VoiceCall_ConfigNetworkList"/) nl = v(b[i])
        else if (b[i] ~ /"CarrierFeature_Setting_CustNetworkSelMenu4"/) sm = v(b[i])
        else { e = b[i]; sub(/ *, *$/, "", e); o[++k] = e }
      }
      if (ind == "") { ind = $0; sub(/[^ \t].*/, "", ind); ind = ind "  " }
      if (index(nl, "_Add5gOnly") == 0) nl = nl "_Add5gOnly"
      if (index(sm, "LTEONLY") == 0) sm = (sm == "" ? "LTEONLY" : sm ",LTEONLY")
      o[++k] = ind "\"CarrierFeature_Setting_CustNetworkSelMenu4\": \"" sm "\""
      o[++k] = ind "\"CarrierFeature_VoiceCall_ConfigNetworkList\": \"" nl "\""
      for (i = 1; i <= k; i++) print o[i] (i < k ? "," : "")
      print; inb = 0; next }
    inb { b[++n] = $0; next }
    { print }
    END { if (bad || inb) exit 1 }' $R/ccf_nr.dec > $R/ccf_nr.txt; ok=$?
  blocks=$(grep -c '"feature": *{ *$' $R/ccf_nr.dec)
  if [ $ok != 0 ] || [ "$blocks" -lt 1 ] || [ "$(grep -c '_Add5gOnly' $R/ccf_nr.txt)" != "$blocks" ] ||
     [ "$(grep -c '"CarrierFeature_Setting_CustNetworkSelMenu4": "[^"]*LTEONLY' $R/ccf_nr.txt)" != "$blocks" ]; then
    log "nronly: $CCF isn't laid out the way this edit expects; skipped"; rm -f $R/ccf_nr.dec $R/ccf_nr.txt; return 1
  fi
  $OMCDEC -e $R/ccf_nr.txt > $R/$CCF_NR.new 2>>$L && $OMCDEC $R/$CCF_NR.new 2>/dev/null | cmp -s - $R/ccf_nr.txt ||
    { log "nronly: encoding the edited carrier features failed; skipped"; rm -f $R/$CCF_NR.new $R/ccf_nr.dec $R/ccf_nr.txt; return 1; }
  mv $R/$CCF_NR.new $R/$CCF_NR; rm -f $R/ccf_nr.dec $R/ccf_nr.txt
  chmod 644 $R/$CCF_NR; chcon u:object_r:vendor_configs_file:s0 $R/$CCF_NR
  mount --bind $R/$CCF_NR $CCF || { log "nronly: couldn't bind $CCF"; return 1; }
  log "nronly: 'LTE only' and '5G only' added to Network mode for both SIMs (Settings > Connections > Mobile networks > Network mode)"
}
nronly_off() {
  nr_ours || return 1
  n=0; while nr_ours && [ $n -lt 5 ]; do umount $CCF; n=$((n+1)); done
  log "nronly: not picked; Network mode is back to Samsung's list"
}

# natroam: an Indian SIM on another circle's network of its own operator (an Airtel UP East SIM, 405-54, on
# Airtel Karnataka, 404-45) is on national roaming: the modem reports roaming, Android shows "R" and the
# data-roaming switch applies, though national roaming has been free in India since 2017. Android's carrier
# config key gsm_nonroaming_networks_string_array lists networks to treat as home; set it to India's MCCs
# for every Indian SIM (ICCID 8991...) through the Phone app's persistent override file, the one
# CarrierConfigManager.overrideConfig(persistent) writes (`cmd phone cc` refuses on user builds). Roaming
# abroad still shows. Our files are listed in $V/natroam; un-picking or cleanup deletes them.
CC_DIR=/data/user_de/0/com.android.phone/files; NROAM=$V/natroam
natroam_files() {   # "<default cache file> <override file>" for each Indian SIM the Phone app has a config for
  for f in $CC_DIR/carrierconfig-*-8991*-*.xml; do
    [ -f "$f" ] || continue; case $f in *-override-*) continue ;; esac
    b=${f##*/}; b=${b#carrierconfig-}; b=${b%.xml}       # <package>-<iccid>-<carrier id>
    cid=${b##*-}; b=${b%-*}; iccid=${b##*-}; pkg=${b%-*}
    case $iccid in 8991[0-9]*) echo "$f $CC_DIR/carrierconfig-$pkg-override-$iccid-$cid.xml" ;; esac
  done
}
natroam_apply() {
  natroam_files > $R/natroam.list
  [ -s $R/natroam.list ] || { log "natroam: no Indian SIM (ICCID 8991...) has a carrier config yet; insert one and apply again"; return 1; }
  changed=1
  while read f o; do
    ver=$(sed -n 's|.*name="__carrier_config_package_version__">\([^<]*\)<.*|\1|p' $f | head -n 1)
    [ -n "$ver" ] || { log "natroam: no package version in ${f##*/}; skipped that SIM"; continue; }
    if [ -f $o ] && ! grep -qxF "$o" $NROAM 2>/dev/null; then
      log "natroam: an override for one SIM already exists (not ours); left alone"; continue
    fi
    printf '%s\n' '<bundle>' '<string-array name="gsm_nonroaming_networks_string_array" num="3">' \
      '<item value="404" />' '<item value="405" />' '<item value="406" />' '</string-array>' \
      "<string name=\"__carrier_config_package_version__\">$ver</string>" '</bundle>' > $R/natroam.xml
    if ! cmp -s $R/natroam.xml $o 2>/dev/null; then
      cat $R/natroam.xml > $o; chown 1001:1001 $o; chmod 600 $o; chcon u:object_r:radio_data_file:s0 $o
      grep -qxF "$o" $NROAM 2>/dev/null || echo "$o" >> $NROAM
      changed=0
    fi
  done < $R/natroam.list
  rm -f $R/natroam.xml $R/natroam.list
  log "natroam: Indian networks (404/405/406) count as home on Indian SIMs; national roaming no longer shows 'R'"
  return $changed   # 0: a file changed, so the Phone app has to reload it
}
natroam_on() { [ -s $NROAM ] || return 1; while read o; do [ -f "$o" ] || return 1; done < $NROAM; }
natroam_off() {   # delete our override files; 0 if any was removed
  [ -s $NROAM ] || { rm -f $NROAM; return 1; }
  while read o; do rm -f "$o"; done < $NROAM; rm -f $NROAM
}

# ---------- Notification highlights (Galaxy AI priority + summaries) ----------
# One UI 8.5's Notification highlights sorts the notifications Android thinks important to the top of
# the panel and summarizes long or repeated chat notifications. The S23 firmware already carries all of
# it: NotificationManagerService's summarize path (NotiSummaryManager/NotiSummarizer), the Settings
# pages and com.samsung.android.intellivoiceservice's SummarizationService. What's off is the gate:
# NotificationManagerService's NmRune flags read SEC_FLOATING_FEATURE_GENAI_CONFIG_LLM_VERSION (the
# second number must be >= 70), COMMON_CONFIG_AI_VERSION (>= 20261) and
# FRAMEWORK_SUPPORT_PERSONALIZED_DATA_CORE, and the S23 firmware has no LLM version at all. The two
# switches are Secure settings that the Settings page (Notification highlights) would write; that page
# is hidden on the S23 because SecSettings' bool/config_na_enable is false, so they're set here.
# Summaries run on the phone (intellivoiceservice, no network) when the screen is off and the phone is
# idle, and need a Samsung account signed in. The model weights aren't on this phone though: Samsung
# ships them as com.samsung.android.offline.language.model, whose version list covers sm8650 and
# newer, not the S23's sm8550, so SIS answers pfd is null and no summary appears yet.
NH_UNDO=$V/undo/noti_intelligence   # the three settings as they were before the first apply
NH_KEYS="noti_intelligence_summarize_content noti_intelligence_priority_content noti_intelligence_priority_conversation"
nh_on() { [ "$(settings get secure noti_intelligence_summarize_content)" = 1 ]; }
nh_apply() {
  if [ ! -f $NH_UNDO ]; then mkdir -p $V/undo; for k in $NH_KEYS; do echo "$k $(settings get secure $k)" >> $NH_UNDO; done; fi
  ff_set GENAI_CONFIG_LLM_VERSION 0.81
  ff_set COMMON_CONFIG_AI_VERSION 20263
  ff_set FRAMEWORK_SUPPORT_PERSONALIZED_DATA_CORE TRUE
  for k in $NH_KEYS; do settings put secure $k 1; done
  nh_on || { log "highlights: couldn't write the notification intelligence settings"; return 1; }
  [ -n "$(nh_row)" ] || log "highlights: no Settings patch for $(getprop ro.build.PDA), so its page stays hidden (the switches above still work)"
  log "highlights: notification priority and summaries on"
}
nh_off() {   # 0 if anything we set was still there
  c=1
  if [ -f $NH_UNDO ]; then   # put back what was there before (wideflash's pattern)
    while read k v; do
      if [ "$v" = null ]; then settings delete secure $k >/dev/null 2>&1 && c=0
      else settings put secure $k "$v" >/dev/null 2>&1 && c=0; fi
    done < $NH_UNDO
    rm -f $NH_UNDO; return $c
  fi
  for k in $NH_KEYS; do
    [ "$(settings get secure $k)" = 1 ] || continue
    settings delete secure $k && c=0
  done
  return $c
}

# rambler: Gboard's Rambler voice typing (Gemini dictation that drops filler words and takes spoken edits),
# which Google turns on only for Pixel 10 and 11. Gboard 18.x has all of it; the server sends
# enable_agentic_dictation=false and switches off Rambler's toolbar and motion flags elsewhere. Gboard
# reads its flags in this order: hermetic override, its own local override store (shared_prefs/
# flag_override.xml, the in-app flag editor's), then the server's values, so a value there wins and stays
# until Gboard's storage is cleared. The set below is PixelBoard's (github.com/Akshayykadam/PixelBoard,
# GboardRambler1803StockPolicy), the patched Gboard reported to bring the Pixel's Rambler to other phones.
# Other overrides in the file are kept; the file as it was is saved once and put back on undo.
GB_PKG=com.google.android.inputmethod.latin; GB_PREFS=/data/user/0/$GB_PKG/shared_prefs
GB_OVR=$GB_PREFS/flag_override.xml; RB_UNDO=$V/undo/gboard_flag_override
RB_TRUE="enable_agentic_dictation config_agentic_dictation enable_jetson_in_toolbar filter_rambler_contributed_input_view_session
  enable_rambler_al_toolbar_overflow_menu enable_hide_rambler_al_idling_state rambler_motion_with_gradient_color
  agentic_dictation_spot_light2 agentic_dictation_new_gi_motion enable_jetson_s3_quota_experiment_override
  agentic_dictation_disable_pre_session_quota_check enable_pcm_audio_caching_for_offline_fallback show_rambler_dict_settings"
RB_FALSE="enable_rambler_al_toolbar agentic_dictation_enable_proactive_parallel_asr agentic_dictation_enable_seamless_fallback"
RB_LONG="ad_activation_type=2"
rb_names() { echo $RB_TRUE $RB_FALSE ${RB_LONG%%=*} | tr ' ' '|'; }
rambler_on() { grep -q 'name="enable_agentic_dictation" value="true"' $GB_OVR 2>/dev/null; }
rambler_write() {   # $1: new file content's path; keeps an existing file's owner and label, sets them on a new one
  am force-stop $GB_PKG   # Gboard reads the overrides when it starts; Android restarts the keyboard right away
  if [ -f $GB_OVR ]; then cat "$1" > $GB_OVR
  else
    cp "$1" $GB_OVR; chown $(stat -c %u:%g $GB_PREFS) $GB_OVR; chmod 660 $GB_OVR
    chcon $(ls -Zd $GB_PREFS | awk '{print $1}') $GB_OVR
  fi
}
rambler_apply() {
  # Gboard's storage is locked until the first unlock after a boot; the file from the last apply stays in effect
  [ -d $GB_PREFS ] || { log "rambler: Gboard's storage isn't readable yet (locked until the first unlock, or Gboard was never opened); open Gboard once and apply again"; return 1; }
  mkdir -p $R $V/undo
  if [ ! -e $RB_UNDO ] && [ ! -e $RB_UNDO.absent ]; then
    if [ -f $GB_OVR ]; then cp $GB_OVR $RB_UNDO; else : > $RB_UNDO.absent; fi
  fi
  # Android writes a preferences file with no entries as <map /> (self-closing); that, an empty file or no
  # file at all starts a new map. Anything else without <map> isn't a file we understand.
  if grep -q '<map>' $GB_OVR 2>/dev/null; then rb_base=keep
  elif [ ! -s $GB_OVR ] || grep -qE '<map ?/>' $GB_OVR; then rb_base=new
  else log "rambler: Gboard's flag_override.xml isn't a preferences file this understands; left alone"; return 1; fi
  { if [ $rb_base = keep ]; then grep -vE "name=\"($(rb_names))\"|</map>" $GB_OVR
    else echo '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>'; echo '<map>'; fi
    for k in $RB_TRUE; do echo "    <boolean name=\"$k\" value=\"true\" />"; done
    for k in $RB_FALSE; do echo "    <boolean name=\"$k\" value=\"false\" />"; done
    for kv in $RB_LONG; do echo "    <long name=\"${kv%%=*}\" value=\"${kv#*=}\" />"; done
    echo '</map>'; } > $R/gboard_flags.xml
  if cmp -s $R/gboard_flags.xml $GB_OVR; then log "rambler: on (Gboard's flag overrides already in place)"; rm -f $R/gboard_flags.xml; return 0; fi
  rambler_write $R/gboard_flags.xml; rm -f $R/gboard_flags.xml
  rambler_on || { log "rambler: couldn't write Gboard's flag overrides"; return 1; }
  log "rambler: on; pick it in Gboard settings > Voice typing > Dictation type > Rambler"
}
rambler_off() {   # put Gboard's flag_override.xml back as it was; 0 if it changed
  [ -e $RB_UNDO ] || [ -e $RB_UNDO.absent ] || return 1
  [ -d $GB_PREFS ] || return 1   # locked: try again next time
  if [ -e $RB_UNDO.absent ]; then am force-stop $GB_PKG; rm -f $GB_OVR
  else rambler_write $RB_UNDO; fi
  rm -f $RB_UNDO $RB_UNDO.absent
}

# Samsung's Mobile Hotspot offers 6 GHz only when SemWifiApServiceImpl.supportWifiAp6GBasedOnCountry() says
# so, and that wants the CSC country (ro.csc.countryiso_code) on a hard-coded list (isRegionFor6GCountry).
# Most S23 CSCs aren't on it, though the hardware and the stock hostapd run a 6 GHz hotspot fine.
# Setting the country to IN passes, but Samsung's servers then see a non-Indian model in India and refuse
# it: Samsung Wallet won't open (v1.3.3 and earlier did that). Instead this uses the method's own debug
# override, vendor.wifiap.6gbandcountry=1. system_server honours it only when SemWifiManager.MHSDBG is true,
# which is SemWifiApCust.DBG, read once from ro.product_ship=false. So: ro.product_ship false and the
# override (resetprop), restart the framework, wait for system_server to report 6g_Country:true (that
# call latches the flag), then put ro.product_ship back. The country is never changed. Until a reboot,
# Samsung's debug logging stays on in the processes that started during the restart (logcat only).
# With india the country is IN anyway, so nothing is needed.
H6_PROP=vendor.wifiap.6gbandcountry
h6_offered() { dumpsys sem_wifi 2>/dev/null | grep -q '6g_Country:true'; }
# before the framework restart: returns 0 when the restart is needed for it
hotspot6g_pre() {
  RP=/data/adb/ksu/bin/resetprop; [ -x $RP ] || { log "hotspot6g: KernelSU resetprop not found; skipped"; return 1; }
  [ "$(getprop ro.csc.countryiso_code)" = IN ] && { log "hotspot6g: CSC country is IN, which already offers 6 GHz"; return 1; }
  $RP $H6_PROP 1
  h6_offered && { log "hotspot6g: already on"; return 1; }
  H6_SHIP=$(getprop ro.product_ship); [ "$H6_SHIP" = false ] && H6_SHIP=""
  [ -n "$H6_SHIP" ] && $RP ro.product_ship false
  H6_WAIT=1
  log "hotspot6g: Samsung's 6 GHz hotspot override set; it loads with the framework restart (country stays $(getprop ro.csc.countryiso_code))"
}
# after the restart
hotspot6g_post() {
  [ "${H6_WAIT:-0}" = 1 ] || return 0
  RP=/data/adb/ksu/bin/resetprop; n=30; until h6_offered; do n=$((n-1)); [ $n = 0 ] && break; sleep 2; done
  [ -n "$H6_SHIP" ] && $RP ro.product_ship "$H6_SHIP"
  if h6_offered; then log "hotspot6g: Mobile hotspot > Band now offers 6 GHz (needs WPA3); country unchanged, Samsung Wallet unaffected"
  else log "hotspot6g: this firmware didn't take Samsung's 6 GHz override; 6 GHz not offered"; fi
}

# display: Always On Display auto brightness. The AOD app (BrightnessManager) builds its brightness curve
# from two framework tables, config_autoBrightnessLevels_doze (lux) and config_autoBrightnessDisplayValuesNits_doze
# (nits). The S23 ships both empty, so every light reading logs "getBrightnessValues not matched!" and the
# AOD gets 0 nits: the wallpaper on AOD shows bright, then drops to the minimum, whatever the room light.
# files/aodbright.apk (built from src/aodbright) is a static overlay with the S24 Ultra's two tables and
# nothing else. The AOD app reads them through Resources.getSystem(), which only has the overlays zygote
# found in the partitions' overlay folders when it started: so it goes on /product/overlay (an overlay
# layer, nothing written) and the framework restarts.
AODB=/product/overlay/s23tweaks-aodbright.apk
aodb_apply() {
  [ -f $AODB ] && { log "display: AOD brightness curve already in"; return 1; }
  [ -f $D/files/aodbright.apk ] || { log "display: files/aodbright.apk missing; AOD brightness curve skipped"; return 1; }
  T=/dev/s23tweaks_aodb; mkdir -p $T; mounted $T tmpfs || mount -t tmpfs -o mode=755 s23tweaks_aodb $T
  cp $D/files/aodbright.apk $T/${AODB##*/} && chmod 644 $T/${AODB##*/} && chcon -R u:object_r:system_file:s0 $T || fail "aodbright copy"
  mount -t overlay s23tweaks_product_overlay -o ro,lowerdir=$T:/product/overlay /product/overlay || fail "overlay on /product/overlay"
  log "display: AOD brightness curve added (/product/overlay)"
}
# Samsung's package manager skips it ("Package is not in allowed list"), so cmd overlay never lists it; zygote
# still loads it into every process's system resources, which is all the AOD app reads. On = system_server has it.
aodb_on() { grep -q s23tweaks-aodbright /proc/$(pidof system_server)/maps 2>/dev/null; }

# HideKSU: hide the KernelSU manager (me.weishu.kernelsu) from third-party apps, so their root/tamper
# checks (CRED, banking apps) can't enumerate it and stop crashing. The patched services.jar carries a
# helper (s23tweaks/H) called at the top of AppsFilterBase.shouldFilterApplicationInternal: it filters
# the manager out for any caller with appId >= 10000 except df.root (DFRoot loads root at boot) and the
# launcher (so its icon still shows). Nothing is injected into the apps themselves, so an app's own
# /proc/self/maps scan stays clean. Takes effect on a framework restart (system_server reloads the jar).
KSUJAR=/system/framework/services.jar
# The patched jar replaces the whole file, so it only goes on a phone whose stock services.jar is the exact
# one it was made from, whatever the firmware name. One row per stock jar: md5 stock, md5 patched, where
# it came from. tools/hideksupatch.sh makes the payload for another jar and prints its row; each payload
# is a PAYLOADS line "hideksu:<stock md5>".
HIDEKSU_JARS="30d17f5d60b0d42585b97a94412f6e12 f4c5966939637df194bb465478234fc3 SM-S918W S918WVLU8GZIF (XAC)
7dc62286f9f0675f84459943cdc397b6 a5449f73103be635f03fb6fdaf9f7d98 SM-S918B (INS)
c438dd27a76486855d01e74379e13b5d f4918c7454965788ecc0c9003cbea941 SM-S918U1"
# the row for the services.jar in place now (stock, or our patched copy bound over it)
hks_row() { m=$(md5 $KSUJAR); echo "$HIDEKSU_JARS" | awk -v m="$m" '$1 == m || $2 == m'; }
hideksu_apply() {
  [ -f $PL/hideksu/services.jar ] || { log "hideksu: payload missing; skipped"; return 1; }
  hideksu_on && { log "hideksu: patched services.jar already loaded"; return 1; }
  T=/dev/s23tweaks_svc; mkdir -p $T; mounted $T tmpfs || mount -t tmpfs -o mode=755 s23tweaks_svc $T
  bound $KSUJAR && umount $KSUJAR 2>/dev/null   # drop any earlier bind so one clean layer remains
  set -- $(hks_row)
  [ "$(md5 $KSUJAR)" = "$1" ] || { log "hideksu: this phone's services.jar isn't one a patch was made from; skipped"; return 1; }
  [ "$(md5 $PL/hideksu/services.jar)" = $2 ] || { log "hideksu: the downloaded services.jar isn't the one for this phone's; skipped"; return 1; }
  cp $PL/hideksu/services.jar $T/services.jar && chmod 644 $T/services.jar && chcon u:object_r:system_file:s0 $T $T/services.jar || fail "hideksu stage"
  mount -o bind $T/services.jar $KSUJAR || fail "bind services.jar"
  pidof system_server > $T/ss_at_bind   # hideksu_on: a system_server started after this loaded the jar
  log "hideksu: patched services.jar bound; the KernelSU manager is hidden from apps after the restart"
}
# On = the system_server that's running mapped OUR bound jar (its inode), not the stock one. Before a
# restart the bind is in place but the stock jar is still loaded, so the inode won't match yet.
hideksu_on() {
  # system_server runs the jar's dex from memory (the stock odex no longer matches), so the jar never shows
  # in its maps; instead: our jar is bound and system_server has restarted since it was bound
  bound $KSUJAR && [ -f /dev/s23tweaks_svc/ss_at_bind ] || return 1
  ss=$(pidof system_server) && [ "$ss" != "$(cat /dev/s23tweaks_svc/ss_at_bind)" ]
}

# chargewatts (experimental): the charging line on the lock screen and on the Always On Display also shows the
# power going into the battery, and what holds it back when that's well under 45 W: "54% • 20.9 W (tapering at
# 54%)", "45 m until full • 12.9 W (phone warm, 25 W charger)". A helper class (S23Watts, in a new dex) reads
# /sys/class/power_supply/battery whenever the line is redrawn: watts = averaged current x voltage; the reason is
# the kernel's winning charge-current vote in voter_status (heat, use, battery protection), else the battery being
# near its step voltage, plus hv_charger_status when the charger isn't a 45 W one.
#   SystemUI: one call before KeyguardSecIndicationController.addInitialIndication() posts the BATTERY text.
#   AOD (com.samsung.android.app.aodservice, runs as a plugin inside SystemUI): every return of the method that
#   builds the "until full" line: the built-in copy in /system, or a Galaxy Store update in /data/app. On a
#   framework restart the package manager re-checks the signature of a /data/app apk whose time changed
#   (collectCertificatesLI: "<path> changed; collecting certs") and uninstalled a bound, patched update in
#   v1.8.12 testing. So the patched copy gets the stock file's time (the stored signature is reused, as for an
#   untouched apk), and the module's own framework restart runs with that bind off.
# tools/chargewatts/build.sh makes both from the stock APKs. Each patched APK keeps every stock byte up to its
# signing block, so the download holds only the tails, and fits only the exact APK it was made from.
# Rows: kind, md5 stock, md5 patched, stock bytes kept, where it came from.
SYSUI=/system_ext/priv-app/SystemUI/SystemUI.apk
AOD_PKG=com.samsung.android.app.aodservice
# aod rows cover both the built-in AODService_v80 and any Galaxy Store update of the app (whichever is the
# active apk); each tail in the payload is named AOD-<patched md5>.tail so several can live side by side.
# A Store update is the same file on every model, so its tail goes into every model's payload (v1.8.14 left it
# out of the S918B's, #56).
CW_ROWS="systemui adcea3e330bb75ab20c8a3602d5a3a65 d5ffd6967577b1ffc82f0b868fc9e0d7 62025728 S918WVLU8GZIF
aod 8765be536661cd4f6f8c2e29a6006766 90f34f5d1af98bea2e5ed71594f73339 52326400 8.9.65.90
aod ea75116a19018c6cb95a0701f506522c 5516690875ece0aa5c48c6f70d72f403 40398848 8.9.67.3
systemui fbd2cd7e81ccce52bf1f4720f973ddb7 beb45e2b83ef4f62378348eb001f3567 95891456 S918BXXUAGZIF
aod cb572b0e9e3fcdfd7416af8a116ff4cb bba34e790b4ced94f36f13871d36baca 52326400 8.9.65.90"
AOD_SYS=/system/priv-app/AODService_v80/AODService_v80.apk
aod_apk() { pm path $AOD_PKG 2>/dev/null | sed -n 's/^package://p' | head -n 1; }
cw_rowof() { m=$(md5 "$2"); echo "$CW_ROWS" | awk -v k=$1 -v m="$m" '$1 == k && ($2 == m || $3 == m)'; }   # cw_rowof <kind> <apk>
cw_row() { cw_rowof systemui $SYSUI; }
cw_patched() { [ -n "$2" ] && bound "$2" && [ "$(md5 "$2")" = "$(cw_rowof $1 "$2" | cut -d' ' -f3)" ]; }
cw_on() { cw_patched systemui $SYSUI; }
cw_ours() { grep " $1 " /proc/1/mountinfo | grep -q "/payload/chargewatts/"; }   # bound by chargewatts (any version)
cw_aod_data() { a=$(aod_apk); case "$a" in /data/*) cw_ours "$a" && echo "$a" ;; esac; }   # our bind over a Store update
cw_aod_on() { a=$(aod_apk); cw_patched aod "$a"; }   # the active AOD apk (built-in or a Store update) is patched
sysui_restart() { p=$(pidof com.android.systemui) && kill $p; }   # persistent: Android starts it again at once
# cw_bind <kind> <apk>: rebuild the patched copy from the stock APK + its tail and bind it read-only. The tail
# is SystemUI.tail for systemui, AOD-<patched md5>.tail for aod (so the built-in and a Store update can both
# ship in one payload). 0 = newly bound, 1 = failed, 2 = already bound. A bind is read-write whatever "ro"
# says, and Android then won't precompile the app and runs it from bytecode, so hidemnt remounts it read-only.
cw_bind() {
  k=$1; t=$2; set -- $(cw_rowof $k "$t")   # $1 kind, $2 stock md5, $3 patched md5, $4 keep bytes
  [ $k = systemui ] && n=SystemUI || n=AOD-$3
  cw_patched $k "$t" && return 2
  bound "$t" && umount -l "$t"   # someone else's or an older copy: start from stock
  P=$PL/chargewatts/$n.apk
  if [ "$(md5 $P 2>/dev/null)" != $3 ]; then
    [ -f $PL/chargewatts/$n.tail ] || { log "chargewatts: $n: download missing"; return 1; }
    head -c $4 "$t" > $P.new && cat $PL/chargewatts/$n.tail >> $P.new
    [ "$(md5 $P.new)" = $3 ] || { rm -f $P.new; log "chargewatts: the rebuilt $n isn't the expected one"; return 1; }
    mv $P.new $P
  fi
  chmod 644 $P; chcon "$(ls -Z "$t" | cut -d' ' -f1)" $P   # keep the stock file's label (system_file or apk_data_file)
  touch -r "$t" $P   # and its time, so the package manager doesn't re-check the signature (see above)
  mount -o bind $P "$t" || { log "chargewatts: couldn't bind the patched $n"; return 1; }
  [ -x $HIDEMNT ] || chmod 755 $HIDEMNT 2>/dev/null
  $HIDEMNT rdonly "$t" 2>/dev/null || log "chargewatts: warning: couldn't make the $n bind read-only, so it runs uncompiled (slower)"
  return 0
}
# The direct-charging step table (device tree, big-endian u32s), copied to a file in SystemUI's device-protected
# data, which SystemUI can read (the device tree is plain sysfs to it): line 1 the battery level each step ends
# at, line 2 each step's battery current in mA. S23Watts uses it to say where the current next drops.
CW_STEPS=/data/user_de/0/com.android.systemui/files/s23tweaks_dcsteps
dtu32() { for h in $(od -An -tx1 -v "$1" 2>/dev/null | tr -d ' \n' | sed 's/\(........\)/\1 /g'); do echo $((0x$h)); done | tr '\n' ' '; }
cw_steps() {
  T=/proc/device-tree/samsung_mobile_device/battery; F=${CW_STEPS%/*}
  [ -d $F ] && [ -f $T/battery,dc_step_chg_val_iout ] || return 0
  n=$(dtu32 $T/battery,dc_step_chg_step | cut -d' ' -f1)
  soc=$(dtu32 $T/battery,dc_step_chg_cond_soc | cut -d' ' -f1-$n); iout=$(dtu32 $T/battery,dc_step_chg_val_iout | cut -d' ' -f1-$n)
  [ -n "$n" ] && [ -n "$soc" ] && [ -n "$iout" ] || return 0
  printf '%s\n%s\n' "$soc" "$iout" > $CW_STEPS.new && chown $(stat -c %u:%g $F) $CW_STEPS.new && chmod 644 $CW_STEPS.new &&
    chcon "$(ls -Zd $F | cut -d' ' -f1)" $CW_STEPS.new && mv $CW_STEPS.new $CW_STEPS || rm -f $CW_STEPS.new
}
# cw_apply: returns 0 when SystemUI has to restart to load the patched copies
cw_apply() {
  cw_ours $SYSUI && [ -z "$(cw_row)" ] && umount -l $SYSUI   # an older chargewatts copy: back to stock, which has a row
  [ -n "$(cw_row)" ] || { log "chargewatts: this phone's SystemUI (md5 $(md5 $SYSUI)) isn't one the patch was made for; skipped"; return 1; }
  cw_steps
  ch=0; cw_bind systemui $SYSUI; r=$?
  [ $r = 1 ] && return 1; [ $r = 0 ] && ch=1
  a=$(aod_apk); aod=0   # patch whichever AOD apk is active: the built-in, or a Galaxy Store update in /data/app
  [ -n "$a" ] && cw_ours "$a" && [ -z "$(cw_rowof aod "$a")" ] && umount -l "$a"   # likewise an older AOD copy
  if [ -z "$a" ]; then log "chargewatts: no Always On Display app; lock screen only"
  elif [ -z "$(cw_rowof aod "$a")" ]; then
    log "chargewatts: this Always On Display (md5 $(md5 "$a"), $(dumpsys package $AOD_PKG | sed -n 's/^ *versionName=//p' | head -n 1)) isn't one the patch was made for ($(echo "$CW_ROWS" | awk '$1 == "aod" {print $NF}' | sort -u | tr '\n' ' ' | sed 's/ $//')); lock screen only"
  else
    [ "$a" != $AOD_SYS ] && bound $AOD_SYS && umount -l $AOD_SYS   # drop a stale built-in bind left from before a Store update
    cw_bind aod "$a"; r=$?; [ $r = 0 ] && ch=1; [ $r != 1 ] && aod=1
  fi
  [ $ch = 0 ] && [ -f /dev/s23tweaks_cw ] && { log "chargewatts: already on"; return 1; }   # SystemUI restarted after the binds
  cmd package compile -m speed-profile -f com.android.systemui >/dev/null 2>&1 ||
    log "chargewatts: warning: precompiling SystemUI failed; it runs uncompiled until Android does it"
  [ $aod = 1 ] && cmd package compile -m speed-profile -f $AOD_PKG >/dev/null 2>&1
  log "chargewatts: $([ $aod = 1 ] && echo "lock screen, Always On Display and charging notification show" || echo "lock screen and charging notification show") the charging watts (experimental; if the lock screen, AOD or status bar misbehaves, unpick this)"
  return 0
}
cw_off() {
  a=$(aod_apk); aodp=0; [ -n "$a" ] && cw_patched aod "$a" && aodp=1
  for t in $SYSUI $AOD_SYS "$a"; do [ -n "$t" ] && bound "$t" && umount -l "$t"; done
  bound $SYSUI && return 1
  rm -f /dev/s23tweaks_cw $CW_STEPS
  cmd package compile -m speed-profile -f com.android.systemui >/dev/null 2>&1   # the stock dex has its own compiled code
  [ $aodp = 1 ] && cmd package compile -m speed-profile -f $AOD_PKG >/dev/null 2>&1
  return 0
}

# hideksu part 2: hide the module's mounts from apps that shouldn't see them. The module binds every
# tweak into init's mount namespace, so every app inherits them and a detector flags them as
# suspicious/inconsistent mounts. KernelSU's own umount is all-or-nothing (every non-root app at spawn),
# which would also strip the mounts from the Samsung apps the tweaks modify (Camera, Gallery, Settings,
# the galaxyai apps, ...) and break them. files/hidemnt (src/hidemnt) instead watches process spawns via
# the kernel's process-event connector and, by install origin, hides the mounts only from apps that
# never consume them: every user-installed app (banking, root detectors) is hidden from by default,
# while every preinstalled system/Samsung app keeps the mounts (a system app updated via the store keeps
# FLAG_SYSTEM, so updated consumers are safe too). It enters only that app's mount namespace and detaches
# the module's mounts there (one native setns+umount pass, fast enough to finish before the app's own code
# runs). init and every other process keep the mounts. $HIDEAPPS is an optional override list: a plain
# package force-hides a system app, a leading '-' force-keeps a user-installed one; re-apply or reboot
# (or just edit it - the watcher reloads it on change) to apply.
HIDEMNT=$D/files/hidemnt
HIDEAPPS=$V/hide-apps.txt; HIDESYS=$V/hidemnt-system.txt
seed_hideapps() {
  [ -f $HIDEAPPS ] && return
  cat > $HIDEAPPS <<'EOF'
# hideksu overrides (optional). By default the module's mounts are hidden from every user-installed app
# (banking, root detectors) and kept for every preinstalled system/Samsung app, so you usually need
# nothing here. One package per line, '#' starts a comment. The watcher reloads this file when it changes.
#   <package>     force-hide this app even if it is a system app
#   -<package>    force-keep this app (don't hide) even if it is user-installed
# Examples:
#   com.google.android.gms
#   -com.example.myrootedapp
EOF
  chmod 644 $HIDEAPPS
}
hidemnt_count() { grep -cvE '^[[:space:]]*(#|$)' $HIDEAPPS 2>/dev/null || echo 0; }
hidemnt_running() { ps -A -o ARGS 2>/dev/null | grep -q "[h]idemnt daemon"; }
hidemnt_stop() {
  for p in $(ps -A -o PID,ARGS 2>/dev/null | grep "[h]idemnt daemon" | awk '{print $1}'); do kill "$p" 2>/dev/null; done
  rm -f $V/hidemnt.pid
}
hidemnt_start() {
  [ -x $HIDEMNT ] || { chmod 755 $HIDEMNT 2>/dev/null; [ -x $HIDEMNT ] || { log "hideksu: files/hidemnt missing; app mount-hiding skipped"; return 1; }; }
  seed_hideapps
  hidemnt_stop                          # restart so an edited override list takes effect
  # The system packages, from the package manager: One UI 7+ stores packages.xml as binary XML (ABX),
  # which hidemnt can't read. Apps installed later aren't system apps, so the list needn't be refreshed
  # until an update adds system apps, and every boot rewrites it. -u: also those removed for this user.
  pm list packages -s -u 2>/dev/null | sed -n 's/^package://p' > $HIDESYS.tmp && mv $HIDESYS.tmp $HIDESYS
  ns=$(grep -c . $HIDESYS 2>/dev/null); ns=${ns:-0}
  setsid $HIDEMNT daemon $HIDEAPPS $HIDESYS </dev/null >/dev/null 2>&1 &
  echo $! > $V/hidemnt.pid
  n=$(hidemnt_count)
  [ "$n" -gt 0 ] 2>/dev/null && ov=" ($n override(s) in ${HIDEAPPS##*/})" || ov=""
  if [ "$ns" -lt 32 ] 2>/dev/null; then
    log "hideksu: warning: the package manager listed only $ns system apps; hiding mounts only from the apps in ${HIDEAPPS##*/}"
  else
    log "hideksu: hiding the module's mounts from user-installed apps ($ns system apps keep them)$ov"
  fi
}

# After a framework restart SystemUI can come up while Wi-Fi is still reconnecting and then drop the
# Wi-Fi *signal* icon from the status bar (Wi-Fi Calling stays), even though Wi-Fi is connected. Cycling
# the Wi-Fi slot through SystemUI's icon blocklist makes it rebuild the slot from the live state; it's a
# display-only nudge and never touches the radio. The user's existing blocklist is preserved exactly, and
# if they've deliberately hidden the Wi-Fi icon (wifi already in the list) it's left alone.
statusbar_wifi_refresh() {
  cur=$(settings get secure icon_blacklist 2>/dev/null); [ "$cur" = null ] && cur=""
  case ",$cur," in *,wifi,*) return 0 ;; esac
  [ -n "$cur" ] && new="$cur,wifi" || new="wifi"
  settings put secure icon_blacklist "$new" 2>/dev/null || return 0
  sleep 1
  sb_restore() { if [ -n "$cur" ]; then settings put secure icon_blacklist "$cur" >/dev/null 2>&1
                 else settings delete secure icon_blacklist >/dev/null 2>&1; fi; }
  wait_for 10 sb_restore || log "status bar: couldn't restore icon_blacklist; the Wi-Fi icon may stay hidden until you reset it"
  log "status bar: nudged SystemUI to redraw the Wi-Fi icon after the framework restart"
}

# dual5g: 5G standalone on both SIMs at once (5G+5G DSDS). The modem's Qualcomm policyman decides it:
# device_config.xml has <msim_config mode="5G_PLUS_5G" list="msim_plmns"/>, and global_defines.xml limits
# msim_plmns to 460-* 712-* (China, Costa Rica). Anywhere else the modem runs 5G_PLUS_4G, and
# disable_sa_ndds.xml takes the SA bands away from the SIM that isn't the data SIM. This adds the MCCs of
# the SIMs in the phone to msim_plmns. It is a file in the modem's own storage (EFS), so unlike the other
# tweaks it stays after a reboot: dual5g_restore puts the original back. files/efstool (src/efstool) reads
# and writes EFS through the stock /vendor/bin/diag_socket_log; policyman reads the file when the modem
# boots, so a write is followed by a modem-only restart (remoteproc, ~15 s without signal).
D5G=$V/dual5g; D5G_F=/policyman/global_defines.xml; D5G_SD=/sdcard/Download/s23tweaks-modem-backup
EFST=$D/files/efstool   # module files ship 0644; cleanup runs from /dev after the module folder is gone
if [ -f $EFST ]; then [ -x $EFST ] || chmod 755 $EFST 2>/dev/null; else EFST=/dev/s23tweaks_efstool; fi
d5g_mccs() {   # MCCs of the SIMs and of the networks they're on; countries with several MCCs get all of them
  for n in $(getprop gsm.sim.operator.numeric | tr ',' ' ') $(getprop gsm.operator.numeric | tr ',' ' '); do
    m=$(echo "$n" | cut -c1-3)
    case $m in
      404|405|406) echo 404 405 406 ;;                       # India (a carrier's SIM and towers can differ)
      310|311|312|313|314|315|316) echo 310 311 312 313 314 315 316 ;;   # United States
      440|441) echo 440 441 ;;                               # Japan
      234|235) echo 234 235 ;;                               # United Kingdom
      [0-9][0-9][0-9]) echo $m ;;
    esac
  done | tr ' ' '\n' | grep -E '^[0-9]{3}$' | sort -u | tr '\n' ' '
}
d5g_line() { grep -v '<!--' "$1" | grep '<plmn_list name="msim_plmns"'; }   # skips the commented-out stock line
d5g_list() { d5g_line "$1" | sed -E 's/.*<plmn_list name="msim_plmns"[^>]*>([^<]*)<\/plmn_list>.*/\1/'; }
d5g_added() { grep -m1 -o 's23tweaks dual5g added:[ 0-9]*' "$1" 2>/dev/null | cut -d: -f2; }
d5g_strip() {   # $1 -> $2 without what dual5g added (used only when there is no stock backup)
  rm_list=$(d5g_added "$1")
  awk -v rm="$rm_list" 'BEGIN { n = split(rm, a, " ") }
    /s23tweaks dual5g added:/ { next }
    /<plmn_list name="msim_plmns"/ && !/<!--/ { for (i = 1; i <= n; i++) gsub(" " a[i] "-\\*", "") }
    { print }' "$1" > "$2"
}
d5g_modem_restart() {
  r=""; for x in /sys/class/remoteproc/remoteproc*; do grep -q 'remoteproc-mss' $x/name 2>/dev/null && r=$x; done
  [ -n "$r" ] || { log "dual5g: can't find the modem's remoteproc; reboot the phone to use the new setting"; return 1; }
  log "dual5g: restarting the modem so it reads the new setting (no signal for ~15 s)"
  echo stop > $r/state 2>/dev/null; sleep 2
  d5g_running() { [ "$(cat $r/state)" = running ]; }
  for i in 1 2 3; do echo start > $r/state 2>/dev/null; wait_for 20 d5g_running && break; done
  [ "$(cat $r/state)" = running ] || { log "dual5g: the modem didn't come back; reboot the phone"; return 1; }
  wait_for 60 sh -c 'getprop gsm.sim.state | grep -q LOADED'; log "dual5g: modem back up"
}
d5g_put() {   # $1 new file, $2 the file it replaces (rollback). Write, read back, compare; roll back on mismatch
  $EFST put "$1" $D5G_F 2>>$L && $EFST get $D5G_F $R/d5g_check.xml 2>>$L && cmp -s "$1" $R/d5g_check.xml && return 0
  log "dual5g: the write didn't verify; putting the previous file back"
  $EFST put "$2" $D5G_F 2>>$L && $EFST get $D5G_F $R/d5g_check.xml 2>>$L && cmp -s "$2" $R/d5g_check.xml &&
    { log "dual5g: previous file restored"; return 1; }
  log "dual5g: COULD NOT RESTORE the modem file. The original is in $D5G/stock and $D5G_SD; run 'tweaks.sh dual5g-restore', or use *#27663368378# > ETC > MCFG > MCFG HW & SW RELOAD"
  return 1
}
d5g_backup_stock() {   # once, before the first write ever; never overwritten
  [ -f $D5G/stock/global_defines.xml ] && return 0
  mkdir -p $D5G/stock
  if [ -n "$(d5g_added $1)" ]; then d5g_strip $1 $D5G/stock/global_defines.xml   # ours already: rebuild the original
  else cp $1 $D5G/stock/global_defines.xml; fi
  for f in device_config.xml disable_sa_ndds.xml; do $EFST get /policyman/$f $D5G/stock/$f 2>/dev/null; done
  mkdir -p $D5G_SD && cp $D5G/stock/* $D5G_SD/ && cat > $D5G_SD/README.txt <<EOF
Original modem files from before s23-ultra-tweaks' "dual5g" tweak changed /policyman/global_defines.xml
(model $(getprop ro.product.model), firmware $(getprop ro.build.PDA), saved $(date '+%Y-%m-%d %H:%M')).
To put the original back: un-pick dual5g and apply, or run as root: sh <module folder>/tweaks.sh dual5g-restore
Without the module: dial *#27663368378# > ETC > MCFG > MCFG HW & SW RELOAD (rewrites the modem's stock config).
EOF
  log "dual5g: original modem file backed up to $D5G/stock and $D5G_SD"
}
dual5g_apply() {
  mkdir -p $R $D5G
  wait_for 90 sh -c 'getprop gsm.sim.state | grep -q LOADED' || { log "dual5g: skipped: no SIM is ready"; return 1; }
  sleep 3; mccs=$(d5g_mccs)
  [ -n "$mccs" ] || { log "dual5g: skipped: the SIMs report no network code yet (try again later)"; return 1; }
  $EFST get $D5G_F $R/d5g_live.xml 2>>$L || { log "dual5g: can't read $D5G_F from the modem"; return 1; }
  [ "$(d5g_line $R/d5g_live.xml | wc -l)" = 1 ] || { log "dual5g: skipped: this modem has no single msim_plmns list in $D5G_F"; return 1; }
  d5g_backup_stock $R/d5g_live.xml || { log "dual5g: couldn't back up the original; not changing anything"; return 1; }
  cur=" $(d5g_list $R/d5g_live.xml) "; add=""
  for m in $mccs; do case "$cur" in *" $m-* "*) ;; *) add="$add $m" ;; esac; done
  if [ -z "$add" ]; then
    log "dual5g: on; the modem already allows 5G on both SIMs for $(echo $mccs | sed 's/[0-9][0-9]*/&-*/g')"
    echo "$cur" > $D5G/applied; return 0
  fi
  cp $R/d5g_live.xml $D5G/before-$(date +%Y%m%d-%H%M%S).xml   # every write gets its own backup
  ours=$(echo $(d5g_added $R/d5g_live.xml) $add | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')
  plmns=$(echo $add | sed 's/[0-9][0-9]*/&-*/g')
  awk -v plmns="$plmns" -v ours="$ours" '
    /s23tweaks dual5g added:/ { next }
    /<plmn_list name="msim_plmns"/ && !/<!--/ { sub(/ *<\/plmn_list>/, " " plmns " </plmn_list>"); print
      print "    <!-- s23tweaks dual5g added: " ours " -->"; next }
    { print }' $R/d5g_live.xml > $R/d5g_new.xml
  [ "$(d5g_line $R/d5g_new.xml | wc -l)" = 1 ] && grep -q '</policy>' $R/d5g_new.xml || { log "dual5g: building the new file failed; nothing changed"; return 1; }
  d5g_put $R/d5g_new.xml $R/d5g_live.xml || return 1
  log "dual5g: msim_plmns is now$(d5g_list $R/d5g_new.xml)"
  echo " $(d5g_list $R/d5g_new.xml) " > $D5G/applied
  d5g_modem_restart
}
dual5g_restore() {   # put the original modem file back
  mkdir -p $R
  $EFST get $D5G_F $R/d5g_live.xml 2>>$L || { log "dual5g: can't read $D5G_F from the modem"; return 1; }
  if [ -f $D5G/stock/global_defines.xml ]; then src=$D5G/stock/global_defines.xml
  elif [ -f $D5G_SD/global_defines.xml ]; then src=$D5G_SD/global_defines.xml
  elif [ -n "$(d5g_added $R/d5g_live.xml)" ]; then d5g_strip $R/d5g_live.xml $R/d5g_orig.xml; src=$R/d5g_orig.xml
  else log "dual5g: no backup and no change of ours in the modem file; nothing to restore"; rm -f $D5G/applied; return 0; fi
  if cmp -s $src $R/d5g_live.xml; then log "dual5g: the modem file is already the original"; rm -f $D5G/applied; return 0; fi
  d5g_put $src $R/d5g_live.xml || return 1
  rm -f $D5G/applied; log "dual5g: original modem file restored (msim_plmns:$(d5g_list $src))"
  d5g_modem_restart
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
mod_ver() { if [ $MODULE = 1 ]; then grep -m1 '^version=' $D/module.prop | cut -d= -f2; else echo "script (install.sh)"; fi; }
phone_facts() {
  model=$(getprop ro.product.model); build=$(getprop ro.build.PDA); csc=$(getprop ro.csc.sales_code)
  gms=$(dumpsys package com.google.android.gms 2>/dev/null | grep -m1 -oE 'versionCode=[0-9]+' | cut -d= -f2)
  lcv=$(lc_installed)
}
# why_not TWEAK: print why it can't run on this phone (nothing if it can). Needs phone_facts.
why_not() {
  case "$model" in SM-S918*) ;; *) echo "this is for the Galaxy S23 Ultra (SM-S918*), not $model"; return ;; esac
  case $1 in
    airdrop|wifi7)
      kernel_supported || { echo "needs firmware $(echo $AIRDROP_FW | sed 's/ /, /g') (this phone runs $build)"; return; }
      if ! kernel_stock && ! cfg80211_stock; then
        echo "this kernel ships its own Wi-Fi stack (cfg80211.ko built for $(cfg80211_vermagic | grep . || echo "an unknown kernel"), not $AIRDROP_KBASE*), which the S24 Wi-Fi driver can't register with; the 6 GHz hotspot still works"; return
      fi
      [ "${gms:-0}" -ge $GMS_MIN ] || echo "needs Google Play services 26.11 or newer" ;;
    callrec|india)
      [ -f "$CSCF" ] || { echo "can't find this phone's carrier config (mdc.system.path is '$CSYS')"; return; }
      if [ $1 = india ]; then
        [ "$SC" = INS ] && [ ! -e $V/india_identity ] && { echo "this phone's sales code is INS already"; return; }
        [ "$(getprop ro.build.version.oneui | cut -c1)" = 9 ] || echo "needs One UI 9 (the INS files come from One UI 9 firmware)"
      else
        [ -f $OMCDEC ] || echo "files/omcdec is missing"
      fi ;;
    battery)
      for f in $BATT_EFS; do [ -f /efs/FactoryApp/$f ] || { echo "this phone has no $f in /efs/FactoryApp"; return; }; done ;;
    colortone)
      [ -n "$(ead_row)" ] || echo "needs firmware $(ead_builds) (it patches that build's Settings app; this phone runs $build)" ;;
    hotspot6g) [ -x /data/adb/ksu/bin/resetprop ] || echo "needs KernelSU's resetprop" ;;
    weather)
      pm path $WX_LIVE >/dev/null 2>&1 || { echo "this phone has no Samsung live wallpaper app ($WX_LIVE)"; return; }
      pm path com.samsung.android.app.dressroom >/dev/null 2>&1 || echo "this phone has no Wallpaper and style app (DressRoom)" ;;
    camerahdr) grep -q "<SEC_FLOATING_FEATURE_$CH_KEY>[^<]" $FF 2>/dev/null || echo "this firmware has no $CH_KEY camera setting to add the HDR steps to" ;;
    videosoftening|afcontrol|aelimit) grep -q '</SecFloatingFeatureSet>' $FF 2>/dev/null || echo "this firmware's $FF can't be edited" ;;
    tenbit) [ -f $TB_LIB ] || echo "this phone has no $TB_LIB" ;;
    wearretry) [ -x $AIR/sqlite3 ] || echo "needs the AirDrop download (its sqlite3 sets the flag): pick AirDrop, apply, then pick this" ;;
    # an older version's patched SystemUI still mounted (an upgrade before a reboot) hides the stock md5; it was
    # built for this phone's stock SystemUI and rows are only ever added, so it counts; cw_apply swaps it
    chargewatts) [ -n "$(cw_row)" ] || cw_ours $SYSUI || echo "this phone's SystemUI (md5 $(md5 $SYSUI)) isn't one a patch was made from, checked by MD5 (so far $(echo "$CW_ROWS" | awk '$1 == "systemui" {print $5}' | tr '\n' ',' | sed 's/,$//; s/,/, /g')'s); tools/chargewatts/build.sh can make one" ;;
    hideksu)
      set -- $(hks_row); m=$(md5 $KSUJAR)
      [ -n "$1" ] && { [ "$m" = $1 ] || bound $KSUJAR; } ||
        { echo "this phone's /system/framework/services.jar (md5 $m) isn't one a patch was made from ($(echo "$HIDEKSU_JARS" | cut -d' ' -f3- | tr '\n' ',' | sed 's/,$//; s/,/, /g')); tools/hideksupatch.sh can make one"; return; }
      pm path me.weishu.kernelsu >/dev/null 2>&1 || echo "the KernelSU manager (me.weishu.kernelsu) isn't installed, so there's nothing to hide" ;;
    hdr2023) for f in $H23_LIBS; do [ -f /system/lib64/$f ] || { echo "this phone has no /system/lib64/$f to replace"; return; }; done ;;
    logvideo|camextras|wideflash|prowbtint|zoomrocker|slowmoaf|extstorage|anamorphic|uhd60lenses) grep -q '</resources>' $CF 2>/dev/null || echo "this firmware's $CF can't be edited" ;;
    profps) grep -q '</resources>' $CF 2>/dev/null || echo "this firmware's $CF can't be edited" ;;
    galaxyai)
      for p in $GAI_APPS; do [ -f /system/$p/${p#*/}.apk ] || { echo "this phone has no /system/$p/${p#*/}.apk to replace"; return; }; done ;;
    highlights)
      cmd package query-services -a android.intellivoiceservice.SummarizationService 2>/dev/null | grep -q SummarizationService ||
        echo "this phone has no on-device summarization service (com.samsung.android.intellivoiceservice)" ;;
    settingssearch) [ -f /system/$SSI/SecSettingsIntelligence.apk ] || echo "this phone has no /system/$SSI to replace" ;;
    rambler) pm path $GB_PKG >/dev/null 2>&1 || echo "Gboard (com.google.android.inputmethod.latin) isn't installed" ;;
    nronly)
      [ -f "$CCF" ] || { echo "can't find this phone's customer_carrier_feature.json (mdc.system.path is '$CSYS')"; return; }
      [ -f $OMCDEC ] || { echo "files/omcdec is missing"; return; }
      pm path com.samsung.android.app.telephonyui >/dev/null 2>&1 || echo "this phone has no Samsung TelephonyUI (Mobile networks settings)" ;;
    natroam)
      [ -d $CC_DIR ] || { echo "can't find the Phone app's carrier config folder"; return; }
      [ -n "$(natroam_files)" ] || echo "needs an Indian SIM (Airtel, Jio, Vi, BSNL)" ;;
    dual5g)
      [ -x $EFST ] || { echo "files/efstool is missing"; return; }
      [ -x /vendor/bin/diag_socket_log ] || { echo "this firmware has no /vendor/bin/diag_socket_log to reach the modem with"; return; }
      [ "$(getprop persist.radio.multisim.config)" = dsds ] || echo "needs a dual-SIM phone in dual standby (DSDS) mode" ;;
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
    india) bound $CSCF && grep -q '<SalesCode>INS<' $CSCF 2>/dev/null ;;
    callrec) bound $CSCF && grep -q 'ConfigRecording>RecordingAllowed<' $CSCF 2>/dev/null ;;
    hotspot6g) h6_offered ;;
    wifi7) bound $WPAS && bound $INI ;;
    display) bound $FF && grep -q "<SEC_FLOATING_FEATURE_LCD_CONFIG_AOD_FULLSCREEN>1<" $FF 2>/dev/null ;;
    logvideo) bound $CF && grep -q 'name="SUPPORT_LOG_VIDEO" value="true"' $CF 2>/dev/null ;;
    camextras) bound $CF && grep -q 'name="SUPPORT_SUPER_STEADY_HORIZONTAL_LOCK" value="true"' $CF 2>/dev/null ;;
    wideflash) bound $CF && grep -q 'name="SUPPORT_FLASH_IN_WIDE_LENS" value="true"' $CF 2>/dev/null ;;
    prowbtint) bound $CF && grep -q 'name="SUPPORT_PRO_WHITE_BALANCE_TINT" value="true"' $CF 2>/dev/null ;;
    zoomrocker) bound $CF && grep -q 'name="SUPPORT_VIDEO_MODE_ZOOM_ROCKER" value="true"' $CF 2>/dev/null ;;
    videosoftening) grep -q '<SEC_FLOATING_FEATURE_CAMERA_SUPPORT_VIDEO_SOFTENING>TRUE<' $FF 2>/dev/null ;;
    afcontrol) grep -q '<SEC_FLOATING_FEATURE_CAMERA_SUPPORT_AFSPEED>TRUE<' $FF 2>/dev/null && grep -q '<SEC_FLOATING_FEATURE_CAMERA_SUPPORT_AFSENSITIVITY>TRUE<' $FF 2>/dev/null ;;
    aelimit) grep -q '<SEC_FLOATING_FEATURE_CAMERA_SUPPORT_AUTO_EXPOSURE_LIMIT>TRUE<' $FF 2>/dev/null ;;
    slowmoaf) bound $CF && grep -q 'name="SUPPORT_SLOW_MOTION_AF_DURING_RECORDING" value="true"' $CF 2>/dev/null && grep -q '<SEC_FLOATING_FEATURE_CAMERA_SUPPORT_AF_DURING_SLOWMOTION_RECORDING>TRUE<' $FF 2>/dev/null ;;
    extstorage) bound $CF && grep -q 'BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_60FPS.*external-storage-support="true"' $CF 2>/dev/null ;;
    anamorphic) bound $CF && grep -q 'name="SUPPORT_CAMERA_ASSISTANT_ANAMORPHIC_LENS" value="true"' $CF 2>/dev/null ;;
    profps) bound $CF &&
      grep -q 'name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_25FPS" value="true"' $CF 2>/dev/null &&
      grep -q 'name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_120FPS".*slow_motion' $CF 2>/dev/null &&
      # when the Camera APK is one the patch knows and active, 24 fps needs the patched copy bound
      # too; an unknown APK (or a Galaxy Store update) leaves the XML rates on and only those two off
      { set -- $(cam24_row)
        if [ -n "$1" ] && pm path com.sec.android.app.camera 2>/dev/null | grep -q "^package:$CAM_APK$"; then
          bound $CAM_APK && grep -q 'name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_24FPS".*supported-mode="[^"]*video' $CF 2>/dev/null
        else true; fi; } ;;
    uhd60lenses) bound $CF && grep -q 'name="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_60FPS".*seamless-zoom-support="true"' $CF 2>/dev/null ;;
    autoframe) grep -q "<SEC_FLOATING_FEATURE_CAMERA_CONFIG_AUTOFRAMING>uhd<" $FF 2>/dev/null ;;
    bargein) grep -q "<SEC_FLOATING_FEATURE_BIXBY_CONFIG_BARGEIN_PARAM_MODE>2<" $FF 2>/dev/null ;;
    wearretry) wr_live ;;
    weather) grep -q "<SEC_FLOATING_FEATURE_$WX_KEY>[^<]*GENWEATHER" $FF 2>/dev/null && pm path $WX_PKG >/dev/null 2>&1 && ! wx_live_off ;;
    settingssearch) bound /system/$SSI/SecSettingsIntelligence.apk ;;
    callscreen) [ "$(lc_installed)" -ge 400000000 ] 2>/dev/null ;;
    vulkan) [ "$(getprop debug.hwui.renderer)" = skiavk ] ;;
    camerahdr) grep -q 'mfhdr.arcsoft.v4' $FF 2>/dev/null && [ -f /system/lib64/liblow_light_hdr.arcsoft.so ] ;;
    audioeraser) [ -f /system/etc/fastScanner.tflite ] ;;
    hdr2023) bound /system/lib64/libae_bracket_hdr.arcsoft.so && bound /system/lib64/libhybrid_high_dynamic_range.arcsoft.so ;;
    colortone) sm=$(md5sum $SETTINGS | cut -d' ' -f1); set -- $(ead_row); [ "$sm" = "${3:-none}" ] || [ "$sm" = "$(nh_row | cut -d' ' -f5)" ] ;;
    tenbit) bound $TB_LIB && [ "$(md5 $TB_LIB)" = "$(md5 $V/tenbit.so)" ] ;;
    galaxyai) bound /system/priv-app/SamsungSmartSuggestions/SamsungSmartSuggestions.apk ;;
    highlights) nh_on && bound $FF && grep -q '<SEC_FLOATING_FEATURE_GENAI_CONFIG_LLM_VERSION>0\.[7-9][0-9]' $FF 2>/dev/null ;;
    hideksu) hideksu_on ;;
    chargewatts) cw_on ;;
    dual5g) [ -f $D5G/applied ] ;;
    nronly) nr_ours ;;
    natroam) natroam_on ;;
    rambler) rambler_on ;;
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
  [ -e $REMOVED ] && { : > $L; fail "$REMOVED_MSG"; }
  rec_start
  picks=$(migrate_choices "$2")
  TWEAKS=" $picks "; : > $L
  [ "$picks" = "$2" ] || log "choices: cam24fps and slowmo4k120 are part of profps now; applying profps"
  log "applying:$TWEAKS"
  for x in $picks; do case " $TWEAK_IDS " in *" $x "*) ;; *) fail "unknown tweak: $x" ;; esac; done
  echo "$picks" > $V/choices
  has wifi7 && ! has airdrop && fail "wifi7 needs airdrop (the S24 Wi-Fi driver)"
  phone_facts; keep=""
  log "module $(mod_ver) on $model $build ($csc), Android $(getprop ro.build.version.release), kernel $(uname -r)"
  for x in $picks; do
    w=$(why_not $x); if [ -n "$w" ]; then log "$x: skipped: $w"; else keep="$keep $x"; fi
  done
  TWEAKS=" $keep "
  if has wifi7 && ! has airdrop; then
    keep=$(echo "$keep" | sed 's/ wifi7//g; s/^wifi7 //; s/^wifi7$//')
    TWEAKS=" $keep "
    log "wifi7: skipped: needs airdrop (the S24 Wi-Fi driver)"
  fi
  # what an apply doesn't undo (binds, kernel modules, properties) stays until a reboot: say so
  for x in $STAYS_TILL_REBOOT; do
    has $x && continue
    { is_on $x || { [ $x = colortone ] && [ -f /system/priv-app/$EAD/$EAD.apk ]; }; } &&
      log "$x: not picked, but still on from an earlier apply in this boot; a reboot turns it off"
  done
  has chargewatts && cw_ours $SYSUI && [ -z "$(cw_row)" ] && umount -l $SYSUI   # an older chargewatts copy hides the stock md5 the download is keyed by
  payload_fetch   # before the AirDrop driver swap takes Wi-Fi down
  if has airdrop; then
    wifi_off && WIFI_WAS_OFF=1   # before the driver swap turns it on; wifi7_check turns it back off
    has wifi7 && wifi7_bind   # before the driver loads, so it reads the MLO settings
    airdrop_kernel
    if has wifi7 && [ "${W7_OFF:-0}" = 0 ]; then [ "${AK_LOADED:-0}" = 1 ] && [ "${W7_INI_NEW:-0}" = 1 ] && wifi7_reload; wifi7_check; fi
  fi
  restart=0
  has airdrop && airdrop_overlays && restart=1
  payload_apply && restart=1   # camerahdr hdr2023 audioeraser colortone galaxyai: before the flag file
  has battery && { ff_tags="$ff_tags BATTERY_SUPPORT_BSOH_SETTINGS SETTINGS_ENABLE_EU_BATTERY_REGULATORY"; battery_auth; }
  has features && ff_tags="$ff_tags SETTINGS_SUPPORT_AUTO_POWER_ON_OFF AUDIO_SUPPORT_VOIP_SOUND_LOUDER"
  if has display; then  # the lock screen wallpaper on Always On Display
    # Not LCD_CONFIG_VIVIDNESS / VIVIDPLUS (the S24's Vividness slider): the S23 panel has no vividness
    # control (the slider writes to a missing /sys/class/mdnie/mdnie/vividness), and VIVIDPLUS 1 makes
    # Vivid screen mode put SurfaceFlinger in sRGB instead of the panel's wide gamut: washed-out colours.
    ff_set LCD_CONFIG_AOD_FULLSCREEN 1; ff_set LCD_CONFIG_AOD_BRIGHTNESS_ANIMATION 1
    # Keep AOD_BRIGHTNESS_ANIMATION: without it the wallpaper on AOD can't be seen on the S23. With it
    # the wallpaper starts bright and dims sharply after a few seconds, to the S23's AOD brightness: the
    # AOD app's light-sensor curve is empty on the S23 (0 nits). aodb_apply adds the S24 Ultra's curve.
    aodb_apply && restart=1
  elif [ -f $AODB ]; then log "display: not picked, but the AOD brightness curve stays until a reboot"
  fi
  if has logvideo; then
    ff_set CAMERA_CONFIG_LOG_VIDEO V1.0; ff_set GALLERY_SUPPORT_LOG_CORRECT_COLOR TRUE
    cf_add="$cf_add
$CF_LOG"
    loglut_bind
  fi
  has camextras && cf_add="$cf_add
$CF_HLOCK"
  has wideflash && cf_add="$cf_add
$CF_WIDEFLASH
$CF_WIDEFLASH_CA"
  has prowbtint && cf_add="$cf_add
$CF_PROWBTINT"
  has zoomrocker && cf_add="$cf_add
$CF_ZOOMROCKER"
  has slowmoaf && cf_add="$cf_add
$CF_SLOWMOAF"
  has anamorphic && cf_add="$cf_add
$CF_ANAMORPHIC
$CF_ANAMORPHIC_SCALER"
  has profps && cf_add="$cf_add
$CF_PROFPS"
  has profps && cf_slowmo_modes="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_120FPS BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1080_120FPS"
  has uhd60lenses && cf_seamless_modes="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_60FPS"
  has profps && cf_video_modes="BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_24FPS BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1080_24FPS BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_7680X4320_24FPS FRONT_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_24FPS FRONT_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1080_24FPS"
  camfeat_apply && restart=1
  has profps && cam24fps_bind   # XML-only when the Camera APK isn't one the patch knows; the log says what was skipped
  # 4K auto framing (untested): the S24's UHD setting for auto framing in video
  has autoframe && ff_set CAMERA_CONFIG_AUTOFRAMING uhd
  # Camera Assistant: video softening (Off / Medium / High) and the AF speed/sensitivity controls
  has videosoftening && ff_set CAMERA_SUPPORT_VIDEO_SOFTENING TRUE
  has afcontrol && { ff_set CAMERA_SUPPORT_AFSPEED TRUE; ff_set CAMERA_SUPPORT_AFSENSITIVITY TRUE; }
  has aelimit && ff_set CAMERA_SUPPORT_AUTO_EXPOSURE_LIMIT TRUE
  has slowmoaf && ff_set CAMERA_SUPPORT_AF_DURING_SLOWMOTION_RECORDING TRUE
  if has logvideo; then logviull_apply   # restarts only the camera driver
  elif bound $LV_LIB; then
    if tb_restart lv_unbind; then log "logvideo: not picked; stock VIULL back"
    else log "logvideo: not picked; took the VIULL fix off, but the camera driver didn't stay up afterwards"; fi
  fi
  has tenbit && tenbit_apply   # restarts only the camera driver
  if has camextras; then hlock_apply   # restarts only the camera driver
  elif bound $HL_LIB || bound $HA_LIB || bound $HL2_LIB || bound $HA2_LIB; then
    if tb_restart hl_unbind; then log "camextras: not picked; stock EIS back"
    else log "camextras: not picked; took the levelling copies off, but the camera driver didn't stay up afterwards"; fi
  fi
  # Bixby barge-in (untested): talk over Bixby while it answers, as on the S24
  has bargein && ff_set BIXBY_CONFIG_BARGEIN_PARAM_MODE 2
  if has highlights; then nh_apply
  elif [ -f $NH_UNDO ] || nh_on; then nh_off && log "highlights: not picked; the notification intelligence settings are back"; fi
  # Lock screen Weather effect: the editor's Weather button (weather_apply adds the AI Core stub)
  has weather && ff_set $WX_KEY "$(wx_style)"
  # Draw apps with Vulkan instead of OpenGL (Samsung's libhwui ignores ro.hwui.use_vulkan)
  has vulkan && { setprop debug.hwui.renderer skiavk; log "vulkan: apps render with Skia on Vulkan"; restart=1; }
  has hideksu && hideksu_apply && restart=1   # patched services.jar: needs a framework restart to load
  ff_apply && restart=1
  if has india; then india_apply && { setprop ctl.restart ril-daemon; log "india: mobile network restarting"; restart=1; }
  elif has callrec; then callrec_apply && restart=1; fi
  has india || india_simprompt_on   # restore the carrier-switch prompt we suppressed for india
  if has nronly; then nronly_apply && restart=1   # after india/callrec, which rebind the carrier files
  else nronly_off && restart=1; fi
  if has natroam; then natroam_apply && restart=1   # the Phone app reads the override when it starts
  elif natroam_off; then log "natroam: not picked; national roaming shows as roaming again"; restart=1; fi
  if has rambler; then rambler_apply
  elif rambler_off; then log "rambler: not picked; Gboard's flag overrides are back as they were"; fi
  if has hotspot6g; then hotspot6g_pre && restart=1   # after india, which may set the country to IN
  elif [ "$(getprop $H6_PROP)" = 1 ]; then
    RP=/data/adb/ksu/bin/resetprop
    if [ -x $RP ]; then $RP $H6_PROP 0 && log "hotspot6g: not picked; 6 GHz override off"
    else log "hotspot6g: KernelSU resetprop not found; the 6 GHz override stays until a reboot"; fi
  fi
  apk_binds
  cw_restart=0
  if has chargewatts; then cw_apply && cw_restart=1
  elif cw_ours $SYSUI; then cw_off && { log "chargewatts: not picked; stock lock screen charging line back"; cw_restart=1; }; fi
  if [ $restart = 1 ]; then
    cwd=$(cw_aod_data); [ -n "$cwd" ] && umount -l "$cwd"   # no bind over a /data/app apk while the package manager rescans
    restart_framework
    [ -n "$cwd" ] && has chargewatts && cw_bind aod "$(aod_apk)" && sysui_restart
  fi
  [ $cw_restart = 1 ] && { [ $restart = 1 ] || sysui_restart; has chargewatts && touch /dev/s23tweaks_cw; }
  if has hideksu; then hidemnt_start                                   # after the restart, so it catches the respawned apps
  elif hidemnt_running; then hidemnt_stop; log "hideksu: app mount-hiding stopped (not picked)"; fi
  has hotspot6g && hotspot6g_post
  has camextras && directorsview_pref
  if has wideflash; then wideflash_pref
  elif [ -f $WF_UNDO ]; then wideflash_unpref && log "wideflash: not picked; the camera's wide-lens flash setting is back as it was"; fi
  helpers_wake
  has callscreen && callscreen_apply
  if has weather; then weather_apply
  elif wx_stub; then pm uninstall $WX_PKG >/dev/null 2>&1 && log "weather: not picked; AI Core stub uninstalled"; fi
  if has dual5g; then dual5g_apply
  elif [ -f $D5G/applied ]; then log "dual5g: not picked; putting the original modem file back"; dual5g_restore; fi
  has airdrop && airdrop_post
  if has wearretry; then wr_set on && log "wearretry: on; Play services no longer retries the watch while it's away (untested: if the watch stops reconnecting, unpick this)"
  elif wr_live; then wr_set off && log "wearretry: not picked; Play services' own watch retry setting is back"; fi
  [ $restart = 1 ] && statusbar_wifi_refresh   # the framework restart can drop the Wi-Fi status-bar icon
  on=""; off=""; for x in $picks; do if is_on $x; then on="$on $x"; else off="$off $x"; fi; done
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
  sim=$(getprop gsm.sim.operator.numeric | cut -d, -f1)   # MCC+MNC of the first SIM; 404/405/406 = India
  printf '{"version":"%s","module":%s,"phone":{"model":"%s","firmware":"%s","csc":"%s","android":"%s","kernel":"%s","gms":%s,"sim":"%s"},' \
    "$ver" "$( [ $MODULE = 1 ] && echo true || echo false)" "$model" "$build" "$csc" "$android" "$kern" "${gms:-0}" "$sim"
  printf '"picked":"%s","autostart":%s,"applying":%s,"tweaks":[' "$(migrate_choices "$(cat $V/choices 2>/dev/null)")" \
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
recorder)
  # logcat rotates its own files (-r KB, -n count). It's restarted if it ever ends; -T 1 then starts at
  # the newest line instead of copying the whole buffer in again.
  mkdir -p $REC; chmod 700 $REC; t=""; echo "$REC_CONF" > $REC/conf; set -- $REC_CONF
  ( while true; do logcat -b main,system,events,crash -v threadtime $t -f $REC/log -r $1 -n $2 '*:I' $REC_QUIET 2>/dev/null; t="-T 1"; sleep 10; done ) &
  # dmesg -W waits for new kernel lines (no polling); only Wi-Fi/AirDrop ones are kept, trimmed to ~1 MB
  while true; do
    dmesg -W 2>/dev/null | grep --line-buffered -iE 'wonder|awdl|llw|wlan|cnss|firmware|mosey' |
      grep --line-buffered -vE 'Runtime (suspend|resume)|PCI link|MHI state' | {
        n=0; while IFS= read -r l; do
          echo "$(date '+%m-%d %H:%M:%S') $l" >> $REC/kernel; n=$((n + 1))
          if [ $n -ge 500 ]; then n=0; [ "$(wc -c < $REC/kernel)" -gt 1048576 ] && tail -c 524288 $REC/kernel > $REC/kernel.t && mv $REC/kernel.t $REC/kernel; fi
        done; }
    sleep 10
  done
  ;;
moseyheal)
  # Mosey's Wi-Fi Aware network outlives its interface: after a share (or just opening the share sheet)
  # the network stays connected when mosey0 is deleted, and netd keeps the name mosey0 assigned to it.
  # The next AirDrop session's network then can't add mosey0 ("already assigned to netId N"), has no
  # route, and every connect fails ENETUNREACH: the iPhone still lists the phone, nothing transfers.
  # Releasing Mosey's request doesn't help (Android keeps local networks connected); only ending the
  # Mosey app does. ip monitor waits on netlink link events (no polling). On a mosey0 change, look 3 s
  # later: stuck means an Aware network while mosey0 is gone, or two of them (the old one still owning
  # mosey0 next to the new one that can't get it). Then ignore events for 30 s: stopping Mosey deletes
  # mosey0 again, which must not trigger another stop. After a normal share (2026-11-28) Mosey's network went
  # away within about 1 s of mosey0, so the 3 s check doesn't stop Mosey after every share.
  while true; do
    last=0
    ip monitor link 2>/dev/null | while IFS= read -r l; do
      case "$l" in *" mosey0:"*) ;; *) continue ;; esac
      now=$(cut -d. -f1 /proc/uptime); [ $((now - last)) -lt 30 ] && continue
      sleep 3
      # count only Mosey's own Aware networks (other apps can hold one); the agent line has "Uid: <owner>"
      mu=$(stat -c %u /data/data/com.google.android.mosey 2>/dev/null) || continue
      n=$(dumpsys connectivity | grep 'NetworkAgentInfo{network{[0-9]*}.*WIFI_AWARE' | grep -c " Uid: $mu ")
      if ip link show mosey0 >/dev/null 2>&1; then [ "$n" -ge 2 ] || continue; else [ "$n" -ge 1 ] || continue; fi
      last=$(cut -d. -f1 /proc/uptime)
      log "airdrop: Mosey's AirDrop network outlived mosey0 ($n Aware networks): stopping Mosey"
      am force-stop com.google.android.mosey
    done
    sleep 10
  done
  ;;
guard)
  # If the Wi-Fi firmware ever crashes, the S24 driver's recovery leaks the AirDrop interface and
  # ~50 s later the phone hard-resets. Stop the daemon, keep the log, and reboot cleanly instead.
  # dmesg -W blocks until the kernel logs something new and prints only new lines, so this waits without
  # using CPU. (Reading the whole kernel log every second instead cost about a third of an idle phone's CPU.)
  until dmesg -W | grep -q -m1 "Received firmware hang event"; do sleep 5; done   # retry only if dmesg ends
  log "Wi-Fi firmware crashed: saving the kernel log and rebooting"
  echo "the Wi-Fi firmware crashed before the last reboot (log saved in $V)" > $V/boot.skip
  ps -A -o PID,ARGS | grep "[t]weaks.sh loop" | while read pid rest; do kill $pid; done
  pkill mosey_server; sleep 3; dmesg > $V/fwcrash_$(cut -d. -f1 /proc/uptime).txt; sync
  reboot
  ;;
status)
  [ -e $REMOVED ] && echo "note: $REMOVED_MSG"
  echo "saved choices: $(migrate_choices "$(cat $V/choices 2>/dev/null)"); $(sh $D/tweaks.sh autostart)"
  echo "airdrop:  modules [$(grep -oE '^(wonder|bwfix) ' /proc/modules | tr -d '\n')]," \
       "Mosey $(bound /system_ext/bin && echo on || echo off), daemon $(running loop && echo running || echo stopped)," \
       "Mosey service $(service check com.google.android.moseyservice.IMoseyService/default | grep -q ': found' && echo registered || echo "not registered")"
  echo "features: $(bound $FF && grep -oE '<SEC_FLOATING_FEATURE_(SETTINGS_SUPPORT_AUTO_POWER_ON_OFF|AUDIO_SUPPORT_VOIP_SOUND_LOUDER)>' $FF | sed 's/<SEC_FLOATING_FEATURE_//; s/>//' | tr '\n' ' ' || echo off)"
  echo "battery:  auth IC $(mounted /sys/class/power_supply tmpfs && echo presented || { [ -e /sys/class/power_supply/sec_auth ] && echo "real (presence $(cat /sys/class/power_supply/sec_auth/presence 2>/dev/null), auth $(cat /sys/class/power_supply/sec_auth/batt_auth 2>/dev/null))" || echo off; }),"\
       "flags [$(grep -oE '<SEC_FLOATING_FEATURE_(BATTERY_SUPPORT_BSOH_SETTINGS|SETTINGS_ENABLE_EU_BATTERY_REGULATORY)>[A-Z]*' $FF | sed 's/<SEC_FLOATING_FEATURE_//; s/>/=/' | tr '\n' ' ')]"
  echo "display:  $(bound $FF && grep -q '<SEC_FLOATING_FEATURE_LCD_CONFIG_AOD_FULLSCREEN>1<' $FF && echo on || echo off), AOD brightness curve $(aodb_on && echo on || { [ -f $AODB ] && echo "added, waiting for a framework restart" || echo off; })"
  echo "logvideo: $(is_on logvideo && echo on || echo off), Gallery LUTs $(bound $LV && echo on || echo off), low-light Log fix $(bound $LV_LIB && echo on || echo off)"
  echo "camextras: horizon lock $(is_on camextras && echo on || echo off), levelling $(bound $HL_LIB && echo "on ($(hl_desc))" || echo off), Director's view $(grep -q '<string name="directors_view_mode">1</string>' $CAM_PREFS 2>/dev/null && echo shown || echo hidden)"
  echo "autoframe: $(grep -o '<SEC_FLOATING_FEATURE_CAMERA_CONFIG_AUTOFRAMING>[^<]*' $FF | cut -d'>' -f2 | grep . || echo stock)"
  echo "bargein:  $(grep -q '<SEC_FLOATING_FEATURE_BIXBY_CONFIG_BARGEIN_PARAM_MODE>2<' $FF && echo on || echo off)"
  echo "wearretry: $(wr_live && echo "on (OFF retry strategy honoured)" || echo off)"
  echo "weather:  flag $(grep -q "<SEC_FLOATING_FEATURE_$WX_KEY>[^<]*GENWEATHER" $FF && echo on || echo off), AI Core $(wx_stub && echo "stub $(wx_code)" || { wx_real && echo "Samsung $(dumpsys package $WX_PKG 2>/dev/null | grep -m1 -oE 'versionName=[^ ]+' | cut -d= -f2) at $(pm path $WX_PKG 2>/dev/null | head -1 | cut -d: -f2)" || echo none; }), live wallpaper app $(wx_live_off && echo disabled || echo enabled)"
  echo "settingssearch: $(bound /system/$SSI/SecSettingsIntelligence.apk && echo S24 || echo stock)"
  echo "callscreen: Language Core $(dumpsys package $LC_PKG 2>/dev/null | grep -m1 -oE 'versionName=[^ ]+' | cut -d= -f2)"
  h=$(TWEAKS=" $(migrate_choices "$(cat $V/choices 2>/dev/null)") "; helpers_off | awk '{gsub(/_/, " ", $2); printf "%s%s", (NR > 1 ? ", " : ""), $2}')
  [ -n "$h" ] && echo "helpers:  disabled: $h (Samsung's Deep sleeping apps; apply turns them back on, then take them off Settings > Battery > Background usage limits > Deep sleeping apps)"
  echo "camerahdr: libraries $([ -f /system/lib64/liblow_light_hdr.arcsoft.so ] && echo on || echo off), list entries $(grep -q 'mfhdr.arcsoft.v4' $FF && echo on || echo off)"
  echo "hdr2023:  $(same_size /system/lib64/libae_bracket_hdr.arcsoft.so $PL/hdr2023/libae_bracket_hdr.arcsoft.so && same_size /system/lib64/libhybrid_high_dynamic_range.arcsoft.so $PL/hdr2023/libhybrid_high_dynamic_range.arcsoft.so && echo "2023 engines" || echo stock)"
  echo "tenbit:   front-camera 10-bit $(is_on tenbit && echo on || echo off)"
  echo "wideflash: $(is_on wideflash && echo on || echo off)"
  echo "prowbtint: $(is_on prowbtint && echo on || echo off)"
  echo "zoomrocker: $(is_on zoomrocker && echo on || echo off)"
  echo "videosoftening: $(is_on videosoftening && echo on || echo off)"
  echo "afcontrol: $(is_on afcontrol && echo on || echo off)"
  echo "aelimit: $(is_on aelimit && echo on || echo off)"
  echo "slowmoaf: $(is_on slowmoaf && echo on || echo off)"
  echo "extstorage: $(is_on extstorage && echo on || echo off)"
  echo "anamorphic: $(is_on anamorphic && echo on || echo off)"
  echo "profps: $(is_on profps && echo on || echo off), Camera $(bound $CAM_APK && echo patched || echo stock), 10x $(cam24_profps_on && echo "unhidden at 25/48/50 fps" || echo hidden)"
  echo "uhd60lenses: $(is_on uhd60lenses && echo "on (0.6x/1x/3x/10x at UHD 60)" || echo off)"
  echo "audioeraser: $([ -f /system/etc/fastScanner.tflite ] && echo on || echo off), engine $(same_size /system/lib64/$VE $PL/audioeraser/$VE && echo S24 || echo stock)"
  echo "colortone: Settings $(bound $SETTINGS && echo patched || echo stock), service $([ -f /system/priv-app/$EAD/$EAD.apk ] && echo on || echo off)"
  echo "galaxyai: $(for p in $GAI_APPS; do n=${p#*/}; printf '%s=%s ' $n "$(same_size /system/$p/$n.apk $PL/galaxyai/$n.apk && echo S24 || echo stock)"; done)C2PA=$(same_size $C2PA $D/files/libC2paDps-shim.so && echo shim || echo stock)"
  echo "chargewatts: $(if cw_on; then echo "lock screen on, AOD $(cw_aod_on && echo on || { [ -n "$(cw_rowof aod "$(aod_apk)")" ] && echo "off (apply again)" || echo "off (this Always On Display version isn't one the patch was made for)"; })"; elif [ -n "$(cw_row)" ]; then echo off; else echo "not available for this SystemUI"; fi)"
  echo "vulkan:   renderer $(getprop debug.hwui.renderer | grep . || echo default)"
  echo "hideksu:  $(hideksu_on && echo "on (KernelSU manager hidden from apps)" || { bound $KSUJAR && echo "bound, waiting for a framework restart" || echo off; }); mounts $(hidemnt_running && { n=$(hidemnt_count); [ "$n" -gt 0 ] 2>/dev/null && echo "hidden from user-installed apps ($n override(s))" || echo "hidden from user-installed apps"; } || { grep -qw hideksu $V/choices 2>/dev/null && echo "visible to apps (the hiding daemon isn't running; apply again to restart it)" || echo "visible to apps"; })"
  echo "wifi7:    wpa_supplicant $(bound $WPAS && echo S24 || echo stock), driver MLO settings $(bound $INI && echo on || echo off)"
  echo "6ghz ap:  $(h6_offered && echo offered || echo "not offered") (CSC country $(getprop ro.csc.countryiso_code), override $(getprop $H6_PROP | grep . || echo unset))"
  echo "csc:      $SC $(bound $CSCF && { grep -q '<SalesCode>INS<' $CSCF && echo "with the INS config" || echo "with call recording"; } || echo stock) ($CSYS)"
  echo "reported: model $(getprop ro.product.model), csc $(getprop ro.csc.sales_code), country $(getprop ro.csc.countryiso_code)$([ -e $V/india_identity ] && [ "$(getprop ro.product.model)" = $IN_MODEL ] && echo " (india identity on)")"
  echo "nronly:   $(nr_ours && echo "on (Network mode offers LTE only and 5G only)" || echo off)"
  echo "natroam:  $([ -s $NROAM ] && echo "on ($(grep -c . $NROAM) SIM override(s))" || echo off)"
  echo "highlights: $(is_on highlights && echo "on (notification priority and summaries)" || echo off)"
  echo "rambler:  $(rambler_on && echo "on (Gboard flag overrides)" || echo off)"
  echo "dual5g:   $([ -f $D5G/applied ] && echo "on (modem msim_plmns:$(cat $D5G/applied))" || echo off)$([ -f $D5G/stock/global_defines.xml ] && echo "; original backed up in $D5G/stock")"
  ;;
cleanup)
  # Undo everything that outlives a reboot, then delete the state folder. module/uninstall.sh runs this
  # from a copy in /dev when the module is removed. It waits for Android and the first unlock, since
  # the Play services database and the Camera settings sit in app storage that's locked until then.
  n=0; until [ "$(getprop sys.boot_completed)" = 1 ] && [ "$(getprop sys.user.0.ce_available)" = true ] &&
    pm path android >/dev/null 2>&1; do n=$((n+1)); [ $n -gt 4320 ] && exit 1; sleep 5; done
  say() { /system/bin/log -t s23tweaks "cleanup: $*" 2>/dev/null; echo "$*"; }   # Android's log: log() here is ours
  [ -s $HIST ] && : > $REMOVED   # an apply ran in this boot: its binds outlive the files deleted below
  [ -x $AIR/sqlite3 ] && sh "$0" unflag >/dev/null 2>&1 && say "Play services flag overrides removed"
  if [ -f $V/undo/languagecore ] && pm path $LC_PKG >/dev/null 2>&1; then
    pm uninstall $LC_PKG >/dev/null 2>&1 && say "Language Core uninstalled"
    for k in call_screening call_screening_auto_screening_onoff call_screening_voice call_screening_voice_speech_rate; do
      settings delete system $k >/dev/null 2>&1; done
  fi
  wx_stub && pm uninstall $WX_PKG >/dev/null 2>&1 && say "AI Core stub uninstalled"
  if [ -f $V/undo/directors_view ] && [ -f $CAM_PREFS ]; then
    v=$(cat $V/undo/directors_view); am force-stop com.sec.android.app.camera; mkdir -p $R
    if [ "$v" = absent ]; then grep -v 'name="directors_view_mode"' $CAM_PREFS > $R/camprefs.new
    else sed "s|<string name=\"directors_view_mode\">[^<]*</string>|<string name=\"directors_view_mode\">$v</string>|" $CAM_PREFS > $R/camprefs.new; fi
    grep -q '</map>' $R/camprefs.new && cat $R/camprefs.new > $CAM_PREFS && say "Camera setting restored"
  fi
  wideflash_unpref && say "Camera's wide-lens flash setting restored"
  # parsed manifests of the apps the tweaks swap, in case a restart cached one; Android re-parses them
  for n in SamsungSmartSuggestions SketchBook CallAssistant SecSettingsIntelligence SecSettings EnvironmentAdaptiveDisplay MoseyApp SamsungCamera; do
    rm -f /data/system/package_cache/*/$n-[0-9]*; done
  if [ -e $V/india_simprompt ]; then
    pm enable $CIDMGR >/dev/null 2>&1; appops set $CIDMGR SYSTEM_ALERT_WINDOW allow >/dev/null 2>&1
    say "carrier-switch prompt (CID Manager) restored"
  fi
  if [ -f $D5G/applied ] || [ -f $D5G/stock/global_defines.xml ]; then
    mkdir -p $R; : > $L
    if dual5g_restore; then say "dual5g: original modem file restored"
    else say "dual5g: COULD NOT restore the modem file; the original stays in $D5G_SD"; cp -r $D5G $D5G_SD/state 2>/dev/null; fi
  fi
  nh_off && say "highlights: notification intelligence settings back to stock"
  rambler_off && say "rambler: Gboard's flag overrides restored"
  natroam_off && say "natroam: carrier config overrides removed (national roaming shows again after the next reboot)"
  rm -f /dev/s23tweaks_efstool
  rm -f /data/adb/service.d/s23tweaks.sh
  cd /; rm -rf $V
  say "done; the next reboot removes what's still mounted"
  case "$0" in /dev/*) rm -f "$0" ;; esac
  exit 0
  ;;
airdrop-test)
  # Record one AirDrop attempt: logcat from now on (the buffers alone cover only minutes on a busy phone)
  # and the kernel log, for $2 seconds while the user shares. Then say which stage it reached: Quick Share
  # used, Mosey started and logging, the Wi-Fi driver's AirDrop link active. The filtered log goes to
  # Download with personal data masked; the verdict also goes in the next report.
  [ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }
  to_root_cgroup   # the user leaves the module page to share: don't get frozen with the manager app
  secs=${2:-90}; case $secs in ''|*[!0-9]*) secs=90 ;; esac; [ $secs -gt 600 ] && secs=600
  mkdir -p $R /sdcard/Download; sn=$(getprop ro.serialno)
  out=/sdcard/Download/s23-ultra-tweaks-airdrop-$(date +%Y%m%d-%H%M%S).txt; raw=$R/airdrop-test.log; kr=$R/airdrop-test.kmsg
  snap() {
    echo "  Mosey app $(pidof com.google.android.mosey >/dev/null && echo running || echo "not running"), mosey_server $(pidof mosey_server >/dev/null && echo running || echo "not running")," \
      "Mosey service $(service check com.google.android.moseyservice.IMoseyService/default | grep -q ': found' && echo registered || echo "not registered")"
    echo "  Wi-Fi: $(cmd wifi status 2>/dev/null | grep -m1 -oE 'Wifi is (enabled|disabled)'), $(cmd wifi status 2>/dev/null | grep -m1 -oE 'Supplicant state: [A-Z_]+')," \
      "hotspot $(cmd wifi status 2>/dev/null | grep -qiE 'SoftApManager|ROLE_SOFTAP' && echo on || echo off)," \
      "Bluetooth $([ "$(settings get global bluetooth_on)" = 1 ] && echo on || echo off)," \
      "AirDrop modules [$(grep -oE '^(wonder|bwfix) ' /proc/modules | tr -d '\n')]"
    echo "  Nearby flags: $(nearby_live)"
    echo "  Broadcast guard: $(bcast_live)"
    echo "  network interfaces: $(ip -o link 2>/dev/null | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }' | grep -vE '^(lo|dummy|ifb|tunl|gre|erspan|ip_vti|ip6|sit|rmnet|epdg)' | tr '\n' ' ')"
  }
  # the kernel log's last record number now: lines after it are the test's (its clock stops in deep sleep,
  # so a time cut-off against /proc/uptime would drop them)
  k0=$(timeout 1 cat /dev/kmsg 2>/dev/null | tail -n 1 | cut -d, -f2); k0=${k0:-0}
  before=$(snap); ap0=$(pidof com.google.android.mosey)
  logcat -b main,system,events,crash -v threadtime -T "$(date '+%m-%d %H:%M:%S').000" > $raw 2>/dev/null & lp=$!
  echo "recording for $secs s: share a photo with Quick Share > Share with Apple devices now"
  sleep $secs; kill $lp 2>/dev/null; wait $lp 2>/dev/null
  after=$(snap)
  # the test's kernel lines (/dev/kmsg works where dmesg can't; each record is "level,number,microseconds,-;text")
  timeout 1 cat /dev/kmsg 2>/dev/null | awk -v k0=$k0 '{ split($0, a, ","); if (a[2] + 0 > k0 + 0) { t = a[3] / 1000000; sub(/^[^;]*;/, ""); printf "[%10.3f] %s\n", t, $0 } }' > $kr
  ad_verdict $raw $kr "$ap0" "start the test, then share within $secs s"
  { echo "$(date '+%Y-%m-%d %H:%M'), $secs s: $v"
    echo "  Quick Share screens opened $nui, Quick Share lines $nsl, Mosey app lines $napp, mosey_server lines $nsrv (its idle restarts not counted), Mosey app starts $nst, Play services loading Mosey $nreg, incoming AirDrop shares $nin, Nearby restarts $nrs, AirDrop link kernel lines $nk"
    echo "  before:"; echo "$before" | sed 's/^/  /'; echo "  after:"; echo "$after" | sed 's/^/  /'
    echo "  log: $out"; } | scrub > $AD_SUM
  { echo "s23-ultra-tweaks AirDrop test, $(date '+%Y-%m-%d %H:%M:%S %z'), module $(mod_ver), $(getprop ro.product.model) $(getprop ro.build.PDA)"
    echo; cat $AD_SUM
    echo; echo "===== Mosey, Quick Share and Nearby lines (all levels, names in quotes masked) ====="
    rel $raw | sed -E "s/\"[^\"]*\"/<name>/g; s/'[^']*'/<name>/g" | tail -n 4000 | cut -c1-400
    echo; echo "===== crashes during the test (with stack traces) ====="
    # the tag field keeps its colon when the tag fills 8 characters or more ("AndroidRuntime:"); only errors, so
    # libc's property warnings don't push the crash out
    awk '($6 ~ /^(AndroidRuntime|DEBUG|libc):?$/ && $5 ~ /^[EF]$/) || / am_crash/ || (/ am_proc_died/ && /gms|mosey|sharelive/)' $raw | tail -n 400 | cut -c1-300
    echo; echo "===== kernel log during the test ====="
    grep -vE 'Runtime (suspend|resume)|PCI link|MHI state' $kr | tail -n 1500 | cut -c1-300
  } 2>&1 | scrub > $out
  rm -f $raw $kr
  cat $AD_SUM
  echo "$out"
  ;;
report)
  # One text file for bug reports: phone and firmware, what each tweak found, the stock values and files
  # it depends on, the last logs and recent crash summaries. Leaves out the serial number, email
  # addresses, MAC addresses and long numbers (IMEI). Saved in Download; the last line is its path.
  phone_facts; mkdir -p /sdcard/Download
  out=/sdcard/Download/s23-ultra-tweaks-report-$(date +%Y%m%d-%H%M%S).txt
  ver() { dumpsys package $1 2>/dev/null | grep -m1 -oE 'versionName=[^ ]+' | cut -d= -f2; }
  sec() { printf '\n===== %s =====\n' "$1"; }
  sn=$(getprop ro.serialno)
  {
    echo "s23-ultra-tweaks report, $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "module $(mod_ver)"
    sec phone
    echo "model $model, firmware $build, CSC $csc, Android $(getprop ro.build.version.release) (One UI $(o=$(getprop ro.build.version.oneui); echo $((o / 10000)).$((o / 100 % 100)))), patch $(getprop ro.build.version.security_patch)"
    echo "kernel $(uname -r)"
    echo "root: $(/data/adb/ksud -V 2>/dev/null || echo "no KernelSU ksud"), SELinux $(getenforce)"
    echo "apps: Play services $(ver com.google.android.gms) ($gms), Camera $(ver com.sec.android.app.camera), Settings $(ver com.android.settings), Quick Share $(ver com.samsung.android.app.sharelive)"
    echo "SIM operator $(getprop gsm.sim.operator.numeric | cut -d, -f1), free on /data $(df -h /data | awk 'NR == 2 {print $4}')"
    sec "tweaks (available, why not, active)"
    sh $D/tweaks.sh probe | tr '{' '\n' | grep '"id"'
    sec status
    sh $D/tweaks.sh status
    sec "what the tweaks depend on"
    echo "airdrop/wifi7 kernel match: $(kernel_stock && echo yes || { kernel_override && echo "no, allowed by allow-any-kernel" || echo "no (supported: $AIRDROP_FW)"; })"
    echo "camera-feature.xml ($(bound $CF && echo "module's copy" || echo stock)):"
    grep -E 'LOG_VIDEO|PREVIEW_LUT|HORIZONTAL_LOCK|AUTO_FRAMING|MULTI_RECORDING' $CF | sed 's/^ */  /'
    echo "floating_feature.xml ($(bound $FF && echo "module's copy" || echo stock)):"
    grep -oE '<SEC_FLOATING_FEATURE_(CAMERA_CONFIG_(LOG_VIDEO|AUTOFRAMING|VENDOR_LIB_INFO)|GALLERY_SUPPORT_LOG_CORRECT_COLOR|LCD_CONFIG_(VIVIDNESS|VIVIDPLUS|AOD_FULLSCREEN)|BIXBY_CONFIG_BARGEIN_PARAM_MODE|BATTERY_SUPPORT_BSOH_SETTINGS|SETTINGS_SUPPORT_AUTO_POWER_ON_OFF)>[^<]*' $FF |
      sed 's/<SEC_FLOATING_FEATURE_/  /; s/>/=/' | cut -c1-200
    echo "camera driver: $(md5 $TB_LIB) $(bound $TB_LIB && echo "(module's copy, made from $(cat $V/tenbit.src 2>/dev/null))")"
    echo "mounts from the module:"
    awk '$4 ~ /s23tweaks/ || $10 ~ /s23tweaks/ {print "  " $5 " <- " $4 " (" $9 ")"}' /proc/self/mountinfo | sort -u | head -80
    sec display
    echo "screen mode $(settings get system screen_mode_setting) (4 = Vivid, 1 = Natural), vividness $(settings get system vividness_intensity), Adaptive color tone $(settings get system ead_enabled)"
    echo "SurfaceFlinger: $(dumpsys SurfaceFlinger 2>/dev/null | grep -m1 'Current color mode' | sed 's/^ *//'), persist.sys.sf.native_mode $(getprop persist.sys.sf.native_mode)"
    echo "panel white point (sensorRGB) $(cat /sys/class/mdnie/mdnie/sensorRGB 2>/dev/null), night mode $(cat /sys/class/mdnie/mdnie/night_mode 2>/dev/null)"
    sec "AirDrop and Wi-Fi"
    echo "Wi-Fi: $(cmd wifi status 2>/dev/null | grep -m1 -oE 'Wifi is (enabled|disabled)'), $(cmd wifi status 2>/dev/null | grep -m1 -oE 'Wi-Fi standard: [^,]*'), driver $(cat /sys/module/wlan/version 2>/dev/null || grep -m1 -oE '^kiwi_v2 [0-9]+' /proc/modules)"
    echo "last app to switch Wi-Fi on or off (Android keeps only the last one, without a time): $(dumpsys wifi 2>/dev/null | grep -m1 'API name=WifiEnabled:' | sed -E 's/.*packageName=([^ ]*) toggleState=(true|false).*/\1 \2/; s/ true$/ (on)/; s/ false$/ (off)/')"
    echo "kernel log (Wi-Fi driver, AirDrop modules, PCIe), last 25:"
    klog | grep -iE 'wonder|bwfix|mhifix|s23tweaks|kiwi_v2.*(error|fail|assert|crash)|cnss.*(fail|error|crash|assert|ssr|recover)|wlan.*firmware' |
      grep -vE 'Runtime (suspend|resume)|PCI link|MHI state' | tail -n 25 | sed 's/^/  /' | cut -c1-200
    echo "Mosey app: $(pidof com.google.android.mosey >/dev/null && echo running || echo "not running (it starts when Quick Share hands it a share)"); the logs below cover the last $(log_span), so an older start or share isn't in them"
    echo "Nearby flags: $(nearby_live)"
    echo "Broadcast guard: $(bcast_live)"
    if [ -f $AD_SUM ]; then echo "last AirDrop test (tweaks.sh airdrop-test):"; sed 's/^/  /' $AD_SUM
    else echo "no AirDrop test recorded yet: Status > Record an AirDrop test, then try a share while it records"; fi
    echo "Mosey / Quick Share warnings and errors, last 30 (names in quotes masked):"
    logcat -d -v brief 2>/dev/null | grep -E '^[EW]/[^(]*(Mosey|mosey|AirDrop|Awdl|NearbySharing|ShareLive|Wonder)' | grep -v '	at ' |
      sed -E "s/\"[^\"]*\"/<name>/g; s/'[^']*'/<name>/g" | tail -n 30 | sed 's/^/  /' | cut -c1-220
    sec "Galaxy AI secure storage"
    # Samsung's Pass Storage (Now Brief's Personal Data Intelligence, aasaservice) is refused with "Root
    # detected" when system_server sees su at one of StorageManagerService.isRootedDevice's paths. Listed
    # by reading the folders, since KernelSU's su compatibility answers file checks from root itself.
    s=$(nsenter -t $(pidof system_server) -m -- sh -c 'for f in /sbin/su /system/su /system/bin/su /system/xbin/su \
      /system/bin/.ext/.su /data/local/xbin/su /data/local/bin/su /system/sd/xbin/su /system/bin/failsafe/su /data/local/su \
      /system/app/Superuser.apk /system/usr/we-need-root/su-backup /system/xbin/mu; do
      ls -a "${f%/*}" 2>/dev/null | grep -qxF "${f##*/}" && echo "$f"; done' 2>/dev/null | tr '\n' ' ')
    echo "su files the system sees: ${s:-none}"
    echo "Pass Storage log, last 15:"
    logcat -d 2>/dev/null | grep -E 'StorageManagerService: (isDetectedRoot|rooting:)|VoldNativeService: (create|get|unlock)PassStorage|SecureStorage(Adapter|Impl)' |
      tail -n 15 | sed 's/^/  /' | cut -c1-200
    sec "every apply since this boot (seconds since boot)"
    tail -n 150 $HIST 2>/dev/null | cut -c1-220
    sec "tweaks.log (last apply)"
    cat $L 2>/dev/null
    sec "boot.log (last 60 lines)"
    tail -n 60 $V/boot.log 2>/dev/null
    sec "native crashes in the last 2 days (count, newest, process, signal, abort message)"
    for t in $(find /data/tombstones -name 'tombstone_[0-9]*' ! -name '*.pb' -mtime -2 2>/dev/null); do
      printf '%s|%s | %s | %s\n' "$(grep -m1 '^Timestamp' $t | cut -c12-30)" "$(grep -m1 '^Cmdline' $t | cut -c10- | cut -d' ' -f1)" \
        "$(grep -m1 '^signal' $t | cut -d, -f1)" "$(grep -m1 '^Abort message' $t | cut -c16-200)"
    done | sort -r | awk -F'|' '{ k = substr($0, index($0, "|") + 1); n[k]++; if (!(k in t)) { t[k] = $1; o[++m] = k } }
      END { for (i = 1; i <= m; i++) printf "%dx  %s |%s\n", n[o[i]], t[o[i]], o[i] }'
    sec "app crashes (count, newest, app, error)"
    logcat -d -b crash 2>/dev/null | awk '
      / Process: / { p = $0; sub(/.* Process: /, "", p); sub(/,.*/, "", p); t = $1 " " $2; want = 1; next }
      want && /AndroidRuntime: [A-Za-z0-9_.$]+(Exception|Error)/ { e = $0; sub(/.*AndroidRuntime: /, "", e); k = p " | " substr(e, 1, 160)
        n[k]++; last[k] = t; if (!(k in seen)) { seen[k] = 1; o[++m] = k }; want = 0 }
      END { for (i = m; i >= 1; i--) printf "%dx  %s | %s\n", n[o[i]], last[o[i]], o[i] }' | head -n 20
    sec "the last 3 app crashes with their stack traces (first 40 lines each)"
    logcat -d -b crash -v threadtime 2>/dev/null | awk '
      / AndroidRuntime: FATAL EXCEPTION/ { b++; pid[b] = $3; n[b] = 0 }
      b && $3 == pid[b] && $6 ~ /^AndroidRuntime/ { if (n[b]++ < 40) t[b] = t[b] $0 "\n" }
      END { for (i = (b > 3 ? b - 2 : 1); i <= b; i++) printf "%s\n", t[i] }' | cut -c1-300
    sec "recorded log (the module's recorder keeps the last hour or more; names in quotes masked)"
    if [ -z "$(rec_files)" ]; then
      echo "nothing recorded yet: the recorder starts at boot and at every apply (started now; the next report will have it)"
    else
      mkdir -p $R; cat $(rec_files) > $R/rec.log; touch $REC/kernel
      echo "covers $(awk 'NF > 5 { print $1, substr($2, 1, 8); exit }' $R/rec.log) to $(tail -n 1 $R/rec.log | cut -c1-14), recorder $(running recorder && echo running || echo "not running (started now)")"
      ad_verdict $R/rec.log $REC/kernel "" "no share was tried in this time"
      echo "AirDrop in this time: $v"
      echo "  Quick Share screens opened $nui, Quick Share lines $nsl, Mosey app lines $napp, mosey_server lines $nsrv, Mosey app starts $nst, Play services loading Mosey $nreg, incoming AirDrop shares $nin, Nearby restarts $nrs, AirDrop link kernel lines $nk"
      echo; echo "--- AirDrop, Quick Share and Nearby lines; Wi-Fi and Wallet warnings and errors; crashes; this module (last 3000) ---"
      awk -v p="$apids" '($3 ~ /^[0-9]+$/ && index(p, " " $3 " ")) || /[Mm]osey|[Aa]irdrop|AirDrop|[Aa]wdl|AWDL|NearbySharing|ShareLive|QuickShare|MCFQS|Wonder|setWifiEnabled|same band/ ||
        ($5 ~ /^[EWF]$/ && /[Ww]ifi|wpa_supplicant|[Ww]allet|SPAY|[Ss]pay/) || / (AndroidRuntime|DEBUG) *:|am_crash|am_anr|s23tweaks/ ||
        (/ am_proc_died/ && /gms|mosey|sharelive/)' $R/rec.log |
        awk '!/	at / || $6 ~ /^AndroidRuntime/' | sed -E "s/\"[^\"]*\"/<name>/g; s/'[^']*'/<name>/g" | tail -n 3000 | cut -c1-300
      echo; echo "--- kernel: Wi-Fi and AirDrop lines (last 400) ---"
      tail -n 400 $REC/kernel | cut -c1-300
      rm -f $R/rec.log
    fi
  } 2>&1 | scrub > $out
  rec_start
  echo "$out"
  ;;
dual5g-restore)
  # put the modem's original /policyman/global_defines.xml back (also what un-picking dual5g does)
  [ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }
  mkdir -p $R; L=$R/dual5g-restore.log; : > $L
  dual5g_restore; rc=$?
  cat $L; cat $L >> $V/tweaks.log; exit $rc
  ;;
unflag)
  G=/data/data/com.google.android.gms; DB=$G/databases/phenotype.db; SQ=$AIR/sqlite3; W=$R/gms
  [ -x $SQ ] || { echo "the AirDrop download (with its sqlite3) isn't on the phone; pick AirDrop once to fetch it" >&2; exit 1; }
  [ -f $DB ] || { echo "Play services database not available; flags not changed" >&2; exit 1; }
  rm -rf $W; mkdir -p $W; am force-stop com.google.android.gms
  cp $DB $W/p.db; [ -f $DB-wal ] && cp $DB-wal $W/p.db-wal
  in_list=""
  for f in $NEARBY_FLAGS; do in_list="${in_list:+$in_list, }'$f'"; done
  $SQ $W/p.db "DELETE FROM experiment_states_to_overrides WHERE override_id IN (SELECT override_id FROM flag_overrides WHERE name IN ($in_list) AND account_id=0);
    DELETE FROM flag_overrides WHERE name IN ($in_list) AND account_id=0;
    DELETE FROM experiment_states_to_overrides WHERE override_id IN (SELECT override_id FROM flag_overrides WHERE name='$BCAST_FLAG' AND account_id=0);
    DELETE FROM flag_overrides WHERE name='$BCAST_FLAG' AND account_id=0;
    DELETE FROM experiment_states_to_overrides WHERE override_id IN (SELECT override_id FROM flag_overrides WHERE name='$WR_FLAG' AND account_id=0);
    DELETE FROM flag_overrides WHERE name='$WR_FLAG' AND account_id=0; PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
  am force-stop com.google.android.gms; cat $W/p.db > $DB && rm -f $DB-wal $DB-shm; rm -rf $W
  wr_live && cp $WR_SNAP $R/wr.pb && pb_drop_flag $R/wr.pb $WR_FLAG && cat $R/wr.pb > $WR_SNAP; rm -f $R/wr.pb
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
  rec_start
  [ -f $V/autostart ] || exit 0
  t=$(migrate_choices "$(cat $V/choices 2>/dev/null)"); [ -n "$t" ] || exit 0
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
*) echo "usage: tweaks.sh start|apply \"<tweaks>\" | probe | status | unflag | dual5g-restore | autostart on|off | wifi7page"; exit 2 ;;
esac
