/**
 * avolocam-source.h - OBS source definition for AvoCam
 */

#pragma once

#include <obs-module.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Register the AvoCam source type with OBS
 */
void avolocam_source_register(void);

#ifdef __cplusplus
}
#endif
