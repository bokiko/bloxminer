#pragma once

#include <string>
#include <iostream>
#include <mutex>
#include <chrono>
#include <iomanip>
#include <sstream>
#include "display.hpp"

namespace bloxminer {
namespace utils {

enum class LogLevel {
    DEBUG,
    INFO,
    WARN,
    ERROR
};

class Logger {
public:
    static Logger& instance() {
        static Logger logger;
        return logger;
    }

    void set_level(LogLevel level) { m_level = level; }

    template<typename... Args>
    void debug(const char* fmt, Args... args) {
        log(LogLevel::DEBUG, fmt, args...);
    }

    template<typename... Args>
    void info(const char* fmt, Args... args) {
        log(LogLevel::INFO, fmt, args...);
    }

    template<typename... Args>
    void warn(const char* fmt, Args... args) {
        log(LogLevel::WARN, fmt, args...);
    }

    template<typename... Args>
    void error(const char* fmt, Args... args) {
        log(LogLevel::ERROR, fmt, args...);
    }

    // Convenience methods for common mining output
    void hashrate(double hashrate, const std::string& unit = "H/s");
    void hashrate_with_stats(double hashrate, double cpu_temp, double cpu_power);
    void share_accepted(uint64_t accepted, uint64_t rejected);
    void share_found(double difficulty);
    void connected(const std::string& host, uint16_t port);
    void disconnected(const std::string& reason);
    void new_job(const std::string& job_id, double difficulty);
    void system_stats(double cpu_temp, double cpu_power);

private:
    Logger() : m_level(LogLevel::INFO) {}

    template<typename... Args>
    void log(LogLevel level, const char* fmt, Args... args) {
        if (level < m_level) return;

        // Build the complete log message
        std::stringstream ss;

        // Timestamp
        auto now = std::chrono::system_clock::now();
        auto time = std::chrono::system_clock::to_time_t(now);
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch()) % 1000;

        ss << "\033[90m";  // Gray for timestamp
        ss << std::put_time(std::localtime(&time), "%H:%M:%S");
        ss << "." << std::setfill('0') << std::setw(3) << ms.count();
        ss << "\033[0m ";

        // Level color and prefix
        const char* color = "";
        const char* prefix = "";
        switch (level) {
            case LogLevel::DEBUG: color = "\033[36m"; prefix = "DBG"; break;
            case LogLevel::INFO:  color = "\033[32m"; prefix = "INF"; break;
            case LogLevel::WARN:  color = "\033[33m"; prefix = "WRN"; break;
            case LogLevel::ERROR: color = "\033[31m"; prefix = "ERR"; break;
        }

        ss << color << "[" << prefix << "]\033[0m ";

        // Format message into the stringstream
        format_into(ss, fmt, args...);

        // Route through Display class for proper scroll region handling
        Display::instance().log(ss.str());
    }

    // Base case for format_into
    void format_into(std::stringstream& ss, const char* fmt) {
        ss << fmt;
    }

    // Recursive case for format_into
    template<typename T, typename... Args>
    void format_into(std::stringstream& ss, const char* fmt, T value, Args... args) {
        while (*fmt) {
            if (*fmt == '%' && *(fmt + 1)) {
                fmt++;
                switch (*fmt) {
                    case 's':
                    case 'd':
                    case 'u':
                    case 'f':
                    case 'x':
                    case 'p':
                        ss << value;
                        format_into(ss, fmt + 1, args...);
                        return;
                    case '%':
                        ss << '%';
                        break;
                    default:
                        ss << '%' << *fmt;
                        break;
                }
            } else {
                ss << *fmt;
            }
            fmt++;
        }
    }

    LogLevel m_level;
};

// Global logger access
#define LOG_DEBUG(...) bloxminer::utils::Logger::instance().debug(__VA_ARGS__)
#define LOG_INFO(...) bloxminer::utils::Logger::instance().info(__VA_ARGS__)
#define LOG_WARN(...) bloxminer::utils::Logger::instance().warn(__VA_ARGS__)
#define LOG_ERROR(...) bloxminer::utils::Logger::instance().error(__VA_ARGS__)

}  // namespace utils
}  // namespace bloxminer
