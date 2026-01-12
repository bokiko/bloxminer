#pragma once

#include <string>
#include <cstdint>
#include <vector>

namespace bloxminer {

/**
 * Configuration for a single pool
 */
struct PoolConfig {
    std::string host;
    uint16_t port = 3956;
    int priority = 0;      // lower = higher priority
    int fail_count = 0;    // consecutive failures
};

struct MinerConfig {
    // Pool settings (legacy single pool - for backwards compatibility)
    std::string pool_host = "eu.luckpool.net";
    uint16_t pool_port = 3956;  // Verus stratum port

    // Multiple pool support (failover)
    std::vector<PoolConfig> pools;
    
    // Mining credentials
    std::string wallet_address = "";  // Required - set via -u flag
    std::string worker_name = "bloxminer";
    std::string worker_password = "x";
    
    // Mining settings
    uint32_t num_threads = 0;  // 0 = auto-detect
    uint32_t batch_size = 0x10000;  // Nonces per batch
    
    // Display settings
    uint32_t stats_interval = 10;  // Seconds between stats output
    bool show_shares = true;
    
    // Connection settings
    uint32_t reconnect_delay = 5;  // Seconds
    uint32_t timeout = 30;  // Seconds
    
    // API settings
    bool api_enabled = true;
    uint16_t api_port = 4068;  // Standard mining API port
    std::string api_bind_address = "127.0.0.1";  // Default to localhost for security
};

// Version info
constexpr const char* VERSION = "1.1.1";
constexpr const char* NAME = "BloxMiner";

}  // namespace bloxminer
