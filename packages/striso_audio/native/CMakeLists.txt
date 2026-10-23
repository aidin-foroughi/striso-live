# striso_audio: the native audio library of Striso Live (miniaudio + the passthrough, the WAV
# writer and the self-test), and striso_audio_check (self-test and hardware checks).
#
# Used two ways:
#   - from windows/CMakeLists.txt (add_subdirectory): builds striso_audio.dll next to the app
#   - on its own, for the self-test:
#       cmake -S packages/striso_audio/native -B build/striso_audio
#       cmake --build build/striso_audio --config Release
#       build/striso_audio/Release/striso_audio_check --selftest <scratch dir>
# macOS app builds use build_macos.sh (a universal dylib) instead.
cmake_minimum_required(VERSION 3.14)
project(striso_audio LANGUAGES C)

option(STRISO_AUDIO_CHECK "Build striso_audio_check (self-test and hardware checks)" ON)

add_library(striso_audio SHARED
  src/striso_audio.c
  src/sa_core.c
  src/sa_platform.c
  src/selftest.c
)
set_target_properties(striso_audio PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON C_VISIBILITY_PRESET hidden)
target_include_directories(striso_audio PRIVATE include third_party/miniaudio)
target_include_directories(striso_audio INTERFACE include)
target_compile_definitions(striso_audio PRIVATE SA_BUILD_DLL)
if(MSVC)
  target_compile_definitions(striso_audio PRIVATE _CRT_SECURE_NO_WARNINGS)
  target_compile_options(striso_audio PRIVATE /W3 /utf-8 $<$<NOT:$<CONFIG:Debug>>:/O2>)
  target_link_libraries(striso_audio PRIVATE cfgmgr32 ole32 shell32)
elseif(APPLE)
  target_link_libraries(striso_audio PRIVATE "-framework CoreFoundation" "-framework CoreAudio" "-framework AudioToolbox" "-framework AVFoundation" objc)
else()
  target_link_libraries(striso_audio PRIVATE m pthread dl)
endif()

if(STRISO_AUDIO_CHECK)
  add_executable(striso_audio_check tools/striso_audio_check.c)
  set_target_properties(striso_audio_check PROPERTIES C_STANDARD 11)
  target_link_libraries(striso_audio_check PRIVATE striso_audio)
  if(MSVC)
    target_compile_definitions(striso_audio_check PRIVATE _CRT_SECURE_NO_WARNINGS)
  elseif(NOT APPLE)
    target_link_libraries(striso_audio_check PRIVATE m)
  endif()
endif()
