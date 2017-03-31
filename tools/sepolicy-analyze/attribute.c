#include <getopt.h>

#include "attribute.h"

void attribute_usage() {
    fprintf(stderr, "\tattribute <name> [-r|--reverse]\n");
}

static void retrieve_mapping(policydb_t *policydb, struct type_datum *dat, char *name, int reverse) {
    struct ebitmap_node *n;
    unsigned int bit;

    if (reverse) {
        ebitmap_for_each_bit(&policydb->type_attr_map[dat->s.value - 1], n, bit) {
            if (!ebitmap_node_get_bit(n, bit))
                continue;
            if (!strcmp(policydb->p_type_val_to_name[bit], name))
                continue;
            printf("%s\n", policydb->p_type_val_to_name[bit]);
        }
    } else {
        ebitmap_for_each_bit(&policydb->attr_type_map[dat->s.value - 1], n, bit) {
            if (!ebitmap_node_get_bit(n, bit))
                continue;
            printf("%s\n", policydb->p_type_val_to_name[bit]);
        }
    }
}

static int list_attribute(policydb_t *policydb, char *name, int reverse)
{
    struct type_datum *dat;

    dat = hashtab_search(policydb->p_types.table, name);
    if (!dat) {
        fprintf(stderr, "%s is not defined in this policy.\n", name);
        return -1;
    }

    if (reverse) {
        if (dat->flavor != TYPE_TYPE) {
            fprintf(stderr, "%s is an attribute not a type in this policy.\n", name);
            return -1;
        }
    } else {
        if (dat->flavor != TYPE_ATTRIB) {
            fprintf(stderr, "%s is a type not an attribute in this policy.\n", name);
            return -1;
        }
    }
    retrieve_mapping(policydb, dat, name, reverse);

    return 0;
}

int attribute_func (int argc, char **argv, policydb_t *policydb) {
    int reverse = 0;
    char ch;

    struct option attribute_options[] = {
        {"reverse", no_argument, NULL, 'r'},
        {NULL, 0, NULL, 0}
    };

    while ((ch = getopt_long(argc, argv, "r", attribute_options, NULL)) != -1) {
        switch (ch) {
        case 'r':
            reverse = 1;
            break;
        default:
            USAGE_ERROR = true;
            return -1;
        }
    }

    if (argc != 2 && !(reverse && argc == 3)) {
        USAGE_ERROR = true;
        return -1;
    }
    return list_attribute(policydb, argv[optind], reverse);
}
