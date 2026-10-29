#include "TouchOSAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct TOAtomic64 {
    _Atomic uint64_t value;
};

static uint64_t bits(double d) { uint64_t u; memcpy(&u, &d, sizeof u); return u; }
static double real(uint64_t u) { double d; memcpy(&d, &u, sizeof d); return d; }

TOAtomic64 *TOAtomicCreate(void) {
    TOAtomic64 *a = malloc(sizeof *a);
    atomic_init(&a->value, 0);
    return a;
}

uint64_t TOAtomicLoad(TOAtomic64 *a) { return atomic_load_explicit(&a->value, memory_order_acquire); }
void TOAtomicStore(TOAtomic64 *a, uint64_t value) { atomic_store_explicit(&a->value, value, memory_order_release); }
double TOAtomicLoadDouble(TOAtomic64 *a) { return real(TOAtomicLoad(a)); }
void TOAtomicStoreDouble(TOAtomic64 *a, double value) { TOAtomicStore(a, bits(value)); }

double TOAtomicAddDouble(TOAtomic64 *a, double delta) {
    uint64_t old = atomic_load_explicit(&a->value, memory_order_relaxed);
    uint64_t new;
    do {
        new = bits(real(old) + delta);
    } while (!atomic_compare_exchange_weak_explicit(&a->value, &old, new, memory_order_acq_rel, memory_order_relaxed));
    return real(new);
}

double TOAtomicExchangeDouble(TOAtomic64 *a, double value) {
    return real(atomic_exchange_explicit(&a->value, bits(value), memory_order_acq_rel));
}

void TOAtomicIncrement(TOAtomic64 *a) { atomic_fetch_add_explicit(&a->value, 1, memory_order_relaxed); }

void TOAtomicMax(TOAtomic64 *a, uint64_t value) {
    uint64_t old = atomic_load_explicit(&a->value, memory_order_relaxed);
    while (old < value && !atomic_compare_exchange_weak_explicit(&a->value, &old, value, memory_order_relaxed, memory_order_relaxed)) {
    }
}

uint64_t TOAtomicExchange(TOAtomic64 *a, uint64_t value) {
    return atomic_exchange_explicit(&a->value, value, memory_order_acq_rel);
}
