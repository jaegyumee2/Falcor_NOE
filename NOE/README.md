# NOE workspace

Everything written by hand for `Falcor_NOE` lives here. The stock Falcor tree
(`Source/`) is left untouched, so pulling upstream updates will not conflict.

```
NOE/
|-- CMakeLists.txt       pulled in by add_subdirectory(NOE) in the root CMakeLists.txt
|-- NOEPartialUPass/     the partial U estimator render pass (porting notes in its own README.md)
|-- script/              render graph scripts and benchmark runners (Python)
|-- run.bat              rebuild the pass and launch it, without leaving this folder
|-- exe/                 junction to build/windows-vs2022/bin/Release (gitignored)
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

## Building

First time only, from the repo root (`setup.bat` needs the `.\` prefix because this
machine sets `NoDefaultCurrentDirectoryInExePath`):

```
.\setup.bat
cmake --preset windows-vs2022
cmake --build build/windows-vs2022 --config Release
```

`NOE/exe` is a directory junction to `build/windows-vs2022/bin/Release`, so the
binaries are reachable from inside this folder without copying anything. Recreate
it after a fresh clone with:

```
mklink /J NOE\exe build\windows-vs2022\bin\Release
```

## Running

```
cd NOE
run.bat                    rebuild NOEPartialUPass only, then launch Mogwai
run.bat --no-build         launch without rebuilding
run.bat Other.py           use another script under NOE\script\
```

Only the pass target is rebuilt, which takes seconds; the junction means the fresh
plugin and shaders are what `run.bat` launches.

Note that the `.slang` files are compiled when Mogwai links the program at run time,
not during the C++ build. A missing `import` therefore builds clean and only fails
once a scene is loaded, so always launch once after touching a shader.

Original CUDA implementation: `Media/NOE/OcclusionTracing_share/`
