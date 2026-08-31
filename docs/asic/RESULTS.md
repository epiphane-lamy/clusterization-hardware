# ASIC Flow — Results

Comparison between two floorplan iterations of the same design, `clusterization`, produced by the manual area/density optimization pass described in [`FLOW.md`](FLOW.md) §5:

- **`v0`** — the first full place-and-route pass, using Innovus's automatically sized floorplan (loose, ~7% routing density).
- **`v10`** — the final, manually tightened floorplan (74.538% routing density) after the iterative optimization pass.

Both target a **100 MHz** clock. A short exploration beyond 100 MHz is also included (§4).

---

## 1. Area

| | `v0` (loose floorplan) | `v10` (optimized floorplan) | Change |
|---|---|---|---|
| Core area | 1677.2 × 1674.28 µm² (≈ 2,808,470 µm²) | 1582.0 × 1295.61 µm² (≈ 2,049,665 µm²) | **≈ −27%** |
| Routing density | ≈ 7% | 74.538% | — |
| Total cell area (all instances) | 1,964,285.10 µm² | 1,958,440.66 µm² | ≈ −0.3% |
| Instance count | 24,170 | 23,093 | — |

The core area dropped by roughly a quarter, but the total area actually occupied by cells barely moved. That's the expected signature of a floorplan-tightening pass rather than a logic-optimization one: the same design, packed into a smaller die, with the routing-density increase (§5 of `FLOW.md`) doing the work rather than any change to the logic itself.

### 1.1 Where the area actually goes

Summing the memory-labeled instances in the area report against the design total shows that **memories account for roughly 97–98% of total cell area** in both floorplan versions:

| Block | `v0` area (µm²) | `v10` area (µm²) |
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

This is the direct explanation for §3 (power barely changes despite the area/density work): with compute logic making up only a couple of percent of total area, there simply isn't much left to optimize once the macros are accounted for. It also matches the reference model's own early warning that motivated [ADR-0002](../decisions/0002-single-row-streaming-vs-full-matrix.md) in the first place — memory footprint was always going to be the dominant cost of this design, in silicon just as much as in the original software analysis.

### 1.2 Per-block breakdown (compute logic)

For completeness, the compute-logic blocks (the remaining ≈ 2.3% of area), which did shift slightly between the two P&R runs due to re-optimization during placement:

| Block | `v0` area (µm²) | `v10` area (µm²) | Change |
|---|---|---|---|
| `exp_block` | 10,119.44 | 9,756.58 | −3.6% |
| `grad_block` | 14,652.31 | 11,102.35 | −24.2% |
| `cluster_assign` | 5,211.05 | 5,135.13 | −1.5% |
| `upd_block` | 1,454.18 | 1,266.08 | −12.9% |
| `exp_LUT` | 8,119.08 | 8,296.236 | +2.2% |
| `inv_LUT` | 4,138.20 | 4,278.42 | +3.4% |
| `P_ij_memory_arbiter` | 1,064.30 | 838.242 | −21.2% |

Some of these shifts are large in absolute terms — they are consistent with the significant reduction in the number of pins resulting from the merging of the two coordinate ports.

## 2. Timing

| | `v0` (loose floorplan) | `v10` (optimized floorplan) |
|---|---|---|
| Target frequency | 100 MHz | 100 MHz |
| Setup slack (WNS) | +0.016 ns | +0.032 ns |
| Hold slack | −0.098 ns | −0.107 ns |
| DRC | Clean | Clean |

Both floorplans meet setup at 100 MHz with a small positive margin, and both show a small hold violation. Worth noting for anyone less familiar with static timing analysis: a hold violation is **not** fixed by lowering the clock frequency the way a setup violation is — hold checks a minimum-delay requirement between register stages, independent of the clock period — so this hold number would carry over regardless of target frequency. These numbers are reported at the slow/worst-case timing corner (matching the `.lib` corner used in the power reports below); a small hold violation there, on a design whose stated goal was demonstrating a working full-custom-to-macro ASIC flow rather than a production tapeout, was accepted as a reasonable result rather than iterated on further.

## 3. Power

| | `v0` (loose floorplan) | `v10` (optimized floorplan) |
|---|---|---|
| Total power | 11.268 mW | 11.101 mW |
| Internal power | 10.355 mW (91.89%) | 10.206 mW (91.94%) |
| Switching power | 0.912 mW (8.09%) | 0.893 mW (8.04%) |
| Leakage power | 0.00164 mW (0.015%) | 0.00153 mW (0.014%) |
| Macro group share | 76.55% | 77.53% |
| Sequential group share | 10.11% | 10.03% |
| Combinational group share | 11.19% | 10.57% |
| Highest single-instance power | `upd_memory/u_ram` (`RAM_4096X32`), 2.338 mW | `upd_memory/u_ram` (`RAM_4096X32`), 2.335 mW |

Total power is essentially unchanged between the two floorplans (11.27 mW vs. 11.33 mW) — directly consistent with §1.1: since the memory macros dominate both area *and* power (≈ 76% of total power, close to their ≈ 97.6% area share), squeezing the floorplan tighter was never going to move the power number much, because it never touched the macros themselves. The single highest-power instance in both versions is the same coordinate-update memory macro (`memory_act`), reinforcing the same point.

## 4. Frequency exploration beyond 100 MHz

A brief exploration of how far the design could be pushed past the 100 MHz target:

| Target frequency | Setup slack | Hold slack |
|---|---|---|
| 100 MHz | positive (§2) | −0.098 to −0.107 ns |
| 120 MHz | +0.042 ns (passes) | −0.100 ns (fails) |
| 125 MHz | −0.037 ns (fails) | −0.128 ns (fails) |

Setup timing closed comfortably up to 120 MHz (DRC clean), but the existing hold violation persists (as expected, since hold doesn't improve with a faster clock) and setup itself breaks down by 125 MHz. 100 MHz was kept as the reported target for both `v0` and `v10` above; this exploration is noted here as a data point on the design's headroom, not as a change to either reported configuration.

## 5. Layout views

See [`FLOW.md`](FLOW.md) §5 for the amoeba and congestion views referenced during the area-optimization discussion above.
