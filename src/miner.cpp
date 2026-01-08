#include "../include/miner.hpp"
#include "../include/utils/hex_utils.hpp"
#include "../include/utils/logger.hpp"
#include "../include/utils/system_monitor.hpp"
#include "../include/utils/display.hpp"

#include <cstring>
#include <sstream>
#include <iomanip>
#include <algorithm>
#include <fstream>

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
    m_stats.num_threads = m_config.num_threads;
    
    // Initialize display with sticky header
    utils::Display::instance().init(m_config.num_threads);
    
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
    
    // Start API server
    if (m_config.api_enabled) {
        auto stats_callback = [this]() -> std::string {
            return get_api_stats_json();
        };
        if (m_api_server.start(m_config.api_port, stats_callback)) {
            LOG_INFO("API server started on port %d", m_config.api_port);
        } else {
            LOG_WARN("Failed to start API server on port %d", m_config.api_port);
        }
    }
    
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
    
    // Reset terminal display
    utils::Display::instance().cleanup();
    
    LOG_INFO("Stopping miner...");
    
    // Stop API server
    m_api_server.stop();
    
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
        
        // Get system stats (temp, power)
        auto sys_stats = utils::SystemMonitor::instance().get_stats();
        
        // Build display stats
        utils::Display::Stats disp_stats;
        disp_stats.total_hashrate = hashrate;
        disp_stats.cpu_temp = sys_stats.cpu_temp;
        disp_stats.cpu_power = sys_stats.cpu_power;
        disp_stats.accepted = m_stats.shares_accepted.load();
        disp_stats.rejected = m_stats.shares_rejected.load();
        disp_stats.pool = m_config.pool_host + ":" + std::to_string(m_config.pool_port);
        disp_stats.worker = m_config.worker_name;
        disp_stats.difficulty = m_current_job.difficulty;
        
        auto now = std::chrono::steady_clock::now();
        disp_stats.uptime_seconds = std::chrono::duration<double>(now - m_stats.start_time).count();
        
        // Collect per-thread hashrates
        for (uint32_t i = 0; i < m_config.num_threads; i++) {
            disp_stats.thread_hashrates.push_back(m_stats.get_thread_hashrate(i));
        }

        // Update sticky header
        utils::Display::instance().update_header(disp_stats);

        // Log plain-text stats line for h-stats.sh parsing
        // Format: [STATS] hr=24.15 unit=MH temp=56 ac=100 rj=0 thr=756.0K,759.8K,...
        std::string hr_unit = "H";
        double hr_value = hashrate;
        if (hashrate >= 1e9) { hr_value = hashrate / 1e9; hr_unit = "GH"; }
        else if (hashrate >= 1e6) { hr_value = hashrate / 1e6; hr_unit = "MH"; }
        else if (hashrate >= 1e3) { hr_value = hashrate / 1e3; hr_unit = "KH"; }

        // Build per-thread string
        std::stringstream threads_ss;
        for (uint32_t i = 0; i < m_config.num_threads; i++) {
            if (i > 0) threads_ss << ",";
            double thr = disp_stats.thread_hashrates[i];
            if (thr >= 1e6) threads_ss << std::fixed << std::setprecision(1) << (thr/1e6) << "M";
            else if (thr >= 1e3) threads_ss << std::fixed << std::setprecision(1) << (thr/1e3) << "K";
            else threads_ss << std::fixed << std::setprecision(0) << thr;
        }

        // Calculate efficiency (KH/W) if power is available
        double efficiency = 0.0;
        if (sys_stats.cpu_power > 0) {
            efficiency = hashrate / 1000.0 / sys_stats.cpu_power;
        }

        // Build stats string manually since LOG_INFO uses simple format parsing
        std::stringstream stats_ss;
        stats_ss << "[STATS] hr=" << std::fixed << std::setprecision(2) << hr_value
                 << " unit=" << hr_unit
                 << " temp=" << static_cast<int>(sys_stats.cpu_temp)
                 << " power=" << std::fixed << std::setprecision(1) << sys_stats.cpu_power
                 << " eff=" << std::fixed << std::setprecision(1) << efficiency
                 << " ac=" << disp_stats.accepted
                 << " rj=" << disp_stats.rejected
                 << " thr=" << threads_ss.str();
        LOG_INFO("%s", stats_ss.str().c_str());
        
        // Write stats to file for HiveOS h-stats.sh (avoids screen buffer issues)
        std::ofstream stats_file("/tmp/bloxminer_stats.txt", std::ios::trunc);
        if (stats_file.is_open()) {
            stats_file << stats_ss.str() << std::endl;
            stats_file.close();
        }
    }
}

void Miner::mining_thread(uint32_t thread_id) {
    verus::Hasher hasher;
    alignas(32) uint8_t hash[32];
    alignas(32) uint8_t target[32];
    
    // Full block buffer: 140-byte header + 3-byte prefix + 1344-byte solution = 1487 bytes
    alignas(32) uint8_t full_block[1536];  // Aligned and padded
    
    // Intermediate state from hash_half (64 bytes)
    alignas(32) uint8_t intermediate[64];
    
    // 15-byte nonceSpace for hash_with_nonce
    uint8_t nonceSpace[15] = {0};
    
    std::string current_job_id;
    std::string current_solution;
    uint8_t solution_version = 0;
    uint32_t nonce = thread_id;  // Each thread starts at different offset
    uint32_t nonce_step = m_config.num_threads;
    
    // Thread started silently for cleaner display
    
    // Initialize per-thread stats
    m_stats.init_thread(thread_id);
    
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
                current_solution = m_current_job.solution;
                memcpy(target, m_current_job.target, 32);
                
                // Build full block for hashing
                memset(full_block, 0, sizeof(full_block));
                
                // Copy 140-byte header
                memcpy(full_block, m_current_job.header, 140);
                
                // Add solution prefix (fd4005 = compact size for 1344)
                full_block[140] = 0xfd;
                full_block[141] = 0x40;
                full_block[142] = 0x05;
                
                // Copy solution body (pad to 1344 bytes)
                size_t sol_bytes = current_solution.length() / 2;
                utils::hex_to_bytes(current_solution, full_block + 143, sol_bytes);
                
                // Get solution version (first byte of solution body)
                solution_version = full_block[143];
                
                // Save header nonce values to nonceSpace BEFORE clearing
                // nonceSpace layout from ccminer (15 bytes total):
                // - bytes 0-6: header[108:114] = first 7 bytes of nNonce (extranonce1 + padding)
                // - bytes 7-10: header[128:131] = bytes 20-23 of nNonce (more padding)
                // - bytes 11-14: mining nonce (set per-iteration)
                //
                // From ccminer: memcpy(nonceSpace, &pdata[27], 7);  // bytes 108-114
                //               memcpy(nonceSpace + 7, &pdata[32], 4);  // bytes 128-131
                memcpy(nonceSpace, full_block + 108, 7);
                memcpy(nonceSpace + 7, full_block + 128, 4);
                // nonceSpace[11..14] will be set per-nonce
                
                // For version >= 7 with merged mining (solution[5] > 0), clear non-canonical data
                if (solution_version >= 7 && full_block[143 + 5] > 0) {
                    // Clear header fields: hashPrevBlock, hashMerkleRoot, hashFinalSaplingRoot (96 bytes at offset 4)
                    memset(full_block + 4, 0, 96);
                    // Clear nBits (4 bytes at offset 104)
                    memset(full_block + 104, 0, 4);
                    // Clear nNonce (32 bytes at offset 108)
                    memset(full_block + 108, 0, 32);
                    // Clear hashPrevMMRRoot and hashBlockMMRRoot in solution (64 bytes starting at solution byte 8)
                    memset(full_block + 143 + 8, 0, 64);
                }
                
                // Compute intermediate state from full block (once per job)
                // This matches ccminer: VerusHashHalf(blockhash_half, full_data, 1487)
                hasher.hash_half(full_block, 1487, intermediate);
                
                // Prepare CLHash key from intermediate (once per job)
                // This matches ccminer: GenNewCLKey(blockhash_half, data_key)
                hasher.prepare_key(intermediate);
                
                // Debug: log job setup (only thread 0 to avoid flooding)
                // Debug logging removed for cleaner display
                
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
            
            // Set mining nonce in nonceSpace (bytes 11-14, little-endian)
            nonceSpace[11] = (nonce >> 0) & 0xFF;
            nonceSpace[12] = (nonce >> 8) & 0xFF;
            nonceSpace[13] = (nonce >> 16) & 0xFF;
            nonceSpace[14] = (nonce >> 24) & 0xFF;
            
            // Use two-stage hash with proper FillExtra rotation
            // This matches ccminer's Verus2hash exactly
            hasher.hash_with_nonce(intermediate, nonceSpace, hash);
            m_stats.hashes++;
            m_stats.thread_hashes[thread_id]++;
            
            // Debug sampling disabled for production
            // static thread_local uint64_t sample_count = 0;
            // if (++sample_count % 500000 == 0) {
            //     std::string hash_hex = utils::bytes_to_hex(hash, 32);
            //     LOG_INFO("[SAMPLE] hash_last4=%s (target=40000000)", hash_hex.substr(56, 8).c_str());
            // }
            
            // Check if hash meets target
            if (check_hash(hash, target)) {
                // Found a share!
                std::lock_guard<std::mutex> lock(m_job_mutex);
                
                // Verify job hasn't changed before submitting
                if (m_current_job.job_id == current_job_id) {
                    utils::Logger::instance().share_found(m_current_job.difficulty);
                    submit_share(m_current_job, nonce, current_solution);
                } else {
                    // Job changed, share is stale - don't submit
                    LOG_WARN("Discarding stale share for job %s (current: %s)", 
                             current_job_id.c_str(), m_current_job.job_id.c_str());
                }
            }
            
            nonce += nonce_step;
        }
        
        // Wrap nonce if needed
        if (nonce >= 0xFFFFFFFF - nonce_step) {
            nonce = thread_id;
        }
    }
    
    // Thread stopped silently
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

void Miner::submit_share(const stratum::Job& job, uint32_t nonce, const std::string& solution) {
    stratum::Share share;
    share.job_id = job.job_id;
    share.ntime = job.ntime;
    share.nonce = nonce;
    share.solution = solution;
    
    m_stats.shares_submitted++;
    m_stratum.submit_share(share);
}

bool Miner::check_hash(const uint8_t* hash, const uint8_t* target) {
    return utils::meets_target(hash, target);
}

std::string Miner::get_api_stats_json() {
    double hashrate = m_stats.get_hashrate();
    auto sys_stats = utils::SystemMonitor::instance().get_stats();
    
    auto now = std::chrono::steady_clock::now();
    double uptime = std::chrono::duration<double>(now - m_stats.start_time).count();
    
    // Calculate efficiency
    double efficiency = 0.0;
    if (sys_stats.cpu_power > 0) {
        efficiency = hashrate / 1000.0 / sys_stats.cpu_power;  // KH/W
    }
    
    // Build per-thread hashrates array
    std::stringstream hs_ss;
    hs_ss << "[";
    for (uint32_t i = 0; i < m_config.num_threads; i++) {
        if (i > 0) hs_ss << ",";
        hs_ss << std::fixed << std::setprecision(1) << (m_stats.get_thread_hashrate(i) / 1000.0);  // KH/s
    }
    hs_ss << "]";
    
    // Build JSON response
    std::stringstream json;
    json << "{"
         << "\"miner\":\"BloxMiner\","
         << "\"version\":\"" << VERSION << "\","
         << "\"algorithm\":\"verushash\","
         << "\"uptime\":" << std::fixed << std::setprecision(0) << uptime << ","
         << "\"hashrate\":{";
    json << "\"total\":" << std::fixed << std::setprecision(2) << (hashrate / 1000.0) << ",";  // KH/s
    json << "\"threads\":" << hs_ss.str() << ",";
    json << "\"unit\":\"KH/s\"},"
         << "\"shares\":{"
         << "\"accepted\":" << m_stats.shares_accepted.load() << ","
         << "\"rejected\":" << m_stats.shares_rejected.load() << ","
         << "\"submitted\":" << m_stats.shares_submitted.load() << "},"
         << "\"pool\":{";
    json << "\"host\":\"" << m_config.pool_host << "\","
         << "\"port\":" << m_config.pool_port << ","
         << "\"worker\":\"" << m_config.worker_name << "\","
         << "\"difficulty\":" << std::fixed << std::setprecision(6) << m_current_job.difficulty << "},"
         << "\"hardware\":{";
    json << "\"threads\":" << m_config.num_threads << ",";
    if (sys_stats.temp_available) {
        json << "\"temp\":" << std::fixed << std::setprecision(1) << sys_stats.cpu_temp << ",";
    }
    if (sys_stats.power_available) {
        json << "\"power\":" << std::fixed << std::setprecision(1) << sys_stats.cpu_power << ",";
        json << "\"efficiency\":" << std::fixed << std::setprecision(1) << efficiency << ",";
    }
    json << "\"efficiency_unit\":\"KH/W\"},"
         << "\"total_hashes\":" << m_stats.hashes.load()
         << "}";
    
    return json.str();
}

}  // namespace bloxminer
