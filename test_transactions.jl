#!/usr/bin/env julia

# Transaction Test Script
# Tests MULTI/EXEC/DISCARD functionality

using Pkg
Pkg.activate(".")

include("Radish.jl")
using .Radish
using Sockets

function test_transactions()
    println("🧪 Testing Transaction Implementation\n")
    
    # Wait for server
    sleep(1)
    
    try
        sock = connect("127.0.0.1", 6379)
        welcome = readline(sock)
        println("Connected: $(rstrip(welcome))\n")
        
        # Test 1: Basic MULTI/EXEC
        println("Test 1: Basic MULTI/EXEC")
        write_resp_command(sock, "MULTI")
        println("  > MULTI: $(read_resp_response(sock))")
        
        write_resp_command(sock, "S_SET key1 value1")
        println("  > S_SET key1 value1: $(read_resp_response(sock))")
        
        write_resp_command(sock, "S_GET key1")
        println("  > S_GET key1: $(read_resp_response(sock))")
        
        write_resp_command(sock, "EXEC")
        println("  > EXEC: $(read_resp_response(sock))")
        println()
        
        # Test 2: DISCARD
        println("Test 2: DISCARD")
        write_resp_command(sock, "MULTI")
        println("  > MULTI: $(read_resp_response(sock))")
        
        write_resp_command(sock, "S_SET key2 value2")
        println("  > S_SET key2 value2: $(read_resp_response(sock))")
        
        write_resp_command(sock, "DISCARD")
        println("  > DISCARD: $(read_resp_response(sock))")
        
        write_resp_command(sock, "S_GET key2")
        println("  > S_GET key2 (should be nil): $(read_resp_response(sock))")
        println()
        
        # Test 3: Counter increment
        println("Test 3: Counter increment in transaction")
        write_resp_command(sock, "S_SET counter 10")
        println("  > S_SET counter 10: $(read_resp_response(sock))")
        
        write_resp_command(sock, "MULTI")
        println("  > MULTI: $(read_resp_response(sock))")
        
        write_resp_command(sock, "S_INCR counter")
        println("  > S_INCR counter: $(read_resp_response(sock))")
        
        write_resp_command(sock, "S_INCR counter")
        println("  > S_INCR counter: $(read_resp_response(sock))")
        
        write_resp_command(sock, "S_GET counter")
        println("  > S_GET counter: $(read_resp_response(sock))")
        
        write_resp_command(sock, "EXEC")
        println("  > EXEC: $(read_resp_response(sock))")
        println()
        
        # Test 4: Error without MULTI
        println("Test 4: EXEC without MULTI (should error)")
        write_resp_command(sock, "EXEC")
        println("  > EXEC: $(read_resp_response(sock))")
        println()
        
        # Test 5: Multi-key transaction
        println("Test 5: Multi-key transaction")
        write_resp_command(sock, "MULTI")
        println("  > MULTI: $(read_resp_response(sock))")
        
        write_resp_command(sock, "S_SET account_A 100")
        println("  > S_SET account_A 100: $(read_resp_response(sock))")
        
        write_resp_command(sock, "S_SET account_B 50")
        println("  > S_SET account_B 50: $(read_resp_response(sock))")
        
        write_resp_command(sock, "S_GET account_A")
        println("  > S_GET account_A: $(read_resp_response(sock))")
        
        write_resp_command(sock, "S_GET account_B")
        println("  > S_GET account_B: $(read_resp_response(sock))")
        
        write_resp_command(sock, "EXEC")
        println("  > EXEC: $(read_resp_response(sock))")
        println()
        
        # Cleanup
        write_resp_command(sock, "QUIT")
        read_resp_response(sock)
        close(sock)
        
        println("✅ All transaction tests completed!")
        
    catch e
        println("❌ Test error: $e")
        rethrow(e)
    end
end

# Run tests
test_transactions()
