# ADR-0006 — Validity bit instead of sentinel value for unassigned clusters

## Status
Accepted

## Context
In the reference software model, each point is assigned a cluster number initialized to `-1`, used as a sentinel value to indicate "not yet assigned to a cluster". This mechanism relies on the fact that a software array can be initialized to an arbitrary value at startup, and that `-1` is trivially distinguishable from any valid cluster number (always positive or zero).

This assumption does not directly hold in hardware: a memory has no observable and reliable "uninitialized" state when read — its contents after reset depend on the target technology and cannot be assumed to be zero or constant in a portable way. Reproducing `-1` as a sentinel would require either explicitly initializing the entire memory to this value at reset (at the cost of cycles or dedicated logic depending on the target), or reserving a value of the cluster-number field as a sentinel.

## Options considered

1. **Reserve a value of the cluster-number field as a sentinel** (e.g. the maximum representable value), as the direct equivalent of the software `-1`.
   - Does not require an additional bit.
   - Reduces the number of effectively representable clusters by one (one field value is "consumed" by the sentinel).
   - Still requires explicit initialization of the memory to this sentinel value at reset, so that the "unassigned" state is guaranteed at startup.

2. **Dedicated validity bit, one per row of the cluster memory, separate from the cluster-number field.**
   - The cluster-number field itself requires no particular initialization: its value is only meaningful when the associated validity bit is 1.
   - The validity bit is initialized to 0 at reset (minimal cost: one bit per point, significantly simpler to guarantee than a complete initialization of the cluster-number field).
   - The cluster-number field retains its entire representable range for actual cluster numbers.

## Decision
Option 2: a dedicated validity bit per row of the cluster memory (`valid_cluster`, visible on the part 2 toplevel diagram), initialized to 0 at reset. A point is considered unassigned as long as its validity bit is 0, regardless of the contents of the cluster-number field at that address.

## Consequences

**Positive**
- No initialization constraint on the cluster-number field itself — only the validity bit must be guaranteed to be 0 at reset, which is trivial to ensure regardless of the target (FPGA or ASIC).
- The entire range of the cluster-number field remains available to represent actual clusters, with no value sacrificed as a sentinel.
- Explicit and unambiguous semantics when reading the RTL: data validity is carried by a dedicated signal rather than inferred from a convention on the contents.

**Negative / limitations**
- One additional bit per point in the cluster memory (marginal memory cost compared to the cluster-number field itself).
- Introduces a representation divergence from the reference software model (`-1` vs `valid = 0`), which must be kept in mind when comparing testbench results with the bit-exact reference model (see [`ARCHITECTURE.md`](../ARCHITECTURE.md), §9): the comparison must interpret `valid = 0` as equivalent to `-1`, rather than comparing the two raw fields term by term.
