#include <CFNetwork/CFNetwork.h>
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>

static void check(CFStringRef address, CFDictionaryRef settings, CFStringRef expected) {
  CFURLRef url=CFURLCreateWithString(NULL,address,NULL);
  CFArrayRef result=CFNetworkCopyProxiesForURL(url,settings);
  assert(result && CFArrayGetCount(result)==1);
  CFDictionaryRef first=CFArrayGetValueAtIndex(result,0);
  if (!CFEqual(CFDictionaryGetValue(first,kCFProxyTypeKey),expected)) {
    fputs("FAIL: proxy decision changed outside the exact private HTTPS8082 scope\n",stderr);
    exit(1);
  }
  CFRelease(result);CFRelease(url);
}

int main(int argc,char **argv) {
  assert(argc==2);
  CFMutableDictionaryRef settings=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  int port=18080;
  CFNumberRef number=CFNumberCreate(NULL,kCFNumberIntType,&port);
  CFDictionarySetValue(settings,kCFNetworkProxiesHTTPSEnable,kCFBooleanTrue);
  CFDictionarySetValue(settings,kCFNetworkProxiesHTTPSProxy,CFSTR("127.0.0.1"));
  CFDictionarySetValue(settings,kCFNetworkProxiesHTTPSPort,number);
  CFDictionarySetValue(settings,kCFNetworkProxiesHTTPEnable,kCFBooleanTrue);
  CFDictionarySetValue(settings,kCFNetworkProxiesHTTPProxy,CFSTR("127.0.0.1"));
  CFDictionarySetValue(settings,kCFNetworkProxiesHTTPPort,number);
  CFRelease(number);
  const void *except[]={CFSTR("existing.example")};
  CFArrayRef exceptions=CFArrayCreate(NULL,except,1,&kCFTypeArrayCallBacks);
  CFDictionarySetValue(settings,kCFNetworkProxiesExceptionsList,exceptions);CFRelease(exceptions);
  CFDictionaryRef original=CFDictionaryCreateCopy(NULL,settings);
  CFStringRef expected=atoi(argv[1]) ? kCFProxyTypeNone : kCFProxyTypeHTTPS;
  check(CFSTR("https://algalon.actual.battle.net:8082/bnetserver/login/"),settings,expected);
  check(CFSTR("https://ALGALON.ACTUAL.BATTLE.NET:8082/"),settings,expected);
  check(CFSTR("https://algalon.actual.battle.net:443/"),settings,kCFProxyTypeHTTPS);
  check(CFSTR("https://algalon.actual.battle.net/"),settings,kCFProxyTypeHTTPS);
  check(CFSTR("https://algalon.actual.battle.net:1120/"),settings,kCFProxyTypeHTTPS);
  check(CFSTR("https://algalon.actual.battle.net:8443/"),settings,kCFProxyTypeHTTPS);
  check(CFSTR("https://algalon.actual.battle.net.:8082/"),settings,kCFProxyTypeHTTPS);
  check(CFSTR("https://other.example/"),settings,kCFProxyTypeHTTPS);
  check(CFSTR("https://algalon.actual.battle.net.evil.example/"),settings,kCFProxyTypeHTTPS);
  check(CFSTR("https://existing.example/"),settings,kCFProxyTypeNone);
  check(CFSTR("http://algalon.actual.battle.net/"),settings,kCFProxyTypeHTTP);
  assert(CFEqual(settings,original));
  CFRelease(original);CFRelease(settings);
  puts("PASS: exact private HTTPS8082 proxy exception; other ports, hosts, schemes, trailing-dot host, caller settings and existing exceptions preserved");
  return 0;
}
