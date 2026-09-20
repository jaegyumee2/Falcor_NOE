# NOEPartialUPass -- NOE partial U ported to Falcor

Original: `NOE/OcclusionTracing_share/cuda/src/` (OptiX/CUDA),
`NOE/Partial_U/noe_partial_u_excerpt.cu`

Following the numbering in `Fundamental_data/methods/`, this covers
**01 Plain NEE / 02 NOE exact U / 03 Partial U** as three modes of one pass.
Anything past 04 (geoadaptive, flattening, ...) was not ported.

---

## The estimator

```
Z = X + c * (U - A)

  X : visibility-corrected contribution of the selected candidate,  E[X] = direct light
  A : candidate mean of the point-sampled unshadowed contribution,  E[A] = U
  U : the unshadowed integral,                                      E[U] = U
```

| Mode | Where U comes from | Cost of U | Shadow rays |
|---|---|---|---|
| Plain NEE | none (`Z = X`) | -- | K^2 |
| NOE exact U | loop over every emitter triangle | **O(n_emit)** | K^2 |
| NOE partial U | estimated from the same J candidates | **O(J)** | K^2 |

The core of partial U:

```
candidate j proposes triangle k with probability p_k
U_k = f * Le_k * phi_k          phi_k = horizon-clipped projected solid angle
U_j = U_k / p_k                 =>  E[U_j] = sum_k U_k = U      (exact)
A_j = f * Le_k * cos_x*cos_y/d^2 / q   =>  E[A_j | k] = U_j     (exact)
```

So `U_J - A_J` is a mean-zero control variate for any J.

---

## Files

| File | Maps to |
|---|---|
| `ProjectedSolidAngle.slang` | `render_common.h:484 tri_projected_solid_angle` |
| `EmitterSampling.slang` | `:112 sample_emit_stratified`, `:845 sample_tri_bary12`, `:893 eval_cv_candidate_raw` |
| `NOEEstimator.slang` | `:647 direct_NOE_nee`, `:1231 cv_analytic_U`, `noe_partial_u_excerpt.cu` |
| `NOEPartialU.cs.slang` | the path loop in `render.cu` |
| `Params.slang`, `NOEPartialUPass.cpp/.h` | `launch_params.h` plus the host side |

The `params.emit_*` arrays were replaced by Falcor's `gScene.lightCollection`:

```
params.emit_tri[k] + tri_v*   ->  lightCollection.getTriangle(k).posW[]
params.emit_area[k]           ->  .area
params.emit_emission[k]       ->  lightCollection.getAverageRadiance(k)
params.emit_cdf               ->  gEmitCdf (built on the host from area or flux)
```

So `k` IS Falcor's emissive triangle index and one level of indirection is gone.

---

## Running

```
build/windows-vs2022/bin/Release/Mogwai.exe --script=NOE/script/NOEPartialU.py
```

Output channels:
- `color` -- the final image
- `X`, `A`, `U` -- the three estimators at the **primary bounce**. Use them to compute
  `c* = Cov(lum X, lum A) / Var(lum A)` offline, or to compare `U` between partial and
  exact mode directly.

### The A/B to run first (the one the excerpt header points at)

Change only the `Estimator` setting and compare RMSE on the same scene.

1. `NOE exact U` vs `NOE partial U` -- this is the real question.
   Per the excerpt, on the 15 scenes with few lights (depth 1), partial U was a
   **16% quality loss** against exact U. It needs many-light scenes and/or deeper
   paths to pay for itself.
2. `NOE partial U` vs `Plain NEE` -- dropping the control term entirely cost 24%, so
   the within-triangle share is not negligible.
3. Sweep `J` -- the cost/quality curve of partial U.
4. Sweep `c` -- c = 1 measured best. Any c stays unbiased, so brightness will not
   change, only variance.

### Checking for bias

Enable `AccumulatePass`, converge fully, and **all three modes must produce the same
image**. All three are unbiased, so they converge to the same value. If they do not,
something is wrong, and gotchas 1-3 from the excerpt are the first suspects:

1. The proposal density `q` is not constant within a triangle, so `p_triangle` is not
   the real selection probability.
2. `U_j` is not accumulated for candidates that fail the geometry checks (`A_j = 0`),
   so the control term no longer has zero mean.
3. Horizon clipping is missing from `triProjectedSolidAngle`, leaving an RMSE floor on
   large emitters viewed at grazing angles.

---

## Deliberate differences from the original

Keep these in mind when comparing numbers against the original CUDA results.

1. **No environment lighting.** The original `direct_env_NEE` was not ported. Only
   emissive triangles contribute. Scenes with an env map show it as background only.
2. **Every surface is treated as Lambertian**, `f = diffuseReflectionAlbedo / pi`.
   The analytic U (Arvo) assumes `f` is constant over the light's solid angle, so
   X/A/U must share the same Lambertian `f` for the control variate to hold. The
   original was also diffuse-only with a separate glossy path
   (`direct_NEE_glossy`), which was not ported.
3. **No spherical emitter group optimization.** The original `cv_analytic_U` collapsed
   spherical light groups with `sphere_projected_solid_angle`. Falcor's
   `lightCollection` has no such grouping, so we loop per triangle. Exact U mode is
   slower than the original and the value can differ by the tessellation error.
4. **Light proposal uses a global CDF** over triangles (area or flux) instead of the
   original group-CDF. The condition from gotcha 1, that `q` is constant within a
   triangle, still holds. Projected-solid-angle proposals break that condition and
   bring back the O(n_emit) cost, so they were not ported.
5. **The emissive CDF is built once at scene load.** For scenes with animated
   emissives, press `Rebuild emitter CDF` in the UI.
6. **Textured emissives are approximated by the per-triangle average radiance**
   via `getAverageRadiance()`. A and U must use the same `Le` for
   `E[A_j | k] = U_j` to hold, and the original `params.emit_emission[k]` was
   per-triangle constant too.
