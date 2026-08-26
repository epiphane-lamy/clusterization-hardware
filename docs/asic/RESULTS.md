# ASIC Flow — Results

Comparison between two floorplan iterations of the same design, `clusterization`, produced by the manual area/density optimization pass described in [`FLOW.md`](FLOW.md) §5:

- **`v0`** — the first full place-and-route pass, using Innovus's automatically sized floorplan (loose, ~7% routing density).
- **`v7`** — the final, manually tightened floorplan (74.309% routing density) after the iterative optimization pass.

Both target a **100 MHz** clock. A short exploration beyond 100 MHz is also included (§4).

---

## 1. Area

| | `v0` (loose floorplan) | `v7` (optimized floorplan) | Change |
|---|---|---|---|
| Core area | 1677.2 × 1674.28 µm² (≈ 2,808,470 µm²) | 1582.0 × 1299.79 µm² (≈ 2,056,067 µm²) | **≈ −27%** |
| Routing density | ≈ 7% | 74.309% | — |
| Total cell area (all instances) | 1,964,285.10 µm² | 1,962,221.13 µm² | ≈ −0.1% |
| Instance count | 24,170 | 24,580 | — |

The core area dropped by roughly a quarter, but the total area actually occupied by cells barely moved. That's the expected signature of a floorplan-tightening pass rather than a logic-optimization one: the same design, packed into a smaller die, with the routing-density increase (§5 of `FLOW.md`) doing the work rather than any change to the logic itself.

### 1.1 Where the area actually goes

Summing the memory-labeled instances in the area report against the design total shows that **memories account for roughly 97–98% of total cell area** in both floorplan versions:

| Block | `v0` area (µm²) | `v7` area (µm²) |
|---|---|---|
| `mem_cluster` | 376,669.70 | 376,008.27 |
| `memory_P_ij` | 239,208.67 | 239,015.10 |
| `memory_P_ij_A` | 239,291.43 | 238,969.95 |
| `memory_act` | 354,110.01 | 353,975.95 |
| `memory_coord_b1` | 353,616.85 | 353,749.89 |
| `memory_coord_b2` | 353,798.11 | 353,614.11 |
| **Memory subtotal** | **1,916,694.77** | **1,915,333.27** |
| **Design total** | 1,964,285.10 | 1,962,221.13 |
| **Memory share** | **≈ 97.6%** | **≈ 97.6%** |

This is the direct explanation for §3 (power barely changes despite the area/density work): with compute logic making up only a couple of percent of total area, there simply isn't much left to optimize once the macros are accounted for. It also matches the reference model's own early warning that motivated [ADR-0002](../decisions/0002-single-row-streaming-vs-full-matrix.md) in the first place — memory footprint was always going to be the dominant cost of this design, in silicon just as much as in the original software analysis.

### 1.2 Per-block breakdown (compute logic)

For completeness, the compute-logic blocks (the remaining ≈ 2.4% of area), which did shift slightly between the two P&R runs due to re-optimization during placement:

| Block | `v0` area (µm²) | `v7` area (µm²) | Change |
|---|---|---|---|
| `bloc_exp` | 10,119.44 | 9,928.26 | −1.9% |
| `bloc_grad` | 14,652.31 | 14,117.42 | −3.7% |
| `dut_cluster_assign` | 5,211.05 | 5,137.18 | −1.4% |
| `dut_compute` (`act_coord`) | 1,454.18 | 1,454.87 | ≈ 0% |
| `exp_LUT` | 8,119.08 | 8,208.34 | +1.1% |
| `inv_LUT` | 4,138.20 | 4,276.37 | +3.3% |
| `memory_P_ij_arbitrer` | 1,064.30 | 1,106.03 | +3.9% |

None of these shifts are large in absolute terms (a few thousand µm² at most, against a ~2 million µm² design) — they're consistent with normal placement-dependent re-optimization rather than any deliberate logic change between the two runs.

## 2. Timing

| | `v0` (loose floorplan) | `v7` (optimized floorplan) |
|---|---|---|
| Target frequency | 100 MHz | 100 MHz |
| Setup slack (WNS) | +0.016 ns | +0.020 ns |
| Hold slack | −0.098 ns | −0.123 ns |
| DRC | Clean | Clean |

Both floorplans meet setup at 100 MHz with a small positive margin, and both show a small hold violation. Worth noting for anyone less familiar with static timing analysis: a hold violation is **not** fixed by lowering the clock frequency the way a setup violation is — hold checks a minimum-delay requirement between register stages, independent of the clock period — so this hold number would carry over regardless of target frequency. These numbers are reported at the slow/worst-case timing corner (matching the `.lib` corner used in the power reports below); a small hold violation there, on a design whose stated goal was demonstrating a working full-custom-to-macro ASIC flow rather than a production tapeout, was accepted as a reasonable result rather than iterated on further.

## 3. Power

| | `v0` (loose floorplan) | `v7` (optimized floorplan) |
|---|---|---|
| Total power | 11.268 mW | 11.335 mW |
| Internal power | 10.355 mW (91.89%) | 10.306 mW (90.93%) |
| Switching power | 0.912 mW (8.09%) | 1.027 mW (9.06%) |
| Leakage power | 0.00164 mW (0.015%) | 0.00162 mW (0.014%) |
| Macro group share | 76.55% | 75.92% |
| Sequential group share | 10.11% | 10.14% |
| Combinational group share | 11.19% | 12.11% |
| Highest single-instance power | `memory_act/u_ram` (`RAM_4096X32`), 2.338 mW | `memory_act/u_ram` (`RAM_4096X32`), 2.335 mW |

Total power is essentially unchanged between the two floorplans (11.27 mW vs. 11.33 mW) — directly consistent with §1.1: since the memory macros dominate both area *and* power (≈ 76% of total power, close to their ≈ 97.6% area share), squeezing the floorplan tighter was never going to move the power number much, because it never touched the macros themselves. The single highest-power instance in both versions is the same coordinate-update memory macro (`memory_act`), reinforcing the same point.

## 4. Frequency exploration beyond 100 MHz

A brief exploration of how far the design could be pushed past the 100 MHz target:

| Target frequency | Setup slack | Hold slack |
|---|---|---|
| 100 MHz | positive (§2) | −0.098 to −0.123 ns |
| 120 MHz | +0.042 ns (passes) | −0.100 ns (fails) |
| 125 MHz | −0.037 ns (fails) | −0.128 ns (fails) |

Setup timing closed comfortably up to 120 MHz (DRC clean), but the existing hold violation persists (as expected, since hold doesn't improve with a faster clock) and setup itself breaks down by 125 MHz. 100 MHz was kept as the reported target for both `v0` and `v7` above; this exploration is noted here as a data point on the design's headroom, not as a change to either reported configuration.

## 5. Layout views

See [`FLOW.md`](FLOW.md) §5 for the amoeba and congestion views referenced during the area-optimization discussion above.
