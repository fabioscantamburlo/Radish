#!/usr/bin/env julia

# Radish Behavioral Test Suite
# Tests all commands via TCP client-server communication

using Pkg
Pkg.activate(".")

include("Radish.jl")
using .Radish
using Sockets

# Test utilities
mutable struct TestStats
    passed::Int
    failed::Int
    TestStats() = new(0, 0)
end

function send_command(sock::TCPSocket, cmd::String)
    write_resp_command(sock, cmd)
    return read_resp_response(sock)
end

function assert_contains(response::String, expected::String, test_name::String, stats::TestStats)
    if occursin(expected, response)
        println("✅ $test_name")
        stats.passed += 1
        return true
    else
        println("❌ $test_name")
        println("   Expected to contain: '$expected'")
        println("   Got: '$response'")
        stats.failed += 1
        return false
    end
end

function assert_equals(response::String, expected::String, test_name::String, stats::TestStats)
    if response == expected
        println("✅ $test_name")
        stats.passed += 1
        return true
    else
        println("❌ $test_name")
        println("   Expected: '$expected'")
        println("   Got: '$response'")
        stats.failed += 1
        return false
    end
end

function assert_success(response::String, test_name::String, stats::TestStats)
    if startswith(response, "✅") || response == "OK" || response == "QUEUED"
        println("✅ $test_name")
        stats.passed += 1
        return true
    else
        println("❌ $test_name")
        println("   Got: '$response'")
        stats.failed += 1
        return false
    end
end

function assert_is_array(response::String, test_name::String, stats::TestStats)
    if startswith(response, "[")
        println("✅ $test_name")
        stats.passed += 1
        return true
    else
        println("❌ $test_name")
        println("   Expected array starting with '['") 
        println("   Got: '$response'")
        stats.failed += 1
        return false
    end
end

function assert_is_nil(response::String, test_name::String, stats::TestStats)
    if occursin("(nil)", response)
        println("✅ $test_name")
        stats.passed += 1
        return true
    else
        println("❌ $test_name")
        println("   Expected nil")
        println("   Got: '$response'")
        stats.failed += 1
        return false
    end
end

# Test suites
function test_context_commands(sock::TCPSocket, stats::TestStats)
    println("\n📋 Testing Context Commands...")
    
    # PING
    resp = send_command(sock, "PING")
    assert_contains(resp, "PONG", "PING command", stats)
    
    # KLIST
    resp = send_command(sock, "KLIST")
    assert_is_array(resp, "KLIST command", stats)
    
    # KLIST with limit
    resp = send_command(sock, "KLIST 2")
    assert_is_array(resp, "KLIST with limit", stats)
end

function test_string_commands(sock::TCPSocket, stats::TestStats)
    println("\n📝 Testing String Commands...")
    
    # S_SET
    resp = send_command(sock, "S_SET testkey hello")
    assert_success(resp, "S_SET basic", stats)
    
    # S_GET
    resp = send_command(sock, "S_GET testkey")
    assert_contains(resp, "hello", "S_GET basic", stats)
    
    # S_SET with TTL
    resp = send_command(sock, "S_SET ttlkey value 60")
    assert_success(resp, "S_SET with TTL", stats)
    
    # S_APPEND
    resp = send_command(sock, "S_APPEND testkey world")
    assert_success(resp, "S_APPEND", stats)
    
    resp = send_command(sock, "S_GET testkey")
    assert_contains(resp, "helloworld", "S_GET after append", stats)
    
    # S_LEN
    resp = send_command(sock, "S_LEN testkey")
    assert_contains(resp, "10", "S_LEN", stats)
    
    # S_GETRANGE
    resp = send_command(sock, "S_GETRANGE testkey 0 4")
    assert_contains(resp, "hello", "S_GETRANGE", stats)
    
    # S_INCR
    resp = send_command(sock, "S_SET counter 10")
    assert_success(resp, "S_SET counter", stats)
    
    resp = send_command(sock, "S_INCR counter")
    assert_success(resp, "S_INCR", stats)
    
    resp = send_command(sock, "S_GET counter")
    assert_contains(resp, "11", "S_GET after INCR", stats)
    
    # S_INCRBY
    resp = send_command(sock, "S_INCRBY counter 5")
    assert_success(resp, "S_INCRBY", stats)
    
    resp = send_command(sock, "S_GET counter")
    assert_contains(resp, "16", "S_GET after INCRBY", stats)
    
    # S_GINCR (get then increment)
    resp = send_command(sock, "S_GINCR counter")
    assert_contains(resp, "16", "S_GINCR returns old value", stats)
    
    resp = send_command(sock, "S_GET counter")
    assert_contains(resp, "17", "S_GET after GINCR", stats)
    
    # S_GINCRBY
    resp = send_command(sock, "S_GINCRBY counter 3")
    assert_contains(resp, "17", "S_GINCRBY returns old value", stats)
    
    resp = send_command(sock, "S_GET counter")
    assert_contains(resp, "20", "S_GET after GINCRBY", stats)
    
    # S_RPAD
    resp = send_command(sock, "S_SET padkey abc")
    resp = send_command(sock, "S_RPAD padkey 6 x")
    assert_success(resp, "S_RPAD", stats)
    
    resp = send_command(sock, "S_GET padkey")
    assert_contains(resp, "abcxxx", "S_GET after RPAD", stats)
    
    # S_LPAD
    resp = send_command(sock, "S_SET padkey2 abc")
    resp = send_command(sock, "S_LPAD padkey2 6 y")
    assert_success(resp, "S_LPAD", stats)
    
    resp = send_command(sock, "S_GET padkey2")
    assert_contains(resp, "yyyabc", "S_GET after LPAD", stats)
    
    # S_LCS (longest common subsequence)
    resp = send_command(sock, "S_SET str1 abcdef")
    resp = send_command(sock, "S_SET str2 acdxf")
    resp = send_command(sock, "S_LCS str1 str2")
    assert_is_array(resp, "S_LCS", stats)
    
    # S_COMPLEN (compare lengths)
    resp = send_command(sock, "S_SET len1 hello")
    resp = send_command(sock, "S_SET len2 world")
    resp = send_command(sock, "S_COMPLEN len1 len2")
    assert_contains(resp, "1", "S_COMPLEN equal lengths", stats)
end

function test_list_commands(sock::TCPSocket, stats::TestStats)
    println("\n📚 Testing List Commands...")
    
    # L_ADD
    resp = send_command(sock, "L_ADD mylist item1")
    assert_success(resp, "L_ADD", stats)
    
    # L_GET
    resp = send_command(sock, "L_GET mylist")
    assert_contains(resp, "item1", "L_GET after add", stats)
    
    # L_PREPEND
    resp = send_command(sock, "L_PREPEND mylist item0")
    assert_success(resp, "L_PREPEND", stats)
    
    resp = send_command(sock, "L_GET mylist")
    assert_contains(resp, "item0", "L_GET after prepend", stats)
    
    # L_APPEND
    resp = send_command(sock, "L_APPEND mylist item2")
    assert_success(resp, "L_APPEND", stats)
    
    resp = send_command(sock, "L_GET mylist")
    assert_contains(resp, "item2", "L_GET after append", stats)
    
    # L_LEN
    resp = send_command(sock, "L_LEN mylist")
    assert_contains(resp, "3", "L_LEN", stats)
    
    # L_RANGE
    resp = send_command(sock, "L_RANGE mylist 1 2")
    assert_is_array(resp, "L_RANGE", stats)
    
    # L_POP (remove from tail)
    resp = send_command(sock, "L_POP mylist")
    assert_contains(resp, "item2", "L_POP returns tail", stats)
    
    resp = send_command(sock, "L_LEN mylist")
    assert_contains(resp, "2", "L_LEN after pop", stats)
    
    # L_DEQUEUE (remove from head)
    resp = send_command(sock, "L_DEQUEUE mylist")
    assert_contains(resp, "item0", "L_DEQUEUE returns head", stats)
    
    resp = send_command(sock, "L_LEN mylist")
    assert_contains(resp, "1", "L_LEN after dequeue", stats)
    
    # L_TRIMR (keep first n)
    resp = send_command(sock, "L_APPEND mylist item3")
    resp = send_command(sock, "L_APPEND mylist item4")
    resp = send_command(sock, "L_APPEND mylist item5")
    resp = send_command(sock, "L_TRIMR mylist 2")
    assert_success(resp, "L_TRIMR", stats)
    
    resp = send_command(sock, "L_LEN mylist")
    assert_contains(resp, "2", "L_LEN after trimr", stats)
    
    # L_TRIML (keep last n)
    resp = send_command(sock, "L_ADD list2 a")
    resp = send_command(sock, "L_APPEND list2 b")
    resp = send_command(sock, "L_APPEND list2 c")
    resp = send_command(sock, "L_TRIML list2 2")
    assert_success(resp, "L_TRIML", stats)
    
    resp = send_command(sock, "L_LEN list2")
    assert_contains(resp, "2", "L_LEN after triml", stats)
    
    # L_MOVE (move list2 to end of list1, consuming list2)
    resp = send_command(sock, "L_ADD list3 x")
    resp = send_command(sock, "L_ADD list4 y")
    resp = send_command(sock, "L_MOVE list3 list4")
    assert_success(resp, "L_MOVE", stats)
    
    resp = send_command(sock, "L_GET list3")
    assert_contains(resp, "y", "L_GET after move contains moved items", stats)
    
    # L_PREPEND on non-existent list (should create)
    resp = send_command(sock, "L_PREPEND newlist first")
    assert_success(resp, "L_PREPEND creates list", stats)
    
    # L_APPEND on non-existent list (should create)
    resp = send_command(sock, "L_APPEND newlist2 first")
    assert_success(resp, "L_APPEND creates list", stats)
end

function test_error_cases(sock::TCPSocket, stats::TestStats)
    println("\n⚠️  Testing Error Cases...")
    
    # Get non-existent key (returns nil)
    resp = send_command(sock, "S_GET nonexistent")
    assert_is_nil(resp, "S_GET non-existent key returns nil", stats)
    
    # Wrong type operation
    resp = send_command(sock, "S_SET stringkey value")
    resp = send_command(sock, "L_GET stringkey")
    assert_contains(resp, "WRONGTYPE", "Wrong type error", stats)
    
    # Key already exists
    resp = send_command(sock, "S_SET existkey val")
    resp = send_command(sock, "S_SET existkey val2")
    assert_contains(resp, "0", "S_SET on existing key returns false", stats)
end

function test_transaction_commands(sock::TCPSocket, stats::TestStats)
    println("\n💳 Testing Transaction Commands...")
    
    # Basic MULTI/EXEC
    resp = send_command(sock, "MULTI")
    assert_success(resp, "MULTI starts transaction", stats)
    
    resp = send_command(sock, "S_SET tx_key1 value1")
    assert_success(resp, "Command queued in transaction", stats)
    
    resp = send_command(sock, "S_GET tx_key1")
    assert_success(resp, "Second command queued", stats)
    
    resp = send_command(sock, "EXEC")
    assert_is_array(resp, "EXEC returns array", stats)
    
    # Verify transaction executed
    resp = send_command(sock, "S_GET tx_key1")
    assert_contains(resp, "value1", "Transaction committed changes", stats)
    
    # DISCARD test
    resp = send_command(sock, "MULTI")
    assert_success(resp, "MULTI for discard test", stats)
    
    resp = send_command(sock, "S_SET tx_key2 value2")
    assert_success(resp, "Command queued for discard", stats)
    
    resp = send_command(sock, "DISCARD")
    assert_success(resp, "DISCARD aborts transaction", stats)
    
    resp = send_command(sock, "S_GET tx_key2")
    assert_is_nil(resp, "Discarded transaction didn't commit", stats)
    
    # Invalid command aborts transaction
    resp = send_command(sock, "MULTI")
    assert_success(resp, "MULTI for invalid command test", stats)
    
    resp = send_command(sock, "S_SET tx_key3 value3")
    assert_success(resp, "Valid command queued", stats)
    
    resp = send_command(sock, "INVALID_CMD")
    assert_contains(resp, "ERR", "Invalid command aborts transaction", stats)
    
    resp = send_command(sock, "S_GET tx_key3")
    assert_is_nil(resp, "Aborted transaction didn't commit", stats)
    
    # Multi-operation transaction
    resp = send_command(sock, "S_SET counter_tx 10")
    resp = send_command(sock, "MULTI")
    resp = send_command(sock, "S_INCR counter_tx")
    resp = send_command(sock, "S_INCR counter_tx")
    resp = send_command(sock, "S_INCR counter_tx")
    resp = send_command(sock, "S_GET counter_tx")
    resp = send_command(sock, "EXEC")
    assert_contains(resp, "13", "Multi-operation transaction", stats)
    
    # EXEC without MULTI
    resp = send_command(sock, "EXEC")
    assert_contains(resp, "ERR", "EXEC without MULTI errors", stats)
    
    # DISCARD without MULTI
    resp = send_command(sock, "DISCARD")
    assert_contains(resp, "ERR", "DISCARD without MULTI errors", stats)
end

# Main test runner
function run_all_tests()
    println("🌱 Starting Radish Behavioral Test Suite\n")
    
    stats = TestStats()
    
    # Start server in background
    println("🚀 Starting Radish server...")
    server_task = @async start_server("127.0.0.1", 6380)
    
    # Wait for server to be ready
    sleep(2)
    
    try
        # Connect client
        println("🔌 Connecting to server...")
        sock = connect("127.0.0.1", 6380)
        
        # Read welcome message
        welcome = readline(sock)
        println("📡 Server says: $(rstrip(welcome))\n")
        
        # Run test suites
        test_context_commands(sock, stats)
        test_string_commands(sock, stats)
        test_list_commands(sock, stats)
        test_transaction_commands(sock, stats)
        test_error_cases(sock, stats)
        
        # Cleanup
        send_command(sock, "QUIT")
        close(sock)
        
        # Report
        println("\n" * "="^50)
        println("📊 Test Results:")
        println("   ✅ Passed: $(stats.passed)")
        println("   ❌ Failed: $(stats.failed)")
        println("   📈 Total:  $(stats.passed + stats.failed)")
        println("="^50)
        
        if stats.failed == 0
            println("\n🎉 All tests passed!")
            exit(0)
        else
            println("\n💥 Some tests failed!")
            exit(1)
        end
        
    catch e
        println("\n❌ Test suite error: $e")
        exit(1)
    end
end

# Run tests
run_all_tests()
