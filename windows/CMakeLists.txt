# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(jj_mkvmaker LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "jj_mkvmaker")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  # 한국어 Windows(코드 페이지 949)에서 UTF-8 소스의 C4819 경고가 오류가 되지 않도록
  target_compile_options(${TARGET} PRIVATE /utf-8)
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# JJ_MKVMaker: FFmpeg 동봉 (별도 설치 없이 동작). 실행 파일 옆 ffmpeg\ 폴더로 복사.
# 파일은 tool\fetch_ffmpeg.ps1 로 third_party\ffmpeg\windows 에 준비한다.
set(JJ_FFMPEG_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/ffmpeg/windows")
file(GLOB JJ_FFMPEG_FILES "${JJ_FFMPEG_DIR}/*.exe" "${JJ_FFMPEG_DIR}/*.txt")
if(JJ_FFMPEG_FILES)
  install(FILES ${JJ_FFMPEG_FILES}
    DESTINATION "${CMAKE_INSTALL_PREFIX}/ffmpeg" COMPONENT Runtime)
endif()

# JJ_MKVMaker: Visual C++ 런타임 DLL 동봉 (새 PC 에 재배포 패키지를 설치하지 않아도 실행되도록)
set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION "${CMAKE_INSTALL_PREFIX}")
set(CMAKE_INSTALL_UCRT_LIBRARIES FALSE)
set(CMAKE_INSTALL_SYSTEM_RUNTIME_COMPONENT Runtime)
include(InstallRequiredSystemLibraries)

# JJ_MKVMaker: 라이선스 고지
# (원문은 assets/licenses - 앱 안 라이선스 화면과 같은 파일. 실행 파일 옆 · 각 도구 폴더에도 둔다)
set(JJ_LICENSES "${CMAKE_CURRENT_SOURCE_DIR}/../assets/licenses")
install(FILES "${JJ_LICENSES}/THIRD_PARTY_NOTICES.txt" "${JJ_LICENSES}/GPL-2.0.txt" "${JJ_LICENSES}/GPL-3.0.txt"
  "${JJ_LICENSES}/LGPL-2.1.txt" "${JJ_LICENSES}/PDFIUM_LICENSES.txt"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime OPTIONAL)
install(FILES "${JJ_LICENSES}/YT-DLP_THIRD_PARTY_LICENSES.txt" DESTINATION "${CMAKE_INSTALL_PREFIX}/tools" COMPONENT Runtime OPTIONAL)
install(FILES "${JJ_LICENSES}/RSYNC_COPYING.txt" DESTINATION "${CMAKE_INSTALL_PREFIX}/rsync" RENAME "COPYING.txt" COMPONENT Runtime OPTIONAL)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../LICENSE" DESTINATION "${CMAKE_INSTALL_PREFIX}" RENAME "LICENSE.txt" COMPONENT Runtime OPTIONAL)

# JJ_MKVMaker: 다운로드 도구 동봉 (yt-dlp, aria2c, deno). 실행 파일 옆 tools\ 폴더로 복사.
set(JJ_TOOLS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/tools/windows")
file(GLOB JJ_TOOL_FILES "${JJ_TOOLS_DIR}/*.exe" "${JJ_TOOLS_DIR}/*.txt")
if(JJ_TOOL_FILES)
  install(FILES ${JJ_TOOL_FILES}
    DESTINATION "${CMAKE_INSTALL_PREFIX}/tools" COMPONENT Runtime)
endif()

# JJ_MKVMaker: rsync 동봉 (내려받기 없이 바로). 실행 파일 옆 rsync\ 폴더로 복사.
# 파일은 tool\fetch_rsync.ps1 로 third_party\rsync\windows 에 준비한다.
set(JJ_RSYNC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/rsync/windows")
file(GLOB JJ_RSYNC_FILES "${JJ_RSYNC_DIR}/*.exe" "${JJ_RSYNC_DIR}/*.dll")
if(JJ_RSYNC_FILES)
  install(FILES ${JJ_RSYNC_FILES}
    DESTINATION "${CMAKE_INSTALL_PREFIX}/rsync" COMPONENT Runtime)
endif()
