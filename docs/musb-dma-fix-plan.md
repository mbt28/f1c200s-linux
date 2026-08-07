# Plan — serialising the suniv MUSB shared FIFO datapath

Status: **PLAN**, 2026-08-07. Kernel 6.18.42, Lctech Pi F1C200s.

Supersedes the cooperative-deferral approach in
`musb-datapath-serialization-roadmap.md` §2; that document's reference survey,
reproducer and parking notes (§4, §7) are still current. Companions:
`musb-suniv-hardware-facts.md` for the register-level evidence, and
`musb-mux-starvation.md` for the investigation that found the bug.

Spot-checked against source before committing: `sunxi_musb_ops` overrides
neither `read_fifo` nor `write_fifo`; `musb_default_read_fifo`/`write_fifo` are
`static` at `musb_core.c:314/359`; all four sunxi accessors already carry the
`addr == mregs + 0x80` branch; `musb_host.c:864` gates the RX-DMA branch on
`is_cppi_enabled || tusb_dma_omap`; and `TXPKTRDY` appears **zero** times in
patch 0016 while `musbhsdma.c:363` sets it explicitly.

---

## 1. The fix in one paragraph

The F1C200s has one FIFO RAM and one global mux bit (`VEND0.BUS_SEL`, `mregs+0x43`) that decides whether the CPU or the DDMA may touch it, and no hardware arbiter — Allwinner's own BSP says arbitration only arrived in 1667/1673-class silicon. Every attempt to *stop* CPU FIFO accesses from happening has failed, because they arrive from hardirq, from softirq (`ipheth_tx`/`usbnet_start_xmit` submit with `GFP_ATOMIC` from `ndo_start_xmit` — verified), and from process context, and no interrupt mask or context test reaches all three. So stop trying: **let the CPU take the datapath back instead.** Install a gate at the small number of chokepoints through which *all* CPU access to the FIFO RAM already funnels — `musb->io.read_fifo`/`write_fifo` (which sunxi does not override today, so they are free) and the `addr == mregs + 0x80` branch that already exists in all four sunxi register accessors — and have that gate, when a DDMA owns `BUS_SEL`, spin on the engine's live residue until it has retired, write `VEND0 = 0`, and only then let the CPU store proceed. Nothing is ever deferred, queued, masked or re-driven, so there is no restart edge, no lost-kick class of bug, and no dependence on the still-unresolved question of whether `INTRTX` status latches independently of `INTRTXE`. The whole interrupt-masking guard is deleted. TX-DMA and ep0 stay on PIO permanently.

---

## 2. Where the board actually is today

`board/lctech/pi-f1c200s/uboot-sdcard.fragment` already ships `musb_hdrc.use_dma=0`. **The board is correct right now and CarPlay works.** Everything below is optional performance work on top of a working baseline. That framing matters for every go/no-go decision in this plan — if the measurement in Stage 0 says PIO is fast enough, the correct engineering outcome is to delete `sunxi_dma.c` and stop, and that is a legitimate result, not a failure.

---

## 3. The mechanism, precisely

### 3.1 State

All of it in `struct sunxi_dma_controller` (`drivers/usb/musb/sunxi_dma.c`), plus a file-scope singleton pointer mirroring the existing `static struct musb *sunxi_musb` precedent in `sunxi.c`:

```c
struct sunxi_fifo_arb {
	struct sunxi_dma_channel *owner;  /* NULL == CPU owns the FIFO RAM */
	bool  disabled;                   /* sticky kill switch, boot-lifetime */
	/* counters, debug build only */
	u32 grants, refusals, reclaims_fifo, reclaims_csr, timeouts, violations;
	u32 spin_iters_max;
};

struct sunxi_dma_channel {
	...
	u32  gen;        /* ++ on every arm and on every kill */
	u32  cur_len;
	dma_cookie_t cookie;
};
```

`struct sunxi_dma_controller` also gains `rx_channel[3]` replacing the `rx_channel`/`tx_channel` singleton pair. The singleton is a real bug today: the core caches `hw_ep->rx_channel` for a whole qh lifetime, so whichever IN endpoint enumerates first (plausibly cdc_ncm) keeps the only channel forever and the video IN endpoint never gets DMA at all.

Deleted: `saved_intrtxe`, `saved_intrrxe`, `intr_masked`, `tx_channel`, `sunxi_dma_rx_mask_others()`, `sunxi_dma_rx_unmask_others()`, `sunxi_dma_is_compatible()` (dead — `musb_host.c` never calls it; only `musb_gadget.c:48` does).

**Lock: `musb->lock`, and only `musb->lock`.** Every reader and writer of `arb` already runs under it. Ordering is `musb->lock → vchan->vc.lock` (`dmaengine_tx_status` with non-NULL state takes `vc.lock`); the reverse never occurs because virt-dma splices `desc_completed` under `vc.lock`, **drops it**, and only then invokes callbacks. Put that sentence in a comment above the gate — it is the non-obvious invariant a reviewer will look for.

### 3.2 The gate

```c
/* musb->lock held. Never sleeps. CONTEXT-AGNOSTIC — hardirq, softirq,
 * BH-disabled and task context all take the identical path. */
void sunxi_musb_fifo_sync(bool from_csr)
{
	struct sunxi_dma_controller *c = READ_ONCE(sunxi_dmac);
	struct sunxi_dma_channel *ch;
	struct dma_tx_state st;
	int i, zero = 0;

	if (!c || likely(!(ch = c->arb.owner)))
		return;                          /* fast path: 1 load, 1 branch */

	for (i = 0; i < SUNXI_SYNC_MAX_US; i++) {          /* hard cap 200 */
		if (dmaengine_tx_status(ch->dma_chan, ch->cookie, &st)
		     == DMA_COMPLETE || st.residue == 0) {
			if (++zero < 2) { cpu_relax(); continue; }  /* 2 in a row */
			udelay(sunxi_sync_slack_us);                /* default 2 */
			sunxi_fifo_release(c, ch);   /* writeb(0, +0x43); owner=NULL */
			from_csr ? c->arb.reclaims_csr++ : c->arb.reclaims_fifo++;
			return;
		}
		zero = 0;
		udelay(1);
	}
	/* engine wedged: loud, bounded, and we take the FIFO anyway */
	dev_err_ratelimited(dev, "DDMA ep%d stuck; forcing PIO for this boot\n", ...);
	c->arb.timeouts++;
	ch->gen++;                                   /* kills the pending callback */
	dmaengine_terminate_async(ch->dma_chan);
	ch->channel.status = MUSB_DMA_STATUS_BUS_ABORT;
	sunxi_fifo_release(c, ch);
	c->arb.disabled = true;                      /* no more DMA this boot */
}
```

Why residue is the right signal, verified in `sun4i-dma.c`: `__execute_vchan_pending()` leaves the in-flight promise on `contract->demands`; `sun4i_dma_tx_status()` sums the demands and then *replaces the first entry's length with the live `SUN4I_DDMA_BYTE_COUNT_REG`* (configured `BYTE_COUNT_MODE_REMAIN`), so residue tracks hardware progress in real time. Only the end-IRQ moves the promise to `completed_demands` and NULLs `vchan->pchan`, after which residue reads 0 regardless of whether `vchan_cookie_complete()` has run. So the gate does **not** depend on the DDMA IRQ, the vchan tasklet, or a cookie update — none of which can run while we spin with IRQs off on the only core. That is what makes the spin terminate. It waits on a bus master that needs no CPU help; for an RX-DMA the bytes are already in the FIFO (`length = rx_count`, ≤512), so it is a ~2 µs drain.

The `zero < 2` double-read and the `sunxi_sync_slack_us` knob exist because nothing in the tree has ever read this counter and we cannot prove from source that it retires *after* the last AHB burst rather than when it is issued. See §8 Q1 — the knob is also the experiment.

### 3.3 Where the gate is installed — six places, all already sunxi-owned

| Site | Covers |
|---|---|
| `sunxi_musb_write_fifo()` / `sunxi_musb_read_fifo()` installed into `musb->io` | **100 % of CPU FIFO data-port traffic** — `musb_host.c:489, 828, 832, 995, 1034, 1448, 1452`, all gadget sites, `musb_core.c:587`. sunxi overrides neither today (verified in `sunxi_musb_ops`), so they are free real estate. |
| `sunxi_musb_readb/writeb/readw/writew`, in the existing `addr == mregs + 0x80` branch | **every** endpoint CSR access — all 11 `FLUSHFIFO`/`TXPKTRDY`/`RXPKTRDY` sites Phase 1 enumerated, plus `MUSB_RXCOUNT`/`MUSB_COUNT0` (which Phase 1 could only classify NEEDS-CHECK). All four accessors already have that branch; it is a one-line insertion each. |
| `sunxi_musb_writeb/writew`, generic window, **only** for `MUSB_TXFIFOSZ/TXFIFOADD/RXFIFOSZ/RXFIFOADD` | `musb_restore_context()` reprogramming the FIFO-RAM allocation from runtime PM without `musb->lock`. Do **not** gate the rest of the generic window — the ISR reads `INTRTX`/`INTRRX` there on every interrupt. |

Gating all four accessors rather than only `writew` is the judge-C fix, and it is what turns the correctness claim from *"I enumerated every FIFO-touching site in musb_host.c"* (a claim that decays with every rebase) into *"sunxi's accessor table is complete and the core cannot reach the FIFO port or the ep register window except through it"* — checkable by reading one struct in one file. `musb_readl`/`musb_writel` are not platform-overridable, but they are also unreachable on sunxi (they would bypass the register remapping entirely and be broken with or without DMA); note it in a comment.

`musb_default_read_fifo`/`musb_default_write_fifo` are `static` in `musb_core.c`, so patch 0024 un-statics and exports them. That patch stands alone and is independently upstreamable ("let glue layers reuse the default FIFO accessors" — `tusb6010.c:1200` currently has to duplicate them).

### 3.4 Process-context and softirq submissions

They are **not** deferred, rejected, queued or restarted. They wait ~2 µs and proceed inline:

```
usb_submit_urb        (usbfs thread, OR ipheth_tx from NET_TX softirq, OR usbnet_bh)
  musb_urb_enqueue                    musb_host.c:2113
    musb_schedule → musb_start_urb    :2109
      musb_ep_program                 :670
        musb_h_tx_flush_fifo          :741  → gated via writew(+0x80)
        musb_write_fifo               :832  → gated via io.write_fifo
        musb_h_tx_start               :157  → gated via writew(+0x80)
```

There is deliberately **no context test anywhere in this design.** That is not an aesthetic choice: `ipheth_tx` is `.ndo_start_xmit` and calls `usb_submit_urb(GFP_ATOMIC)`, and `usbnet` does the same from `usbnet_bh` — so any design keyed on `in_interrupt()` either corrupts (skips the wait) or hard-hangs the only core (spins in softirq waiting for a tasklet). Because the gate waits only on hardware, every context is safe and identical.

Cost, stated plainly: the submitter eats up to one FIFO drain with `musb->lock` held and IRQs off. This is *less* than what ships today — stock `musb_h_tx_flush_fifo()` spins `1000 × mdelay(1)` = up to one second in exactly those conditions, and it only ever spun because `FIFONOTEMPTY` will not clear while `BUS_SEL` is held.

### 3.5 ep0

ep0 needs no special case and cannot be starved. It has no DRQ line and is never a DMA candidate (`channel_allocate()` rejects `epnum < 1`; `hcd->self.uses_pio_for_control = 1`), so it is only ever a *consumer* of the gate, never a holder — there is no path by which ep0 waits on itself. All four ep0 touchpoints land on the gate: the SETUP load (`musb_start_urb` → `musb_ep_program` → `musb_write_fifo` at `:832`), the data stages (`musb_h_ep0_continue` `:995`/`:1034`), `musb_h_ep0_flush_fifo()` `CSR0 = FLUSHFIFO` at `:133`, and `musb_h_tx_start()`'s `CSR0 = SETUPPKT|TXPKTRDY` at `:160`. Worst-case added latency: 200 µs (the cap), typical ~2 µs, against USB control timeouts of 5 s. The `dev_WARN_ONCE` at `musb_host.c:146` also stops firing spuriously.

As a **Stage-1-only** extra belt, `channel_program()` refuses while `!list_empty(&musb->control)` (module param `dma_block_on_ctrl`, default 1). It makes the enumeration argument a single sentence during bring-up. Relax to 0 in Stage 2 once `reclaims_*` shows the gate working.

### 3.6 Concurrent DMA requests

One token, one holder, loser silently runs PIO — using the only veto musb offers a host-side backend:

```c
static int sunxi_dma_channel_program(...)
{
	sunxi_reclaim_if_done(c);            /* NON-blocking: never spin here */
	if (c->arb.disabled || c->arb.owner) { c->arb.refusals++; return 0; }
	if (ch->is_tx || mode != 0) return 0;
	if (dma_block_on_ctrl && !list_empty(&musb->control)) return 0;
	if (len < 512 || (len & 3) || (dma_addr & 3) || (packet_sz & 3)) return 0;
	...prep_slave_sg...
	ch->cookie   = dmaengine_submit(desc);
	desc->callback_param = (void *)(uintptr_t)((epnum << 24) | (++ch->gen & 0xffffff));
	sunxi_fifo_take(c, ch);              /* VEND0 = (drq<<1)|BUS_SEL; owner = ch */
	dma_async_issue_pending(ch->dma_chan);
	c->arb.grants++;
	return 1;
}
```

`VEND0` **must** be written before `dma_async_issue_pending()` — `sun4i_dma_issue_pending()` synchronously calls `__execute_vchan_pending()` → `configure_pchan()`, which writes `SUN4I_DDMA_CFG_REG` and starts the engine inside that call. (This explicitly overrules one judge's suggestion to reorder; the code says otherwise.) The whole claim-arm sequence is inside one `musb->lock` critical section with IRQs off, so no CPU op can observe the intermediate state.

Returning 0 makes `musb_rx_dma_in_inventra_cppi41()` (`musb_host.c:1687-1700`) release the channel, clear `DMAENAB|H_AUTOREQ|AUTOCLEAR`, and fall through to PIO — **which is why patch 0018 hunk 1 is load-bearing and must be kept.** Without it the caller's stale `dma` local skips the `if (!dma)` PIO block and the packet is dropped. That is a genuine upstream bug (no in-tree backend ever refuses, which is why it survived) and is worth submitting on its own.

Structural fact that shortens the whole argument: on sunxi, `channel_program()` is reachable from **exactly one place**. `musb_ep_program()`'s RX-DMA branch is gated by `if ((is_cppi_enabled(musb) || tusb_dma_omap(musb)) && dma_channel)` (`musb_host.c:864`) — neither is true for sunxi — so the process-context RX program path is dead, and with TX-DMA removed `musb_tx_dma_program()` is dead too. Assert it: `WARN_ON_ONCE(!in_hardirq())` in `channel_program()`.

### 3.7 Completion, abort, and the stale-callback hole

```c
static void sunxi_dma_callback(void *param)
{
	u8 ep  = (uintptr_t)param >> 24;
	u32 gen = (uintptr_t)param & 0xffffff;
	ch = &c->rx_channel[ep - 1];

	spin_lock_irqsave(&musb->lock, flags);
	if ((ch->gen & 0xffffff) != gen)  goto out;   /* killed or superseded */
	if (c->arb.owner == ch) sunxi_fifo_release(c, ch);  /* if not already stolen */
	dmaengine_tx_status(ch->dma_chan, ch->cookie, &st);
	channel->actual_len = ch->cur_len - st.residue;     /* NOT cur_len */
	channel->status = MUSB_DMA_STATUS_FREE;
	musb_dma_completion(musb, ep, 0);
out:	spin_unlock_irqrestore(&musb->lock, flags);
}
```

Three things this fixes, all raised by judges and all real:

* **A stolen-but-successful transfer still completes.** The gate reclaims the *datapath*; it never calls `musb_dma_completion()` itself (that would re-enter `musb_host_rx` from inside `musb_ep_program`). Keying the callback on generation rather than on ownership is what stops an eager reclaim from silently dropping a URB.
* **A killed transfer can never over-report.** `sun4i-dma` implements no `.device_synchronize`, so `dmaengine_terminate_async()` leaves a window; the generation check closes it, and residue-derived `actual_len` closes the second half. Today `actual_len = cur_len` unconditionally, and the core consumes it directly (`musb_host_tx`: `qh->offset += dma->actual_len`; `musb_cleanup_urb`: `urb->actual_length += dma->actual_len`) — an inflated length on a link with no retransmission is exactly the failure signature we are trying to eliminate.
* **`channel_abort()` actually aborts.** The core sets `dma->status = MUSB_DMA_STATUS_CORE_ABORT` *before* calling it at four sites (`musb_host.c:941, 1266, 1831, 1861` — and patch 0022 makes `musb_bulk_nak_timeout` routine on this board), so the inherited `if (status == BUSY)` body is dead on every core-initiated abort: `dmaengine_terminate_all()` never runs while the URB buffer goes back to the class driver. Key on ownership and `gen` instead, and order it `terminate → gen++ → release → then touch CSRs`, so the gate's fast path sees `owner == NULL` and cannot re-enter. Add the missing `musb_ep_select()` before the TXCSR/RXCSR access (sunxi is `MUSB_INDEXED_EP` and `ep_offset()` returns a constant 0x80, so `epio` aliases every endpoint).

### 3.8 Other backend fixes folded in (all prerequisites, not nice-to-haves)

`channel_release()` terminates + clears `hw_ep`; `BUG_ON` → `WARN_ON_ONCE + return 0`; `channel->max_len` clamped to the engine's real `dma_get_max_seg_size()` instead of `SZ_16M`; `controller_create()` returns `ERR_PTR(-EPROBE_DEFER)` rather than NULL (the core only handles `IS_ERR`); a `dma_get_slave_caps()` probe check that fails to PIO if the engine ever reports `DMA_RESIDUE_GRANULARITY_DESCRIPTOR` or no `cmd_terminate`, turning the design's one hard dependency into an enforced contract; `pm_runtime_get_noresume()` for the DMA backend's lifetime so `musb_save/restore_context()` cannot race (the board is mains-powered in a car).

---

## 4. What stays PIO forever

* **ep0 / all control traffic** — hardware: the DRQ mux has lines only for TX EP1-3 and RX EP1-3. Not a policy, a fact.
* **All bulk-OUT / TX** — a deliberate, permanent scope cut. TX-DMA has never worked: `sunxi_dma_callback()` never sets `TXPKTRDY` (which `musbhsdma.c:dma_controller_irq()` does explicitly), so a 512-byte OUT lands on mode 0 with `AUTOSET` cleared and hangs until the class driver times out — matching the `LIBUSB_ERROR_TIMEOUT` in patch 0018's own commit message. The TX `DRQ_SEL` encoding is disputed between patch 0016's BSP formula (TX 0/2/4) and patch 0022's manual citation (TX 0/1/2), under which 0016's TX ep3 value aliases RX ep1. And OUT is the direction that is silently losing data. Delete the `is_tx` half of `sunxi_dma_drq_sel()` so the unverified value can never be programmed. **Do not revive this.**
* **Every transfer < 512 B, misaligned, or arriving while the token is held.**

---

## 5. Staged implementation

### Stage 0 — make the baseline honest, and decide whether to continue *(ship immediately; no new patches)*

**Do:** trim `0018-musb-host-suniv-dma-rx-fallback-and-tx-flush.patch` to hunk 1 only. Delete hunk 2 (the bounded 4-retry TX flush: it returns with `FIFONOTEMPTY` still set and `TXPKTRDY` armed over stale bytes — a data-integrity hazard in its own right — and being a build-time `#if` it *also* modified the `use_dma=0` "proven-safe PIO baseline", so every A/B measurement this workstream has ever taken was against non-stock code). Delete hunk 3 (raw `writeb(0, musb->mregs + 0x43)` in `musb_cleanup_urb()`, a hardcoded sunxi offset in a file linked into eight glues, which never did what its comment claimed since `channel_abort()` cleared VEND0 unconditionally a few lines earlier). Keep `musb_hdrc.use_dma=0`. Add the 2-line bounds check to 0019 (`if (pchan_idx >= priv->cfg->dma_nr_max_channels) continue;` — bit 24 indexes past the end of an 8-entry array on suniv).

**Files:** `patches/linux-lctech/0018-*.patch` (−78), `0019-*.patch` (+3).

**Then measure, before writing a line of Stage 1.** Fixed 60 s CarPlay video plus a `dd` from a USB stick: record `/proc/stat` system+irq time, `/proc/interrupts` deltas, and the RT aa-read thread's `utime/stime` from `/proc/<pid>/stat`. (No `perf stat` cycles — ARM926EJ-S is ARMv5 with no PMU; Linux has no ARMv5 perf backend and you will get `<not supported>`.) A 512-byte `ioread32_rep` is ~128 load/store pairs, maybe 1.5-3 µs; one DDMA arm costs a `prep_slave_sg` (contract + promise allocation), submit, issue, a DDMA hardirq, a vchan tasklet, and the claim/release bookkeeping. **These are plausibly the same order of magnitude.**

**Exit criterion / GO-NO-GO:** if PIO leaves adequate headroom for the video stream, **stop here, delete `sunxi_dma.c`, remove patches 0016/0017/0019 and the two DMA Kconfig lines, and close the workstream.** That is a good outcome and it costs one boot argument to reach.

**What could go wrong:** removing hunk 2 restores the stock `1000 × mdelay(1)` flush spin. With `use_dma=0` that loop never spins (nothing holds `BUS_SEL`), which is exactly the point — but watch for it if you ever boot `use_dma=1` before Stage 1 lands.

---

### Stage 1 — the arbiter, with DMA still off by default *(independently shippable, behaviour-identical to Stage 0 unless enabled)*

**New patches:**

* `0024-musb-core-allow-glue-layers-to-reuse-the-default-fifo-accessors.patch` — un-`static` `musb_default_read_fifo`/`musb_default_write_fifo` (`musb_core.c:314/359`), `EXPORT_SYMBOL_GPL`, prototypes near `musb_core.h:496`. **+4 / −2.** The only core file touched, mechanical, independently upstreamable.
* `0025-musb-sunxi-serialise-the-shared-fifo-datapath.patch` — `sunxi.c`: the two `musb->io` FIFO hooks, the `+0x80` gate in all four accessors, the FIFO-RAM-alloc-register gate in the generic window, ops wiring. New `sunxi_dma.h` with the `sunxi_musb_fifo_sync()` prototype and an empty static inline under `#if !IS_ENABLED(CONFIG_USB_SUNXI_DMA)`. **~+55 / −0.** (Note: `sunxi_dma.o` links into `musb_hdrc` while `sunxi.c` is `musb_sunxi`, so `sunxi_musb_fifo_sync()` must be non-static + exported, or move `sunxi_dma.o` into the sunxi module. Confirm the Makefile hunk in 0016 during implementation.)
* **`0016` rewritten in place** — everything in §3.1, §3.6, §3.7, §3.8. Roughly **+230 / −130**; `sunxi_dma.c` goes 485 → ~540 lines but *loses* the interrupt guard entirely. Ships with `sunxi_dma.enable=0` and `dma_block_on_ctrl=1`.
* **`0017` modified** — one `dmas` entry (`dma-names = "usb"`), one channel reconfigured per direction; move the property from `suniv-f1c100s.dtsi` to the board `.dts`, matching what 0014 already does correctly for spi1. **~+6 / −8.** This also removes the sun4i-dma hazard of two vchans sharing dedicated endpoint 4, and halves DDMA pchan pressure ahead of `feature/spi-ddma-ahb`.
* `linux.fragment` — add `CONFIG_USB_SUNXI_DMA_DEBUG` for the counters/knobs.

**Total shared-core footprint: ~14 lines** (`musb_core.c` +4/−2, `musb_core.h` +2, `musb_host.c` +8/−2 of which 6 are a comment and the rest is a genuine upstream bug fix unrelated to sunxi). Compare the ~90 lines of sunxi-specific logic currently sitting in `musb_host.c`.

**What could go wrong:** (a) the fast-path NULL guard is missing and `use_dma=0` oopses on the first FIFO write — put `if (!sunxi_dmac) return;` first and test that boot before anything else; (b) `channel_abort()` re-enters the gate through a CSR write — enforce the release-before-CSR ordering and comment it, or someone will "clean it up"; (c) the `+0x80` gate accidentally covers `MUSB_INDEX` (it does not — INDEX is in the generic window) or the ISR's `INTRTX` reads (it must not).

**Exit criterion:** with `sunxi_dma.enable=0`, byte-identical behaviour to Stage 0 across a 30-minute CarPlay session; `violations == 0`; boot with `use_dma=0` and `use_dma=1 enable=0` both clean.

---

### Stage 2 — turn RX-DMA on *(independently shippable)*

**New patch:**

* `0026-dma-sun4i-complete-finished-contracts-before-acquiring-a-pchan.patch` — in `__execute_vchan_pending()`, hoist the `list_empty(&contract->demands)` completion check above `find_and_use_pchan()`. Today a finished contract's `vchan_cookie_complete()` is skipped when the DDMA pool is exhausted, so the callback is never delivered. **~+20.** Genuine upstream bug, independently submittable, latent until `feature/spi-ddma-ahb` adds DDMA clients.

Flip `sunxi_dma.enable=1`, run the full validation in §6, then consider `dma_block_on_ctrl=0` if `reclaims_*` and the ep0 oracle look healthy.

**What could go wrong:** DDMA pchan exhaustion (4 pchans, shared with the SPI workstream) means `find_and_use_pchan()` returns `-EBUSY`, residue never falls, and the gate runs to the 200 µs cap → one aborted transfer, a loud `dev_err`, `disabled = true`, PIO for the rest of the boot. Bounded and visible, not silent — but it is the one path where this design degrades rather than merely slows. `timeouts > 0` names it immediately.

---

### Stage 3 — hardening / tighten the window *(optional; only if Stage 0 said DMA pays)*

Add `sun4i_dma_hw_state(chan, *residue)` to `sun4i-dma.c` exposing `SUN4I_DDMA_CFG_BUSY` (BIT(30), defined at `sun4i-dma.c:85` and used by nothing in the tree) so the gate can require `!BUSY && residue == 0` and drop `sunxi_sync_slack_us` to 0. **~+52.** Not upstreamable as an `EXPORT_SYMBOL_GPL` reaching into a pchan; downstream-only, or propose a generic `device_hw_idle()` op. Worth doing only if Q1 (§8) shows the slack is actually needed and you want the microseconds back.

---

### Stage 4 — mode-1 / multi-packet RX DMA: **recommended NOT to do**

This is the only lever that would materially increase bytes-per-claim, and it is structurally incompatible with reclaim-on-touch. The gate reclaims only when the engine has *retired*; a multi-packet mode-1 DMA is paced by the device on the wire, so the token can be held for ~1 ms, and a CPU FIFO op arriving in that window would spin to the 200 µs cap and abort a healthy transfer. Preempting instead is not available — `sun4i-dma` implements neither pause nor resume, and clearing `BUS_SEL` mid-flight is already hardware-observed to destroy the RX stream (the re-enumeration storm, commit `2c6e60d`). **The performance ceiling of this design is one 512-byte packet per claim.** If Stage 0's measurement says per-packet DMA is a wash, that ceiling is the answer, and the honest conclusion is Stage 0's exit: ship PIO.

---

## 6. Validation

### The evidence standard, and why the obvious signal is useless here

`trace_musb_urb_rx`/`trace_musb_urb_tx` in this kernel fire from `musb_host_rx()`/`musb_host_tx()` **once per interrupt**, not once per URB completion. A multi-interrupt URB produces several events; `status = -115` is `-EINPROGRESS`, i.e. "still running", not an error. So a raw event count measures interrupt rate, and — critically — **a bulk-OUT whose FIFO store vanished looks byte-for-byte identical in the trace to one that reached the device**: `TXPKTRDY` was set, the core advanced, the URB completed with the full length. Trace counts cannot detect this bug and must not be cited as evidence.

What counts as proof, in descending order:

1. **`violations` == 0** — a counter + `WARN_ONCE` in the two `musb->io` FIFO hooks and in each `+0x80` accessor gate, incremented if entered with `readb(mregs+0x43) & BIT(0)` still set *after* the sync. This is a direct detector of the defect, not a proxy.
2. **`reclaims_fifo > 0` AND `reclaims_csr > 0`** — proof the gate is load-bearing on *both* surfaces. Split counters matter: break the CSR gate and a single combined counter stays healthy while 11 hazard sites silently reopen.
3. **Byte-exact oracles**, not liveness: `md5sum` over a multi-GB `dd` in both directions on a USB stick; a golden `GET_DESCRIPTOR` captured once at `use_dma=0` and diffed every iteration under the ep0 hammer; the iPhone's own usbmux sequence-gap reports ("Expected 16 received 18") logged read-only from the FastCarPlay side.
4. If you want URB-level truth, enable `CONFIG_USB_MON` temporarily and read `/sys/kernel/debug/usb/usbmon/0u` — not the musb tracepoints.

Also: `debugfs` is not auto-mounted on this image. Mount it from the init script, or expose the counters as read-only module params under `/sys/module/musb_hdrc/parameters/` (`sunxi_dma.o` links into `musb_hdrc`). Measure `spin_iters_max` by counting `udelay(1)` iterations, not by reading a clocksource from hardirq. Replace `WARN_ONCE`'s stack dump on the hot path with a counter plus a deferred one-shot `printk_deferred` — 200 ms of blocking printk over a 115200 serial console will kill the session it is diagnosing.

### THE NEGATIVE TEST (run this first, before trusting any green run)

`sunxi_dma.unsafe_no_sync=1`, present only under `CONFIG_USB_SUNXI_DMA_DEBUG`, makes `sunxi_musb_fifo_sync()` return immediately — reinstating exactly today's unguarded behaviour with everything else intact.

* `unsafe_no_sync=1` → the ep0 hammer + concurrent bulk-IN reproducer **must** go back to **6/6 corrupt** and `violations` must climb within seconds.
* `unsafe_no_sync=0` → **0/N corrupt**, `violations == 0`, `reclaims_fifo > 0`, `reclaims_csr > 0`, `timeouts == 0`.

**A test that cannot fail is not a test.** If the `=1` run does not reproduce the corruption, the harness is not exercising the race and the passing run proves nothing. CI must assert the *pair*, plus `reclaims_* > 0` — because a future refactor that moves a FIFO op outside the gated accessor set collapses `reclaims` toward 0, which trips CI even on a run where corruption happens not to reproduce.

Second injection knob, and the highest-value addition to the plan: **`sunxi_dma.inject_hold_us=N`** holds `BUS_SEL` for N µs *after* hardware completion. At `N=100` the exclusion window widens from ~2 µs to ~100 µs, so the reclaim path is taken on essentially every FIFO op instead of by luck — which is what turns a 30-minute soak on one board into real coverage of the steal path, the ownership handoff, and the stale-callback generation checks.

### Test list

* **T1** boot matrix: `use_dma=0`; `use_dma=1 enable=0`; `use_dma=1 enable=1`. All three reach userspace and enumerate.
* **T2** ep0 hammer (the 6/6 reproducer): `GET_DESCRIPTOR` at ~1 kHz from libusb concurrently with a bulk-IN DMA stream, diffed against the golden descriptor, 10 min. Then repeat under `inject_hold_us=100` and under `unsafe_no_sync=1`.
* **T3** bulk-OUT integrity under RX-DMA: `dd` ≥1 GiB each direction on a USB stick + `md5sum`. Report the achieved transfer count as the confidence bound — "0/6" is not a result. One round with `CONFIG_DMA_API_DEBUG=y`.
* **T4** three concurrent IN endpoints (iAP2 mux IN + cdc_ncm bulk IN + cdc_ncm interrupt IN, the patch-0022 ftrace scenario) — exercises `refusals` hard.
* **T5** teardown races: `usb_kill_urb` mid-DMA ×100, cable yank ×50, bind/unbind, `usb_set_interface`. Checks the `CORE_ABORT` fix and the generation-check. Watch `/proc/interrupts` for musb still climbing.
* **T6** softirq submitter coverage — **mandatory, not optional**: concurrent cdc_ncm/`iperf` traffic while an RX-DMA streams. This is the only test that exercises `ipheth_tx`/`usbnet_start_xmit` (`GFP_ATOMIC`, softirq), the context that broke three of the four candidate designs.
* **T7** 30-minute wired CarPlay, zero usbmux sequence gaps, ×3, one with a mid-session replug.
* **T8** the Stage-0 A/B re-run with DMA on: `use_dma=0` vs `enable=1`. Report `grants`, `refusals/(grants+refusals)`, `reclaims_*`, `spin_iters_max`. Predictions to falsify: `spin_iters_max` ≈ single-digit µs, `timeouts == 0`. If `spin_iters_max` approaches the 200 µs cap, the termination premise is wrong somewhere — re-examine, do not raise the cap.

---

## 7. What we give up

1. **TX / bulk-OUT offload, permanently.** Nothing measurable is lost today (it never worked), but it is a capability removal and reviving it needs `TXPKTRDY`, a verified DRQ table, and a re-opened arbitration question.
2. **Concurrent DMA, ever.** One endpoint holds the engine at a time; the others run PIO. The SoC has one `usb_drq` and one FIFO port. Every workable precedent — Allwinner's own BSP, 8250, tusb6010 — enforces the same half-duplex, and Allwinner's fix for the real problem was to change the silicon (`usbc.c:597-601`: `FIFO_BUS_SEL` hardwired to 1 "in 1667 1673 and later ic"). There is no register-level workaround to find on a 1663-class part.
3. **Added interrupt latency**, paid by whoever touches the FIFO during a DMA: ~2 µs expected, 200 µs hard cap, with `musb->lock` held and IRQs off on a single 408 MHz core. Net *improvement* versus the 1000 ms flush spin it replaces, but spread across more sites.
4. **A hard dependency on live DMA residue.** Enforced at probe via `dma_get_slave_caps()`, fails safe to PIO, but this backend cannot be lifted onto an engine with `DMA_RESIDUE_GRANULARITY_DESCRIPTOR`.
5. **Peak offload under concurrent load.** A deferral design could in principle keep both engines busy. We give that up for: no state machine in `musb_host.c`, no restart edge, no watchdog on which *correctness* depends, no lost-kick failure mode, and independence from the unresolved `INTRTX`-latching question.
6. **~14 lines of shared-core divergence** to carry across rebases (two of the three hunks are independently upstreamable, so this is plausibly temporary).
7. **The possibility that all of it is unnecessary.** PIO measured ~21 Mbps on the storage test; the AA video needs a few. Stage 0 exists so that call is made with numbers.

---

## 8. Open questions that genuinely need hardware

1. **Does `SUN4I_DDMA_BYTE_COUNT_REG` reach 0 before the last AHB burst retires, or after?** Nothing in the tree has ever read `SUN4I_DDMA_CFG_BUSY`, and dmaengine exposes no idle indicator. *Experiment:* run T3 at `sunxi_sync_slack_us` = 0, 2, 8 and compare `violations` and md5 failures. If 0 differs from 2, the margin is real and you have measured a bus-timing property with a `dd` and an `md5sum`. Ship the default at 2 regardless — it is 1 % of the cap.
2. **Is a `FLUSHFIFO` under `BUS_SEL == 1` merely ineffective (`csr 2003`, observed) or actively corrupting the other endpoint's bytes?** Decides whether the CSR gate must stay as strict as the data-port gate or could be cheapened to a bounded retry. Phase 1 left this open; the plan assumes corrupting.
3. **What does one DDMA arm + completion actually cost versus a 512-byte `ioread32_rep` on this core?** The entire go/no-go. Stage 0.
4. **RX `DRQ_SEL` encoding**: patch 0016's BSP formula (RX 1/3/5) vs patch 0022's UM citation (RX 4/5/6). RX works empirically, which favours the BSP formula, but the two cannot both be literal. Only matters if RX ever misbehaves; TX is moot now.
5. **Is DDMA pchan exhaustion reachable in practice once `feature/spi-ddma-ahb` lands?** Watch `timeouts`.
6. **Can `musb_runtime_suspend/resume` fire with URBs in flight?** `pm_runtime_get_noresume()` makes it moot, but if you would rather not pin runtime PM, this needs tracing.
7. **Is `/proc/interrupts` for `1c13000` genuinely unshared?** Not load-bearing for this design (unlike the IRQ-masking alternatives), but worth confirming once.

---

## 9. One-line summary of the recommendation

Ship Stage 0 today; **measure before building anything**; if and only if DMA demonstrably pays, land Stages 1-2 as written; keep ep0 and all bulk-OUT on PIO forever; do not attempt mode-1.