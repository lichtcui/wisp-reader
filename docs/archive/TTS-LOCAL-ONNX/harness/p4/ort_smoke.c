/* P4 load smoke: dlopen the cross-built libonnxruntime.so and report its version.
 * Deliberately avoids the `ort` crate so we isolate "can OHOS load our ORT". */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct OrtApiBase OrtApiBase;
struct OrtApiBase {
  const void* (*GetApi)(unsigned int version);
  const char* (*GetVersionString)(void);
};

int main(int argc, char** argv) {
  const char* path = argc > 1 ? argv[1] : "libonnxruntime.so";
  unsigned int want = argc > 2 ? (unsigned int)atoi(argv[2]) : 24u;
  void* h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (!h) { printf("SMOKE dlopen FAIL: %s\n", dlerror()); return 2; }
  printf("SMOKE dlopen OK: %s\n", path);
  const OrtApiBase* (*get_base)(void) = (const OrtApiBase* (*)(void))dlsym(h, "OrtGetApiBase");
  if (!get_base) { printf("SMOKE dlsym FAIL: %s\n", dlerror()); return 3; }
  const OrtApiBase* base = get_base();
  printf("SMOKE version_string=%s\n", base->GetVersionString());
  const void* api = base->GetApi(want);
  printf("SMOKE GetApi(%u)=%s\n", want, api ? "OK" : "NULL");
  return api ? 0 : 4;
}
