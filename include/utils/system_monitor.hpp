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
    double cpu_power = 0.0;       // Watts (if available)
    double cpu_usage = 0.0;       // Percentage
    bool temp_available = false;
    bool power_available = false;
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
        stats.power_available = (stats.cpu_power > 0);
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
    
    // Get CPU power in Watts (AMD RAPL or Intel RAPL)
    double get_cpu_power() {
        // Try RAPL (Running Average Power Limit)
        return read_rapl_power();
    }
    
private:
    SystemMonitor() {
        // Initialize - find sensor paths
        find_temp_sensor();
        find_power_sensor();
    }
    
    void find_temp_sensor() {
        // Search for CPU temp sensor in hwmon
        DIR* dir = opendir("/sys/class/hwmon");
        if (!dir) return;
        
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
                
                // Look for CPU temp sensors
                if (name == "k10temp" || name == "coretemp" || name == "zenpower" ||
                    name == "cpu_thermal" || name == "acpitz") {
                    m_hwmon_path = hwmon_path;
                    break;
                }
            }
        }
        closedir(dir);
    }
    
    void find_power_sensor() {
        // Look for RAPL power sensors
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
                break;
            }
        }
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
        // Handle wraparound (energy counter is typically 32-bit)
        uint64_t energy_delta;
        if (current_energy >= m_last_energy) {
            energy_delta = current_energy - m_last_energy;
        } else {
            // Wraparound
            energy_delta = (0xFFFFFFFFULL - m_last_energy) + current_energy;
        }
        
        // Convert microjoules to watts
        double power = (energy_delta / 1000000.0) / seconds;
        
        // Update for next reading
        m_last_energy = current_energy;
        m_last_energy_time = now;
        m_last_power = power;
        
        return power;
    }
    
    std::string m_hwmon_path;
    std::string m_rapl_path;
    uint64_t m_last_energy = 0;
    std::chrono::steady_clock::time_point m_last_energy_time;
    double m_last_power = 0.0;
};

}  // namespace utils
}  // namespace bloxminer
