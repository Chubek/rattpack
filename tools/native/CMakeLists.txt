cmake_minimum_required(VERSION 3.20)
project(rattpack_native LANGUAGES C CXX)
get_filename_component(RATTPACK_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${RATTPACK_ROOT}/build")
foreach(configuration DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
  set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY_${configuration} "${RATTPACK_ROOT}/build")
endforeach()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_C_EXTENSIONS ON CACHE BOOL "Expose platform APIs during native feature checks" FORCE)

# zlib's upstream configure step renames a source header. Work on a build-tree
# copy so pinned submodule worktrees remain untouched.
file(COPY "${RATTPACK_ROOT}/third_party/zlib/" DESTINATION "${CMAKE_CURRENT_BINARY_DIR}/zlib-source"
     PATTERN ".git" EXCLUDE PATTERN "zconf.h" EXCLUDE)
set(ZLIB_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
add_subdirectory("${CMAKE_CURRENT_BINARY_DIR}/zlib-source" zlib)
set_target_properties(zlibstatic PROPERTIES OUTPUT_NAME rattz)
configure_file("${RATTPACK_ROOT}/third_party/zlib/zlib.h" "${CMAKE_CURRENT_BINARY_DIR}/zlib/zlib.h" COPYONLY)
set(ZLIB_LIBRARY "${RATTPACK_ROOT}/build/${CMAKE_STATIC_LIBRARY_PREFIX}rattz${CMAKE_STATIC_LIBRARY_SUFFIX}" CACHE FILEPATH "" FORCE)
set(ZLIB_INCLUDE_DIR "${CMAKE_CURRENT_BINARY_DIR}/zlib" CACHE PATH "" FORCE)

set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_CLI OFF CACHE BOOL "" FORCE)
set(USE_SSH exec CACHE STRING "" FORCE)
set(REGEX_BACKEND builtin CACHE STRING "" FORCE)
add_subdirectory("${RATTPACK_ROOT}/third_party/libgit2" git2)
set_target_properties(libgit2package PROPERTIES OUTPUT_NAME rattgit)
add_dependencies(libgit2package zlibstatic)

set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_XZ OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_XZDEC OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_LZMADEC OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_LZMAINFO OFF CACHE BOOL "" FORCE)
set(XZ_NLS OFF CACHE BOOL "" FORCE)
set(XZ_DOC OFF CACHE BOOL "" FORCE)
add_subdirectory("${RATTPACK_ROOT}/third_party/xz" xz)
set_target_properties(liblzma PROPERTIES OUTPUT_NAME rattxz)

add_library(rattnative STATIC
  "${RATTPACK_ROOT}/source/rattpack/native/bridge.c"
  "${RATTPACK_ROOT}/third_party/blake3/c/blake3.c"
  "${RATTPACK_ROOT}/third_party/blake3/c/blake3_dispatch.c"
  "${RATTPACK_ROOT}/third_party/blake3/c/blake3_portable.c")
set_target_properties(rattnative PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON)
target_compile_definitions(rattnative PRIVATE
  BLAKE3_NO_SSE2 BLAKE3_NO_SSE41 BLAKE3_NO_AVX2 BLAKE3_NO_AVX512 BLAKE3_USE_NEON=0)
target_include_directories(rattnative PRIVATE
  "${RATTPACK_ROOT}/third_party/libgit2/include"
  "${CMAKE_CURRENT_BINARY_DIR}/zlib-source"
  "${CMAKE_CURRENT_BINARY_DIR}/zlib"
  "${RATTPACK_ROOT}/third_party/xz/src/liblzma/api")
add_dependencies(rattnative libgit2package liblzma zlibstatic)

add_executable(ratt-satie satie.cpp
  "${RATTPACK_ROOT}/third_party/satie/src/SatieMemory.cpp")
find_package(Threads REQUIRED)
target_link_libraries(ratt-satie PRIVATE Threads::Threads)
target_compile_features(ratt-satie PRIVATE cxx_std_20)
target_compile_definitions(ratt-satie PRIVATE SATIE_NO_LUA_PLUGIN)
target_include_directories(ratt-satie PRIVATE
  "${RATTPACK_ROOT}/third_party/satie/include"
  "${RATTPACK_ROOT}/third_party/satie/third_party/memtkx/include"
  "${RATTPACK_ROOT}/third_party/satie/stdplugin")
set_target_properties(ratt-satie PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${RATTPACK_ROOT}/build")
foreach(configuration DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
  set_target_properties(ratt-satie PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY_${configuration} "${RATTPACK_ROOT}/build")
endforeach()
add_dependencies(rattnative ratt-satie)
