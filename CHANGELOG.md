# Changelog

## Unreleased

- **AOD wallpaper brightness** (`display`): the lock screen wallpaper on Always On Display showed bright for a few seconds and then dropped sharply. The tweak no longer sets the S24's `LCD_CONFIG_AOD_BRIGHTNESS_ANIMATION`; only `LCD_CONFIG_AOD_FULLSCREEN` turns the wallpaper on. Not yet tested on a phone.

## v1.2.2

- **Every tweak says why it can't run.** The module page shows the reason for each unavailable tweak (before, Camera HDR, Galaxy AI, Settings search, the carrier tweaks and the camera-config tweaks could be offered and then skip silently). Apply logs `<tweak>: skipped: <reason>` and carries on with the rest (an unsupported kernel no longer stops the whole apply at AirDrop), and the log ends with `on:` / `not on:`.
- **Battery health** no longer needs `/efs/FactoryApp/batt_full_status_usage`, which some phones (an S918B) don't have. Android only uses it when the kernel reports BFSU.
- **Adaptive color tone** shows as unavailable off S918WVLU8GZIF: it patches that build's Settings app, so on other firmware it did nothing.
- **4K auto framing** was reported to make the camera fail (S918B). Ticking the Camera category or "all" no longer picks it; it can still be picked on its own.

## v1.2.1

- **Battery health page:** the two feature flags it needs are now set to TRUE even when a firmware ships them as FALSE (before, they were only added when missing, so the page could stay hidden on other models).
- The module page now names the missing `/efs/FactoryApp` file when `battery` can't run (it checked only one of the five), and `tweaks.sh status` shows whether the battery auth IC is the module's or a real one, plus both flag values.

## v1.2.0

- **AirDrop and Wi-Fi 7 on more S23 Ultra models:** S918B, S918U1, S918U and S918N on One UI 9 build GZIF, besides the S918W. All five run the same GKI kernel build; their Wi-Fi drivers (cnss2, mhi, cfg80211, mac80211, ipa) have the same code and every symbol the AirDrop modules import has the same CRC, checked against each firmware's files. Only the S918W has been tested on a phone so far. `AIRDROP_FW` in `device/tweaks.sh` lists the firmware; `tools/kocompat.py` and `tools/modcmp.py` check a new one.
- `india` is now labelled for what it is to Airtel/Jio users: the **Use 5G standalone networks** switch, call recording, Smart IVR and message cards. With an Indian SIM (MCC 404/405) the Carrier category (module page and installer) picks `india` instead of `callrec`.

## v1.1.0

- **Categories:** the tweaks are grouped into Connectivity, Camera, Display and graphics, Galaxy AI and Samsung apps, Battery and settings, and Carrier. The module page has a checkbox per category (all, some or none), and the installer takes a category letter or single tweak numbers.
- New tweaks: `camextras` (Director's view and Super steady horizontal lock), `autoframe` (4K auto framing, untested), `settingssearch` (S24 Settings search bar, 10 MB download), `bargein` (Bixby barge-in, untested) and `callscreen` (Call screening via Samsung Language Core; screening works, the AI summary doesn't; persistent; 3.1 GB download in two parts).
- Camera settings from several tweaks now share one rebuilt camera-feature.xml.
- **No tweak files in RAM:** the overlays hold only empty placeholders in tmpfs, and every real file (AirDrop's driver files and Mosey, the Wi-Fi 7 supplicant and library, the camera HDR libraries, color tone's patched Settings) is bind-mounted from storage. All tweaks on now take 24 KB of tmpfs instead of about 107 MB. Programs bound from /data get `nosuid` cleared with BusyBox so they still enter their SELinux domains (the kernel won't build an overlay from /data).
- **Removing the module cleans up everything it made:** Play services flags, Language Core (if it installed it), the Camera setting, cached app manifests and `/data/adb/s23tweaks`. The cleanup (`tweaks.sh cleanup`) waits for Android and the first unlock.
- Fixed: after a reboot, apps the tweaks had swapped (e.g. Now Brief / Smart Suggestions) could crash in a loop: Android kept the S24 build's parsed manifest in `/data/system/package_cache`. Every framework restart now drops the cache entries of the bound APKs.
- Fixed: AirDrop failed on phones booted with `kptr_restrict=2` (the kallsyms line match never matched, and the cnss2 section address read as 0).
- **The zip holds only scripts** (under 400 KB instead of 20 MB). Every tweak that needs files, `airdrop` and `wifi7` included, downloads them from the `payloads-S918WVLU8GZIF` release when it's applied, checked against SHA-256s pinned in `device/tweaks.sh`. A file split into parts (over GitHub's 2 GB limit) is joined on the phone.

- New tweaks: `display` (Vividness slider and full-screen AOD wallpaper), `logvideo` (Log recording and LUT preview in Pro video) and `vulkan` (Skia on Vulkan for apps).
- Feature flags can now be set to values, replacing the stock ones (not only added as TRUE).
- New tweaks with their own download, fetched by the phone only when picked: `camerahdr` (untested: puts back the multi-frame and low-light HDR camera processing One UI 9 removed), `audioeraser` (Audio Eraser in Gallery), `colortone` (Adaptive color tone) and `galaxyai` (S24 Now Brief, Creative Studio and Call Assist).
- `docs/findings.md`: research notes, starting with the One UI 9 camera processing regression.

## v1.0.0

First release, for the Galaxy S23 Ultra on One UI 9 / Android 17 (AirDrop and Wi-Fi 7 need firmware S918WVLU8GZIF).

- Seven tweaks: AirDrop with Apple devices, battery health page, extra settings (auto power on/off, louder VoIP calls), call recording, India (INS) carrier config, 6 GHz Mobile Hotspot, Wi-Fi 7 multi-link (MLO).
- KernelSU module with a settings page: install from KernelSU → Modules, pick tweaks and apply on the phone, no computer needed.
- Apply at every boot: the saved tweaks re-apply automatically after each reboot, with fail-safes against boot loops.
- Computer installer (`install.sh`) over adb for macOS and Linux.
- Nothing is written to a partition; a reboot returns the phone to stock.
