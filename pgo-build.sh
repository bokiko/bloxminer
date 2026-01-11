#!/bin/bash
# PGO (Profile-Guided Optimization) build script for bloxminer
# Expected performance gain: 5-15% hashrate improvement
#
# Usage: ./pgo-build.sh [profile-minutes]
#   profile-minutes: How long to run for profiling (default: 10)

set -e

PROFILE_MINUTES=${1:-10}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

echo "=========================================="
echo "BloxMiner PGO Build"
echo "=========================================="
echo "Profile duration: ${PROFILE_MINUTES} minutes"
echo ""

# Check for existing config
CONFIG_FILE=""
if [[ -f "$SCRIPT_DIR/bloxminer.json" ]]; then
    CONFIG_FILE="$SCRIPT_DIR/bloxminer.json"
elif [[ -f "$HOME/.config/bloxminer/config.json" ]]; then
    CONFIG_FILE="$HOME/.config/bloxminer/config.json"
fi

if [[ -z "$CONFIG_FILE" ]]; then
    echo "ERROR: No config file found. Please run the miner first to create one."
    echo "  Expected: bloxminer.json or ~/.config/bloxminer/config.json"
    exit 1
fi

echo "Using config: $CONFIG_FILE"
echo ""

# Step 1: Baseline hashrate (optional but useful for comparison)
echo "Step 0: Building baseline for comparison..."
cd "$BUILD_DIR"
rm -rf CMakeCache.txt CMakeFiles
cmake .. -DCMAKE_BUILD_TYPE=Release -DDISABLE_AVX512=ON
make -j$(nproc)

echo ""
echo "Running baseline for 60 seconds to get comparison hashrate..."
timeout 60 ./bloxminer -c "$CONFIG_FILE" 2>&1 | tee /tmp/pgo-baseline.log || true
BASELINE_HR=$(grep -oP 'hashrate.*?(\d+\.?\d*)\s*MH/s' /tmp/pgo-baseline.log | tail -1 | grep -oP '\d+\.?\d*' | tail -1)
echo ""
echo "Baseline hashrate: ${BASELINE_HR:-unknown} MH/s"
echo ""

# Step 2: Build with profiling enabled
echo "Step 1: Building with PGO profile generation..."
rm -rf CMakeCache.txt CMakeFiles *.gcda
cmake .. -DCMAKE_BUILD_TYPE=Release -DENABLE_PGO_GENERATE=ON -DDISABLE_AVX512=ON
make -j$(nproc)

# Step 3: Run profiling workload
echo ""
echo "Step 2: Running miner for ${PROFILE_MINUTES} minutes to collect profile data..."
echo "        (Mining to your configured pool - shares will be submitted)"
echo ""
PROFILE_SECONDS=$((PROFILE_MINUTES * 60))
timeout $PROFILE_SECONDS ./bloxminer -c "$CONFIG_FILE" || true

# Check if profile data was generated
GCDA_COUNT=$(find . -name "*.gcda" 2>/dev/null | wc -l)
if [[ $GCDA_COUNT -eq 0 ]]; then
    echo "ERROR: No profile data generated. Check if miner ran correctly."
    exit 1
fi
echo ""
echo "Profile data collected ($GCDA_COUNT .gcda files)"

# Step 4: Rebuild with PGO optimization
echo ""
echo "Step 3: Rebuilding with PGO optimization..."
rm -rf CMakeCache.txt CMakeFiles
cmake .. -DCMAKE_BUILD_TYPE=Release -DENABLE_PGO_USE=ON -DDISABLE_AVX512=ON
make -j$(nproc)

# Step 5: Verify optimized build
echo ""
echo "Step 4: Running optimized build for 60 seconds..."
timeout 60 ./bloxminer -c "$CONFIG_FILE" 2>&1 | tee /tmp/pgo-optimized.log || true
OPTIMIZED_HR=$(grep -oP 'hashrate.*?(\d+\.?\d*)\s*MH/s' /tmp/pgo-optimized.log | tail -1 | grep -oP '\d+\.?\d*' | tail -1)

echo ""
echo "=========================================="
echo "PGO Build Complete!"
echo "=========================================="
echo "Baseline hashrate:  ${BASELINE_HR:-unknown} MH/s"
echo "Optimized hashrate: ${OPTIMIZED_HR:-unknown} MH/s"
if [[ -n "$BASELINE_HR" && -n "$OPTIMIZED_HR" ]]; then
    IMPROVEMENT=$(echo "scale=1; (($OPTIMIZED_HR - $BASELINE_HR) / $BASELINE_HR) * 100" | bc 2>/dev/null || echo "?")
    echo "Improvement:        ${IMPROVEMENT}%"
fi
echo ""
echo "The optimized binary is at: $BUILD_DIR/bloxminer"
echo "To run: cd $BUILD_DIR && ./bloxminer"
