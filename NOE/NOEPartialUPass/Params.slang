/***************************************************************************
 # NOE partial U - parameters shared between host and device
 #
 # Original: NOE/OcclusionTracing_share/cuda/src/render_common.h
 #           NOE/Partial_U/noe_partial_u_excerpt.cu
 **************************************************************************/
#pragma once
#include "Utils/HostDeviceShared.slangh"

BEGIN_NAMESPACE_FALCOR

/**
 * Which direct lighting estimator to use. All three cost one shadow ray per event.
 *
 *   PlainNEE     L = X
 *   NOE_ExactU   L = X + c * (U_exact - A)    U_exact loops every emitter, O(n_emit)
 *   NOE_PartialU L = X + c * (U_J   - A_J)    U is also estimated from J candidates,
 *                                             independent of n_emit
 */
enum class EstimatorMode : uint32_t
{
    PlainNEE = 0,
    NOE_ExactU = 1,
    NOE_PartialU = 2,
};

FALCOR_ENUM_INFO(
    EstimatorMode,
    {
        {EstimatorMode::PlainNEE, "Plain NEE"},
        {EstimatorMode::NOE_ExactU, "NOE exact U"},
        {EstimatorMode::NOE_PartialU, "NOE partial U"},
    }
);
FALCOR_ENUM_REGISTER(EstimatorMode);

/**
 * Light proposal distribution. Either one keeps q constant WITHIN a triangle, which
 * is what gotcha 1 in the excerpt requires. Projected-solid-angle proposals break
 * that condition and bring back the O(n_emit) cost, so they were not ported.
 */
enum class NOELightSampler : uint32_t
{
    UniformArea = 0, ///< p_k = area_k / total_area. Original light_sampler == 0.
    Power = 1,       ///< p_k = flux_k / total_flux. Matches the original group-CDF ("power").
};

FALCOR_ENUM_INFO(
    NOELightSampler,
    {
        {NOELightSampler::UniformArea, "Uniform area"},
        {NOELightSampler::Power, "Power (flux)"},
    }
);
FALCOR_ENUM_REGISTER(NOELightSampler);

/**
 * Host/device shared parameters. Follow HLSL packing rules (16-byte rows).
 */
struct NOEPartialUParams
{
    uint2 frameDim = {0, 0};
    uint frameCount = 0;
    /// Number of diffuse bounces. The original max_depth; matches the depth1 / depth4 runs.
    uint pathDepth = 1;

    uint K = 1; ///< The event count is K*K. Original params.K.
    uint J = 8; ///< Candidates per event for partial U.
    uint estimatorMode = (uint)EstimatorMode::NOE_PartialU;
    uint lightSampler = (uint)NOELightSampler::UniformArea;

    /// c. Excerpt gotcha 4: it must be fixed before the event. c = 1 measured best.
    float cvCoefficient = 1.f;
    uint emitTriangleCount = 0;
    /// Relative slack applied to the shadow ray tMax. Stands in for the original's
    /// absolute 1e-4 offset.
    float shadowRayEpsilon = 1e-3f;
    uint _pad0 = 0;
};

END_NAMESPACE_FALCOR
