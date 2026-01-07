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

}  // namespace utils
}  // namespace bloxminer
