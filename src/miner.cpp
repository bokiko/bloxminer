#include "../include/miner.hpp"
#include "../include/utils/hex_utils.hpp"
#include "../include/utils/logger.hpp"

#include <cstring>
#include <sstream>
#include <iomanip>
#include <algorithm>

namespace bloxminer {

Miner::Miner(const MinerConfig& config) : m_config(config) {
    // Auto-detect thread count if not specified
    if (m_config.num_threads == 0) {
        m_config.num_threads = std::thread::hardware_concurrency();
        if (m_config.num_threads == 0) {
            m_config.num_threads = 4;  // Fallback
        }
    }
}

Miner::~Miner() {
    stop();
}

bool Miner::start() {
    if (m_running) {
        return true;
    }
    
    // Check CPU support
    if (!verus::Hasher::supported()) {
        LOG_ERROR("CPU does not support required features (AES-NI, AVX, PCLMUL)");
        return false;
    }
    
    LOG_INFO("Starting BloxMiner v%s", VERSION);
    LOG_INFO("Using %d mining threads", m_config.num_threads);
    LOG_INFO("Pool: %s:%d", m_config.pool_host.c_str(), m_config.pool_port);
    LOG_INFO("Wallet: %s", m_config.wallet_address.c_str());
    
    m_running = true;
    m_stats.start_time = std::chrono::steady_clock::now();
    
    // Setup stratum callbacks
    m_stratum.on_job([this](const stratum::Job& job) {
        on_new_job(job);
    });
    
    m_stratum.on_share_result([this](bool accepted, const std::string& reason) {
        on_share_result(accepted, reason);
    });
    
    // Start stratum thread
    m_stratum_thread = std::thread(&Miner::stratum_thread, this);
    
    // Start stats thread
    m_stats_thread = std::thread(&Miner::stats_thread, this);
    
    // Start mining threads
    m_mining_threads.reserve(m_config.num_threads);
    for (uint32_t i = 0; i < m_config.num_threads; i++) {
        m_mining_threads.emplace_back(&Miner::mining_thread, this, i);
    }
    
    return true;
}

void Miner::stop() {
    if (!m_running) {
        return;
    }
    
    LOG_INFO("Stopping miner...");
    
    m_running = false;
    m_has_job = false;
    m_job_cv.notify_all();
    
    // Stop stratum
    m_stratum.stop();
    m_stratum.disconnect();
    
    // Join threads
    if (m_stratum_thread.joinable()) {
        m_stratum_thread.join();
    }
    
    if (m_stats_thread.joinable()) {
        m_stats_thread.join();
    }
    
    for (auto& t : m_mining_threads) {
        if (t.joinable()) {
            t.join();
        }
    }
    
    m_mining_threads.clear();
    
    LOG_INFO("Miner stopped");
}

void Miner::stratum_thread() {
    while (m_running) {
        // Connect to pool
        if (!m_stratum.connect(m_config.pool_host, m_config.pool_port)) {
            LOG_ERROR("Failed to connect to pool, retrying in %d seconds...", m_config.reconnect_delay);
            std::this_thread::sleep_for(std::chrono::seconds(m_config.reconnect_delay));
            continue;
        }
        
        // Subscribe
        if (!m_stratum.subscribe()) {
            LOG_ERROR("Failed to subscribe, reconnecting...");
            m_stratum.disconnect();
            std::this_thread::sleep_for(std::chrono::seconds(m_config.reconnect_delay));
            continue;
        }
        
        // Authorize
        std::string username = m_config.wallet_address;
        if (!m_config.worker_name.empty()) {
            username += "." + m_config.worker_name;
        }
        
        if (!m_stratum.authorize(username, m_config.worker_password)) {
            LOG_ERROR("Failed to authorize, reconnecting...");
            m_stratum.disconnect();
            std::this_thread::sleep_for(std::chrono::seconds(m_config.reconnect_delay));
            continue;
        }
        
        // Run receive loop (blocks until disconnected)
        m_stratum.run();
        
        if (m_running) {
            utils::Logger::instance().disconnected("Connection lost, reconnecting...");
            std::this_thread::sleep_for(std::chrono::seconds(m_config.reconnect_delay));
        }
    }
}

void Miner::stats_thread() {
    while (m_running) {
        std::this_thread::sleep_for(std::chrono::seconds(m_config.stats_interval));
        
        if (!m_running) break;
        
        double hashrate = m_stats.get_hashrate();
        utils::Logger::instance().hashrate(hashrate);
        utils::Logger::instance().share_accepted(
            m_stats.shares_accepted.load(),
            m_stats.shares_rejected.load()
        );
    }
}

void Miner::mining_thread(uint32_t thread_id) {
    verus::Hasher hasher;
    alignas(32) uint8_t hash[32];
    alignas(32) uint8_t header[80];
    alignas(32) uint8_t target[32];
    
    std::string current_job_id;
    uint32_t nonce = thread_id;  // Each thread starts at different offset
    uint32_t nonce_step = m_config.num_threads;
    
    LOG_INFO("Mining thread %d started", thread_id);
    
    while (m_running) {
        // Wait for job
        {
            std::unique_lock<std::mutex> lock(m_job_mutex);
            m_job_cv.wait_for(lock, std::chrono::milliseconds(100), [this] {
                return m_has_job || !m_running;
            });
            
            if (!m_running) break;
            if (!m_has_job) continue;
            
            // Check if job changed
            if (m_current_job.job_id != current_job_id) {
                current_job_id = m_current_job.job_id;
                memcpy(header, m_current_job.header, 80);
                memcpy(target, m_current_job.target, 32);
                
                // Initialize hasher with new header (80 bytes for stratum)
                hasher.init(header, 80);
                
                // Reset nonce for new job
                nonce = thread_id;
            }
        }
        
        // Mine batch
        uint32_t batch_end = nonce + m_config.batch_size;
        
        while (nonce < batch_end && m_running && m_has_job) {
            // Check if job changed
            if (m_current_job.job_id != current_job_id) {
                break;
            }
            
            // Compute hash
            hasher.hash(nonce, hash);
            m_stats.hashes++;
            
            // Check if hash meets target
            if (check_hash(hash, target)) {
                // Found a share!
                std::lock_guard<std::mutex> lock(m_job_mutex);
                
                // Generate extranonce2
                uint32_t en2 = m_extranonce2++;
                std::stringstream ss;
                ss << std::hex << std::setfill('0') << std::setw(m_stratum.get_extranonce2_size() * 2) << en2;
                
                utils::Logger::instance().share_found(m_current_job.difficulty);
                submit_share(m_current_job, nonce, ss.str());
            }
            
            nonce += nonce_step;
        }
        
        // Wrap nonce if needed
        if (nonce >= 0xFFFFFFFF - nonce_step) {
            nonce = thread_id;
        }
    }
    
    LOG_INFO("Mining thread %d stopped", thread_id);
}

void Miner::on_new_job(const stratum::Job& job) {
    std::lock_guard<std::mutex> lock(m_job_mutex);
    
    m_current_job = job;
    m_has_job = true;
    m_job_cv.notify_all();
}

void Miner::on_share_result(bool accepted, const std::string& reason) {
    if (accepted) {
        m_stats.shares_accepted++;
        if (m_config.show_shares) {
            LOG_INFO("Share accepted!");
        }
    } else {
        m_stats.shares_rejected++;
        LOG_WARN("Share rejected: %s", reason.c_str());
    }
}

void Miner::submit_share(const stratum::Job& job, uint32_t nonce, const std::string& extranonce2) {
    stratum::Share share;
    share.job_id = job.job_id;
    share.extranonce2 = extranonce2;
    share.ntime = job.ntime;
    share.nonce = nonce;
    
    m_stats.shares_submitted++;
    m_stratum.submit_share(share);
}

bool Miner::check_hash(const uint8_t* hash, const uint8_t* target) {
    return utils::meets_target(hash, target);
}

}  // namespace bloxminer
