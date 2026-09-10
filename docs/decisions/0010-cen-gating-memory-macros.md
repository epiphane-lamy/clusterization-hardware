# ADR-0010 — Chip-enable (`CEN`) gating of memory macros

## Status
Accepted and implemented. Power benefit assessed qualitatively rather than via `report_power` — see Context and Consequences.

## Context

Every memory-macro wrapper in this design (`coord_mem_wrapper.md`, `pij_mem_wrapper.md`, `cluster_mem_wrapper.md`) originally tied its macro's `CEN` permanently to `0` (always enabled), each explicitly flagging this as an unexploited power-gating opportunity.

Two separate obstacles came up while trying to quantify the expected benefit, in sequence:

1. **Generic activity.** The `report_power` runs behind every number in `docs/asic/RESULTS.md` so far use a uniform, generic activity model (`Sequential Element Activity: 0.2`, `Primary Input Activity: 0.2`), not activity extracted from an actual RTL simulation. Under that model, simply gating `CEN` in the RTL and re-running `report_power` the same way would show no benefit at all, since the tool has no notion of "this macro is idle right now."
2. **No leakage data in the macro `.lib`.** To address (1), a full activity-driven power analysis was carried out — VCD generated from RTL simulation, both post-synthesis and post-layout. This resolved the *switching*-activity blind spot, but surfaced a deeper problem: the memory macros' `.lib` files provide **no leakage-power characterization at all**. `CEN` gating is specifically meant to reduce a macro's static/leakage draw while disabled — and that's exactly the number this library simply doesn't model. So even with real activity data, `report_power` has nothing to report for the benefit this ADR is after.

Given both obstacles, the benefit of gating is assessed **qualitatively** instead: by measuring, over a representative benchmark run, how many clock cycles each memory is actually enabled versus how many cycles the full computation takes. See `docs/asic/RESULTS.md` for those figures and the resulting per-memory conclusions.

## Decision

Gate each of the four macros' `CEN` based on the control-flow window in which it's actually needed, using control signals already present at the toplevel (`start`, `all_steps_done`, `done`, and each memory's own external-load control signal — see `ARCHITECTURE.md` §9.1/§9.2):

| Macro | Enabled window | Rationale |
|---|---|---|
| `coord_memory_b1` | `start` (or external load, `we_coord_load`) → `done` (`cluster_assign`'s own `done`) | Used throughout the entire run, including external benchmark loading and the final clustering pass (`cluster_assign` reads coordinates from this copy) |
| `coord_memory_b2` | `start` (or external load) → `all_steps_done` | Only used during the iterative loop; not touched during the final clustering pass |
| `upd_memory` | `start` → `all_steps_done` | Same idle window as `coord_memory_b2`; no external-load path of its own |
| `memory_cluster` | `all_steps_done` → `done` (`cluster_assign`'s own `done`) | Idle for the entire iterative loop; enabled until `cluster_assign`'s own `done`, the final results remain externally readable (via the toplevel's read port) |

Each window is implemented as a level signal held by a register (set on the window's start event, cleared on its end event), OR'd with the raw start-event signal itself so the enable is already high on the very cycle that event fires, without waiting a cycle for the register to update.

RTL-side, this required exposing `cen` as a genuine input port on the synthesizable memory wrappers rather than hardwiring the macro's `CEN` to `0`: new `memory_dual_port_v2_synth.sv` and `memory_cluster_v2_synth.sv` variants (functionally identical to their existing synthesizable counterparts otherwise) drive `.CEN(~cen)` from this new port instead of a constant.

## Consequences

**Positive**
- Implemented across all four v2 macros; the synthesizable wrapper variants now expose the `CEN` control this project's memory-wrapper docs had been flagging as unused since ADR-0007.
- `memory_cluster`'s gating window is the most favorable of the four by construction — idle for the entire iterative loop, active only for the comparatively short final pass (plus the post-computation readout window).
- `coord_memory_b1` needs the widest enable window of the four, which is itself a useful cross-check: it confirms this memory really is needed throughout the run, consistent with `ARCHITECTURE.md`'s description of how `cluster_assign` reuses it.

**Negative / limits**
- The actual power benefit of this gating **cannot be quantified from `report_power`**, even using real, activity-driven data (VCD, post-synthesis and post-layout) — the macro `.lib` files used in this project don't characterize leakage power at all, and leakage is precisely what `CEN` gating targets. This is a library limitation, not something fixable from the RTL or flow side.
- In its place, a qualitative measure (cycles-enabled vs. total run length, per memory, over a representative benchmark) was used instead — see `docs/asic/RESULTS.md`. This measures how much each memory is idled *during active computation* specifically; the more significant payoff of gating is expected during powered-but-idle (standby) periods, which this particular measurement doesn't directly observe, since it's derived from one continuous compute run.
