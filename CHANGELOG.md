# Changelog

## 1.0.0 - 2026-10-16

First release.

### Features

- Direct method: exports the userstore without the Amazon framework and returns to KOReader on eject or unplug after safe storage recovery.
- Amazon UI method as an alternative, and automatically when KOReader runs on top of the framework.
- Prompt when a computer is connected, also on wake-up; never repeated while the cable stays in after a session or after declining, including across the file manager and opened books.
- Illustrated status screens on 758x1024 Kindles, plain text elsewhere. All status screens, including the recovery one, follow KOReader's language where the font can draw it.
- English and 41 other KOReader languages (machine-translated except Spanish).

### Safety And Validation

- Require confirmed LUN release, successful recovery and FUSE access before resuming KOReader. Stop automatic recovery on terminal errors instead of bypassing a failed filesystem check.
- Reserve a shared atomic lock before payload staging and require a session token and matching helper PID for both methods. Cancel late startup helpers without leaving a result for a later KOReader. Clear a lock only when its owner is gone or it is our own cancelled reservation.
- Respect the Amazon UI automatic return setting and require disconnected USB and available storage before relaunching. Never start a second KOReader if one was started by hand, and stay in the Amazon UI on Kindles that do not report the cable state.
- Reject additional visible FAT mounts and unreadable mount tables; document the supported environment and recovery limits.
- Add hardware-independent regression tests for recovery and session coordination.
- Merge image conversion into one standalone script with correct defaults and complete-input validation; remove the unrelated screensaver converter.
- Check file write and close failures, replace staged files by rename, report payload preparation errors with paths and operations, and constrain saved timeout values.
- Validate framebuffer width, pixel depth, RAW size and stride when reported. Accept virtual framebuffer heights larger than the visible image, including the Paperwhite 2's 768x4096 virtual buffer.
- Require both the USB connection signal and powerd charging signal before direct export.
- Show the leaving message before waiting for the helper, so the short pre-flight pause is not a frozen screen.
- Add regression coverage for virtual framebuffer geometry, optional stride and USB connection gating.
- Add release packaging with Lua syntax, translation schema, RAW resource, ZIP structure and SHA-256 checks. The translation list comes from `l10n/`.

### Device Validation

- Tested on a Kindle Paperwhite 2, firmware 5.12.2.2, KOReader 2026.07.2.
