#pragma once
#include <obs-module.h>

// Main source
#define ALOG(level, fmt, ...) blog(level, "[avolocam] " fmt, ##__VA_ARGS__)

// Sub-component prefixes
#define ALOG_WS(level, fmt, ...) blog(level, "[avolocam-ws] " fmt, ##__VA_ARGS__)
#define ALOG_FFMPEG(level, fmt, ...) \
	blog(level, "[avolocam-ffmpeg] " fmt, ##__VA_ARGS__)
#define ALOG_MF(level, fmt, ...) \
	blog(level, "[avolocam-mf] " fmt, ##__VA_ARGS__)
#define ALOG_GPU(level, fmt, ...) \
	blog(level, "[avolocam-gpu] " fmt, ##__VA_ARGS__)
#define ALOG_MDNS(level, fmt, ...) \
	blog(level, "[avolocam-mdns] " fmt, ##__VA_ARGS__)
#define ALOG_TEX(level, fmt, ...) \
	blog(level, "[avolocam-tex] " fmt, ##__VA_ARGS__)
