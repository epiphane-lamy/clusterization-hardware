# Block: `ping_pong_arbitrer`

Arbitrates access to the two `P_ij` line buffers (memory A / memory B) that implement the ping-pong scheme between the `exp` block (writer) and the `grad` block (reader), and generates the credit-based flow control signal (`credit_avail`) consumed by `exp`.

See [`ARCHITECTURE.md`](../ARCHITECTURE.md) §4 for the toplevel view of the ping-pong mechanism, and [ADR-0003](../decisions/0003-ping-pong-buffering.md) for the design rationale. This module is the direct RTL implementation of that decision.

RTL: [`ping_pong_arbiter.sv`](../../rtl/ping_pong_arbiter.sv)


---

## 1. Role in the pipeline

Physically, buffers A and B are two single-port memories, each large enough to hold one row of `P` (`NB_POINTS` entries). At any given time, `exp` is writing the row currently in flight into one buffer while `grad` is reading the previous, already-completed row out of the other buffer. This module does not store any data itself — it only:

- Routes `exp`'s write requests to the correct physical buffer (A or B), based on which row is currently being written.
- Routes `grad`'s read requests to the correct physical buffer, based on which completed row is currently being read.
- Tracks, via a credit counter, how many buffers are currently free for `exp` to write into, and exposes that as `credit_avail`.

## 2. Interface

### Parameters

| Parameter | Meaning |
|---|---|
| `ADDR_W` | Address width within a row (`⌈log2(NB_POINTS)⌉`) |
| `P_IJ_W` | Data width of a `P_ij` coefficient |
| `ADDR_P_IJ_W` | Address width for the `P_ij` coefficient |

### Ports

| Port | Dir | Description |
|---|---|---|
| `clk`, `rst_n` | in | Clock, active-low async reset |
| `valid_p_ij_exp` | in | `valid_out` from the `exp` block: a `P_ij` write is active this cycle |
| `out_i_exp` | in | `out_i` from the `exp` block: row index currently being written. Its LSB selects the destination buffer (§4) |
| `line_done_grad` | in | `done` from the `grad` block (`norm_entropy_grad`): the row currently being read has been fully consumed |
| `addr_P_ij_w`, `P_ij_w` | in | Write address/data coming from `exp` (`out_j` / `P_ij`) |
| `addr_P_ij_r` | in | Read address requested by `grad` |
| `P_ij_r` | out | Read data returned to `grad` |
| `addr_A`, `we_A`, `w_data_A`, `r_data_A` | out/out/out/in | Single read/write port to physical buffer A |
| `addr_B`, `we_B`, `w_data_B`, `r_data_B` | out/out/out/in | Single read/write port to physical buffer B |
| `credit_avail` | out | Flow control to `exp`: at least one buffer is free to start a new row |

## 3. Credit-based flow control

A 2-bit counter (`cnt_credit`), reset to `2`, tracks how many of the two buffers are currently free for `exp` to write into:

- **Consumed** (`cnt_credit -= 1`) on `row_start_exp`, a one-cycle pulse asserted when `exp` writes the first element (`addr_P_ij_w == 0`) of a new row. This is the earliest possible moment a new row can be detected, and it comes directly from `exp`'s own write stream rather than a signal delayed further down the pipeline — there is no clock-domain or pipeline skew between "a new row starts" and "a credit is spent".
- **Released** (`cnt_credit += 1`) on `line_done_grad`, when `grad` finishes reading a row out of a buffer, freeing it up.

`credit_avail = (cnt_credit != 0)`. This is exactly the signal wired into `exp`'s `credit_avail` input (see `docs/blocks/exp.md` §3): `exp` is only allowed to start writing the next row once this arbiter confirms a buffer is actually free.

Starting at `cnt_credit = 2` allows `exp` to get up to one row ahead of `grad` before stalling (both buffers can hold in-flight data — one being read, one being written — before `exp` has to wait), which is exactly the recovery depth the ping-pong scheme in ADR-0003 is meant to provide.

## 4. Buffer selection

Two independent one-bit selectors decide, each cycle, which physical buffer is targeted by the write side and by the read side:

- **`write_buf_sel = out_i_exp[0]`** — combinational, derived directly from the parity of the row index `exp` is currently writing. There is no dedicated toggle register on the write side: the buffer selection can never drift out of sync with the row actually being written, since it is read straight from the same index that produced the data.
- **`read_buf_sel`** — a registered toggle, flipped only when `line_done_grad` pulses (i.e. only when a row has genuinely finished being read). Reset to `0`, matching the fact that row 0 is always written into buffer A first.

Because rows are written in order (`0, 1, 2, ...`) and read in the same order one at a time, `write_buf_sel` and `read_buf_sel` follow the same alternating pattern, offset by exactly one row — which is precisely what keeps the writer and the reader on two different physical buffers at any moment a transaction is actually valid. This module does not enforce that invariant itself through arbitration logic; it holds as a consequence of the credit scheme in §3 combined with this parity-based addressing, not as a runtime check. This is worth keeping in mind if either the credit depth or the buffer-selection logic is changed later — the two are coupled and would need to be re-verified together.

## 5. Address / data muxing

For each buffer, the address bus defaults to the current read request (`addr_P_ij_r`) if that buffer is the one currently selected for reading, or `0` otherwise. If that same buffer is also the one currently selected for writing, the write request (`addr_P_ij_w` / `P_ij_w` / `we = valid_p_ij_exp`) overrides the default — write access always takes priority on a buffer's shared address bus whenever both would otherwise be asserted on it. In steady-state operation this override never actually conflicts with a genuine read, since (per §4) an actively written buffer and an actively read buffer are never the same one at the same time.

`P_ij_r` is selected from `r_data_A` or `r_data_B` according to `read_buf_sel`.

