/*
 * Debug test for target calculation and hash comparison
 */

#include <cstdio>
#include <cstring>
#include <cstdint>

#include "../src/crypto/verus_hash.h"
#include "../include/utils/hex_utils.hpp"

void print_bytes(const char* label, const uint8_t* data, size_t len) {
    printf("%s: ", label);
    for (size_t i = 0; i < len; i++) {
        printf("%02x", data[i]);
    }
    printf("\n");
}

int main() {
    printf("=== BloxMiner Target Debug Test ===\n\n");
    
    // Initialize
    verus_hash_init();
    
    // Test 1: Check target calculation for difficulty 1
    printf("Test 1: Target calculation\n");
    {
        uint8_t target[32];
        
        bloxminer::utils::difficulty_to_target(1.0, target);
        print_bytes("Diff 1.0 target", target, 32);
        
        bloxminer::utils::difficulty_to_target(0.5, target);
        print_bytes("Diff 0.5 target", target, 32);
        
        bloxminer::utils::difficulty_to_target(2.0, target);
        print_bytes("Diff 2.0 target", target, 32);
        
        bloxminer::utils::difficulty_to_target(1000.0, target);
        print_bytes("Diff 1000 target", target, 32);
    }
    
    // Test 2: Generate some hashes and see their distribution
    printf("\nTest 2: Hash distribution check\n");
    {
        verus::Hasher hasher;
        alignas(32) uint8_t header[80] = {0};
        alignas(32) uint8_t hash[32];
        uint8_t target[32];
        
        // Set difficulty 1
        bloxminer::utils::difficulty_to_target(1.0, target);
        
        hasher.init(header, 80);
        
        int found = 0;
        int checks = 100000;
        
        printf("Checking %d hashes against diff 1 target...\n", checks);
        
        for (uint32_t i = 0; i < (uint32_t)checks; i++) {
            hasher.hash(i, hash);
            
            if (bloxminer::utils::meets_target(hash, target)) {
                found++;
                if (found <= 5) {
                    printf("  Found at nonce %u: ", i);
                    print_bytes("", hash, 32);
                }
            }
        }
        
        printf("Found %d shares in %d hashes (expected ~%.1f for diff 1)\n", 
               found, checks, (double)checks / 65536.0);
    }
    
    // Test 3: Check meets_target logic
    printf("\nTest 3: meets_target logic check\n");
    {
        uint8_t hash[32] = {0};
        uint8_t target[32] = {0};
        
        // All zeros should be < any target with non-zero byte
        target[0] = 0xFF;
        printf("hash=0x00... target=0xFF...: %s (expect: true)\n",
               bloxminer::utils::meets_target(hash, target) ? "true" : "false");
        
        // Target with leading zeros
        memset(target, 0, 32);
        target[4] = 0xFF;
        target[5] = 0xFF;
        
        // Hash with first byte > 0 should fail
        hash[0] = 0x01;
        printf("hash=0x01... target=0x0000...FFFF...: %s (expect: false)\n",
               bloxminer::utils::meets_target(hash, target) ? "true" : "false");
        
        // Hash all zeros should pass
        hash[0] = 0x00;
        printf("hash=0x00... target=0x0000...FFFF...: %s (expect: true)\n",
               bloxminer::utils::meets_target(hash, target) ? "true" : "false");
    }
    
    // Test 4: Check first few hash values
    printf("\nTest 4: First 10 hash values\n");
    {
        verus::Hasher hasher;
        alignas(32) uint8_t header[80] = {0};
        alignas(32) uint8_t hash[32];
        
        hasher.init(header, 80);
        
        for (uint32_t i = 0; i < 10; i++) {
            hasher.hash(i, hash);
            printf("nonce %u: first bytes = %02x%02x%02x%02x\n", 
                   i, hash[0], hash[1], hash[2], hash[3]);
        }
    }
    
    // Test 5: Check with real-like header
    printf("\nTest 5: Simulated mining check\n");
    {
        verus::Hasher hasher;
        alignas(32) uint8_t header[80];
        alignas(32) uint8_t hash[32];
        uint8_t target[32];
        
        // Fill with somewhat random data
        for (int i = 0; i < 80; i++) {
            header[i] = (uint8_t)(i * 17 + 3);
        }
        
        hasher.init(header, 80);
        bloxminer::utils::difficulty_to_target(1.0, target);
        
        printf("Target first 8 bytes: ");
        for (int i = 0; i < 8; i++) printf("%02x", target[i]);
        printf("\n");
        
        int found = 0;
        uint32_t firstFound = 0;
        
        for (uint32_t i = 0; i < 1000000 && found < 3; i++) {
            hasher.hash(i, hash);
            
            if (bloxminer::utils::meets_target(hash, target)) {
                if (found == 0) firstFound = i;
                found++;
                printf("Found share at nonce %u\n", i);
                print_bytes("  Hash", hash, 32);
            }
        }
        
        if (found == 0) {
            printf("NO SHARES FOUND in 1M hashes - BUG DETECTED!\n");
            
            // Debug: show some hash values
            printf("\nDebug - sample hashes:\n");
            for (uint32_t i = 0; i < 5; i++) {
                hasher.hash(i * 1000, hash);
                print_bytes("  ", hash, 32);
            }
        } else {
            printf("First share found at nonce %u (expected ~65536 avg for diff 1)\n", firstFound);
        }
    }
    
    printf("\n=== Debug Test Complete ===\n");
    return 0;
}
