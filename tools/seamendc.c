#include <getopt.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <cil/cil.h>
#include <cil/android.h>
#include <sepol/policydb.h>
#include "sepol/handle.h"

void usage(const char *prog)
{
    printf("Usage: %s [OPTION]... FILE...\n", prog);
    printf("Takes a binary policy file as input and applies the rules and definitions specified ");
    printf("in the provided FILEs. Each FILE must be a policy file in CIL format.\n");
    printf("\n");
    printf("Options:\n");
    printf("  -b, --base=<file>          (required) base binary policy.\n");
    printf("  -o, --output=<file>        (required) write binary policy to <file>\n");
    printf("  -v, --verbose              increment verbosity level\n");
    printf("  -h, --help                 display usage information\n");
    exit(1);
}

/*
 * Read binary policy file from path into the allocated pdb.
 *
 * We first read the binary policy into memory, and then we parse it to a
 * policydb object using sepol_policydb_from_image. This combination is slightly
 * faster than using sepol_policydb_read that reads the binary file in small
 * chunks at a time.
 */
static int read_binary_policy(char *path, sepol_policydb_t *pdb)
{
    int rc = SEPOL_OK;
    char *buff = NULL;
    sepol_handle_t *handle = NULL;

    FILE *file = fopen(path, "r");
    if (!file) {
        fprintf(stderr, "Could not open %s: %s.\n", path, strerror(errno));
        rc = SEPOL_ERR;
        goto exit;
    }

    struct stat binarydata;
    rc = stat(path, &binarydata);
    if (rc == -1) {
        fprintf(stderr, "Could not stat %s: %s.\n", path, strerror(errno));
        goto exit;
    }

    uint32_t file_size = binarydata.st_size;
    if (!file_size) {
        fprintf(stderr, "Binary policy file is empty.\n");
        rc = SEPOL_ERR;
        goto exit;
    }

    buff = malloc(file_size);
    if (buff == NULL) {
        perror("malloc failed");
        rc = SEPOL_ERR;
        goto exit;
    }

    rc = fread(buff, file_size, 1, file);
    if (rc != 1) {
        fprintf(stderr, "Failure reading %s: %s.\n", path, strerror(errno));
        rc = SEPOL_ERR;
        goto exit;
    }

    handle = sepol_handle_create();
    if (!handle) {
        perror("Could not create policy handle");
        rc = SEPOL_ERR;
        goto exit;
    }

    rc = sepol_policydb_from_image(handle, buff, file_size, pdb);
    if (rc != 0) {
        fprintf(stderr, "Failed to read binary policy: %d.\n", rc);
    }

exit:
    if (file != NULL && fclose(file) == EOF && rc == SEPOL_OK) {
        perror("Failure closing binary file");
        rc = SEPOL_ERR;
    }
    if(handle != NULL) {
        sepol_handle_destroy(handle);
    }
    free(buff);
    return rc;
}

/*
 * read_cil_files - Initialize db and parse CIL input files.
 */
static int read_cil_files(struct cil_db **db, char **paths,
                          unsigned int n_files)
{
    int rc = SEPOL_ERR;
    FILE *file = NULL;
    char *buff = NULL;

    for (int i = 0; i < n_files; i++) {
        char *path = paths[i];

        file = fopen(path, "r");
        if (file == NULL) {
            rc = SEPOL_ERR;
            fprintf(stderr, "Could not open %s: %s.\n", path, strerror(errno));
            goto file_err;
        }

        struct stat filedata;
        rc = stat(path, &filedata);
        if (rc == -1) {
            fprintf(stderr, "Could not stat %s: %s.\n", path, strerror(errno));
            goto err;
        }

        uint32_t file_size = filedata.st_size;
        buff = malloc(file_size);
        if (buff == NULL) {
            perror("malloc failed");
            rc = SEPOL_ERR;
            goto err;
        }

        rc = fread(buff, file_size, 1, file);
        if (rc != 1) {
            fprintf(stderr, "Failure reading %s: %s.\n", path, strerror(errno));
            rc = SEPOL_ERR;
            goto err;
        }
        fclose(file);
        file = NULL;

        /* create parse_tree */
        rc = cil_add_file(*db, path, buff, file_size);
        if (rc != SEPOL_OK) {
            fprintf(stderr, "Failure adding %s to parse tree.\n", path);
            goto parse_err;
        }
        free(buff);
        buff = NULL;
    }

    return SEPOL_OK;
err:
    fclose(file);
parse_err:
    free(buff);
file_err:
    return rc;
}

/*
 * Write binary policy in pdb to file at path.
 */
static int write_binary_policy(sepol_policydb_t *pdb, char *path)
{
    int rc = SEPOL_OK;

    FILE *file = fopen(path, "w");
    if (file == NULL) {
        fprintf(stderr, "Could not open %s: %s.\n", path, strerror(errno));
        rc = SEPOL_ERR;
        goto exit;
    }

    struct sepol_policy_file *pf = NULL;
    rc = sepol_policy_file_create(&pf);
    if (rc != 0) {
        fprintf(stderr, "Failed to create policy file: %d.\n", rc);
        goto exit;
    }
    sepol_policy_file_set_fp(pf, file);

    rc = sepol_policydb_write(pdb, pf);
    if (rc != 0) {
        fprintf(stderr, "failed to write binary policy: %d.\n", rc);
        goto exit;
    }

exit:
    if (file != NULL && fclose(file) == EOF && rc == SEPOL_OK) {
        perror("Failure closing binary file");
        rc = SEPOL_ERR;
    }
    return rc;
}

int main(int argc, char *argv[])
{
    char *base = NULL;
    char *output = NULL;
    enum cil_log_level log_level = CIL_ERR;
    static struct option long_opts[] = {{"base", required_argument, 0, 'b'},
                                        {"output", required_argument, 0, 'o'},
                                        {"verbose", no_argument, 0, 'v'},
                                        {"help", no_argument, 0, 'h'},
                                        {0, 0, 0, 0}};

    while (1) {
        int opt_index = 0;
        int opt_char = getopt_long(argc, argv, "b:o:vh", long_opts, &opt_index);
        if (opt_char == -1) {
            break;
        }
        switch (opt_char)
        {
        case 'b':
            base = optarg;
            break;
        case 'o':
            output = optarg;
            break;
        case 'v':
            log_level++;
            break;
        case 'h':
            usage(argv[0]);
        default:
            fprintf(stderr, "Unsupported option: %s.\n", optarg);
            usage(argv[0]);
        }
    }
    if (base == NULL || output == NULL) {
        fprintf(stderr, "Please specify required arguments.\n");
        usage(argv[0]);
    }

    cil_set_log_level(log_level);

    // Initialize and read input policydb file.
    sepol_policydb_t *pdb = NULL;
    int rc = sepol_policydb_create(&pdb);
    if (rc != 0) {
        fprintf(stderr, "Could not create policy db: %d.\n", rc);
        exit(rc);
    }

    rc = read_binary_policy(base, pdb);
    if (rc != SEPOL_OK) {
        fprintf(stderr, "Failed to read binary policy: %d.\n", rc);
        exit(rc);
    }

    // Initialize cil_db.
    struct cil_db *incremental_db = NULL;
    cil_db_init(&incremental_db);
    cil_set_attrs_expand_generated(incremental_db, 1);

    // Read input cil files and compile them into cil_db.
    rc = read_cil_files(&incremental_db, argv + optind, argc - optind);
    if (rc != SEPOL_OK) {
        fprintf(stderr, "Failed to read CIL files: %d.\n", rc);
        exit(rc);
    }

    rc = cil_compile(incremental_db);
    if (rc != SEPOL_OK) {
        fprintf(stderr, "Failed to compile cildb: %d.\n", rc);
        exit(rc);
    }

    //  Amend the policydb.
    rc = cil_amend_policydb(incremental_db, pdb);
    if (rc != SEPOL_OK) {
        fprintf(stderr, "Failed to build policydb.\n");
        exit(rc);
    }

    rc = write_binary_policy(pdb, output);
    if (rc != SEPOL_OK) {
        fprintf(stderr, "Failed to write binary policy: %d.\n", rc);
        exit(rc);
    }
}
