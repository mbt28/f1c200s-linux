# Wired CarPlay: MUSB silently drops bulk-OUT packets in DMA mode

**Status 2026-08-07: RESOLVED (cause found, permanent fix still to write).**

The cause is the shared FIFO datapath, not the mux endpoint. With MUSB DMA
enabled the controller completes bulk-OUT transfers that the device never
receives: userspace gets a full byte count, no error, and the iPhone reports
usbmux sequence gaps. usbmux has no retransmission, so one silent drop desyncs
the link permanently and the session dies at `carkit open failed`.

Booting with **`musb_hdrc.use_dma=0`** (PIO only -- `musb_core.c` gates
`musb_dma_controller_create()` on that parameter) eliminates the loss entirely,
and a complete wired CarPlay session then works: carkit TLS iAP2 channel up,
iAP2 link NORMAL, MFi authentication, hardware H.264.

Mechanism, in one line: `VEND0` bit 0 (`BUS_SEL`) is a GLOBAL mux between CPU
and DMA access to a single shared FIFO RAM, and per both vendor manuals "any
operation of FIFO ports by CPU host is unpredictable" while it is 1. Our DDMA
backend guards this by masking MUSB interrupts, which only stops
interrupt-context FIFO ops -- a bulk-OUT URB submitted from PROCESS context
(`musb_urb_enqueue` -> `musb_schedule` -> `musb_start_urb` -> `musb_ep_program`
-> `musb_write_fifo`) walks straight past the guard while a cdc_ncm RX DMA owns
the datapath. `musb->lock` does not help: the DMA is asynchronous, so BUS_SEL
stays 1 long after the lock that started it was dropped.

See `musb-suniv-hardware-facts.md` for the register-level evidence, including
Allwinner's own admission that hardware CPU/DMA arbitration exists only on later
ICs than this one, and `musb-dma-fix-plan.md` for the plan to re-enable DDMA
safely — which starts by measuring whether PIO is fast enough that we should
simply delete the DMA backend.

The rest of this document records the investigation that got here -- what was
ruled out and, importantly, the measurement mistake that produced two false
"fixed" conclusions. Both are still worth reading before touching this area.

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

## Endpoint count: revised 2026-08-07

The 0022 row above says "correct per the User Manual". That is still the best
evidence for the F1C200s specifically, but the F1C600 manual documents the SAME
block with 4 TX + 4 RX and 4 KB of FIFO RAM (vs 3+3 and 2 KB here). So this IP
ships in several strap configurations and mainline's 5 matches none of them.
Keep 0022, but treat the count as documented-not-proven --
`musb-suniv-hardware-facts.md` has the full variant table and the reason the
silicon cannot be interrogated (EPINFO/RAMINFO are not in the relocated sunxi
register map, and CONFIGDATA returns a hardcoded 0xde).

## Open question: app or host? -- ANSWERED

Every measurement so far drives the mux through FastCarPlay, which cannot
distinguish "the host controller will not service the endpoint" from "the app is
asking wrongly". The app-side notes report a standalone usbfs probe that **did**
get VERSION replies with ipheth unbound; the equivalent through the app gets
nothing. That contradiction is the most valuable thing left to resolve.

`cp-mux-probe` (package/cp-mux-probe) answered this: with the app stopped it
claims the mux interface, sends a usbmux VERSION packet and gets a valid 20-byte
reply on the FIRST read, with usb0 up and ipheth bound. So the host path was
never broken and the mux was never starved -- which is what redirected the
investigation to the OUT direction and found the real bug.

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
