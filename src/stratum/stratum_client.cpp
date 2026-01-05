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
{
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
    // Format for mining.submit: ["worker.name", "job_id", "extranonce2", "ntime", "nonce"]
    std::stringstream ss;
    ss << "{\"id\":" << m_message_id++
       << ",\"method\":\"mining.submit\""
       << ",\"params\":[\"" << m_username << "\""
       << ",\"" << share.job_id << "\""
       << ",\"" << share.extranonce2 << "\""
       << ",\"" << share.ntime << "\""
       << ",\"" << std::hex << std::setfill('0') << std::setw(8) << share.nonce << "\"]}\n";
    
    std::lock_guard<std::mutex> lock(m_send_mutex);
    send_message(ss.str());
}

bool StratumClient::send_message(const std::string& message) {
    if (!m_connected || m_socket < 0) return false;
    
    ssize_t sent = send(m_socket, message.c_str(), message.length(), 0);
    return sent == static_cast<ssize_t>(message.length());
}

std::string StratumClient::receive_line() {
    std::string line;
    char c;
    
    while (m_connected) {
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
        bool success = message.find("\"result\":true") != std::string::npos ||
                       message.find("\"result\": true") != std::string::npos ||
                       (message.find("\"result\":") != std::string::npos && 
                        message.find("\"error\":null") != std::string::npos);
        
        std::string error = extract_string(message, "error");
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
    // mining.notify format:
    // {"id":null,"method":"mining.notify","params":["job_id","prevhash","coinb1","coinb2",["merkle"],version","nbits","ntime",clean]}
    
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
    
    // Parse elements
    if (elements.size() < 8) {
        LOG_WARN("Invalid job notification - not enough elements");
        return;
    }
    
    // Remove quotes from strings
    auto unquote = [](const std::string& s) -> std::string {
        if (s.length() >= 2 && s.front() == '"' && s.back() == '"') {
            return s.substr(1, s.length() - 2);
        }
        return s;
    };
    
    job.job_id = unquote(elements[0]);
    job.prev_hash = unquote(elements[1]);
    job.coinbase1 = unquote(elements[2]);
    job.coinbase2 = unquote(elements[3]);
    
    // Merkle branches (element 4 is an array)
    std::string merkle_str = elements[4];
    if (merkle_str.front() == '[') {
        auto branches = extract_string_array(merkle_str, 0);
        job.merkle_branches = branches;
    }
    
    job.version = unquote(elements[5]);
    job.nbits = unquote(elements[6]);
    job.ntime = unquote(elements[7]);
    
    // Clean jobs flag
    if (elements.size() > 8) {
        job.clean_jobs = (elements[8] == "true" || elements[8] == "1");
    }
    
    // Set difficulty from current pool difficulty
    job.difficulty = m_difficulty;
    
    // Construct block header
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
    // Block header structure (80 bytes):
    // - version: 4 bytes
    // - prev_hash: 32 bytes
    // - merkle_root: 32 bytes
    // - timestamp: 4 bytes
    // - nbits: 4 bytes
    // - nonce: 4 bytes
    
    memset(job.header, 0, 80);
    
    // Version (little-endian)
    utils::hex_to_bytes(job.version, job.header, 4);
    
    // Previous hash (needs byte reversal for each 32-bit word)
    utils::hex_to_bytes(job.prev_hash, job.header + 4, 32);
    
    // Merkle root - computed from coinbase and merkle branches
    // First, build coinbase transaction
    std::string coinbase_hex = job.coinbase1 + m_extranonce1;
    
    // Add extranonce2 (we'll use zeros for now, miner will fill this)
    for (size_t i = 0; i < m_extranonce2_size; i++) {
        coinbase_hex += "00";
    }
    
    coinbase_hex += job.coinbase2;
    
    // Double SHA-256 of coinbase
    std::vector<uint8_t> coinbase = utils::hex_to_bytes(coinbase_hex);
    uint8_t hash1[32], merkle_root[32];
    
    SHA256(coinbase.data(), coinbase.size(), hash1);
    SHA256(hash1, 32, merkle_root);
    
    // Apply merkle branches
    for (const auto& branch : job.merkle_branches) {
        std::vector<uint8_t> branch_bytes = utils::hex_to_bytes(branch);
        uint8_t concat[64];
        memcpy(concat, merkle_root, 32);
        memcpy(concat + 32, branch_bytes.data(), 32);
        
        SHA256(concat, 64, hash1);
        SHA256(hash1, 32, merkle_root);
    }
    
    memcpy(job.header + 36, merkle_root, 32);
    
    // Timestamp
    utils::hex_to_bytes(job.ntime, job.header + 68, 4);
    
    // nBits
    utils::hex_to_bytes(job.nbits, job.header + 72, 4);
    
    // Nonce (starts at 0)
    memset(job.header + 76, 0, 4);
}

void StratumClient::calculate_target(Job& job) {
    utils::difficulty_to_target(job.difficulty, job.target);
}

}  // namespace stratum
}  // namespace bloxminer
