# ADR-0001 — Stage-by-stage fixed-point quantization, with a bit-exact reference model

## Status
Accepted

## Context
The reference software model performs all its calculations using double-precision floating-point arithmetic (Euclidean distance, Gaussian argument, exponential, normalization, gradient, position update). A floating-point hardware implementation of this pipeline would be disproportionate in terms of area and power consumption compared to the actual precision requirements of the algorithm.

## Options considered

1. **Global and approximate floating-point → fixed-point conversion**: choose a single "comfortable" Q format (e.g. Q16.16 everywhere) for the entire pipeline, without detailed analysis.
   - Simple to implement, but risks over-dimensioning some buses (wasted area) or under-dimensioning other stages (uncontrolled precision loss).

2. **Stage-by-stage quantization, with error measurement at each stage against the floating-point reference calculation.**
   - Requires more upfront analysis work (determining the most appropriate Q format for each stage: distance, argument, exponential, normalization sum, gradient, update).
   - Makes it possible to size each bus as tightly as possible, with full knowledge of the induced error.
   - Direct by-product: once the entire pipeline has been quantized, it becomes possible to run a **fully fixed-point software model**, which exactly reproduces the calculations that will be performed in hardware.

## Decision
Stage-by-stage quantization (option 2), with systematic measurement of the deviation from floating-point at each stage. The resulting fixed-point software model serves as the bit-exact reference model for RTL testbenches: each intermediate signal produced by the hardware simulation is directly compared against the intermediate results produced by this model, rather than against a floating-point resimulation.

## Consequences

**Positive**
- Each data bus is sized as tightly as possible, limiting the area/register cost without sacrificing the required precision.
- The bit-exact reference model eliminates ambiguity when debugging the testbench: a discrepancy between the RTL and the reference model is necessarily an RTL bug, rather than a floating-point/fixed-point comparison rounding artifact.
- The approach is documented and reproducible for potential future changes to the Q format of a given stage.

**Negative / limitations**
- More initial analysis work than an approximate global conversion.
- The fixed-point reference model must be kept consistent with the RTL throughout architectural changes (any change to the Q format on the hardware side must be reflected on the software model side).
