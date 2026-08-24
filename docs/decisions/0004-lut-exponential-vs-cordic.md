# ADR-0004 — LUT for exponential and inverse, instead of CORDIC

## Status
Accepted

## Context
The Gaussian kernel calculation of matrix `P` requires an exponential (`exp(argument)`), and the normalization of each row requires a division, implemented as a multiplication by the inverse of the row sum. These two nonlinear functions do not have a trivial hardware implementation.

## Options considered

1. **CORDIC** (or an equivalent iterative algorithm) for calculating the exponential and inverse.
   - Generic solution, covering any input range without prior assumptions about the distribution of the arguments.
   - Significant architectural cost: multi-stage iterative pipeline, heavy to integrate for a gain in generality that is not necessary here (see below).

2. **LUT (lookup table), sized after studying the actual range of arguments observed in the reference software model.**
   - Requires prior analysis of the distribution of the arguments passed to `exp()`` on real-world cases, to verify that a reasonably sized LUT can cover the useful range without excessive loss.
   - Much lower hardware cost than CORDIC (a directly addressed memory, with no iterative pipeline).

## Analysis motivating the decision
A study of the range of values taken by the `exp()` argument in the reference software model showed that this argument, always negative, remains **bounded and quickly saturates toward 0** below a certain threshold (beyond which the contribution to the Gaussian kernel is negligible anyway). This narrow range makes a LUT directly addressed by the quantized argument both accurate and reasonably sized.

For the inverse (used in normalization), the dynamic range of the row sum to be inverted is much wider. Direct addressing by the value would have required an oversized LUT. The chosen solution addresses the inverse LUT using the **mantissa** of the sum (after extracting the most significant bit and shifting), making it possible to cover the entire useful dynamic range with a fixed and reasonably sized LUT (1024 entries).

## Decision
Implementation of `exp()` and the inverse using LUTs:
- `exp` LUT, directly addressed by the quantized argument (Q6.10), 10241 entries in Q0.16.
- Inverse LUT, addressed by the mantissa of the row sum, 1024 entries in Q0.16.

## Consequences

**Positive**
- Much lower hardware cost than a CORDIC implementation: simple addressed memory, with no multi-stage iterative pipeline.
- Fixed and known calculation latency (simple memory access), rather than the variable or fixed-but-high number of iterations of a CORDIC.
- Mantissa-based addressing for the inverse makes it possible to cover a wide dynamic range without increasing the LUT size.

**Negative / limitations**
- Solution specific to the distribution of arguments observed for this dataset and algorithm — unlike CORDIC, it cannot be generalized as-is to another computational context without revalidating the range analysis.
- Precision is limited by the LUT resolution (additional quantization compared to a direct calculation), whose impact was measured in the overall quantization chain (see [ADR-0001](0001-fixed-point-quantization-chain.md)).
- Fixed memory cost of the two LUTs (approximately 20 KB in total), to be weighed against the area that a CORDIC would have occupied — considered favorable here given the gain in control simplicity.
