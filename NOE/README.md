# NOE workspace

Everything written by hand for `Falcor_NOE` lives here. The stock Falcor tree
(`Source/`) is left untouched, so pulling upstream updates will not conflict.

```
NOE/
|-- CMakeLists.txt       pulled in by add_subdirectory(NOE) in the root CMakeLists.txt
|-- NOEPartialUPass/     the partial U estimator render pass (porting notes in its own README.md)
|-- script/              render graph scripts and benchmark runners (Python)
|-- notes/               working notes
`-- results/             renders and RMSE comparisons
```

## Adding another pass

1. Create `NOE/<MethodName>/` with a `CMakeLists.txt` containing
   `add_plugin(<PassName>)`, `target_copy_shaders(<PassName> NOE/<MethodName>)` and
   `target_source_group(<PassName> "NOE")`.
   `add_plugin()` and `target_copy_shaders()` are global functions defined in the root
   CMakeLists.txt, so they work outside `Source/` just fine.
2. Add one line to `NOE/CMakeLists.txt`: `add_subdirectory(<MethodName>)`.
3. The shader path on the C++ side must match the output path given to
   `target_copy_shaders` (e.g. `"NOE/<MethodName>/Foo.cs.slang"`).

## Running

```
build/windows-vs2022/bin/Release/Mogwai.exe --script=NOE/script/NOEPartialU.py
```

Original CUDA implementation: `Media/NOE/OcclusionTracing_share/`
