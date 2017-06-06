
#ifdef __cplusplus
extern "C" {
#endif

int get_allow_rule(char *out, size_t len, void *policydbp, void *avtab_iterp);
void *load_policy(const char *policy_path);
void destroy_policy(void *policydbp);
void *init_avtab(void *policydbp);
void *init_cond_avtab(void *policydbp);
void destroy_avtab(void *avtab_iterp);
int get_type(char *out, size_t max_size, void *policydbp, void *type_iterp);
void *init_type_iter(void *policydbp, const char *type, bool is_attr);
void destroy_type_iter(void *type_iterp);

#ifdef __cplusplus
}
#endif

