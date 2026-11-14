#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Every returned string is owned by the caller and freed with axo_mlx_string_free.
// On failure returns null and writes an owned diagnostic to error.
// Initialize once, before model creation. The resource cannot change afterward.
int axo_mlx_initialize(const char* metallib, char** error);
void* axo_mlx_load(const char* directory, char** error);
char* axo_mlx_description(void* model, char** error);
char* axo_mlx_predict(void* model, const char* inputs, char** error);
void axo_mlx_free(void* model);
void axo_mlx_string_free(char* text);
#ifdef __cplusplus
}
#endif
