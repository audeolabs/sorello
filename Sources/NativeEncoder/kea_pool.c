/* kea_pool.c: the encoder's thread pool.

   kea_pool_run wakes every worker, runs the task on the calling thread too, and waits for all. Workers wait for the
   next task by spinning on a generation counter for up to KEA_SPIN_NS, then park on a condition variable; a parked
   worker costs a wake-up (tens of microseconds) at the next run, a spinning one does not. Inside one encode the gaps
   between runs are far shorter than the spin window, so workers park only between encodes. Threads are not pinned.
   On Apple systems workers run at the user-interactive QoS class. */
#define _DARWIN_C_SOURCE
#include "kea_internal.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if defined(__APPLE__)
#include <pthread/qos.h>
#endif

#define KEA_SPIN_NS 200000 /* 0.2 ms */
#define KEA_SCRATCH_SLOTS 4

struct kea_pool {
    int n;
    pthread_t *th;
    _Atomic unsigned gen;
    _Atomic int done, sleepers, stop;
    kea_task_fn fn;
    void *ctx;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    void *scratch[KEA_SCRATCH_SLOTS];
    size_t scratch_len[KEA_SCRATCH_SLOTS];
#ifdef KEA_STATS
    unsigned long regions;
#endif
};

typedef struct {
    kea_pool *p;
    int tid;
} kea_worker_arg;

static inline void cpu_relax(void) {
#if defined(__x86_64__)
    __builtin_ia32_pause();
#elif defined(__aarch64__)
    __asm__ __volatile__("yield");
#endif
}

static long long now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void *worker(void *arg) {
    kea_pool *p = ((kea_worker_arg *)arg)->p;
    int tid = ((kea_worker_arg *)arg)->tid;
    free(arg);
    unsigned seen = 0;
    for (;;) {
        unsigned g;
        long long t0 = 0;
        int spins = 0;
        while ((g = atomic_load_explicit(&p->gen, memory_order_acquire)) == seen) {
            cpu_relax();
            if (++spins & 63) continue;
            long long t = now_ns();
            if (!t0) t0 = t;
            if (t - t0 < KEA_SPIN_NS) continue;
            pthread_mutex_lock(&p->mu);
            atomic_fetch_add(&p->sleepers, 1);
            while ((g = atomic_load(&p->gen)) == seen) pthread_cond_wait(&p->cv, &p->mu);
            atomic_fetch_sub(&p->sleepers, 1);
            pthread_mutex_unlock(&p->mu);
            break;
        }
        seen = g;
        if (atomic_load(&p->stop)) return NULL;
        p->fn(p->ctx, tid, p->n);
        atomic_fetch_add_explicit(&p->done, 1, memory_order_release);
    }
}

static void wake(kea_pool *p) {
    atomic_fetch_add(&p->gen, 1); /* sequentially consistent: pairs with the sleepers count below */
    if (atomic_load(&p->sleepers) > 0) {
        pthread_mutex_lock(&p->mu);
        pthread_cond_broadcast(&p->cv);
        pthread_mutex_unlock(&p->mu);
    }
}

kea_pool *kea_pool_create(int threads) {
    kea_pool *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->n = threads > 0 ? threads : 4;
    pthread_mutex_init(&p->mu, NULL);
    pthread_cond_init(&p->cv, NULL);
    p->th = calloc((size_t)p->n, sizeof(pthread_t));
    if (!p->th) {
        free(p);
        return NULL;
    }
    pthread_attr_t attr;
    pthread_attr_init(&attr);
#if defined(__APPLE__)
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    for (int i = 1; i < p->n; i++) {
        kea_worker_arg *a = malloc(sizeof *a);
        if (a) {
            a->p = p;
            a->tid = i;
        }
        if (!a || pthread_create(&p->th[i], &attr, worker, a) != 0) {
            free(a);
            p->n = i; /* run with the threads that started */
            break;
        }
    }
    pthread_attr_destroy(&attr);
    return p;
}

void kea_pool_destroy(kea_pool *p) {
    if (!p) return;
    atomic_store(&p->stop, 1);
    wake(p);
    for (int i = 1; i < p->n; i++) pthread_join(p->th[i], NULL);
    for (int s = 0; s < KEA_SCRATCH_SLOTS; s++) free(p->scratch[s]);
    pthread_mutex_destroy(&p->mu);
    pthread_cond_destroy(&p->cv);
    free(p->th);
    free(p);
}

void kea_pool_run(kea_pool *p, kea_task_fn fn, void *ctx) {
#ifdef KEA_STATS
    p->regions++;
#endif
    if (p->n == 1) {
        fn(ctx, 0, 1);
        return;
    }
    p->fn = fn;
    p->ctx = ctx;
    atomic_store(&p->done, 0);
    wake(p);
    fn(ctx, 0, p->n);
    while (atomic_load_explicit(&p->done, memory_order_acquire) < p->n - 1) cpu_relax();
}

int kea_pool_threads(const kea_pool *p) { return p->n; }

void *kea_pool_scratch(kea_pool *p, int slot, size_t bytes) {
    if (slot < 0 || slot >= KEA_SCRATCH_SLOTS) return NULL;
    if (p->scratch_len[slot] < bytes) {
        free(p->scratch[slot]);
        p->scratch[slot] = kea_aligned_alloc(bytes);
        p->scratch_len[slot] = p->scratch[slot] ? bytes : 0;
    }
    return p->scratch[slot];
}

#ifdef KEA_STATS
unsigned long kea_pool_regions(const kea_pool *p) { return p->regions; }
#endif
