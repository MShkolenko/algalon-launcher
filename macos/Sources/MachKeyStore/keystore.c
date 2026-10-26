// keystore.c - see keystore.h. Direct port of forever-launcher.cpp's key-store code to mach_vm.
//
// Windows -> macOS mapping:
//   VirtualQueryEx (MEM_COMMIT, MEM_PRIVATE, PAGE_READWRITE)  ->  mach_vm_region, protection has R and W
//   ReadProcessMemory                                         ->  mach_vm_read_overwrite
//   WriteProcessMemory                                        ->  mach_vm_write
//   OpenProcess(PROCESS_VM_*)                                 ->  task_for_pid
#include "keystore.h"
#include <mach/mach_vm.h>
#include <string.h>

kern_return_t ks_task_for_pid(int pid, task_t *out_task) {
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr == KERN_SUCCESS) *out_task = task;
    return kr;
}

typedef enum { KS_INVALID, KS_ORIGINAL, KS_PATCHED } store_state_t;

#define KEY_AT(known, e) ((known) + (size_t)(e) * KS_KEYLEN)

// Validate the 40*12 table at `block`. Mirrors store_state() in the Windows source exactly.
static store_state_t store_state(task_t task, mach_vm_address_t block, int group,
                                 const unsigned char *known,
                                 const unsigned char *flags,
                                 const unsigned char *newkey) {
    unsigned char raw[KS_ENTRY * KS_COUNT];
    mach_vm_size_t got = 0;
    if (mach_vm_read_overwrite(task, block, sizeof(raw), (mach_vm_address_t)(uintptr_t)raw, &got) != KERN_SUCCESS
        || got != sizeof(raw))
        return KS_INVALID;
    for (size_t e = 0; e < KS_COUNT; ++e) {
        const unsigned char *o = raw + e * KS_ENTRY;
        uint32_t id = o[0] | (o[1] << 8) | (o[2] << 16) | ((uint32_t)o[3] << 24);
        int is_known = memcmp(o + 4, KEY_AT(known, e), KS_KEYLEN) == 0;
        int ok = ((int)e == group - 1) ? (is_known || memcmp(o + 4, newkey, KS_KEYLEN) == 0) : is_known;
        if (id != e + 1 || !ok || o[36] != flags[e] || o[38] != 0 || o[39] != 0)
            return KS_INVALID;
    }
    return memcmp(raw + (group - 1) * KS_ENTRY + 4, newkey, KS_KEYLEN) == 0 ? KS_PATCHED : KS_ORIGINAL;
}

// Replace the group's key, then re-validate the whole table. Mirrors patch_store().
static int patch_store(task_t task, mach_vm_address_t block, int group,
                       const unsigned char *known,
                       const unsigned char *flags,
                       const unsigned char *newkey) {
    mach_vm_address_t addr = block + (mach_vm_address_t)(group - 1) * KS_ENTRY + 4;
    unsigned char cur[KS_KEYLEN];
    mach_vm_size_t got = 0;
    if (mach_vm_read_overwrite(task, addr, KS_KEYLEN, (mach_vm_address_t)(uintptr_t)cur, &got) != KERN_SUCCESS
        || got != KS_KEYLEN || memcmp(cur, KEY_AT(known, group - 1), KS_KEYLEN) != 0)
        return 0;
    if (mach_vm_write(task, addr, (vm_offset_t)(uintptr_t)newkey, KS_KEYLEN) != KERN_SUCCESS)
        return 0;
    return store_state(task, block, group, known, flags, newkey) == KS_PATCHED;
}

void ks_scan_and_patch(task_t task,
                       const unsigned char *known,
                       const unsigned char *flags,
                       const unsigned char *newkey,
                       int group,
                       ks_result *res) {
    memset(res, 0, sizeof(*res));

    // One reused buffer, bounded 4 MB chunks with a 64-byte overlap (Codex review 2026-10-10: a buffer
    // per region could allocate as large as the biggest region).
    const mach_vm_size_t CHUNK = (mach_vm_size_t)4 << 20, OVERLAP = 64;
    static unsigned char buf[(4u << 20) + 64];

    mach_vm_address_t address = 0;
    while (1) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t kr = mach_vm_region(task, &address, &size, VM_REGION_BASIC_INFO_64,
                                          (vm_region_info_t)&info, &count, &object);
        if (kr != KERN_SUCCESS) {
            if (kr != KERN_INVALID_ADDRESS)
                res->last_kr = kr; // a real failure, not just the end of the address space
            break;
        }
        // mach_vm_region hands back a send right to the region's named object; release it or the rights
        // accumulate across the whole session until later Mach calls fail.
        if (MACH_PORT_VALID(object))
            mach_port_deallocate(mach_task_self(), object);

        mach_vm_address_t region_base = address;
        mach_vm_size_t region_size = size;
        mach_vm_address_t next = address + size;
        if (next <= region_base)
            break; // address wrapped: stop, as the Windows scanner does
        address = next; // advance before any continue, so the loop always terminates

        // Windows scanned MEM_PRIVATE | PAGE_READWRITE only; the key store is heap-private, so require
        // read+write and skip shared/mapped regions (faster, and avoids the shared cache).
        if (!(info.protection & VM_PROT_READ) || !(info.protection & VM_PROT_WRITE) || info.shared)
            continue;

        for (mach_vm_size_t off = 0; off < region_size; off += CHUNK) {
            mach_vm_size_t want = region_size - off < CHUNK + OVERLAP ? region_size - off : CHUNK + OVERLAP;
            mach_vm_size_t got = 0;
            if (mach_vm_read_overwrite(task, region_base + off, want,
                                       (mach_vm_address_t)(uintptr_t)buf, &got) != KERN_SUCCESS
                || got < 36)
                continue;
            // a match inside the overlap belongs to the next chunk
            mach_vm_size_t limit = off + CHUNK < region_size ? CHUNK : got;
            // Valid tables are four-byte aligned; all VM region/chunk bases share that alignment.
            for (mach_vm_size_t i = 0; i + KS_KEYLEN <= got && i < limit; i += 4) {
                if (buf[i] != known[0] || memcmp(&buf[i], known, KS_KEYLEN) != 0)
                    continue;
                mach_vm_address_t at = region_base + off + i;
                if (at % 4 != 0 || at < region_base + 4)
                    continue;
                store_state_t s = store_state(task, at - 4, group, known, flags, newkey);
                if (s == KS_INVALID)
                    continue;
                res->stores_found++;
                if (s == KS_PATCHED) {
                    res->already_patched++;
                } else if (patch_store(task, at - 4, group, known, flags, newkey)) {
                    res->patched_now++;
                } else {
                    res->write_errors++;
                }
            }
        }
    }
}
