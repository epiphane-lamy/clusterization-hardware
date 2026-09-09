# Block: `grad` v2 (`norm_entropy_grad_v2`)

Consumes `P_ij` directly from `exp_v2`, coefficient by coefficient, as it's produced — no row buffer, no arbiter, and no control FSM of its own anymore. Implements the `grad`-side half of [ADR-0008](../decisions/0008-on-the-fly-dual-exp-pipeline.md).

See [`exp_block_v2.md`](exp_block_v2.md) for the row-offset mechanism this block's timing depends on (essential background before reading §3 below), and [`grad_block.md`](grad_block.md) for the v1 version this one replaces.

RTL: [`norm_entropy_grad_v2.sv`](../../rtl/norm_entropy_grad_v2.sv)

---

## 1. Role

For each row, once `exp_v2` signals a row's sum is ready:

```
sum_row_P_inv = inv_LUT[mantissa(sum_row_P)]     (mantissa-addressed, see ADR-0004)
P_ij_norm     = (P_ij * sum_row_P_inv) >> msb     (streamed live as P_ij arrives, no buffering)
P_dot_X       = Σ_j P_ij_norm * X_j
P_dot_Y       = Σ_j P_ij_norm * Y_j
grad_X        = P_dot_X - X_i
grad_Y        = P_dot_Y - Y_i
entropy       = 1 - Σ_j P_ij_norm²                (Gini entropy, ADR-0005)
forca         = 0.002 if entropy > threshold else 0.35
mult_act_X    = (grad_X * forca) >> 16
mult_act_Y    = (grad_Y * forca) >> 16
```

Same formulas, same constants (`0.35`, `0.002`, threshold `65200`) as v1 — see `grad_block.md` §1 for the full cross-check against the reference model's constants. What changed is entirely *how* `P_ij` arrives and how the block is sequenced, not the math itself.

## 2. Interface changes vs. v1

| Change | Detail |
|---|---|
| No more control FSM | This block has no `state_t`/`current_state` at all. It's a free-running pipeline, reacting directly to `valid_P_ij` and `valid_sum_row_P` pulses as they arrive. |
| `addr_P_ij` removed | v1 issued a read address to the ping-pong arbiter (`addr_P_ij`) to request each coefficient. v2 has no such port — `exp_v2` pushes `P_ij`/`valid_P_ij` directly, unrequested. |
| `out_i` (v1) → `out_i_sum` | Renamed to match `exp_v2`'s port naming — still "which row this sum applies to". |
| `done` is now purely combinational | `done = valid_out && (out_j == NB_POINTS-1)` — derived directly from the pipeline's own tags, rather than an FSM reaching a `S_DONE` state. Same "once per row" meaning as v1's `done`. |

## 3. Column tracking without an address request

Since `exp_v2` pushes coefficients rather than responding to requests, this block tracks its own position in the row purely from the incoming stream: `cnt_j` increments every cycle `valid_P_ij` is asserted, wrapping back to `0` after `NB_POINTS - 1` — no explicit reset tied to a new row is needed, since the wraparound itself re-synchronizes every row boundary (relies on `exp_v2` producing exactly `NB_POINTS` valid pulses per row, no more, no less).

## 4. Reference-point capture

A two-stage sequence, triggered by `valid_sum_row_P`:
1. `valid_coord_i_1` pulses for one cycle, during which `addr` is steered to `cnt_i` to fetch the reference point's coordinate from the BRAM.
2. `valid_coord_i_2` (the following cycle) triggers the capture of that BRAM response into `coord_X_i`/`coord_Y_i`, through a small two-deep shift register (`coord_X_i_next` → `coord_X_i`) mirroring the same "register the input once for timing, then use it" pattern seen elsewhere in this project (e.g. `exp_v2`'s own reference-point capture).

## 5. Inverse-LUT addressing, without a dedicated state

Unlike v1 (which only recomputed `msb`/`mantissa` during a dedicated `S_COMPUTE_INV` state), this block recomputes them **every cycle**, unconditionally, from whatever `sum_row_P_i` currently holds. Since `sum_row_P_i` itself only changes once per row (updated solely inside the `valid_sum_row_P` branch), the recomputed values settle to the correct, stable result one cycle after a new row's sum arrives, and then stay stable — redundantly recomputed every cycle — for the rest of that row. Functionally equivalent to v1's gated version, at the cost of some unnecessary switching activity (and an inverse-LUT read every cycle rather than once per row) now that there's no FSM state to gate it on.

## 6. Compute pipeline

Same five-stage structure as v1 (`grad_block.md` §6): normalize → multiply by neighbour coordinate → accumulate `P_dot` → derive the gradient on the row's last column → apply the entropy-modulated force. The Gini entropy accumulator taps `P_ij_norm` at stage 0 exactly as in v1, independently of the `P_dot`/gradient chain, for the same reason: `forca` needs to be ready before `mult_act_X/Y` is computed for the same row.
