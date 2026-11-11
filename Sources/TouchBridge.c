#include "TouchBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#include <stdint.h>
// Undocumented MultitouchSupport contact ABI. Requires runtime verification on new macOS versions.
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } Readout;
typedef struct {
 int frame; double timestamp; int identifier, state, unknown1, unknown2;
 Readout normalized; float size; int unknown3; float angle, majorAxis, minorAxis;
 Readout mm; int unknown4, unknown5; float unknown6;
} Contact;
_Static_assert(sizeof(Contact)==96, "Unexpected contact layout");
typedef void *Device;
typedef int (*ContactCallback)(Device, Contact *, int, double, int);
static void *library;
static CFArrayRef devices;
static CFArrayRef (*createList)(void);
static io_service_t (*getService)(Device);
static void (*registerCallback)(Device, ContactCallback);
static void (*unregisterCallback)(Device, ContactCallback);
static void (*startDevice)(Device, int);
static void (*stopDevice)(Device);
static TapFrameHandler handler;
static bool running[64];
static char names[64][256];
static bool mice[64];
static bool trackpads[64];
static int count;
static _Atomic(uintptr_t) activeDevice;
static _Atomic(int) activeIndex;
static char errorText[256];
static int onContact(Device device, Contact *contacts, int n, double timestamp, int frame) {
 (void)frame;
 if(atomic_load(&activeDevice)!=(uintptr_t)device)return 0;
 int index=atomic_load(&activeIndex);
 if(!handler || n<0 || n>32 || (n>0 && !contacts))return 0;
 float positions[64]; int active=0;
 for(int i=0;i<n;i++) {
  if(contacts[i].state!=3 && contacts[i].state!=4)continue;
  positions[active*2]=contacts[i].normalized.position.x;
  positions[active*2+1]=contacts[i].normalized.position.y;
  active++;
 }
 handler(timestamp,active,positions,index); return 0;
}
static bool load(void) {
 if(library)return true;
 library=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
 if(!library){snprintf(errorText,sizeof(errorText),"MultitouchSupport unavailable");return false;}
 createList=dlsym(library,"MTDeviceCreateList");getService=dlsym(library,"MTDeviceGetService");
 registerCallback=dlsym(library,"MTRegisterContactFrameCallback");unregisterCallback=dlsym(library,"MTUnregisterContactFrameCallback");
 startDevice=dlsym(library,"MTDeviceStart");stopDevice=dlsym(library,"MTDeviceStop");
 if(!createList || !getService || !registerCallback || !unregisterCallback || !startDevice || !stopDevice){
  snprintf(errorText,sizeof(errorText),"Required multitouch API unavailable");dlclose(library);library=NULL;return false;
 }
 return true;
}
void tap_stop(void) {
 atomic_store(&activeDevice,0);
 for(int i=0;i<count;i++)if(running[i]){
  Device d=(Device)CFArrayGetValueAtIndex(devices,i);
  stopDevice(d);unregisterCallback(d,onContact);running[i]=false;
 }
 // Keep handler valid for any callback already in flight; Swift serializes delivery on the main queue.
}
int tap_scan(void) {
 tap_stop(); if(devices){CFRelease(devices);devices=NULL;} count=0;errorText[0]=0;
 if(!load())return 0;
 devices=createList(); if(!devices)return 0;
 count=(int)CFArrayGetCount(devices);if(count>64)count=64;
 for(int i=0;i<count;i++){
  names[i][0]=0;mice[i]=false;trackpads[i]=false;
  io_service_t s=getService((Device)CFArrayGetValueAtIndex(devices,i));
  CFTypeRef product=s?IORegistryEntrySearchCFProperty(s,kIOServicePlane,CFSTR("Product"),kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents):NULL;
  if(product && CFGetTypeID(product)==CFStringGetTypeID()){
   CFStringGetCString(product,names[i],sizeof(names[i]),kCFStringEncodingUTF8);
   mice[i]=CFStringFind(product,CFSTR("Magic Mouse"),kCFCompareCaseInsensitive).location!=kCFNotFound;
  }
  if(product && CFGetTypeID(product)==CFStringGetTypeID())
   trackpads[i]=CFStringFind(product,CFSTR("Trackpad"),kCFCompareCaseInsensitive).location!=kCFNotFound;
  if(product)CFRelease(product);
  if(!names[i][0])snprintf(names[i],sizeof(names[i]),"Unknown touch device");
 }
 return count;
}
const char *tap_device_name(int i){return i>=0 && i<count?names[i]:"";}
bool tap_device_is_mouse(int i){return i>=0 && i<count && mice[i];}
bool tap_device_is_trackpad(int i){return i>=0 && i<count && trackpads[i];}
int tap_start(TapFrameHandler callback, int selected){
 handler=callback; int started=0;
 for(int i=0;i<count;i++)if(i==selected && (mice[i] || trackpads[i]) && !running[i]){
  Device d=(Device)CFArrayGetValueAtIndex(devices,i);
  running[i]=true;atomic_store(&activeIndex,i);atomic_store(&activeDevice,(uintptr_t)d);
  registerCallback(d,onContact);startDevice(d,0);started++;
 }
 return started;
}
const char *tap_error(void){return errorText;}
