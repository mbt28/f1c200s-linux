# Development workflow: branches, CI, releases

## Branch model

| branch | purpose | rule |
|---|---|---|
| `main` | stable, releasable; every commit hardware-validated on the board | only merges from `dev` (or hotfixes), never day-to-day work; tag `vX.Y.Z` after validating |
| `dev` | integration branch — day-to-day work lands here | CI builds an image for every push; flash + smoke-test that image before promoting to `main` |
| `feature/<topic>` | larger or risky experiments (e.g. `feature/7.1-freeze-hunt`) | branch off `dev`, merge back via PR so CI gates it; delete after merge |
| `kernel-7.1` | parallel kernel track (7.1 port; open freeze regression) | not part of the stable flow; shared files (patches, overlay, board/, docs) are mirrored to it by copy + a `(kernel-7.1 mirror)` commit |

The flow:

```
feature/foo ──PR──► dev ──CI image──► flash & test on board ──merge──► main ──tag──► release
```

Rules that keep `main` trustworthy:

1. **Nothing reaches `main` without booting on real hardware.** CI proves it
   compiles; only the board proves it works (decode colour, LCD, touch,
   dongle). Test the CI/dev image first, then `git merge --ff-only dev`.
2. **Tag every validated state** (`git tag -a vX.Y.Z -m "..."` + push the
   tag): the tag triggers a CI build that attaches the flashable image to a
   GitHub Release, so any past release stays downloadable forever.
3. Small fixes may go straight to `dev`; anything touching the kernel
   patches, U-Boot, or the VE drivers deserves a `feature/*` branch + PR.

Optional but recommended — protect `main` on GitHub (blocks accidental direct
pushes; requires the CI check to pass before merging):

```sh
gh api -X PUT repos/mbt28/f1c200s-linux/branches/main/protection \
  -f 'required_status_checks[strict]=true' \
  -f 'required_status_checks[contexts][]=sdcard-image' \
  -F 'enforce_admins=false' -F 'required_pull_request_reviews=null' \
  -F 'restrictions=null'
```

## CI: GitHub Actions builds the image for you

`.github/workflows/build-image.yml` runs the exact same
`scripts/fetch-sources.sh` + `scripts/build.sh` flow as a local build, on
every push to `main`, `dev`, `kernel-7.1`, every `v*` tag, and every PR into
`main`/`dev`. Docs-only pushes (`docs/**`, `*.md`) are skipped. You can also
start a run by hand: repo → Actions → build-image → "Run workflow".

- **Where the image is**: the run's page → Artifacts →
  `sdcard-<branch>` (an `.img.xz`; `xz -d` it, then `dd` as usual).
  Artifacts live 30 days. Tagged builds are also attached permanently to the
  GitHub Release for that tag.
- **Speed**: the first run on a fresh cache compiles the whole toolchain
  (~2.5–3.5 h on the free 4-vCPU runner — the repo is public, so minutes are
  free). Two caches make later runs fast: `buildroot/dl` (source tarballs)
  and a Buildroot ccache. A kernel-or-rootfs-only change typically rebuilds
  in well under an hour.
- **ccache is CI-only**: the workflow appends `BR2_CCACHE=y` to the generated
  `.config` after applying the defconfig, so the board defconfig stays clean.
- The job summary page shows the produced images and the vmlinux size for a
  quick RAM-diet regression check.

## Releasing

```sh
git checkout main && git merge --ff-only dev
git tag -a v0.2.0 -m "..."
git push origin main v0.2.0     # tag build attaches sdcard image to the Release
```
