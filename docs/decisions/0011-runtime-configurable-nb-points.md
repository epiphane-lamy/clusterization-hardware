# ADR-0011 — Runtime-configurable point count (`NB_POINTS_LOADER`)

## Status
Accepted (v3)

## Context

Since the project's earliest RTL, `NB_POINTS` has been a compile-time SystemVerilog parameter, fixed at synthesis time and baked directly into every FSM boundary condition across the four compute blocks (`exp`, `grad`, `act_coord`, `cluster_assign`) — e.g. `cnt_j == NB_POINTS - 1`. This means a fabricated chip could only ever process benchmarks with *exactly* the point count it happened to be synthesized for; anything smaller or larger would need a new tapeout. This limitation was flagged in essentially every block's documentation since the very first one written (`docs/blocks/exp_block.md` §7, repeated in every block doc after it).

This ADR removes that limitation, up to the chip's physical maximum of 4096 points (fixed by the memory macros' physical size, [ADR-0007](0007-memory-macro-wrappers.md)) — `NB_POINTS` becomes a value chosen once per run, rather than a value the chip is permanently locked to.

## Options considered

1. **Keep `NB_POINTS` as a compile-time parameter** (status quo). No RTL work, but the limitation above persists indefinitely.

2. **Make the point count a runtime input**, loaded once before each run via a small dedicated loader module, with each compute block's `NB_POINTS` parameter replaced by an `nb_points` input port.

## Decision

Option 2. A new module, [`NB_POINTS_LOADER`](../../rtl/NB_POINTS_LOADER.sv), loads a 12-bit `nb_points` value (matching the chip's fixed 4096-point maximum, ADR-0007) serially, 3 bits at a time over 4 cycles, through a minimal `valid_load` / `load[2:0]` interface — **4 pins total** (`valid_load` + 3 data bits), against **13 pins** a direct 12-bit parallel load port plus its own valid signal would have needed. Since this value only needs to be configured once per run rather than every cycle, trading a few extra clock cycles at start-up for 9 fewer package pins is a straightforward win.

Each of the four compute blocks — `exp_v2`, `grad_v2`, `act_coord`, `cluster_assign` — has its `NB_POINTS` parameter removed and replaced by an `nb_points` input port, with every internal reference to the old compile-time constant replaced by this new runtime signal. `ADDR_W` (and the other address-width parameters tied to the macros' physical size) stay exactly as they were, compile-time constants — only the *actual point count in use this run* becomes runtime-configurable, not the chip's underlying addressable capacity.

This change is made **in place**, directly on v2's existing files, rather than as a parallel `_v3` set the way `exp`/`grad` got a `_v2` variant kept alongside v1 (ADR-0008). v3 is v2 plus this change — it supersedes v2 outright rather than coexisting with it. However, `act_coord` and `cluster_assign` are exceptions: dedicated act_coord_v3.sv and cluster_assign_v3.sv files have been created for v3, allowing both the v1 and v3 architectures to remain runnable.

## Consequences

**Positive**
- Removes a limitation flagged since the project's very first RTL: the chip can now process any benchmark up to its physical 4096-point capacity, rather than only the exact point count it was synthesized for.
- Minimal RTL footprint: one small new module plus a parameter-to-port rename in each of the four compute blocks — no change to any compute pipeline or control logic itself.
- Cleanly separates two concerns ADR-0007 first introduced together: the chip's fixed physical capacity (4096 points, set by the memory macros, unchanged) from the actual problem size in use for a given run (now a runtime value, up to that same ceiling).

**Negative / limits**
- Nothing in the RTL enforces *when* `nb_points` may be loaded. The intended contract — load once, after reset, before the first `start`, and hold stable for the entire run — is a convention the testbench follows, not something the hardware itself checks or protects against a reload mid-computation.
- Replacing a compile-time constant with a runtime register in every FSM boundary comparison (e.g. `cnt_j == nb_points - 1`) trades a synthesis-optimized, constant-folded comparator for a genuine register-compare/subtract circuit in each of the four blocks — a modest area/timing cost expected in each, to be confirmed once v3 goes through a full synthesis/P&R run.
