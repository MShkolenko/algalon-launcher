#include <stdlib.h>
#include <string.h>

int realmPrivateProcess(void) {
  const char *scope = getenv("FOREVER_INPUT_FIXTURE");
  return scope && !strcmp(scope, "1");
}
