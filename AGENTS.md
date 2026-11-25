# Porting s23-ultra-tweaks to another firmware (guide for coding agents)

This file is for an AI coding agent (or a person) rebuilding these tweaks for a Galaxy S23 Ultra whose firmware isn't the one supported here. Read `README.md` first for what each tweak does.

The release is built and tested for exactly one setup:

| | Reference |
|---|---|
| Phone | SM-S918W (S23 Ultra, Canada), CSC XAC |
| Firmware | `S918WVLU8GZIF`, One UI 9 / Android 17 |
| Kernel | `5.15.197-android13-8-34343818-abS918WVLU8GZIF` |
| Root | DFRoot + KernelSU LKM (`samsung-v2.2`) |
| S24 source of the Wi-Fi/AirDrop files | SM-S928B firmware `S928BXXU6EZJB` (S24 Ultra, Android 17) |
| S24 kernel source | `SM-S928B_17_Opensource.zip` (opensource.samsung.com) |
| Play services | 26.45 |

## Rules (follow these on the user's phone)

1. **Show the user every script before running it on the phone**, and wait for their go-ahead. Explain what it changes and how to undo it.
2. **Never write to a partition.** Use module loads, tmpfs/overlayfs RAM overlays, bind mounts and runtime settings only. A reboot must always restore stock.
3. **Never touch the sales code**: `mps_code.dat`, `sales_code.dat`, `omc.info`, `persist.sys.matched_code`, `ro.boot.sales_code`. Changing it can factory-reset the phone.
4. **Never `setprop ctl.restart servicemanager`.** The phone reboots with `checkpoint_commit_failed`. Restarting zygote is fine. To make servicemanager reload VINTF manifests, `touch /apex/apex-info-list.xml`.
5. **Don't drive the phone's UI** (`input`, `monkey`) while the user is holding it. Ask them to tap things.
6. **Run long phone jobs detached** in init's mount namespace, logging to a file, so a framework restart or Wi-Fi drop doesn't kill them:
   `su -c "nsenter -t 1 -m -- setsid sh script.sh </dev/null >/dev/null 2>&1 &"`
7. **Check before you claim.** Before saying something works, test it end to end on the phone. A loaded module or a set flag doesn't prove the feature works.
8. **Keep memory use bounded** on the computer. Decompile single classes (`jadx --single-class <cls>`, `JAVA_OPTS=-Xmx3g`), not whole multi-hundred-MB APKs.

## What depends on the firmware

| Piece | Firmware-specific? | What to redo |
|---|---|---|
| `battery`, `features` | No (One UI 9 floating features) | Check that the tags still exist in `/system/etc/floating_feature.xml` |
| `hotspot6g` | Mostly no | Re-check `SemWifiApServiceImpl.supportWifiAp6GBasedOnCountry()` in `/system/framework/semwifi-service.jar` still honours `vendor.wifiap.6gbandcountry` under `SemWifiManager.MHSDBG`, and that `SemWifiApCust.DBG` (framework.jar) still comes from `ro.product_ship` |
| `callrec`, `india` | `callrec`: no (decodes the phone's own file). `india`: One UI 9 | `india`: new INS files from a matching firmware (see "Carrier config") |
| `hideksu` | **Yes**: the exact stock `services.jar` (keyed on its MD5) | `tools/hideksupatch.sh services.jar out/`, upload the tarball to the payloads release, add its row to `HIDEKSU_JARS` and its `hideksu:<md5>` line to `PAYLOADS` in `device/tweaks.sh`, and both MD5s to `HKS_MD5` in `install.sh` |
| `colortone` | **Yes**: the build's `SecSettings.apk` | `python3 -I tools/eadpatch.py SecSettings.apk <build>`, put the patch in `device/files/`, add the two MD5s to `SETTINGS_EAD` in `device/tweaks.sh` and the build to `can_ct` in `install.sh` |
| `cam24fps`, `profps` (10x) | **Yes**: the exact `SamsungCamera.apk` (keyed on its MD5, not the firmware) | `python3 -I tools/cam24patch.py SamsungCamera.apk <build>` (it also patches `Led/g;.i` to unhide the 10x super tele for `profps`). If its patch lines equal an existing file's, reuse that file. Add a row (stock MD5, patched MD5, patch file, firmware) to `CAMERA_24FPS` in `device/tweaks.sh` and both MD5s to `CAM24_MD5` in `install.sh` |
| `airdrop`, `wifi7` kernel modules | **Yes**: kernel build (all models of one build share them) | Same build, other model: check and add to `AIRDROP_FW` (see "Another model on the same build"). New build: rebuild all four `.ko`s (see "Kernel modules") |
| `airdrop` payload (firmware, Mosey, supplicant) | Android version + S24 release | Re-extract from a matching S24 firmware (see "Payload") |
| Play services flags `45704091`, `45723015`, `sharing_package_whitelist_check_bypass` | Play services version | Re-check if AirDrop doesn't show up (see "Play services") |
| `AIRDROP_KBASE`, `AIRDROP_FW`, `PAYLOAD*` | Yes | Update in `install.sh` and `device/tweaks.sh` |

Every firmware or hardware condition a tweak needs is checked in one place: `why_not` in `device/tweaks.sh` prints the reason a tweak can't run (empty if it can), and `is_on` says whether it's in effect. The module page shows `why_not` as "Not available: ...", apply logs `<tweak>: skipped: ...` and leaves it out, and the log ends with `on:` / `not on:`. When a tweak gains a requirement, add it to `why_not` so it never gets offered and then silently skips.

Collect this from the phone first:

```sh
adb shell 'getprop ro.product.model; getprop ro.build.PDA; getprop ro.csc.sales_code; uname -r; getprop ro.build.version.release'
adb shell 'dumpsys package com.google.android.gms | grep -m1 versionCode'
adb shell su -c 'cat /proc/config.gz' | gunzip > phone.config
```

## Kernel modules

`kiwi_v2.ko` (the S24 qcacld-3.0 driver with Wondertap), `wonder.ko`, `mhifix.ko` and `bwfix.ko` are out-of-tree modules for the phone's **running** kernel. Two things must match exactly, or `insmod` fails:

- **vermagic**: the `UTS_RELEASE` string. `build/prep-vendor-tree.sh` writes it to `include/generated/utsrelease.h`. Set it to the phone's `uname -r`. (With MODVERSIONS the kernel compares only the part after the release name, `SMP preempt mod_unload modversions aarch64`, which is why one build serves every model of a firmware month.)
- **Symbol CRCs** (MODVERSIONS): every imported symbol's CRC must equal the phone's. A mismatch shows in `dmesg` as `disagrees about version of symbol`.

### Another model on the same build

Samsung builds every S23 Ultra model of one month from the same kernel source (GZIF: S918W, B, U1, U, N all run GKI `5.15.197-android13-8-34343818`). To add a model, get its firmware (`samloader download -m SM-S918B -r EUX`), take `boot.img`, and `vendor_dlkm`, `system_dlkm` and `vendor` from `super.img` (`simg2img`, then an LP-metadata extractor, then `fsck.erofs --extract`), and run:

```sh
strings -n 20 boot.img | grep -m1 'Linux version'          # same GKI build as AIRDROP_KBASE?
python3 -I tools/kocompat.py <its modules dir> kiwi_v2.ko wonder.ko mhifix.ko bwfix.ko   # want 0 CRC mismatches
python3 -I tools/modcmp.py <S918W modules dir> <its modules dir>                         # want "Wi-Fi stack: IDENTICAL"
```

Also compare `vendor/firmware/kiwi/amss20.bin` (mhifix's `fw_alloc_size` assumes its size). If all match, add the firmware to `AIRDROP_FW` in `device/tweaks.sh` and `install.sh`.

### 1. Sources and toolchain

- **S23 kernel source** for the target build from <https://opensource.samsung.com>: search `SM-S918B` (or the user's model) and pick the release closest to the firmware. Samsung publishes per-build zips, and the W/U/N models share the S918B source. Extract `Kernel.tar.gz` to `/work/s23` in the Docker volume.
- **S24 kernel source** `SM-S928B_<ver>_Opensource.zip` for the S24 release you take the firmware files from. Extract to `/work/s24`. The driver, Wondertap and `wonder` are under `vendor/qcom/opensource/wlan`. **The S24 driver source and the S24 firmware blobs must come from the same S24 release**, because the host-firmware interface changes between releases.
- **Clang:** the phone's `/proc/version` names the compiler, e.g. `Android (8508608, based on r450784e) clang version 14.0.7`. Get that AOSP prebuilt (`clang-r450784e` here) and mount it at `/clang`.
- Docker images: `build/Dockerfile` (Debian build tools) and `build/Dockerfile.cc16` (adds clang-16, used only as a CFI type checker; see `build/cc16wrap.sh`).

### 2. Kernel config

`build/prep-vendor-tree.sh` recreates Samsung's vendor-module config by merging `gki_defconfig` + `vendor/kalama_GKI.config` + `lego.config` + `vendor/kalama_sec_defconfig`, then runs `modules_prepare`. Compare the result with the phone's `/proc/config.gz`: options that change struct layouts (e.g. `CONFIG_CFI_CLANG`, `CONFIG_KASAN`, `CONFIG_DEBUG_*`, `CONFIG_MODVERSIONS`) must agree. `build/s23.config` is the reference phone's config, kept for diffing.

### 3. Symbol CRCs (`build/Module.symvers.base`, `build/extra.symvers`)

The GKI kernel's `Module.symvers` isn't published, so harvest the CRCs from the phone's own modules. Every stock `.ko` lists the CRC of each symbol it imports in its `__versions` section:

```sh
mkdir -p mods && adb pull /vendor_dlkm/lib/modules mods/v && adb pull /system_dlkm/lib/modules mods/s
python3 -I tools/symvers.py Module.symvers.stock mods/v/*.ko mods/s/*/*.ko
```

- `tools/symvers.py` writes one line per symbol: `0x<crc> <symbol> vmlinux EXPORT_SYMBOL`.
- Symbols that a **module** exports must be credited to that module, not to `vmlinux`, so modpost records the dependency. These are cfg80211, mac80211, cnss2, the IPA driver and similar. Put them in `extra.symvers` with their module path. Build the exporting module from the S23 source, or copy its line from a build, and check that its CRC equals the harvested one.
- `Module.symvers.base` is the stock list minus everything in `extra.symvers`:
  `awk -F'\t' 'NR==FNR{w[$2]=1; next} !($2 in w)' extra.symvers Module.symvers.stock > Module.symvers.base`
- **Verify** after building: run `tools/symvers.py` on your new `.ko`. Every symbol it imports must have the same CRC as in `Module.symvers.stock`. Symbols missing from the stock list are allowed only if `CONFIG_MODVERSIONS` treats them as unversioned. Prefer confirming them with a test `insmod`.

### 4. Driver patches (`src/qcacld-patch`, `src/wonder-patch`)

The S24 driver expects the S24's cnss2 platform API. `src/qcacld-patch/apply.sh` adapts it to the S23's cnss2:

- `s23_cnss_compat.h`: declarations the S23 cnss2 lacks.
- Event and reason enum values missing on the S23.
- A **CFI** fix: cnss2 calls `update_status` as `void (*)(struct pci_dev *, uint32_t)`, so the S24's enum-typed signature would trip CFI at runtime.

For a new firmware, diff `/work/s23/vendor/qcom/opensource/wlan/platform/inc/cnss2.h` against the reference. Rerun `build/cc16wrap.sh` (via `build-mhifix.sh`/`build-bwfix.sh`) and read `cfi_strict.log`. Any function-pointer type mismatch across the cnss2 boundary will panic the phone with a CFI failure.

### 5. Hard-coded offsets in mhifix and bwfix

- `src/mhifix/mhifix.c` uses fixed `struct mhi_controller`/`struct mhi_device` offsets (`OFF_*`). Re-derive them from the phone's BTF: `adb pull /sys/kernel/btf/mhi` and dump it (`bpftool btf dump file mhi` or `pahole`). `bwfix.c` checks the same offsets with `BUILD_BUG_ON`.
- `fw_alloc_size` (0x6c0000, the S23 firmware's DDR allocation) and `NEW_FW_DDR_SIZE` (0x730000, what the S24 firmware asks for) depend on the firmware pair. Run `insmod mhifix.ko mode=0` (report only, changes nothing) and read `dmesg` to see the live sizes before using `mode=1`.
- At runtime `tweaks.sh` passes `plat_env=` and `orig=` from `/proc/kallsyms`: `plat_env` must sit inside cnss2's `.bss`, and `orig` is `cnss_mhi_bw_scale.cfi_jt`. Check that both symbols still exist.

### 6. Build

See README → "Building the kernel modules". Afterwards check `strings X.ko | grep vermagic` against `uname -r`.

### 7. Test on the phone, in this order

1. `insmod mhifix.ko mode=0`, then read `dmesg`. It reports and changes nothing.
2. Run `tweaks.sh apply airdrop` with the new payload, and read `tweaks.log` plus `dmesg | grep -iE "kiwi_v2|cnss|mhi|wonder"`.
3. Check that Wi-Fi reconnects. Then the user tests Quick Share → Share with Apple devices.
4. Expect a firmware crash on the first AirDrop attempt if the S24 firmware's PCIe Gen3 request isn't handled; that's bwfix's job. The `guard` loop saves `dmesg` to `fwcrash_*.txt` and reboots cleanly.

## Payload (S24 files)

The release file `airdrop-S918WVLU8GZIF-2.tar.gz` (release `payloads-S918WVLU8GZIF`; `-2` has the wonder.ko that pre-reserves mac80211's 128 KB block, issue #7) is downloaded by the phone and unpacked to `/data/adb/s23tweaks/payload/airdrop/`. Everything that isn't built from source comes from the S24 Ultra firmware, which you can download with [samloader](https://github.com/samloader/samloader) or a similar tool (model `SM-S928B`, a CSC such as `EUX`). Unpack `super.img` with `lpunpack` and mount or extract the `system`, `system_ext` and `vendor` images.

| File | From the S24 image |
|---|---|
| `fw/amss20.bin`, `fw/phy_ucode20.elf`, `fw/regdb.bin` | `vendor/firmware/kiwi/` (keep the S23's own board file `bdwlan*`) |
| `mosey/` | `system_ext`: `priv-app/MoseyApp`, `bin/mosey_server`, `lib64/libmosey_daemon_ffi.so`, `etc/permissions`, `etc/sysconfig`, `etc/vintf/manifest` entries for Mosey |
| `wifi7/wpa_supplicant` | `vendor/bin/hw/wpa_supplicant` |
| `wifi7/android.hardware.wifi.supplicant-V2-ndk.so` | `vendor/lib64/` |

Built from this repo: `moseyrun` (`src/moseyrun`), `pbflag` (`src/pbflag`), and a static `sqlite3`. Use NDK `aarch64-linux-android34-clang -O2 -static`.

**Match Android versions.** Mosey and the supplicant link against the phone's system and vendor libraries. Take them from an S24 release on the same Android version as the target S23. Before shipping, compare each binary's `NEEDED` libraries (`llvm-readelf -d`) with what exists on the phone. The supplicant needed exactly one extra library on the reference phone.

Then rebuild the tarball and update `PAYLOAD`, `PAYLOAD_SHA256` and `VERSION` in `install.sh`, plus `AIRDROP_KERNEL` in both `install.sh` and `device/tweaks.sh`.

## Play services

Quick Share only hands AirDrop to Mosey when two Nearby flags are on. `tweaks.sh` sets them as local overrides in `phenotype.db`:
- config package `com.google.android.gms.nearby`;
- account 0;
- the flags are added to `flag_overrides` and linked from `experiment_states_to_overrides`;
- the `nearby.pb` snapshot is patched with `pbflag`.

If a newer Play services renames them, Google's server config is the place to look (search the decompiled Nearby classes for `enableExternalProviders`). Don't guess flag numbers.

## Carrier config (`callrec`, `india`)

These bind plain-XML versions over the phone's own carrier files, whatever its sales code: `csc_paths` in `tweaks.sh` takes the folder from `mdc.system.path` (what `SemCscFeature` reads). Samsung's parser accepts plain files, although stock files are OMC-encoded.

- Decoding: `device/files/omcdec` (static arm64, `src/omcdec/build.sh`) on the phone, `tools/omcdecode.py salts.txt shifts.txt in out` on a computer. The 256-entry `salts` and `shifts` arrays come from `SemCscFeature` in `/system/framework/framework.jar` (`jadx --no-replace-consts --single-class com.samsung.android.feature.SemCscFeature`). If a firmware changes them, `omcdec` exits 2 ("not an OMC-encoded file") and `callrec` skips.
- `callrec` decodes the stock `cscfeature.xml` at every apply and adds the two call-recording keys to every `FeatureSet` (multi-country files, e.g. EUX, have one per country). It refuses a file that isn't one feature per line.
- `india` uses the INS files from an S918B INS One UI 9 firmware (`HOME_CSC`); `INS_keystrings.dat` is copied under the phone's own sales code's name. For another One UI version, take the INS files from a firmware of that version.
- `india` also runs `india_identity` in `tweaks.sh`: `resetprop` sets the model props (`IN_MODEL_PROPS` → `SM-S918B`), the sales-code props (`IN_SALES_PROPS` → `INS`) and `ro.csc.countryiso_code=IN`, then force-stops Samsung Wallet so it re-reads them. This is why Samsung Wallet India and the 6 GHz hotspot work: Samsung's `wallet-enabler` server keys on model + country, and `SM-S918W` + `IN` is rejected while `SM-S918B` + `IN` is accepted (proven from Wallet's own log: `CountryISOSelector` stays `IN` from the SIM, but the enabler returns `spay` only when the model is Indian). It is runtime `resetprop` only — reverts on reboot, writes none of the CSC files — but it changes `Build.MODEL` for every app while on, and hardware-attested payment-card provisioning still sees the real model. `$V/india_identity` marks that our spoof set `INS`, so `why_not`/status don't mistake it for a genuinely-INS phone. `india` also runs `india_simprompt_off`: Samsung's CID Manager (`com.samsung.android.cidmanager`) pops a persistent "Switch to \<carrier\>?" dialog (SIM-based CSC auto-switch) when the SIM's carrier differs from the reported sales code, which `india` triggers by forcing INS. The dialog is drawn by the `com.android.phone` process (shared uid 1001) as a `SYSTEM_ALERT_WINDOW` attributed to the CID Manager package, so disabling the package alone doesn't stop it (it keeps respawning) — the fix also denies that package's `SYSTEM_ALERT_WINDOW` appop (`appops set … ignore`), which is the lever the system actually checks (confirmed on-device: `rejectTime` on the appop as the phone process tries to redraw). `india_simprompt_on` reverts both (`pm enable` + appop `allow`) when `india` isn't picked, and `cleanup` does the same on uninstall; the `$V/india_simprompt` marker records that we disabled it so we only restore what we changed. Both `pm disable-user` and `appops set` persist across reboot (unlike the `resetprop` identity), which is why the explicit undo is needed. `hotspot6g` no longer touches the country (v1.3.4): it sets Samsung's debug override `vendor.wifiap.6gbandcountry=1`, which `supportWifiAp6GBasedOnCountry()` honours only when `SemWifiManager.MHSDBG` (= `SemWifiApCust.DBG`, computed once from `ro.product_ship=false`) is true. `hotspot6g_pre` sets `ro.product_ship=false` before the framework restart; `hotspot6g_post` waits for `dumpsys sem_wifi` to show `6g_Country:true` (that call latches the flag in `system_server`) and restores `ro.product_ship`. Don't go back to faking `ro.csc.countryiso_code`: Samsung's servers reject a non-Indian model with country `IN` (Wallet won't open). Also note `PaymentManagerService.COUNTRYISO_CODE` in services.jar caches the country at `system_server` start.
- `galaxyai` sets `COMMON_CONFIG_AI_VERSION` to 20263 (the S24 Smart Suggestions gates its Personal Data Engine / Now Brief consumers on >= 20261 and >= 20263). The S23's **Visual Cloud Core** reads the same key (`o0/c.java` in 3.0.02.16: >= 20261 → C2PA adapter V2) and calls `getVersion`, `enableTrustCheck`, `readFromFd`, `readFromFile`, which the S23's V1 `/system/lib64/libC2paDps.camera.samsung.so` lacks (issue #19). **Per-app hiding can't fix this**: `floating_feature.xml` is parsed in zygote (`android.app.WallpaperManager`, preloaded, calls `SemFloatingFeature.getInstance()` in its static init, and `SemFloatingFeature` parses in its own `<clinit>`), so every app inherits the parsed values; that's also why every `ff_set` tweak needs the framework restart. `files/libC2paDps-shim.so` (`src/c2pashim`) is bound over the library: the four V2 calls are mapped onto V1 (`*WithTrustCheck` with the paths `enableTrustCheck` stored, as the V1 adapter does), and the other eight are forwarded to the original, staged into the lib64 layer as `libC2paDps_s23.camera.samsung.so` and opened with `dlopen` by name (the shim lives in the default linker namespace, which searches `/system/lib64`). Test the shim without root: copy both libraries to `/data/local/tmp/c2t`, and with `LD_LIBRARY_PATH` set, run a stand-in `C2paLib` class through `app_process`. The C2PA service itself (`C2paService`) needs a signature permission, so adb can't call it.
- `weather`: DressRoom 3.0.10.38 gates the lock screen editor's Weather effect on `va.q.g` (`LOCKSCREEN_CONFIG_WALLPAPER_STYLE` contains `GENWEATHER`, `COMMON_DISABLE_NATIVE_AI` off, platform >= 150100) plus `cj.a.a(FEATURE_WALLPAPER/FEATURE_DOWNLOAD)` = 0 or 3. For those features cj.a binds `com.samsung.android.aicore`: the global setting `scs_visual_supported_feature_info` is Visual Cloud Core's (its `app_version` never matches AI Core's), so it falls through to `content://com.samsung.android.aicore.feature` `call("featureSupportRequest", feature)` → `constVersion` (>= 1 = available). Selecting Weather then runs `f9.p.d`: `IDownloadService` (`visual.intent.action.BIND_DOWNLOAD_SERVICE`) transaction 3 `(String "visionlvm", int, int) -> int`. The client treats 0 as "no such interface" and subtracts 10000 from anything above 9000, and the editor needs 0, so the stub returns 10000. `WX_VER` in `tweaks.sh` must equal the stub's `versionCode`; its versionName ends in `-s23tweaks`, which is how `wx_stub` tells it from a real AI Core. The stub is signed with the builder's debug key, so a rebuild elsewhere has another signature: `weather_apply` uninstalls and reinstalls on `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. The engine (SpriteWallpaper `WeatherWallpaperService`) picks the effect from Samsung Weather's icon number (`WallpaperInfoContract.convertToWeatherEffect`): 0/16/23 sunny (daytime only), 6/7/8/19/20/28 rain, 11–14/27/29 snow, 5 fog, anything else none.
- `dual5g`: 5G+5G DSDS is gated by the modem's policyman, not Android (`persist.radio.support.dualrat=2` already gives the secondary SIM the full network mode, and `ril.enabled_5g_rf_per_subs=[1,1]`). `/policyman/device_config.xml` has `<msim_config mode="5G_PLUS_5G" list="msim_plmns"/>`; `global_defines.xml` ships `msim_plmns` = `460-* 712-*`; otherwise 5G_PLUS_4G applies and `disable_sa_ndds.xml` strips SA bands from the non-DDS sub. These come from the HW MBN (`/vendor/firmware-modem/image/modem_pr/mcfg/configs/mcfg_hw/.../DSDS/mcfg_hw.mbn`, plain XML inside) and are written to EFS once, when the MBN is activated, not at every boot. There is no `/dev/diag`; `diag-router` serves libdiag clients over HIDL, but its stock client `/vendor/bin/diag_socket_log -a <ip> -p <port>` is a two-way HDLC DIAG-over-TCP bridge, so `files/efstool` listens on 127.0.0.1, starts it, and speaks EFS2 (DIAG `0x4B`, subsys `0x13`: HELLO 0, OPEN 2, CLOSE 3, READ 4, WRITE 5, STAT 15; layouts as in QCSuper's `efs_shell_commands`). The modem restart is `echo stop/start > /sys/class/remoteproc/<mss>/state` (`persist.vendor.ssr.restart_level=ALL_ENABLE`, recovery enabled); SIMs re-register in ~13 s. From a computer, QCSuper `--usb-modem 05c6:901d --efs-shell` after `setprop sys.usb.config diag,adb` reaches the same files.
- `nronly`: TelephonyUI 18.1.00.62 builds Network mode from fixed lists (`i7.n`, e.g. default 5G {26,9,0}); `j7.a.a()` then appends 11 (LTE only) and, if `w.a(24)` (`CarrierFeature_VoiceCall_ConfigNetworkList` contains `ADD_5GONLY`/`_Add5gOnly`) and `y3.h0.O()` (a SIM's max network type > 22), 23 (NR only). `a()` runs only on the Jio path or when `CarrierFeature_Setting_CustNetworkSelMenu4` contains `LTEONLY`, so both keys are needed. `SemCarrierFeature` reads the group `mdc.matched_code<slot>` (default `ro.csc.sales_code`) from `customer_carrier_feature.json`; on ship builds `TextDecoder` accepts only OMC-encoded files (header `2f 27`), and the singleton is loaded in zygote, so a framework restart is needed. The edit stacks one bind over `india`'s; `csc_unbind` drops all layers.
- `natroam`: `cmd phone cc` is refused on user builds. CarrierConfigLoader also loads `files/carrierconfig-<pkg>-override-<iccid>-<carrierid>.xml` (in `/data/user_de/0/com.android.phone`) when the SIM loads, if its `__carrier_config_package_version__` matches the cache file's. `gsm_nonroaming_networks_string_array` with MCC-only entries makes ServiceStateTracker treat those networks as home. The files written are listed in `$V/natroam`.
- `rambler`: Gboard's flag resolution (`rqn.x()`) walks `rrr.values()` from the end: HERMETRIC_OVERRIDE, OVERRIDE (`shared_prefs/flag_override.xml`, see `rrg`), OEM, MANAGED_CONFIG, PHENOTYPE (`flag_value.xml`, the server's), SYSTEM_SETTING, DEFAULT. Overrides are cleared only during crash recovery (`thx.w`). `enable_agentic_dictation` (qhr.a) switches Voice typing to `setting_voice_unified` with Rambler or Standard. The look depends on `enable_jetson_in_toolbar`, `ad_activation_type` and the motion flags. The flag set is PixelBoard's. A first attempt using only Gboard's code defaults didn't match the Pixel's look.
- `hideksu` has two independent parts. (1) The patched `services.jar` (`src/hideksu/H.smali`) hides the KernelSU manager **package** from the AppsFilter in `system_server`. (2) `files/hidemnt` (`src/hidemnt/hidemnt.c`, static arm64, built by `src/hidemnt/build.sh`) hides the module's **mounts** per app by install origin. Every module mount line in `mountinfo` contains the token `s23tweaks` (overlay sources `s23tweaks_*`, or binds whose mount-root is `/adb/s23tweaks/...`), so `hidemnt` can find them generically. It watches the kernel process-event connector (`NETLINK_CONNECTOR`/`PROC_EVENT_COMM`) and, when an app spawns, decides by policy whether to `setns()` into its mount namespace and `umount2(MNT_DETACH)` each module mount (deepest first) — one native pass, fast enough to finish before the app's own onCreate check. **Policy (install origin):** hide from every app whose uid ≥ 10000 and whose package is not flagged `FLAG_SYSTEM` (i.e. user-installed: banks, detectors); keep the mounts for every preinstalled system app (the tweak consumers — Camera/Gallery/Settings/the galaxyai apps). Systemness comes from `pm list packages -s -u`, written by `hidemnt_start` to `$V/hidemnt-system.txt` and passed as the daemon's third argument (an updated system app is still listed, so a store-updated consumer is kept). **Don't parse `/data/system/packages.xml`**: One UI 7+ writes it as binary XML (ABX, magic `ABX\0`; seen on SM-S918B One UI 9), so v1.3.6's text scan found 0 packages and its fail-safe silently turned auto-hiding off. The text scan stays only as the fallback when no list is given. `com.samsung.*`/`com.sec.*` packages are always kept: Samsung apps installed from the Galaxy Store (Voice Recorder, Samsung Health, language packs) aren't `FLAG_SYSTEM` but can read the tweaked feature files. **`hide_in` refuses a pid whose mount namespace is init's (or the daemon's own):** Chrome's app zygote (`com.android.chrome_zygote_native`, app uid, not a package name) and its sandboxed children run in init's namespace, so a detach "in that app" removed every module mount system-wide; zygote then aborted every new app zygote/WebView (`Failed open(/product/overlay/s23tweaks-aodbright.apk)`) until a reboot. Seen on-device in v1.3.8 testing. The daemon re-reads the system list and the override file whenever their mtime changes. `/data/adb/s23tweaks/hide-apps.txt` is an override layer, not the source of truth: a plain `<pkg>` force-hides a system app, a leading-`-` `<pkg>` force-keeps a user-installed one. Reason for install-origin over KernelSU's own umount (`ksud kernel umount add`): KSU's is global to all non-root apps and would strip the mounts from the Samsung consumers too (confirmed on-device); an enumerated consumer *keep*-list was rejected because file-based tweaks like `floating_feature.xml`/`camera-feature.xml` are read by a broad, firmware-dependent set of Samsung apps, so a missed entry silently breaks a tweak. `hidemnt_start`/`hidemnt_stop` run from the apply after the framework restart; the daemon then runs whenever `hideksu` is on, regardless of the override file. Detector used to verify: Native Detector (`com.reveny.nativecheck`) 7.7.0, which keys on `/proc/self/mountinfo` (overlay fs on system partitions = "suspicious", single-file binds among normal files = "inconsistent"); `selinux_hide` in this KSU build already sanitizes `/sys/fs/selinux` so no SELinux trace is left.
- `restart_framework` (setprop `ctl.restart zygote`) can leave SystemUI having started before Wi-Fi reconnects, so it drops the Wi-Fi **signal** status-bar icon (Wi-Fi Calling / `ims_volte` stays; Wi-Fi itself is still connected) until the next reboot or a manual Wi-Fi toggle — a plain `cmd wifi` off/on does *not* fix it, the icon controller is wedged. `statusbar_wifi_refresh` (called at the end of apply when `restart=1`) fixes it by cycling the `wifi` slot through `settings … secure icon_blacklist` (add `wifi`, sleep, restore the exact prior value; `settings delete` if it was unset), which forces `StatusBarIconController` to rebuild the slot from live state. Display-only, no radio touched; skipped if the user already has `wifi` in the blocklist. Don't "fix" this by restarting SystemUI again (extra black-screen flash) — the blocklist cycle is silent.

## Releasing

- Build the zip with `module/build.sh`. Bump the version in `CHANGELOG.md`, `install.sh`, `module/module.prop` (version and versionCode) and `module/update.json`.
- Publish module releases as normal releases marked **Latest**, not pre-releases. The README links to `releases/latest`, which skips pre-releases. Only the `payloads-<firmware>` releases (tweak files, not the module) stay pre-releases, so they never become Latest.

## Known dead ends (don't retry)

- **Wi-Fi 7 hotspot:** the S23's `hostapd` has no 802.11be code. The S24's logs `CONFIG_IEEE80211BE not  for hostapd` and fails `addAccessPoint`. A 6 GHz Wi-Fi 6E hotspot works with the stock hostapd.
- **`cmd overlay fabricate`** can't target policy-restricted resources such as `com.android.wifi.resources` (state `STATE_NO_IDMAP`). A static RRO in `/product/overlay` also needs an `allowed-system-preload-apps.xml` entry on Samsung ("Package is not in allowed list").
- **Toggling Wi-Fi around a driver swap:** Samsung turns Wi-Fi back on by itself about 0.4 s after a hotspot stops. Stop the hotspot, wait, turn Wi-Fi off, and confirm `cmd wifi status` says `Wifi is disabled` before `rmmod`. Otherwise WifiSelfRecovery fights you. `wifi_down` in `tweaks.sh` does this.
- **The KernelSU manager app** makes some anti-tamper apps (e.g. CRED) crash in the background. The user chose to keep it installed.
