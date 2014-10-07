#include <getopt.h>
#include <unistd.h>
#include <stddef.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <sepol/policydb/policydb.h>
#include <sepol/policydb/services.h>
#include <sepol/policydb/expand.h>
#include <sepol/policydb/util.h>
#include <stdbool.h>
#include <ctype.h>

static int debug;
static int warn;

void usage(char *arg0)
{
    fprintf(stderr, "%s [-w|--warn] [-z|--debug] [-e|--equiv] [-d|--diff] [-D|--dups] [-p|--permissive] [-n|--neverallow <neverallow file>] -P <policy file>\n", arg0);
    exit(1);
}

int load_policy(char *filename, policydb_t * policydb, struct policy_file *pf)
{
    int fd;
    struct stat sb;
    void *map;
    int ret;

    fd = open(filename, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "Can't open '%s':  %s\n", filename, strerror(errno));
        return 1;
    }
    if (fstat(fd, &sb) < 0) {
        fprintf(stderr, "Can't stat '%s':  %s\n", filename, strerror(errno));
        close(fd);
        return 1;
    }
    map = mmap(NULL, sb.st_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) {
        fprintf(stderr, "Can't mmap '%s':  %s\n", filename, strerror(errno));
        close(fd);
        return 1;
    }

    policy_file_init(pf);
    pf->type = PF_USE_MEMORY;
    pf->data = map;
    pf->len = sb.st_size;
    if (policydb_init(policydb)) {
        fprintf(stderr, "Could not initialize policydb!\n");
        close(fd);
        munmap(map, sb.st_size);
        return 1;
    }
    ret = policydb_read(policydb, pf, 0);
    if (ret) {
        fprintf(stderr, "error(s) encountered while parsing configuration\n");
        close(fd);
        munmap(map, sb.st_size);
        return 1;
    }

    return 0;
}

static int insert_type_rule(avtab_key_t * k, avtab_datum_t * d,
                            struct avtab_node *type_rules)
{
    struct avtab_node *p, *c, *n;

    for (p = type_rules, c = type_rules->next; c; p = c, c = c->next) {
        /*
         * Find the insertion point, keeping the list
         * ordered by source type, then target type, then
         * target class.
         */
        if (k->source_type < c->key.source_type)
            break;
        if (k->source_type == c->key.source_type &&
            k->target_type < c->key.target_type)
            break;
        if (k->source_type == c->key.source_type &&
            k->target_type == c->key.target_type &&
            k->target_class <= c->key.target_class)
            break;
    }

    if (c &&
        k->source_type == c->key.source_type &&
        k->target_type == c->key.target_type &&
        k->target_class == c->key.target_class) {
        c->datum.data |= d->data;
        return 0;
    }

    /* Insert the rule */
    n = malloc(sizeof(struct avtab_node));
    if (!n) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }

    n->key = *k;
    n->datum = *d;
    n->next = p->next;
    p->next = n;
    return 0;
}

static int create_type_rules_helper(avtab_key_t * k, avtab_datum_t * d,
                                    void *args)
{
    struct avtab_node *type_rules = args;
    avtab_key_t key;

    /*
     * Insert the rule into the list for
     * the source type.  The source type value
     * is cleared as we want to compare against other type
     * rules with different source types.
     */
    key = *k;
    key.source_type = 0;
    if (k->source_type == k->target_type) {
        /* Clear target type as well; this is a self rule. */
        key.target_type = 0;
    }
    if (insert_type_rule(&key, d, &type_rules[k->source_type - 1]))
        return -1;

    if (k->source_type == k->target_type)
        return 0;

    /*
     * If the target type differs, then we also
     * insert the rule into the list for the target
     * type.  We clear the target type value so that
     * we can compare against other type rules with
     * different target types.
     */
    key = *k;
    key.target_type = 0;
    if (insert_type_rule(&key, d, &type_rules[k->target_type - 1]))
        return -1;

    return 0;
}

static int create_type_rules(avtab_key_t * k, avtab_datum_t * d, void *args)
{
    if (k->specified & AVTAB_ALLOWED)
        return create_type_rules_helper(k, d, args);
    return 0;
}

static int create_type_rules_cond(avtab_key_t * k, avtab_datum_t * d,
                                  void *args)
{
    if ((k->specified & (AVTAB_ALLOWED|AVTAB_ENABLED)) ==
        (AVTAB_ALLOWED|AVTAB_ENABLED))
        return create_type_rules_helper(k, d, args);
    return 0;
}

static void free_type_rules(struct avtab_node *l)
{
    struct avtab_node *tmp;

    while (l) {
        tmp = l;
        l = l->next;
        free(tmp);
    }
}

static void display_allow(policydb_t *policydb, avtab_key_t *key, int idx,
                          uint32_t perms)
{
    printf("    allow %s %s:%s { %s };\n",
           policydb->p_type_val_to_name[key->source_type
                                        ? key->source_type - 1 : idx],
           key->target_type == key->source_type ? "self" :
           policydb->p_type_val_to_name[key->target_type
                                        ? key->target_type - 1 : idx],
           policydb->p_class_val_to_name[key->target_class - 1],
           sepol_av_to_string
           (policydb, key->target_class, perms));
}

static int find_match(policydb_t *policydb, struct avtab_node *l1,
                      int idx1, struct avtab_node *l2, int idx2)
{
    struct avtab_node *c;
    uint32_t perms1, perms2;

    for (c = l2; c; c = c->next) {
        if (l1->key.source_type < c->key.source_type)
            break;
        if (l1->key.source_type == c->key.source_type &&
            l1->key.target_type < c->key.target_type)
            break;
        if (l1->key.source_type == c->key.source_type &&
            l1->key.target_type == c->key.target_type &&
            l1->key.target_class <= c->key.target_class)
            break;
    }

    if (c &&
        l1->key.source_type == c->key.source_type &&
        l1->key.target_type == c->key.target_type &&
        l1->key.target_class == c->key.target_class) {
        perms1 = l1->datum.data & ~c->datum.data;
        perms2 = c->datum.data & ~l1->datum.data;
        if (perms1 || perms2) {
            if (perms1)
                display_allow(policydb, &l1->key, idx1, perms1);
            if (perms2)
                display_allow(policydb, &c->key, idx2, perms2);
            printf("\n");
            return 1;
        }
    }

    return 0;
}

static int analyze_types(policydb_t * policydb, char equiv, char diff)
{
    avtab_t exp_avtab, exp_cond_avtab;
    struct avtab_node *type_rules, *l1, *l2;
    struct type_datum *type;
    size_t i, j;

    /*
     * Create a list of access vector rules for each type
     * from the access vector table.
     */
    type_rules = malloc(sizeof(struct avtab_node) * policydb->p_types.nprim);
    if (!type_rules) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }
    memset(type_rules, 0, sizeof(struct avtab_node) * policydb->p_types.nprim);

    if (avtab_init(&exp_avtab) || avtab_init(&exp_cond_avtab)) {
        fputs("out of memory\n", stderr);
        return -1;
    }

    if (expand_avtab(policydb, &policydb->te_avtab, &exp_avtab)) {
        fputs("out of memory\n", stderr);
        avtab_destroy(&exp_avtab);
        return -1;
    }

    if (expand_avtab(policydb, &policydb->te_cond_avtab, &exp_cond_avtab)) {
        fputs("out of memory\n", stderr);
        avtab_destroy(&exp_avtab);
        return -1;
    }

    if (avtab_map(&exp_avtab, create_type_rules, type_rules))
        exit(1);

    if (avtab_map(&exp_cond_avtab, create_type_rules_cond, type_rules))
        exit(1);

    avtab_destroy(&exp_avtab);
    avtab_destroy(&exp_cond_avtab);

    /*
     * Compare the type lists and identify similar types.
     */
    for (i = 0; i < policydb->p_types.nprim - 1; i++) {
        if (!type_rules[i].next)
            continue;
        type = policydb->type_val_to_struct[i];
        if (type->flavor) {
            free_type_rules(type_rules[i].next);
            type_rules[i].next = NULL;
            continue;
        }
        for (j = i + 1; j < policydb->p_types.nprim; j++) {
            type = policydb->type_val_to_struct[j];
            if (type->flavor) {
                free_type_rules(type_rules[j].next);
                type_rules[j].next = NULL;
                continue;
            }
            for (l1 = type_rules[i].next, l2 = type_rules[j].next;
                 l1 && l2; l1 = l1->next, l2 = l2->next) {
                if (l1->key.source_type != l2->key.source_type)
                    break;
                if (l1->key.target_type != l2->key.target_type)
                    break;
                if (l1->key.target_class != l2->key.target_class
                    || l1->datum.data != l2->datum.data)
                    break;
            }
            if (l1 || l2) {
                if (diff) {
                    printf
                        ("Types %s and %s differ, starting with:\n",
                         policydb->p_type_val_to_name[i],
                         policydb->p_type_val_to_name[j]);

                    if (l1 && l2) {
                        if (find_match(policydb, l1, i, l2, j))
                            continue;
                        if (find_match(policydb, l2, j, l1, i))
                            continue;
                    }
                    if (l1)
                        display_allow(policydb, &l1->key, i, l1->datum.data);
                    if (l2)
                        display_allow(policydb, &l2->key, j, l2->datum.data);
                    printf("\n");
                }
                continue;
            }
            free_type_rules(type_rules[j].next);
            type_rules[j].next = NULL;
            if (equiv) {
                printf("Types %s and %s are equivalent.\n",
                       policydb->p_type_val_to_name[i],
                       policydb->p_type_val_to_name[j]);
            }
        }
        free_type_rules(type_rules[i].next);
        type_rules[i].next = NULL;
    }

    free(type_rules);
    return 0;
}

static int find_dups_helper(avtab_key_t * k, avtab_datum_t * d,
                            void *args)
{
    policydb_t *policydb = args;
    ebitmap_t *sattr, *tattr;
    ebitmap_node_t *snode, *tnode;
    unsigned int i, j;
    avtab_key_t avkey;
    avtab_ptr_t node;
    struct type_datum *stype, *ttype, *stype2, *ttype2;
    bool attrib1, attrib2;

    if (!(k->specified & AVTAB_ALLOWED))
        return 0;

    if (k->source_type == k->target_type)
        return 0; /* self rule */

    avkey.target_class = k->target_class;
    avkey.specified = k->specified;

    sattr = &policydb->type_attr_map[k->source_type - 1];
    tattr = &policydb->type_attr_map[k->target_type - 1];
    stype = policydb->type_val_to_struct[k->source_type - 1];
    ttype = policydb->type_val_to_struct[k->target_type - 1];
    attrib1 = stype->flavor || ttype->flavor;
    ebitmap_for_each_bit(sattr, snode, i) {
        if (!ebitmap_node_get_bit(snode, i))
            continue;
        ebitmap_for_each_bit(tattr, tnode, j) {
            if (!ebitmap_node_get_bit(tnode, j))
                continue;
            avkey.source_type = i + 1;
            avkey.target_type = j + 1;
            if (avkey.source_type == k->source_type &&
                avkey.target_type == k->target_type)
                continue;
            if (avkey.source_type == avkey.target_type)
                continue; /* self rule */
            stype2 = policydb->type_val_to_struct[avkey.source_type - 1];
            ttype2 = policydb->type_val_to_struct[avkey.target_type - 1];
            attrib2 = stype2->flavor || ttype2->flavor;
            if (attrib1 && attrib2)
                continue; /* overlapping attribute-based rules */
            for (node = avtab_search_node(&policydb->te_avtab, &avkey);
                 node != NULL;
                 node = avtab_search_node_next(node, avkey.specified)) {
                uint32_t perms = node->datum.data & d->data;
                if ((attrib1 && perms == node->datum.data) ||
                    (attrib2 && perms == d->data)) {
                    /*
                     * The attribute-based rule is a superset of the
                     * non-attribute-based rule.  This is a dup.
                     */
                    printf("Duplicate allow rule found:\n");
                    display_allow(policydb, k, i, d->data);
                    display_allow(policydb, &node->key, i, node->datum.data);
                    printf("\n");
                }
            }
        }
    }

    return 0;
}

static int find_dups(policydb_t * policydb)
{
    if (avtab_map(&policydb->te_avtab, find_dups_helper, policydb))
        return -1;
    return 0;
}

static int list_permissive(policydb_t * policydb)
{
    struct ebitmap_node *n;
    unsigned int bit;

    /*
     * iterate over all domains and check if domain is in permissive
     */
    ebitmap_for_each_bit(&policydb->permissive_map, n, bit)
    {
        if (ebitmap_node_get_bit(n, bit)) {
            printf("%s\n", policydb->p_type_val_to_name[bit -1]);
        }
    }
    return 0;
}

static int read_typeset(policydb_t *policydb, char **ptr, char *end,
                        type_set_t *typeset, uint32_t *flags)
{
    const char *keyword = "self";
    size_t keyword_size = strlen(keyword), len;
    char *p = *ptr;
    unsigned openparens = 0;
    char *start, *id;
    type_datum_t *type;
    struct ebitmap_node *n;
    unsigned int bit;
    bool negate = false;
    int rc;

    do {
        while (p < end && isspace(*p))
            p++;

        if (p == end)
            goto err;

        if (*p == '~') {
            if (debug)
                printf(" ~");
            typeset->flags = TYPE_COMP;
            p++;
            while (p < end && isspace(*p))
                p++;
            if (p == end)
                goto err;
        }

        if (*p == '{') {
            if (debug && !openparens)
                printf(" {");
            openparens++;
            p++;
            continue;
        }

        if (*p == '}') {
            if (debug && openparens == 1)
                printf(" }");
            if (openparens == 0)
                goto err;
            openparens--;
            p++;
            continue;
        }

        if (*p == '*') {
            if (debug)
                printf(" *");
            typeset->flags = TYPE_STAR;
            p++;
            continue;
        }

        if (*p == '-') {
            if (debug)
                printf(" -");
            negate = true;
            p++;
            continue;
        }

        if (*p == '#') {
            while (p < end && *p != '\n')
                p++;
            continue;
        }

        start = p;
        while (p < end && !isspace(*p) && *p != ':' && *p != ';' && *p != '{' && *p != '}' && *p != '#')
            p++;

        if (p == start)
            goto err;

        len = p - start;
        if (len == keyword_size && !strncmp(start, keyword, keyword_size)) {
            if (debug)
                printf(" self");
            *flags |= RULE_SELF;
            continue;
        }

        id = calloc(1, len + 1);
        if (!id)
            goto err;
        memcpy(id, start, len);
        if (debug)
            printf(" %s", id);
        type = hashtab_search(policydb->p_types.table, id);
        if (!type) {
            if (warn)
                fprintf(stderr, "Warning!  Type or attribute %s used in neverallow undefined in policy being checked.\n", id);
            negate = false;
            continue;
        }
        free(id);

        if (type->flavor == TYPE_ATTRIB) {
            if (negate)
                rc = ebitmap_union(&typeset->negset, &policydb->attr_type_map[type->s.value - 1]);
            else
                rc = ebitmap_union(&typeset->types, &policydb->attr_type_map[type->s.value - 1]);
        } else if (negate) {
            rc = ebitmap_set_bit(&typeset->negset, type->s.value - 1, 1);
        } else {
            rc = ebitmap_set_bit(&typeset->types, type->s.value - 1, 1);
        }

        negate = false;

        if (rc)
            goto err;

    } while (p < end && openparens);

    if (p == end)
        goto err;

    if (typeset->flags & TYPE_STAR) {
        for (bit = 0; bit < policydb->p_types.nprim; bit++) {
            if (ebitmap_get_bit(&typeset->negset, bit))
                continue;
            if (policydb->type_val_to_struct[bit] &&
                policydb->type_val_to_struct[bit]->flavor == TYPE_ATTRIB)
                continue;
            if (ebitmap_set_bit(&typeset->types, bit, 1))
                goto err;
        }
    }

    ebitmap_for_each_bit(&typeset->negset, n, bit) {
        if (!ebitmap_node_get_bit(n, bit))
            continue;
        if (ebitmap_set_bit(&typeset->types, bit, 0))
            goto err;
    }

    if (typeset->flags & TYPE_COMP) {
        for (bit = 0; bit < policydb->p_types.nprim; bit++) {
            if (policydb->type_val_to_struct[bit] &&
                policydb->type_val_to_struct[bit]->flavor == TYPE_ATTRIB)
                continue;
            if (ebitmap_get_bit(&typeset->types, bit))
                ebitmap_set_bit(&typeset->types, bit, 0);
            else {
                if (ebitmap_set_bit(&typeset->types, bit, 1))
                    goto err;
            }
        }
    }

    if (warn && ebitmap_length(&typeset->types) == 0 && !(*flags))
        fprintf(stderr, "Warning!  Empty type set\n");

    *ptr = p;
    return 0;
err:
    return -1;
}

static int read_classperms(policydb_t *policydb, char **ptr, char *end,
                           class_perm_node_t **perms)
{
    char *p = *ptr;
    unsigned openparens = 0;
    char *id, *start;
    class_datum_t *cls = NULL;
    perm_datum_t *perm = NULL;
    class_perm_node_t *classperms = NULL, *node = NULL;
    bool complement = false;

    while (p < end && isspace(*p))
        p++;

    if (p == end || *p != ':')
        goto err;
    p++;

    if (debug)
        printf(" :");

    do {
        while (p < end && isspace(*p))
            p++;

        if (p == end)
            goto err;

        if (*p == '{') {
            if (debug && !openparens)
                printf(" {");
            openparens++;
            p++;
            continue;
        }

        if (*p == '}') {
            if (debug && openparens == 1)
                printf(" }");
            if (openparens == 0)
                goto err;
            openparens--;
            p++;
            continue;
        }

        if (*p == '#') {
            while (p < end && *p != '\n')
                p++;
            continue;
        }

        start = p;
        while (p < end && !isspace(*p) && *p != '{' && *p != '}' && *p != ';' && *p != '#')
            p++;

        if (p == start)
            goto err;

        id = calloc(1, p - start + 1);
        if (!id)
            goto err;
        memcpy(id, start, p - start);
        if (debug)
            printf(" %s", id);
        cls = hashtab_search(policydb->p_classes.table, id);
        if (!cls) {
            if (warn)
                fprintf(stderr, "Warning!  Class %s used in neverallow undefined in policy being checked.\n", id);
            continue;
        }

        node = calloc(1, sizeof *node);
        if (!node)
            goto err;
        node->class = cls->s.value;
        node->next = classperms;
        classperms = node;
        free(id);
    } while (p < end && openparens);

    if (p == end)
        goto err;

    if (warn && !classperms)
        fprintf(stderr, "Warning!  Empty class set\n");

    do {
        while (p < end && isspace(*p))
            p++;

        if (p == end)
            goto err;

        if (*p == '~') {
            if (debug)
                printf(" ~");
            complement = true;
            p++;
            while (p < end && isspace(*p))
                p++;
            if (p == end)
                goto err;
        }

        if (*p == '{') {
            if (debug && !openparens)
                printf(" {");
            openparens++;
            p++;
            continue;
        }

        if (*p == '}') {
            if (debug && openparens == 1)
                printf(" }");
            if (openparens == 0)
                goto err;
            openparens--;
            p++;
            continue;
        }

        if (*p == '#') {
            while (p < end && *p != '\n')
                p++;
            continue;
        }

        start = p;
        while (p < end && !isspace(*p) && *p != '{' && *p != '}' && *p != ';' && *p != '#')
            p++;

        if (p == start)
            goto err;

        id = calloc(1, p - start + 1);
        if (!id)
            goto err;
        memcpy(id, start, p - start);
        if (debug)
            printf(" %s", id);

        if (!strcmp(id, "*")) {
            for (node = classperms; node; node = node->next)
                node->data = ~0;
            continue;
        }

        for (node = classperms; node; node = node->next) {
            cls = policydb->class_val_to_struct[node->class-1];
            perm = hashtab_search(cls->permissions.table, id);
            if (cls->comdatum && !perm)
                perm = hashtab_search(cls->comdatum->permissions.table, id);
            if (!perm) {
                if (warn)
                    fprintf(stderr, "Warning!  Permission %s used in neverallow undefined in class %s in policy being checked.\n", id, policydb->p_class_val_to_name[node->class-1]);
                continue;
            }
            node->data |= 1U << (perm->s.value - 1);
        }
        free(id);
    } while (p < end && openparens);

    if (p == end)
        goto err;

    if (complement) {
        for (node = classperms; node; node = node->next)
            node->data = ~node->data;
    }

    if (warn) {
        for (node = classperms; node; node = node->next)
            if (!node->data)
                fprintf(stderr, "Warning!  Empty permission set\n");
    }

    *perms = classperms;
    *ptr = p;
    return 0;
err:
    return -1;
}

static int check_neverallows(policydb_t *policydb, const char *filename)
{
    const char *keyword = "neverallow";
    size_t keyword_size = strlen(keyword), len;
    struct avrule *neverallows = NULL, *avrule;
    int fd;
    struct stat sb;
    char *text, *end, *start;
    char *p;

    fd = open(filename, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "Could not open %s:  %s\n", filename, strerror(errno));
        return -1;
    }
    if (fstat(fd, &sb) < 0) {
        fprintf(stderr, "Can't stat '%s':  %s\n", filename, strerror(errno));
        close(fd);
        return -1;
    }
    text = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    end = text + sb.st_size;
    if (text == MAP_FAILED) {
        fprintf(stderr, "Can't mmap '%s':  %s\n", filename, strerror(errno));
        close(fd);
        return -1;
    }
    close(fd);

    p = text;
    while (p < end) {
        while (p < end && isspace(*p))
            p++;

        if (*p == '#') {
            while (p < end && *p != '\n')
                p++;
            continue;
        }

        start = p;
        while (p < end && !isspace(*p))
            p++;

        len = p - start;
        if (len != keyword_size || strncmp(start, keyword, keyword_size))
            continue;

        if (debug)
            printf("neverallow");

        avrule = calloc(1, sizeof *avrule);
        if (!avrule)
            goto err;

        avrule->specified = AVRULE_NEVERALLOW;

        if (read_typeset(policydb, &p, end, &avrule->stypes, &avrule->flags))
            goto err;

        if (read_typeset(policydb, &p, end, &avrule->ttypes, &avrule->flags))
            goto err;

        if (read_classperms(policydb, &p, end, &avrule->perms))
            goto err;

        while (p < end && *p != ';')
            p++;

        if (p == end || *p != ';')
            goto err;

        if (debug)
            printf(";\n");

        avrule->next = neverallows;
        neverallows = avrule;
    }

    return check_assertions(NULL, policydb, neverallows);
err:
    if (errno == ENOMEM) {
        fprintf(stderr, "Out of memory while parsing %s\n", filename);
    } else
        fprintf(stderr, "Error while parsing %s\n", filename);
    return -1;
}

int main(int argc, char **argv)
{
    char *policy = NULL, *neverallows = NULL;
    struct policy_file pf;
    policydb_t policydb;
    char ch;
    char equiv = 0, diff = 0, dups = 0, permissive = 0;
    int rc = 0;

    struct option long_options[] = {
        {"equiv", no_argument, NULL, 'e'},
        {"debug", no_argument, NULL, 'z'},
        {"diff", no_argument, NULL, 'd'},
        {"dups", no_argument, NULL, 'D'},
        {"neverallow", required_argument, NULL, 'n'},
        {"permissive", no_argument, NULL, 'p'},
        {"policy", required_argument, NULL, 'P'},
        {"warn", no_argument, NULL, 'w'},
        {NULL, 0, NULL, 0}
    };

    while ((ch = getopt_long(argc, argv, "edDpn:P:wz", long_options, NULL)) != -1) {
        switch (ch) {
        case 'e':
            equiv = 1;
            break;
        case 'd':
            diff = 1;
            break;
        case 'D':
            dups = 1;
            break;
        case 'n':
            neverallows = optarg;
            break;
        case 'p':
            permissive = 1;
            break;
        case 'P':
            policy = optarg;
            break;
        case 'w':
            warn = 1;
            break;
        case 'z':
            debug = 1;
            break;
        default:
            usage(argv[0]);
        }
    }

    if (!policy || (!equiv && !diff && !dups && !permissive && !neverallows))
        usage(argv[0]);

    if (load_policy(policy, &policydb, &pf))
        exit(1);

    if (equiv || diff)
        analyze_types(&policydb, equiv, diff);

    if (dups)
        find_dups(&policydb);

    if (permissive)
        list_permissive(&policydb);

    if (neverallows)
        rc |= check_neverallows(&policydb, neverallows);

    policydb_destroy(&policydb);

    return rc;
}
