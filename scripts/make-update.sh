#!/bin/bash
# Make an update for a board running this Buildroot image (docs/ostree.md): from
# the version the board runs to the last build, as a tar file for the phone to
# hand to LEHU, which installs it with lehu-os-update. LEHU OS has the same
# script (lehu-os/scripts/make-update.sh).
#
#   scripts/make-update.sh FROM [OUT.tar]
#
# FROM is the commit the board runs ("lehu-os-update status" on the board,
# booted=), or "board" to ask the board over SSH (f1c@192.168.9.1, with
# $SSH_OPTS: LEHU OS and Buildroot have different host keys). OUT defaults to
# output/updates/buildroot-<version>-from-<commit>.tar; beside it go OUT.json
# and the folder's manifest.json, for an update server (below).
#
# The update is a small OSTree repository: the static delta from FROM to the
# branch's last commit, the delta's fallback objects (files over 4 MB that
# have no older version to diff against go whole), the two commits with
# their signatures, and the repository's summary, signed. The last commit
# must be signed (LEHU_OSTREE_SIGN_KEY, board/lctech/pi-f1c200s/ostree-image.sh);
# the summary is signed here, with the same key. Before the tar is written,
# the update is pulled the way the board pulls it, into a scratch repository
# holding FROM, with the board's checks: the signatures against the public
# key the image carries, and nothing but the delta.
#
# KEEP_WORK=1 keeps the scratch folder (the upload and the rehearsal
# repository) for a look after a failure.
#
# ostree: the build's own (host-ostree), or $OSTREE.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT=$HERE/output
REPO=${OSTREE_REPO:-$OUTPUT/ostree_repo}
BRANCH=f1c-buildroot
KEY=${LEHU_OSTREE_SIGN_KEY:-$HOME/.config/lehu-os/ostree-sign.sec}
PUB=$HERE/rootfs-overlay/usr/share/ostree/trusted.ed25519.d/lehu-os.ed25519
BOARD=f1c@192.168.9.1

[ $# -ge 1 ] && [ $# -le 2 ] || { sed -n '6,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

OSTREE=${OSTREE:-$OUTPUT/host/bin/ostree}
[ -x "$OSTREE" ] || { echo "no ostree: scripts/build.sh host-ostree, or set OSTREE" >&2; exit 1; }
ost() { "$OSTREE" "$@"; }

[ -r "$KEY" ] || { echo "no signing key: $KEY (LEHU_OSTREE_SIGN_KEY)" >&2; exit 1; }

# The two versions.
FROM=$1
if [ "$FROM" = board ]; then
	# shellcheck disable=SC2086
	FROM=$(ssh -i "$HOME/.ssh/f1c200s_dev" -o BatchMode=yes -o ConnectTimeout=10 ${SSH_OPTS:-} "$BOARD" \
		/usr/sbin/lehu-os-update status | sed -n 's/^booted=\([0-9a-f]\{64\}\)$/\1/p')
	[ -n "$FROM" ] || { echo "the board does not say which version it runs" >&2; exit 1; }
fi
FROM=$(ost --repo="$REPO" rev-parse "$FROM") || { echo "$1 is not in $REPO" >&2; exit 1; }
TO=$(ost --repo="$REPO" rev-parse $BRANCH)
[ "$FROM" != "$TO" ] || { echo "the board runs the last build already ($TO)" >&2; exit 1; }
ost --repo="$REPO" sign --verify --keys-file="$PUB" "$TO" >/dev/null \
	|| { echo "the last build $TO is not signed with the key of $PUB" >&2; exit 1; }
VERSION=$(ost --repo="$REPO" show --print-metadata-key=version "$TO" | tr -d "'")
OUT=${2:-$OUTPUT/updates/buildroot-$VERSION-from-${FROM:0:7}.tar}
echo "update: $FROM -> $TO, version $VERSION"

# The delta, made again each time: its output (on stderr) names the
# fallback objects. Parts of 4 MB (ostree's default is 32): the board
# unpacks each part whole, into a temporary file and through xz's
# dictionary, which both grow with the part. With 32 MB parts an OS update
# ran the board out of memory (2026-11-08, docs/ostree.md).
GEN=$(ost --repo="$REPO" static-delta generate --max-chunk-size=4 --from="$FROM" --to="$TO" 2>&1)
FALLBACK=$(sed -n 's/^fallback for \([0-9a-f]\{64\}\) .*/\1/p' <<<"$GEN")
ost --repo="$REPO" summary -u --sign-type=ed25519 --sign="$(cat "$KEY")"

# The upload's repository. Delta paths use OSTree's modified base64 of the
# commits ('/' as '_', no padding).
b64() { python3 -c "import base64,sys; print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode().rstrip('=').replace('/','_'))" "$1"; }
F64=$(b64 "$FROM") T64=$(b64 "$TO")
WORK=$(mktemp -d)
[ -n "${KEEP_WORK:-}" ] && echo "work: $WORK" || trap 'rm -rf "$WORK"' EXIT
U=$WORK/upload
mkdir -p "$U/refs/heads" "$U/deltas/${F64:0:2}" "$U/delta-indexes/${T64:0:2}"
cp "$REPO/config" "$REPO/summary" "$REPO/summary.sig" "$U/"
cp "$REPO/refs/heads/$BRANCH" "$U/refs/heads/"
cp -r "$REPO/deltas/${F64:0:2}/${F64:2}-$T64" "$U/deltas/${F64:0:2}/"
cp "$REPO/delta-indexes/${T64:0:2}/${T64:2}.index" "$U/delta-indexes/${T64:0:2}/"
obj() {
	mkdir -p "$U/objects/${1:0:2}"
	cp "$REPO/objects/${1:0:2}/${1:2}.$2" "$U/objects/${1:0:2}/"
}
obj "$FROM" commit
obj "$TO" commit
obj "$TO" commitmeta
[ ! -e "$REPO/objects/${FROM:0:2}/${FROM:2}.commitmeta" ] || obj "$FROM" commitmeta
for o in $FALLBACK; do obj "$o" filez; done

# The board's pull, rehearsed: a repository with FROM in it, the board's
# remote settings, the image's public key.
T=$WORK/test
ost --repo="$T" init --mode=bare-user
ost --repo="$T" pull-local "$REPO" "$FROM" >/dev/null
ost --repo="$T" remote add --no-gpg-verify --set=sign-verify=true --set=sign-verify-summary=true \
	--set=verification-ed25519-file="$PUB" up "file://$U" $BRANCH
PULL=$(ost --repo="$T" pull --require-static-deltas up $BRANCH 2>&1) \
	|| { echo "$PULL" | tail -3 >&2; echo "the update does not pull: not written" >&2; exit 1; }
[ "$(ost --repo="$T" rev-parse up:$BRANCH)" = "$TO" ]
ost --repo="$T" fsck -q >/dev/null || { echo "the pulled version does not check: not written" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
tar -c -f "$OUT.new" -C "$U" --owner=0 --group=0 .
mv "$OUT.new" "$OUT"
echo "written: $OUT ($(du -k "$OUT" | cut -f1) KB, $(wc -w <<<"$FALLBACK") fallback objects)"

# The update's entry for an update server, OUT.json, and the folder's
# index, manifest.json: every update there, for LEHU's Settings > Update.
# A board takes the entry whose "from" is the commit it runs. NOTES, if
# set, is a line for the screen.
python3 - "$OUT" "$VERSION" "$TO" "$FROM" "${NOTES:-}" <<'PY'
import hashlib, json, os, sys, glob, time
out, version, to, frm, notes = sys.argv[1:6]
h = hashlib.sha256()
with open(out, "rb") as f:
    for b in iter(lambda: f.read(1 << 20), b""):
        h.update(b)
entry = {"version": version, "commit": to, "from": frm,
         "file": os.path.basename(out), "size": os.path.getsize(out),
         "sha256": h.hexdigest(), "notes": notes,
         "made": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
with open(out + ".json", "w") as f:
    json.dump(entry, f, indent=1)
folder = os.path.dirname(out)
updates = []
for j in sorted(glob.glob(os.path.join(folder, "*.tar.json"))):
    e = json.load(open(j))
    if os.path.exists(os.path.join(folder, e["file"])):
        updates.append(e)
with open(os.path.join(folder, "manifest.json.new"), "w") as f:
    json.dump({"format": 1, "branch": "f1c-buildroot", "updates": updates}, f, indent=1)
os.replace(os.path.join(folder, "manifest.json.new"), os.path.join(folder, "manifest.json"))
PY
echo "manifest: $(dirname "$OUT")/manifest.json"
