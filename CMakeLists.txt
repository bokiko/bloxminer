cmake_minimum_required(VERSION 3.16)
project(bloxminer VERSION 1.0.3 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Build type
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# Compiler flags for maximum performance
# Optimized for modern x86-64 CPUs with AES-NI, AVX2, PCLMUL
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare")

# Release optimizations - tuned for Ryzen
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -march=native -mtune=native -maes -mavx2 -mpclmul -msse4.1 -msse4.2 -flto -funroll-loops -fomit-frame-pointer")
set(CMAKE_C_FLAGS_RELEASE "-O3 -march=native -mtune=native -maes -mavx2 -mpclmul -msse4.1 -msse4.2 -flto -funroll-loops -fomit-frame-pointer")

# Debug flags
set(CMAKE_CXX_FLAGS_DEBUG "-g -O0 -maes -mavx2 -mpclmul")
set(CMAKE_C_FLAGS_DEBUG "-g -O0 -maes -mavx2 -mpclmul")

# AVX-512 support detection
# Note: Zen2/Zen3 (Ryzen 3000/5000) do NOT support AVX-512, only Zen4+ does
# Use -DDISABLE_AVX512=ON for Ryzen 3000/5000 systems
option(DISABLE_AVX512 "Disable AVX-512 (required for Zen2/Zen3 CPUs)" OFF)

include(CheckCXXCompilerFlag)
check_cxx_compiler_flag("-mavx512f" COMPILER_SUPPORTS_AVX512F)
if(COMPILER_SUPPORTS_AVX512F AND NOT DISABLE_AVX512)
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -mavx512f -mavx512vl")
    set(CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE} -mavx512f -mavx512vl")
    message(STATUS "AVX-512 support enabled")
elseif(DISABLE_AVX512)
    message(STATUS "AVX-512 disabled by user (Zen2/Zen3 compatibility)")
endif()

# Profile-Guided Optimization (PGO) options
# Usage:
#   1. Build with: cmake .. -DENABLE_PGO_GENERATE=ON && make
#   2. Run workload to generate profile data
#   3. Rebuild with: cmake .. -DENABLE_PGO_USE=ON && make
option(ENABLE_PGO_GENERATE "Generate PGO profile data" OFF)
option(ENABLE_PGO_USE "Use PGO profile for optimization" OFF)

if(ENABLE_PGO_GENERATE)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fprofile-generate")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fprofile-generate")
    message(STATUS "PGO profile generation enabled")
endif()

if(ENABLE_PGO_USE)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fprofile-use -fprofile-correction")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fprofile-use -fprofile-correction")
    message(STATUS "PGO optimization enabled")
endif()

# Find required packages
find_package(Threads REQUIRED)
find_package(OpenSSL REQUIRED)

# Source files
set(SOURCES
    src/main.cpp
    src/miner.cpp
    src/config_manager.cpp
    src/stratum/stratum_client.cpp
    src/utils/hex_utils.cpp
    src/utils/logger.cpp
    # VerusHash crypto (state of the art implementation)
    src/crypto/haraka.c
    src/crypto/verus_clhash.c
    src/crypto/verus_clhash_v2.c
    src/crypto/verus_hash.cpp
)

# Create executable with project name prefix to place it in project root
add_executable(bloxminer ${SOURCES})

# Set output directory to project root (not build/)
set_target_properties(bloxminer PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
)

# Include directories
target_include_directories(bloxminer PRIVATE
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/src/crypto
    ${OPENSSL_INCLUDE_DIR}
)

# Link libraries
target_link_libraries(bloxminer PRIVATE
    Threads::Threads
    OpenSSL::SSL
    OpenSSL::Crypto
)

# Enable link-time optimization
set_property(TARGET bloxminer PROPERTY INTERPROCEDURAL_OPTIMIZATION TRUE)

# Install
install(TARGETS bloxminer DESTINATION bin)
