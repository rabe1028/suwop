#ifndef SUWOP_H
#define SUWOP_H
#include <stdint.h>
uint64_t suwop_new(void);
void suwop_drop(uint64_t handle);
char *suwop_call(uint64_t handle, uint32_t action, const char *input);
void suwop_free(char *value);
#endif
