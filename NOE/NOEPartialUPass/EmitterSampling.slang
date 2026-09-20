/***************************************************************************
 # Emissive triangle proposal and candidate evaluation
 #
 # Original: render_common.h
 #   :112  sample_emit_stratified()
 #   :845  sample_tri_bary12()
 #   :893  eval_cv_candidate_raw()
 #
 # [PORTING NOTE] The original carried its own params.emit_* arrays. Falcor's
 # gScene.lightCollection already holds the same data:
 #   params.emit_tri[k] + tri_v*   -> lightCollection.getTriangle(k).posW[]
 #   params.emit_area[k]           -> .area
 #   params.emit_emission[k]       -> lightCollection.getAverageRadiance(k)
 #   params.emit_cdf               -> gEmitCdf (built on the host)
 # So k IS Falcor's emissive triangle index and one level of indirection is gone.
 **************************************************************************/
#include "Utils/Math/MathConstants.slangh"

__exported import Scene.Scene;
__exported import Params;
import ProjectedSolidAngle;
import Utils.Sampling.SampleGeneratorInterface;

/// Cumulative selection probability. gEmitCdf[k] - gEmitCdf[k-1] is p_k, the
/// probability of picking triangle k.
StructuredBuffer<float> gEmitCdf;

/** One proposed candidate. */
struct EmitSample
{
    uint triIdx;      ///< Emissive triangle index. areaWeight == 0 means invalid.
    float areaWeight; ///< 1/q, where q is the area-measure proposal density (constant within a triangle).
    float pTriangle;  ///< p_k, the probability of selecting this triangle. = area_k / areaWeight.
};

/** First index in gEmitCdf whose value is >= u. */
uint lowerBoundCdf(const float u, const uint count)
{
    uint lo = 0;
    uint hi = count - 1;
    while (lo < hi)
    {
        uint mid = (lo + hi) >> 1;
        if (gEmitCdf[mid] < u)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo;
}

/**
 * Draw candidate j, stratified over j. Same as the original sample_emit_stratified.
 *
 * Excerpt gotcha 1: q must be constant within a triangle so that
 * p_triangle = q * area_k really is the triangle's selection probability. Both the
 * uniform-area and the power (flux) proposals pick a triangle first and then sample
 * uniformly by area inside it, so the condition holds.
 */
EmitSample sampleEmitStratified<S : ISampleGenerator>(inout S sg, const uint j, const uint J, const uint emitCount)
{
    EmitSample es = {};
    es.triIdx = 0;
    es.areaWeight = 0.f;
    es.pTriangle = 0.f;

    if (emitCount == 0)
        return es;

    const float u = (float(j) + sampleNext1D(sg)) / float(J);
    const uint k = lowerBoundCdf(u, emitCount);

    const float c1 = gEmitCdf[k];
    const float c0 = (k == 0) ? 0.f : gEmitCdf[k - 1];
    const float p = c1 - c0;
    if (!(p > 0.f))
        return es;

    const float area = gScene.lightCollection.getTriangle(k).area;
    if (!(area > 0.f))
        return es;

    es.triIdx = k;
    es.pTriangle = p;
    es.areaWeight = area / p; // = 1/q
    return es;
}

/** Barycentrics (b1, b2) of a uniform point on a triangle. Original sample_tri_bary12. */
float2 sampleTriBary12<S : ISampleGenerator>(inout S sg)
{
    const float2 u = sampleNext2D(sg);
    const float r1 = sqrt(u.x);
    const float r2 = u.y;
    return float2(r1 * (1.f - r2), r1 * r2);
}

/**
 * The unweighted area-measure integrand h(y) = f * Le * G.
 * Original eval_cv_candidate_raw.
 *
 * Le is the per-triangle constant average radiance. That is required because
 * U_k = f * Le_k * phi_k uses the same Le; if Le varied across the triangle (textured
 * emissives) then E[A_j | k] = U_j would break. The original params.emit_emission[k]
 * was per-triangle constant too.
 *
 * @param[out] pLight The sampled point on the triangle.
 * @return h(y). Zero below the horizon or on the back side of the emitter.
 */
float3 evalCandidateRaw(
    const uint triIdx,
    const float2 bary12,
    const float3 hit,
    const float3 n_x,
    const float3 alb,
    out float3 pLight
)
{
    pLight = float3(0.f);

    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triIdx);

    const float b1 = bary12.x;
    const float b2 = bary12.y;
    const float b0 = 1.f - b1 - b2;
    if (b0 < -1e-5f || b1 < -1e-5f || b2 < -1e-5f)
        return float3(0.f);

    pLight = tri.getPosition(float3(b0, b1, b2));

    const float3 w = pLight - hit;
    const float d2 = dot(w, w);
    if (d2 < 1e-12f)
        return float3(0.f);

    const float3 wi = w / sqrt(d2);
    const float cos_x = dot(n_x, wi);
    const float cos_y = -dot(tri.normal, wi); // One-sided emitter.
    if (cos_x <= 0.f || cos_y <= 0.f)
        return float3(0.f);

    const float3 f = alb * M_1_PI;
    return f * gScene.lightCollection.getAverageRadiance(triIdx) * (cos_x * cos_y / d2);
}

/** The exact unshadowed contribution of one triangle, U_k = f * Le_k * phi_k. */
float3 evalExactUForTriangle(const uint triIdx, const float3 hit, const float3 n_x, const float3 alb)
{
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triIdx);
    const float phi = triProjectedSolidAngle(tri.posW[0], tri.posW[1], tri.posW[2], hit, n_x);
    if (!(phi > 0.f))
        return float3(0.f);

    const float3 f = alb * M_1_PI;
    return f * gScene.lightCollection.getAverageRadiance(triIdx) * phi;
}

/** Rec.709 luminance. Original cv_luminance. */
float cvLuminance(const float3 v)
{
    return 0.2126f * v.x + 0.7152f * v.y + 0.0722f * v.z;
}
