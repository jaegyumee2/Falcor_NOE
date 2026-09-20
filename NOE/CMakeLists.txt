# NOE workspace. Pulled in by add_subdirectory(NOE) in the root CMakeLists.txt.
# add_plugin() and target_copy_shaders() are global functions defined in the root
# CMakeLists, so they work fine outside the Source/ tree.

add_subdirectory(NOEPartialUPass)
