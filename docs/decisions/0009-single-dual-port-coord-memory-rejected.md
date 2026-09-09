# ADR-0009 — Merging the two coordinate memories into a single dual-port memory (rejected)

## Status
Rejected

## Context

Since [ADR-0003](0003-ping-pong-buffering.md), the two coordinate memories (`coord_memory_b1` for `exp`, `coord_memory_b2` for `grad`) always hold exactly the same content: `act_coord` broadcasts every update to both copies at once (`docs/blocks/act_coord.md`, `docs/ARCHITECTURE.md` §9.2), so they never diverge. This naturally raises an obvious-looking idea: since both memories store identical data and only need to be *read* simultaneously by two different consumers, why not replace them with a single true dual-port memory instead of paying for two full copies of the same data? This is, after all, precisely the kind of access pattern dual-port memories exist to serve.

On paper, this looks like a clear area win: the current design pays for two independent copies, together accounting for roughly 700,000 µm² (`coord_memory_b1` + `coord_memory_b2` in `docs/asic/RESULTS.md`: ≈353,791 + 353,6668 µm²).

## Options considered

1. **Keep the current scheme**: two independent, macro-backed, single-port-style coordinate memories, one per reader (as implemented per ADR-0003 and `docs/blocks/coord_mem_wrapper.md`).

2. **Merge into a single true dual-port coordinate memory**, backed by the `RAM2P_1024X32` macro already used elsewhere in the design (the only dual-port macro available in the current library, see ADR-0007).

## Decision

Rejected option 2; kept option 1.

## Reasoning

The available dual-port macro only stores 1024 points per instance — a quarter of the 4096-point capacity the design actually needs (matching `NB_POINTS`'s target range and the depth of the existing per-copy coordinate memories). Reaching 4096 points in dual-port form requires combining four instances of this macro behind a wrapper. At roughly 240,000 µm² per instance, four instances alone cost approximately 4 × 240,000 ≈ 960,000 µm² — already more than the ≈700,000 µm² currently spent on the two independent single-port copies.

This is a direct instance of the constraint ADR-0007 already documents: the available memory-macro library doesn't offer a shape that matches what the design actually needs, so an architecturally "obvious" improvement can still lose once confronted with the granularity of what's actually on hand.

## Consequences

**Positive**
- Avoided spending synthesis/P&R and verification effort on a change that the area estimate above indicates would have made the design worse, not better.
- The reasoning is documented here so this specific path isn't re-explored later without a reason to revisit it (see below).

**Negative / limits**
- The two coordinate memories remain duplicated, so the area cost of holding two identical copies — a trade-off already knowingly accepted in ADR-0003 for the sake of parallel read access — persists unchanged in v2.
- This decision is specific to the macro library currently available (`RAM2P_1024X32` at 1024 points per instance). If a dual-port macro closer to the design's actual 4096-point need became available in the future, this trade-off would be worth recalculating.
