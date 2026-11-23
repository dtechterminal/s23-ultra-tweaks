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
| `hotspot6g` | Mostly no | Re-check `SemWifiApServiceImpl.isRegionFor6GCountry()` in `/system/framework/semwifi-service.jar`; `IN` must still pass |
| `callrec`, `india` | **Yes**: XAC on S918W GZIF; `callrec` also EUX on S918B GZIF | New CSC files + new MD5 gates (see "Carrier config") |
| `colortone` | **Yes**: the build's `SecSettings.apk` | `python3 -I tools/eadpatch.py SecSettings.apk <build>`, put the patch in `device/files/`, add the two MD5s to `SETTINGS_EAD` in `device/tweaks.sh` and the build to `can_ct` in `install.sh` |
| `airdrop`, `wifi7` kernel modules | **Yes**: kernel build (all models of one build share them) | Same build, other model: check and add to `AIRDROP_FW` (see "Another model on the same build"). New build: rebuild all four `.ko`s (see "Kernel modules") |
| `airdrop` payload (firmware, Mosey, supplicant) | Android version + S24 release | Re-extract from a matching S24 firmware (see "Payload") |
| Play services flags `45704091`, `45723015` | Play services version | Re-check if AirDrop doesn't show up (see "Play services") |
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

The release file `airdrop-S918WVLU8GZIF.tar.gz` (release `payloads-S918WVLU8GZIF`) is downloaded by the phone and unpacked to `/data/adb/s23tweaks/payload/airdrop/`. Everything that isn't built from source comes from the S24 Ultra firmware, which you can download with [samloader](https://github.com/samloader/samloader) or a similar tool (model `SM-S928B`, a CSC such as `EUX`). Unpack `super.img` with `lpunpack` and mount or extract the `system`, `system_ext` and `vendor` images.

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

These replace three XAC files with plain-XML versions. Samsung's parser accepts plain files, although stock files are OMC-encoded.

- Decode a stock file: `tools/omcdecode.py salts.txt shifts.txt in out`. The 256-entry `salts` and `shifts` arrays come from `SemCscFeature` in the phone's `/system/framework/framework.jar`; decompile that one class.
- `callrec` is the decoded XAC `cscfeature.xml` plus the call-recording keys. `india` uses the INS files from an S918B INS firmware (`HOME_CSC`).
- Another sales code for `callrec`: add a line to `CALLREC_CSC` in `tweaks.sh` (sales code, firmware, path and MD5 of the stock `cscfeature.xml`, folder in `device/files/`) and to `can_rec` in `install.sh`. The file is the decoded stock one plus the two recording keys. Multi-country files (`/optics/configs/carriers/single/<CSC>`, e.g. EUX) have one `FeatureSet` per country; add the keys to every one.
- The MD5 gates in `tweaks.sh` (`XAC_*_MD5`) make the tweak refuse to run on any other stock file. For a new firmware, make new files from **that** firmware's stock files and update the MD5s. Never reuse files across firmware versions.

## Known dead ends (don't retry)

- **Wi-Fi 7 hotspot:** the S23's `hostapd` has no 802.11be code. The S24's logs `CONFIG_IEEE80211BE not  for hostapd` and fails `addAccessPoint`. A 6 GHz Wi-Fi 6E hotspot works with the stock hostapd.
- **`cmd overlay fabricate`** can't target policy-restricted resources such as `com.android.wifi.resources` (state `STATE_NO_IDMAP`). A static RRO in `/product/overlay` also needs an `allowed-system-preload-apps.xml` entry on Samsung ("Package is not in allowed list").
- **Toggling Wi-Fi around a driver swap:** Samsung turns Wi-Fi back on by itself about 0.4 s after a hotspot stops. Stop the hotspot, wait, turn Wi-Fi off, and confirm `cmd wifi status` says `Wifi is disabled` before `rmmod`. Otherwise WifiSelfRecovery fights you. `wifi_down` in `tweaks.sh` does this.
- **The KernelSU manager app** makes some anti-tamper apps (e.g. CRED) crash in the background. The user chose to keep it installed.
