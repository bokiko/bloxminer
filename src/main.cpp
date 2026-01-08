#include "../include/config.hpp"
#include "../include/miner.hpp"
#include "../include/utils/logger.hpp"
#include "verus_hash.h"

#include <iostream>
#include <csignal>
#include <cstring>
#include <getopt.h>
#include <thread>
#include <algorithm>
#include <cctype>

using namespace bloxminer;

// Validate Verus wallet address format (warning only)
bool validate_verus_address(const std::string& addr) {
    // Basic Verus address validation:
    // - Transparent addresses start with 'R' (34 chars, Base58)
    // - Identity addresses start with 'i' (variable length)
    if (addr.empty()) return false;
    if (addr[0] != 'R' && addr[0] != 'i') return false;
    if (addr.length() < 25 || addr.length() > 36) return false;

    // Check alphanumeric (Base58 charset - no 0, O, I, l)
    for (char c : addr) {
        if (!std::isalnum(static_cast<unsigned char>(c))) return false;
    }

    return true;
}

// Global miner pointer for signal handling
static Miner* g_miner = nullptr;

void signal_handler(int signum) {
    (void)signum;
    std::cout << "\nInterrupt received, shutting down..." << std::endl;
    if (g_miner) {
        g_miner->stop();
    }
}

void print_banner() {
    std::cout << R"(
  ____  _            __  __ _                 
 | __ )| | _____  __| \/ (_)_ __   ___ _ __ 
 |  _ \| |/ _ \ \/ /| |\/| | '_ \ / _ \ '__|
 | |_) | | (_) >  < | |  | | | | |  __/ |   
 |____/|_|\___/_/\_\|_|  |_|_| |_|\___|_|   
                                             
)" << std::endl;
    std::cout << "  BloxMiner v" << VERSION << " - VerusHash CPU Miner" << std::endl;
    std::cout << "  ===========================================" << std::endl;
    std::cout << std::endl;
}

void print_usage(const char* program) {
    std::cout << "Usage: " << program << " [options]" << std::endl;
    std::cout << std::endl;
    std::cout << "Options:" << std::endl;
    std::cout << "  -o, --pool <host:port>    Pool address (default: eu.luckpool.net:3956)" << std::endl;
    std::cout << "  -u, --user <wallet>       Wallet address" << std::endl;
    std::cout << "  -p, --pass <password>     Pool password (default: x)" << std::endl;
    std::cout << "  -w, --worker <name>       Worker name (default: bloxminer)" << std::endl;
    std::cout << "  -t, --threads <num>       Number of mining threads (default: auto)" << std::endl;
    std::cout << "  --api-port <port>         API server port (default: 4068, 0 to disable)" << std::endl;
    std::cout << "  --api-bind <addr>         API bind address (default: 127.0.0.1)" << std::endl;
    std::cout << "  -h, --help                Show this help message" << std::endl;
    std::cout << std::endl;
    std::cout << "Example:" << std::endl;
    std::cout << "  " << program << " -o eu.luckpool.net:3956 -u RYourWalletAddress -w rig1" << std::endl;
    std::cout << std::endl;
}

bool parse_pool(const std::string& pool, std::string& host, uint16_t& port) {
    size_t colon = pool.rfind(':');
    if (colon == std::string::npos) {
        host = pool;
        port = 3956;  // Default Verus stratum port
        return true;
    }
    
    host = pool.substr(0, colon);
    try {
        port = static_cast<uint16_t>(std::stoi(pool.substr(colon + 1)));
    } catch (...) {
        return false;
    }
    
    return true;
}

int main(int argc, char* argv[]) {
    MinerConfig config;
    
    // Parse command line options
    static struct option long_options[] = {
        {"pool",     required_argument, 0, 'o'},
        {"user",     required_argument, 0, 'u'},
        {"pass",     required_argument, 0, 'p'},
        {"worker",   required_argument, 0, 'w'},
        {"threads",  required_argument, 0, 't'},
        {"api-port", required_argument, 0, 'a'},
        {"api-bind", required_argument, 0, 'b'},
        {"help",     no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };
    
    int opt;
    while ((opt = getopt_long(argc, argv, "o:u:p:w:t:a:b:h", long_options, nullptr)) != -1) {
        switch (opt) {
            case 'o':
                if (!parse_pool(optarg, config.pool_host, config.pool_port)) {
                    std::cerr << "Invalid pool address: " << optarg << std::endl;
                    return 1;
                }
                break;
            case 'u':
                config.wallet_address = optarg;
                break;
            case 'p':
                config.worker_password = optarg;
                break;
            case 'w':
                config.worker_name = optarg;
                break;
            case 't':
                try {
                    config.num_threads = static_cast<uint32_t>(std::stoi(optarg));

                    // Bounds check: max 2x hardware threads or 256
                    uint32_t hw_threads = std::thread::hardware_concurrency();
                    uint32_t max_threads = std::max(256u, hw_threads > 0 ? hw_threads * 2 : 256u);
                    if (config.num_threads > max_threads) {
                        std::cerr << "Thread count " << config.num_threads
                                  << " exceeds maximum (" << max_threads << ")" << std::endl;
                        return 1;
                    }
                } catch (...) {
                    std::cerr << "Invalid thread count: " << optarg << std::endl;
                    return 1;
                }
                break;
            case 'a':
                try {
                    int port = std::stoi(optarg);
                    if (port == 0) {
                        config.api_enabled = false;
                    } else if (port > 0 && port <= 65535) {
                        config.api_port = static_cast<uint16_t>(port);
                        config.api_enabled = true;
                    } else {
                        std::cerr << "Invalid API port: " << optarg << std::endl;
                        return 1;
                    }
                } catch (...) {
                    std::cerr << "Invalid API port: " << optarg << std::endl;
                    return 1;
                }
                break;
            case 'b':
                config.api_bind_address = optarg;
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }

    print_banner();
    
    // Validate configuration
    if (config.wallet_address.empty()) {
        std::cerr << "Error: Wallet address is required (-u option)" << std::endl;
        print_usage(argv[0]);
        return 1;
    }

    // Validate wallet address format (warning only - user may know better)
    if (!validate_verus_address(config.wallet_address)) {
        std::cerr << "Warning: Wallet address format may be invalid: "
                  << config.wallet_address << std::endl;
        std::cerr << "Expected: R... (34 chars) for transparent or i... for identity" << std::endl;
        std::cerr << "Continuing anyway..." << std::endl;
    }

    // Check CPU features
    if (!verus::Hasher::supported()) {
        std::cerr << "Error: Your CPU does not support required features." << std::endl;
        std::cerr << "VerusHash requires AES-NI, AVX, and PCLMUL for efficient mining." << std::endl;
        return 1;
    }
    
    LOG_INFO("CPU supports VerusHash requirements - OK");
    
    // Setup signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Create and start miner
    Miner miner(config);
    g_miner = &miner;
    
    if (!miner.start()) {
        std::cerr << "Failed to start miner" << std::endl;
        return 1;
    }
    
    // Wait for miner to finish
    while (miner.is_running()) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    
    g_miner = nullptr;
    
    // Print final stats
    const auto& stats = miner.get_stats();
    std::cout << std::endl;
    std::cout << "Final Statistics:" << std::endl;
    std::cout << "  Total hashes: " << stats.hashes.load() << std::endl;
    std::cout << "  Shares accepted: " << stats.shares_accepted.load() << std::endl;
    std::cout << "  Shares rejected: " << stats.shares_rejected.load() << std::endl;
    
    return 0;
}
