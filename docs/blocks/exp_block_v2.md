# Block: `exp` v2 (`dist_mat_arg_exp_v2`)

> This document only covers what changed for v2. Everything not mentioned here — the per-stage pipeline math (distance, argument scaling, LUT saturation), the quantization formats, the shared coordinate BRAM addressing pattern — is unchanged from v1 and already described in [`exp_block.md`](exp_block.md). Read that document first if you haven't already.

Implements [ADR-0008](../decisions/0008-on-the-fly-dual-exp-pipeline.md): removes the row buffering this block used to write into (the ping-pong scheme, [ADR-0003](../decisions/0003-ping-pong-buffering.md)) and streams `P_ij` directly to `grad_v2` instead, using a second, duplicated compute pipeline to avoid doubling the total row-sweep time.

RTL: [`dist_mat_arg_exp_v2.sv`](../../rtl/dist_mat_arg_exp_v2.sv)

---

## 1. What changed, at a glance

- **No more row buffer, no more flow control.** `credit_avail` is gone entirely — there's nothing left downstream for it to protect (no ping-pong buffer, no arbiter). `grad_v2` consumes `P_ij` as it's produced, cycle by cycle.
- **Two compute pipelines instead of one.** The exact same 8-stage pipeline from v1 (see `exp_block.md` §4) is now instantiated twice, each producing its own `P_ij`-shaped output — one feeds `out_i`/`out_j`/`P_ij`/`valid_out` (the real, forwarded-downstream coefficients), the other only feeds an internal `P_ij_sum` used to accumulate `sum_row_P`. Both pipelines read the same shared coordinate stream (`coord_X`/`coord_Y`), so there's still only one coordinate BRAM read port — only the compute logic and the `exp_LUT` read port are duplicated (`index_LUT_exp_sum`/`result_exp_sum`, a second port on `exp_LUT`, see §3).
- **The FSM now sweeps one extra row per full pass.** See §2.

## 2. Why the pipelines run one row apart, and why there's an extra pass

The problem this design solves: normalizing a row requires its full sum, which is only known once the whole row has been produced — but by then, the row's coefficients are gone if nothing stored them. Instead of buffering the row (v1's answer), v2 computes each row **twice**, on two pipelines running exactly one pass apart, so that by the time the "real" coefficients for a row are streamed out, that row's sum was already computed and forwarded on a previous pass.

Concretely, during a single pass (one full sweep of `j = 0..NB_POINTS-1`, indexed here by the value of `cnt_i` for that pass):

- The **sum pipeline** computes `sum_row_P` for row `cnt_i`, using the coordinate of point `cnt_i` as its reference (freshly fetched this pass).
- The **`P_ij` pipeline** computes and forwards the real coefficients for row `cnt_i - 1`, using the coordinate of point `cnt_i - 1` — captured on the *previous* pass, and held in a second register stage (`coord_X_i`/`coord_Y_i`, one pass behind `coord_X_i_sum`/`coord_Y_i_sum`) specifically so it's still available now.

This is why the FSM's boundary conditions changed from v1 (see `S_LAST_WAIT` in the RTL): the row counter now runs from `cnt_i = 0` up to and including `cnt_i = NB_POINTS` — one pass more than the `NB_POINTS` rows actually being processed:

| Pass (`cnt_i`) | Sum pipeline active? | `P_ij` pipeline active? |
|---|---|---|
| `0` | Yes — computes the sum for row 0 | No (`issue_j` is gated off by `cnt_i != 0`; there's no "row -1" to forward) |
| `1 .. NB_POINTS-1` | Yes — computes the sum for row `cnt_i` | Yes — forwards row `cnt_i - 1`, using that row's sum from the previous pass |
| `NB_POINTS` | No (`issue_j_sum` is gated off by `cnt_i != NB_POINTS`; every row already has a sum) | Yes — forwards the last row, `NB_POINTS - 1` |

Total: `NB_POINTS + 1` passes instead of `2 × NB_POINTS` for a naive "compute every row twice, sequentially" approach — this is exactly the area/latency trade-off argued in ADR-0008.

## 3. Interface changes vs. v1

| Port | Change |
|---|---|
| `credit_avail` | Removed (no buffer left to protect) |
| `index_LUT_exp` / `result_exp` | Unchanged — serves the `P_ij` pipeline |
| `index_LUT_exp_sum` / `result_exp_sum` | New — second `exp_LUT` read port, serves the sum pipeline, see ADR-0008 |
| `out_i` / `out_j` | Unchanged in role (tag the forwarded `P_ij`) |
| `out_i_sum` / `out_j_sum` | New — tag which row/column the just-completed `sum_row_P` belongs to |
| `sum_row_P` / `valid_sum_row_P` | Unchanged in role and timing (strobed once per row, on the sum pipeline's last column) |
| `P_ij` / `valid_out` | Unchanged in role — still the forwarded, per-coefficient output, just no longer routed through an arbiter |

## 4. Known items

- `i_1 <= cnt_i - 1` underflows (wraps to all-ones) on the very first pass (`cnt_i == 0`). Harmless: `valid_1` is gated off by `issue_j` (itself gated by `cnt_i != 0`) on that same pass, so the wrapped tag is never latched as valid downstream. Flagged here for anyone reading the waveform cold, not because it needs fixing.
