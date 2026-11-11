#pragma once
#include <stdbool.h>
typedef void (*TapFrameHandler)(double, int, const float *, int);
int tap_scan(void);
const char *tap_device_name(int index);
bool tap_device_is_mouse(int index);
bool tap_device_is_trackpad(int index);
int tap_start(TapFrameHandler handler, int index);
void tap_stop(void);
const char *tap_error(void);
