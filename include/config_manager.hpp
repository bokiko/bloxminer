#pragma once

#include "config.hpp"
#include <string>
#include <optional>

namespace bloxminer {

/**
 * Configuration file manager
 * Handles loading/saving JSON config and interactive setup
 */
class ConfigManager {
public:
    // Config file names
    static constexpr const char* LOCAL_CONFIG = "bloxminer.json";
    static constexpr const char* GLOBAL_CONFIG_DIR = ".config/bloxminer";
    static constexpr const char* GLOBAL_CONFIG_FILE = "config.json";

    /**
     * Load config from file (local first, then global)
     * @param custom_path Optional custom config file path
     * @return Loaded config or nullopt if no file found
     */
    static std::optional<MinerConfig> load_config(const std::string& custom_path = "");

    /**
     * Save config to file
     * @param config Config to save
     * @param path File path (default: local config)
     * @return true if saved successfully
     */
    static bool save_config(const MinerConfig& config,
                           const std::string& path = LOCAL_CONFIG);

    /**
     * Run interactive setup prompts
     * @return Configured MinerConfig
     */
    static MinerConfig interactive_setup();

    /**
     * Check if terminal supports interactive input
     */
    static bool is_interactive_terminal();

    /**
     * Get the path to the global config file
     */
    static std::string get_global_config_path();

private:
    static std::string expand_home_path(const std::string& path);
    static std::string get_hostname();
    static uint32_t get_cpu_count();
    static bool file_exists(const std::string& path);
    static bool create_directory(const std::string& path);
};

}  // namespace bloxminer
