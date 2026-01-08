#pragma once

#include <string>
#include <thread>
#include <atomic>
#include <functional>
#include <sstream>
#include <cstring>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

namespace bloxminer {
namespace utils {

/**
 * Simple HTTP API server for miner stats
 * Provides JSON endpoint at /api/stats
 */
class ApiServer {
public:
    using StatsCallback = std::function<std::string()>;
    
    ApiServer() = default;
    ~ApiServer() { stop(); }
    
    /**
     * Start the API server
     * @param port Port to listen on (default 4068)
     * @param stats_callback Function that returns JSON stats string
     * @return true if started successfully
     */
    bool start(uint16_t port, StatsCallback stats_callback) {
        if (m_running) return true;
        
        m_port = port;
        m_stats_callback = stats_callback;
        
        // Create socket
        m_socket = socket(AF_INET, SOCK_STREAM, 0);
        if (m_socket < 0) {
            return false;
        }
        
        // Allow address reuse
        int opt = 1;
        setsockopt(m_socket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        
        // Bind
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port = htons(port);
        
        if (bind(m_socket, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
            close(m_socket);
            m_socket = -1;
            return false;
        }
        
        // Listen
        if (listen(m_socket, 5) < 0) {
            close(m_socket);
            m_socket = -1;
            return false;
        }
        
        m_running = true;
        m_thread = std::thread(&ApiServer::server_thread, this);
        
        return true;
    }
    
    void stop() {
        if (!m_running) return;
        
        m_running = false;
        
        // Close socket to unblock accept()
        if (m_socket >= 0) {
            shutdown(m_socket, SHUT_RDWR);
            close(m_socket);
            m_socket = -1;
        }
        
        if (m_thread.joinable()) {
            m_thread.join();
        }
    }
    
    uint16_t port() const { return m_port; }
    bool is_running() const { return m_running; }
    
private:
    void server_thread() {
        while (m_running) {
            struct sockaddr_in client_addr;
            socklen_t client_len = sizeof(client_addr);
            
            int client = accept(m_socket, (struct sockaddr*)&client_addr, &client_len);
            if (client < 0) {
                if (m_running) {
                    // Error, but keep trying
                    continue;
                }
                break;  // Shutdown
            }
            
            handle_client(client);
            close(client);
        }
    }
    
    void handle_client(int client) {
        char buffer[4096];
        ssize_t n = recv(client, buffer, sizeof(buffer) - 1, 0);
        if (n <= 0) return;
        
        buffer[n] = '\0';
        
        // Parse request (very simple)
        std::string request(buffer);
        
        std::string response;
        std::string content_type = "application/json";
        
        if (request.find("GET /api/stats") != std::string::npos ||
            request.find("GET /summary") != std::string::npos ||
            request.find("GET / ") != std::string::npos) {
            // Return stats JSON
            response = m_stats_callback ? m_stats_callback() : "{}";
        } else if (request.find("GET /health") != std::string::npos) {
            response = R"({"status":"ok"})";
        } else {
            // 404
            std::string body = R"({"error":"not found","endpoints":["/api/stats","/health"]})";
            std::stringstream ss;
            ss << "HTTP/1.1 404 Not Found\r\n"
               << "Content-Type: application/json\r\n"
               << "Content-Length: " << body.length() << "\r\n"
               << "Connection: close\r\n"
               << "Access-Control-Allow-Origin: *\r\n"
               << "\r\n"
               << body;
            std::string http_response = ss.str();
            send(client, http_response.c_str(), http_response.length(), 0);
            return;
        }
        
        // Build HTTP response
        std::stringstream ss;
        ss << "HTTP/1.1 200 OK\r\n"
           << "Content-Type: " << content_type << "\r\n"
           << "Content-Length: " << response.length() << "\r\n"
           << "Connection: close\r\n"
           << "Access-Control-Allow-Origin: *\r\n"
           << "\r\n"
           << response;
        
        std::string http_response = ss.str();
        send(client, http_response.c_str(), http_response.length(), 0);
    }
    
    std::atomic<bool> m_running{false};
    std::thread m_thread;
    int m_socket = -1;
    uint16_t m_port = 0;
    StatsCallback m_stats_callback;
};

}  // namespace utils
}  // namespace bloxminer
