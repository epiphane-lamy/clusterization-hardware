# Block: `upd` (`act_coord`)

Applies the per-point update contribution (`mult_act_X/Y`, produced by the `grad` block and staged in `memory mult_upd`) to the current coordinates, one point at a time, closing out the iteration. This is the `upd block` in [`ARCHITECTURE.md`](../ARCHITECTURE.md) §3.

RTL: [`act_coord.sv`](../../frontend/rtl/act_coord.sv)

## Role, and the duplicated-memory write

For each point `i` (sequentially, not pipelined — see note below):

```
coord_X_act = coord_X[i] + mult_act_X[i]
coord_Y_act = coord_Y[i] + mult_act_Y[i]
```

The interesting architectural detail is *how* this closes the loop with [ADR-0003](../decisions/0003-ping-pong-buffering.md)'s duplicated coordinate memories (one copy for `exp`, one for `grad`): this module only exposes a single `addr_coord` / `we_coord` / `coord_X_act` / `coord_Y_act` port. It reads the current coordinate from one memory copy, computes the update, and its write-back signals are wired at the toplevel to **both** duplicated memories at once. The two copies never need an explicit synchronization step to stay identical — they are simply both driven by the same broadcast write every time this block updates a point.

## Interface

| Port | Dir | Description |
|---|---|---|
| `start` | in | Launches the update pass over all `NB_POINTS` points |
| `addr_coord`, `we_coord` | out | Shared read/write address and write-enable, broadcast to both coordinate memory copies |
| `coord_X`, `coord_Y` | in | Current coordinates read back for point `cnt_i` |
| `coord_X_act`, `coord_Y_act` | out | Updated coordinates, written back to `addr_coord` |
| `addr_act` | out | Read address into `memory mult_upd` (same index, `cnt_i`) |
| `mult_act_X`, `mult_act_Y` | in | Update contribution read back for point `cnt_i` |
| `done` | out | All points updated |

## FSM

| State | Behavior |
|---|---|
| `S_IDLE` | Waits for `start` |
| `S_FETCH` | Issues `addr_coord = addr_act = cnt_i` |
| `S_COMPUTE` | Captures `coord_X/Y` and `mult_act_X/Y`; computes `coord_X_act`/`coord_Y_act` |
| `S_WRITE` | Asserts `we_coord`, writing the updated coordinates back to `cnt_i` (broadcast to both memories); advances to the next point or to `S_DONE` |
| `S_DONE` | Update pass complete |

Unlike `exp` and `grad`, this block processes one point at a time through a plain 3-cycle FETCH/COMPUTE/WRITE loop rather than a deep pipeline — because the same memory is alternately read from and written to for each point.

