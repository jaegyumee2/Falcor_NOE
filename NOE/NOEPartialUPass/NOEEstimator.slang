/***************************************************************************
 # The three NOE direct lighting estimators
 #
 # Original:
 #   render_common.h :443  direct_NEE_strat  (ported here as the sampled version)
 #   render_common.h :647  direct_NOE_nee    -> NOE_ExactU
 #   render_common.h :1231 cv_analytic_U
 #   noe_partial_u_excerpt.cu                -> NOE_PartialU
 #
 # Shared meaning:
 #   E[X] = direct light,  E[A] = E[U] = the exact unshadowed integral
 #   The final estimator Z = X + c * (U - A) is unbiased for any c.
 #
 # All three cost one shadow ray per event (K*K in total).
 **************************************************************************/
#include "Utils/Math/MathConstants.slangh"

__exported import EmitterSampling;
import Scene.RaytracingInline;
import Utils.Sampling.SampleGeneratorInterface;

/** The three estimators at one shading point. Never fold them together (see the
    caller comment in the excerpt). */
struct NOEResult
{
    float3 X; ///< Visibility-corrected contribution.
    float3 A; ///< Candidate mean of the point-sampled unshadowed contribution.
    float3 U; ///< The unshadowed integral: exact, or a candidate-mean estimate, depending on mode.

    static NOEResult createZero()
    {
        NOEResult r;
        r.X = float3(0.f);
        r.A = float3(0.f);
        r.U = float3(0.f);
        return r;
    }
};

/** Original trace_visible. Is the point on the light reachable unoccluded? */
bool traceVisible(const float3 originW, const float3 pLight, const float epsilon)
{
    const float3 w = pLight - originW;
    const float d = length(w);
    if (!(d > 0.f))
        return false;

    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(originW, w / d, 0.f, d * (1.f - epsilon));
    return rayQuery.traceVisibilityRay(ray);
}

/**
 * The exact U, looping over every emitter. Original cv_analytic_U.
 *
 * This is O(n_emit), which is exactly the cost partial U exists to remove. It is
 * kept here only as the A/B baseline.
 *
 * [PORTING NOTE] The original collapsed spherical emitter groups with
 * sphere_projected_solid_angle. Falcor's lightCollection has no such grouping, so we
 * loop per triangle. Results can differ from the original by the tessellation error
 * (the same term the excerpt header warns about for this A/B).
 */
float3 evalExactU(const float3 hit, const float3 n_x, const float3 alb, const uint emitCount)
{
    float3 U = float3(0.f);
    for (uint k = 0; k < emitCount; ++k)
        U += evalExactUForTriangle(k, hit, n_x, alb);
    return U;
}

/**
 * One partial U event: J candidates plus one shadow ray.
 * A direct translation of the original noe_partial_u_direct().
 */
NOEResult noePartialUEvent<S : ISampleGenerator>(
    inout S sg,
    const float3 hit,
    const float3 n_x,
    const float3 alb,
    const uint J,
    const uint emitCount,
    const float shadowEpsilon
)
{
    NOEResult res = NOEResult::createZero();
    if (J < 1 || emitCount == 0)
        return res;

    const float invJ = 1.f / float(J);
    const float3 f = alb * M_1_PI;

    float scoreSum = 0.f;
    float winnerScore = 0.f;
    float3 winnerA = float3(0.f);
    float3 winnerPoint = float3(0.f);
    bool haveWinner = false;

    for (uint j = 0; j < J; ++j)
    {
        // --- Propose one candidate (stratified over j) -------------------------
        const EmitSample es = sampleEmitStratified(sg, j, J, emitCount);

        // --- A_j: point-sampled unshadowed contribution. E[A_j | k] = U_k / p_k --
        const float2 bary = sampleTriBary12(sg);
        float3 pLight = float3(0.f);
        float3 A_j = float3(0.f);
        if (es.areaWeight > 0.f)
        {
            const float3 raw = evalCandidateRaw(es.triIdx, bary, hit, n_x, alb, pLight);
            A_j = raw * es.areaWeight; // 1/q = areaWeight
            res.A += A_j;
        }

        // --- U_j: the whole U estimated from this one triangle ------------------
        // q is constant within a triangle, so p_triangle = area_k / areaWeight is the
        // real triangle selection probability and U_k / p_triangle is unbiased for the
        // sum over ALL emitters.
        // Excerpt gotcha 2: this must be accumulated even when the candidate fails the
        // geometry checks (A_j == 0), which is why it sits BEFORE the reservoir score test.
        if (es.pTriangle > 0.f)
        {
            const EmissiveTriangle tri = gScene.lightCollection.getTriangle(es.triIdx);
            const float phi = triProjectedSolidAngle(tri.posW[0], tri.posW[1], tri.posW[2], hit, n_x);
            if (phi > 0.f)
                res.U += f * gScene.lightCollection.getAverageRadiance(es.triIdx) * (phi / es.pTriangle);
        }

        // --- Streaming reservoir: keep one candidate for the shadow ray ---------
        // Any strictly positive score keeps X unbiased; the score only moves variance.
        // A_j == 0 (back-facing or below the horizon) scores 0 and is never selected.
        const float score = cvLuminance(A_j);
        if (!(score > 0.f) || !isfinite(score))
            continue;
        scoreSum += score;
        if (sampleNext1D(sg) * scoreSum < score)
        {
            winnerScore = score;
            winnerA = A_j;
            winnerPoint = pLight;
            haveWinner = true;
        }
    }

    res.A *= invJ;
    res.U *= invJ;

    // No selectable candidate: X = 0 is the correct value here, and the control term
    // U_J - A_J still stands on its own. Do NOT discard the event.
    if (!haveWinner || !(scoreSum > 0.f) || !(winnerScore > 0.f))
        return res;

    // RIS correction: E[correction * A_win] = A_J, so X is an unbiased estimate of the
    // candidate mean of the VISIBLE contributions.
    const float correction = scoreSum / (float(J) * winnerScore);
    if (traceVisible(hit, winnerPoint, shadowEpsilon))
        res.X = winnerA * correction;

    return res;
}

/**
 * Direct lighting at one shading point. Shared entry point for all three modes.
 *
 * @param[in] hit Shading point (already offset to avoid self-intersection).
 * @param[in] n_x Shading normal.
 * @param[in] alb Diffuse albedo. Only used as f = alb / pi, Lambertian like the original.
 */
NOEResult estimateDirect<S : ISampleGenerator>(
    inout S sg,
    const float3 hit,
    const float3 n_x,
    const float3 alb,
    const uint estimatorMode,
    const uint K,
    const uint J,
    const uint emitCount,
    const float shadowEpsilon
)
{
    NOEResult res = NOEResult::createZero();

    if (emitCount == 0)
        return res;

    const uint events = max(1u, K * K);
    const float invE = 1.f / float(events);

    if (estimatorMode == (uint)EstimatorMode::NOE_PartialU)
    {
        // K*K independent events. The three estimators are averaged separately;
        // folding the control term into the winner would break E[U_J - A_J] = 0.
        for (uint e = 0; e < events; ++e)
        {
            const NOEResult ev = noePartialUEvent(sg, hit, n_x, alb, J, emitCount, shadowEpsilon);
            res.X += ev.X;
            res.A += ev.A;
            res.U += ev.U;
        }
        res.X *= invE;
        res.A *= invE;
        res.U *= invE;
        return res;
    }

    // PlainNEE / NOE_ExactU: K*K stratified samples, one shadow ray each.
    for (uint i = 0; i < events; ++i)
    {
        const EmitSample es = sampleEmitStratified(sg, i, events, emitCount);
        if (!(es.areaWeight > 0.f))
            continue;

        const float2 bary = sampleTriBary12(sg);
        float3 pLight = float3(0.f);
        const float3 raw = evalCandidateRaw(es.triIdx, bary, hit, n_x, alb, pLight);
        const float3 sample = raw * es.areaWeight;
        if (!(cvLuminance(sample) > 0.f))
            continue;

        res.A += sample;
        if (traceVisible(hit, pLight, shadowEpsilon))
            res.X += sample;
    }
    res.X *= invE;
    res.A *= invE;

    if (estimatorMode == (uint)EstimatorMode::NOE_ExactU)
        res.U = evalExactU(hit, n_x, alb, emitCount);

    return res;
}

/** Z = X + c * (U - A). In PlainNEE mode U = A = 0, so Z = X. */
float3 combineNOE(const NOEResult r, const uint estimatorMode, const float c)
{
    if (estimatorMode == (uint)EstimatorMode::PlainNEE)
        return r.X;
    return r.X + (r.U - r.A) * c;
}
