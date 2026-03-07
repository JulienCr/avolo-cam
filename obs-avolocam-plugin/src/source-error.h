#pragma once
#include <cstdint>

namespace avolocam {

enum class SourceError {
    OK = 0,
    // Pipeline init
    NO_CAMERA_IP,
    PORT_IN_USE,
    DECODER_CREATE_FAILED,
    // UDP
    SOCKET_CREATE_FAILED,
    BIND_FAILED,
    // Decoder
    D3D11_DEVICE_FAILED,
    CODEC_NOT_FOUND,
    CODEC_OPEN_FAILED,
    SPS_PPS_INVALID,
    // GPU
    GPU_INIT_FAILED,
    GPU_FALLBACK_TO_CPU,
    // WebSocket
    WS_CONNECT_FAILED,
};

const char* source_error_str(SourceError e);

template<typename T>
struct Result {
    T value;
    SourceError error = SourceError::OK;
    explicit operator bool() const { return error == SourceError::OK; }
};

template<>
struct Result<void> {
    SourceError error = SourceError::OK;
    explicit operator bool() const { return error == SourceError::OK; }
};

} // namespace avolocam
