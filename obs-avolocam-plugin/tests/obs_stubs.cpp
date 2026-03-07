/**
 * obs_stubs.cpp - Minimal stubs for OBS functions used by avocam-core in tests
 *
 * Provides a no-op implementation of blog() so that components using
 * ALOG macros can link in the test binary without the full OBS library.
 */

#include <cstdarg>

extern "C" {

void blog(int /*log_level*/, const char * /*format*/, ...)
{
    // No-op in tests
}

} // extern "C"
