#include <assert.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <arpa/inet.h>
#include <errno.h>

static void address_is(const char *name, const char *expected, int flags) {
  struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM, .ai_flags = flags};
  struct addrinfo *answer = NULL;
  assert(getaddrinfo(name, "1120", &hints, &answer) == 0);
  char value[NI_MAXHOST];
  assert(getnameinfo(answer->ai_addr, answer->ai_addrlen, value, sizeof(value), NULL, 0,
                     NI_NUMERICHOST) == 0);
  assert(strcmp(value, expected) == 0);
  freeaddrinfo(answer);
}

static void numeric_rejects(const char *name) {
  struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM, .ai_flags = AI_NUMERICHOST};
  struct addrinfo *answer = NULL;
  if (getaddrinfo(name, "1120", &hints, &answer) != EAI_NONAME || answer) {
    fputs("FAIL: DNS override escaped its private process/host/validated-address scope\n",stderr);
    exit(1);
  }
}

int main(int argc, char **argv) {
  assert(argc == 2);
  setenv("FOREVER_SERVER_IPV4", "203.0.113.7", 1);
  struct sockaddr_in destination = {.sin_len = sizeof(destination), .sin_family = AF_INET};
  for (int correct_address = 0; correct_address <= 1; ++correct_address) {
    assert(inet_pton(AF_INET, correct_address ? "203.0.113.7" : "192.0.2.9",
                     &destination.sin_addr) == 1);
    for (int port = 1119; port <= 1120; ++port) {
      destination.sin_port = htons(port);
      errno = 0;
      assert(connect(-1, (const struct sockaddr *)&destination, sizeof(destination)) == -1);
      assert(errno == (atoi(argv[1]) && (!correct_address || port != 1120) ? EACCES : EBADF));
    }
  }
  struct sockaddr_in6 v6 = {.sin6_len = sizeof(v6), .sin6_family = AF_INET6,
                            .sin6_port = htons(1120)};
  for (int mapped = 0; mapped <= 1; ++mapped) {
    assert(inet_pton(AF_INET6, mapped ? "::ffff:203.0.113.7" : "::1", &v6.sin6_addr) == 1);
    errno = 0;
    assert(connect(-1, (const struct sockaddr *)&v6, sizeof(v6)) == -1);
    assert(errno == (atoi(argv[1]) && !mapped ? EACCES : EBADF));
  }
  destination.sin_port = htons(443);
  errno = 0;
  assert(connect(-1, (const struct sockaddr *)&destination, sizeof(destination)) == -1);
  assert(errno == EBADF);
  puts("PASS: login transport admits only the selected realm1120 inside the private process");
  if (atoi(argv[1])) {
    address_is("algalon.actual.battle.net", "203.0.113.7", AI_NUMERICHOST);
    address_is("ALGALON.actual.battle.net.", "203.0.113.7", AI_NUMERICHOST);
    puts("PASS: private DNS redirects only the exact realm, including a terminal dot");
  } else {
    numeric_rejects("algalon.actual.battle.net");
    numeric_rejects("ALGALON.actual.battle.net.");
    puts("PASS: outside-private-process DNS retains native numeric-host rejection");
  }
  numeric_rejects("algalon.actual.battle.net.evil.example");
  numeric_rejects("prefix.algalon.actual.battle.net");
  address_is("localhost", "127.0.0.1", 0);
  puts("PASS: DNS preserves ordinary hostname resolution and rejects alias lookalikes");
  setenv("FOREVER_SERVER_IPV4", "not an address", 1);
  numeric_rejects("algalon.actual.battle.net");
  unsetenv("FOREVER_SERVER_IPV4");
  numeric_rejects("algalon.actual.battle.net");
  puts("PASS: missing or invalid realm addresses cannot redirect DNS");
  return 0;
}
