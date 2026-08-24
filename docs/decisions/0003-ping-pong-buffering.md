# ADR-0003 — Double buffering (ping-pong) between `exp` and `grad`, and duplication of coordinate memories

## Status
Accepted

## Context
Following [ADR-0002](0002-single-row-streaming-vs-full-matrix.md), `P` is processed row by row through a shared buffer memory between `exp` (producer) and `grad` (consumer). A strictly sequential flow using a single row memory (exp writes → grad reads → exp writes again) introduces significant idle time: each block must wait for the other to finish before starting its own access.

## Options considered

1. **A single row memory, with strictly sequential access between `exp` and `grad`.**
   - Simplest architecture, with minimal memory footprint (only one row stored).
   - No overlap possible between the production and consumption of a row: the total processing time is the sum of both phases, row after row.

2. **Two row memories (A and B) with a ping-pong arbiter.**
   - While `exp` writes row `i+1` to memory A, `grad` simultaneously reads row `i` (already produced) from memory B. Once both are finished, the arbiter swaps the roles of the two memories (routing only, without copying data).
   - Overlaps the two phases: processing time approaches the slower of the two blocks rather than their sum.
   - Cost: twice the row memory compared to option 1 (two stored rows instead of one), plus an additional arbiter block.

## Secondary consequence and sub-decision: coordinate duplication

The overlap provided by option 2 requires `exp` and `grad` to be able to read point coordinates **simultaneously**, each for the row it is processing. A single-port coordinate memory would create an access conflict between the two blocks.

Two options were considered for this sub-problem:
- **Single coordinate memory, with access arbitration between `exp` and `grad`**: reintroduces idle time equivalent to the very delay that the ping-pong scheme is intended to eliminate.
- **Duplicate the coordinate memory** (one dedicated copy for `exp`, one for `grad`): each block has a dedicated access, with no arbitration or conflict.

Duplication appears, at first glance, to go against the memory-efficiency objective established by ADR-0002. However, the actual cost remains marginal: the coordinates are encoded on 16 bits in Q8.8, and a duplicated coordinate memory remains vastly smaller than the complete `P` matrix that was avoided by ADR-0002.

## Decision
Option 2 (two-memory ping-pong buffering), combined with duplication of the coordinate memory between `exp` and `grad`.

## Consequences

**Positive**
- Effective overlap between the production and consumption of a `P` row: total computation time is halved compared to a strictly sequential flow.
- Both computation blocks (`exp` and `grad`) operate in parallel on different rows at all times.
- The memory cost of coordinate duplication remains negligible compared to the gain provided by ADR-0002.

**Negative / limitations**
- Memory footprint for `P` rows is doubled compared to a single-memory scheme (it remains `O(N)`, so the overall objective of ADR-0002 is not compromised).
- Additional control complexity: the `ping pong arbiter` block must ensure that the swap between memories A and B occurs only once both accesses (write by `exp`, read by `grad`) have actually completed.
- Explicitly goes against the initial "memory light" objective stated in ADR-0002 — accepted as a deliberate and quantified trade-off, not an oversight.
