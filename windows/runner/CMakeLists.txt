cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

if(MINGW)
  # windres resolves relative icon paths from the build directory, while
  # MSVC's resource compiler resolves them relative to Runner.rc.
  set_source_files_properties(Runner.rc PROPERTIES
    COMPILE_OPTIONS "-I${CMAKE_CURRENT_SOURCE_DIR}")
endif()

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# The application manifest requires elevation for USB/IP operations. Visual
# Studio's default linker UAC fragment is asInvoker, which conflicts with the
# custom manifest above, so let that manifest provide the UAC declaration.
if(MSVC)
  target_link_options(${BINARY_NAME} PRIVATE "/MANIFESTUAC:NO")
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
if(MSVC)
  target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
else()
  target_link_libraries(${BINARY_NAME} PRIVATE dwmapi)
  if(MINGW)
    # The Flutter runner exports wWinMain; select MinGW's Unicode startup code.
    # Static-link the MinGW runtimes so the portable bundle does not depend on
    # libgcc_s_seh-1.dll or libstdc++-6.dll being installed on Windows.
    target_link_options(${BINARY_NAME} PRIVATE
      -municode
      -static-libgcc
      -static-libstdc++
    )
  endif()
endif()
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
