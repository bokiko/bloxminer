#!/usr/bin/env bash
#
# BloxMiner Interactive Installer for Ubuntu/Debian
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/bokiko/bloxminer/master/install.sh | bash
#
# Or run locally:
#   ./install.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Banner
print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
  ____  _            __  __ _                 
 | __ )| | _____  __| \/ (_)_ __   ___ _ __ 
 |  _ \| |/ _ \ \/ /| |\/| | '_ \ / _ \ '__|
 | |_) | | (_) >  < | |  | | | | |  __/ |   
 |____/|_|\___/_/\_\|_|  |_|_| |_|\___|_|   
                                             
EOF
    echo -e "${NC}"
    echo -e "${BOLD}BloxMiner Installer - VerusHash v2.2 CPU Miner${NC}"
    echo -e "================================================"
    echo ""
}

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -eq 0 ]; then
        log_warn "Running as root. Consider running as a regular user."
    fi
}

# Check system requirements
check_system() {
    log_step "Checking system requirements..."
    
    # Check OS
    if [ ! -f /etc/os-release ]; then
        log_error "Cannot detect OS. This script is for Ubuntu/Debian."
        exit 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "$ID_LIKE" != *"debian"* && "$ID_LIKE" != *"ubuntu"* ]]; then
        log_warn "This script is designed for Ubuntu/Debian. Your OS: $ID"
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check CPU features
    if ! grep -q "aes" /proc/cpuinfo; then
        log_error "CPU does not support AES-NI. VerusHash requires AES-NI."
        exit 1
    fi
    
    if ! grep -q "avx" /proc/cpuinfo; then
        log_warn "CPU may not support AVX. Mining performance might be reduced."
    fi
    
    log_info "System check passed!"
}

# Install dependencies
install_deps() {
    log_step "Installing build dependencies..."
    
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        build-essential \
        cmake \
        libssl-dev \
        git \
        lm-sensors \
        bc
    
    # Try to load CPU temp sensor
    sudo modprobe k10temp 2>/dev/null || sudo modprobe coretemp 2>/dev/null || true
    
    log_info "Dependencies installed!"
}

# Clone and build
build_miner() {
    log_step "Building BloxMiner..."
    
    INSTALL_DIR="$HOME/bloxminer"
    
    # Clean previous installation
    if [ -d "$INSTALL_DIR" ]; then
        log_warn "Previous installation found at $INSTALL_DIR"
        read -p "Remove and reinstall? [Y/n] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            log_info "Keeping existing installation."
            return
        fi
        rm -rf "$INSTALL_DIR"
    fi
    
    # Clone
    git clone --depth 1 https://github.com/bokiko/bloxminer.git "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # Build
    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release
    make -j$(nproc)
    
    log_info "Build complete!"
}

# Interactive configuration
configure_miner() {
    log_step "Configuring BloxMiner..."
    echo ""

    # Wallet
    echo -e "${BOLD}Enter your Verus (VRSC) wallet address:${NC}"
    read -p "> " WALLET
    while [ -z "$WALLET" ]; do
        log_error "Wallet address is required!"
        read -p "> " WALLET
    done

    echo ""

    # Pool
    echo -e "${BOLD}Enter pool address (default: pool.verus.io:9999):${NC}"
    read -p "> " POOL
    POOL="${POOL:-pool.verus.io:9999}"

    # Parse pool host and port
    POOL_HOST="${POOL%:*}"
    POOL_PORT="${POOL##*:}"
    if [ "$POOL_PORT" = "$POOL_HOST" ]; then
        POOL_PORT="9999"
    fi

    echo ""

    # Worker name
    echo -e "${BOLD}Enter worker name (default: $(hostname)):${NC}"
    read -p "> " WORKER
    WORKER="${WORKER:-$(hostname)}"

    echo ""

    # Threads (0 = auto)
    MAX_THREADS=$(nproc)
    echo -e "${BOLD}Enter number of mining threads (1-$MAX_THREADS, default: auto):${NC}"
    read -p "> " THREADS
    THREADS="${THREADS:-0}"

    # Validate threads
    if ! [[ "$THREADS" =~ ^[0-9]+$ ]]; then
        THREADS=0
    elif [ "$THREADS" -gt "$MAX_THREADS" ]; then
        log_warn "Thread count exceeds CPU count. Using auto."
        THREADS=0
    fi

    echo ""
    echo -e "${GREEN}Configuration:${NC}"
    echo "  Wallet:  $WALLET"
    echo "  Pool:    $POOL_HOST:$POOL_PORT"
    echo "  Worker:  $WORKER"
    echo "  Threads: $([ "$THREADS" = "0" ] && echo "auto ($MAX_THREADS)" || echo "$THREADS")"
    echo ""

    # Save JSON config
    CONFIG_FILE="$HOME/bloxminer/bloxminer.json"
    cat > "$CONFIG_FILE" << EOF
{
  "wallet": "$WALLET",
  "pools": [
    {"host": "$POOL_HOST", "port": $POOL_PORT}
  ],
  "worker": "$WORKER",
  "threads": $THREADS
}
EOF

    log_info "Configuration saved to $CONFIG_FILE"
}

# Create run script
create_run_script() {
    log_step "Creating run scripts..."

    # Main run script (config loaded automatically from bloxminer.json)
    cat > "$HOME/bloxminer/run.sh" << 'EOF'
#!/usr/bin/env bash
# BloxMiner Run Script
cd "$(dirname "$0")"
exec ./build/bloxminer
EOF
    chmod +x "$HOME/bloxminer/run.sh"

    # Background run script
    cat > "$HOME/bloxminer/run-background.sh" << 'EOF'
#!/usr/bin/env bash
# BloxMiner Background Run Script
cd "$(dirname "$0")"

LOG_FILE="$HOME/bloxminer/miner.log"

echo "Starting BloxMiner in background..."
echo "Log file: $LOG_FILE"
echo ""
echo "Commands:"
echo "  View logs:   tail -f $LOG_FILE"
echo "  Stop miner:  pkill -f bloxminer"
echo ""

nohup ./build/bloxminer > "$LOG_FILE" 2>&1 &

echo "Miner started with PID: $!"
EOF
    chmod +x "$HOME/bloxminer/run-background.sh"
    
    # Systemd service file
    cat > "$HOME/bloxminer/bloxminer.service" << EOF
[Unit]
Description=BloxMiner VerusHash CPU Miner
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME/bloxminer
ExecStart=$HOME/bloxminer/run.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    log_info "Run scripts created!"
}

# Print final instructions
print_instructions() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}   BloxMiner Installation Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${BOLD}Quick Start:${NC}"
    echo "  cd ~/bloxminer && ./run.sh"
    echo ""
    echo -e "${BOLD}Run in Background:${NC}"
    echo "  cd ~/bloxminer && ./run-background.sh"
    echo ""
    echo -e "${BOLD}View Logs:${NC}"
    echo "  tail -f ~/bloxminer/miner.log"
    echo ""
    echo -e "${BOLD}Stop Miner:${NC}"
    echo "  pkill -f bloxminer"
    echo ""
    echo -e "${BOLD}Edit Configuration:${NC}"
    echo "  nano ~/bloxminer/bloxminer.json"
    echo ""
    echo -e "${BOLD}Install as System Service (optional):${NC}"
    echo "  sudo cp ~/bloxminer/bloxminer.service /etc/systemd/system/"
    echo "  sudo systemctl daemon-reload"
    echo "  sudo systemctl enable bloxminer"
    echo "  sudo systemctl start bloxminer"
    echo ""
    echo -e "${CYAN}Happy Mining!${NC}"
    echo ""
}

# Ask to start mining
ask_start() {
    echo ""
    read -p "Start mining now? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        cd "$HOME/bloxminer"
        exec ./run.sh
    fi
}

# Main
main() {
    print_banner
    check_root
    check_system
    install_deps
    build_miner
    configure_miner
    create_run_script
    print_instructions
    ask_start
}

main "$@"
