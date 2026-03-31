#!/usr/bin/env bats
# tests/test_write_mac.bats

setup() {
    source ./write_mac.sh --source-only
}

@test "validate_mac accepts AA:BB:CC:DD:EE:FF format" {
    run validate_mac "AA:BB:CC:DD:EE:FF"
    [ "$status" -eq 0 ]
}

@test "validate_mac accepts AABBCCDDEEFF format" {
    run validate_mac "AABBCCDDEEFF"
    [ "$status" -eq 0 ]
}

@test "validate_mac accepts lowercase aa:bb:cc:dd:ee:ff" {
    run validate_mac "aa:bb:cc:dd:ee:ff"
    [ "$status" -eq 0 ]
}

@test "validate_mac rejects short MAC" {
    run validate_mac "AABBCCDDEE"
    [ "$status" -eq 1 ]
}

@test "validate_mac rejects invalid characters" {
    run validate_mac "GG:HH:II:JJ:KK:LL"
    [ "$status" -eq 1 ]
}

@test "validate_mac rejects empty string" {
    run validate_mac ""
    [ "$status" -eq 1 ]
}

@test "normalize_mac converts AA:BB:CC:DD:EE:FF to AABBCCDDEEFF" {
    run normalize_mac "AA:BB:CC:DD:EE:FF"
    [ "$output" = "AABBCCDDEEFF" ]
}

@test "normalize_mac converts lowercase to uppercase" {
    run normalize_mac "aa:bb:cc:dd:ee:ff"
    [ "$output" = "AABBCCDDEEFF" ]
}

@test "normalize_mac passes through already-normalized MAC" {
    run normalize_mac "AABBCCDDEEFF"
    [ "$output" = "AABBCCDDEEFF" ]
}
