#pragma once

#include <string>
#include <vector>
#include <iostream>
#include <iomanip>
#include <sstream>
#include <chrono>
#include <mutex>
#include <cstdio>

namespace bloxminer {
namespace utils {

/**
 * Terminal display manager with sticky header (htop-style)
 */
class Display {
public:
    static Display& instance() {
        static Display display;
        return display;
    }
    
    struct Stats {
        double total_hashrate = 0;
        std::vector<double> thread_hashrates;
        uint64_t accepted = 0;
        uint64_t rejected = 0;
        double cpu_temp = 0;
        double cpu_power = 0;
        std::string pool;
        std::string worker;
        double difficulty = 0;
        double uptime_seconds = 0;
    };
    
    void set_header_lines(int lines) { m_header_lines = lines; }
    
    // Update and redraw the sticky header
    void update_header(const Stats& stats) {
        std::lock_guard<std::mutex> lock(m_mutex);
        
        // Save cursor position, move to top, clear header area
        std::cout << "\033[s";  // Save cursor
        std::cout << "\033[H";  // Move to top
        
        // Draw header box
        draw_header(stats);
        
        // Restore cursor position
        std::cout << "\033[u";  // Restore cursor
        std::cout << std::flush;
    }
    
    // Print a log line (below the header)
    void log(const std::string& message) {
        std::lock_guard<std::mutex> lock(m_mutex);
        std::cout << message << std::endl;
    }
    
    // Initialize terminal for header display
    void init(int num_threads) {
        m_num_threads = num_threads;
        m_header_lines = 7 + (num_threads > 8 ? 2 : 1);  // Adjust based on thread count
        
        // Clear screen and set scroll region below header
        std::cout << "\033[2J";  // Clear screen
        std::cout << "\033[H";   // Move to top
        
        // Print empty lines for header
        for (int i = 0; i < m_header_lines; i++) {
            std::cout << std::endl;
        }
        
        // Set scroll region (below header)
        std::cout << "\033[" << (m_header_lines + 1) << ";999r";
        
        // Move cursor to start of scroll region
        std::cout << "\033[" << (m_header_lines + 1) << ";1H";
        std::cout << std::flush;
    }
    
    // Reset terminal on exit
    void cleanup() {
        // Reset scroll region
        std::cout << "\033[r";
        std::cout << std::flush;
    }

private:
    Display() = default;
    
    void draw_header(const Stats& stats) {
        const char* CYAN = "\033[36m";
        const char* GREEN = "\033[32m";
        const char* YELLOW = "\033[33m";
        const char* MAGENTA = "\033[35m";
        const char* WHITE = "\033[97m";
        const char* DIM = "\033[90m";
        const char* BOLD = "\033[1m";
        const char* RESET = "\033[0m";
        
        int width = 80;  // Terminal width (could be dynamic)
        
        // Format uptime
        int hours = static_cast<int>(stats.uptime_seconds) / 3600;
        int mins = (static_cast<int>(stats.uptime_seconds) % 3600) / 60;
        int secs = static_cast<int>(stats.uptime_seconds) % 60;
        
        // Format total hashrate
        std::string hr_str = format_hashrate(stats.total_hashrate);
        
        // Clear header area
        for (int i = 0; i < m_header_lines; i++) {
            std::cout << "\033[K" << std::endl;  // Clear line
        }
        std::cout << "\033[H";  // Back to top
        
        // Line 1: Title bar
        std::cout << BOLD << CYAN << " BloxMiner v1.0.0 " << RESET
                  << DIM << "| " << RESET
                  << "Pool: " << WHITE << stats.pool << RESET
                  << DIM << " | " << RESET
                  << "Worker: " << WHITE << stats.worker << RESET
                  << "\033[K" << std::endl;
        
        // Line 2: Separator
        std::cout << DIM;
        for (int i = 0; i < width; i++) std::cout << "─";
        std::cout << RESET << std::endl;
        
        // Line 3: Main stats
        std::cout << " " << BOLD << GREEN << "Hashrate: " << hr_str << RESET;
        
        if (stats.cpu_temp > 0) {
            std::cout << DIM << " │ " << RESET;
            std::cout << YELLOW << "Temp: " << std::fixed << std::setprecision(0) 
                      << stats.cpu_temp << "°C" << RESET;
        }
        
        if (stats.cpu_power > 0) {
            std::cout << DIM << " │ " << RESET;
            std::cout << MAGENTA << "Power: " << std::fixed << std::setprecision(1) 
                      << stats.cpu_power << "W" << RESET;
        }
        
        std::cout << DIM << " │ " << RESET;
        std::cout << "Uptime: " << std::setfill('0') << std::setw(2) << hours 
                  << ":" << std::setw(2) << mins << ":" << std::setw(2) << secs;
        std::cout << "\033[K" << std::endl;
        
        // Line 4: Shares
        std::cout << " Shares: " << GREEN << "✓ " << stats.accepted << RESET;
        if (stats.rejected > 0) {
            std::cout << "  " << "\033[31m" << "✗ " << stats.rejected << RESET;
        }
        std::cout << DIM << " │ " << RESET;
        std::cout << "Difficulty: " << std::fixed << std::setprecision(4) << stats.difficulty;
        std::cout << "\033[K" << std::endl;
        
        // Line 5: Separator
        std::cout << DIM;
        for (int i = 0; i < width; i++) std::cout << "─";
        std::cout << RESET << std::endl;
        
        // Line 6+: Thread hashrates (compact display)
        std::cout << " Threads: ";
        int threads_per_line = 8;
        for (size_t i = 0; i < stats.thread_hashrates.size(); i++) {
            if (i > 0 && i % threads_per_line == 0) {
                std::cout << "\033[K" << std::endl << "          ";
            }
            std::cout << DIM << "[" << RESET << std::setw(2) << i << DIM << "]" << RESET;
            std::cout << format_hashrate_short(stats.thread_hashrates[i]) << " ";
        }
        std::cout << "\033[K" << std::endl;
        
        // Final separator
        std::cout << DIM;
        for (int i = 0; i < width; i++) std::cout << "═";
        std::cout << RESET << "\033[K" << std::endl;
    }
    
    std::string format_hashrate(double hr) {
        std::stringstream ss;
        ss << std::fixed << std::setprecision(2);
        if (hr >= 1e9) {
            ss << (hr / 1e9) << " GH/s";
        } else if (hr >= 1e6) {
            ss << (hr / 1e6) << " MH/s";
        } else if (hr >= 1e3) {
            ss << (hr / 1e3) << " KH/s";
        } else {
            ss << hr << " H/s";
        }
        return ss.str();
    }
    
    std::string format_hashrate_short(double hr) {
        std::stringstream ss;
        ss << std::fixed << std::setprecision(1);
        if (hr >= 1e6) {
            ss << (hr / 1e6) << "M";
        } else if (hr >= 1e3) {
            ss << (hr / 1e3) << "K";
        } else {
            ss << std::setprecision(0) << hr;
        }
        return ss.str();
    }
    
    std::mutex m_mutex;
    int m_header_lines = 8;
    int m_num_threads = 0;
};

}  // namespace utils
}  // namespace bloxminer
