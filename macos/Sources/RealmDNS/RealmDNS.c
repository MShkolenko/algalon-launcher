#include <arpa/inet.h>
#include <netdb.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <errno.h>
#include <unistd.h>
#include "RealmScope.h"

// This exact realm name must stay in sync with C.hostName; other names use normal macOS resolution.
static int realm_getaddrinfo(const char *name, const char *service,
                             const struct addrinfo *hints, struct addrinfo **result) {
  int saved = errno;
  static const char host[] = REALM_HOST;
  const size_t length = sizeof(host) - 1;
  int expected = name && strncasecmp(name, host, length) == 0
      && (name[length] == '\0' || (name[length] == '.' && name[length + 1] == '\0'));
  int private_process = realmPrivateProcess();
  if (name && private_process && !expected) {
    const char suffix[] = ".actual.battle.net";
    size_t n = strlen(name), s = sizeof(suffix) - 1;
    if (n && name[n - 1] == '.') --n;
    if (n >= s && !strncasecmp(name + n - s, suffix, s)) {
      fputs("[Forever DNS] refused unexpected Battle.net login host\n", stderr);
      if (result) *result = NULL;
      errno = saved;
      return EAI_NONAME;
    }
  }
  if (expected && private_process) {
    const char *address = realmServerIPv4();
    if (!address) { errno = saved; return EAI_NONAME; }
    static atomic_flag logged = ATOMIC_FLAG_INIT;
    if (!atomic_flag_test_and_set(&logged))
      fputs("[Forever DNS] private realm address override active\n", stderr);
    errno = saved;
    return getaddrinfo(address, service, hints, result);
  }
  errno = saved;
  return getaddrinfo(name, service, hints, result);
}

// Standard dyld interposing applies only to the process loading this library.
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *substitute; const void *original; } realm_resolver = {
  (const void *)&realm_getaddrinfo, (const void *)&getaddrinfo
};

// Login ports must never reach another realm, including numeric destinations that bypass DNS.
static int realm_connect(int descriptor, const struct sockaddr *address, socklen_t size) {
  if (address && size >= sizeof(struct sockaddr) && realmPrivateProcess()) {
    uint16_t port = 0;
    const void *ipv4 = NULL;
    if (address->sa_family == AF_INET && size >= sizeof(struct sockaddr_in)) {
      const struct sockaddr_in *v4 = (const struct sockaddr_in *)address;
      port = ntohs(v4->sin_port);
      ipv4 = &v4->sin_addr;
    } else if (address->sa_family == AF_INET6 && size >= sizeof(struct sockaddr_in6)) {
      const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)address;
      port = ntohs(v6->sin6_port);
      if (IN6_IS_ADDR_V4MAPPED(&v6->sin6_addr)) ipv4 = &v6->sin6_addr.s6_addr[12];
    }
    if (port == 1119 || port == 1120) {
      struct in_addr expected;
      const char *ip = realmServerIPv4();
      if (port != 1120 || !ipv4 || !ip || inet_pton(AF_INET, ip, &expected) != 1
          || memcmp(ipv4, &expected, sizeof(expected))) {
        fputs("[Forever DNS] refused unexpected login address or port\n", stderr);
        errno = EACCES;
        return -1;
      }
    }
  }
  return connect(descriptor, address, size);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *substitute; const void *original; } realm_connector = {
  (const void *)&realm_connect, (const void *)&connect
};
