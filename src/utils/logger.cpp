#include "../../include/utils/logger.hpp"
#include <iomanip>

namespace bloxminer {
namespace utils {

void Logger::hashrate(double hashrate, const std::string& unit) {
    std::string formatted_unit = unit;
    
    // Auto-scale hashrate
    if (hashrate >= 1e12) {
        hashrate /= 1e12;
        formatted_unit = "TH/s";
    } else if (hashrate >= 1e9) {
        hashrate /= 1e9;
        formatted_unit = "GH/s";
    } else if (hashrate >= 1e6) {
        hashrate /= 1e6;
        formatted_unit = "MH/s";
    } else if (hashrate >= 1e3) {
        hashrate /= 1e3;
        formatted_unit = "KH/s";
    }
    
    std::lock_guard<std::mutex> lock(m_mutex);
    
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;
    
    std::stringstream ss;
    ss << std::put_time(std::localtime(&time), "%H:%M:%S");
    ss << "." << std::setfill('0') << std::setw(3) << ms.count();
    
    std::cout << "\033[90m" << ss.str() << "\033[0m "
              << "\033[36m[HASH]\033[0m "
              << std::fixed << std::setprecision(2) << hashrate << " " << formatted_unit
              << std::endl;
}

void Logger::hashrate_with_stats(double hashrate, double cpu_temp, double cpu_power) {
    std::string formatted_unit = "H/s";
    
    // Auto-scale hashrate
    if (hashrate >= 1e12) {
        hashrate /= 1e12;
        formatted_unit = "TH/s";
    } else if (hashrate >= 1e9) {
        hashrate /= 1e9;
        formatted_unit = "GH/s";
    } else if (hashrate >= 1e6) {
        hashrate /= 1e6;
        formatted_unit = "MH/s";
    } else if (hashrate >= 1e3) {
        hashrate /= 1e3;
        formatted_unit = "KH/s";
    }
    
    std::lock_guard<std::mutex> lock(m_mutex);
    
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;
    
    std::stringstream ss;
    ss << std::put_time(std::localtime(&time), "%H:%M:%S");
    ss << "." << std::setfill('0') << std::setw(3) << ms.count();
    
    std::cout << "\033[90m" << ss.str() << "\033[0m "
              << "\033[36m[HASH]\033[0m "
              << "\033[1m" << std::fixed << std::setprecision(2) << hashrate << " " << formatted_unit << "\033[0m";
    
    // Add temp if available
    if (cpu_temp > 0) {
        std::cout << " | \033[33mTemp:\033[0m " << std::fixed << std::setprecision(0) << cpu_temp << "C";
    }
    
    // Add power if available
    if (cpu_power > 0) {
        std::cout << " | \033[35mPower:\033[0m " << std::fixed << std::setprecision(1) << cpu_power << "W";
    }
    
    std::cout << std::endl;
}

void Logger::system_stats(double cpu_temp, double cpu_power) {
    std::lock_guard<std::mutex> lock(m_mutex);
    
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;
    
    std::stringstream ss;
    ss << std::put_time(std::localtime(&time), "%H:%M:%S");
    ss << "." << std::setfill('0') << std::setw(3) << ms.count();
    
    std::cout << "\033[90m" << ss.str() << "\033[0m "
              << "\033[34m[SYS]\033[0m ";
    
    if (cpu_temp > 0) {
        std::cout << "Temp: " << std::fixed << std::setprecision(0) << cpu_temp << "C";
    }
    
    if (cpu_power > 0) {
        if (cpu_temp > 0) std::cout << " | ";
        std::cout << "Power: " << std::fixed << std::setprecision(1) << cpu_power << "W";
    }
    
    std::cout << std::endl;
}

void Logger::share_accepted(uint64_t accepted, uint64_t rejected) {
    std::lock_guard<std::mutex> lock(m_mutex);
    
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;
    
    std::stringstream ss;
    ss << std::put_time(std::localtime(&time), "%H:%M:%S");
    ss << "." << std::setfill('0') << std::setw(3) << ms.count();
    
    std::cout << "\033[90m" << ss.str() << "\033[0m "
              << "\033[32m[SHARE]\033[0m "
              << "Accepted: \033[32m" << accepted << "\033[0m"
              << " | Rejected: \033[31m" << rejected << "\033[0m"
              << std::endl;
}

void Logger::share_found(double difficulty) {
    std::lock_guard<std::mutex> lock(m_mutex);
    
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;
    
    std::stringstream ss;
    ss << std::put_time(std::localtime(&time), "%H:%M:%S");
    ss << "." << std::setfill('0') << std::setw(3) << ms.count();
    
    std::cout << "\033[90m" << ss.str() << "\033[0m "
              << "\033[33m[FOUND]\033[0m "
              << "Share found! Difficulty: " << std::fixed << std::setprecision(4) << difficulty
              << std::endl;
}

void Logger::connected(const std::string& host, uint16_t port) {
    std::lock_guard<std::mutex> lock(m_mutex);
    
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;
    
    std::stringstream ss;
    ss << std::put_time(std::localtime(&time), "%H:%M:%S");
    ss << "." << std::setfill('0') << std::setw(3) << ms.count();
    
    std::cout << "\033[90m" << ss.str() << "\033[0m "
              << "\033[32m[CONN]\033[0m "
              << "Connected to " << host << ":" << port
              << std::endl;
}

void Logger::disconnected(const std::string& reason) {
    std::lock_guard<std::mutex> lock(m_mutex);
    
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;
    
    std::stringstream ss;
    ss << std::put_time(std::localtime(&time), "%H:%M:%S");
    ss << "." << std::setfill('0') << std::setw(3) << ms.count();
    
    std::cout << "\033[90m" << ss.str() << "\033[0m "
              << "\033[31m[DISC]\033[0m "
              << "Disconnected: " << reason
              << std::endl;
}

void Logger::new_job(const std::string& job_id, double difficulty) {
    std::lock_guard<std::mutex> lock(m_mutex);
    
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;
    
    std::stringstream ss;
    ss << std::put_time(std::localtime(&time), "%H:%M:%S");
    ss << "." << std::setfill('0') << std::setw(3) << ms.count();
    
    std::cout << "\033[90m" << ss.str() << "\033[0m "
              << "\033[35m[JOB]\033[0m "
              << "New job: " << job_id.substr(0, 8) << "... "
              << "Difficulty: " << std::fixed << std::setprecision(4) << difficulty
              << std::endl;
}

void Logger::init_display() {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (m_display_initialized) return;

    // Clear screen and move to home
    std::cout << "\033[2J\033[H";

    // Box dimensions
    const int width = 47;
    const std::string h_line(width - 2, '-');

    // Draw initial box with placeholder values
    std::cout << "\033[36m+" << h_line << "+\033[0m\n";
    std::cout << "\033[36m|\033[0m  \033[1mBloxMiner v1.0.0\033[0m - VerusHash CPU Miner    \033[36m|\033[0m\n";
    std::cout << "\033[36m+" << h_line << "+\033[0m\n";
    std::cout << "\033[36m|\033[0m  Hashrate: \033[32m" << std::left << std::setw(12) << "-- H/s" << "\033[0m";
    std::cout << "Temp: \033[33m" << std::setw(8) << "--°C" << "\033[0m  \033[36m|\033[0m\n";
    std::cout << "\033[36m|\033[0m  Accepted: \033[32m" << std::left << std::setw(12) << "0" << "\033[0m";
    std::cout << "Rejected: \033[31m" << std::setw(4) << "0" << "\033[0m    \033[36m|\033[0m\n";
    std::cout << "\033[36m|\033[0m  Uptime: " << std::left << std::setw(14) << "0h 0m";
    std::cout << "Power: \033[35m" << std::setw(7) << "--W" << "\033[0m   \033[36m|\033[0m\n";
    std::cout << "\033[36m+" << h_line << "+\033[0m\n";
    std::cout << "\n";  // Blank line before logs
    std::cout << std::flush;

    m_display_initialized = true;
}

void Logger::stats_box(const MiningStats& stats) {
    std::lock_guard<std::mutex> lock(m_mutex);

    // Format hashrate with auto-scaling
    double hr = stats.hashrate;
    std::string hr_unit = "H/s";
    if (hr >= 1e12) { hr /= 1e12; hr_unit = "TH/s"; }
    else if (hr >= 1e9) { hr /= 1e9; hr_unit = "GH/s"; }
    else if (hr >= 1e6) { hr /= 1e6; hr_unit = "MH/s"; }
    else if (hr >= 1e3) { hr /= 1e3; hr_unit = "KH/s"; }

    // Format uptime
    uint64_t secs = stats.uptime_seconds;
    uint64_t hours = secs / 3600;
    uint64_t mins = (secs % 3600) / 60;
    std::stringstream uptime_ss;
    uptime_ss << hours << "h " << mins << "m";
    std::string uptime = uptime_ss.str();

    // Build stats strings
    std::stringstream hr_ss, temp_ss, power_ss, acc_ss, rej_ss;
    hr_ss << std::fixed << std::setprecision(2) << hr << " " << hr_unit;
    temp_ss << std::fixed << std::setprecision(0) << stats.cpu_temp << "°C";
    power_ss << std::fixed << std::setprecision(1) << stats.cpu_power << "W";
    acc_ss << stats.accepted;
    rej_ss << stats.rejected;

    // Box dimensions
    const int width = 47;
    const std::string h_line(width - 2, '-');

    // Save cursor position, move to home, draw box, restore cursor
    std::cout << "\033[s";      // Save cursor position
    std::cout << "\033[H";      // Move to home (top-left)

    // Draw box (overwrites existing)
    std::cout << "\033[36m+" << h_line << "+\033[0m\n";
    std::cout << "\033[36m|\033[0m  \033[1mBloxMiner v1.0.0\033[0m - VerusHash CPU Miner    \033[36m|\033[0m\n";
    std::cout << "\033[36m+" << h_line << "+\033[0m\n";

    // Stats row 1: Hashrate and Temp
    std::cout << "\033[36m|\033[0m  Hashrate: \033[32m" << std::left << std::setw(12) << hr_ss.str() << "\033[0m";
    std::cout << "Temp: \033[33m" << std::setw(8) << temp_ss.str() << "\033[0m  \033[36m|\033[0m\n";

    // Stats row 2: Accepted and Rejected
    std::cout << "\033[36m|\033[0m  Accepted: \033[32m" << std::left << std::setw(12) << acc_ss.str() << "\033[0m";
    std::cout << "Rejected: \033[31m" << std::setw(4) << rej_ss.str() << "\033[0m    \033[36m|\033[0m\n";

    // Stats row 3: Uptime and Power
    std::cout << "\033[36m|\033[0m  Uptime: " << std::left << std::setw(14) << uptime;
    std::cout << "Power: \033[35m" << std::setw(7) << power_ss.str() << "\033[0m   \033[36m|\033[0m\n";

    std::cout << "\033[36m+" << h_line << "+\033[0m";

    std::cout << "\033[u";      // Restore cursor position
    std::cout << std::flush;
}

}  // namespace utils
}  // namespace bloxminer
