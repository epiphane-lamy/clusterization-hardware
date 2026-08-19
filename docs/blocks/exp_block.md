# Block: `exp` (`dist_mat_arg_exp`)

Produces one row of the unnormalized Gaussian-kernel similarity matrix `P` per sweep. For a fixed reference point `i`, it streams the squared distance to every other point `j`, converts it into an exponential argument, and looks up `P_ij = exp(arg_ij)` in a LUT — one coefficient per cycle, forwarded downstream without ever storing the row on its own side.

See [`ARCHITECTURE.md`](../ARCHITECTURE.md) for how this block fits in the toplevel pipeline. Related decisions: [ADR-0001](../decisions/0001-fixed-point-quantization-chain.md) (quantization chain), [ADR-0002](../decisions/0002-single-row-streaming-vs-full-matrix.md) (row streaming instead of full matrix), [ADR-0003](../decisions/0003-ping-pong-buffering.md) (ping-pong buffering, credit-based flow control), [ADR-0004](../decisions/0004-lut-exponential-vs-cordic.md) (LUT instead of CORDIC).

RTL: [`dist_mat_arg_exp.sv`](../../rtl/dist_mat_arg_exp.sv)

---

## 1. Role in the pipeline

For each iteration step, this block scans all `NB_POINTS` reference rows `i = 0 .. NB_POINTS-1`. For each row, it streams all `NB_POINTS` columns `j = 0 .. NB_POINTS-1`, computing:

```
D2_ij      = (x_i - x_j)^2 + (y_i - y_j)^2
arg_ij     = D2_ij * K_step          (K_step = -1 / (2*T^2), precomputed per step)
P_ij       = exp(arg_ij)             (via LUT, see §4)
sum_row_P += P_ij                    (accumulated across the row, see §5)
```

`P_ij`, its coordinates `(out_i, out_j)`, and a `valid_out` strobe are emitted one pair per cycle to the ping-pong arbiter. `sum_row_P` is emitted once per row, right after the last column, for later use by the `grad` block during normalization (see `ARCHITECTURE.md` §6).

## 2. Interface

### Parameters

| Parameter | Meaning |
|---|---|
| `NB_POINTS` | Number of points processed (currently a hardcoded default; see §7, known limitations) |
| `COORD_W` | Width of a fixed-point coordinate |
| `ADDR_W` | Address width for the point BRAM (`⌈log2(NB_POINTS)⌉`) |
| `P_IJ_W` | Width of a fixed-point `P_ij` coefficient |
| `ADDR_P_IJ_W` | Address width for the `P_ij` coefficient |
| `SUM_ROW_P_W` | Width of the `sum_row_P` accumulator |
| `ADDR_LUT_EXP` | Address width of the `exp` LUT |
| `STEP_W` | Width of the step index counter |
| `K_W` | Width of the precomputed, signed, negative `K_step` constant |
| `D2_W` | Width of `D2_ij` |

### Ports

| Port | Dir | Description |
|---|---|---|
| `clk`, `rst_n` | in | Clock, active-low async reset |
| `start` | in | Launches a full sweep (all rows) for the current step |
| `step_idx` | in | Current iteration index, selects `K_step` from the ROM |
| `addr` | out | Shared address to the point coordinate BRAM (multiplexed between fetching `i` and streaming `j`) |
| `coord_X`, `coord_Y` | in | Coordinates read back from the point BRAM (1-cycle synchronous read latency) |
| `index_LUT_exp` | out | Address into the `exp` LUT |
| `result_exp` | in | `exp` LUT output (1-cycle synchronous read latency) |
| `P_ij` | out | Similarity coefficient for `(out_i, out_j)`, or 0 if the argument saturated (§4) |
| `out_i`, `out_j` | out | Row/column indices matching the `P_ij` on the bus this cycle |
| `valid_out` | out | Strobe: `P_ij`/`out_i`/`out_j` valid this cycle |
| `sum_row_P` | out | Row sum, valid once per row (see `valid_sum_row_P`) |
| `valid_sum_row_P` | out | Strobe: `sum_row_P` valid this cycle (asserted when `out_j == NB_POINTS-1`) |
| `credit_avail` | in | Flow-control input from downstream (ping-pong arbiter): permits starting the next row |
| `done` | out | Full sweep (all rows) completed |

## 3. Control FSM

| State | Behavior |
|---|---|
| `S_IDLE` | Waits for `start`; resets the row counter `cnt_i` |
| `S_FETCH_I` | Issues `addr = cnt_i` to fetch the reference point for the new row |
| `S_FETCH_WAIT` | Issues `addr = cnt_j` (`= 0`); captures `coord_X_i`/`coord_Y_i` from the BRAM response |
| `S_RUN` | Streams `addr = cnt_j`, incrementing every cycle, until the last column of the row |
| `S_LAST_WAIT` | Last column of the row issued; **waits for `credit_avail`** before moving to the next row (or to `S_DRAIN` if the row just completed was the last one) |
| `S_DRAIN` | Lets the 8-stage compute pipeline flush the in-flight data of the last row |
| `S_DONE` | Sweep complete, `done` asserted for one cycle, returns to `S_IDLE` |

The `S_LAST_WAIT → credit_avail` gate is the direct RTL counterpart of the ping-pong contract described in ADR-0003: this block cannot start writing the next row into a ping-pong buffer until the arbiter confirms the buffer is free (i.e. the `grad` block has finished reading the previous row out of it).

## 4. Compute pipeline (8 stages)

The datapath is a fixed 8-stage pipeline, one register stage per cycle, tagged with `(i, j, valid)` shift registers so that each intermediate result stays associated with the correct point pair as it flows through:

1. `dx = x_i - x_j`, `dy = y_i - y_j`
2. `x_2 = dx*dx`, `y_2 = dy*dy`
3. `D2_ij = x_2 + y_2`
4. `arg_exp_brut = D2_ij * K_step` (signed, always ≤ 0)
5. `arg_exp_q6_10 = arg_exp_brut >>> 22` (arithmetic shift down to the Q6.10 format expected by the LUT address, per the quantization chain in ADR-0001)
6. Range check: if `arg_exp_q6_10 ∈ [-10240, 0]`, bias it into a valid LUT address (`arg_shifted = arg_exp_q6_10 + 10240`); otherwise flag the argument as out-of-range (`flag_exp = 1`) — the same saturation-to-zero behavior as the reference software model for arguments below the LUT's lower bound (see `exp_lut` construction in the C model, and ADR-0004)
7. One extra cycle of delay on `flag_exp`/`i`/`j`/`valid` to stay aligned with `result_exp`, which the external LUT returns one cycle after `index_LUT_exp` is driven
8. `P_ij = flag_exp_d ? 0 : result_exp` — final output register

`PIPE_DEPTH = 8` in the RTL is exactly this depth, used by `S_DRAIN` to know how many cycles to wait for the last row's data to exit the pipeline before asserting `done`.

## 5. Row sum accumulation

`sum_row_P` is accumulated incrementally as each `P_ij` of the row is produced (`sum_row_P_reg += P_ij`), and latched out as `sum_row_P`/`valid_sum_row_P` on the cycle where `out_j == NB_POINTS-1`. This lets the row sum needed for normalization (`ARCHITECTURE.md` §6) be available to the `grad` block without a second pass over the row.

## 6. Assumptions / preconditions

- The point coordinate BRAM is a single read port, synchronous, 1-cycle latency, shared between fetching the reference point `i` and streaming the neighbours `j` (arbitrated purely by FSM state, no explicit request/grant needed since the two phases never overlap in time for a given row).
- The `exp` LUT is a synchronous ROM with a 1-cycle read latency, addressed directly by the biased Q6.10 argument (see ADR-0004).
- `K_step` values for all steps are precomputed in software and preloaded via `$readmemh("k_step_rom.hex", ...)`.

## 7. Known limitations / cleanup TODO

- `NB_POINTS` is currently a fixed parameter default rather than a value loaded at the start of computation, even though the intent is to support a runtime-configurable point count. To revisit once the point count is driven dynamically.
