#ifndef __MACROS_H__
#define __MACROS_H__

#include "config.h"

#if KEEP_SYMBOLS == 1
    #define __maybe_inline __attribute__((noinline))
#else
    #define __maybe_inline __attribute__((always_inline))
#endif

#endif