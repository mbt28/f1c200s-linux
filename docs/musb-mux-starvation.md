# Wired CarPlay: the usbmux bulk-IN endpoint returns nothing

Status 2026-08-06: **unresolved.** Three hypotheses tested and refuted on
hardware. This records what is measured, what is ruled out, and the one
measurement mistake that produced two false "fixed" conclusions -- so nobody
repeats it.

## The symptom

Wired CarPlay needs the iPhone's usbmux bulk-IN endpoint (interface 1, ff/fe,
EP 0x85) to answer while cdc_ncm's `usb0` is up -- the iAP2 control channel runs
over the mux for the whole session while AV runs over `usb0`. The mux is polled
and returns **zero bytes, indefinitely**. The app stalls at
`carkit open failed (paired? unlocked?)`.

Everything else on the board is confirmed working: kernel 6.18.42, `usb0` up
with carrier and an `fe80::` address from a cold boot, MFi 3.0 on `/dev/i2c-0`,
`:7000` listening, `cp-usbmux: usbmux up for <serial> (config 6)`, phone
enumerated **directly** (never test through a hub -- see below).

## Measure it correctly

The `musb_urb_rx` tracepoint fires on every RX **interrupt/retry**, not once per
URB completion. Counting raw `musb_urb_rx` lines therefore produces numbers far
larger than the submissions, which is impossible for real completions and is a
sign the metric is wrong -- not that the endpoint is busy.

```sh
T=/sys/kernel/tracing
# WRONG -- counts retries, reports thousands while nothing is transferred
grep -c 'musb_urb_rx.*ep5in,' $T/trace
# RIGHT -- real completions only
grep 'musb_urb_rx.*ep5in,' $T/trace | grep -vc 'status -115'
```

`status -115` is `-EINPROGRESS`. In every failing run so far **100 % of ep5in
events carry `status -115` and `len 0/…`**: reads posted, nothing returned.

Two conclusions in this project were drawn from the raw count (`enq 65 /
rx 2473`, `enq 64 / rx 2347`) and were wrong. Sanity rule: **`rx` can never
exceed `enq`.** If it does, fix the metric before believing the result.

## Ruled out on hardware

| hypothesis | patch | result |
| --- | --- | --- |
| MUSB advertises endpoints the SoC lacks | 0022 (3 TX + 3 RX) | no change; 0 real completions |
| cdc_ncm's 5 posted RX URBs starve the mux | 0021 (`usbnet.rx_qlen_max`) | no change; also inert -- ipheth is not a usbnet driver |
| ipheth's posted RX URB holds the endpoint | 0023 (`ipheth_kill_urbs` on close) | no change, bound **or** unbound |

The ipheth test was controlled: same app process throughout, no
re-enumeration, only the binding differing.

```
BOUND, eth0 down:  real_completions=0  nonzero_len=0  retries=1852
ipheth UNBOUND:    real_completions=0  nonzero_len=0  retries=1707
usb0: up in both
```

Keep 0022 anyway -- it is correct per the F1C200s User Manual V1.2 section 7.7.2
("TX Endpoint 1/2/3 and RX Endpoint 1/2/3", corroborated by the DMA request
lines in 7.7.3.1) and the driver still declares five of each in mainline and in
linux-7.1.y. 0023 fixes a genuine URB leak (an RX URB outliving the netdev being
down) and is defensible upstream on its own merits. Neither fixes this.

## Open question: app or host?

Every measurement so far drives the mux through FastCarPlay, which cannot
distinguish "the host controller will not service the endpoint" from "the app is
asking wrongly". The app-side notes report a standalone usbfs probe that **did**
get VERSION replies with ipheth unbound; the equivalent through the app gets
nothing. That contradiction is the most valuable thing left to resolve.

`cp-mux-probe` (package/cp-mux-probe) exists for this: it claims the mux
interface itself, sends a usbmux VERSION packet and reports whether the phone
replies, with no app involved.

```sh
killall fastcarplay          # the app holds the interface via usbfs
cp-mux-probe                 # -t timeout_ms  -r reads  -s readsize
```

- **Replies** -> the host path is fine and the problem is in how the app uses
  the endpoint (read size, timeout, claim order). Redirects the work to the app.
- **No reply** -> the host genuinely cannot service it, and the remaining
  suspects are MUSB scheduling and the phone's own preconditions for serving
  usbmux.

Note the pair record lives in `/var/lib/lockdown` on the rootfs, so **every
reflash wipes it** and the phone must trust the board again.

## Also worth doing, on separate evidence

`musb_host.c` returns `-ESHUTDOWN` on `MUSB_RXCSR_H_ERROR` ("three-strikes"),
assuming the device is gone. Observed with the phone attached and healthy: a mux
read failed with `ESHUTDOWN` right after a three-strikes, and the next read on
the same endpoint returned a valid 20-byte VERSION packet. `-EPROTO`, or a
bounded retry, is the accurate behaviour -- `-ESHUTDOWN` tells class drivers to
stop resubmitting for good. Lower priority: it costs a retry, it does not block
the session.

## Do not re-investigate

- **USB hubs.** Behind a Fresco Logic hub every interface showed `rx_bytes=0`
  plus three-strikes errors. Always attach the phone directly.
- **Pairing/Trust, the MFi chip, endpoint addresses, mux framing** -- all
  verified fine app-side.
- **NetworkManager.** Cannot help: the problem is at USB-driver binding level,
  taking an interface down does not release a posted URB, and NM would
  autoconnect and post one. It also costs tens of MB on a 64 MiB board.
