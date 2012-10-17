#include <stdio.h>
#include <stdlib.h>
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

int main(int argc, char **argv)
{
  struct selinux_opt opts[] = {
    { SELABEL_OPT_VALIDATE, (void*)1 },
    { SELABEL_OPT_PATH, NULL }
  };
  FILE *fp;
  struct selabel_handle *sehnd;

  if (argc != 3) {
    fprintf(stderr, "usage:  %s policy file_contexts\n", argv[0]);
    exit(1);
  }

  fp = fopen(argv[1], "r");
  if (!fp) {
    perror(argv[1]);
    exit(2);
  }
  if (sepol_set_policydb_from_file(fp) < 0) {
    fprintf(stderr, "Error loading policy from %s\n", argv[1]);
    exit(3);
  }

  selinux_set_callback(SELINUX_CB_VALIDATE,
                       (union selinux_callback)&validate);


  opts[1].value = argv[2];
  sehnd = selabel_open(SELABEL_CTX_FILE, opts, 2);
  if (!sehnd) {
    fprintf(stderr, "Error loading file contexts from %s\n", argv[2]);
    exit(4);
  }
  if (nerr) {
    fprintf(stderr, "Invalid file contexts found in %s\n", argv[2]);
    exit(5);
  }
  exit(0);
}
