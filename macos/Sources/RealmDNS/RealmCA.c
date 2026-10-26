#include <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "RealmScope.h"

static SecCertificateRef realm_certificate;
static pthread_once_t certificate_once = PTHREAD_ONCE_INIT;
static _Thread_local int loading_certificate;

static int realmFingerprint(SecCertificateRef certificate) {
  static const unsigned char expected[CC_SHA256_DIGEST_LENGTH] = REALM_CA_SHA256_BYTES;
  CFDataRef der = SecCertificateCopyData(certificate);
  if (!der) return 0;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CFIndex size = CFDataGetLength(der);
  int matches = size > 0 && size <= 16384 && CC_SHA256(CFDataGetBytePtr(der), (CC_LONG)size, digest)
      && !memcmp(digest, expected, sizeof(expected));
  CFRelease(der);
  return matches;
}

static int realmTrustConfigured(CFArrayRef settings) {
  if (!settings || CFGetTypeID(settings) != CFArrayGetTypeID()) return 0;
  int trusted = 0;
  if (CFArrayGetCount(settings) == 1) {
    CFTypeRef value = CFArrayGetValueAtIndex(settings, 0);
    if (value && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
      CFDictionaryRef setting = value;
      CFTypeRef host = CFDictionaryGetValue(setting, kSecTrustSettingsPolicyString);
      CFTypeRef policy = CFDictionaryGetValue(setting, kSecTrustSettingsPolicy);
      CFTypeRef result = CFDictionaryGetValue(setting, kSecTrustSettingsResult);
      int32_t decision = kSecTrustSettingsResultTrustRoot;
      int valid_result = !result || (CFGetTypeID(result) == CFNumberGetTypeID()
          && CFNumberGetValue(result, kCFNumberSInt32Type, &decision));
      if (host && CFEqual(host, CFSTR(REALM_HOST))
          && policy && CFGetTypeID(policy) == SecPolicyGetTypeID()
          && !CFDictionaryContainsKey(setting, kSecTrustSettingsApplication)
          && !CFDictionaryContainsKey(setting, kSecTrustSettingsAllowedError)
          && valid_result && decision == kSecTrustSettingsResultTrustRoot) {
        CFDictionaryRef properties = SecPolicyCopyProperties((SecPolicyRef)policy);
        CFTypeRef oid = properties ? CFDictionaryGetValue(properties, kSecPolicyOid) : NULL;
        trusted = oid && CFEqual(oid, kSecPolicyAppleSSL);
        if (properties) CFRelease(properties);
      }
    }
  }
  return trusted;
}

static int scopedUserTrust(SecCertificateRef certificate) {
  CFArrayRef settings = NULL;
  OSStatus status = SecTrustSettingsCopyTrustSettings(certificate, kSecTrustSettingsDomainUser, &settings);
  int trusted = status == errSecSuccess && realmTrustConfigured(settings);
  if (settings) CFRelease(settings);
  return trusted;
}

__attribute__((visibility("hidden"))) int realmPrivateProcess(void) {
  char path[PROC_PIDPATHINFO_MAXSIZE], actual[PATH_MAX], expected[PATH_MAX];
  const char suffix[] = REALM_PRIVATE_SUFFIX;
  const char *selected = getenv("FOREVER_PRIVATE_EXECUTABLE");
  if (!selected || selected[0] != '/' || !realpath(selected, expected)
      || proc_pidpath(getpid(), path, sizeof(path)) <= 0 || !realpath(path, actual)) return 0;
  size_t length = strlen(expected);
  return length >= sizeof(suffix)-1
      && !strcmp(expected + length - (sizeof(suffix)-1), suffix) && !strcmp(actual, expected);
}

const char *realmServerIPv4(void) {
  struct in_addr address;
  const char *realm_ip = getenv("FOREVER_SERVER_IPV4");
  return realm_ip && inet_pton(AF_INET, realm_ip, &address) == 1 ? realm_ip : NULL;
}

static void loadRealmCertificate(void) {
  if (!realmPrivateProcess() || !realmServerIPv4()) return;

  const void *keys[] = {kSecClass,kSecAttrLabel,kSecMatchLimit,kSecReturnRef};
  const void *values[] = {kSecClassCertificate,CFSTR(REALM_CA_LABEL),kSecMatchLimitAll,kCFBooleanTrue};
  CFDictionaryRef query = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  if (!query) return;
  CFTypeRef found = NULL;
  OSStatus status = SecItemCopyMatching(query, &found);
  CFRelease(query);
  if (status == errSecSuccess && found && CFGetTypeID(found) == CFArrayGetTypeID()
      && CFArrayGetCount(found) <= 32) {
    for (CFIndex i = 0; i < CFArrayGetCount(found); ++i) {
      CFTypeRef value = CFArrayGetValueAtIndex(found, i);
      if (value && CFGetTypeID(value) == SecCertificateGetTypeID()
          && realmFingerprint((SecCertificateRef)value) && scopedUserTrust((SecCertificateRef)value)) {
        realm_certificate = (SecCertificateRef)CFRetain(value);
        break;
      }
    }
  }
  if (found) CFRelease(found);
}

static int realmCertificateQuery(CFDictionaryRef query) {
  if (CFDictionaryGetCount(query) != 5) return 0;
  CFTypeRef kind = CFDictionaryGetValue(query,kSecClass);
  CFTypeRef limit = CFDictionaryGetValue(query,kSecMatchLimit);
  CFTypeRef refs = CFDictionaryGetValue(query,kSecReturnRef);
  CFTypeRef trusted = CFDictionaryGetValue(query,kSecMatchTrustedOnly);
  CFTypeRef policy = CFDictionaryGetValue(query,kSecMatchPolicy);
  if (!kind || !CFEqual(kind,kSecClassCertificate) || !limit || !CFEqual(limit,kSecMatchLimitAll)
      || !refs || !CFEqual(refs,kCFBooleanTrue) || !trusted || !CFEqual(trusted,kCFBooleanTrue)
      || CFDictionaryContainsKey(query,kSecMatchSearchList)
      || !policy || CFGetTypeID(policy) != SecPolicyGetTypeID()) return 0;
  CFDictionaryRef properties = SecPolicyCopyProperties((SecPolicyRef)policy);
  if (!properties) return 0;
  CFTypeRef oid = CFDictionaryGetValue(properties,kSecPolicyOid);
  CFTypeRef client = CFDictionaryGetValue(properties,kSecPolicyClient);
  int matches = oid && CFEqual(oid,kSecPolicyAppleSSL)
      && !CFDictionaryContainsKey(properties,kSecPolicyName)
      && (!client || CFEqual(client,kCFBooleanFalse));
  CFRelease(properties);
  return matches;
}

static OSStatus realmItems(CFDictionaryRef query, CFTypeRef *result) {
  OSStatus status = SecItemCopyMatching(query,result);
  int saved = errno;
  if (loading_certificate || status != errSecSuccess || !query || !result || !*result
      || CFGetTypeID(*result) != CFArrayGetTypeID() || !realmCertificateQuery(query)) {
    errno = saved;
    return status;
  }
  loading_certificate = 1;
  pthread_once(&certificate_once,loadRealmCertificate);
  if (realm_certificate && CFArrayGetCount(*result) <= 4096) {
    int contains = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(*result); ++i) {
      CFTypeRef value = CFArrayGetValueAtIndex(*result,i);
      if (!value || CFGetTypeID(value) != SecCertificateGetTypeID()) { contains = 1; break; }
      if (CFEqual(value,realm_certificate)) { contains = 1; break; }
    }
    if (!contains) {
      CFMutableArrayRef certificates = CFArrayCreateMutableCopy(NULL,0,*result);
      if (certificates) {
        CFArrayAppendValue(certificates,realm_certificate);
        fprintf(stderr,"[Forever trust] appended existing scoped realm CA; preserved %ld original certificates\n",CFArrayGetCount(*result));
        CFRelease(*result);
        *result = certificates;
      }
    }
  }
  loading_certificate = 0;
  errno = saved;
  return status;
}

__attribute__((used,section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } realm_ca_items = {
  (const void *)&realmItems,(const void *)&SecItemCopyMatching
};
