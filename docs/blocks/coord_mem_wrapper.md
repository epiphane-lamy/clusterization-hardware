# Block: `memory_dual_port` — behavioral model vs. ASIC macro wrapper

Two drop-in implementations of the same coordinate-storage memory, sharing the identical module name and port list: a behavioral model used for RTL simulation, and a wrapper backing the same interface with a real ASIC memory macro (`RAM_4096X32`) for the ASIC flow. Because the interface never changes, none of the RTL that instantiates this memory (the `exp`/`grad`-side coordinate memories described in [ADR-0003](../decisions/0003-ping-pong-buffering.md)) needs any modification when switching between the two.

> Naming note: despite the module name (kept from the original custom design), this isn't a true dual-port memory — it's a single read/write port that returns/accepts two data words per access (a point's X and Y coordinate together). See `ARCHITECTURE.md` §4.4 for why the toplevel relies on this "both coordinates in one access" behavior.

Related decision: memory-macro wrapper strategy ([ADR-0007](../decisions/0007-memory-macro-wrappers.md)).

RTL: [`memory_dual_port.sv`](../../frontend/rtl/memory_dual_port.sv), [`memory_dual_port_synth.sv`](../../frontend/synth_files/memory_dual_port_synth.sv)

> Suggested file layout: keeping the two implementations in separate directories (`rtl/` vs `synth_files/`), both defining a module of the same name, is what makes the "drop-in replacement" property in the paragraph above actually work at the file-list / build level — only the ASIC flow's source list points at `synth_files/`, everything else keeps using `rtl/`.

---

## 1. Interface (shared by both implementations)

| Parameter | Meaning |
|---|---|
| `ADDR_W` | Address width |
| `DATA_W` | Width of **one** coordinate (16 bits: a point's X or Y, not the packed word) |

| Port | Dir | Description |
|---|---|---|
| `clk`, `rst_n` | in | Clock, reset |
| `we` | in | Write enable |
| `addr` | in | Address (one point per address) |
| `data_in1`, `data_in2` | in | Coordinate values to write (X, Y) |
| `data_out1`, `data_out2` | out | Coordinate values read back (X, Y), 1-cycle synchronous latency in both implementations |

## 2. Behavioral model

A straightforward 2-word-per-address memory: `memory[addr][0]` / `memory[addr][1]` store `data_in1`/`data_in2` together, written as a pair whenever `we` is asserted. Both outputs are registered every cycle regardless of `we` (continuous synchronous read, matching standard BRAM inference behavior).

## 3. Macro-backed wrapper

The target macro, `RAM_4096X32`, is a single 32-bit-wide memory (`ADDR_W = 12`, `DATA_W = 32`) — it has no notion of "two 16-bit fields per word" on its own. The wrapper's only job is to pack and unpack that 32-bit word:

```
write_data[31:16] = data_in1   (X)
write_data[15:0]  = data_in2   (Y)

data_out1 = read_data[31:16]   (X)
data_out2 = read_data[15:0]    (Y)
```

i.e. a point's X and Y coordinates occupy the upper and lower halves of a single 32-bit macro word, addressed together — preserving the "both coordinates in one access" behavior the rest of the design (`exp`/`grad`) relies on, with no change needed on their side.

### Control signal mapping

The macro uses active-low chip-enable/write-enable conventions (`CEN`, `WEN`), different from the behavioral model's single active-high `we`:

| Macro signal | Driven as | Meaning |
|---|---|---|
| `CEN` | `1'b0` (tied) | Chip permanently enabled — every cycle performs a read, matching the behavioral model's unconditional read (§2). See §5 for the power-gating opportunity this leaves on the table. |
| `WEN` | `~we` | `we = 1` → `WEN = 0` → write enabled, matching the behavioral model's semantics |

### Latency and read/write ordering

With `CEN` tied low, `RAM_4096X32`'s simulation model (see the caution box at the top of this document) registers `Q <= memory[A]` every cycle unconditionally, and writes `memory[A] <= D` on top of that same cycle when `WEN` is also low — i.e. the read reflects the *pre-write* value at that address (write-after-read), with 1-cycle latency. This matches the behavioral model exactly: same address, same 1-cycle latency, same relative read/write ordering. This equivalence is what the resimulation of the full clustering pipeline (swapping the behavioral memories for the macro-backed wrappers)confirmed (see `ARCHITECTURE.md` §9 (verification strategy)).

## 4. Reset

Neither implementation actually uses `rst_n` — memory contents are never cleared by reset in either version (kept in the port list for interface consistency with the rest of the design, and because a real macro wouldn't have a reset pin in the first place).

## 5. Known limitations / notes

- `CEN` is permanently tied to `0` (always enabled). This means every cycle costs a read access on the macro regardless of whether the address is actually meaningful that cycle — a power-gating opportunity (driving `CEN` from a genuine "memory access needed this cycle" signal) that hasn't been exploited yet.
- Address width is now fixed by the macro's physical size (`RAM_4096X32` → `ADDR_W = 12`) rather than freely parameterizable the way the behavioral model's `2**ADDR_W` sizing was. Any block that previously derived its address width from `$clog2(NB_POINTS)` now needs to use the macro's fixed constant instead — see the upcoming ADR-0007 for the full discussion of this constraint.
- The `RAM_4096X32` module shown here is a **behavioral simulation model only**, used to verify the wrapper's logic in RTL simulation. The macro actually used in synthesis and place-and-route is an opaque black box, characterized by its `.lib` (timing/power) and `.lef` (physical) views — it is not this Verilog.
