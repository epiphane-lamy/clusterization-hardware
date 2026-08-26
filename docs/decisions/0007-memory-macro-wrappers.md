# ADR-0007 — Interface-preserving wrappers around ASIC memory macros

## Status
Accepted

## Context

The RTL simulation oriented version of the design uses behavioral memories (`memory_dual_port`, `memory_single_port`, `memory_cluster`), each shaped exactly around what the surrounding logic needs: a point's X and Y coordinate together, a single `P_ij` value, a cluster number plus its valid bit.

Taking the design through a full ASIC flow (RTL → GDSII) requires replacing these behavioral memories with real memory macros, characterized by `.lib` (timing/power) and `.lef` (physical) views and treated as black boxes by the tools. Two macros were available for this project: `RAM2P_1024X32` (true 2-port, 32-bit wide, 1024 deep) and `RAM_4096X32` (single port, 32-bit wide, 4096 deep). Neither matches any of the three custom memories' shape directly — all three custom memories use narrower words (16 bits or less) than the macros' fixed 32-bit width, and none of them are naturally 32-bit-wide to begin with.

## Options considered

1. **Rewrite the surrounding RTL to work natively in the macros' terms** — propagate 32-bit-wide words and the macros' fixed depths through `exp`, `grad`, `act_coord`, and `cluster_assign` directly, rather than hiding the translation behind a memory-shaped interface.
   - No extra packing/unpacking logic anywhere.
   - Spreads ASIC-specific concerns (macro word width, active-low `CEN`/`WEN` conventions, fixed depth) across every block that touches memory, rather than containing them in one place. Any future change of macro (different vendor, different size) would require touching all of those blocks again.

2. **Thin wrappers, one per custom memory, preserving the exact same module name and port list as the behavioral version, translating internally to the macro's interface.**
   - `exp`, `grad`, `act_coord`, and `cluster_assign` need zero changes when switching from the behavioral memories to the macro-backed ones — only the file list fed to the ASIC flow points at a different implementation of the same module name (see `docs/blocks/coord_mem_wrapper.md`, `pij_mem_wrapper.md`, `cluster_mem_wrapper.md` for the file-layout convention this relies on).
   - Concentrates all ASIC-specific translation logic (bit-packing, `CEN`/`WEN` mapping) in three small, individually documented, individually resimulated modules, rather than scattering it through the compute blocks.
   - Requires genuinely non-trivial packing logic in places (e.g. pairing two `P_ij` values into one 32-bit macro word to use the full bus width, see `pij_mem_wrapper.md`), which is itself a source of subtle timing bugs if not done carefully — see the read-path timing concern flagged in that same document.

## Decision

Option 2: interface-preserving wrappers, one per custom memory, kept in a separate `synth_files/` source tree alongside the behavioral versions in `rtl/`.

Three wrappers were built, each documented individually:
- [`coord_mem_wrapper.md`](../blocks/coord_mem_wrapper.md) — packs a point's X/Y coordinates into one `RAM_4096X32` word.
- [`pij_mem_wrapper.md`](../blocks/pij_mem_wrapper.md) — pairs two consecutive `P_ij` values into one `RAM2P_1024X32` word, exploiting the fact that `P_ij` is always produced in strictly increasing address order.
- [`cluster_mem_wrapper.md`](../blocks/cluster_mem_wrapper.md) — moves the cluster number into `RAM_4096X32`, while deliberately keeping the valid bits (ADR-0006) as flip-flops rather than macro contents, since a macro's reset state isn't guaranteed the way a flip-flop's is.

## Consequences

**Positive**
- The compute blocks (`exp`, `grad`, `act_coord`, `cluster_assign`) required no modification at all to move from the FPGA/simulation target to the ASIC flow — the memory interface contract was preserved exactly.
- Each wrapper is independently documented and was independently resimulated (full clustering pipeline, behavioral memories swapped for macro-backed wrappers) to check functional equivalence before trusting it in the ASIC flow.

**Negative / limits**
- Address width can no longer be derived dynamically from the point count (e.g. `$clog2(NB_POINTS)`) the way the behavioral memories allowed — a macro's depth is a fixed physical property, so every wrapper's `ADDR_W` (and, for the `P_ij` and coordinate wrappers, the corresponding logical/physical address split) must now be sized to match the specific macro chosen, as a literal constant rather than a parameter derived from the design's own point count.
- Only two macro shapes were available, and neither matches the design's memory requirements exactly, resulting in some area overhead due to unused bytes.

