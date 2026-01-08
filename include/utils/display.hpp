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
 * Terminal display manager with TRUE sticky header using scroll regions
 *
 * The key insight: set scroll region BELOW header, then ALL output
 * (including printf/cout) will scroll within that region, never touching header.
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

    // Initialize terminal for sticky header mode
    void init(int num_threads) {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_num_threads = num_threads;

        // Calculate header height: 7 base lines + extra rows for >8 threads
        m_header_lines = 7 + ((num_threads + 7) / 8);  // Ceiling div for thread rows
        if (m_header_lines > 12) m_header_lines = 12;  // Cap at reasonable height

        // Clear entire screen
        std::cout << "\033[2J";

        // Move to top
        std::cout << "\033[H";

        // Reserve space for header by printing empty lines
        for (int i = 0; i < m_header_lines; i++) {
            std::cout << "\033[K\n";  // Clear line and newline
        }

        // SET SCROLL REGION: from (header_lines+1) to bottom of screen (999 = large number)
        // This is the critical part - all subsequent output stays in this region
        std::cout << "\033[" << (m_header_lines + 1) << ";999r";

        // Move cursor to first line of scroll region
        std::cout << "\033[" << (m_header_lines + 1) << ";1H";

        std::cout << std::flush;
        m_initialized = true;
    }

    // Update header without disturbing scroll region content
    void update_header(const Stats& stats) {
        if (!m_initialized) return;

        std::lock_guard<std::mutex> lock(m_mutex);

        // Save cursor position
        std::cout << "\033[s";

        // Temporarily disable scroll region to access header area
        std::cout << "\033[r";

        // Move to home (top-left)
        std::cout << "\033[H";

        // Draw the header
        draw_header(stats);

        // Re-enable scroll region (from header_lines+1 to bottom)
        std::cout << "\033[" << (m_header_lines + 1) << ";999r";

        // Restore cursor position (back to where we were in scroll region)
        std::cout << "\033[u";

        std::cout << std::flush;
    }

    // Print a log line (ensures it goes to scroll region)
    void log(const std::string& message) {
        std::lock_guard<std::mutex> lock(m_mutex);
        std::cout << message << std::endl;
    }

    // Cleanup: reset scroll region and cursor
    void cleanup() {
        std::lock_guard<std::mutex> lock(m_mutex);

        // Reset scroll region to entire screen
        std::cout << "\033[r";

        // Move cursor below header area
        std::cout << "\033[" << (m_header_lines + 1) << ";1H";

        std::cout << std::flush;
        m_initialized = false;
    }

    bool is_initialized() const { return m_initialized; }
    int header_lines() const { return m_header_lines; }

private:
    Display() = default;

    void draw_header(const Stats& stats) {
        // ANSI color codes
        const char* CYAN = "\033[36m";
        const char* GREEN = "\033[32m";
        const char* YELLOW = "\033[33m";
        const char* MAGENTA = "\033[35m";
        const char* WHITE = "\033[97m";
        const char* DIM = "\033[90m";
        const char* BOLD = "\033[1m";
        const char* RESET = "\033[0m";
        const char* RED = "\033[31m";

        int width = 80;

        // Format uptime
        int hours = static_cast<int>(stats.uptime_seconds) / 3600;
        int mins = (static_cast<int>(stats.uptime_seconds) % 3600) / 60;
        int secs = static_cast<int>(stats.uptime_seconds) % 60;

        // Format total hashrate
        std::string hr_str = format_hashrate(stats.total_hashrate);

        // Line 1: Title bar
        std::cout << BOLD << CYAN << " BloxMiner v1.0.0 " << RESET
                  << DIM << "| " << RESET
                  << "Pool: " << WHITE << stats.pool << RESET
                  << DIM << " | " << RESET
                  << "Worker: " << WHITE << stats.worker << RESET
                  << "\033[K\n";

        // Line 2: Separator (thin)
        std::cout << DIM;
        for (int i = 0; i < width; i++) std::cout << "\342\224\200";  // ─ UTF-8
        std::cout << RESET << "\n";

        // Line 3: Main stats
        std::cout << " " << BOLD << GREEN << "Hashrate: " << hr_str << RESET;

        if (stats.cpu_temp > 0) {
            std::cout << DIM << " \342\224\202 " << RESET;  // │
            std::cout << YELLOW << "Temp: " << std::fixed << std::setprecision(0)
                      << stats.cpu_temp << "\302\260C" << RESET;  // °C
        }

        if (stats.cpu_power > 0) {
            std::cout << DIM << " \342\224\202 " << RESET;
            std::cout << MAGENTA << "Power: " << std::fixed << std::setprecision(1)
                      << stats.cpu_power << "W" << RESET;
            
            // Efficiency (KH/W)
            double efficiency = stats.total_hashrate / 1000.0 / stats.cpu_power;
            std::cout << DIM << " \342\224\202 " << RESET;
            std::cout << WHITE << "Eff: " << std::fixed << std::setprecision(1)
                      << efficiency << " KH/W" << RESET;
        }

        std::cout << DIM << " \342\224\202 " << RESET;
        std::cout << "Uptime: " << std::setfill('0') << std::setw(2) << hours
                  << ":" << std::setw(2) << mins << ":" << std::setw(2) << secs;
        std::cout << "\033[K\n";

        // Line 4: Shares
        std::cout << " Shares: " << GREEN << "\342\234\223 " << stats.accepted << RESET;  // ✓
        if (stats.rejected > 0) {
            std::cout << "  " << RED << "\342\234\227 " << stats.rejected << RESET;  // ✗
        }
        std::cout << DIM << " \342\224\202 " << RESET;
        std::cout << "Difficulty: " << std::fixed << std::setprecision(4) << stats.difficulty;
        std::cout << "\033[K\n";

        // Line 5: Separator
        std::cout << DIM;
        for (int i = 0; i < width; i++) std::cout << "\342\224\200";
        std::cout << RESET << "\n";

        // Lines 6+: Thread hashrates (compact display, 8 per line)
        std::cout << " Threads: ";
        int threads_per_line = 8;
        for (size_t i = 0; i < stats.thread_hashrates.size(); i++) {
            if (i > 0 && i % threads_per_line == 0) {
                std::cout << "\033[K\n          ";  // New line with indent
            }
            std::cout << DIM << "[" << RESET
                      << std::setfill('0') << std::setw(2) << i
                      << DIM << "]" << RESET
                      << format_hashrate_short(stats.thread_hashrates[i]) << " ";
        }
        std::cout << "\033[K\n";

        // Final separator (double line)
        std::cout << DIM;
        for (int i = 0; i < width; i++) std::cout << "\342\225\220";  // ═
        std::cout << RESET << "\033[K\n";
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
    bool m_initialized = false;
};

}  // namespace utils
}  // namespace bloxminer
