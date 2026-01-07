#pragma once

#include "config.hpp"
#include "stratum/stratum_client.hpp"
#include "verus_hash.h"

#include <thread>
#include <vector>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <chrono>

namespace bloxminer {

/**
 * Mining statistics
 */
struct MinerStats {
    std::atomic<uint64_t> hashes{0};
    std::atomic<uint64_t> shares_accepted{0};
    std::atomic<uint64_t> shares_rejected{0};
    std::atomic<uint64_t> shares_submitted{0};
    std::chrono::steady_clock::time_point start_time;
    
    double get_hashrate() const {
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration<double>(now - start_time).count();
        return elapsed > 0 ? static_cast<double>(hashes.load()) / elapsed : 0.0;
    }
};

/**
 * Multi-threaded CPU miner for VerusHash
 */
class Miner {
public:
    explicit Miner(const MinerConfig& config);
    ~Miner();
    
    /**
     * Start mining
     * @return true if started successfully
     */
    bool start();
    
    /**
     * Stop mining
     */
    void stop();
    
    /**
     * Check if miner is running
     */
    bool is_running() const { return m_running; }
    
    /**
     * Get current statistics
     */
    const MinerStats& get_stats() const { return m_stats; }
    
    /**
     * Get current hashrate
     */
    double get_hashrate() const { return m_stats.get_hashrate(); }

private:
    // Configuration
    MinerConfig m_config;
    
    // State
    std::atomic<bool> m_running{false};
    std::atomic<bool> m_has_job{false};
    
    // Current job
    stratum::Job m_current_job;
    std::mutex m_job_mutex;
    std::condition_variable m_job_cv;
    std::atomic<uint32_t> m_extranonce2{0};
    
    // Threads
    std::vector<std::thread> m_mining_threads;
    std::thread m_stratum_thread;
    std::thread m_stats_thread;
    
    // Stratum client
    stratum::StratumClient m_stratum;
    
    // Statistics
    MinerStats m_stats;
    
    // Methods
    void mining_thread(uint32_t thread_id);
    void stratum_thread();
    void stats_thread();
    
    void on_new_job(const stratum::Job& job);
    void on_share_result(bool accepted, const std::string& reason);
    void submit_share(const stratum::Job& job, uint32_t nonce, const std::string& solution);
    
    bool check_hash(const uint8_t* hash, const uint8_t* target);
};

}  // namespace bloxminer
