# FM1 Flasher — iOS app

## Goal

A native iOS app (Swift) that lets a Vave FM1 owner flash firmware directly
from an iPhone over USB-C, instead of needing a Mac/Chrome + Web MIDI. Scraps
the current workflow of: laptop + Chrome + thefirmwarehub.com.

Rough feature set:
- Connect to the FM1 over USB (iPhone USB-C, or Lightning + camera adapter).
- Pull the firmware catalogue from thefirmwarehub.com (mirrors GitHub release
  assets, SHA-256 checked). Start with a locally scraped copy for testing.
- List available firmwares, let the user pick one, flash it to the FM1.

App Store / TestFlight distribution is explicitly deferred until there's a
working app shell. See "Distribution" below for what we already know.

## Key finding: it's MIDI, not raw USB

thefirmwarehub.com's flasher uses **Web MIDI**, not WebUSB/WebHID. It talks to
the FM1 over **USB MIDI SysEx**: a two-stage process where the running
firmware first stages the new package's update loader, then the loader writes
the firmware. SHA-256 of the package is checked before writing.

This matters a lot for iOS: CoreMIDI has native support for class-compliant
USB MIDI devices — no MFi program, no special entitlement needed. Since the
FM1 already works with Chrome's Web MIDI (which on Apple platforms is itself
built on CoreMIDI), it should enumerate over CoreMIDI on iOS the same way,
via native USB-C (iPhone 15+) or a Lightning camera adapter on older phones.

**Conclusion: the transport layer is not the risk here. It's effectively free.**

## Language: Swift, not Objective-C

CoreMIDI is a C API but fully callable from Swift. The only mildly annoying
part is manual `MIDIPacketList` / buffer handling for SysEx — a day of
unfamiliarity, not a real obstacle. No Objective-C or Java needed anywhere.

## The actual hard part: the SysEx protocol

Nobody has published a formal spec (opcodes, framing, loader handshake, flash
block size). The official m-vave/fm1_open repo open-sources the firmware
*source*, not the flasher protocol.

Best leads for reverse-porting the protocol, found so far:
- [ChoralRootFM1](https://github.com/Quixotic7/ChoralRootFM1) —
  `tools/fm1_install.py`, a Python reference implementation using
  `python-rtmidi` that does real flashing. Also has a browser (Web MIDI)
  installer. This is the most promising starting point — port the SysEx
  message sequence from Python to Swift/CoreMIDI.
- [fm1-dock](https://github.com/joakimeriksson/fm1-dock) — community
  firmware/tooling, also talks to "the FM-1 Firmware Hub's updater" over
  MIDI. Added resumable installs / forced "update mode" safety net from
  v0.16 on.
- Package format across tools is `.fwsc`, with `SHA256SUMS` alongside.

Plan: read `fm1_install.py` (and the hub's own JS if accessible) end-to-end,
port 1:1 into a Swift CoreMIDI client before doing anything fancier.

## Protocol notes, from reading `fm1_install.py`

Read the actual reference implementation
([ChoralRootFM1/tools/fm1_install.py](https://github.com/Quixotic7/ChoralRootFM1/blob/main/tools/fm1_install.py),
~3800 lines, GPL-3.0). This fills in what was previously undocumented.

**Framing.** Everything is `F0 ... F7` SysEx. The body in between is packed
7-bit (`pack7`/`unpack7`: classic 8-bit→7-bit MIDI bit packing, LSB-first).
Two fixed messages matter:
- `HS_QUERY = F0 00 32 45 00 00 00 40 7F F7` — identity/handshake query.
- `UPGRADE = F0 22 24 35 7F F7` — "enter update mode" / "start writing",
  sent twice in a full install (see below).

**The device reads, the host answers — not the other way round.** This is
the key structural fact. The host never pushes firmware data. The device
sends SysEx **read requests** — `(flags, addr, length)`, max 512 bytes a
request (`MAXDATA`) — for chunks of a "logical image" built from the
package file, and the host answers each with the matching bytes
(`response()`: magic `00 59 30`, little-endian addr/length, a one's-complement
checksum, then 7-bit-packed and SysEx-wrapped). This continues until the
device asks for one of two sentinel addresses — `FINISH_CHECK = 0xE0000000`
or `FINISH_WRITE = 0xF0000000` — which the host acknowledges with a canned
`"success\0"` reply.

**Two distinct phases, both using that same serve-the-reads loop:**
1. **Check** — send `UPGRADE` to the *currently running* firmware. It reads
   parts of the package (validating it) up to `FINISH_CHECK`, then reboots
   into a separate **update loader** identity (reports itself as `ota-...`)
   on what is, from USB's perspective, a new MIDI port — the host has to
   notice the old port vanish and a new one appear.
2. **Write** — send `UPGRADE` again, now to the loader. It reads the
   *entire* package up to `FINISH_WRITE`, actually writing flash this time,
   then restarts into the new firmware. The host verifies by sending
   `HS_QUERY` again and checking the identity string matches what was
   expected.

**Package (`.fwsc`) format.** Not a flat image. It's laid out in `0x30`
(48-byte) blocks, with 1 marker byte per block (`KEEP = 0x2F` payload
bytes + 1 marker). The first ~20 blocks' marker bytes each reversibly
encode one character of a human-readable identity string (e.g. `"FM-1_906"`
= model + firmware version), via `(marker - index - 1) & 0xFF`, unless the
marker is the sentinel `0x7D` (padding). `logical_image()` strips these
markers out to reconstruct what the device actually reads block-by-block.
Firmware bytes inside are obfuscated with a simple self-inverse XOR stream
cipher the tool calls "the JieLi ENC stream cipher" — not real security,
just the vendor toolchain's packaging convention. Integrity uses CRC-16/XMODEM.

**Bricking risk — more reassuring than the secondary sources suggested.**
The tool's own docstring: on ChoralRoot firmware **0.16 and later** (which
has a "boot stub"), an install interrupted mid-write makes the FM-1 come
back in **update mode at the next power-on** (three LED flashes) rather
than booting broken firmware — you just run the install again to finish it.
Older firmware (0.15 and earlier) does not have this safety net. So the
real bricking risk is firmware-version-dependent, not universal — another
reason to test only against recent ChoralRoot, per the mitigations below.

**Implication for porting to Swift/CoreMIDI.** The cleanest, lowest-risk
first milestone isn't flashing at all — it's implementing `pack7`/`unpack7`
+ `HS_QUERY`/identity-parsing only, and confirming the app can read back
`"FM-1_906"` (or whatever string) from a real device. That's a pure read,
zero write risk, and proves the SysEx plumbing end-to-end before the
`UPGRADE` / block-serving / two-phase-restart logic is attempted at all.
Done — confirmed against real hardware on two different community firmwares
(X0X, Sloop); see "Hardware / connectivity notes" below.

**Canonical flash layout and safety notes, from the actual open-source
firmware** ([Felucca](https://github.com/hugelton/Felucca) /
[felucca-bsp](https://github.com/hugelton/felucca-bsp), the base platform
most community firmwares — X0X, Sloop, etc. — fork from; MPL-2.0/GPL-3.0).
This is a stronger source than ChoralRootFM1's Python port for anything
chip/flash-specific, since it's the actual firmware, not a reverse-ported
client.

- Physical flash layout ([felucca-bsp docs/FLASH.md](https://github.com/hugelton/felucca-bsp/blob/main/docs/FLASH.md)),
  cross-confirms the `OTA_AREA`/`OTA_AREA_LEN` constants found in fork
  source: `0x4000..0x97000` application image, `0x97000..0xE0000` main
  store (projects/presets), `0xE0000..0xE5000` OTA staging,
  `0xE5000..0xE7000` autosave, `0xFC000..0xFF000` globals.
- **Flash writes are explicitly not atomic/transactional** — straight from
  the BSP docs: "a later hardware failure or CPU1 job can still stop a
  multi-page operation after earlier pages changed... Applications retain
  responsibility for... power-loss recovery." Reinforces (doesn't change)
  the bricking mitigations below.
- **Install-time safety validation is bsp-commit-dependent, not just
  firmware-version-dependent.** The current `felucca-bsp` `ota.c` has an
  extra check (`ota_boot_valid`) that structurally validates a package's
  bootloader image before accepting it. The X0X fork's vendored copy of
  `ota.c` is pinned to an older `felucca-bsp` commit and does *not* have
  this check (confirmed by diffing the two directly). So "how much
  install-time validation a given build performs" depends on which
  upstream commit that specific fork happened to vendor in, not simply
  whether the release is recent. Don't assume parity across forks.
- **Flash chip is not fully uniform across hardware revisions** — per the
  Felucca README, newer FM-1 units may ship a different/larger flash chip
  (UC25HQ80, JEDEC `0xB36014`) than earlier units. The protocol itself
  shouldn't care (the device drives all reads; the host just answers), but
  worth knowing hardware isn't a monolith here.
- **The flash chip's JEDEC ID is embedded in the identity reply** — but
  only the *full* variant (`HS_FULL`, the one-byte-body-`01` handshake,
  not the plain `HS_QUERY`), at bytes 24–26 of the 27-byte identity field.
  A zero-risk, read-only way to tell which flash chip a given unit has.

## Risk: bricking

Independent reverse-engineering
([Zeli writeup](https://zeli.app/story/49994065)) found that M-VAVE's stock
update protocol has **no demonstrated safe recovery from an interrupted
write**, and the chip (JieLi AC791N/WL82) uses a **single flash bank** — no
A/B fallback. Community firmware (fm1-dock 0.16+) added a resumable-install /
forced update-mode safety net, but that's a property of what's currently
running on the device, not something a client app can guarantee on its own.
The underlying flash writes themselves are confirmed non-atomic at the BSP
level too (see "Canonical flash layout and safety notes" above) — a failure
mid-multi-page-write leaves partial state by design, recovery is entirely
on firmware-level safety nets.

This safety net isn't just a firmware-version question — it's a
**bsp-commit** question. Community forks each vendor in `ota.c` from
whatever `felucca-bsp` commit they happened to fork from, and that commit's
validation logic can differ (confirmed: the current upstream has a
boot-image validation check an older vendored copy lacks). "Recent release"
of a given fork doesn't guarantee it has every upstream safety check.

Mitigations before trusting this app with a real device:
- Test only against a device running recent fm1-dock (has the safety net),
  or one that's genuinely expendable for a while.
- Always detect and honor the OCT− USB-rescue / bootloader mode
  (`UBOOT1.00` mass-storage device) as a recovery path.
- Don't skip the SHA-256 verification step the existing tools do before
  writing.

## Hardware / connectivity notes

Test device is an **iPhone 12 mini** (Lightning port, still on supported iOS).

- Lightning phones need Apple's official **Lightning to USB 3 Camera
  Adapter** (~$39, model MK0W2AM/A or regional equivalent) — don't use a
  cheap third-party one, class-compliant MIDI enumeration is hit-or-miss on
  those. It has a Lightning plug (to the phone), a USB-A port, and a second
  Lightning port underneath for a charging passthrough.
- From the adapter's USB-A port, a plain **USB-A-to-USB-C cable** goes to
  the FM1's USB-C port. Already have cables for this.
- A **USB-C "Digital AV Multiport" adapter will NOT work** here — it has a
  USB-C plug on its host end, which doesn't physically fit a Lightning
  port at all. Not a protocol issue, just the wrong connector for this phone.
- **USB-C iPhones (15 and later) don't need any adapter** — they support
  USB-C host mode for class-compliant accessories natively, so a plain
  USB-C-to-USB-C cable straight into the FM1 would work. The Digital AV
  Multiport adapter would also likely work fine as a bridge on a USB-C
  iPhone, for the same reason (USB-C host mode), just not on the 12 mini.
- None of this affects the app code: CoreMIDI sees the same class-compliant
  MIDI device either way, regardless of whether it arrived via Lightning +
  Camera Adapter or native USB-C.

## Distribution (deferred, notes for later)

- **TestFlight is not free.** It requires the same $99/year Apple Developer
  Program enrollment as the App Store — there is no free TestFlight tier.
- Genuinely free options for personal use:
  - 7-day free-provisioning resign loop via Xcode (tether to Mac weekly).
  - AltStore / SideStore — same free provisioning, but automates the 7-day
    refresh wirelessly. Realistic $0 option if we want to stay free.
- If the AltStore refresh cycle gets annoying, $99/year buys a boring
  permanent ad-hoc or TestFlight build.

## Next steps

1. Scaffold a minimal SwiftUI app shell with a CoreMIDI connection screen:
   list MIDI devices, detect the FM1, show connected/disconnected state.
2. Pull `fm1_install.py` from ChoralRootFM1 and read through the actual
   SysEx sequence it sends.
3. Port that sequence into a Swift CoreMIDI client; test read-only commands
   (e.g. identity query) before attempting any write.
4. Add the firmware catalogue fetch (GitHub releases API and/or
   thefirmwarehub.com) once the MIDI transport is proven.

## Write flow — implemented, untested on hardware

Ported the full two-phase install (`fm1_install.py`'s Updater class) to
Swift: `FM1Protocol.swift` has `parseReadRequest`/`response`/
`packageProductIdentity`/`packageLogicalImage`/`modelOf`/`Identity.isLoader`
alongside the existing identity-query code; `FirmwareInstaller.swift` is a
new, separate `@MainActor` class (own CoreMIDI client/ports, independent of
`MIDIManager`) that drives Check → wait-for-loader → Write → reboot →
Verify, using a `SysExInbox` actor to bridge the realtime CoreMIDI callback
into `await`-with-timeout reads (mirrors Python's `queue.Queue` +
`read(timeout)`). `FirmwareCatalog.swift` bundles two test firmwares
(X0X 1.2.2, CoralFlower 0.7.1) as app resources, each re-verified by SHA-256
at load time (not just trusted because it's in the bundle) against the hash
recorded when they were downloaded from GitHub releases.

Mitigations actually in place for the risks called out above:
- **SHA-256 re-check at load**, independent of the one done at download
  time — catches bundle corruption or a build-pipeline mistake, not just a
  bad download.
- **Package sanity checks before touching the device**: identity string
  must parse as `model_digits`, and the raw package must contain the
  literal `"FELUCCA-LOADER-1"` marker — rejects anything that isn't a real
  Felucca-family package before any SysEx is sent.
- **Model match check**: the connected device's model (via `modelOf`,
  loader-prefix-stripped) must match the package's model before Check even
  starts.
- **`UIApplication.isIdleTimerDisabled`** during the whole install, so
  auto-lock/display-sleep can't interrupt it on its own — directly for the
  risk flagged from the Chrome-tab-backgrounding observation (a backgrounded
  Chrome tab's JS paused mid-install, stalling the device for 5+ minutes;
  confirmed this applies to iOS too, likely worse, since an app that's
  actually backgrounded — not just locked — gets suspended by the OS within
  seconds unless it declares a background mode, which this app doesn't).
- **UI-level backgrounding warning**: `ContentView` watches `scenePhase`
  and raises a persistent "do not trust the device, check manually" banner
  if the app left the foreground while `FirmwareInstaller.phase.isActive`.
  This can't prevent the suspension itself — only `isIdleTimerDisabled`
  does that, and only for auto-lock, not a manual home-swipe or incoming
  call — so this is a "tell the user something may have gone wrong,"
  not a "prevent it," mitigation.
- **No cancel button once Check starts.** The confirmation dialog is the
  only off-ramp; once accepted, the only way out is letting the serve loop
  finish, fail, or time out on its own, same as the Python CLI.

Each failure path surfaces distinctly (lost/stopped-responding/bad-request,
loader-never-appeared, device-never-came-back, post-write identity
mismatch) rather than a single generic error, so a failed attempt says
something actionable about where it failed.

**Tested against real hardware — confirmed working, including recovery
from an interrupted write.** First attempt (CoralFlower → X0X, iPad 6th
gen + Lightning Camera Adapter): Check phase completed cleanly (17 sparse
validation reads, not a full scan — Check only touches specific offsets),
loader appeared and was detected correctly, Write started and served 2
reads successfully, then the loader's MIDI port genuinely vanished from
CoreMIDI's device enumeration (confirmed via logging: device count dropped
from 3 to 2, not just a stale reference) — a real USB-level disconnect, not
a bug in the Swift port. This happened at the identical read count on a repeat attempt too, which
first looked like it argued against a settle-time explanation (a pure
timing issue felt like it should be more random) and for something
deterministic in the loader's own firmware — e.g. a bootloader blocking
USB interrupt handling while actually erasing/programming a flash page.

**That theory turned out to be wrong, or at least incomplete.** Fixed by
`FirmwareInstaller.writeWithRetries()` automatically retrying the Write
pass (re-discovering the loader, resending `UPGRADE`) if it drops early —
confirmed on hardware to reliably succeed on the second attempt, giving a
working single-button-press install. But the real fix turned out to be
simpler: the delay between seeing `FINISH_CHECK` and looking for the
loader (`install()`, the `.waitingForLoader` step) was only 3s. Bumping it
to 5s didn't change anything; bumping it to **10s eliminated the failure
entirely** — first Write attempt now completes cleanly every time, no
retry needed. So it really is a one-time settle delay after the reboot
into the loader, just a longer one than seemed reasonable to guess at
upfront (the loader answering 2 real read/response round-trips before
dropping out past 3s/5s makes more sense in hindsight if whatever it's
settling — flash controller init, USB re-enumeration completing — finishes
asynchronously sometime in that 5-10s window regardless of host traffic).
`writeWithRetries()` is kept as a safety net regardless, since nothing
guarantees 10s is enough on every unit/cable/host combination.

Critically, **the device did exactly what the safety net is supposed to
do**: after the interrupted write it was left parked in the Felucca update
loader (identity `ota-FM-1_900`), not bricked, not stuck — a black screen
while idle in loader mode turned out to just be normal, not a bad sign.
Retrying the install with the FM-1 still in that state worked exactly as
intended: the app detected it was already talking to the loader and
skipped straight to Write (no need to redo Check), served the full image
(1147 reads for ~609KB) to completion, and the device rebooted reporting
`FM-1_9010202` — an exact match for the package's own embedded identity
string. Full round trip, end to end, confirmed on real hardware.

Added along the way, now part of the app: unbuffered stdout (`setvbuf` in
`FM1FlasherApp.init()`) so `print()` logging actually appears live when
streamed via `devicectl --console` instead of sitting in a buffer, and
much more detailed logging throughout `FirmwareInstaller` (phase
transitions, every served read in chunks, and critically, distinguishing
*why* a connection was considered lost — CoreMIDI reporting the device
offline vs. an actual `MIDISend` failure — which is what made diagnosing
the above possible at all).

**If a first-attempt failure recurs anyway** (different unit, cable, or
host), the app already handles it correctly regardless: `writeWithRetries()`
resumes from the loader automatically, no data loss, no user action beyond
the original single button press.

## Firmware catalog expanded to 20

Added 18 community firmwares to `FirmwareCatalog.swift`, alongside the
original X0X 1.2.2 and CoralFlower 0.7.1: Sloop, Jiant FM, Skiff, OberVave,
Zen-1, Dub-1, Hyp-1, Niagra Drift, FoMni, FiMba-1, FuMi-1, Tuna, X0X-RMX,
No Man Sky FM, GuitChordi, Bytemania, XMOD, Satie-1.

Source: thefirmwarehub.com publishes `/catalog.json`, a CC-BY-4.0-licensed
data file (distinct from `/api/convert/library`, which is for the site's
*VST-conversion* feature and serves `.wasm`/`.aot` bundles, not FM-1
packages) with a `pkg` field per firmware pointing at the actual `.fwsc`
and a `sha256` to verify it against. This is the real source for Jiant FM
and HYP-1 too — neither has a GitHub Release, but the hub builds and
serves their packages itself from the upstream repo's code. All 18 were
downloaded from `thefirmwarehub.com/fw/<id>-<version>.fwsc` and verified
against the catalog's published SHA-256 before being added to the bundle
(same re-verification at load time as the original two, via
`FirmwareCatalog.load`).

Two ambiguous names from the user's request were resolved against the
catalog/hub listing: "OverVave" is actually "OberVave" (zvenson), and
"FoMini" is "FoMni" by Charles Vestal (`charlesvestal/fm1-fomni`), not the
similarly-named "FMini-1" by Ruppert — confirmed with the user.

Confirmed on real hardware: Dub-1 installed cleanly on the iPad via the
expanded picker.

## Future improvement (not blocking): identity lookup against thefirmwarehub.com

[thefirmwarehub.com/kb/#ids](https://thefirmwarehub.com/kb/#ids) maintains a
live, human-curated table of every known firmware's identity string (~140
entries), each flagged `own` (unique) or `shared` (several firmwares report
the same string — e.g. `FM-1_900` alone is shared by ~20 different
firmwares). Not relevant to *what's currently running* on the FM-1 before an
install — that's just informational. But it would genuinely matter for the
write-flow's own post-install verification step (confirming the identity
read back after a flash matches what was actually installed, per the
"Two distinct phases" section above) if we ever want a human-readable name
rather than a bare `FM-1_900`-style string.

No scraping for this: if the app ever ships, reach out to the hub's
developer for an API/JSON endpoint rather than depending on page structure.
