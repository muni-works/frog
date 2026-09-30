// C ABI of tang-llm-ios (crates/tang-llm-ios in the tang repo). Every returned string is
// UTF-8 JSON and must be freed with tang_string_free.
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct TangHandle TangHandle;

TangHandle *tang_load(const char *dir, uint32_t max_ctx, bool q4, char **error);
void tang_free(TangHandle *h);
void tang_string_free(char *s);
char *tang_info(TangHandle *h);
char *tang_bench(TangHandle *h, uint32_t prompt_tokens, uint32_t gen_tokens);
char *tang_chat(TangHandle *h, const char *messages, uint32_t max_tokens,
                bool (*on_text)(const char *text, void *ctx), void *ctx);
