# Block: `memory_cluster` — behavioral model vs. ASIC macro wrapper

Two drop-in implementations of the cluster-number storage memory, sharing the same module name and port list. Same overall strategy as the other memory wrappers — see [`coord_mem_wrapper.md`](coord_mem_wrapper.md) for the general rationale.

Related decisions: [ADR-0006](../decisions/0006-valid-bit-for-unassigned-cluster.md) (valid bit instead of `-1`), [ADR-0007](../decisions/0007-memory-macro-wrappers.md) (memory-macro wrapper strategy).

RTL: [`memory_cluster.sv`](../../frontend/rtl/memory_cluster.sv), [`memory_cluster_synth.sv`](../../frontend/synth_files/memory_cluster_synth.sv)

---

## Why the valid bits stay out of the macro

The one design point in this wrapper worth calling out on its own: the cluster **number** is moved into the `RAM_4096X32` macro (packed into the lower 16 bits of the 32-bit word, upper 16 bits unused — see §1), but the **valid bits** stay exactly where they were in the behavioral model — a separate array of real flip-flops (`valid_array`), synchronously resettable to all-`0` on `rst_n`.

This isn't an oversight; it's the point. ADR-0006's entire argument for using a valid bit instead of a `-1` sentinel rested on the valid bit being reliably `0` at reset. A memory macro has no such guarantee — its contents after power-up/reset are generally undefined, the same way FPGA/ASIC RAM contents are unless explicitly initialized. Flip-flops, unlike macro storage, do support a defined synchronous reset. So once real macros entered the picture, keeping the valid bits as flip-flops isn't just convenient — it's what makes ADR-0006 actually hold at the ASIC-flow level, not only in the behavioral simulation.

One visible consequence: the behavioral model resets `data_out` to `0` explicitly, while the macro-backed wrapper does not (its `data_out` is a combinational read straight from the macro, which has no defined reset content). This is a real difference between the two implementations, but a harmless one by construction: consumers are only ever supposed to trust `data_out` when `valid_cluster` says the entry is assigned — exactly ADR-0006's contract.

## 1. Packing scheme

Unlike the `P_ij` wrapper (which packs two values per macro word, see [`pij_mem_wrapper.md`](pij_mem_wrapper.md)), this wrapper packs a single field per word: the cluster number occupies the lower 16 bits (`write_data[15:0] = data_in`), with the upper 16 bits tied to `0` and unused. No even/odd address pairing is used here — one logical address maps directly to one macro row (`A = addr`), so the read path has none of the current/previous-cycle parity-mux subtlety flagged in `pij_mem_wrapper.md` — `data_out` is a plain, correctly-latency-matched combinational slice of the macro's own registered output.

## 2. Known limitations / notes

- The upper 16 bits of every macro word are unused — a straightforward area inefficiency, and the same kind of pairing trick used for P_ij (packing two cluster numbers per word) cannot be applied here.
- Same fixed-address-width consequence as the other wrappers (`ADDR_W` follows the macro's physical size) — see ADR-0007.
- Same note as the other wrappers: `RAM_4096X32` is a **behavioral simulation model only**, used to verify the wrapper's logic in RTL simulation. The macro actually used in synthesis and place-and-route is an opaque black box, characterized by its `.lib` (timing/power) and `.lef` (physical) views — it is not this Verilog.