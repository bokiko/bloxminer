#pragma once

#include <string>
#include <vector>
#include <queue>
#include <mutex>
#include <atomic>
#include <functional>
#include <cstdint>
#include <thread>

namespace bloxminer {
namespace stratum {

/**
 * Mining job received from pool
 */
struct Job {
    std::string job_id;
    std::string prev_hash;      // Previous block hash
    std::string coinbase1;      // Coinbase prefix
    std::string coinbase2;      // Coinbase suffix
    std::vector<std::string> merkle_branches;
    std::string version;
    std::string nbits;          // Difficulty target
    std::string ntime;          // Block timestamp
    bool clean_jobs;            // If true, discard previous work
    
    // Parsed/computed fields
    uint8_t header[80];         // Constructed block header
    uint8_t target[32];         // Target hash for share validation
    double difficulty;          // Current difficulty
    
    bool valid() const { return !job_id.empty(); }
};

/**
 * Share to submit to pool
 */
struct Share {
    std::string job_id;
    std::string extranonce2;
    std::string ntime;
    uint32_t nonce;
};

/**
 * Stratum v1 protocol client for pool mining
 */
class StratumClient {
public:
    using JobCallback = std::function<void(const Job&)>;
    using ShareCallback = std::function<void(bool accepted, const std::string& reason)>;
    using ErrorCallback = std::function<void(const std::string& error)>;
    
    StratumClient();
    ~StratumClient();
    
    /**
     * Connect to mining pool
     * @param host Pool hostname
     * @param port Pool port
     * @return true if connected
     */
    bool connect(const std::string& host, uint16_t port);
    
    /**
     * Disconnect from pool
     */
    void disconnect();
    
    /**
     * Authorize with pool
     * @param username Wallet address or username
     * @param password Worker password (usually "x")
     * @return true if authorized
     */
    bool authorize(const std::string& username, const std::string& password);
    
    /**
     * Subscribe to mining notifications
     * @return true if subscribed
     */
    bool subscribe();
    
    /**
     * Submit a share to the pool
     * @param share Share to submit
     */
    void submit_share(const Share& share);
    
    /**
     * Set callback for new jobs
     */
    void on_job(JobCallback callback) { m_job_callback = std::move(callback); }
    
    /**
     * Set callback for share results
     */
    void on_share_result(ShareCallback callback) { m_share_callback = std::move(callback); }
    
    /**
     * Set callback for errors
     */
    void on_error(ErrorCallback callback) { m_error_callback = std::move(callback); }
    
    /**
     * Check if connected
     */
    bool is_connected() const { return m_connected; }
    
    /**
     * Get current extranonce1
     */
    const std::string& get_extranonce1() const { return m_extranonce1; }
    
    /**
     * Get extranonce2 size
     */
    size_t get_extranonce2_size() const { return m_extranonce2_size; }
    
    /**
     * Get current difficulty
     */
    double get_difficulty() const { return m_difficulty; }
    
    /**
     * Run the receive loop (blocks)
     */
    void run();
    
    /**
     * Stop the client
     */
    void stop();

private:
    // Socket
    int m_socket;
    std::atomic<bool> m_connected;
    std::atomic<bool> m_running;
    
    // Pool info
    std::string m_host;
    uint16_t m_port;
    std::string m_username;  // Stored for share submission
    
    // Stratum state
    std::string m_extranonce1;
    size_t m_extranonce2_size;
    std::atomic<double> m_difficulty;
    std::atomic<uint64_t> m_message_id;
    
    // Thread safety
    std::mutex m_send_mutex;
    std::mutex m_job_mutex;
    
    // Callbacks
    JobCallback m_job_callback;
    ShareCallback m_share_callback;
    ErrorCallback m_error_callback;
    
    // Internal methods
    bool send_message(const std::string& message);
    std::string receive_line();
    void process_message(const std::string& message);
    void handle_notification(const std::string& method, const std::string& params);
    void handle_response(uint64_t id, bool success, const std::string& result, const std::string& error);
    void parse_job(const std::string& params);
    void construct_header(Job& job);
    void calculate_target(Job& job);
};

}  // namespace stratum
}  // namespace bloxminer
