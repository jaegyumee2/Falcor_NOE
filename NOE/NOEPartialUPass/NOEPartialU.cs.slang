/***************************************************************************
 # NOE partial U - main kernel
 #
 # A port of the path loop in the original render.cu. The primary hit comes from the
 # VBuffer; later bounces are traced with inline ray tracing.
 #
 # Diffuse only, like the original:
 #   - Every surface is treated as Lambertian (f = diffuseAlbedo / pi). The analytic U
 #     (Arvo projected solid angle) assumes f is constant over the light's solid angle,
 #     so X/A/U must all use the same Lambertian f for the control variate to hold.
 #   - Emitters are only added when directly visible at the primary hit (the original's
 #     prev_specular rule).
 #   - Environment lighting (the original direct_env_NEE) was not ported. Emissive
 #     triangles only.
 **************************************************************************/
#include "Utils/Math/MathConstants.slangh"

import LoadShadingData;
import NOEEstimator;
// NOEEstimator imports this without re-exporting it, and the bounce loop
// below instantiates SceneRayQuery directly.
import Scene.RaytracingInline;
import Params;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Utils.Debug.PixelDebug;

ConstantBuffer<NOEPartialUParams> gParams;
Texture2D<PackedHitInfo> gVBuffer;

RWTexture2D<float4> gColor;
RWTexture2D<float4> gEstimatorX;
RWTexture2D<float4> gEstimatorA;
RWTexture2D<float4> gEstimatorU;

#define is_valid(name) (is_valid_##name != 0)

static const bool kUseEnvBackground = USE_ENV_BACKGROUND;

/** Cosine-weighted hemisphere sample around n. */
float3 sampleCosineHemisphere<S : ISampleGenerator>(inout S sg, const float3 n)
{
    float pdf;
    const float3 local = sample_cosine_hemisphere_concentric(sampleNext2D(sg), pdf);
    const float3 T = perp_stark(n);
    const float3 B = cross(n, T);
    return T * local.x + B * local.y + n * local.z;
}

/** Build ShadingData from a single hit. */
bool prepareHit(const HitInfo hit, const float3 rayDir, out ShadingData sd)
{
    sd = {};
    if (!hit.isValid() || hit.getType() != HitType::Triangle)
        return false;

    const TriangleHit triangleHit = hit.getTriangleHit();
    const VertexData v = gScene.getVertexData(triangleHit);
    const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    sd = gScene.materials.prepareShadingData(v, materialID, -rayDir);
    return true;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gParams.frameDim))
        return;

    printSetPixel(pixel);

    SampleGenerator sg = SampleGenerator(pixel, gParams.frameCount);

    float3 L = float3(0.f);
    float3 beta = float3(1.f);
    NOEResult primary = NOEResult::createZero();

    float3 rayDir = gScene.camera.computeRayPinhole(pixel, gParams.frameDim).dir;

    ShadingData sd;
    bool hasHit = prepareHit(HitInfo(gVBuffer[pixel]), rayDir, sd);
    if (!hasHit && kUseEnvBackground)
        L = gScene.envMap.eval(rayDir);

    const uint depth = max(1u, gParams.pathDepth);

    for (uint b = 0; b < depth && hasHit; ++b)
    {
        let lod = ExplicitLodTextureSampler(0.f);
        let hints = getMaterialInstanceHints();
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);

        // Directly visible emitter. After a diffuse bounce, NEE already counts it.
        if (b == 0)
            L += beta * bsdfProperties.emission;

        const float3 alb = bsdfProperties.diffuseReflectionAlbedo;
        const float3 n_x = sd.getOrientedFaceNormal();
        const float3 org = sd.computeRayOrigin();

        const NOEResult r = estimateDirect(
            sg, org, n_x, alb, gParams.estimatorMode, gParams.K, gParams.J, gParams.emitTriangleCount, gParams.shadowRayEpsilon
        );
        L += beta * combineNOE(r, gParams.estimatorMode, gParams.cvCoefficient);

        if (b == 0)
            primary = r;

        if (b + 1 >= depth)
            break;

        // Cosine-weighted diffuse bounce. pdf = cos/pi and f = alb/pi, so the
        // throughput update is just alb.
        const float3 wi = sampleCosineHemisphere(sg, n_x);
        if (dot(wi, n_x) <= 0.f)
            break;
        beta *= alb;

        SceneRayQuery<1> rayQuery;
        float hitT;
        const HitInfo nextHit = rayQuery.traceRay(Ray(org, wi, 0.f, FLT_MAX), hitT);
        rayDir = wi;
        hasHit = prepareHit(nextHit, rayDir, sd);
    }

    gColor[pixel] = float4(L, 1.f);

    // The three primary-bounce estimators. Used to compute
    // c* = Cov(lum X, lum A) / Var(lum A) offline, or to compare partial U vs exact U.
    if (is_valid(gEstimatorX))
        gEstimatorX[pixel] = float4(primary.X, 1.f);
    if (is_valid(gEstimatorA))
        gEstimatorA[pixel] = float4(primary.A, 1.f);
    if (is_valid(gEstimatorU))
        gEstimatorU[pixel] = float4(primary.U, 1.f);
}
