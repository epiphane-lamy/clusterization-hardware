# Block: `memory_single_port` — behavioral model vs. ASIC macro wrapper (P_ij storage)

Two drop-in implementations of the row-of-`P_ij` storage memory used by the ping-pong buffers (A/B), sharing the same module name and port list: a plain behavioral single-port model, and a wrapper backing the same interface with the `RAM2P_1024X32` ASIC macro. Same overall strategy as the coordinate memory wrapper — see [`coord_mem_wrapper.md`](coord_mem_wrapper.md) for the general rationale (interface-compatible drop-in, ASIC flow only touches `rtl/`).

Related decision: memory-macro wrapper strategy ([ADR-0007](../decisions/0007-memory-macro-wrappers.md)).

RTL: [`memory_single_port.sv`](../../frontend/rtl/memory_single_port.sv), [`memory_single_port_synth.sv`](../../frontend/synth_files/memory_single_port_synth.sv)



---

## 1. Interface

| Parameter | Meaning |
|---|---|
| `ADDR_W` | Logical address width (one `P_ij` per address) |
| `DATA_W` | Width of a single `P_ij` value (16 bits, Q0.16) |

| Port | Dir | Description |
|---|---|---|
| `clk`, `rst_n` | in | Clock, reset |
| `we` | in | Write enable |
| `addr` | in | Logical address (one `P_ij` per address) |
| `data_in` | in | `P_ij` value to write |
| `data_out` | out | `P_ij` value read back |

## 2. Packing scheme

`RAM2P_1024X32` is a true 2-port, 32-bit-wide macro; only port A is used (port B is tied off: `CENB = 1`, `WENB = 1`, `AB = 0`, `DB` left unconnected — see §4). Two consecutive `P_ij` values (an even/odd pair, addresses `2k`/`2k+1`) are packed into a single 32-bit macro word at physical row `k = addr >> 1`, matching the reference software model's property that `P_ij` values are produced strictly in increasing address order, one per cycle (see `ARCHITECTURE.md` §4.6 for the Q0.16 row format this relies on).

**Write path:** when the even address `2k` is written, its value is only *latched* (`data_reg <= data_in`, gated by `addr[0]==0`) — no macro write happens meaningfully yet (the macro is written every cycle `we` is high, but with a stale/incomplete `data_reg` on the even cycle). One cycle later, when the odd address `2k+1` is written, `write_data = {data_reg, data_in}` now holds the correct pair (even value in the upper half, odd value captured this cycle in the lower half), written to row `k`. The even-address write is a harmless transient: it gets overwritten by the odd-address write to the same row one cycle later, and — thanks to the ping-pong scheme (ADR-0003) never reading a buffer while it is still being written — no reader ever observes that transient value.

## 3. Control signal mapping

Same convention as the coordinate memory wrapper: `CENA` tied to `1'b0` (permanently enabled, same power-gating note as `coord_mem_wrapper.md` §5), `WENA = ~we`.

## 4. Known limitations / notes

- Same fixed-address-width consequence as the coordinate memory wrapper (`ADDR_W` now follows the macro's physical size rather than `$clog2(NB_POINTS)`) — see the upcoming ADR-0007.
- The `RAM2P_1024X32` module shown here is a **behavioral simulation model only**; the macro used in synthesis and place-and-route is an opaque black box characterized by its `.lib`/`.lef` views, not this Verilog.
