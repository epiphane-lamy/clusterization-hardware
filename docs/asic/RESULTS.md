# ASIC Flow — Results

Results across the two architecture generations documented in [`ARCHITECTURE.md`](../ARCHITECTURE.md) and their respective ADRs:

- **v1** ([ADR-0003](../decisions/0003-ping-pong-buffering.md)) — the ping-pong buffered architecture. `v1.0` is the first full place-and-route pass (Innovus's automatic floorplan sizing, ~7% routing density); `v1.10` is the final, manually tightened floorplan (74.538% density) after the iterative optimization pass described in [`FLOW.md`](FLOW.md) §5.
- **v2** ([ADR-0008](../decisions/0008-on-the-fly-dual-exp-pipeline.md)) — the on-the-fly, duplicated-`exp`-pipeline architecture, with the `P_ij` ping-pong buffers and arbiter removed. `v2.0` is the first full place-and-route pass on this architecture; `v2.3` is the final, with manually tightened floorplan and gating memory (see [`FLOW.md`](FLOW.md) §6 and [ADR-0010](../decisions/0010-cen-gating-memory-macros.md)).

All configurations target a **100 MHz** clock unless noted otherwise (v1's frequency exploration, §1.4; v2, §2.4).

---

## Headline: v1.10 vs. v2.3

| Metric | `v1.10` (ping-pong, ADR-0003) | `v2.3` (on-the-fly, ADR-0008 & gating memory ADR-0010) | Change |
|---|---|---|---|
| Core area | 1582.0 × 1295.61 µm² (≈ 2,049,655 µm²) | 796.0 × 1979.8 µm² (≈ 1,575,920 µm²) | **≈ −23%** |
| Routing density | 74.538% | 89.582% | +15 pp |
| Total cell area | 1,958,440.66 µm² | 1,509,895.65 µm² | **≈ −23%** |
| Setup slack (WNS) | +0.032 ns | **+0.694 ns** | ≈ 22× more margin |
| Hold slack | −0.107 ns | −0.094 ns | slightly better |
| Total power | 11.101 mW | 10.653 mW | **≈ −4%** |

Removing the `P_ij` ping-pong buffers and arbiter in favor of a duplicated `exp` compute pipeline (ADR-0008) delivers the area reduction that ADR predicted, and by a comfortable margin: it estimated roughly 460,000 µm² saved (≈480,000 µm² of removed buffer/arbiter area, against an estimated ≈20,000 µm² of added pipeline/LUT duplication); the measured reduction is ≈448,000 µm², in the same ballpark, but for a more favorable reason than expected — see §2.1.2, the actual cost of duplicating the `exp` pipeline itself turned out much smaller than the ADR's estimate, even though duplicating `exp_LUT` cost almost exactly what was predicted.

The setup-timing jump (+0.032 ns → +1.159 ns, roughly 36× more margin) is the most striking number here — well beyond what the area reduction alone would suggest, and related to the buffer/arbiter logic removed by ADR-0008 having been a timing bottleneck in v1. Hold slack, which doesn't respond to area/logic changes the same way setup does, stays essentially flat.

Total power drops only modestly (≈4%) despite the large area reduction, since v2 removes memory (low activity, but large static/leakage-adjacent internal power) and adds flip-flops (the duplicated pipeline stages, which toggle every cycle) — see §2.2 for the shift in power composition this causes.

---

## 1. v1 results (ping-pong buffered, ADR-0003)

### 1.1 Area

| | `v1.0` (loose floorplan) | `v1.10` (optimized floorplan) | Change |
|---|---|---|---|
| Core area | 1677.2 × 1674.28 µm² (≈ 2,808,470 µm²) | 1582.0 × 1295.61 µm² (≈ 2,049,655 µm²) | **≈ −27%** |
| Routing density | ≈ 7% | 74.538% | — |
| Total cell area (all instances) | 1,964,285.10 µm² | 1,958,440.66 µm² | ≈ −0.3% |
| Instance count | 24,170 | 23,093 | — |

The core area dropped by roughly a quarter, but the total area actually occupied by cells barely moved. That's the expected signature of a floorplan-tightening pass rather than a logic-optimization one: the same design, packed into a smaller die, with the routing-density increase (`FLOW.md` §5) doing the work rather than any change to the logic itself.

#### 1.1.1 Where the area actually goes

Summing the memory-labeled instances in the area report against the design total shows that **memories account for roughly 97–98% of total cell area** in both floorplan versions:

| Block | `v1.0` area (µm²) | `v1.10` area (µm²) |
|---|---|---|
| `memory_cluster` | 376,669.70 | 375,964.50 |
| `memory_P_ij_A` | 239,208.67 | 239,202.51 |
| `memory_P_ij_B` | 239,291.43 | 239,293.48 |
| `upd_memory` | 354,110.01 | 353,450.29 |
| `coord_memory_b1` | 353,616.85 | 353,791.27 |
| `coord_memory_b2` | 353,798.11 | 353,667.81 |
| **Memory subtotal** | **1,916,694.77** | **1,915,369.86** |
| **Design total** | 1,964,285.10 | 1,958,440.66 |
| **Memory share** | **≈ 97.6%** | **≈ 97.8%** |

This is the direct explanation for §1.3 (power barely changes despite the area/density work): with compute logic making up only a couple of percent of total area, there simply isn't much left to optimize once the macros are accounted for. It also matches the reference model's own early warning that motivated [ADR-0002](../decisions/0002-single-row-streaming-vs-full-matrix.md) in the first place — memory footprint was always going to be the dominant cost of this design, in silicon just as much as in the original software analysis. It's also exactly the observation that later motivated [ADR-0008](../decisions/0008-on-the-fly-dual-exp-pipeline.md): with two of these memories (`memory_P_ij_A`/`B`, ≈478,500 µm² combined) existing purely to buffer `P_ij` between `exp` and `grad`, removing them outright was always going to matter more than any further floorplan tuning could — see the v2 results in §2.

#### 1.1.2 Per-block breakdown (compute logic)

For completeness, the compute-logic blocks (the remaining ≈ 2.3% of area), which did shift slightly between the two P&R runs due to re-optimization during placement:

| Block | `v1.0` area (µm²) | `v1.10` area (µm²) | Change |
|---|---|---|---|
| `exp_block` | 10,119.44 | 9,756.58 | −3.6% |
| `grad_block` | 14,652.31 | 11,102.35 | −24.2% |
| `cluster_assign` | 5,211.05 | 5,135.13 | −1.5% |
| `upd_block` | 1,454.18 | 1,266.08 | −12.9% |
| `exp_LUT` | 8,119.08 | 8,296.24 | +2.2% |
| `inv_LUT` | 4,138.20 | 4,278.42 | +3.4% |
| `P_ij_memory_arbiter` | 1,064.30 | 838.24 | −21.2% |

Some of these shifts are large in absolute terms — consistent with the significant reduction in pin count resulting from merging the two coordinate ports.

### 1.2 Timing

| | `v1.0` (loose floorplan) | `v1.10` (optimized floorplan) |
|---|---|---|
| Target frequency | 100 MHz | 100 MHz |
| Setup slack (WNS) | +0.016 ns | +0.032 ns |
| Hold slack | −0.098 ns | −0.107 ns |
| DRC | Clean | Clean |

Both floorplans meet setup at 100 MHz with a small positive margin, and both show a small hold violation. Worth noting for anyone less familiar with static timing analysis: a hold violation is **not** fixed by lowering the clock frequency the way a setup violation is — hold checks a minimum-delay requirement between register stages, independent of the clock period — so this hold number would carry over regardless of target frequency. These numbers are reported at the slow/worst-case timing corner (matching the `.lib` corner used in the power reports below); a small hold violation there, on a design whose stated goal was demonstrating a working full-custom-to-macro ASIC flow rather than a production tapeout, was accepted as a reasonable result rather than iterated on further.

### 1.3 Power

| | `v1.0` (loose floorplan) | `v1.10` (optimized floorplan) |
|---|---|---|
| Total power | 11.268 mW | 11.101 mW |
| Internal power | 10.355 mW (91.89%) | 10.206 mW (91.94%) |
| Switching power | 0.912 mW (8.09%) | 0.893 mW (8.04%) |
| Leakage power | 0.00164 mW (0.015%) | 0.00153 mW (0.014%) |
| Macro group share | 76.55% | 77.53% |
| Sequential group share | 10.11% | 10.03% |
| Combinational group share | 11.19% | 10.57% |
| Highest single-instance power | `upd_memory/u_ram` (`RAM_4096X32`), 2.338 mW | `upd_memory/u_ram` (`RAM_4096X32`), 2.335 mW |

Total power is essentially unchanged between the two floorplans (11.27 mW vs. 11.10 mW) — directly consistent with §1.1.1: since the memory macros dominate both area *and* power (≈77.5% of total power, close to their ≈97.6–97.8% area share), squeezing the floorplan tighter was never going to move the power number much, because it never touched the macros themselves. The single highest-power instance in both versions is the same coordinate-update memory macro (`upd_memory`), reinforcing the same point.

### 1.4 Frequency exploration beyond 100 MHz

A brief exploration of how far `v1.10` could be pushed past the 100 MHz target:

| Target frequency | Setup slack | Hold slack |
|---|---|---|
| 100 MHz | +0.032 ns | −0.107 ns |
| 120 MHz | +0.042 ns (passes) | −0.100 ns |
| 125 MHz | −0.037 ns (fails) | −0.128 ns |

Setup timing closed comfortably up to 120 MHz (DRC clean), but the existing hold violation persists (as expected, since hold doesn't improve with a faster clock) and setup itself breaks down by 125 MHz. This exploration is noted here as a data point on v1's headroom, not as a change to the reported `v1.0`/`v1.10` configurations above.

---

## 2. v2 results (on-the-fly, duplicated `exp` pipeline, ADR-0008)

### 2.1 Area

| | `v2.0` (loose floorplan) | `v2.3` (optimized floorplan & CEN) | Change |
|---|---|---|---|
| Core area | 796.0 × 2009.82 µm² (≈ 1,599,817 µm²) | 796.0 × 1979.8 µm² (≈ 1,575,920 µm²) | **≈ −1.5%** |
| Routing density | 74.121% | 89.582% | +15.461 pp |
| Total cell area (all instances) | 1,510,207.56 µm² | 1,509,895.65 µm² | ≈ same |
| Instance count | 32,465 | 32,790 | +1% |

Interesting contrast with v1: **instance count went up** (23,093 → 32,465) while **total area went down**. Consistent with the trade made in ADR-0008 — the removed `P_ij` buffers were few in number but individually enormous, while the duplicated `exp` pipeline adds a large number of individually small flip-flops and gates. We can also observe that adding the gating memory slightly increases the instance count between v2.0 and v2.3.

#### 2.1.1 Where the area actually goes

| Block | `v2.0` area (µm²) | `v2.3` area (µm²) |
|---|---|---|
| `memory_cluster` | 397,066.58 | 397,399.0 |
| `upd_memory` | 353,393.18 | 353,399.68 |
| `coord_memory_b1` | 353,587.44 | 353,711.582 |
| `coord_memory_b2` | 353,654.13 | 353,657.204 |
| **Memory subtotal** | **1,457,701.32** | **1,458,167.466** |
| **Design total** | 1,510,207.56 | 1,509,895.65 |
| **Memory share** | **≈ 96.5%** | **≈ 96.6%** |

Memory's share of total area drops slightly compared to v1 (≈97.6–97.8% → ≈96.5%) — expected, since removing the `P_ij` buffers removes memory area specifically, while the duplicated `exp` pipeline and second `exp_LUT` port add to the logic side instead.

#### 2.1.2 Per-block breakdown (compute logic), and closing the loop on ADR-0008's open question

| Block | `v1.10` area (µm²) | `v2.0` area (µm²) | Change |
|---|---|---|---|
| `exp_block` | 9,756.58 | 11,263.09 | +15.4% |
| `grad_block` | 11,102.35 | 11,029.16 | ≈ −0.7% |
| `cluster_assign` | 5,135.13 | 5,390.95 | +5.0% |
| `upd_block` | 1,266.08 | 1,321.49 | +4.4% |
| `exp_LUT` | 8,296.24 | 16,233.37 | **+95.7%** |
| `inv_LUT` | 4,278.42 | 4,121.10 | −3.7% |
| `P_ij_memory_arbiter` | 838.24 | *(removed)* | — |

This directly answers the open question flagged in ADR-0008's "negative/limits" section: whether the second `exp_LUT` read port would cost close to a full duplicate of the LUT's area. It essentially did — **+95.7%, almost exactly double**.

The other half of the estimate went the other way, though: ADR-0008 budgeted roughly +10,000 µm² for duplicating the `exp` compute pipeline itself, but the actual cost was only **+1,506 µm² (+15.4%)** — far cheaper than a naive doubling, likely because much of `exp`'s area is the LUT interface and control logic rather than the arithmetic datapath, and only the datapath needed a true second instance. `grad_block` stayed essentially flat despite losing its entire control FSM (ADR-0008), suggesting that the computing pipeline accounted for most of grad_block's area (see `grad_block_v2.md` §4).

Net effect: the real "duplication tax" (`exp_block` + `exp_LUT` combined delta) is about **+9,443 µm²**, close to ADR-0008's ~20,000 µm² estimate's lower half, not its full amount — one of the reasons the overall area win came in as strong as it did.

### 2.2 Timing

| | `v2.0` | `v2.3` |
|---|---|---|
| Target frequency | 100 MHz | 100 MHz |
| Setup slack (WNS) | +1.159 ns |  +0.694 ns |
| Hold slack | −0.098 ns |  −0.094 ns |
| DRC | Clean | Clean |


See the Headline section above for discussion of the large setup-margin jump versus v1.

### 2.3 Power

| | `v2.0` | `v2.3` |
|---|---|---|
| Total power | 10.653 mW | ≈ same |
| Internal power | 9.552 mW (89.67%) |≈ same |
| Switching power | 1.099 mW (10.31%) | ≈ same |
| Leakage power | 0.00213 mW (0.020%) | ≈ same |
| Macro group share | 66.56% | ≈ same |
| Sequential group share | 17.40% | ≈ same |
| Combinational group share | 12.68% | ≈ same |
| Highest single-instance power | `upd_memory/u_ram` (`RAM_4096X32`), 2.353 mW | same |


The composition shift here is the interesting part, more than the modest total reduction: the macro group's share of total power drops sharply (v1.10: 77.53% → v2.0: 66.56%), while the sequential group's share more than doubles (10.03% → 17.40%). This is exactly the memory-for-flip-flops trade ADR-0008 describes — removing the `P_ij` buffer macros lowers memory's dominance of the power budget, while the duplicated `exp` pipeline's extra registers (toggling every cycle during a sweep) pick up a meaningfully larger share than before. The single highest-power instance is still the same coordinate-update memory macro (`upd_memory/u_ram`) as in v1, essentially unchanged in absolute power (2.335 mW → 2.353 mW) — consistent with that specific memory not having changed at all between v1 and v2.

#### 2.3.1 Qualitative assessment of CEN gating, and closing the loop on ADR-0010's open question

The open question raised by ADR-0010 was whether gating the memory macros' CEN signals provides a meaningful power benefit in practice. A direct quantitative answer could not be obtained from report_power (See [ADR-0010](../decisions/0010-cen-gating-memory-macros.md)).

The benefit was therefore assessed qualitatively by measuring, over a representative benchmark run, how many clock cycles each memory remained enabled compared with the total computation time. The benchmark required 80,149,050 clock cycles to complete, giving the following results:

| Memory | Enabled cycles | Share of total computation |
|---|---|---|
| `coord_memory_b1` | 80,149,050 | 100.0% |
| `coord_memory_b2` | 80,070,972 |  99.9% |
| `upd_memory` | 80,070,972 |  99.9% |
| `memory_cluster` | 78,080 | 0.1% |

These measurements confirm that the four gating windows behave as intended, but they also show that their potential impact during active computation is highly uneven. `coord_memory_b1` is enabled for the entire computation. `coord_memory_b2` and `upd_memory` are enabled for 99.9% of the computation and therefore offer essentially no meaningful opportunity for power reduction during an active benchmark run. In contrast, `memory_cluster` is enabled for only 0.1% of the total computation time, meaning that its CEN gating provides a substantial idle window and is clearly beneficial during active computation.

This answers ADR-0010's open question in two parts. During active computation, CEN gating is highly effective for `memory_cluster`, but provides little opportunity for the other three memories because they are required for almost the entire run. The more important benefit of the mechanism, however, is expected when the chip is powered but not actively computing. During such standby or idle periods, all four memories can remain disabled instead of being permanently enabled, potentially reducing their leakage consumption significantly. The exact magnitude of this saving cannot be quantified with the current memory libraries because their .lib files do not characterize leakage power.

### 2.4 Frequency exploration

A brief exploration of how far `v2.3` could be pushed past the 100 MHz target:

| Target frequency | Setup slack | Hold slack |
|---|---|---|
| 100 MHz | +0.694 ns | −0.094 ns |
| 140 MHz | +0.034 ns (passes) | −0.104 ns |
| 145 MHz | −0.136 ns (fails) | −0.100 ns |

Setup timing closed comfortably up to 140 MHz (DRC clean), but the existing hold violation persists (as expected, since hold doesn't improve with a faster clock) and setup itself breaks down by 145 MHz. This exploration is noted here as a data point on v2's headroom, not as a change to the reported `v2.0`/`v2.3` configurations above.

---

## 3. Layout views

See [`FLOW.md`](FLOW.md) §5 (v1) and §6 (v2) for the amoeba and congestion views referenced above.
