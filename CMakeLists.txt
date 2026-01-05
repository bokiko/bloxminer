cmake_minimum_required(VERSION 3.16)
project(bloxminer VERSION 1.0.0 LANGUAGES CXX C)

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

# Find required packages
find_package(Threads REQUIRED)
find_package(OpenSSL REQUIRED)

# Source files
set(SOURCES
    src/main.cpp
    src/miner.cpp
    src/stratum/stratum_client.cpp
    src/utils/hex_utils.cpp
    src/utils/logger.cpp
    # VerusHash crypto (state of the art implementation)
    src/crypto/haraka.c
    src/crypto/verus_clhash.c
    src/crypto/verus_hash.cpp
)

# Create executable
add_executable(bloxminer ${SOURCES})

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
