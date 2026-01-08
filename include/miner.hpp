#pragma once

#include "config.hpp"
#include "stratum/stratum_client.hpp"
#include "verus_hash.h"
#include "utils/api_server.hpp"

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
    static constexpr size_t MAX_THREADS = 256;
    
    std::atomic<uint64_t> hashes{0};
    std::atomic<uint64_t> shares_accepted{0};
    std::atomic<uint64_t> shares_rejected{0};
    std::atomic<uint64_t> shares_submitted{0};
    std::chrono::steady_clock::time_point start_time;
    
    // Per-thread hash counts for individual hashrate calculation
    std::atomic<uint64_t> thread_hashes[MAX_THREADS] = {};
    std::chrono::steady_clock::time_point thread_start_time[MAX_THREADS];
    uint32_t num_threads = 0;
    
    double get_hashrate() const {
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration<double>(now - start_time).count();
        return elapsed > 0 ? static_cast<double>(hashes.load()) / elapsed : 0.0;
    }
    
    double get_thread_hashrate(uint32_t thread_id) const {
        if (thread_id >= MAX_THREADS) return 0.0;
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration<double>(now - thread_start_time[thread_id]).count();
        return elapsed > 0 ? static_cast<double>(thread_hashes[thread_id].load()) / elapsed : 0.0;
    }
    
    void init_thread(uint32_t thread_id) {
        if (thread_id < MAX_THREADS) {
            thread_hashes[thread_id] = 0;
            thread_start_time[thread_id] = std::chrono::steady_clock::now();
        }
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
    
    // API Server
    utils::ApiServer m_api_server;
    
    // Methods
    void mining_thread(uint32_t thread_id);
    void stratum_thread();
    void stats_thread();
    
    void on_new_job(const stratum::Job& job);
    void on_share_result(bool accepted, const std::string& reason);
    void submit_share(const stratum::Job& job, uint32_t nonce, const std::string& solution);
    
    bool check_hash(const uint8_t* hash, const uint8_t* target);
    
    // API methods
    std::string get_api_stats_json();
};

}  // namespace bloxminer
