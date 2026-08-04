# Project structure — target layout and development workflow

**Status: living document.** This describes where we are heading, not where we
are. It is written up front so the restructuring can happen in one deliberate
pass once a fast FastCarPlay build loop exists, rather than drifting.

**How this file changes:** Claude proposes improvements in conversation; the
owner decides; accepted items land here. Nothing gets restructured directly
off a suggestion — this file is the agreed plan, and the code follows it.

Analysis date: 2026-08-04. Anything marked *observed* was measured in the repo
at that date, not assumed.

---

## 1. The problem this is solving

*Observed:* there is no local Buildroot output tree, so **every change — including
a one-line app fix — costs a 25-30 min CI build plus a card swap and reboot.**
That is the dominant cost of development, and it is independent of how the repos
are laid out.

Second-order problems, all observed:

- **FastCarPlay has no CI, no tests and no CLAUDE.md** (276 files, ~46.6k LOC),
  and it is the fastest-moving component. Three bugs that cost board time in one
  session were pure logic, catchable off-hardware in seconds:
  `mfi-i2c-bus` defaulting to `/dev/i2c-1` which does not exist on this board;
  the MFi presence check using a write probe the chip NAKs (so a working chip
  reads as absent); and error strings that *guess* rather than report
  (`:7000 (already running?)`, `carkit open failed (paired? unlocked?)`).
- **Images are not reproducible.** `FASTCARPLAY_VERSION` resolves the branch tip
  at build time, so rebuilding a tag does not reproduce that tag.
- **Coupled versions are enforced only by comments.** The esp-hosted driver and
  the ESP32 firmware do a strict handshake; `config.env` says so in prose.
  Separately `CEDAR_REF="master"` points at the *unported* cedar driver while
  the 6.18/7.x-ready commits sit on the `kernel-7.1` branch.
- **The ESP32 firmware is not version controlled** — the bundles exist only on
  the maintainer's disk, with hand-written READMEs as the sole build record.

---

## 2. Fast development loop (do this first)

Dropbear is already in the image (`BR2_PACKAGE_DROPBEAR=y`) and
`rootfs-overlay/etc/init.d/S41eth-dev` already brings up `eth0` on the RTL8153
USB NIC for exactly this purpose — its own comment says it exists to "scp
cedrus.ko + ssh-run tests without reflashing the SD card". That path is built
and unused.

Target loop:

```
edit app  ->  make fastcarplay-rebuild  ->  scp to board  ->  restart  ->  read log
                     ~30 s                      ~2 s          ~5 s
```

About a minute instead of thirty, with no card handling. Buildroot's
`make sdk` produces a relocatable toolchain+sysroot, so FastCarPlay can also be
cross-built standalone without Buildroot in the loop. Buildroot's
`<pkg>-rebuild` / `<pkg>-reconfigure` targets are the per-package entry points.

**Reserve CI images for integration and release, not iteration.**

---

## 3. Where knowledge lives

| Kind | Goes in | Loaded |
|---|---|---|
| Invariants, safety rules, conventions | `CLAUDE.md` | every turn |
| Procedures with non-obvious gotchas | `.claude/skills/<name>/SKILL.md` | on demand |
| Bulk reading / parallel investigation | `.claude/agents/<name>.md` | when delegated |

Rule of thumb: **knowledge -> CLAUDE.md; procedure -> skill; bulk reading ->
agent.** Safety rules must be in CLAUDE.md, not a skill — a skill only helps if
someone remembers to invoke it.

Agents earn their place when the work would otherwise swamp the main context.
Precedent: the two kernel-API research agents each consumed ~90-100k tokens of
header diffing and returned a one-page verdict.

---

## 4. Target structure

```
f1c200s-linux/                      # integrator — owns the image + release
├── CLAUDE.md                       ✓ exists
├── manifest.env                    # was config.env: pins EVERY component
├── .claude/
│   ├── skills/
│   │   ├── board-serial/           ✓ exists
│   │   ├── kernel-patch-triage/    ✓ exists
│   │   ├── image-build-flash/      # CI -> artifact -> verify -> flash (device guard)
│   │   └── kernel-config-verify/   # extract-ikconfig, assert symbols, size delta
│   └── agents/
│       └── kernel-api-delta.md     # driver + 2 kernel tags -> breakage report
├── board/ configs/ package/ patches/ rootfs-overlay/ scripts/
└── docs/
    ├── project-structure.md        ← this file
    ├── kernel-6.18-upgrade.md
    └── releases/                   # what shipped in each tag

FastCarPlay/                        # app — fastest-moving, least tooled
├── CLAUDE.md                       # ← biggest single gap
├── .claude/skills/
│   ├── crossbuild/                 # build ARMv5 against the Buildroot SDK
│   └── deploy-and-run/             # scp -> restart detached -> tail log
├── .github/workflows/build.yml     # ← none today
├── tests/                          # ← none today
├── src/ docs/ third_party/
└── settings_drm.txt settings_desktop.txt

f1c200s-esp32-firmware/             # ← untracked loose directories today
├── config/sdkconfig.defaults.esp32
├── .github/workflows/build.yml     # publishes bins + md5 as a release
└── docs/
```

### Why not a monorepo

The three components have different toolchains, CI and release cadences, and
FastCarPlay is board-independent enough to have a desktop build
(`settings_desktop.txt`). Merging would couple release cycles that should stay
separate. The integrator repo is already the right shape — it just needs to pin
its inputs properly.

---

## 5. Reproducibility: one manifest

`config.env` becomes `manifest.env` and pins **every** input: Buildroot, Linux,
U-Boot, `CEDAR_REF`, the FastCarPlay sha, the esp-hosted driver sha, and the
ESP32 firmware version + md5. Coupled pairs sit adjacent with the coupling
stated.

Policy: **branch tips on `dev`, hard shas on release tags.** That keeps daily
iteration fast while making any tag rebuildable.

---

## 6. FastCarPlay: the highest-leverage additions

1. **`CLAUDE.md`** — target is ARMv5TE soft-float, 64 MiB, no GPU, cross-compile
   only; settings-key conventions and where runtime overrides live
   (`usersettings.txt`); and the rule learned the hard way:
   **an error message must name the actual failure, never speculate.**
2. **CI** — desktop build plus an ARMv5 cross build. Catches breakage in ~3 min
   instead of ~30.
3. **Tests** — pure-logic units needing no hardware: settings parsing and merge,
   `video_path` selection, protocol framing.

---

## 7. Order of work

1. Local Buildroot output + the `crossbuild` / `deploy-and-run` skills.
2. FastCarPlay `CLAUDE.md` + minimal CI.
3. `config.env` -> `manifest.env`; pin shas on tags.
4. ESP32 firmware into version control.
5. Remaining image skills, alongside the 6.18 kernel work.

Step 1 gates the rest: once the app loop is fast, the restructuring in section 4
happens in a single pass.

---

## 8. Considered and parked

Kept so decisions are not re-litigated.

- *(nothing yet)*
