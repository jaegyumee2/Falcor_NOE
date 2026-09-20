add_plugin(NOEPartialUPass)

target_sources(NOEPartialUPass PRIVATE
    NOEPartialUPass.cpp
    NOEPartialUPass.h
    Params.slang
    ProjectedSolidAngle.slang
    EmitterSampling.slang
    NOEEstimator.slang
    LoadShadingData.slang
    NOEPartialU.cs.slang
)

target_copy_shaders(NOEPartialUPass NOE/NOEPartialUPass)

target_source_group(NOEPartialUPass "NOE")
