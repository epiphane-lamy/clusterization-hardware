# ADR-0002 — Row-by-row streaming of matrix P instead of full storage

## Status
Accepted

## Context
The reference software model fully builds and stores an `N × N` matrix `P` at each iteration of the algorithm, where `N` is the number of points. For a reasonable test set of 1000 points, this represents 1,000,000 coefficients — even when encoded on 16 bits (Q0.16), this corresponds to 2 MB to be reconstructed at each iteration. On a modest-sized FPGA target, or in an ASIC flow where every memory bit has a direct area cost, this approach is not viable as-is.

## Options considered

1. **Store the complete matrix `P` in memory (direct reproduction of the software algorithm).**
   - Faithful to the original algorithm, with no restructuring of the calculation order required.
   - `O(N²)` memory footprint, prohibitive as soon as `N` exceeds a few dozen points.

2. **Produce and consume matrix `P` row by row, without ever materializing it in its entirety.**
   - The `exp` block produces one row of `P` (the `N` coefficients corresponding to a point `i`), the `grad` block consumes it immediately to calculate the gradient contribution for point `i`, and then the next row can be produced.
   - `O(N)` memory footprint (only one row at a time), at the cost of restructuring the calculation flow compared to the original software model.

## Decision
Option 2: the `exp` block produces `P` row by row, consumed on the fly by the `grad` block. No memory ever stores the complete matrix `P` at any point during execution.

## Consequences

**Positive**
- Memory footprint reduced from `O(N²)` to `O(N)` — for 1000 points, going from 2 MB to a few KB.
- Makes the architecture viable both for FPGA and for an ASIC flow where memory area is directly costly.
- This choice structures the entire memory architecture of the project (see [ADR-0003](0003-ping-pong-buffering.md) for the direct follow-up to this decision).

**Negative / limitations**
- The simple sequential flow (exp writes → grad reads → exp writes again) introduces idle time between the two blocks, which required a complementary overlap solution (see [ADR-0003](0003-ping-pong-buffering.md)).
- The calculation of the normalization sum for a row, which previously required a second pass over the complete matrix in the software model, must be recalculated differently to remain compatible with a row-by-row streaming flow (on-the-fly accumulation by the `exp` block, see [ARCHITECTURE.md](../ARCHITECTURE.md) §6).
