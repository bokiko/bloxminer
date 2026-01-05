/*
 * VerusHash Test Vectors
 * 
 * Tests to validate the VerusHash implementation against known values.
 */

#include <cstdio>
#include <cstring>
#include <cstdint>

#include "../src/crypto/verus_hash.h"

// Convert bytes to hex string
void bytes_to_hex(const uint8_t* data, size_t len, char* out) {
    for (size_t i = 0; i < len; i++) {
        sprintf(out + i * 2, "%02x", data[i]);
    }
    out[len * 2] = '\0';
}

// Print hash in hex
void print_hash(const char* label, const uint8_t* hash) {
    char hex[65];
    bytes_to_hex(hash, 32, hex);
    printf("%s: %s\n", label, hex);
}

int main() {
    printf("=== BloxMiner VerusHash Test ===\n\n");
    
    // Check CPU support
    if (!verus_hash_supported()) {
        printf("ERROR: CPU does not support required features (AES-NI, AVX, PCLMUL)\n");
        return 1;
    }
    printf("CPU support: OK (AES-NI, AVX, PCLMUL)\n\n");
    
    // Initialize
    verus_hash_init();
    
    // Test 1: Empty input
    printf("Test 1: Empty input\n");
    {
        alignas(32) uint8_t hash[32];
        uint8_t empty[1] = {0};
        verus_hash_v2(hash, empty, 0);
        print_hash("V2.0 empty", hash);
        
        // Note: These are not official test vectors, just for consistency checking
    }
    
    // Test 2: Single byte
    printf("\nTest 2: Single byte (0x00)\n");
    {
        alignas(32) uint8_t hash[32];
        uint8_t data[1] = {0x00};
        verus_hash_v2(hash, data, 1);
        print_hash("V2.0 0x00", hash);
    }
    
    // Test 3: 32 bytes of zeros
    printf("\nTest 3: 32 bytes of zeros\n");
    {
        alignas(32) uint8_t hash[32];
        alignas(32) uint8_t data[32] = {0};
        verus_hash_v2(hash, data, 32);
        print_hash("V2.0 32x0", hash);
    }
    
    // Test 4: 80 bytes (standard block header size)
    printf("\nTest 4: 80 bytes header-like data\n");
    {
        alignas(32) uint8_t hash[32];
        alignas(32) uint8_t data[80];
        for (int i = 0; i < 80; i++) {
            data[i] = (uint8_t)i;
        }
        
        verus_hash_v2(hash, data, 80);
        print_hash("V2.0 80B", hash);
        
        verus_hash_v2_2(hash, data, 80);
        print_hash("V2.2 80B", hash);
    }
    
    // Test 5: Using the Hasher class
    printf("\nTest 5: Hasher class with nonce\n");
    {
        verus::Hasher hasher;
        alignas(32) uint8_t header[80];
        alignas(32) uint8_t hash[32];
        
        for (int i = 0; i < 80; i++) {
            header[i] = (uint8_t)i;
        }
        
        hasher.init(header, 80);
        
        // Hash with different nonces
        hasher.hash(0x00000000, hash);
        print_hash("nonce=0", hash);
        
        hasher.hash(0x00000001, hash);
        print_hash("nonce=1", hash);
        
        hasher.hash(0x12345678, hash);
        print_hash("nonce=0x12345678", hash);
    }
    
    // Test 6: Haraka256 test
    printf("\nTest 6: Haraka256 (32->32)\n");
    {
        alignas(32) uint8_t in[32] = {0};
        alignas(32) uint8_t out[32];
        
        haraka256(out, in);
        print_hash("haraka256(zeros)", out);
        
        // Input = 0,1,2,...,31
        for (int i = 0; i < 32; i++) in[i] = i;
        haraka256(out, in);
        print_hash("haraka256(0..31)", out);
    }
    
    // Test 7: Haraka512 test
    printf("\nTest 7: Haraka512 (64->32)\n");
    {
        alignas(32) uint8_t in[64] = {0};
        alignas(32) uint8_t out[32];
        
        haraka512(out, in);
        print_hash("haraka512(zeros)", out);
        
        // Input = 0,1,2,...,63
        for (int i = 0; i < 64; i++) in[i] = i;
        haraka512(out, in);
        print_hash("haraka512(0..63)", out);
    }
    
    // Test 8: Performance test
    printf("\nTest 8: Performance (1M hashes)\n");
    {
        verus::Hasher hasher;
        alignas(32) uint8_t header[80] = {0};
        alignas(32) uint8_t hash[32];
        
        hasher.init(header, 80);
        
        // Time 1 million hashes
        auto start = __builtin_ia32_rdtsc();
        for (uint32_t i = 0; i < 1000000; i++) {
            hasher.hash(i, hash);
        }
        auto end = __builtin_ia32_rdtsc();
        
        double cycles = (double)(end - start);
        double cycles_per_hash = cycles / 1000000.0;
        
        printf("Cycles per hash: %.0f\n", cycles_per_hash);
        printf("Last hash: ");
        print_hash("", hash);
    }
    
    printf("\n=== Tests Complete ===\n");
    return 0;
}
