/* Loads a PAM service's policy (which loads every module in it) and reports
 * whether that worked. Used by install.sh before and after editing sudo_local
 * so a module that fails to load can never lock sudo out. */
#include <security/pam_appl.h>
#include <stdio.h>

static int conv(int n, const struct pam_message **m, struct pam_response **r, void *d) {
    (void)n; (void)m; (void)r; (void)d;
    return PAM_CONV_ERR;
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: pamcheck <service> <user>\n"); return 2; }
    struct pam_conv c = { conv, NULL };
    pam_handle_t *h = NULL;
    int rc = pam_start(argv[1], argv[2], &c, &h);
    printf("pam_start(%s) = %d %s\n", argv[1], rc, rc == PAM_SUCCESS ? "OK" : pam_strerror(h, rc));
    if (h) pam_end(h, rc);
    return rc == PAM_SUCCESS ? 0 : 1;
}
