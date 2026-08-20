# Block: `grad` (`norm_entropy_grad`)

Consumes one row of `P_ij` (produced by the `exp` block, buffered through the ping-pong arbiter) per sweep: normalizes each coefficient, accumulates the weighted sum of neighbour coordinates, derives the Ricci gradient for the row's reference point, and applies the entropy-modulated update force to produce the `mult_act_X/Y` contribution consumed by the `upd` block. The Gini entropy of the row (ADR-0005) is computed here too, directly from the same normalized `P_ij` stream.

See [`ARCHITECTURE.md`](../ARCHITECTURE.md) for the toplevel view. Related decisions: [ADR-0001](../decisions/0001-fixed-point-quantization-chain.md) (quantization chain), [ADR-0002](../decisions/0002-single-row-streaming-vs-full-matrix.md) (row streaming), [ADR-0003](../decisions/0003-ping-pong-buffering.md) (ping-pong buffering), [ADR-0004](../decisions/0004-lut-exponential-vs-cordic.md) (LUT-based inverse), [ADR-0005](../decisions/0005-gini-entropy-vs-shannon.md) (Gini entropy).

RTL: [`norm_entropy_grad.sv`](../../rtl/norm_entropy_grad.sv)

---

## 1. Role in the pipeline

For each row, once notified that `exp` has produced a complete, summed row (`valid_sum_row_P`, carrying `sum_row_P` and `out_i`):

```
sum_row_P_inv = inv_LUT[mantissa(sum_row_P)]        (mantissa-addressed, see ADR-0004)
P_ij_norm     = (P_ij * sum_row_P_inv) >> msb        (completes the division, see ADR-0004)
P_dot_X       = Σ_j P_ij_norm * X_j
P_dot_Y       = Σ_j P_ij_norm * Y_j
grad_X        = P_dot_X - X_i
grad_Y        = P_dot_Y - Y_i
entropy       = 1 - Σ_j P_ij_norm²                   (Gini entropy, see ADR-0005)
forca         = 0.002 if entropy > threshold else 0.35   (Perelman-surgery force modulation)
mult_act_X    = (grad_X * forca) >> 16
mult_act_Y    = (grad_Y * forca) >> 16
```

The `entropy > 65200` threshold and the two `forca` values (`131` ≈ `0.002 × 65536`, `22938` ≈ `0.35 × 65536`) match the reference software model's `limiar_cirurgico_fixed`/`forca_float` constants directly — a good sanity anchor if you ever need to re-derive them.

`mult_act_X/Y`, tagged with `addr_act = cnt_i`, are written out to the `memory mult_upd` buffer (see `ARCHITECTURE.md` §3), consumed by the `upd` block at the end of the step.

## 2. Interface

### Parameters

| Parameter | Meaning |
|---|---|
| `NB_POINTS` | Number of points (fixed default for now, see `docs/blocks/exp_block.md` §7 — same limitation applies here) |
| `COORD_W` | Coordinate width, fixed-point |
| `ADDR_W` | **Point** address width (used for `cnt_i`/`cnt_j`/`addr`)  |
| `P_IJ_W` | `P_ij` width, fixed-point |
| `ADDR_P_IJ_W` | `P_ij` / update address width |
| `SUM_ROW_P_W` | `sum_row_P` width |
| `ACT_W` | Update value width (`mult_act_X/Y`), signed fixed-point |
| `ENTH_W` | Entropy value width, fixed-point |
| `ADDR_LUT_INV` | Inverse LUT address width |

### Ports

| Port | Dir | Description |
|---|---|---|
| `clk`, `rst_n` | in | Clock, active-low async reset |
| `addr` | out | Address to the grad-side point coordinate BRAM (§4 in `ARCHITECTURE.md`) |
| `coord_X`, `coord_Y` | in | Coordinates read back from that BRAM |
| `addr_P_ij` | out | Read address to the ping-pong arbiter |
| `P_ij` | in | Row data read back from the arbiter |
| `index_LUT_inv`, `result_inv` | out/in | Inverse LUT port, addressed by mantissa (ADR-0004) |
| `mult_act_X`, `mult_act_Y` | out | Update contribution for the reference point of this row |
| `addr_act` | out | Address (= row index `i`) for the update write |
| `valid_out` | out | Strobe: `mult_act_X/Y` valid this cycle |
| `sum_row_P`, `out_i`, `valid_sum_row_P` | in | Row-ready notification from the `exp` block (row sum, row index, strobe) |
| `entropy`, `valid_entropy` | out | Gini entropy of the row, and its strobe |
| `done` | out | Row fully processed (feeds `ping_pong_arbiter.line_done_grad`) |

## 3. Control FSM

| State | Behavior |
|---|---|
| `S_IDLE` | Waits for `start_pulse` (§4) |
| `S_COMPUTE_INV` | Computes the mantissa/MSB of `sum_row_P` for the inverse LUT address |
| `S_INV_WAIT` | One cycle of delay to match the inverse LUT's read latency |
| `S_FETCH_I` | Issues `addr = cnt_i` (reference point coordinates); latches `sum_row_P_inv <= result_inv` |
| `S_FETCH_WAIT` | Issues `addr = cnt_j (=0)`; captures `coord_X_i`/`coord_Y_i` from the `S_FETCH_I` response (see the flagged timing point above) |
| `S_RUN` | Streams `addr = cnt_j` and `addr_P_ij = cnt_j` across the row |
| `S_DRAIN` | Waits until both the last `mult_act` and the last `entropy` for the row have been seen (`last_mult_act_seen && last_entropy_seen`) — these two finish at different pipeline depths, so both flags are needed rather than a fixed drain count |
| `S_DONE` | Row complete, `done` asserted for one cycle |

## 4. Row-ready notification and the pending latch

`exp` notifies `grad` that a new row is ready via a single-cycle pulse (`valid_sum_row_P`, carrying `sum_row_P` and `out_i`). If `grad` happens to be idle exactly when this pulse arrives, it is consumed immediately (`start_pulse = (S_IDLE) && valid_sum_row_P`). If `grad` is still busy finishing the previous row, the pulse would otherwise be lost — so it is latched instead (`pending`, `sum_row_P_latched`, `out_i_latched`), and consumed as soon as `grad` returns to `S_IDLE` (`start_pulse = (S_IDLE) && (valid_sum_row_P || pending)`). This is a single-slot queue: it assumes at most one row-ready notification can be pending at a time, which holds as long as the ping-pong credit depth (ADR-0003) doesn't let `exp` get more than one row ahead of `grad` finishing its *previous* row's notification being picked up — worth keeping in mind if the credit depth in `ping_pong_arbiter` is ever increased.

## 5. Inverse LUT addressing (mantissa-based division)

Same mechanism as the reference software model and ADR-0004: the MSB position of `sum_row_P` is found combinationally (`msb_comb`, priority search from the top bit down), the mantissa is normalized by shifting left by `(31 - msb)`, and the top 10 bits of that mantissa address the inverse LUT. `P_ij_norm` is then reconstructed as `(P_ij * sum_row_P_inv) >> msb`.

## 6. Compute pipeline

1. **Stage 0** — `P_ij_norm = (P_ij * sum_row_P_inv) >> msb`; `coord_X_d`/`coord_Y_d` capture the matching neighbour coordinates in lockstep.
2. **Stage 1** — `mult_X = P_ij_norm * coord_X_d`, `mult_Y = P_ij_norm * coord_Y_d`.
3. **Stage 2** — Running accumulation into `P_dot_X_reg`/`P_dot_Y_reg`; on the last column of the row, finalizes `P_dot_X`/`P_dot_Y` with a final `>> 16` shift.
4. **Stage 3** — On the last column only (`j_3 == NB_POINTS-1`), computes `grad_X = P_dot_X - X_i`, `grad_Y = P_dot_Y - Y_i`.
5. **Stage 4** — Applies the entropy-modulated force: `mult_act_X/Y = (grad * forca) >>> 16`.

In parallel, **the Gini entropy accumulator** taps `P_ij_norm` directly at Stage 0 (`p_squared = P_ij_norm²`, accumulated every valid cycle, finalized as `entropy = 65536 - Σp²` on the last column) — it does not go through the `mult_X`/`P_dot`/`grad` chain at all, which is why it becomes available, and updates `forca`, before `mult_act_X/Y` is computed later in the same row's pipeline. This ordering is what lets `forca` reflect *this row's own* entropy by the time it's applied to *this row's own* update, with no extra synchronization needed.

