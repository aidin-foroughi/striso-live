# striso_audio: the native audio library of Striso Live (miniaudio + the passthrough, the WAV
# writer, the MIDI input (striso_midi.c: WinMM, CoreMIDI; MIDI 2.0: striso_midi_wms.cpp, Windows
# MIDI Services, and CoreMIDI's UMP) and the self-test), and striso_audio_check (self-test and
# hardware checks).
#
# Used two ways:
#   - from windows/CMakeLists.txt (add_subdirectory): builds striso_audio.dll next to the app
#   - on its own, for the self-test:
#       cmake -S packages/striso_audio/native -B build/striso_audio
#       cmake --build build/striso_audio --config Release
#       build/striso_audio/Release/striso_audio_check --selftest <scratch dir>
# macOS app builds use build_macos.sh (a universal dylib) instead.
cmake_minimum_required(VERSION 3.14)
project(striso_audio LANGUAGES C CXX)

option(STRISO_AUDIO_CHECK "Build striso_audio_check (self-test and hardware checks)" ON)

add_library(striso_audio SHARED
  src/striso_audio.c
  src/sa_core.c
  src/sa_platform.c
  src/selftest.c
  src/striso_midi.c
  src/selftest_midi.c
)
set_target_properties(striso_audio PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON C_VISIBILITY_PRESET hidden)
target_include_directories(striso_audio PRIVATE include third_party/miniaudio)
target_include_directories(striso_audio INTERFACE include)
target_compile_definitions(striso_audio PRIVATE SA_BUILD_DLL)
if(MSVC)
  target_compile_definitions(striso_audio PRIVATE _CRT_SECURE_NO_WARNINGS)
  target_compile_options(striso_audio PRIVATE /W3 /utf-8 $<$<NOT:$<CONFIG:Debug>>:/O2>)
  target_link_libraries(striso_audio PRIVATE cfgmgr32 ole32 shell32 winmm)

  # MIDI 2.0: Windows MIDI Services through its SDK (third_party/midi2): C++/WinRT headers made
  # from its winmd with the Windows SDK's cppwinrt.exe; the SDK's DLL goes next to the binaries
  set(STRISO_MIDI2_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/midi2")
  get_filename_component(STRISO_KITS "[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots;KitsRoot10]" ABSOLUTE)
  set(STRISO_SDK_VERSION "${CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION}")
  if(NOT STRISO_SDK_VERSION)
    set(STRISO_SDK_VERSION "${CMAKE_SYSTEM_VERSION}")
  endif()
  find_program(STRISO_CPPWINRT cppwinrt
    HINTS "${STRISO_KITS}/bin/${STRISO_SDK_VERSION}/x64" "${STRISO_KITS}/bin/10.0.26100.0/x64" "${STRISO_KITS}/bin/10.0.22621.0/x64"
    NO_DEFAULT_PATH)
  if(STRISO_CPPWINRT AND EXISTS "${STRISO_MIDI2_DIR}/Windows.Devices.Midi2.winmd")
    set(STRISO_MIDI2_GEN "${CMAKE_CURRENT_BINARY_DIR}/midi2_winrt")
    add_custom_command(
      OUTPUT "${STRISO_MIDI2_GEN}/winrt/Windows.Devices.Midi2.h"
      COMMAND "${STRISO_CPPWINRT}" -in "${STRISO_MIDI2_DIR}/Windows.Devices.Midi2.winmd" -ref "${STRISO_SDK_VERSION}" -out "${STRISO_MIDI2_GEN}"
      DEPENDS "${STRISO_MIDI2_DIR}/Windows.Devices.Midi2.winmd"
      COMMENT "C++/WinRT headers of Windows.Devices.Midi2")
    target_sources(striso_audio PRIVATE src/striso_midi_wms.cpp "${STRISO_MIDI2_GEN}/winrt/Windows.Devices.Midi2.h")
    target_include_directories(striso_audio PRIVATE "${STRISO_MIDI2_GEN}")
    set_source_files_properties(src/striso_midi_wms.cpp PROPERTIES COMPILE_OPTIONS "/std:c++20;/EHsc;/bigobj")
    target_link_libraries(striso_audio PRIVATE windowsapp)
    set(STRISO_MIDI2_DLL "${STRISO_MIDI2_DIR}/win-x64/Windows.Devices.Midi2.dll" "${STRISO_MIDI2_DIR}/win-x64/Windows.Devices.Midi2.pri"
      CACHE INTERNAL "the Windows MIDI Services SDK's files that go next to the exe")
    add_custom_command(TARGET striso_audio POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different ${STRISO_MIDI2_DLL} "$<TARGET_FILE_DIR:striso_audio>")
    message(STATUS "striso_audio: MIDI 2.0 through Windows MIDI Services (${STRISO_CPPWINRT}, SDK ${STRISO_SDK_VERSION})")
  else()
    target_compile_definitions(striso_audio PRIVATE SA_NO_WMS)
    set(STRISO_MIDI2_DLL "" CACHE INTERNAL "")
    message(WARNING "striso_audio: no cppwinrt.exe in the Windows SDK: built without MIDI 2.0 (Windows MIDI Services)")
  endif()
elseif(APPLE)
  target_link_libraries(striso_audio PRIVATE "-framework CoreFoundation" "-framework CoreAudio" "-framework AudioToolbox" "-framework AVFoundation" "-framework CoreMIDI" objc)
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
