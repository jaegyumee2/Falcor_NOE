/***************************************************************************
 # NOE partial U - port to Falcor 8.0
 **************************************************************************/
#include "NOEPartialUPass.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

using namespace Falcor;

namespace
{
const std::string kShaderFile = "NOE/NOEPartialUPass/NOEPartialU.cs.slang";

const std::string kInputVBuffer = "vbuffer";

const Falcor::ChannelList kInputChannels = {
    // clang-format off
    { kInputVBuffer, "gVBuffer", "Visibility buffer in packed format" },
    // clang-format on
};

const Falcor::ChannelList kOutputChannels = {
    // clang-format off
    { "color", "gColor",      "Final color",                                  true /* optional */, ResourceFormat::RGBA32Float },
    { "X",     "gEstimatorX", "Primary-bounce X (visible contribution)",      true /* optional */, ResourceFormat::RGBA32Float },
    { "A",     "gEstimatorA", "Primary-bounce A (point-sampled unshadowed)",  true /* optional */, ResourceFormat::RGBA32Float },
    { "U",     "gEstimatorU", "Primary-bounce U (analytic unshadowed)",       true /* optional */, ResourceFormat::RGBA32Float },
    // clang-format on
};

// Scripting options.
const char* kEstimatorMode = "estimatorMode";
const char* kLightSampler = "lightSampler";
const char* kK = "K";
const char* kJ = "J";
const char* kCvCoefficient = "cvCoefficient";
const char* kPathDepth = "pathDepth";
const char* kShadowRayEpsilon = "shadowRayEpsilon";
} // namespace

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, NOEPartialUPass>();
}

NOEPartialUPass::NOEPartialUPass(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);

    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
    mpPixelDebug = std::make_unique<PixelDebug>(mpDevice);
}

void NOEPartialUPass::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kEstimatorMode)
            mParams.estimatorMode = (uint32_t)(EstimatorMode)value;
        else if (key == kLightSampler)
            mParams.lightSampler = (uint32_t)(NOELightSampler)value;
        else if (key == kK)
            mParams.K = value;
        else if (key == kJ)
            mParams.J = value;
        else if (key == kCvCoefficient)
            mParams.cvCoefficient = value;
        else if (key == kPathDepth)
            mParams.pathDepth = value;
        else if (key == kShadowRayEpsilon)
            mParams.shadowRayEpsilon = value;
        else
            logWarning("Unknown property '{}' in NOEPartialUPass properties.", key);
    }
}

Properties NOEPartialUPass::getProperties() const
{
    Properties props;
    props[kEstimatorMode] = (EstimatorMode)mParams.estimatorMode;
    props[kLightSampler] = (NOELightSampler)mParams.lightSampler;
    props[kK] = mParams.K;
    props[kJ] = mParams.J;
    props[kCvCoefficient] = mParams.cvCoefficient;
    props[kPathDepth] = mParams.pathDepth;
    props[kShadowRayEpsilon] = mParams.shadowRayEpsilon;
    return props;
}

RenderPassReflection NOEPartialUPass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void NOEPartialUPass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    mFrameDim = compileData.defaultTexDims;
}

void NOEPartialUPass::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpScene = pScene;
    mpPass = nullptr;
    mpEmitCdf = nullptr;
    mCdfDirty = true;
    mParams.frameCount = 0;

    if (mpScene && mpScene->hasProceduralGeometry())
        logWarning("NOEPartialUPass: This render pass only supports triangles. Other types of geometry will be ignored.");
}

void NOEPartialUPass::updateEmitterCdf(RenderContext* pRenderContext)
{
    mParams.emitTriangleCount = 0;
    mCdfDirty = false;

    // Always keep a valid binding by creating a 1-element dummy up front.
    // When emitTriangleCount == 0 the shader bails out before ever reading it.
    const float kDummyCdf = 1.f;
    mpEmitCdf = mpDevice->createStructuredBuffer(
        sizeof(float), 1, ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, &kDummyCdf, false
    );

    if (!mpScene)
        return;

    const auto& pLightCollection = mpScene->getLightCollection(pRenderContext);
    if (!pLightCollection || pLightCollection->getTotalLightCount() == 0)
    {
        logWarning("NOEPartialUPass: The scene has no emissive triangles. The output will be black.");
        return;
    }

    // We need the CPU-side triangle list. Staging it early reduces the GPU stall.
    pLightCollection->prepareSyncCPUData(pRenderContext);
    const auto& triangles = pLightCollection->getMeshLightTriangles(pRenderContext);

    const uint32_t count = (uint32_t)triangles.size();
    if (count == 0)
        return;

    const bool usePower = (NOELightSampler)mParams.lightSampler == NOELightSampler::Power;

    std::vector<float> cdf(count);
    double total = 0.0;
    for (uint32_t i = 0; i < count; ++i)
    {
        const double w = usePower ? (double)triangles[i].flux : (double)triangles[i].area;
        total += std::max(0.0, w);
        cdf[i] = (float)total;
    }

    if (total <= 0.0)
    {
        // Degenerate case where every area/flux is zero: fall back to uniform selection.
        logWarning("NOEPartialUPass: All emitter weights are zero, falling back to uniform triangle selection.");
        for (uint32_t i = 0; i < count; ++i)
            cdf[i] = (float)(i + 1) / (float)count;
    }
    else
    {
        const float invTotal = (float)(1.0 / total);
        for (uint32_t i = 0; i < count; ++i)
            cdf[i] *= invTotal;
    }
    cdf[count - 1] = 1.f; // Make sure the binary search always lands on a valid triangle.

    mpEmitCdf = mpDevice->createStructuredBuffer(
        sizeof(float),
        count,
        ResourceBindFlags::ShaderResource,
        MemoryType::DeviceLocal,
        cdf.data(),
        false
    );
    mpEmitCdf->setName("NOEPartialUPass::mpEmitCdf");

    mParams.emitTriangleCount = count;

    logInfo(
        "NOEPartialUPass: Built emitter CDF over {} triangles ({}).",
        count,
        usePower ? "power/flux" : "uniform area"
    );
}

void NOEPartialUPass::preparePass(const RenderData& renderData)
{
    FALCOR_ASSERT(mpScene);

    if (!mpPass)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderFile).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines = mpScene->getSceneDefines();
        defines.add(mpSampleGenerator->getDefines());
        defines.add("GBUFFER_ADJUST_SHADING_NORMALS", mGBufferAdjustShadingNormals ? "1" : "0");
        defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add(getValidResourceDefines(kOutputChannels, renderData));

        mpPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    mpPass->addDefine("GBUFFER_ADJUST_SHADING_NORMALS", mGBufferAdjustShadingNormals ? "1" : "0");
    mpPass->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    mpPass->getProgram()->addDefines(getValidResourceDefines(kOutputChannels, renderData));
}

void NOEPartialUPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
    {
        clearRenderPassChannels(pRenderContext, kOutputChannels, renderData);
        return;
    }

    if (is_set(mpScene->getUpdates(), IScene::UpdateFlags::RecompileNeeded) ||
        is_set(mpScene->getUpdates(), IScene::UpdateFlags::GeometryChanged))
    {
        mpPass = nullptr;
        mCdfDirty = true;
    }

    auto& dict = renderData.getDictionary();
    if (mOptionsChanged)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, Falcor::RenderPassRefreshFlags::None);
        flags |= Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        dict[Falcor::kRenderPassRefreshFlags] = flags;
        mOptionsChanged = false;
    }
    mGBufferAdjustShadingNormals = dict.getValue(Falcor::kRenderPassGBufferAdjustShadingNormals, false);

    if (mCdfDirty)
        updateEmitterCdf(pRenderContext);

    preparePass(renderData);

    mParams.frameDim = mFrameDim;

    mpPixelDebug->beginFrame(pRenderContext, mFrameDim);

    FALCOR_PROFILE(pRenderContext, "NOEPartialU");

    auto rootVar = mpPass->getRootVar();
    mpScene->bindShaderData(rootVar["gScene"]);
    mpSampleGenerator->bindShaderData(rootVar);
    mpPixelDebug->prepareProgram(mpPass->getProgram(), rootVar);

    rootVar["gParams"].setBlob(&mParams, sizeof(mParams));
    rootVar["gVBuffer"] = renderData.getTexture(kInputVBuffer);
    rootVar["gEmitCdf"] = mpEmitCdf;

    for (const auto& channel : kOutputChannels)
        rootVar[channel.texname] = renderData.getTexture(channel.name);

    mpPass->execute(pRenderContext, mFrameDim.x, mFrameDim.y);

    mpPixelDebug->endFrame(pRenderContext);

    mParams.frameCount++;
}

bool NOEPartialUPass::onMouseEvent(const MouseEvent& mouseEvent)
{
    return mpPixelDebug ? mpPixelDebug->onMouseEvent(mouseEvent) : false;
}

void NOEPartialUPass::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    EstimatorMode mode = (EstimatorMode)mParams.estimatorMode;
    if (widget.dropdown("Estimator", mode))
    {
        mParams.estimatorMode = (uint32_t)mode;
        dirty = true;
    }
    widget.tooltip(
        "Plain NEE      L = X\n"
        "NOE exact U    L = X + c(U_exact - A),  U costs O(n_emit)\n"
        "NOE partial U  L = X + c(U_J - A_J),    U is estimated from J candidates too\n"
        "\n"
        "All three cost one shadow ray per event (K*K total), so they compare directly."
    );

    dirty |= widget.var("Path depth", mParams.pathDepth, 1u, 16u);
    widget.tooltip("Number of diffuse bounces. The original max_depth; matches the depth1 / depth4 runs.");

    dirty |= widget.var("K", mParams.K, 1u, 16u);
    widget.tooltip("The event count is K*K. Original params.K.");

    if ((EstimatorMode)mParams.estimatorMode == EstimatorMode::NOE_PartialU)
    {
        dirty |= widget.var("J (candidates/event)", mParams.J, 1u, 256u);
        widget.tooltip("Light candidates per event. Costs O(J) and is independent of n_emit.");
    }

    if ((EstimatorMode)mParams.estimatorMode != EstimatorMode::PlainNEE)
    {
        dirty |= widget.var("c (CV coefficient)", mParams.cvCoefficient, 0.f, 4.f);
        widget.tooltip(
            "Control variate coefficient. Any value stays unbiased; c = 1 measured best.\n"
            "It must be fixed before the event - deriving c from the same samples fits it to its own noise."
        );
    }

    NOELightSampler sampler = (NOELightSampler)mParams.lightSampler;
    if (widget.dropdown("Light sampler", sampler))
    {
        mParams.lightSampler = (uint32_t)sampler;
        mCdfDirty = true;
        dirty = true;
    }
    widget.tooltip(
        "Triangle selection distribution. In both cases the proposal density q is\n"
        "constant within a triangle, so p_triangle = area / areaWeight is the real selection probability."
    );

    dirty |= widget.var("Shadow ray epsilon", mParams.shadowRayEpsilon, 0.f, 0.1f, 1e-4f);
    widget.tooltip("Relative slack on the shadow ray tMax. Avoids self-hits on the light surface.");

    widget.text("Emitter triangles: " + std::to_string(mParams.emitTriangleCount));
    if (widget.button("Rebuild emitter CDF"))
    {
        mCdfDirty = true;
        dirty = true;
    }
    widget.tooltip("For scenes where the emissives are animated and need a manual rebuild.");

    if (auto group = widget.group("Pixel debug"))
        mpPixelDebug->renderUI(group);

    if (dirty)
    {
        mOptionsChanged = true;
        mParams.frameCount = 0;
    }
}
