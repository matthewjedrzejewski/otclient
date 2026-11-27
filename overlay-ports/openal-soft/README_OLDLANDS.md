OldLands: copy of the openal-soft port from vcpkg master (1.25.2, port-version 1, "Patch Tuesday November 2026").
The port from our vcpkg baseline (1.25.1) no longer compiles with the current MSVC on the GitHub Windows runner
(alc.cpp: error C3889 in std::ranges). Remove this folder when the vcpkg baseline is updated past November 2026.
