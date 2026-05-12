#include "../include/config.hpp"
#include <iostream>

int main() {
    bloxminer::MinerConfig config;

    if (config.pool_host != "pool.verus.io") {
        std::cerr << "Expected default pool_host to be pool.verus.io, got: " << config.pool_host << std::endl;
        return 1;
    }

    if (config.pool_port != 9999) {
        std::cerr << "Expected default pool_port to be 9999, got: " << config.pool_port << std::endl;
        return 1;
    }

    std::cout << "Default config pool values are correct" << std::endl;
    return 0;
}
