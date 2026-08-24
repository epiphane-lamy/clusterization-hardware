# ADR-0005 — Gini entropy instead of Shannon entropy

## Status
Accepted

## Context
The reference software model uses Shannon entropy to measure the dispersion of each normalized row of `P`, a value subsequently used to modulate the displacement intensity of each point. Calculating Shannon entropy requires a `log()`, which poses exactly the same hardware implementation problem as the exponential addressed in [ADR-0004](0004-lut-exponential-vs-cordic.md).

## Options considered

1. **LUT for `log()`, following the same principle as the `exp()` LUT.**
   - Consistent with the approach already chosen for the exponential.
   - Requires a second dedicated LUT, with its own input range analysis, doubling the area dedicated to nonlinear functions.

2. **Gini entropy, as an alternative dispersion measure.**
   - Can be used as a dispersion measure instead of Shannon entropy for this purpose (modulating the displacement intensity according to the dispersion of a point's similarities with its neighbors).
   - Can be calculated directly from a sum of squares of the normalized row coefficients (`1 - Σ p_ij²`), without any additional nonlinear function — only multiplications already present in the calculation pipeline.

## Decision
Use of Gini entropy (`H_fixed = 1 - Σ p_ij²`, calculated in Q0.16) instead of Shannon entropy, as the criterion for modulating the displacement force of each point.

## Consequences

**Positive**
- No additional LUT or combinational stage dedicated to a nonlinear function: the Gini calculation uses the multipliers already used by the `exp`/`grad` pipeline.
- Fully compatible with the pipelined flow without a hidden buffer (see ARCHITECTURE.md §6): the `Σ p_ij²` accumulation is performed on the fly, just like the normalization sum.
- Further reduces the total area dedicated to nonlinear functions in the design.

**Negative / limitations**
- Introduces an **intentional divergence** from the reference software model, which uses Shannon entropy: the force modulation trigger threshold (`limiar_cirurgico`) must be recalibrated specifically for the Gini value scale rather than being reused directly from the Shannon threshold.
- The behavioral difference between the two entropy measures in edge cases (distributions very close to uniform or highly concentrated) has not been exhaustively characterized.
