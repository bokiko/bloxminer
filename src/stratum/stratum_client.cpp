#include "../../include/stratum/stratum_client.hpp"
#include "../../include/utils/hex_utils.hpp"
#include "../../include/utils/logger.hpp"

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>

#include <cstring>
#include <sstream>
#include <algorithm>
#include <cmath>
#include <openssl/sha.h>

// Simple JSON parsing helpers (avoiding external dependency)
namespace {

std::string extract_string(const std::string& json, const std::string& key) {
    std::string search = "\"" + key + "\"";
    size_t pos = json.find(search);
    if (pos == std::string::npos) return "";
    
    pos = json.find(':', pos);
    if (pos == std::string::npos) return "";
    
    pos = json.find('"', pos);
    if (pos == std::string::npos) return "";
    
    size_t end = json.find('"', pos + 1);
    if (end == std::string::npos) return "";
    
    return json.substr(pos + 1, end - pos - 1);
}

int64_t extract_int(const std::string& json, const std::string& key) {
    std::string search = "\"" + key + "\"";
    size_t pos = json.find(search);
    if (pos == std::string::npos) return 0;
    
    pos = json.find(':', pos);
    if (pos == std::string::npos) return 0;
    
    pos++;
    while (pos < json.length() && (json[pos] == ' ' || json[pos] == '\t')) pos++;
    
    std::string num;
    while (pos < json.length() && (isdigit(json[pos]) || json[pos] == '-')) {
        num += json[pos++];
    }
    
    return num.empty() ? 0 : std::stoll(num);
}

double extract_double(const std::string& json, const std::string& key) {
    std::string search = "\"" + key + "\"";
    size_t pos = json.find(search);
    if (pos == std::string::npos) return 0.0;
    
    pos = json.find(':', pos);
    if (pos == std::string::npos) return 0.0;
    
    pos++;
    while (pos < json.length() && (json[pos] == ' ' || json[pos] == '\t')) pos++;
    
    std::string num;
    while (pos < json.length() && (isdigit(json[pos]) || json[pos] == '.' || json[pos] == '-' || json[pos] == 'e' || json[pos] == 'E' || json[pos] == '+')) {
        num += json[pos++];
    }
    
    return num.empty() ? 0.0 : std::stod(num);
}

bool extract_bool(const std::string& json, const std::string& key) {
    std::string search = "\"" + key + "\"";
    size_t pos = json.find(search);
    if (pos == std::string::npos) return false;
    
    pos = json.find(':', pos);
    if (pos == std::string::npos) return false;
    
    return json.find("true", pos) < json.find(',', pos);
}

std::vector<std::string> extract_string_array(const std::string& json, size_t start_pos) {
    std::vector<std::string> result;
    
    size_t pos = json.find('[', start_pos);
    if (pos == std::string::npos) return result;
    
    size_t end = json.find(']', pos);
    if (end == std::string::npos) return result;
    
    std::string arr = json.substr(pos + 1, end - pos - 1);
    
    size_t p = 0;
    while ((p = arr.find('"', p)) != std::string::npos) {
        size_t e = arr.find('"', p + 1);
        if (e == std::string::npos) break;
        result.push_back(arr.substr(p + 1, e - p - 1));
        p = e + 1;
    }
    
    return result;
}

}  // namespace

namespace bloxminer {
namespace stratum {

StratumClient::StratumClient()
    : m_socket(-1)
    , m_connected(false)
    , m_running(false)
    , m_port(0)
    , m_extranonce2_size(4)
    , m_difficulty(1.0)
    , m_message_id(1)
    , m_has_pool_target(false)
{
    memset(m_pool_target, 0, 32);
}

StratumClient::~StratumClient() {
    disconnect();
}

bool StratumClient::connect(const std::string& host, uint16_t port) {
    m_host = host;
    m_port = port;
    
    // Resolve hostname
    struct addrinfo hints{}, *result;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    
    std::string port_str = std::to_string(port);
    if (getaddrinfo(host.c_str(), port_str.c_str(), &hints, &result) != 0) {
        LOG_ERROR("Failed to resolve hostname: %s", host.c_str());
        return false;
    }
    
    // Create socket
    m_socket = socket(result->ai_family, result->ai_socktype, result->ai_protocol);
    if (m_socket < 0) {
        LOG_ERROR("Failed to create socket");
        freeaddrinfo(result);
        return false;
    }
    
    // Set TCP_NODELAY for lower latency
    int flag = 1;
    setsockopt(m_socket, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
    
    // Connect
    if (::connect(m_socket, result->ai_addr, result->ai_addrlen) < 0) {
        LOG_ERROR("Failed to connect to %s:%d", host.c_str(), port);
        close(m_socket);
        m_socket = -1;
        freeaddrinfo(result);
        return false;
    }
    
    freeaddrinfo(result);
    m_connected = true;
    
    utils::Logger::instance().connected(host, port);
    return true;
}

void StratumClient::disconnect() {
    m_running = false;
    m_connected = false;
    
    if (m_socket >= 0) {
        shutdown(m_socket, SHUT_RDWR);
        close(m_socket);
        m_socket = -1;
    }
}

bool StratumClient::subscribe() {
    std::stringstream ss;
    ss << "{\"id\":" << m_message_id++ 
       << ",\"method\":\"mining.subscribe\""
       << ",\"params\":[\"BloxMiner/1.0.0\"]}\n";
    
    if (!send_message(ss.str())) {
        return false;
    }
    
    // Wait for response
    std::string response = receive_line();
    if (response.empty()) {
        LOG_ERROR("No response to subscribe");
        return false;
    }
    
    // Parse subscription response
    // Format: {"id":1,"result":[[["mining.set_difficulty","..."],["mining.notify","..."]],"extranonce1","extranonce2_size"],"error":null}
    
    // Extract extranonce1
    size_t pos = response.find("\"result\"");
    if (pos != std::string::npos) {
        // Find the extranonce1 (usually after the subscription arrays)
        auto parts = extract_string_array(response, pos);
        if (parts.size() >= 2) {
            // The extranonce is usually the last string before a number
            for (size_t i = 0; i < parts.size(); i++) {
                if (parts[i].length() == 8 || parts[i].length() == 16) {  // extranonce1 is typically 4-8 bytes hex
                    m_extranonce1 = parts[i];
                }
            }
        }
        
        // Extract extranonce2_size
        m_extranonce2_size = extract_int(response, "extranonce2_size");
        if (m_extranonce2_size == 0) {
            // Try to find it differently - usually 4
            m_extranonce2_size = 4;
        }
        
        // Fallback: manual parsing
        if (m_extranonce1.empty()) {
            size_t arr_end = response.rfind(']');
            if (arr_end != std::string::npos) {
                size_t quote_end = response.rfind('"', arr_end);
                size_t quote_start = response.rfind('"', quote_end - 1);
                if (quote_start != std::string::npos && quote_end != std::string::npos) {
                    std::string candidate = response.substr(quote_start + 1, quote_end - quote_start - 1);
                    if (candidate.length() >= 4 && candidate.length() <= 16) {
                        m_extranonce1 = candidate;
                    }
                }
            }
        }
    }
    
    LOG_INFO("Subscribed - extranonce1: %s, extranonce2_size: %d", 
             m_extranonce1.c_str(), (int)m_extranonce2_size);
    
    return true;
}

bool StratumClient::authorize(const std::string& username, const std::string& password) {
    uint64_t auth_id = m_message_id++;
    
    std::stringstream ss;
    ss << "{\"id\":" << auth_id
       << ",\"method\":\"mining.authorize\""
       << ",\"params\":[\"" << username << "\",\"" << password << "\"]}\n";
    
    if (!send_message(ss.str())) {
        return false;
    }
    
    // Wait for response - may receive notifications before auth response
    for (int attempts = 0; attempts < 10; attempts++) {
        std::string response = receive_line();
        if (response.empty()) {
            LOG_ERROR("No response to authorize");
            return false;
        }
        
        // Check if this is a notification (has "method" field)
        if (response.find("\"method\"") != std::string::npos) {
            // It's a notification - process it and continue waiting
            process_message(response);
            continue;
        }
        
        // Check for auth success
        if (response.find("\"result\":true") != std::string::npos ||
            response.find("\"result\": true") != std::string::npos) {
            m_username = username;  // Store for share submission
            LOG_INFO("Authorized as %s", username.c_str());
            return true;
        }
        
        // Check if this response has an error
        if (response.find("\"error\":null") != std::string::npos ||
            response.find("\"error\": null") != std::string::npos) {
            // No error means success (result could be various formats)
            m_username = username;  // Store for share submission
            LOG_INFO("Authorized as %s", username.c_str());
            return true;
        }
        
        // Check for explicit error
        if (response.find("\"error\":[") != std::string::npos ||
            response.find("\"error\": [") != std::string::npos) {
            LOG_ERROR("Authorization failed: %s", response.c_str());
            return false;
        }
    }
    
    LOG_ERROR("Authorization timed out");
    return false;
}

void StratumClient::submit_share(const Share& share) {
    // Verus stratum submit format (from ccminer-verus):
    // ["user", "jobid", "timehex", "noncestr", "solhex"]
    //
    // The full solution must be 1347 bytes (2694 hex chars):
    // - 3 bytes prefix (fd4005 = varint for 1344)
    // - 1344 bytes solution body
    //
    // CRITICAL: The 15-byte nonce must be embedded at offset 1332 in the solution body!
    // This is how the pool identifies which extranonce1 (pool nonce) was used.
    //
    // nonceSpace structure (15 bytes):
    // - bytes 0-3: extranonce1 (pool nonce, 4 bytes)
    // - bytes 4-7: extranonce2 (zeros, 4 bytes)  
    // - bytes 8-10: padding (3 bytes of zeros)
    // - bytes 11-14: mining nonce (4 bytes, little-endian)
    
    // Build the 15-byte nonceSpace that goes into the solution
    // Layout must match what the miner uses for hashing (from ccminer):
    // - bytes 0-6: header[108:114] = extranonce1 (4 bytes) + first 3 bytes of extranonce2
    // - bytes 7-10: header[128:131] = bytes 20-23 of nNonce (padding, zeros)
    // - bytes 11-14: mining nonce (4 bytes, little-endian)
    uint8_t nonceSpace[15] = {0};
    
    size_t xnonce1_bytes = m_extranonce1.length() / 2;
    
    // Copy extranonce1 at bytes 0-3
    utils::hex_to_bytes(m_extranonce1, nonceSpace, xnonce1_bytes);
    // bytes 4-6: first 3 bytes of extranonce2 (zeros) - already zeroed
    // bytes 7-10: from header[128:131] which is zeros in merged mining - already zeroed
    
    // Mining nonce at bytes 11-14 (little-endian)
    nonceSpace[11] = (share.nonce >> 0) & 0xFF;
    nonceSpace[12] = (share.nonce >> 8) & 0xFF;
    nonceSpace[13] = (share.nonce >> 16) & 0xFF;
    nonceSpace[14] = (share.nonce >> 24) & 0xFF;
    
    // Build the full 32-byte nNonce field for noncestr submission
    // In ccminer, the mining nonce is stored at word 30 (byte offset 120 in header)
    // which is byte offset 12 within the 32-byte nNonce field (108 + 12 = 120)
    // 
    // nNonce layout (32 bytes):
    // - bytes 0-3: extranonce1 (pool prefix)
    // - bytes 4-11: extranonce2 + padding (8 bytes of zeros for merged mining)
    // - bytes 12-15: mining nonce
    // - bytes 16-31: more padding (zeros)
    
    // Build full 32-byte nNonce
    uint8_t full_nonce[32] = {0};
    
    // Copy extranonce1 at bytes 0-3
    utils::hex_to_bytes(m_extranonce1, full_nonce, xnonce1_bytes);
    
    // bytes 4-11: zeros (extranonce2 + padding) - already zeroed
    
    // Mining nonce at bytes 12-15 (little-endian)
    full_nonce[12] = (share.nonce >> 0) & 0xFF;
    full_nonce[13] = (share.nonce >> 8) & 0xFF;
    full_nonce[14] = (share.nonce >> 16) & 0xFF;
    full_nonce[15] = (share.nonce >> 24) & 0xFF;
    
    // bytes 16-31: zeros - already zeroed
    
    // noncestr = nNonce bytes after extranonce1 (bytes 4-31 = 28 bytes)
    std::string noncestr = utils::bytes_to_hex(full_nonce + xnonce1_bytes, 32 - xnonce1_bytes);
    
    // Build full solution (1347 bytes = 2694 hex chars)
    // Format: fd4005 (3 bytes prefix) + solution_body (1344 bytes)
    
    std::string full_solution = "fd4005";  // Prefix: compact size for 1344 bytes
    
    // Start with pool's solution template
    std::string sol_body = share.solution;
    
    // Pad solution body to 2688 hex chars (1344 bytes)
    while (sol_body.length() < 2688) {
        sol_body += "00";
    }
    sol_body = sol_body.substr(0, 2688);  // Ensure exactly 2688 hex chars
    
    // CRITICAL: Embed nonceSpace at byte offset 1332 in the solution body
    // Offset 1332 in hex = 1332 * 2 = 2664 chars from solution body start
    std::string nonceSpace_hex = utils::bytes_to_hex(nonceSpace, 15);
    
    // Replace bytes at offset 1332 (hex offset 2664) with the 15-byte nonceSpace
    // Note: solution body is 1344 bytes, so offset 1332 + 15 = 1347, but we only
    // have 1344 bytes (ending at offset 1343). The nonce space is 1332-1343 (12 bytes)
    // Actually looking at ccminer: offset 1332 with 15 bytes would go beyond 1344
    // Let me recalculate: 1332 + 15 = 1347 > 1344
    // So the 15 bytes span: solution body bytes 1332-1343 (12 bytes in body) 
    // The extra 3 bytes might be beyond? No - let's check again.
    //
    // Looking at ccminer more carefully:
    // - work->extra is 1347 bytes total (3 prefix + 1344 body)
    // - memcpy(work->extra + 1332, nonceSpace, 15) copies at offset 1332 from start of extra
    // - So that's offset 1332 - 3 = 1329 in the solution body
    //
    // Wait, extra starts at sol_data = &full_data[140], and sol_data includes the fd4005 prefix
    // So work->extra[0..2] = fd4005, work->extra[3..1346] = solution body
    // work->extra + 1332 means starting at byte 1332 of the 1347-byte buffer
    // That's byte 1332 - 3 = 1329 in the solution body... 
    // No wait, 1332 is the absolute offset in the extra buffer, which is 1347 bytes.
    // So bytes 1332-1346 (15 bytes) in the extra buffer.
    // Since prefix is 3 bytes, that's bytes 1329-1343 in the solution body (1344 bytes total)
    // 
    // In hex: offset 1329 in body = 1329 * 2 = 2658 hex chars from body start
    // After fd4005 prefix: offset (3 + 1329) * 2 = 2664 in full_solution string... 
    // No wait, full_solution starts with "fd4005" (6 chars), then body
    // So byte 1332 in the binary = hex position 6 + (1332-3)*2 = 6 + 2658 = 2664
    // Actually let me think simpler:
    // Binary: [fd4005 (3 bytes)][solution body (1344 bytes)]
    // Index 1332 in binary = index 1332 * 2 = 2664 in hex string
    // Our nonceSpace is 15 bytes = 30 hex chars
    // So replace hex chars 2664..2693 with nonceSpace_hex
    
    if (sol_body.length() >= 2664 + 30 - 6) {  // -6 because we haven't added prefix yet
        // Actually, let's work with the full solution after prefix
        // full_solution = "fd4005" + sol_body
        // Binary offset 1332 = hex offset 2664
        // We need to replace starting at hex position 2664
    }
    
    full_solution += sol_body;  // Total: 6 + 2688 = 2694 hex chars
    
    // Now embed nonce at binary offset 1332 (hex offset 2664)
    // Replace 30 hex chars (15 bytes) starting at position 2664
    if (full_solution.length() >= 2664 + 30) {
        full_solution.replace(2664, 30, nonceSpace_hex);
    }
    
    uint64_t submit_id = m_message_id++;
    
    // ccminer format: user, jobid, timehex, noncestr, solhex
    std::stringstream ss;
    ss << "{\"method\":\"mining.submit\",\"params\":["
       << "\"" << m_username << "\""
       << ",\"" << share.job_id << "\""
       << ",\"" << share.ntime << "\""
       << ",\"" << noncestr << "\""
       << ",\"" << full_solution << "\"]"
       << ",\"id\":" << submit_id << "}\n";
    
    std::string msg = ss.str();
    
    std::lock_guard<std::mutex> lock(m_send_mutex);
    send_message(msg);
}

bool StratumClient::send_message(const std::string& message) {
    if (!m_connected || m_socket < 0) return false;
    
    ssize_t sent = send(m_socket, message.c_str(), message.length(), 0);
    return sent == static_cast<ssize_t>(message.length());
}

std::string StratumClient::receive_line() {
    std::string line;
    char c;
    const size_t MAX_LINE_LENGTH = 65536;  // 64KB limit to prevent memory exhaustion

    while (m_connected && line.length() < MAX_LINE_LENGTH) {
        ssize_t n = recv(m_socket, &c, 1, 0);
        if (n <= 0) {
            m_connected = false;
            return "";
        }

        if (c == '\n') {
            return line;
        }

        line += c;
    }

    if (line.length() >= MAX_LINE_LENGTH) {
        utils::Logger::instance().error("Stratum line exceeded 64KB limit, disconnecting");
        m_connected = false;
    }

    return line;
}

void StratumClient::run() {
    m_running = true;
    
    while (m_running && m_connected) {
        std::string line = receive_line();
        if (line.empty()) {
            if (m_connected) {
                utils::Logger::instance().disconnected("Connection lost");
                m_connected = false;
            }
            break;
        }
        
        process_message(line);
    }
}

void StratumClient::stop() {
    m_running = false;
}

void StratumClient::process_message(const std::string& message) {
    // Check if it's a notification (has "method" but no "id" or id is null)
    std::string method = extract_string(message, "method");
    
    if (!method.empty()) {
        // It's a notification
        handle_notification(method, message);
    } else {
        // It's a response to our request
        int64_t id = extract_int(message, "id");
        
        // Check for success - result can be true, or any non-null value with null error
        bool has_result_true = message.find("\"result\":true") != std::string::npos ||
                               message.find("\"result\": true") != std::string::npos;
        bool has_null_error = message.find("\"error\":null") != std::string::npos ||
                              message.find("\"error\": null") != std::string::npos;
        bool has_error_array = message.find("\"error\":[") != std::string::npos ||
                               message.find("\"error\": [") != std::string::npos;
        
        bool success = has_result_true || (has_null_error && !has_error_array);

        // Extract error message if present
        std::string error;
        if (has_error_array) {
            // Error format: "error":[code, "message", null]
            size_t err_pos = message.find("\"error\"");
            if (err_pos != std::string::npos) {
                size_t start = message.find('"', message.find('[', err_pos) + 1);
                size_t end = message.find('"', start + 1);
                if (start != std::string::npos && end != std::string::npos) {
                    error = message.substr(start + 1, end - start - 1);
                }
            }
        }

        handle_response(id, success, "", error);
    }
}

void StratumClient::handle_notification(const std::string& method, const std::string& params) {
    if (method == "mining.notify") {
        parse_job(params);
    } else if (method == "mining.set_difficulty") {
        double diff = extract_double(params, "params");
        if (diff <= 0) {
            // Try to parse array format: {"method":"mining.set_difficulty","params":[1.0]}
            size_t pos = params.find("\"params\"");
            if (pos != std::string::npos) {
                pos = params.find('[', pos);
                if (pos != std::string::npos) {
                    pos++;
                    std::string num;
                    while (pos < params.length() && (isdigit(params[pos]) || params[pos] == '.')) {
                        num += params[pos++];
                    }
                    if (!num.empty()) {
                        diff = std::stod(num);
                    }
                }
            }
        }
        
        if (diff > 0) {
            m_difficulty = diff;
            LOG_INFO("Difficulty set to %f", diff);
        }
    } else if (method == "mining.set_target") {
        // Pool sends target directly (Verus pools often use this)
        // Format: {"method":"mining.set_target","params":["target_hex"]}
        // Target is sent as big-endian hex, but VerusHash outputs little-endian
        // We must reverse the target for proper comparison
        size_t pos = params.find("\"params\"");
        if (pos != std::string::npos) {
            pos = params.find('[', pos);
            if (pos != std::string::npos) {
                pos = params.find('"', pos);
                if (pos != std::string::npos) {
                    size_t end = params.find('"', pos + 1);
                    if (end != std::string::npos) {
                        std::string target_hex = params.substr(pos + 1, end - pos - 1);
                        if (target_hex.length() == 64) {
                            // Parse target as big-endian
                            uint8_t target_be[32];
                            utils::hex_to_bytes(target_hex, target_be, 32);
                            
                            // Reverse to little-endian for comparison with hash
                            // Pool sends: 0000004000... (big-endian)
                            // Hash is little-endian: most significant bytes at [31]
                            // So target[31] should have 0x00, target[28] should have 0x40
                            for (int i = 0; i < 32; i++) {
                                m_pool_target[31 - i] = target_be[i];
                            }
                            m_has_pool_target = true;
                            
                            // Calculate approximate difficulty for logging
                            // diff = 0xFFFF * 2^208 / target (using big-endian target_be)
                            double target_val = 0;
                            for (int i = 0; i < 32; i++) {
                                target_val = target_val * 256.0 + target_be[i];
                            }
                            double diff = (0xFFFF * pow(2.0, 208)) / target_val;
                            m_difficulty = diff;
                            
                            LOG_INFO("Target set: %s (diff ~%f)", target_hex.substr(0, 16).c_str(), diff);
                        }
                    }
                }
            }
        }
    } else if (method == "mining.set_extranonce") {
        // Some pools send this
        m_extranonce1 = extract_string(params, "extranonce1");
        m_extranonce2_size = extract_int(params, "extranonce2_size");
        LOG_INFO("Extranonce updated: %s", m_extranonce1.c_str());
    }
}

void StratumClient::handle_response(uint64_t id, bool success, const std::string& result, const std::string& error) {
    (void)result;  // Unused for now
    
    // This is likely a share response
    if (m_share_callback) {
        m_share_callback(success, error);
    }
    
    if (!success && !error.empty()) {
        LOG_WARN("Request %lu failed: %s", id, error.c_str());
    }
}

void StratumClient::parse_job(const std::string& params) {
    // Verus mining.notify format:
    // {"id":null,"method":"mining.notify","params":[
    //   "job_id",           [0]
    //   "version",          [1] - block version (e.g., "04000100")
    //   "hashPrevBlock",    [2] - 64 hex chars
    //   "hashMerkleRoot",   [3] - 64 hex chars
    //   "hashFinalSapling", [4] - 64 hex chars (Zcash heritage)
    //   "nTime",            [5] - 8 hex chars
    //   "nBits",            [6] - 8 hex chars
    //   clean_jobs,         [7] - boolean
    //   "solution"          [8] - solution template (variable length hex)
    // ]}
    
    Job job;
    
    // Extract params array
    size_t pos = params.find("\"params\"");
    if (pos == std::string::npos) return;
    
    pos = params.find('[', pos);
    if (pos == std::string::npos) return;
    
    // Parse the array elements
    std::vector<std::string> elements;
    size_t depth = 0;
    std::string current;
    bool in_string = false;
    
    for (size_t i = pos; i < params.length(); i++) {
        char c = params[i];
        
        if (c == '"' && (i == 0 || params[i-1] != '\\')) {
            in_string = !in_string;
            current += c;
        } else if (!in_string) {
            if (c == '[') {
                depth++;
                if (depth > 1) current += c;
            } else if (c == ']') {
                depth--;
                if (depth == 0) {
                    if (!current.empty() && current != ",") {
                        elements.push_back(current);
                    }
                    break;
                } else {
                    current += c;
                }
            } else if (c == ',' && depth == 1) {
                if (!current.empty()) {
                    elements.push_back(current);
                }
                current.clear();
            } else if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
                current += c;
            }
        } else {
            current += c;
        }
    }
    
    // Parse elements - need at least 8 for Verus format
    if (elements.size() < 8) {
        LOG_WARN("Invalid job notification - not enough elements (%zu)", elements.size());
        return;
    }
    
    // Remove quotes from strings
    auto unquote = [](const std::string& s) -> std::string {
        if (s.length() >= 2 && s.front() == '"' && s.back() == '"') {
            return s.substr(1, s.length() - 2);
        }
        return s;
    };
    
    // Verus stratum format
    job.job_id = unquote(elements[0]);
    job.version = unquote(elements[1]);
    job.prev_hash = unquote(elements[2]);
    job.coinbase1 = unquote(elements[3]);  // Actually hashMerkleRoot for Verus
    job.final_sapling_root = unquote(elements[4]);
    job.ntime = unquote(elements[5]);
    job.nbits = unquote(elements[6]);
    
    // Clean jobs flag (element 7)
    job.clean_jobs = (elements[7] == "true" || elements[7] == "1");
    
    // Solution template (element 8)
    if (elements.size() > 8) {
        std::string raw_sol = elements[8];
        job.solution = unquote(raw_sol);
    }
    
    // Set difficulty from current pool difficulty
    job.difficulty = m_difficulty;
    
    // Construct block header for Verus
    construct_header(job);
    
    // Calculate target
    calculate_target(job);
    
    // Notify callback
    if (m_job_callback) {
        utils::Logger::instance().new_job(job.job_id, job.difficulty);
        m_job_callback(job);
    }
}

void StratumClient::construct_header(Job& job) {
    // Verus block header is 140 bytes:
    // - version: 4 bytes
    // - hashPrevBlock: 32 bytes
    // - hashMerkleRoot: 32 bytes
    // - hashFinalSaplingRoot: 32 bytes
    // - nTime: 4 bytes
    // - nBits: 4 bytes
    // - nNonce: 32 bytes (but only first 4 bytes used for mining nonce)
    //
    // Total: 4 + 32 + 32 + 32 + 4 + 4 + 32 = 140 bytes
    
    memset(job.header, 0, sizeof(job.header));
    
    // Version (4 bytes) - offset 0
    utils::hex_to_bytes(job.version, job.header, 4);
    
    // Previous block hash (32 bytes) - offset 4
    utils::hex_to_bytes(job.prev_hash, job.header + 4, 32);
    
    // Merkle root (32 bytes) - offset 36
    // In Verus stratum, this is the coinbase1 field
    utils::hex_to_bytes(job.coinbase1, job.header + 36, 32);
    
    // hashFinalSaplingRoot (32 bytes) - offset 68
    utils::hex_to_bytes(job.final_sapling_root, job.header + 68, 32);
    
    // nTime (4 bytes) - offset 100
    utils::hex_to_bytes(job.ntime, job.header + 100, 4);
    
    // nBits (4 bytes) - offset 104
    utils::hex_to_bytes(job.nbits, job.header + 104, 4);
    
    // nNonce (32 bytes) - offset 108
    // The first 4 bytes are the pool's extranonce1
    // The next 4 bytes are extranonce2 (zeros)
    // The next 4 bytes will be our mining nonce
    // Rest is padding (zeros)
    utils::hex_to_bytes(m_extranonce1, job.header + 108, m_extranonce1.length() / 2);
    // extranonce2 and padding are already zero from memset
    
    job.header_len = 140;  // Full Verus header
}

void StratumClient::calculate_target(Job& job) {
    // Use pool-provided target if available (from mining.set_target)
    if (m_has_pool_target) {
        memcpy(job.target, m_pool_target, 32);
    } else {
        // Fallback: calculate from difficulty
        utils::difficulty_to_target(job.difficulty, job.target);
    }
}

}  // namespace stratum
}  // namespace bloxminer
