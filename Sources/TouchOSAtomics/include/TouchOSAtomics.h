// 无锁原子变量（C11 stdatomic）。事件拦截回调不得加锁（SRS FR-7.2），
// 而 Swift 标准库的 Atomic 需要 macOS 15，最低支持版本为 macOS 14，故用 C 实现。
#pragma once
#include <stdint.h>

typedef struct TOAtomic64 TOAtomic64;

TOAtomic64 *TOAtomicCreate(void);
uint64_t TOAtomicLoad(TOAtomic64 *a);
void TOAtomicStore(TOAtomic64 *a, uint64_t value);
double TOAtomicLoadDouble(TOAtomic64 *a);
void TOAtomicStoreDouble(TOAtomic64 *a, double value);
/// 原子累加并返回新值
double TOAtomicAddDouble(TOAtomic64 *a, double delta);
/// 原子地取出当前值并置零
double TOAtomicExchangeDouble(TOAtomic64 *a, double value);
/// 原子加一（整数）
void TOAtomicIncrement(TOAtomic64 *a);
/// 原子地把值更新为 max(当前值, value)（整数）
void TOAtomicMax(TOAtomic64 *a, uint64_t value);
/// 原子地取出当前值并替换（整数）
uint64_t TOAtomicExchange(TOAtomic64 *a, uint64_t value);
