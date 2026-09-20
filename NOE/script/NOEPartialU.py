from falcor import *

def render_graph_NOEPartialU():
    g = RenderGraph("NOEPartialU")

    VBufferRT = createPass("VBufferRT", {'useAlphaTest': True})
    g.addPass(VBufferRT, "VBufferRT")

    # estimatorMode: 'Plain NEE' | 'NOE exact U' | 'NOE partial U'
    NOEPartialUPass = createPass("NOEPartialUPass", {
        'estimatorMode': 'NOE partial U',
        'lightSampler': 'Uniform area',
        'K': 1,
        'J': 8,
        'cvCoefficient': 1.0,
        'pathDepth': 1,
    })
    g.addPass(NOEPartialUPass, "NOEPartialUPass")

    # Converge here before measuring RMSE (the reference runs used 512 spp).
    AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePass")

    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    g.addPass(ToneMapper, "ToneMapper")

    g.addEdge("VBufferRT.vbuffer", "NOEPartialUPass.vbuffer")
    g.addEdge("NOEPartialUPass.color", "AccumulatePass.input")
    g.addEdge("AccumulatePass.output", "ToneMapper.src")

    g.markOutput("ToneMapper.dst")
    # Primary-bounce estimators, for computing c* = Cov(lum X, lum A) / Var(lum A)
    # offline, or for comparing partial U against exact U.
    g.markOutput("NOEPartialUPass.X")
    g.markOutput("NOEPartialUPass.A")
    g.markOutput("NOEPartialUPass.U")
    return g

NOEPartialU = render_graph_NOEPartialU()
try: m.addGraph(NOEPartialU)
except NameError: None
