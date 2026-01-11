#include "../include/config.hpp"
#include "../include/config_manager.hpp"
#include "../include/miner.hpp"
#include "../include/utils/logger.hpp"
#include "../include/utils/display.hpp"
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
    std::cout << "  -c, --config <path>       Config file path (default: bloxminer.json)" << std::endl;
    std::cout << "  -o, --pool <host:port>    Pool address (can specify multiple for failover)" << std::endl;
    std::cout << "  -u, --user <wallet>       Wallet address" << std::endl;
    std::cout << "  -p, --pass <password>     Pool password (default: x)" << std::endl;
    std::cout << "  -w, --worker <name>       Worker name (default: bloxminer)" << std::endl;
    std::cout << "  -t, --threads <num>       Number of mining threads (default: auto)" << std::endl;
    std::cout << "  --api-port <port>         API server port (default: 4068, 0 to disable)" << std::endl;
    std::cout << "  --api-bind <addr>         API bind address (default: 127.0.0.1)" << std::endl;
    std::cout << "  -q, --quiet               Quiet mode - reduce log verbosity (only warnings/errors)" << std::endl;
    std::cout << "  -h, --help                Show this help message" << std::endl;
    std::cout << std::endl;
    std::cout << "Config File:" << std::endl;
    std::cout << "  On first run without arguments, interactive setup creates bloxminer.json" << std::endl;
    std::cout << "  CLI arguments override config file values" << std::endl;
    std::cout << std::endl;
    std::cout << "Examples:" << std::endl;
    std::cout << "  " << program << "                                    # Use config file or interactive setup" << std::endl;
    std::cout << "  " << program << " -o eu.luckpool.net:3956 -u RWallet -w rig1" << std::endl;
    std::cout << "  " << program << " -o primary:3956 -o backup:3956 -u RWallet  # Failover pools" << std::endl;
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
    // Step 1: Parse command line options first pass to get config path and help
    static struct option long_options[] = {
        {"config",   required_argument, 0, 'c'},
        {"pool",     required_argument, 0, 'o'},
        {"user",     required_argument, 0, 'u'},
        {"pass",     required_argument, 0, 'p'},
        {"worker",   required_argument, 0, 'w'},
        {"threads",  required_argument, 0, 't'},
        {"api-port", required_argument, 0, 'a'},
        {"api-bind", required_argument, 0, 'b'},
        {"quiet",    no_argument,       0, 'q'},
        {"help",     no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    std::string custom_config_path;
    bool quiet_mode = false;

    // Track which CLI args were explicitly set
    bool cli_wallet_set = false;
    bool cli_pools_set = false;
    bool cli_worker_set = false;
    bool cli_password_set = false;
    bool cli_threads_set = false;
    bool cli_api_port_set = false;
    bool cli_api_bind_set = false;

    // Temporary storage for CLI values
    MinerConfig cli_config;

    int opt;
    while ((opt = getopt_long(argc, argv, "c:o:u:p:w:t:a:b:qh", long_options, nullptr)) != -1) {
        switch (opt) {
            case 'c':
                custom_config_path = optarg;
                break;
            case 'o': {
                PoolConfig pool;
                if (!parse_pool(optarg, pool.host, pool.port)) {
                    std::cerr << "Invalid pool address: " << optarg << std::endl;
                    return 1;
                }
                pool.priority = static_cast<int>(cli_config.pools.size());
                cli_config.pools.push_back(pool);
                cli_pools_set = true;
                break;
            }
            case 'u':
                cli_config.wallet_address = optarg;
                cli_wallet_set = true;
                break;
            case 'p':
                cli_config.worker_password = optarg;
                cli_password_set = true;
                break;
            case 'w':
                cli_config.worker_name = optarg;
                cli_worker_set = true;
                break;
            case 't':
                try {
                    cli_config.num_threads = static_cast<uint32_t>(std::stoi(optarg));
                    uint32_t hw_threads = std::thread::hardware_concurrency();
                    uint32_t max_threads = std::max(256u, hw_threads > 0 ? hw_threads * 2 : 256u);
                    if (cli_config.num_threads > max_threads) {
                        std::cerr << "Thread count " << cli_config.num_threads
                                  << " exceeds maximum (" << max_threads << ")" << std::endl;
                        return 1;
                    }
                    cli_threads_set = true;
                } catch (...) {
                    std::cerr << "Invalid thread count: " << optarg << std::endl;
                    return 1;
                }
                break;
            case 'a':
                try {
                    int port = std::stoi(optarg);
                    if (port == 0) {
                        cli_config.api_enabled = false;
                    } else if (port > 0 && port <= 65535) {
                        cli_config.api_port = static_cast<uint16_t>(port);
                        cli_config.api_enabled = true;
                    } else {
                        std::cerr << "Invalid API port: " << optarg << std::endl;
                        return 1;
                    }
                    cli_api_port_set = true;
                } catch (...) {
                    std::cerr << "Invalid API port: " << optarg << std::endl;
                    return 1;
                }
                break;
            case 'b':
                cli_config.api_bind_address = optarg;
                cli_api_bind_set = true;
                break;
            case 'q':
                quiet_mode = true;
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }

    // Step 2: Load config file (if exists)
    MinerConfig config;
    auto file_config = ConfigManager::load_config(custom_config_path);
    bool config_loaded = false;

    if (file_config) {
        config = *file_config;
        config_loaded = true;
    }

    // Step 3: Merge CLI args over config file values (CLI takes precedence)
    if (cli_wallet_set) config.wallet_address = cli_config.wallet_address;
    if (cli_pools_set) config.pools = cli_config.pools;
    if (cli_worker_set) config.worker_name = cli_config.worker_name;
    if (cli_password_set) config.worker_password = cli_config.worker_password;
    if (cli_threads_set) config.num_threads = cli_config.num_threads;
    if (cli_api_port_set) {
        config.api_port = cli_config.api_port;
        config.api_enabled = cli_config.api_enabled;
    }
    if (cli_api_bind_set) config.api_bind_address = cli_config.api_bind_address;

    // Update legacy pool fields if CLI pools were set
    if (cli_pools_set && !cli_config.pools.empty()) {
        config.pool_host = cli_config.pools[0].host;
        config.pool_port = cli_config.pools[0].port;
    }

    // Step 4: Interactive setup if no config file AND no wallet provided AND interactive terminal
    if (!config_loaded && config.wallet_address.empty() && ConfigManager::is_interactive_terminal()) {
        print_banner();
        config = ConfigManager::interactive_setup();

        // Offer to save configuration
        std::cout << "Save this configuration? [Y/n]: ";
        std::string save_input;
        std::getline(std::cin, save_input);
        if (save_input.empty() || save_input[0] == 'y' || save_input[0] == 'Y') {
            if (ConfigManager::save_config(config)) {
                std::cout << "Configuration saved to bloxminer.json\n" << std::endl;
            }
        }
        std::cout << std::endl;
    }

    // If no pools specified, use the default pool
    if (config.pools.empty()) {
        PoolConfig default_pool;
        default_pool.host = config.pool_host;
        default_pool.port = config.pool_port;
        default_pool.priority = 0;
        config.pools.push_back(default_pool);
    }

    // Auto-detect thread count if not specified
    uint32_t num_threads = config.num_threads;
    if (num_threads == 0) {
        num_threads = std::thread::hardware_concurrency();
        if (num_threads == 0) {
            num_threads = 4;  // Fallback
        }
    }

    // Print banner (skip if already printed during interactive setup)
    if (config_loaded || cli_wallet_set) {
        print_banner();
    }

    // Validate configuration before initializing display
    if (config.wallet_address.empty()) {
        std::cerr << "Error: Wallet address is required" << std::endl;
        std::cerr << "  Run without arguments for interactive setup, or use:" << std::endl;
        std::cerr << "  " << argv[0] << " -u <wallet_address>" << std::endl;
        return 1;
    }

    // Validate wallet address format (warning only - user may know better)
    if (!validate_verus_address(config.wallet_address)) {
        std::cerr << "Warning: Wallet address format may be invalid: "
                  << config.wallet_address << std::endl;
        std::cerr << "Expected: R... (34 chars) for transparent or i... for identity" << std::endl;
        std::cerr << "Continuing anyway..." << std::endl;
    }

    // Check CPU features before initializing display
    if (!verus::Hasher::supported()) {
        std::cerr << "Error: Your CPU does not support required features." << std::endl;
        std::cerr << "VerusHash requires AES-NI, AVX, and PCLMUL for efficient mining." << std::endl;
        return 1;
    }

    // Initialize Display with sticky header BEFORE any LOG calls
    // This sets up the scroll region so logs appear below the header
    utils::Display::instance().init(num_threads);

    // Set log level based on quiet mode
    if (quiet_mode) {
        utils::Logger::instance().set_level(utils::LogLevel::WARN);
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
