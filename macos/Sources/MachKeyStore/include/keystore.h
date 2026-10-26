// keystore.h - runtime key-store scan and patch for the Forever launcher on macOS.
//
// Port of the proven Windows logic in forever-launcher.cpp (store_state / find_stores / patch_store,
// 2026-10-09..10). The store is 12 entries of 40 bytes: uint32 little-endian id (1..12), a 32-byte
// Ed25519 key, a flag byte at offset 36, then two zero bytes at 38 and 39. Only the key of one region
// group (group 8 for the default realm) is replaced, in the memory of the RUNNING client; the on-disk image is
// never touched. Every check from the Windows version is preserved: exactly 12 entries, ids 1..12, all
// known keys match, flags match, only the target group's key is changed, and the whole table is
// re-read and re-validated after the write.
//
// All data edits only; no executable memory is involved, so no page-protection change is needed.
#ifndef FOREVER_KEYSTORE_H
#define FOREVER_KEYSTORE_H

#include <mach/mach.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KS_ENTRY 40
#define KS_COUNT 12
#define KS_KEYLEN 32

// Result of a single scan+patch pass.
typedef struct {
    int stores_found;    // full valid tables located in this pass
    int already_patched; // of those, how many already carried newkey in the target group
    int patched_now;     // of those, how many this pass changed from original to patched
    int write_errors;    // writes that failed or did not verify
    kern_return_t last_kr; // last non-success kernel return, for diagnostics (0 if none)
} ks_result;

// Acquire the task port of `pid`. Returns KERN_SUCCESS or the failing kernel code.
// On macOS with SIP enabled this succeeds only when THIS process holds
// com.apple.security.cs.debugger and the TARGET process holds com.apple.security.get-task-allow
// (the re-signed private client copy). Root alone is not sufficient under SIP.
kern_return_t ks_task_for_pid(int pid, task_t *out_task);

// One scan of every readable+writable region of `task`, patching each original store found so that the
// key of `group` (1..12) becomes `newkey`. Flat buffers, for clean Swift interop:
//   known  - 12*32 bytes, the stock key of entry e at known + e*32
//   flags  - 12 bytes, the expected flag byte of entry e
//   newkey - 32 bytes
// Idempotent: a store already patched is counted, not rewritten. Returns the tallies in `*res`. A
// non-zero res->write_errors means a located store failed to patch; treat that as a hard error.
void ks_scan_and_patch(task_t task,
                       const unsigned char *known,
                       const unsigned char *flags,
                       const unsigned char *newkey,
                       int group,
                       ks_result *res);

#ifdef __cplusplus
}
#endif

#endif
