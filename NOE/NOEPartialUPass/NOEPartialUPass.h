/***************************************************************************
 # NOE partial U - port to Falcor 8.0
 #
 # Original: NOE/OcclusionTracing_share (OptiX/CUDA)
 #       NOE/Partial_U/noe_partial_u_excerpt.cu
 **************************************************************************/
#pragma once

#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "Utils/Debug/PixelDebug.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "Params.slang"

using namespace Falcor;

/**
 * Render pass that runs the NOE estimator Z = X + c * (U - A) inside Falcor.
 *
 * Three modes can be switched inside one pass, which makes the A/B direct:
 *   Plain NEE     L = X
 *   NOE exact U   L = X + c(U_exact - A)   U costs O(n_emit)
 *   NOE partial U L = X + c(U_J - A_J)     U also estimated from J candidates,
 *                                          independent of n_emit
 * All three cost one shadow ray per event (K*K in total).
 */
class NOEPartialUPass : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(NOEPartialUPass, "NOEPartialUPass", {"NOE direct lighting with partial U control variate."})

    static ref<NOEPartialUPass> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<NOEPartialUPass>(pDevice, props);
    }

    NOEPartialUPass(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override;

private:
    void parseProperties(const Properties& props);
    void preparePass(const RenderData& renderData);

    /**
     * Build the emissive triangle selection CDF.
     * Accumulates area for uniform-area, flux for power. Either way the proposal
     * density q is constant within a triangle, which is what partial U requires.
     */
    void updateEmitterCdf(RenderContext* pRenderContext);

    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    std::unique_ptr<PixelDebug> mpPixelDebug;

    NOEPartialUParams mParams;

    ref<ComputePass> mpPass;
    ref<Buffer> mpEmitCdf;

    uint2 mFrameDim = {0, 0};
    bool mOptionsChanged = false;
    bool mGBufferAdjustShadingNormals = false;
    bool mCdfDirty = true;
};
