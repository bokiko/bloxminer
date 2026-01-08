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

        // Fixed 7-line box header
        m_header_lines = 7;

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
        const char* BOLD = "\033[1m";
        const char* RESET = "\033[0m";
        const char* RED = "\033[31m";

        // Box-drawing characters (UTF-8)
        const char* TL = "\xE2\x94\x8C";  // ┌
        const char* TR = "\xE2\x94\x90";  // ┐
        const char* BL = "\xE2\x94\x94";  // └
        const char* BR = "\xE2\x94\x98";  // ┘
        const char* H  = "\xE2\x94\x80";  // ─
        const char* V  = "\xE2\x94\x82";  // │
        const char* LT = "\xE2\x94\x9C";  // ├
        const char* RT = "\xE2\x94\xA4";  // ┤

        const int BOX_WIDTH = 60;  // Inner width

        // Format uptime
        int hours = static_cast<int>(stats.uptime_seconds) / 3600;
        int mins = (static_cast<int>(stats.uptime_seconds) % 3600) / 60;

        // Format total hashrate
        std::string hr_str = format_hashrate(stats.total_hashrate);

        // Helper to print horizontal line
        auto print_hline = [&](const char* left, const char* right) {
            std::cout << CYAN << left;
            for (int i = 0; i < BOX_WIDTH; i++) std::cout << H;
            std::cout << right << RESET << "\033[K\n";
        };

        // Line 1: Top border
        print_hline(TL, TR);

        // Line 2: Title
        std::cout << CYAN << V << RESET << "  " << BOLD << WHITE
                  << "BloxMiner v1.0.0" << RESET << " - VerusHash CPU Miner";
        std::cout << std::string(BOX_WIDTH - 41, ' ');
        std::cout << CYAN << V << RESET << "\033[K\n";

        // Line 3: Middle separator
        print_hline(LT, RT);

        // Line 4: Hashrate and Temp
        std::string temp_str = (stats.cpu_temp > 0)
            ? std::to_string((int)stats.cpu_temp) + "\xC2\xB0" "C"
            : "--\xC2\xB0" "C";

        std::cout << CYAN << V << RESET
                  << "  Hashrate: " << GREEN << std::setw(12) << std::left << hr_str << RESET
                  << "   Temp: " << YELLOW << std::setw(8) << std::left << temp_str << RESET
                  << std::string(BOX_WIDTH - 44, ' ')
                  << CYAN << V << RESET << "\033[K\n";

        // Line 5: Accepted and Rejected
        std::cout << CYAN << V << RESET
                  << "  Accepted: " << GREEN << std::setw(12) << std::left << stats.accepted << RESET
                  << "   Rejected: " << RED << std::setw(6) << std::left << stats.rejected << RESET
                  << std::string(BOX_WIDTH - 44, ' ')
                  << CYAN << V << RESET << "\033[K\n";

        // Line 6: Uptime and Power
        std::stringstream uptime_ss;
        uptime_ss << hours << "h " << mins << "m";
        std::stringstream power_ss;
        if (stats.cpu_power > 0) {
            power_ss << std::fixed << std::setprecision(1) << stats.cpu_power << "W";
        } else {
            power_ss << "--W";
        }
        std::string power_str = power_ss.str();

        std::cout << CYAN << V << RESET
                  << "  Uptime: " << std::setw(14) << std::left << uptime_ss.str()
                  << "   Power: " << MAGENTA << std::setw(8) << std::left << power_str << RESET
                  << std::string(BOX_WIDTH - 44, ' ')
                  << CYAN << V << RESET << "\033[K\n";

        // Line 7: Bottom border
        print_hline(BL, BR);
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
