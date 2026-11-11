#pragma once
#include <stdbool.h>
typedef void (*TapFrameHandler)(double, int, const float *);
int tap_scan(void);
const char *tap_device_name(int index);
bool tap_device_is_mouse(int index);
int tap_start(TapFrameHandler handler);
void tap_stop(void);
const char *tap_error(void);
