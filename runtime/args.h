#ifndef args_h
#define args_h

#include <stdbool.h>

extern float GCThreshold; // fraction of total heap used before gc runs.

typedef enum {
  LAZY,    // default
  STRICT1, // just function's arity args
  STRICT2, // all args in application
} EvalStrategy;

extern int evalStrategy;
extern int constStrict;
extern bool sanityChecker;

void parseArgs (int argc, char **argv);

#endif
