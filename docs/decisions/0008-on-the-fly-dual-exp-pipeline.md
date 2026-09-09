# ADR-0008 — On-the-fly row processing with a duplicated `exp` pipeline, replacing ping-pong buffering

## Status
Accepted. Supersedes [ADR-0003](0003-ping-pong-buffering.md) as the current architecture (v2). ADR-0003's ping-pong scheme remains documented as the v1 solution — see `docs/blocks/exp_block.md`, `docs/blocks/grad_block.md`, and `docs/blocks/ping_pong_arbiter.md` for that version, and `docs/blocks/exp_block_v2.md` / `docs/blocks/grad_block_v2.md` for this one.

## Context

ADR-0003's ping-pong scheme (two `P_ij` row buffers, arbitrated by `ping_pong_arbiter`) solved the dead-time problem of a naive sequential handoff between `exp` and `grad`, while also enabling the normalization of the P_ij coefficients. However, it came with two costs that became harder to justify once the ASIC macro wrappers were in place (ADR-0007):

1. **Area.** The two `P_ij` buffer memories plus the arbiter account for roughly 480,000 µm² of the design (`memory_P_ij_A` + `memory_P_ij_B` + `P_ij_memory_arbiter` in `docs/asic/RESULTS.md`: ≈239,291 + 239,209 + 1,064 µm²) — by far the largest single contributor to area after the coordinate memories themselves.
2. **A hard point-count ceiling.** The `P_ij` macro wrapper packs two coefficients per 32-bit macro word to use the bus efficiently (`docs/blocks/pij_mem_wrapper.md`), which doubles the addressable range of the underlying `RAM2P_1024X32` macro from 1024 to 2048 — but that's still a hard ceiling: the design cannot process a benchmark with more than 2048 points without a bigger `P_ij` macro.

Both costs trace back to the same root cause: the ping-pong scheme was introduced to address two requirements. First, normalizing a `P_ij` coefficient requires the full row sum, which is only known once every coefficient in the row has been produced. The ping-pong buffers therefore allow `exp` to write the coefficients in an unnormalized form into one memory, while `grad` reads the completed row from the other memory and normalizes the coefficients using the known row sum. Second, using two memories allows `exp` and `grad` to operate concurrently, avoiding dead time: while `exp` writes a new row into memory A, `grad` reads and processes a previously produced row from memory B, after which the two memories are swapped.

Memory also dominates total power in this design (≈77.5% of total power in the current v2 build), so removing a large memory block is expected to help there as well, independent of the area discussion.

## Options considered

1. **Keep the ping-pong scheme (ADR-0003, as implemented).** No further work needed, but keeps paying the area/power cost and the 2048-point ceiling described above.

2. **Fully on-the-fly processing, no row buffer at all.** `exp` streams `P_ij` directly to `grad`, with no memory in between. This removes the buffers and the arbiter entirely — but runs into the same obstacle that motivated storing a row in the first place (ADR-0002 §4.1): normalizing a coefficient requires the *full row sum*, which is only known once every coefficient in the row has been produced. In a naive implementation, this means `exp` has to compute each row **twice** — once to produce the sum, once to re-produce the coefficients for `grad` to normalize on the fly — doubling `exp`'s total compute time compared to the buffered scheme (2×`N` row-times instead of `N`).

3. **On-the-fly processing with a duplicated `exp` compute pipeline.** Same principle as option 2 (no row buffer, coefficients are produced twice), but with `exp`'s compute pipeline instantiated **twice**, running out of phase with each other: while pipeline A streams row `i`'s coefficients live to `grad` (normalizing them using the sum already known for row `i`, computed on the *previous* pass), pipeline B is simultaneously computing the sum for row `i+1`'s first pass. This overlaps the "sum-only pass" of one row with the "grad-consuming pass" of the previous row, bringing the total time back down to roughly `N+1` row-times instead of `2N` — at the cost of duplicating `exp`'s own pipeline logic and, since both pipelines need `exp()` lookups concurrently, adding a second read port to `exp_LUT`.

## Decision

Option 3. `ping_pong_arbiter` and both `P_ij` row buffers are removed entirely. `exp`'s compute pipeline is duplicated (two instances running one row apart, one for "sum-only" and the other dor "stream-to-grad" roles); `exp_LUT` gains a second read port to serve both pipelines. `grad` is restructured to consume `P_ij` coefficients live, as they're produced, rather than reading them back from a buffer — this removes the need for `grad`'s own FSM entirely (no more waiting on a row-ready notification; it simply processes whatever arrives, whenever it arrives) and, correspondingly, removes the `credit_avail` flow-control mechanism that ADR-0003 introduced specifically to protect the now-deleted buffers.

## Consequences

**Positive**
- Removes roughly 480,000 µm² of buffer/arbiter area, replaced by an estimated ≈20,000 µm² of duplicated pipeline logic (≈10,000 µm² for the second `exp` compute pipeline, ≈10,000 µm² for the second `exp_LUT` read port) — see the exact results from a full synthesis/P&R run of the v2 design (`docs/asic/RESULTS.md`).
- Removes the 2048-point ceiling imposed by the `P_ij` macro wrapper's fixed depth (ADR-0007), since there is no `P_ij` memory macro left in the design at all.
- Given memory's dominant share of total power (≈77.5%), removing this large memory block is expected to meaningfully reduce power as well — to be confirmed against a full power report for v2.
- `grad` no longer needs its own control FSM, a significant simplification of its control logic compared to v1.

**Negative / limits**
- Introduces new control complexity: the two `exp` pipelines must be kept exactly one row apart.
- Adds one extra row-time of latency per full sweep (`N+1` row-times instead of the theoretical minimum of `N`) compared to an idealized single-pass scheme — though far better than option 2's naive `2N`.
- v1 (ping-pong buffered) and v2 (this architecture) are kept side by side under the `_v2` naming convention rather than replacing v1 outright, so both remain buildable and simulatable independently — see `docs/blocks/exp_block_v2.md` and `docs/blocks/grad_block_v2.md`.
