#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Success returns a handle/result and leaves error null. All strings are UTF-8,
// malloc-owned, and freed with axo_coreml_string_free. No exceptions escape.
char *axo_coreml_probe(char **error);
void *axo_coreml_load(const char *path, const char *work_directory, char **error);
char *axo_coreml_description(void *model, char **error);
char *axo_coreml_predict(void *model, const char *json, size_t length, char **error);
void axo_coreml_free(void *model);
void axo_coreml_string_free(char *string);
#ifdef __cplusplus
}
#endif
