# Block: `cluster_assign`

Final pass of the pipeline (`ARCHITECTURE.md` §3, "Partie 2"): scans the converged point coordinates and assigns a cluster number to each point, grouping points that ended up within a fixed distance tolerance of each other. Directly implements the reference model's final grouping pass (`cluster_labels[i] = -1` sentinel replaced by a valid bit, per [ADR-0006](../decisions/0006-valid-bit-for-unassigned-cluster.md)).

See [`ARCHITECTURE.md`](../ARCHITECTURE.md) for the toplevel view. Related decisions: [ADR-0001](../decisions/0001-fixed-point-quantization-chain.md) (quantization chain), [ADR-0006](../decisions/0006-valid-bit-for-unassigned-cluster.md) (valid bit instead of `-1`).

RTL: [`cluster_assign.sv`](../../frontend/rtl/cluster_assign.sv)

---

## 1. Algorithm

Same logic as the reference model's final clustering pass, adapted to the valid-bit representation of ADR-0006:

```
for i in 0 .. NB_POINTS-1:
    if point i already has a valid cluster: skip to the next i
    assign point i the current cluster number (num_cluster)
    for j in i+1 .. NB_POINTS-1:
        if point j does not yet have a valid cluster:
            if squared_distance(i, j) <= TOL:
                assign point j the same cluster number (num_cluster)
    num_cluster += 1
```

The `TOL` parameter (`422144877`) is the same squared-distance tolerance as the reference model's `tol_fixed`, precomputed in software.

Since ADR-0006 replaced the `-1` sentinel with an explicit valid bit, there's no need to ever write a placeholder value for an unassigned point: the cluster number field only needs to be written when a point is actually being labelled, and "unassigned" is conveyed purely by the valid bit's reset state.

## 2. Interface

### Parameters

| Parameter | Meaning |
|---|---|
| `NB_POINTS` | Number of points (fixed default for now, see `docs/blocks/exp_block.md` §7 — same limitation applies here) |
| `COORD_W` | Coordinate width, fixed-point |
| `ADDR_W` | Point / cluster address width |
| `TOL` | Squared-distance tolerance, precomputed in software (see §1) |

### Ports

| Port | Dir | Description |
|---|---|---|
| `clk`, `rst_n` | in | Clock, active-low async reset |
| `start` | in | Launches the clustering pass |
| `addr_coord` | out | Address to the final (updated) point coordinate memory |
| `coord_X`, `coord_Y` | in | Coordinates read back |
| `addr_cluster` | out | Address to the cluster memory |
| `we_cluster` | out | Write enable for the cluster memory (see §4 for the exact timing) |
| `valid_cluster` | in | Valid bit read back at `addr_cluster`: `0` = not yet assigned, `1` = already assigned (ADR-0006) |
| `cluster_out` | out | Cluster number to write |
| `done` | out | Clustering pass complete |

## 3. Control FSM

| State | Behavior |
|---|---|
| `S_IDLE` | Waits for `start` |
| `S_FETCH_I` | Issues `addr_coord = addr_cluster = cnt_i`; also pre-sets `cnt_j = cnt_i + 1` for the inner loop |
| `S_FETCH_WAIT` | Captures `coord_X_i`/`coord_Y_i`; reads back `valid_cluster` for point `i` — if already assigned, `cnt_i` advances and the FSM loops back to `S_FETCH_I` for the next `i`; otherwise moves to `S_WRITE_I` |
| `S_WRITE_I` | Labels point `i` itself with `num_cluster` |
| `S_FETCH_J` | Issues `addr_coord = addr_cluster = cnt_j` for the candidate neighbour `j` |
| `S_CHOICE_COMPUTE` | Reads back `valid_cluster` for point `j` — if already assigned, `j` is skipped (advance `cnt_j`, or move on to the next `i` if `j` was the last point); otherwise starts the distance pipeline (§4) |
| `S_COMPUTE` | Waits for the 3-stage distance pipeline to produce a result (`valid_out`) |
| `S_WRITE` | Bookkeeping only — advances `cnt_j` to the next candidate, or `cnt_i`/`num_cluster` to the next reference point once all `j` have been checked (see the timing note in §4: the actual cluster memory write for `j` happens one cycle *before* this state, not during it) |
| `S_DRAIN` | Lets the 3-stage pipeline flush |
| `S_DONE` | Clustering pass complete |

The inner loop only ever compares `j > i`: since points are processed in order and an already-clustered point is always skipped, this is the same optimization as the reference model's `for (j = i+1; ...)` — no need to compare a pair twice.

## 4. Distance pipeline and write timing

The 3-stage distance check (`dx`/`dy` → squares → `dist_sq`, compared against `TOL`) is structurally the same pattern as in `dist_mat_arg_exp` (see `docs/blocks/exp.md` §4), just shorter (no LUT stage, only a threshold comparison at the end):

1. `dx = X_i - X_j`, `dy = Y_i - Y_j`
2. `x_2 = dx*dx`, `y_2 = dy*dy`
3. `dist_sq = x_2 + y_2`; result register: `hit_j = (dist_sq <= TOL)`, `cluster_out_j = num_cluster` (captured at that time), tagged `valid_out`

**Timing note:** `we_cluster = (valid_out && hit_j) || (current_state == S_WRITE_I)` and `cluster_out` are both driven combinationally from the pipeline's `valid_out`/`hit_j` outputs directly, not gated by the FSM being in state `S_WRITE`. Since the FSM only transitions from `S_COMPUTE` to `S_WRITE` the cycle *after* `valid_out` first becomes true, the actual cluster memory write for point `j` happens during the last cycle the FSM is still nominally in `S_COMPUTE` — the `S_WRITE` state itself only performs the `cnt_i`/`cnt_j` bookkeeping for moving on to the next candidate. Worth keeping in mind when reading waveforms: don't expect `we_cluster` to align with `current_state == S_WRITE`.


## 5. Known limitations / cleanup TODO

- Same `NB_POINTS`-as-fixed-default limitation as the other blocks (see `docs/blocks/exp_block.md` §7).
