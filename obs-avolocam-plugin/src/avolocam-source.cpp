/**
 * avolocam-source.cpp - OBS source callbacks and registration
 *
 * Contains only the OBS plugin interface: source callbacks, globals,
 * and avolocam_source_register(). All SourceData method implementations
 * live in avolocam-pipeline.cpp, avolocam-receive.cpp, and
 * avolocam-decode.cpp. Test pattern generation is in test-pattern.cpp.
 */

#include "avolocam-source.h"
#include "avolocam-source-data.h"
#include "test-pattern.h"

namespace avolocam {

// Global mDNS discovery instance (shared across all sources)
std::unique_ptr<MdnsDiscovery> g_discovery;
std::mutex g_discovery_mutex;

// Global port registry: prevents multiple sources from binding the same UDP port
std::set<uint16_t> g_bound_ports;
std::mutex g_ports_mutex;

// --- SourceData destructor (uses OBS graphics API) ---

SourceData::~SourceData() {
    stop();
    if (test_pattern.texture) {
        obs_enter_graphics();
        gs_texture_destroy(test_pattern.texture);
        obs_leave_graphics();
        test_pattern.texture = nullptr;
    }
}

// ============================================================================
// OBS Source Callbacks
// ============================================================================

static const char *avolocam_get_name(void *)
{
    return "AvoCam Flash Source";
}

static void *avolocam_create(obs_data_t *settings, obs_source_t *source)
{
    auto *data = new SourceData();
    data->source = source;

    // Load settings (single-threaded construction, but use store() for atomics)
    data->config.camera_ip = obs_data_get_string(settings, PROP_MANUAL_IP);
    data->config.camera_port.store((uint16_t)obs_data_get_int(settings, PROP_MANUAL_PORT));
    data->config.jitter_mode.store((int)obs_data_get_int(settings, PROP_JITTER_MODE));
    data->config.show_latency.store(obs_data_get_bool(settings, PROP_SHOW_LATENCY));
    data->config.auth_token = obs_data_get_string(settings, PROP_AUTH_TOKEN);
    data->config.prefer_zero_copy.store(obs_data_get_bool(settings, PROP_PREFER_ZERO_COPY));
    data->config.debug_mode.store(obs_data_get_bool(settings, PROP_DEBUG_MODE));
    data->config.decoder_type.store((int)obs_data_get_int(settings, PROP_DECODER_TYPE));

    ALOG(LOG_INFO, "Source created (decoder_type=%d, port=%d)",
         data->config.decoder_type.load(), data->config.camera_port.load());
    return data;
}

static void avolocam_destroy(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    delete src;
    ALOG(LOG_INFO, "Source destroyed");
}

static void avolocam_update(void *data, obs_data_t *settings)
{
    auto *src = static_cast<SourceData *>(data);

    // Check if a camera was selected from the dropdown
    std::string camera_select = obs_data_get_string(settings, PROP_CAMERA_SELECT);
    std::string new_ip = obs_data_get_string(settings, PROP_MANUAL_IP);
    uint16_t new_port = (uint16_t)obs_data_get_int(settings, PROP_MANUAL_PORT);

    // If a camera was selected from dropdown, use it as the IP
    // Note: Port is NOT from dropdown - it must be set manually to match Tauri assignment
    if (!camera_select.empty()) {
        new_ip = camera_select;
        ALOG(LOG_INFO, "Selected camera from dropdown: %s (port from manual field: %d)",
             new_ip.c_str(), new_port);
    }

    int new_jitter = (int)obs_data_get_int(settings, PROP_JITTER_MODE);
    std::string new_token = obs_data_get_string(settings, PROP_AUTH_TOKEN);
    bool new_zero_copy = obs_data_get_bool(settings, PROP_PREFER_ZERO_COPY);
    bool new_debug_mode = obs_data_get_bool(settings, PROP_DEBUG_MODE);
    int new_decoder_type = (int)obs_data_get_int(settings, PROP_DECODER_TYPE);

    // Snapshot current string values under lock for comparison
    std::string old_ip, old_token;
    {
        std::lock_guard<std::mutex> lock(src->config.mutex);
        old_ip = src->config.camera_ip;
        old_token = src->config.auth_token;
    }

    // Check if we need to restart
    bool needs_restart = (new_ip != old_ip ||
                          new_port != src->config.camera_port.load() ||
                          new_jitter != src->config.jitter_mode.load() ||
                          new_token != old_token ||
                          new_zero_copy != src->config.prefer_zero_copy.load() ||
                          new_decoder_type != src->config.decoder_type.load());

    // Update string fields under lock
    {
        std::lock_guard<std::mutex> lock(src->config.mutex);
        src->config.camera_ip = new_ip;
        src->config.auth_token = new_token;
    }
    // Update atomic fields
    src->config.camera_port.store(new_port);
    src->config.jitter_mode.store(new_jitter);
    src->config.show_latency.store(obs_data_get_bool(settings, PROP_SHOW_LATENCY));
    src->config.prefer_zero_copy.store(new_zero_copy);
    src->config.debug_mode.store(new_debug_mode);
    src->config.decoder_type.store(new_decoder_type);

    if (needs_restart && src->running.load()) {
        src->stop();
        auto result = src->start();
        if (!result) {
            ALOG(LOG_ERROR, "Start failed: %s", source_error_str(result.error));
        }
    }
}

static void avolocam_activate(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    ALOG(LOG_INFO, "Source activated");
    auto result = src->start();
    if (!result) {
        ALOG(LOG_ERROR, "Start failed: %s", source_error_str(result.error));
    }
}

static void avolocam_deactivate(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    ALOG(LOG_INFO, "Source deactivated (keeping decoder running for fast switching)");
    // Don't stop the decoder here - keep it running for instant scene switching
    // The decoder will be stopped when the source is destroyed
    (void)src;
}

static void avolocam_show(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    src->visible.store(true);
    ALOG(LOG_INFO, "Source shown");
}

static void avolocam_hide(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    src->visible.store(false);
    ALOG(LOG_INFO, "Source hidden");
}

// Callback to auto-fill IP when camera is selected from dropdown
// Port is ALWAYS visible since it must be set manually per Tauri assignment
static bool camera_select_changed(obs_properties_t *props, obs_property_t *,
                                   obs_data_t *settings)
{
    const char *selected = obs_data_get_string(settings, PROP_CAMERA_SELECT);

    // Auto-fill the IP field if a camera was selected
    if (selected && selected[0] != '\0') {
        obs_data_set_string(settings, PROP_MANUAL_IP, selected);
    }

    // IP and Port fields are ALWAYS visible
    // - IP is auto-filled from dropdown but can be edited
    // - Port must always be set manually to match Tauri Controller assignment
    (void)props;  // Fields always visible, no need to modify

    return true;  // Refresh properties UI
}

// Callback to check port collision when user changes port value
static bool port_changed_callback(void *priv, obs_properties_t *props,
                                   obs_property_t *, obs_data_t *settings)
{
    uint16_t port = (uint16_t)obs_data_get_int(settings, PROP_MANUAL_PORT);
    obs_property_t *warning = obs_properties_get(props, PROP_PORT_WARNING);
    if (!warning) return false;

    // Exclude this source's own currently-bound port from collision check
    auto *src = static_cast<SourceData *>(priv);
    uint16_t own_port = (src && src->running.load()) ? src->config.camera_port.load() : 0;

    bool collision = false;
    if (port > 0) {
        std::lock_guard<std::mutex> lock(g_ports_mutex);
        collision = g_bound_ports.count(port) > 0 && port != own_port;
    }

    obs_property_set_visible(warning, collision);
    return true;  // Refresh properties UI
}

static obs_properties_t *avolocam_get_properties(void *data)
{
    obs_properties_t *props = obs_properties_create();

    // Camera selection dropdown (populated by mDNS discovery)
    obs_property_t *camera_list = obs_properties_add_list(
        props, PROP_CAMERA_SELECT, "Camera",
        OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
    obs_property_list_add_string(camera_list, "(Manual Entry)", "");

    // Add discovered cameras from global discovery
    // Note: Only store IP, NOT port - port is assigned by Tauri Controller per-camera
    {
        std::lock_guard<std::mutex> lock(g_discovery_mutex);
        if (g_discovery) {
            for (const auto& cam : g_discovery->get_cameras()) {
                std::string label = cam.alias.empty() ? cam.name : cam.alias;
                label += " (" + cam.ip + ")";
                // Store only IP - user must set port manually to match Tauri assignment
                obs_property_list_add_string(camera_list, label.c_str(), cam.ip.c_str());
            }
        }
    }

    // Set callback to auto-fill IP when camera is selected
    obs_property_set_modified_callback(camera_list, camera_select_changed);

    // Camera IP - auto-filled from dropdown but editable
    obs_property_t *ip_prop = obs_properties_add_text(props, PROP_MANUAL_IP, "Camera IP",
                            OBS_TEXT_DEFAULT);
    obs_property_set_visible(ip_prop, true);

    // UDP Port - must match the port configured in Tauri Controller
    obs_property_t *port_prop = obs_properties_add_int(props, PROP_MANUAL_PORT, "UDP Port",
                           1024, 65535, 1);
    obs_property_set_visible(port_prop, true);
    obs_property_set_long_description(port_prop,
        "Must match the port assigned by Tauri Controller (5000 for first camera, 5001 for second, etc.)");
    obs_property_set_modified_callback2(port_prop, port_changed_callback, data);

    // Port collision warning (hidden by default, shown by port_changed_callback)
    obs_property_t *port_warn = obs_properties_add_text(props, PROP_PORT_WARNING,
        "WARNING: This port is already in use by another AvoCam source!",
        OBS_TEXT_INFO);
    obs_property_set_visible(port_warn, false);

    // Authentication token
    obs_properties_add_text(props, PROP_AUTH_TOKEN, "Auth Token",
                            OBS_TEXT_PASSWORD);

    // Jitter buffer mode
    obs_property_t *jitter = obs_properties_add_list(
        props, PROP_JITTER_MODE, "Jitter Buffer",
        OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(jitter, "Ultra-Low (0-8ms)", JITTER_ULTRA_LOW);
    obs_property_list_add_int(jitter, "Stable (16-50ms)", JITTER_STABLE);

    // Show latency overlay
    obs_properties_add_bool(props, PROP_SHOW_LATENCY, "Show Latency Overlay");

    // GPU zero-copy option
    obs_properties_add_bool(props, PROP_PREFER_ZERO_COPY,
                            "Prefer GPU Zero-Copy (requires compatible GPU)");

    // Decoder type selection
    obs_property_t *decoder = obs_properties_add_list(
        props, PROP_DECODER_TYPE, "Decoder",
        OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(decoder, "Auto (Recommended)", DECODER_TYPE_AUTO);
    obs_property_list_add_int(decoder, "Media Foundation (D3D11VA)", DECODER_TYPE_MEDIA_FOUNDATION);
#ifdef HAVE_FFMPEG_D3D11VA
    obs_property_list_add_int(decoder, "FFmpeg D3D11VA (Low Latency)", DECODER_TYPE_FFMPEG_D3D11VA);
#endif
    obs_property_set_long_description(decoder,
        "Decoder selection:\n"
        "- Auto: Uses Media Foundation (proven stable)\n"
        "- Media Foundation: Windows built-in hardware decoder\n"
        "- FFmpeg D3D11VA: Alternative low-latency decoder (experimental)");

    // Debug mode
    obs_properties_add_bool(props, PROP_DEBUG_MODE, "Enable debug logging");

    return props;
}

static void avolocam_get_defaults(obs_data_t *settings)
{
    obs_data_set_default_string(settings, PROP_MANUAL_IP, "");
    obs_data_set_default_int(settings, PROP_MANUAL_PORT, 5000);
    obs_data_set_default_int(settings, PROP_JITTER_MODE, JITTER_STABLE);
    obs_data_set_default_bool(settings, PROP_SHOW_LATENCY, false);
    obs_data_set_default_string(settings, PROP_AUTH_TOKEN, "");
    obs_data_set_default_bool(settings, PROP_PREFER_ZERO_COPY, true);
    obs_data_set_default_bool(settings, PROP_DEBUG_MODE, false);
    obs_data_set_default_int(settings, PROP_DECODER_TYPE, DECODER_TYPE_AUTO);
}

// video_tick: open/update shared texture for CUSTOM_DRAW (called on render thread)
static void avolocam_video_tick(void *data, float seconds)
{
    UNUSED_PARAMETER(seconds);
    auto *src = static_cast<SourceData *>(data);

    // Cache source name once per tick (avoid repeated obs_source_get_name calls)
    const char *name_ptr = obs_source_get_name(src->source);
    std::string cur_name = name_ptr ? name_ptr : "";

    // Snapshot camera_ip under lock for test pattern comparison
    std::string ip_snapshot;
    {
        std::lock_guard<std::mutex> lock(src->config.mutex);
        ip_snapshot = src->config.camera_ip;
    }

    // Invalidate test pattern if camera IP or source name changed
    if (src->test_pattern.created &&
        (ip_snapshot != src->test_pattern.baked_ip || cur_name != src->test_pattern.baked_name)) {
        obs_enter_graphics();
        if (src->test_pattern.texture) {
            gs_texture_destroy(src->test_pattern.texture);
            src->test_pattern.texture = nullptr;
        }
        obs_leave_graphics();
        src->test_pattern.created = false;
    }

    // Lazy-init test pattern texture (on graphics thread)
    if (!src->test_pattern.created) {
        ALOG(LOG_INFO, "Creating test pattern texture %ux%u (name='%s', ip='%s')",
             SourceData::TestPattern::WIDTH, SourceData::TestPattern::HEIGHT,
             cur_name.c_str(), ip_snapshot.c_str());
        auto pixels = generate_test_pattern_rgba(
            SourceData::TestPattern::WIDTH, SourceData::TestPattern::HEIGHT,
            cur_name, ip_snapshot);
        const uint8_t *ptr = pixels.data();
        obs_enter_graphics();
        src->test_pattern.texture = gs_texture_create(
            SourceData::TestPattern::WIDTH, SourceData::TestPattern::HEIGHT,
            GS_RGBA, 1, &ptr, 0);
        obs_leave_graphics();
        src->test_pattern.created = true;
        src->test_pattern.baked_ip = ip_snapshot;
        src->test_pattern.baked_name = cur_name;
        ALOG(LOG_INFO, "Test pattern texture %s",
             src->test_pattern.texture ? "created OK" : "FAILED");
    }

    if (src->gpu.use_gpu_render.load()) {
        // GPU PATH: open the shared RGBA texture on OBS device (cached)
        void *h = src->gpu.latest_shared_handle.load(std::memory_order_acquire);
        if (h && h != src->gpu.cached_shared_handle) {
            obs_enter_graphics();
            if (src->gpu.obs_shared_texture) {
                gs_texture_destroy(src->gpu.obs_shared_texture);
                src->gpu.obs_shared_texture = nullptr;
            }
            // Legacy DXGI shared handles (D3D11_RESOURCE_MISC_SHARED) are
            // kernel object indices that fit in 32 bits even on x64.
            // gs_texture_open_shared() takes uint32_t matching this convention.
            src->gpu.obs_shared_texture = gs_texture_open_shared(
                static_cast<uint32_t>(reinterpret_cast<uintptr_t>(h)));
            obs_leave_graphics();

            if (src->gpu.obs_shared_texture) {
                src->gpu.cached_shared_handle = h;
            } else {
                ALOG(LOG_WARNING, "gs_texture_open_shared failed for handle %p", h);
            }
        }
    } else {
        // CPU FALLBACK: upload NV12 frame data into a BGRX texture
        SourceData::DecodeQueue::Frame *frame = src->decode_queue.latest.load(std::memory_order_acquire);
        if (frame && frame->valid) {
            // CPU fallback uses ASYNC_VIDEO mode via obs_source_output_video
            // (called in decode_frame_async), so no texture upload is needed here.
        }
    }
}

// video_render: draw the GPU or CPU texture (called on render thread)
static void avolocam_video_render(void *data, gs_effect_t *effect)
{
    UNUSED_PARAMETER(effect);
    auto *src = static_cast<SourceData *>(data);

    // GPU path: camera frame available via shared texture
    if (src->gpu.use_gpu_render.load() && src->gpu.obs_shared_texture) {
        effect = obs_get_base_effect(OBS_EFFECT_OPAQUE);
        while (gs_effect_loop(effect, "Draw")) {
            obs_source_draw(src->gpu.obs_shared_texture, 0, 0, 0, 0, false);
        }
        return;
    }

    // CPU path: OBS ASYNC_VIDEO renders if a frame has been submitted
    SourceData::DecodeQueue::Frame *frame = src->decode_queue.latest.load(std::memory_order_acquire);
    if (frame && frame->valid)
        return;

    // No camera frame available — draw the "NO SIGNAL" test pattern
    if (src->test_pattern.texture) {
        effect = obs_get_base_effect(OBS_EFFECT_OPAQUE);
        while (gs_effect_loop(effect, "Draw")) {
            obs_source_draw(src->test_pattern.texture, 0, 0, 0, 0, false);
        }
    }
}

static uint32_t avolocam_get_width(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    uint32_t w = src->gpu.texture_width.load(std::memory_order_relaxed);
    if (w > 0)
        return w;
    if (src->pipeline.decoder) {
        w = src->pipeline.decoder->get_width();
        if (w > 0) return w;
    }
    return SourceData::TestPattern::WIDTH;
}

static uint32_t avolocam_get_height(void *data)
{
    auto *src = static_cast<SourceData *>(data);
    uint32_t h = src->gpu.texture_height.load(std::memory_order_relaxed);
    if (h > 0)
        return h;
    if (src->pipeline.decoder) {
        h = src->pipeline.decoder->get_height();
        if (h > 0) return h;
    }
    return SourceData::TestPattern::HEIGHT;
}

} // namespace avolocam

// ============================================================================
// Public API
// ============================================================================

void avolocam_source_register(void)
{
    // Start global mDNS discovery
    {
        std::lock_guard<std::mutex> lock(avolocam::g_discovery_mutex);
        avolocam::g_discovery = std::make_unique<avolocam::MdnsDiscovery>();
        if (avolocam::g_discovery->start([](avolocam::DiscoveryEvent event, const avolocam::DiscoveredCamera& cam) {
            const char* event_str = (event == avolocam::DiscoveryEvent::Added) ? "discovered" :
                                    (event == avolocam::DiscoveryEvent::Updated) ? "updated" : "removed";
            ALOG(LOG_INFO, "Camera %s: %s (%s:%d)",
                 event_str, cam.alias.c_str(), cam.ip.c_str(), cam.flash_udp_port);
        })) {
            ALOG(LOG_INFO, "mDNS discovery started");
        } else {
            ALOG(LOG_WARNING, "Failed to start mDNS discovery");
        }
    }

    struct obs_source_info info = {};

    info.id = "avolocam_source";
    info.type = OBS_SOURCE_TYPE_INPUT;
    // CUSTOM_DRAW + ASYNC_VIDEO: GPU zero-copy when available, CPU async fallback
    info.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_VIDEO
                      | OBS_SOURCE_CUSTOM_DRAW;
    info.get_name = avolocam::avolocam_get_name;
    info.create = avolocam::avolocam_create;
    info.destroy = avolocam::avolocam_destroy;
    info.update = avolocam::avolocam_update;
    info.activate = avolocam::avolocam_activate;
    info.deactivate = avolocam::avolocam_deactivate;
    info.show = avolocam::avolocam_show;
    info.hide = avolocam::avolocam_hide;
    info.get_properties = avolocam::avolocam_get_properties;
    info.get_defaults = avolocam::avolocam_get_defaults;
    info.video_tick = avolocam::avolocam_video_tick;
    info.video_render = avolocam::avolocam_video_render;
    info.get_width = avolocam::avolocam_get_width;
    info.get_height = avolocam::avolocam_get_height;

    obs_register_source(&info);
    ALOG(LOG_INFO, "Source type registered");
}
