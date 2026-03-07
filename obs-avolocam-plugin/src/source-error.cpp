#include "source-error.h"

namespace avolocam {

const char* source_error_str(SourceError e) {
    switch (e) {
    case SourceError::OK:                   return "OK";
    case SourceError::NO_CAMERA_IP:         return "No camera IP configured";
    case SourceError::PORT_IN_USE:          return "Port already in use";
    case SourceError::DECODER_CREATE_FAILED:return "Failed to create decoder";
    case SourceError::SOCKET_CREATE_FAILED: return "Failed to create socket";
    case SourceError::BIND_FAILED:          return "Failed to bind socket";
    case SourceError::D3D11_DEVICE_FAILED:  return "D3D11 device creation failed";
    case SourceError::CODEC_NOT_FOUND:      return "Codec not found";
    case SourceError::CODEC_OPEN_FAILED:    return "Failed to open codec";
    case SourceError::SPS_PPS_INVALID:      return "Invalid SPS/PPS";
    case SourceError::GPU_INIT_FAILED:      return "GPU initialization failed";
    case SourceError::GPU_FALLBACK_TO_CPU:  return "GPU unavailable, using CPU fallback";
    case SourceError::WS_CONNECT_FAILED:    return "WebSocket connection failed";
    default:                                return "Unknown error";
    }
}

} // namespace avolocam
