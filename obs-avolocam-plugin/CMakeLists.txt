cmake_minimum_required(VERSION 3.16)

project(obs-avolocam VERSION 1.0.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# On Apple Silicon, compile for arm64 to match OBS.app
if(APPLE)
    set(CMAKE_OSX_ARCHITECTURES "arm64")
endif()

# OBS SDK configuration
# Use local headers from deps/ directory
set(OBS_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/deps/obs-studio-32.0.4")
set(OBS_LIBOBS_DIR "${OBS_SOURCE_DIR}/libobs")

# Check if OBS headers exist
if(NOT EXISTS "${OBS_LIBOBS_DIR}/obs-module.h")
    message(FATAL_ERROR "OBS SDK headers not found. Please run:
    cd deps && curl -sL https://github.com/obsproject/obs-studio/archive/refs/tags/32.0.4.tar.gz | tar -xz")
endif()

# On macOS, we link against the installed OBS framework
if(APPLE)
    set(OBS_APP_PATH "/Applications/OBS.app")
    set(OBS_FRAMEWORK_PATH "${OBS_APP_PATH}/Contents/Frameworks/libobs.framework")
    if(EXISTS "${OBS_FRAMEWORK_PATH}")
        message(STATUS "Found OBS framework at ${OBS_FRAMEWORK_PATH}")
        set(OBS_LIBRARIES "${OBS_FRAMEWORK_PATH}/Versions/A/libobs")
    else()
        message(WARNING "OBS framework not found at ${OBS_FRAMEWORK_PATH}. Plugin will be header-only build.")
        set(OBS_LIBRARIES "")
    endif()
endif()

# Find platform-specific dependencies
if(APPLE)
    find_library(VIDEOTOOLBOX_FRAMEWORK VideoToolbox REQUIRED)
    find_library(COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
    find_library(COREVIDEO_FRAMEWORK CoreVideo REQUIRED)
    find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
    find_library(IOSURFACE_FRAMEWORK IOSurface REQUIRED)
    # CFNetwork for mDNS discovery
    find_library(CFNETWORK_FRAMEWORK CFNetwork REQUIRED)
    # Foundation for NSNumber, etc.
    find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
endif()

if(WIN32)
    # Media Foundation for hardware decoding
    set(MF_LIBRARIES mf mfplat mfuuid mfreadwrite d3d11 dxgi)
    # Bonjour SDK for mDNS discovery (requires Bonjour SDK installed)
    # dnssd.lib is provided by Bonjour SDK for Windows

    # OBS SDK for Windows - user must set OBS_DIR or use standard location
    if(NOT DEFINED OBS_DIR)
        # Check common installation locations
        if(EXISTS "C:/Program Files/obs-studio")
            set(OBS_DIR "C:/Program Files/obs-studio" CACHE PATH "OBS installation directory")
        elseif(EXISTS "$ENV{ProgramFiles}/obs-studio")
            set(OBS_DIR "$ENV{ProgramFiles}/obs-studio" CACHE PATH "OBS installation directory")
        else()
            set(OBS_DIR "" CACHE PATH "OBS installation directory")
        endif()
    endif()

    if(OBS_DIR AND EXISTS "${OBS_DIR}")
        # Find OBS library - try deps folder first (generated import lib), then OBS installation
        find_library(OBS_LIB obs
            PATHS
                "${CMAKE_CURRENT_SOURCE_DIR}/deps"
                "${OBS_DIR}/bin/64bit"
                "${OBS_DIR}/lib"
            NO_DEFAULT_PATH
        )

        # OBS include directory - OBS SDK headers in include/
        set(OBS_WIN_INCLUDE_DIR "${OBS_DIR}/include")
        if(EXISTS "${OBS_WIN_INCLUDE_DIR}")
            message(STATUS "Found OBS Windows include directory: ${OBS_WIN_INCLUDE_DIR}")
        endif()

        if(OBS_LIB)
            message(STATUS "Found OBS library: ${OBS_LIB}")
            set(OBS_WINDOWS_FOUND TRUE)
        else()
            message(WARNING "OBS library not found in ${OBS_DIR}. Plugin may not link correctly.")
            set(OBS_WINDOWS_FOUND FALSE)
        endif()
    else()
        message(WARNING "OBS_DIR not set or doesn't exist. Set OBS_DIR to your OBS installation.")
        set(OBS_WINDOWS_FOUND FALSE)
    endif()

    # Bonjour SDK path
    if(NOT DEFINED BONJOUR_SDK_DIR)
        if(EXISTS "C:/Program Files/Bonjour SDK")
            set(BONJOUR_SDK_DIR "C:/Program Files/Bonjour SDK" CACHE PATH "Bonjour SDK directory")
        else()
            set(BONJOUR_SDK_DIR "" CACHE PATH "Bonjour SDK directory")
        endif()
    endif()

    if(BONJOUR_SDK_DIR AND EXISTS "${BONJOUR_SDK_DIR}")
        set(BONJOUR_INCLUDE_DIR "${BONJOUR_SDK_DIR}/Include")
        set(BONJOUR_LIB_DIR "${BONJOUR_SDK_DIR}/Lib/x64")
        if(EXISTS "${BONJOUR_INCLUDE_DIR}" AND EXISTS "${BONJOUR_LIB_DIR}")
            message(STATUS "Found Bonjour SDK at ${BONJOUR_SDK_DIR}")
            set(BONJOUR_FOUND TRUE)
        else()
            message(WARNING "Bonjour SDK structure not found. mDNS discovery may not work.")
            set(BONJOUR_FOUND FALSE)
        endif()
    else()
        message(WARNING "Bonjour SDK not found. mDNS discovery will be disabled.")
        set(BONJOUR_FOUND FALSE)
    endif()
endif()

# Source files
set(SOURCES
    src/plugin-main.cpp
    src/avolocam-source.cpp
    src/avolocam-source.h
    src/udp-receiver.cpp
    src/udp-receiver.h
    src/jitter-buffer.cpp
    src/jitter-buffer.h
    src/rtp-depacketizer.cpp
    src/rtp-depacketizer.h
    src/access-unit-assembler.cpp
    src/access-unit-assembler.h
    src/sync-state-machine.cpp
    src/sync-state-machine.h
    src/timestamp-mapper.cpp
    src/timestamp-mapper.h
    src/mdns-discovery.cpp
    src/mdns-discovery.h
    src/websocket-client.cpp
    src/websocket-client.h
    src/texture-output.h
    src/decoder/platform-decoder.h
)

# Platform-specific decoder and texture output sources
if(APPLE)
    list(APPEND SOURCES
        src/decoder/videotoolbox-decoder.mm
        src/decoder/videotoolbox-decoder.h
        src/texture-output-macos.mm
    )
endif()

if(WIN32)
    list(APPEND SOURCES
        src/decoder/mf-decoder.cpp
        src/decoder/mf-decoder.h
        src/texture-output-windows.cpp
    )
endif()

# FFmpeg fallback decoder (optional)
option(ENABLE_FFMPEG_FALLBACK "Enable FFmpeg software decoder fallback" ON)
if(ENABLE_FFMPEG_FALLBACK)
    find_package(FFmpeg COMPONENTS avcodec avutil)
    if(FFmpeg_FOUND)
        list(APPEND SOURCES
            src/decoder/ffmpeg-decoder.cpp
            src/decoder/ffmpeg-decoder.h
        )
        add_definitions(-DHAVE_FFMPEG)
    endif()
endif()

# Fallback decoder factory for platforms without specific decoder
if(NOT APPLE AND NOT WIN32 AND NOT FFmpeg_FOUND)
    list(APPEND SOURCES
        src/decoder/platform-decoder-fallback.cpp
    )
endif()

# Create the plugin
add_library(obs-avolocam MODULE ${SOURCES})

# Include directories - use local OBS headers
target_include_directories(obs-avolocam PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${OBS_LIBOBS_DIR}
    ${OBS_SOURCE_DIR}
)

# Windows: add pthread shim directory
if(WIN32)
    target_include_directories(obs-avolocam PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/deps/pthread-win32
    )
endif()

# Link libraries
if(APPLE AND OBS_LIBRARIES)
    target_link_libraries(obs-avolocam PRIVATE
        "${OBS_LIBRARIES}"
    )
endif()

if(APPLE)
    target_link_libraries(obs-avolocam PRIVATE
        ${VIDEOTOOLBOX_FRAMEWORK}
        ${COREMEDIA_FRAMEWORK}
        ${COREVIDEO_FRAMEWORK}
        ${COREFOUNDATION_FRAMEWORK}
        ${IOSURFACE_FRAMEWORK}
        ${CFNETWORK_FRAMEWORK}
        ${FOUNDATION_FRAMEWORK}
    )
    # Enable Objective-C++ for .mm files
    set_source_files_properties(
        src/decoder/videotoolbox-decoder.mm
        src/texture-output-macos.mm
        PROPERTIES COMPILE_FLAGS "-x objective-c++"
    )
endif()

if(WIN32)
    # Add OBS Windows include directory
    if(OBS_WINDOWS_FOUND AND EXISTS "${OBS_WIN_INCLUDE_DIR}")
        target_include_directories(obs-avolocam PRIVATE ${OBS_WIN_INCLUDE_DIR})
    endif()

    # Add Bonjour SDK include directory
    if(BONJOUR_FOUND)
        target_include_directories(obs-avolocam PRIVATE ${BONJOUR_INCLUDE_DIR})
        target_link_directories(obs-avolocam PRIVATE ${BONJOUR_LIB_DIR})
    endif()

    # Link OBS library
    if(OBS_WINDOWS_FOUND AND OBS_LIB)
        target_link_libraries(obs-avolocam PRIVATE ${OBS_LIB})
    endif()

    # Link Media Foundation and other Windows libraries
    target_link_libraries(obs-avolocam PRIVATE
        ${MF_LIBRARIES}
        ws2_32      # Winsock for UDP
    )

    # Link Bonjour SDK if found
    if(BONJOUR_FOUND)
        target_link_libraries(obs-avolocam PRIVATE dnssd)
    else()
        # Define to disable mDNS at compile time
        target_compile_definitions(obs-avolocam PRIVATE NO_MDNS_DISCOVERY)
    endif()
endif()

if(UNIX AND NOT APPLE)
    # Linux - link against Avahi for mDNS (optional)
    find_package(PkgConfig)
    if(PkgConfig_FOUND)
        pkg_check_modules(AVAHI avahi-client)
        if(AVAHI_FOUND)
            target_include_directories(obs-avolocam PRIVATE ${AVAHI_INCLUDE_DIRS})
            target_link_libraries(obs-avolocam PRIVATE ${AVAHI_LIBRARIES})
            add_definitions(-DHAVE_AVAHI)
        endif()
    endif()
endif()

if(ENABLE_FFMPEG_FALLBACK AND FFmpeg_FOUND)
    target_link_libraries(obs-avolocam PRIVATE
        FFmpeg::avcodec
        FFmpeg::avutil
    )
endif()

# Set output name
set_target_properties(obs-avolocam PROPERTIES
    OUTPUT_NAME "obs-avolocam"
    PREFIX ""
)

# Installation
if(APPLE)
    set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/obs-studio/plugins")
elseif(WIN32)
    set(PLUGIN_INSTALL_DIR "$ENV{APPDATA}/obs-studio/plugins")
else()
    set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.config/obs-studio/plugins")
endif()

install(TARGETS obs-avolocam
    LIBRARY DESTINATION "${PLUGIN_INSTALL_DIR}/obs-avolocam/bin/64bit"
)

# Install data files if any
install(DIRECTORY data/
    DESTINATION "${PLUGIN_INSTALL_DIR}/obs-avolocam/data"
    OPTIONAL
)
