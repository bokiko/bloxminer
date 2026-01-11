#pragma once

#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <chrono>
#include <cstdint>
#include <climits>
#include <dirent.h>
#include <cstring>

namespace bloxminer {
namespace utils {

struct SystemStats {
    double cpu_temp = 0.0;        // Celsius
    double cpu_power = 0.0;       // Watts (CPU only, from RAPL)
    double gpu_power = 0.0;       // Watts (GPUs only, from amdgpu hwmon)
    double cpu_usage = 0.0;       // Percentage
    bool temp_available = false;
    bool cpu_power_available = false;
    bool gpu_power_available = false;
};

class SystemMonitor {
public:
    static SystemMonitor& instance() {
        static SystemMonitor monitor;
        return monitor;
    }
    
    // Get current system stats
    SystemStats get_stats() {
        SystemStats stats;
        stats.cpu_temp = get_cpu_temp();
        stats.temp_available = (stats.cpu_temp > 0);
        stats.cpu_power = get_cpu_power();
        stats.cpu_power_available = (stats.cpu_power > 0);
        stats.gpu_power = get_gpu_power();
        stats.gpu_power_available = (stats.gpu_power > 0);
        return stats;
    }
    
    // Get CPU temperature in Celsius
    double get_cpu_temp() {
        double temp = 0.0;
        
        // Try hwmon sensors (works for most CPUs)
        temp = read_hwmon_temp();
        if (temp > 0) return temp;
        
        // Try thermal zones (fallback)
        temp = read_thermal_zone_temp();
        if (temp > 0) return temp;
        
        return 0.0;
    }
    
    // Get CPU power in Watts (from RAPL only)
    double get_cpu_power() {
        return read_rapl_power();
    }

    // Get GPU power in Watts (sum of all GPU power sensors)
    double get_gpu_power() {
        double total = 0.0;

        // Sum all GPU power sensors (amdgpu, nvidia, etc.)
        for (const auto& path : m_gpu_power_paths) {
            std::ifstream file(path);
            if (file.is_open()) {
                uint64_t power_uw = 0;
                file >> power_uw;
                file.close();
                if (power_uw > 0) {
                    total += power_uw / 1000000.0;  // microwatts to watts
                }
            }
        }

        return total;
    }
    
private:
    SystemMonitor() {
        // Initialize - find sensor paths
        find_temp_sensor();
        find_power_sensor();
        find_gpu_power_sensors();
    }
    
    void find_temp_sensor() {
        // Search for CPU temp sensor in hwmon
        // Priority: k10temp (AMD) > coretemp (Intel) > zenpower > cpu_thermal > acpitz
        DIR* dir = opendir("/sys/class/hwmon");
        if (!dir) return;

        std::string fallback_path;  // Lower priority sensor

        struct dirent* entry;
        while ((entry = readdir(dir)) != nullptr) {
            if (strncmp(entry->d_name, "hwmon", 5) != 0) continue;

            std::string hwmon_path = std::string("/sys/class/hwmon/") + entry->d_name;

            // Check name
            std::ifstream name_file(hwmon_path + "/name");
            if (name_file.is_open()) {
                std::string name;
                std::getline(name_file, name);
                name_file.close();

                // High priority: actual CPU temp sensors
                if (name == "k10temp" || name == "coretemp" || name == "zenpower") {
                    m_hwmon_path = hwmon_path;
                    break;  // Found best option, stop searching
                }
                // Low priority: fallback sensors (may not be accurate)
                if (name == "cpu_thermal" || name == "acpitz") {
                    if (fallback_path.empty()) {
                        fallback_path = hwmon_path;
                    }
                }
            }
        }
        closedir(dir);

        // Use fallback if no high-priority sensor found
        if (m_hwmon_path.empty() && !fallback_path.empty()) {
            m_hwmon_path = fallback_path;
        }
    }
    
    void find_power_sensor() {
        // Look for RAPL power sensors first
        // AMD: /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj
        // Intel: same path structure

        std::vector<std::string> rapl_paths = {
            "/sys/class/powercap/intel-rapl/intel-rapl:0",
            "/sys/class/powercap/intel-rapl:0",
            "/sys/devices/virtual/powercap/intel-rapl/intel-rapl:0"
        };

        for (const auto& path : rapl_paths) {
            std::ifstream test(path + "/energy_uj");
            if (test.is_open()) {
                m_rapl_path = path;
                test.close();

                // Read initial energy value
                m_last_energy = read_energy_uj();
                m_last_energy_time = std::chrono::steady_clock::now();
                return;  // RAPL found, done
            }
        }

        // RAPL not available, try hwmon power sensors (AMD systems)
        find_hwmon_power_sensor();
    }

    void find_hwmon_power_sensor() {
        // Scan /sys/class/hwmon/ for CPU power sensors
        // Skip GPU power sensors (amdgpu, nvidia, etc.)
        DIR* dir = opendir("/sys/class/hwmon");
        if (!dir) return;

        struct dirent* entry;
        while ((entry = readdir(dir)) != nullptr) {
            if (strncmp(entry->d_name, "hwmon", 5) != 0) continue;

            std::string hwmon_path = std::string("/sys/class/hwmon/") + entry->d_name;

            // Check sensor name - skip GPU sensors
            std::ifstream name_file(hwmon_path + "/name");
            if (name_file.is_open()) {
                std::string name;
                std::getline(name_file, name);
                name_file.close();

                // Skip GPU power sensors
                if (name == "amdgpu" || name == "nvidia" || name == "nouveau" ||
                    name == "radeon" || name.find("gpu") != std::string::npos) {
                    continue;
                }

                // Only use CPU-related power sensors
                if (name != "k10temp" && name != "coretemp" && name != "zenpower") {
                    continue;
                }
            }

            // Check for power sensor files (in order of preference)
            std::vector<std::string> power_files = {
                hwmon_path + "/power1_average",
                hwmon_path + "/power1_input"
            };

            for (const auto& power_file : power_files) {
                std::ifstream test(power_file);
                if (test.is_open()) {
                    // Verify it returns a valid reading
                    uint64_t value = 0;
                    test >> value;
                    test.close();

                    if (value > 0) {
                        m_hwmon_power_path = power_file;
                        closedir(dir);
                        return;
                    }
                }
            }
        }
        closedir(dir);
    }

    void find_gpu_power_sensors() {
        // Find GPU-specific power sensors (amdgpu, nvidia, nouveau, radeon)
        DIR* dir = opendir("/sys/class/hwmon");
        if (!dir) return;

        struct dirent* entry;
        while ((entry = readdir(dir)) != nullptr) {
            if (strncmp(entry->d_name, "hwmon", 5) != 0) continue;

            std::string hwmon_path = std::string("/sys/class/hwmon/") + entry->d_name;

            // Check sensor name - only include GPU sensors
            std::ifstream name_file(hwmon_path + "/name");
            if (!name_file.is_open()) continue;

            std::string name;
            std::getline(name_file, name);
            name_file.close();

            // Only GPU power sensors
            if (name != "amdgpu" && name != "nvidia" && name != "nouveau" && name != "radeon") {
                continue;
            }

            // Check for power sensor files
            std::vector<std::string> power_files = {
                hwmon_path + "/power1_average",
                hwmon_path + "/power1_input"
            };

            for (const auto& power_file : power_files) {
                std::ifstream test(power_file);
                if (test.is_open()) {
                    uint64_t value = 0;
                    test >> value;
                    test.close();

                    if (value > 0) {
                        m_gpu_power_paths.push_back(power_file);
                        break;  // Only one per hwmon device
                    }
                }
            }
        }
        closedir(dir);
    }

    double read_hwmon_temp() {
        if (m_hwmon_path.empty()) return 0.0;
        
        // Try temp1_input first (most common)
        std::vector<std::string> temp_files = {
            m_hwmon_path + "/temp1_input",
            m_hwmon_path + "/temp2_input",
            m_hwmon_path + "/temp3_input"
        };
        
        for (const auto& path : temp_files) {
            std::ifstream file(path);
            if (file.is_open()) {
                int temp_milli;
                file >> temp_milli;
                file.close();
                if (temp_milli > 0) {
                    return temp_milli / 1000.0;
                }
            }
        }
        
        return 0.0;
    }
    
    double read_thermal_zone_temp() {
        // Try thermal zones
        for (int i = 0; i < 10; i++) {
            std::string path = "/sys/class/thermal/thermal_zone" + std::to_string(i) + "/temp";
            std::ifstream file(path);
            if (file.is_open()) {
                int temp_milli;
                file >> temp_milli;
                file.close();
                if (temp_milli > 0 && temp_milli < 150000) {  // Sanity check
                    return temp_milli / 1000.0;
                }
            }
        }
        return 0.0;
    }
    
    uint64_t read_energy_uj() {
        if (m_rapl_path.empty()) return 0;
        
        std::ifstream file(m_rapl_path + "/energy_uj");
        if (!file.is_open()) return 0;
        
        uint64_t energy;
        file >> energy;
        file.close();
        return energy;
    }
    
    double read_rapl_power() {
        // Try hwmon power sensor first (if RAPL was not available)
        if (!m_hwmon_power_path.empty()) {
            return read_hwmon_power();
        }

        if (m_rapl_path.empty()) return 0.0;

        auto now = std::chrono::steady_clock::now();
        uint64_t current_energy = read_energy_uj();

        if (m_last_energy == 0 || current_energy == 0) {
            m_last_energy = current_energy;
            m_last_energy_time = now;
            return 0.0;
        }

        // Calculate time delta in seconds
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now - m_last_energy_time);
        double seconds = duration.count() / 1000.0;

        if (seconds < 0.1) return m_last_power;  // Too fast, return cached value

        // Calculate power (energy delta / time delta)
        // Handle wraparound - if current < last, counter wrapped
        uint64_t energy_delta;
        if (current_energy >= m_last_energy) {
            energy_delta = current_energy - m_last_energy;
        } else {
            // Wraparound - just use the new value as delta (approximation)
            // This loses one sample but avoids huge incorrect values
            m_last_energy = current_energy;
            m_last_energy_time = now;
            return m_last_power;  // Return cached value during wraparound
        }

        // Convert microjoules to watts
        double power = (energy_delta / 1000000.0) / seconds;

        // Sanity check - CPU power should never exceed 500W
        if (power > 500.0) {
            // Invalid reading, skip this sample
            m_last_energy = current_energy;
            m_last_energy_time = now;
            return m_last_power;
        }

        // Update for next reading
        m_last_energy = current_energy;
        m_last_energy_time = now;
        m_last_power = power;

        return power;
    }

    double read_hwmon_power() {
        if (m_hwmon_power_path.empty()) return 0.0;

        std::ifstream file(m_hwmon_power_path);
        if (!file.is_open()) return 0.0;

        uint64_t power_uw = 0;  // microwatts
        file >> power_uw;
        file.close();

        if (power_uw == 0) return 0.0;

        // Convert microwatts to watts
        return power_uw / 1000000.0;
    }
    
    std::string m_hwmon_path;
    std::string m_hwmon_power_path;  // hwmon power sensor path (AMD fallback)
    std::string m_rapl_path;
    std::vector<std::string> m_gpu_power_paths;  // GPU power sensors (amdgpu, nvidia, etc.)
    uint64_t m_last_energy = 0;
    std::chrono::steady_clock::time_point m_last_energy_time;
    double m_last_power = 0.0;
};

}  // namespace utils
}  // namespace bloxminer
