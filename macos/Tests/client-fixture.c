#include <netdb.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>

int main(void) {
  const char *endpoint = getenv("FOREVER_FIXTURE_ENDPOINT");
  if (endpoint) {
    signal(SIGTERM, SIG_IGN);
    FILE *log = fopen("Logs/Connection.log", "a");
    if (!log) return 3;
    fputs("[Connection] Battle.net logon requested ", log);
    fflush(log);
    usleep(60000);
    fprintf(log, "%s\n", endpoint);
    fclose(log);
    usleep(700000);
    FILE *marker = fopen("Logs/credentials-stage", "w");
    if (!marker) return 4;
    fclose(marker);
    return 0;
  }
  const char *expected = getenv("FOREVER_SERVER_IPV4");
  if (!expected) return 0;
  struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM};
  struct addrinfo *answer = NULL;
  if (getaddrinfo("algalon.actual.battle.net", "1120", &hints, &answer) != 0) return 1;
  char address[NI_MAXHOST];
  int status = getnameinfo(answer->ai_addr, answer->ai_addrlen, address, sizeof(address),
                           NULL, 0, NI_NUMERICHOST);
  freeaddrinfo(answer);
  return status == 0 && strcmp(address, expected) == 0 ? 0 : 2;
}
