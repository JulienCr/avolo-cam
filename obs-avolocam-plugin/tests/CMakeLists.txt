include(FetchContent)

FetchContent_Declare(
    googletest
    URL https://github.com/google/googletest/archive/refs/tags/v1.14.0.tar.gz
    URL_HASH SHA256=8ad598c73ad796e0d8280b082cebd82a630d73e73cd3c70057938a6501bba5d7
)

# Crucial for MSVC: use shared CRT to avoid LNK4098 warnings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(googletest)

add_executable(avocam-tests
    rtp_test_helpers.h
    test_rtp_depacketizer.cpp
    test_jitter_buffer.cpp
    test_access_unit_assembler.cpp
    test_sync_state_machine.cpp
)

target_link_libraries(avocam-tests PRIVATE
    avocam-core
    GTest::gtest_main
)

target_include_directories(avocam-tests PRIVATE
    ${CMAKE_SOURCE_DIR}/src
)

include(GoogleTest)
gtest_discover_tests(avocam-tests)
