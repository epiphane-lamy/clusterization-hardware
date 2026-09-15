# ADR-0012 — On-chip memory, rather than streaming coordinates and results through an external host link

## Status
Accepted

## Context

Every memory-related decision documented so far (ADR-0002, ADR-0003, ADR-0007, ADR-0008, ADR-0009, ADR-0010) already takes for granted that the design stores data on-chip, and discusses only *how* to organize that storage as cheaply as possible. None of them justify the more fundamental choice: *why store anything on-chip at all*, rather than keep the point coordinates and cluster results off-chip, streamed to and from an external host as needed.

This question is worth asking directly, because the answer to "how much does on-chip storage cost this design" is now well documented and consistently large: memory accounts for roughly 96–98% of total cell area and 63–77% of total power across every version measured (`docs/asic/RESULTS.md`). Given a cost that dominant, it's a fair question whether an architecture that avoided on-chip storage altogether — sending point coordinates in as needed and streaming cluster assignments out as they're produced, with no local memory for either — could have avoided that cost.

## Options considered

1. **On-chip memory for coordinates, `P_ij`, and cluster assignments** (as implemented, across all three architecture versions).

2. **Fully streaming architecture, no on-chip storage of points or results.** Point coordinates would be sent in by an external host as `exp` needs them; cluster assignments would be streamed out as `cluster_assign` produces them, rather than held in a `memory_cluster` for later readout.

## Reasoning

Option 2 was not pursued, for three compounding reasons specific to this algorithm's access pattern:

1. **Coordinates are read repeatedly, not once.** `exp` re-reads the full point set once per iteration, `NB_ITER` times (50, by default). Without on-chip coordinate storage, the host would need to resend the entire benchmark 50 times over, not once.

2. **Coordinates are also rewritten every iteration.** `act_coord` updates every point's position at the end of each iteration (§4.5, `ARCHITECTURE.md`). Without a memory to hold those updated coordinates on-chip, each iteration would additionally require a full round trip back to the host — sending the updated points out, then reading the same (now current) points back in for the next iteration — rather than a single initial load. That's up to 49 additional round trips for a 50-iteration run, on top of the 50 reads in point 1.

3. **Cluster-assignment access is data-dependent, not sequential.** Unlike a predictable, fixed-order stream, `cluster_assign`'s access to the cluster memory depends on how quickly each point converges into a cluster during the algorithm's run — which points get labelled, and in what order, isn't known in advance. A host serving this over a link would need to answer effectively arbitrary-order requests rather than deliver a simple, predictable sequential stream, defeating much of the appeal of "just stream it."

These three effects compound rather than one dominating: a fully streaming version of this design would need drastically more host-link traffic than a single pass over the input data, for every one of the three memories this project actually implements on-chip.

This conclusion is informed by direct prior experience with exactly this kind of bottleneck: an earlier academic project (a quantized CNN on FPGA, communicating with a host over UART) showed that an external link can be a real throughput bottleneck even for a *single* streaming pass over an input (transferring pixel data once). This design's access pattern — repeated, host-updated, and partly data-dependent — would multiply that same bottleneck many times over across a single benchmark run.

**Caveat:** this reasoning is qualitative, based on the point-count/iteration-count scaling argument above and on the referenced prior project's experience, not on a cycle-accurate measurement of an actually-implemented streaming alternative. No streaming version of this design was built to measure directly against the on-chip-memory version documented throughout the rest of this project.

## Consequences

**Positive**
- Keeping coordinates, `P_ij`, and cluster results on-chip means the entire `NB_ITER`-iteration computation is self-contained after a single initial point-set load — no host round-trip anywhere in the iterative loop, which is presumably central to this design achieving the clock frequencies and throughput reported in `docs/asic/RESULTS.md` without being bottlenecked by an external link.
- This is the root decision that every other memory-related ADR in this project builds on top of (ADR-0002 onward) — documenting it explicitly closes the gap in the project's own reasoning chain: every subsequent memory decision optimizes a cost that this ADR is the one actually choosing to accept.

**Negative / limits**
- This is the direct root cause of memory's dominant share of area and power throughout the project — every number quantifying that dominance in `docs/asic/RESULTS.md` (≈96–98% of area, ≈63–77% of power, across every version) is a consequence of this decision, not of any individual downstream memory-organization choice.
- The trade-off was never validated by actually building and measuring the streaming alternative — the reasoning above is sound in direction, but the exact magnitude of host-link traffic (and whether some hybrid, e.g. streaming only the least data-dependent of the three memories, might have been worthwhile) was not explored.
