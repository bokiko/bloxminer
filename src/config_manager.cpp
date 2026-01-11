#include "../include/config_manager.hpp"
#include "../include/nlohmann/json.hpp"

#include <fstream>
#include <iostream>
#include <cstdlib>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>

using json = nlohmann::json;

namespace bloxminer {

std::string ConfigManager::expand_home_path(const std::string& path) {
    if (path.empty() || path[0] != '~') {
        return path;
    }
    const char* home = std::getenv("HOME");
    if (home == nullptr) {
        return path;
    }
    return std::string(home) + path.substr(1);
}

std::string ConfigManager::get_hostname() {
    char hostname[HOST_NAME_MAX];
    if (gethostname(hostname, HOST_NAME_MAX) == 0) {
        return std::string(hostname);
    }
    return "miner";
}

uint32_t ConfigManager::get_cpu_count() {
    long count = sysconf(_SC_NPROCESSORS_ONLN);
    return count > 0 ? static_cast<uint32_t>(count) : 1;
}

bool ConfigManager::file_exists(const std::string& path) {
    struct stat buffer;
    return (stat(path.c_str(), &buffer) == 0);
}

bool ConfigManager::create_directory(const std::string& path) {
    return mkdir(path.c_str(), 0755) == 0 || errno == EEXIST;
}

std::string ConfigManager::get_global_config_path() {
    std::string home = expand_home_path("~");
    return home + "/" + GLOBAL_CONFIG_DIR + "/" + GLOBAL_CONFIG_FILE;
}

bool ConfigManager::is_interactive_terminal() {
    return isatty(fileno(stdin)) && isatty(fileno(stdout));
}

std::optional<MinerConfig> ConfigManager::load_config(const std::string& custom_path) {
    std::string config_path;

    // Priority: custom path > local > global
    if (!custom_path.empty()) {
        config_path = expand_home_path(custom_path);
        if (!file_exists(config_path)) {
            std::cerr << "Config file not found: " << config_path << std::endl;
            return std::nullopt;
        }
    } else if (file_exists(LOCAL_CONFIG)) {
        config_path = LOCAL_CONFIG;
    } else {
        std::string global_path = get_global_config_path();
        if (file_exists(global_path)) {
            config_path = global_path;
        } else {
            return std::nullopt;  // No config file found
        }
    }

    // Load and parse JSON
    std::ifstream file(config_path);
    if (!file.is_open()) {
        std::cerr << "Failed to open config file: " << config_path << std::endl;
        return std::nullopt;
    }

    try {
        json j;
        file >> j;

        MinerConfig config;

        // Parse wallet (required in config)
        if (j.contains("wallet")) {
            config.wallet_address = j["wallet"].get<std::string>();
        }

        // Parse pools array
        if (j.contains("pools") && j["pools"].is_array()) {
            for (const auto& pool_json : j["pools"]) {
                PoolConfig pool;
                pool.host = pool_json.value("host", "pool.verus.io");
                pool.port = pool_json.value("port", 9999);
                pool.priority = config.pools.size();
                config.pools.push_back(pool);
            }
        }

        // If no pools specified, use default
        if (config.pools.empty()) {
            PoolConfig default_pool;
            default_pool.host = "pool.verus.io";
            default_pool.port = 9999;
            default_pool.priority = 0;
            config.pools.push_back(default_pool);
        }

        // Set legacy pool fields for compatibility
        if (!config.pools.empty()) {
            config.pool_host = config.pools[0].host;
            config.pool_port = config.pools[0].port;
        }

        // Parse worker settings
        config.worker_name = j.value("worker", get_hostname());
        config.worker_password = j.value("password", "x");

        // Parse threads (0 = auto)
        config.num_threads = j.value("threads", 0);

        // Parse API settings
        if (j.contains("api")) {
            const auto& api = j["api"];
            config.api_enabled = api.value("enabled", true);
            config.api_port = api.value("port", 4068);
            config.api_bind_address = api.value("bind", "127.0.0.1");
        }

        // Parse display settings
        if (j.contains("display")) {
            const auto& display = j["display"];
            config.stats_interval = display.value("stats_interval", 10);
            config.show_shares = display.value("show_shares", true);
        }

        std::cout << "Loaded config from: " << config_path << std::endl;
        return config;

    } catch (const json::exception& e) {
        std::cerr << "Error parsing config file: " << e.what() << std::endl;
        return std::nullopt;
    }
}

bool ConfigManager::save_config(const MinerConfig& config, const std::string& path) {
    std::string save_path = expand_home_path(path);

    // Create directory if saving to global path
    if (save_path.find(GLOBAL_CONFIG_DIR) != std::string::npos) {
        std::string dir = expand_home_path("~/" + std::string(GLOBAL_CONFIG_DIR));
        create_directory(dir);
    }

    // Build JSON object
    json j;
    j["wallet"] = config.wallet_address;

    // Build pools array
    json pools_array = json::array();
    for (const auto& pool : config.pools) {
        json pool_json;
        pool_json["host"] = pool.host;
        pool_json["port"] = pool.port;
        pools_array.push_back(pool_json);
    }
    j["pools"] = pools_array;

    j["worker"] = config.worker_name;
    j["password"] = config.worker_password;
    j["threads"] = config.num_threads;

    // API settings
    json api;
    api["enabled"] = config.api_enabled;
    api["port"] = config.api_port;
    api["bind"] = config.api_bind_address;
    j["api"] = api;

    // Write to file
    std::ofstream file(save_path);
    if (!file.is_open()) {
        std::cerr << "Failed to create config file: " << save_path << std::endl;
        return false;
    }

    file << j.dump(2) << std::endl;
    return true;
}

MinerConfig ConfigManager::interactive_setup() {
    MinerConfig config;
    std::string input;

    std::cout << "\n";
    std::cout << "========================================\n";
    std::cout << "   BloxMiner First-Run Setup\n";
    std::cout << "========================================\n";
    std::cout << "\n";

    // Wallet address (required)
    std::cout << "Enter your Verus (VRSC) wallet address:\n";
    std::cout << "> ";
    std::getline(std::cin, config.wallet_address);
    while (config.wallet_address.empty()) {
        std::cout << "Wallet address is required!\n";
        std::cout << "> ";
        std::getline(std::cin, config.wallet_address);
    }

    std::cout << "\n";

    // Pool address
    std::cout << "Enter pool address [pool.verus.io:9999]:\n";
    std::cout << "> ";
    std::getline(std::cin, input);

    PoolConfig pool;
    if (input.empty()) {
        pool.host = "pool.verus.io";
        pool.port = 9999;
    } else {
        // Parse host:port
        size_t colon_pos = input.find(':');
        if (colon_pos != std::string::npos) {
            pool.host = input.substr(0, colon_pos);
            try {
                pool.port = static_cast<uint16_t>(std::stoi(input.substr(colon_pos + 1)));
            } catch (...) {
                pool.port = 9999;
            }
        } else {
            pool.host = input;
            pool.port = 9999;
        }
    }
    pool.priority = 0;
    config.pools.push_back(pool);
    config.pool_host = pool.host;
    config.pool_port = pool.port;

    std::cout << "\n";

    // Worker name
    std::string default_worker = get_hostname();
    std::cout << "Enter worker name [" << default_worker << "]:\n";
    std::cout << "> ";
    std::getline(std::cin, input);
    config.worker_name = input.empty() ? default_worker : input;

    std::cout << "\n";

    // Thread count
    uint32_t max_threads = get_cpu_count();
    std::cout << "Enter thread count (1-" << max_threads << ") [auto=" << max_threads << "]:\n";
    std::cout << "> ";
    std::getline(std::cin, input);
    if (input.empty()) {
        config.num_threads = 0;  // 0 = auto
    } else {
        try {
            config.num_threads = static_cast<uint32_t>(std::stoul(input));
            if (config.num_threads > max_threads * 2) {
                config.num_threads = max_threads;
            }
        } catch (...) {
            config.num_threads = 0;
        }
    }

    std::cout << "\n";
    std::cout << "----------------------------------------\n";
    std::cout << "Configuration Summary:\n";
    std::cout << "  Wallet:  " << config.wallet_address << "\n";
    std::cout << "  Pool:    " << pool.host << ":" << pool.port << "\n";
    std::cout << "  Worker:  " << config.worker_name << "\n";
    std::cout << "  Threads: " << (config.num_threads == 0 ? "auto" : std::to_string(config.num_threads)) << "\n";
    std::cout << "----------------------------------------\n";
    std::cout << "\n";

    return config;
}

}  // namespace bloxminer
