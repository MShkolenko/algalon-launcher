#include <assert.h>
#include "../Sources/RealmDNS/RealmCA.c"

static CFMutableDictionaryRef setting(void) {
  CFMutableDictionaryRef value = CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  SecPolicyRef policy = SecPolicyCreateSSL(true,NULL);
  assert(value && policy);
  CFDictionarySetValue(value,kSecTrustSettingsPolicy,policy);
  CFDictionarySetValue(value,kSecTrustSettingsPolicyString,CFSTR("algalon.actual.battle.net"));
  CFRelease(policy);
  return value;
}

static int admitted(CFTypeRef value) {
  CFArrayRef settings = CFArrayCreate(NULL,&value,1,&kCFTypeArrayCallBacks);
  assert(settings);
  int result = realmTrustConfigured(settings);
  CFRelease(settings);
  return result;
}

int main(void) {
  CFMutableDictionaryRef value = setting();
  assert(admitted(value));
  int32_t root = kSecTrustSettingsResultTrustRoot;
  CFNumberRef decision = CFNumberCreate(NULL,kCFNumberSInt32Type,&root);
  CFDictionarySetValue(value,kSecTrustSettingsResult,decision);
  assert(admitted(value));
  CFRelease(decision);
  int32_t other[] = {kSecTrustSettingsResultDeny,kSecTrustSettingsResultUnspecified,kSecTrustSettingsResultTrustAsRoot,99};
  for (unsigned i=0;i<sizeof(other)/sizeof(other[0]);++i) {
    decision = CFNumberCreate(NULL,kCFNumberSInt32Type,&other[i]);
    CFDictionarySetValue(value,kSecTrustSettingsResult,decision);
    assert(!admitted(value)); CFRelease(decision);
  }
  CFDictionarySetValue(value,kSecTrustSettingsResult,CFSTR("1")); assert(!admitted(value));
  CFDictionaryRemoveValue(value,kSecTrustSettingsResult);
  CFDictionarySetValue(value,kSecTrustSettingsPolicyString,CFSTR("wrong.example")); assert(!admitted(value));
  CFDictionaryRemoveValue(value,kSecTrustSettingsPolicyString); assert(!admitted(value));
  CFDictionarySetValue(value,kSecTrustSettingsPolicyString,CFSTR("algalon.actual.battle.net"));
  CFDictionarySetValue(value,kSecTrustSettingsAllowedError,CFSTR("exception")); assert(!admitted(value));
  CFDictionaryRemoveValue(value,kSecTrustSettingsAllowedError);
  CFDictionarySetValue(value,kSecTrustSettingsApplication,CFSTR("application")); assert(!admitted(value));
  CFDictionaryRemoveValue(value,kSecTrustSettingsApplication);
  SecPolicyRef basic = SecPolicyCreateBasicX509();
  CFDictionarySetValue(value,kSecTrustSettingsPolicy,basic); assert(!admitted(value)); CFRelease(basic);
  CFDictionaryRemoveValue(value,kSecTrustSettingsPolicy); assert(!admitted(value));
  assert(!admitted(CFSTR("not a setting")));
  CFArrayRef empty = CFArrayCreate(NULL,NULL,0,&kCFTypeArrayCallBacks);
  assert(!realmTrustConfigured(empty)); CFRelease(empty);
  CFRelease(value);
  value = setting();
  const void *two[] = {value,value};
  CFArrayRef multiple = CFArrayCreate(NULL,two,2,&kCFTypeArrayCallBacks);
  assert(!realmTrustConfigured(multiple)); CFRelease(multiple); CFRelease(value);
  puts("PASS: exact realm SSL trust profile; deny, broad, unrelated, malformed and exception settings rejected without OS mutation");
  return 0;
}
