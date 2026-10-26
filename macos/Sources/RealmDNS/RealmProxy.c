#include <CFNetwork/CFNetwork.h>
#include <errno.h>
#include <stdio.h>
#include <stdatomic.h>
#include "RealmScope.h"

static CFArrayRef realmProxies(CFURLRef url, CFDictionaryRef settings) {
  int saved = errno;
  CFStringRef host = url ? CFURLCopyHostName(url) : NULL;
  CFStringRef scheme = url ? CFURLCopyScheme(url) : NULL;
  int realm = host && scheme && CFURLGetPortNumber(url)==8082
      && CFStringCompare(scheme,CFSTR("https"),kCFCompareCaseInsensitive)==kCFCompareEqualTo
      && CFStringCompare(host,CFSTR(REALM_HOST),kCFCompareCaseInsensitive)==kCFCompareEqualTo;
  if (host) CFRelease(host);
  if (scheme) CFRelease(scheme);
  CFMutableDictionaryRef scoped = NULL;
  if (realm && settings && realmPrivateProcess() && realmServerIPv4()) {
    CFTypeRef existing = CFDictionaryGetValue(settings,kCFNetworkProxiesExceptionsList);
    if (!existing || (CFGetTypeID(existing)==CFArrayGetTypeID() && CFArrayGetCount(existing)<4096)) {
      CFMutableArrayRef exceptions = existing ? CFArrayCreateMutableCopy(NULL,0,existing) :
          CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
      if (exceptions) {
        CFArrayAppendValue(exceptions,CFSTR(REALM_HOST));
        scoped = CFDictionaryCreateMutableCopy(NULL,0,settings);
        if (scoped) CFDictionarySetValue(scoped,kCFNetworkProxiesExceptionsList,exceptions);
        CFRelease(exceptions);
      }
    }
  }
  errno = saved;
  CFArrayRef result = CFNetworkCopyProxiesForURL(url,scoped ? scoped : settings);
  saved = errno;
  if (scoped) {
    static atomic_flag logged = ATOMIC_FLAG_INIT;
    if (!atomic_flag_test_and_set(&logged))
      fputs("[Forever proxy] exact realm HTTPS exception applied only inside private process\n",stderr);
    CFRelease(scoped);
  }
  errno = saved;
  return result;
}

__attribute__((used,section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } realm_proxy = {
  (const void *)&realmProxies,(const void *)&CFNetworkCopyProxiesForURL
};
