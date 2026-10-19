/*
 * pam_facemac — face unlock for sudo, backed by the FaceMac app.
 *
 * Asks the FaceMac app of the target user (over a Unix socket in their
 * Application Support folder) to recognise them. The socket's server must be
 * the FaceMac app signed by the pinned certificate, so a random user process
 * cannot answer "OK" and hand out root. Any failure returns PAM_AUTH_ERR (or
 * PAM_IGNORE when it does not apply) so the next module — Touch ID, then the
 * password — runs as usual.
 */
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

#define PAM_SM_AUTH
#include <security/pam_appl.h>
#include <security/pam_modules.h>

#ifndef FACEMAC_EXEC
#define FACEMAC_EXEC "/Applications/boringNotch.app/Contents/MacOS/boringNotch"
#endif
#ifndef FACEMAC_REQUIREMENT
#error "FACEMAC_REQUIREMENT must be defined at build time"
#endif
#define REPLY_TIMEOUT_MS 305000  /* prompts wait up to 5 min for a face */

static void info(pam_handle_t *pamh, const char *msg) {
    const struct pam_conv *conv = NULL;
    if (pam_get_item(pamh, PAM_CONV, (const void **)&conv) != PAM_SUCCESS || !conv || !conv->conv) return;
    struct pam_message m = { PAM_TEXT_INFO, (char *)msg };
    const struct pam_message *mp = &m;
    struct pam_response *resp = NULL;
    conv->conv(1, &mp, &resp, conv->appdata_ptr);
    if (resp) { free(resp->resp); free(resp); }
}

/* True when the peer is the pinned, validly signed FaceMac app. */
static int peer_is_facemac(int fd, uid_t expected_uid) {
    uid_t uid; gid_t gid;
    if (getpeereid(fd, &uid, &gid) != 0 || uid != expected_uid) return 0;

    pid_t pid = 0;
    socklen_t len = sizeof(pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) != 0 || pid <= 0) return 0;

    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0 || strcmp(path, FACEMAC_EXEC) != 0) return 0;

    int ok = 0;
    CFNumberRef cfpid = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *keys[] = { kSecGuestAttributePid };
    const void *vals[] = { cfpid };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    SecRequirementRef req = NULL;
    if (SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecRequirementCreateWithString(CFSTR(FACEMAC_REQUIREMENT), kSecCSDefaultFlags, &req) == errSecSuccess &&
        SecCodeCheckValidity(code, kSecCSDefaultFlags, req) == errSecSuccess) {
        ok = 1;
    }
    if (req) CFRelease(req);
    if (code) CFRelease(code);
    CFRelease(attrs);
    CFRelease(cfpid);
    return ok;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)flags; (void)argc; (void)argv;

    /* Someone at the camera must not approve a remote session. */
    const char *rhost = NULL;
    if (pam_get_item(pamh, PAM_RHOST, (const void **)&rhost) == PAM_SUCCESS && rhost && *rhost) return PAM_IGNORE;
    if (getenv("SSH_CONNECTION") || getenv("SSH_CLIENT") || getenv("SSH_TTY")) return PAM_IGNORE;

    const char *user = NULL;
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || !user) return PAM_IGNORE;
    struct passwd *pw = getpwnam(user);
    if (!pw || !pw->pw_dir) return PAM_IGNORE;

    char sock_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    if (snprintf(sock_path, sizeof(sock_path), "%s/Library/Application Support/FaceMac/auth.sock", pw->pw_dir)
        >= (int)sizeof(sock_path)) return PAM_IGNORE;

    struct stat st;
    if (lstat(sock_path, &st) != 0 || !S_ISSOCK(st.st_mode) || st.st_uid != pw->pw_uid) return PAM_IGNORE;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return PAM_IGNORE;
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, sock_path, sizeof(addr.sun_path));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return PAM_IGNORE; }

    if (!peer_is_facemac(fd, pw->pw_uid)) { close(fd); return PAM_IGNORE; }

    const char *service = NULL;
    pam_get_item(pamh, PAM_SERVICE, (const void **)&service);
    char line[256];
    snprintf(line, sizeof(line), "AUTH %s %s\n", service ? service : "pam", user);
    if (write(fd, line, strlen(line)) < 0) { close(fd); return PAM_IGNORE; }

    info(pamh, "Face ID: look at the notch…");

    struct pollfd p = { fd, POLLIN, 0 };
    char reply[8] = {0};
    int rc = PAM_AUTH_ERR;
    if (poll(&p, 1, REPLY_TIMEOUT_MS) == 1 && read(fd, reply, sizeof(reply) - 1) >= 2 &&
        strncmp(reply, "OK", 2) == 0) {
        rc = PAM_SUCCESS;
    }
    close(fd);
    if (rc != PAM_SUCCESS) info(pamh, "Face ID: not recognised");
    return rc;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}
