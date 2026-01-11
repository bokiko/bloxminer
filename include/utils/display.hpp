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
 * Terminal display manager with TRUE sticky header using absolute cursor positioning
 *
 * Key fix: Never reset scroll region (\033[r]) during updates - this was causing
 * logs to overwrite the header. Instead, use absolute cursor positioning to draw
 * the header in-place.
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
        double cpu_power = 0;     // CPU power only (from RAPL)
        double rig_power = 0;     // Total rig power (CPU + GPUs)
        double efficiency = 0;    // KH/W
        std::string pool;
        std::string worker;
        double difficulty = 0;
        double uptime_seconds = 0;
        // Pool failover info
        size_t current_pool_index = 0;
        size_t total_pools = 1;
    };

    // Initialize terminal for sticky header mode
    void init(int num_threads) {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_num_threads = num_threads;

        // Calculate header lines: 7 base lines + thread lines (6 threads per line)
        int thread_lines = (num_threads + 5) / 6;  // Ceiling division
        m_header_lines = 7 + thread_lines;

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

    // Update header WITHOUT disturbing scroll region - uses absolute positioning only
    void update_header(const Stats& stats) {
        if (!m_initialized) return;

        std::lock_guard<std::mutex> lock(m_mutex);

        // Save cursor position
        std::cout << "\033[s";

        // Draw header using absolute positioning - NO \033[r] (scroll region reset)!
        draw_header_absolute(stats);

        // Restore cursor position (back to where we were in scroll region)
        std::cout << "\033[u";

        std::cout << std::flush;
    }

    // Print a log line (ensures it goes to scroll region and is thread-safe)
    void log(const std::string& message) {
        std::lock_guard<std::mutex> lock(m_mutex);
        std::cout << message << std::endl;
        std::cout.flush();
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

    static constexpr int BOX_WIDTH = 68;  // Inner width for the box

    void draw_header_absolute(const Stats& stats) {
        // ANSI color codes
        const char* CYAN = "\033[36m";
        const char* GREEN = "\033[32m";
        const char* YELLOW = "\033[33m";
        const char* MAGENTA = "\033[35m";
        const char* WHITE = "\033[97m";
        const char* BOLD = "\033[1m";
        const char* RESET = "\033[0m";
        const char* RED = "\033[31m";

        // ASCII box-drawing characters
        const char* TL = "+";  // top-left
        const char* TR = "+";  // top-right
        const char* BL = "+";  // bottom-left
        const char* BR = "+";  // bottom-right
        const char* H  = "-";  // horizontal
        const char* V  = "|";  // vertical
        const char* LT = "+";  // left-tee
        const char* RT = "+";  // right-tee

        // Format uptime
        int hours = static_cast<int>(stats.uptime_seconds) / 3600;
        int mins = (static_cast<int>(stats.uptime_seconds) % 3600) / 60;

        // Format total hashrate
        std::string hr_str = format_hashrate(stats.total_hashrate);

        // Format pool with failover indicator
        std::string pool_str = stats.pool;
        if (stats.total_pools > 1) {
            std::stringstream ps;
            ps << pool_str << " (" << (stats.current_pool_index + 1) << "/" << stats.total_pools << ")";
            pool_str = ps.str();
        }
        if (pool_str.length() > 30) {
            pool_str = pool_str.substr(0, 27) + "...";
        }

        // Format difficulty
        std::stringstream diff_ss;
        diff_ss << std::fixed << std::setprecision(4) << stats.difficulty;
        std::string diff_str = diff_ss.str();

        int row = 1;

        // Helper to position cursor and clear line
        auto goto_row = [&row]() {
            std::cout << "\033[" << row << ";1H\033[2K";
            row++;
        };

        // Helper to print horizontal line
        auto print_hline = [&](const char* left, const char* right) {
            goto_row();
            std::cout << CYAN << left;
            for (int i = 0; i < BOX_WIDTH; i++) std::cout << H;
            std::cout << right << RESET;
        };

        // Line 1: Top border
        print_hline(TL, TR);

        // Line 2: Title
        goto_row();
        std::cout << CYAN << V << RESET << "  " << BOLD << WHITE
                  << "BloxMiner v1.0.3" << RESET << " - VerusHash CPU Miner";
        int padding = BOX_WIDTH - 41;
        std::cout << std::string(padding > 0 ? padding : 0, ' ');
        std::cout << CYAN << V << RESET;

        // Line 3: Middle separator
        print_hline(LT, RT);

        // Line 4: Hashrate and Pool
        goto_row();
        std::cout << CYAN << V << RESET
                  << "  Hashrate: " << GREEN << std::setw(14) << std::left << hr_str << RESET
                  << "  Pool: " << CYAN << std::setw(30) << std::left << pool_str << RESET
                  << std::string(BOX_WIDTH - 60 > 0 ? BOX_WIDTH - 60 : 0, ' ')
                  << CYAN << V << RESET;

        // Line 5: Accepted, Rejected, Difficulty
        goto_row();
        std::cout << CYAN << V << RESET
                  << "  Accepted: " << GREEN << std::setw(8) << std::left << stats.accepted << RESET
                  << "  Rejected: " << RED << std::setw(6) << std::left << stats.rejected << RESET
                  << "  Difficulty: " << YELLOW << std::setw(10) << std::left << diff_str << RESET
                  << std::string(BOX_WIDTH - 56 > 0 ? BOX_WIDTH - 56 : 0, ' ')
                  << CYAN << V << RESET;

        // Line 6: CPU Temp, Rig Power, Efficiency, Uptime
        std::string temp_str = (stats.cpu_temp > 0)
            ? std::to_string((int)stats.cpu_temp) + "C"
            : "--C";
        std::stringstream uptime_ss;
        uptime_ss << hours << "h " << mins << "m";
        std::stringstream rig_power_ss;
        if (stats.rig_power > 0) {
            rig_power_ss << std::fixed << std::setprecision(0) << stats.rig_power << "W";
        } else {
            rig_power_ss << "N/A";
        }
        std::stringstream eff_ss;
        if (stats.efficiency > 0) {
            eff_ss << std::fixed << std::setprecision(0) << stats.efficiency << " KH/W";
        } else {
            eff_ss << "N/A";
        }

        goto_row();
        std::cout << CYAN << V << RESET
                  << "  Temp: " << YELLOW << std::setw(5) << std::left << temp_str << RESET
                  << "  Power: " << MAGENTA << std::setw(5) << std::left << rig_power_ss.str() << RESET
                  << "  Eff: " << GREEN << std::setw(10) << std::left << eff_ss.str() << RESET
                  << "  Uptime: " << std::setw(8) << std::left << uptime_ss.str()
                  << std::string(BOX_WIDTH - 55 > 0 ? BOX_WIDTH - 55 : 0, ' ')
                  << CYAN << V << RESET;

        // Line 7: Separator before thread hashrates
        print_hline(LT, RT);

        // Thread hashrate lines (6 threads per line in compact format: T00: 870K)
        size_t thread_count = stats.thread_hashrates.size();
        int threads_per_line = 6;

        for (size_t start = 0; start < thread_count; start += threads_per_line) {
            goto_row();
            std::cout << CYAN << V << RESET << " ";

            std::stringstream line_ss;
            for (size_t i = start; i < start + threads_per_line && i < thread_count; i++) {
                if (i > start) line_ss << "  ";
                line_ss << "T" << std::setfill('0') << std::setw(2) << i << ": "
                        << std::setfill(' ') << std::setw(5) << std::right
                        << format_hashrate_short(stats.thread_hashrates[i]);
            }

            std::string line_content = line_ss.str();
            std::cout << line_content;

            // Pad to box width
            int content_len = static_cast<int>(line_content.length()) + 1;  // +1 for leading space
            int pad = BOX_WIDTH - content_len;
            if (pad > 0) std::cout << std::string(pad, ' ');
            std::cout << CYAN << V << RESET;
        }

        // Bottom border
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
        if (hr >= 1e6) {
            ss << std::fixed << std::setprecision(1) << (hr / 1e6) << "M";
        } else if (hr >= 1e3) {
            ss << std::fixed << std::setprecision(0) << static_cast<int>(hr / 1e3) << "K";
        } else {
            ss << std::fixed << std::setprecision(0) << static_cast<int>(hr);
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
