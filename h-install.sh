#!/usr/bin/env bash
# BloxMiner HiveOS Installation Script

set -e

MINER_NAME="bloxminer"
INSTALL_DIR="/hive/miners/$MINER_NAME"

echo "Installing BloxMiner..."

# Install build dependencies
apt-get update -qq
apt-get install -y -qq build-essential cmake libssl-dev git

# Clean previous installation
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Clone and build
cd /tmp
rm -rf bloxminer
git clone https://github.com/bokiko/bloxminer.git
cd bloxminer
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Install binary
cp bloxminer "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bloxminer"

# Create h-run.sh for HiveOS
cat > "$INSTALL_DIR/h-run.sh" << 'EOF'
#!/usr/bin/env bash
cd /hive/miners/bloxminer
./bloxminer $@
EOF
chmod +x "$INSTALL_DIR/h-run.sh"

# Create h-stats.sh placeholder
cat > "$INSTALL_DIR/h-stats.sh" << 'EOF'
#!/usr/bin/env bash
# Stats script - placeholder for HiveOS integration
echo "{}"
EOF
chmod +x "$INSTALL_DIR/h-stats.sh"

# Cleanup
rm -rf /tmp/bloxminer

echo ""
echo "=========================================="
echo "BloxMiner installed to $INSTALL_DIR"
echo "=========================================="
echo ""
echo "Run with:"
echo "  $INSTALL_DIR/bloxminer -o pool.verus.io:9999 -u YOUR_WALLET -w worker1 -t \$(nproc)"
echo ""
