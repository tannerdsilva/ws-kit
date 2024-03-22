#include "cwskit_datachain_keyed.h"
#include "cwskit_types.h"
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

bool _cwskit_dc_pass_link(const _cwskit_datachainpair_keyed_ptr_t chain, const _cwskit_datachainlink_keyed_ptr_t link) {
    _cwskit_datachainlink_keyed_ptr_t expected = NULL;
    _cwskit_datachainlink_keyed_ptr_t gettail = atomic_load_explicit(chain->tail, memory_order_acquire);

    _cwskit_datachainlink_keyed_aptr_t* _Nonnull writeptr;
    if (gettail == NULL) {
        writeptr = chain->tail;
    } else {
        writeptr = &gettail->next;
    }

    bool storeResult = atomic_compare_exchange_strong_explicit(writeptr, &expected, link, memory_order_release, memory_order_acquire);
    if (storeResult == true) {
        if (gettail == NULL) {
            atomic_store_explicit(chain->base, link, memory_order_release);
        } else {
            atomic_store_explicit(chain->tail, link, memory_order_release);
        }

        atomic_fetch_add_explicit(&chain->element_count, 1, memory_order_acq_rel);
    }
    return storeResult;
}

void _cwskit_dc_pass(const _cwskit_datachainpair_keyed_ptr_t chain, uint64_t key, const _cwskit_ptr_t ptr) {
    const struct _cwskit_datachainlink_keyed link_on_stack = {
        .key = key,
        .ptr = ptr,
        .next = NULL
    };
    const _cwskit_datachainlink_keyed_ptr_t link_on_heap = memcpy(malloc(sizeof(link_on_stack)), &link_on_stack, sizeof(link_on_stack));
    bool current = false;
    do {
        current = _cwskit_dc_pass_link(chain, link_on_heap);
    } while (current == false);
}

bool _cwskit_dc_consume_by_key(const _cwskit_datachainpair_keyed_ptr_t chain, uint64_t key, const _cwskit_datachainlink_ptr_consume_f consumer_f) {
    bool consume_success = false;
    _cwskit_datachainlink_keyed_ptr_t current = atomic_load_explicit(chain->base, memory_order_acquire);
    _cwskit_datachainlink_keyed_ptr_t prev = NULL;

    while (current != NULL) {
        _cwskit_datachainlink_keyed_ptr_t next = atomic_load_explicit(&current->next, memory_order_acquire);

        if (current->key == key) {
            // Adjust pointers to remove the current node from the chain
            if (prev == NULL) { // It's the base
                atomic_compare_exchange_strong_explicit(chain->base, &current, next, memory_order_release, memory_order_relaxed);
            } else {
                atomic_store_explicit(&prev->next, next, memory_order_release);
            }

            // If it's the tail, update the tail pointer
            if (atomic_load_explicit(chain->tail, memory_order_acquire) == current) {
                atomic_compare_exchange_strong_explicit(chain->tail, &current, prev, memory_order_release, memory_order_relaxed);
            }

            consumer_f(current->ptr);
            chain->dealloc_f(current->ptr);
            free(current);
            atomic_fetch_sub_explicit(&chain->element_count, 1, memory_order_acq_rel);
            consume_success = true;
            break;
        }

        prev = current;
        current = next;
    }
    return consume_success;
}
