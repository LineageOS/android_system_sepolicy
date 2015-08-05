#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <sepol/sepol.h>
#include <selinux/selinux.h>
#include <selinux/label.h>

static int nerr;

static int validate(char **contextp)
{
  char *context = *contextp;
  if (sepol_check_context(context) < 0) {
    nerr++;
    return -1;
  }
  return 0;
}

static void usage(char *name) {
    fprintf(stderr, "usage1:  %s [-p] sepolicy context_file\n\n", name);
    fprintf(stderr, "Parses a context file and checks for syntax errors.\n");
    fprintf(stderr, "The context_file is assumed to be a file_contexts file\n");
    fprintf(stderr, "unless the -p option is used to indicate the property backend.\n\n");

    fprintf(stderr, "usage2:  %s -c file_contexts1 file_contexts2\n\n", name);
    fprintf(stderr, "Compares two file contexts files and reports one of subset, equal, superset, or incomparable.\n");
    fprintf(stderr, "\n");
    exit(1);
}

int main(int argc, char **argv)
{
  struct selinux_opt opts[] = {
    { SELABEL_OPT_VALIDATE, (void*)1 },
    { SELABEL_OPT_PATH, NULL }
  };

  // Default backend unless changed by input argument.
  unsigned int backend = SELABEL_CTX_FILE;

  FILE *fp;
  bool compare = false;
  struct selabel_handle *sehnd[2];
  char c;

  while ((c = getopt(argc, argv, "cph")) != -1) {
    switch (c) {
      case 'c':
        compare = true;
        break;
      case 'p':
        backend = SELABEL_CTX_ANDROID_PROP;
        break;
      case 'h':
      default:
        usage(argv[0]);
        break;
    }
  }

  int index = optind;
  if (argc - optind != 2) {
    usage(argv[0]);
  }

  if (compare && backend != SELABEL_CTX_FILE) {
    usage(argv[0]);
  }

  if (compare) {
    enum selabel_cmp_result result;
    char *result_str[] = { "subset", "equal", "superset", "incomparable" };
    int i;

    opts[0].value = NULL; /* not validating against a policy when comparing */

    for (i = 0; i < 2; i++) {
        opts[1].value = argv[index+i];
        sehnd[i] = selabel_open(backend, opts, 2);
        if (!sehnd[i]) {
            fprintf(stderr, "Error loading context file from %s\n", argv[index+i]);
            exit(1);
        }
    }

    result = selabel_cmp(sehnd[0], sehnd[1]);
    for (i = 0; i < 2; i++)
        selabel_close(sehnd[i]);
    printf("%s\n", result_str[result]);
    exit(0);
  }

  // remaining args are sepolicy file and context file
  char *sepolicyFile = argv[index];
  char *contextFile = argv[index + 1];

  fp = fopen(sepolicyFile, "r");
  if (!fp) {
    perror(sepolicyFile);
    exit(1);
  }
  if (sepol_set_policydb_from_file(fp) < 0) {
    fprintf(stderr, "Error loading policy from %s\n", sepolicyFile);
    exit(1);
  }

  selinux_set_callback(SELINUX_CB_VALIDATE,
                       (union selinux_callback)&validate);

  opts[1].value = contextFile;

  sehnd[0] = selabel_open(backend, opts, 2);
  if (!sehnd[0]) {
    fprintf(stderr, "Error loading context file from %s\n", contextFile);
    exit(1);
  }
  if (nerr) {
    fprintf(stderr, "Invalid context file found in %s\n", contextFile);
    exit(1);
  }

  exit(0);
}
