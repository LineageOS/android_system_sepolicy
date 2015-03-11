#include "booleans.h"
#include <sepol/booleans.h>

void booleans_usage() {
    fprintf(stderr, "\tbooleans\n");
}

int booleans_func (int argc, __attribute__ ((unused)) char **argv, policydb_t *policydb) {
    int rc;
    unsigned int count;
    if (argc != 1) {
        USAGE_ERROR = true;
        return -1;
    }
    rc = sepol_bool_count(NULL, (const struct sepol_policydb *) policydb,
                          &count);
    if (rc)
        return rc;
    printf("%u\n", count);
    return 0;
}
