# Shared Linux/Windows integration. Rust stays behind a C ABI; Flutter and the
# geometry kernel do not depend on Rust language bindings.
find_program(MMX_CARGO cargo HINTS "$ENV{HOME}/.cargo/bin" "$ENV{USERPROFILE}/.cargo/bin")
if(NOT MMX_CARGO)
  message(FATAL_ERROR "Rust/Cargo is required for the native renderer; install toolchain 1.99.1")
endif()
find_package(Python3 COMPONENTS Interpreter REQUIRED)
set(MMX_RUST_TARGET_DIR "${CMAKE_BINARY_DIR}/mmx-rust")
if(WIN32)
  set(MMX_GPU_LIBRARY "${MMX_RUST_TARGET_DIR}/release/mmx_gpu.dll")
else()
  set(MMX_GPU_LIBRARY "${MMX_RUST_TARGET_DIR}/release/libmmx_gpu.so")
endif()
set(MMX_NATIVE_LICENSES "${CMAKE_BINARY_DIR}/mmx-native-licenses")
file(GLOB_RECURSE MMX_LICENSE_INPUTS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/vendor_licenses/*")
add_custom_command(
  OUTPUT "${MMX_GPU_LIBRARY}" "${MMX_NATIVE_LICENSES}/index.json"
  COMMAND "${MMX_CARGO}" build --release --locked --target-dir "${MMX_RUST_TARGET_DIR}"
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/collect_licenses.py"
          --output "${MMX_NATIVE_LICENSES}"
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
  DEPENDS Cargo.toml Cargo.lock rust-toolchain.toml src/lib.rs src/shader.wgsl collect_licenses.py ${MMX_LICENSE_INPUTS}
  COMMENT "Build wgpu native renderer and native dependency notices"
  VERBATIM
)
add_custom_target(mmx_gpu_native ALL DEPENDS "${MMX_GPU_LIBRARY}" "${MMX_NATIVE_LICENSES}/index.json")
add_dependencies(${BINARY_NAME} mmx_gpu_native)
install(FILES "${MMX_GPU_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
install(DIRECTORY "${MMX_NATIVE_LICENSES}/" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/native-licenses" COMPONENT Runtime)
