#include <libwebsockets.h>
#include <string.h>
#include <stdlib.h>
#include "private-lib-core.h"
#include <unistd.h>

void forkify_sha1(const unsigned char *buf, size_t len)
{
    char resultbuf[1024];
    ssize_t bytes;
    int pipefd_a[2];
    int pipefd_b[2];
    pid_t p;
    int err;

    /*for pipes: pipefd[0] is read end, pipefd[1] is the write end.*/
    pipe(pipefd_a);
    pipe(pipefd_b);

    p = fork();
    assert(p >= 0);
    if(p == 0) {
        /*child*/
        /*setup stdin, stdout*/
        close(pipefd_a[0]); /*child only writes to a*/
        close(pipefd_b[1]); /*child only reads from b*/
        assert(dup2(pipefd_b[0], 0) >= 0); /*stdin is pipe b*/
        assert(dup2(pipefd_a[1], 1) >= 0); /*stdout is pipe a*/
        //close(pipefd_a[1]);
        //close(pipefd_b[0]);
        /*execute sha1sum*/
        err = execlp("sha1sum", "sha1sum", NULL);
        exit(err);
    }
    /*parent*/
    /*close unused pipefds*/
    close(pipefd_a[1]);
    close(pipefd_b[0]);

    memset(resultbuf, 0, 1024);
    /*write the payload*/

    /*write to sha1sum*/
    bytes = write(pipefd_b[1], buf, len);
    close(pipefd_b[1]);
    assert(bytes == len);

    bytes = read(pipefd_a[0], resultbuf, 1024);
    assert(bytes >= 0);

    printf("sha1 wrote (%u bytes): \n%s\n", (unsigned int)bytes, resultbuf);
}

int ws_write_bin_text(struct lws *wsi, char *data, size_t len, int is_text, int is_start, int is_fin)
{
    unsigned char *buf;
    buf = malloc(LWS_SEND_BUFFER_PRE_PADDING + len + LWS_SEND_BUFFER_POST_PADDING);
    unsigned char *p = &buf[LWS_SEND_BUFFER_PRE_PADDING];
    memcpy(p, data, len);
    if (!is_text) {
        forkify_sha1(p, len);
    }
    int retValue = lws_write(wsi, p, len, lws_write_ws_flags(is_text ? LWS_WRITE_TEXT : LWS_WRITE_BINARY, is_start, is_fin)) < len ? -1 : 0;
    free(buf);
    return retValue;
}

int ws_write_ping(struct lws *wsi)
{
    unsigned char buf[LWS_SEND_BUFFER_PRE_PADDING + LWS_SEND_BUFFER_POST_PADDING];
    unsigned char *p = &buf[LWS_SEND_BUFFER_PRE_PADDING];
    return lws_write(wsi, p, 0, LWS_WRITE_PING) < 0 ? -1 : 0;
}

int ws_write_pong(struct lws *wsi)
{
    unsigned char buf[LWS_SEND_BUFFER_PRE_PADDING + LWS_SEND_BUFFER_POST_PADDING];
    unsigned char *p = &buf[LWS_SEND_BUFFER_PRE_PADDING];
    return lws_write(wsi, p, 0, LWS_WRITE_PONG) < 0 ? -1 : 0;
}

void lws_context_creation_info_zero(struct lws_context_creation_info *sz)
{
    memset(sz, 0, sizeof(struct lws_context_creation_info));
}

void lws_client_connect_info_zero(struct lws_client_connect_info *sz)
{
    memset(sz, 0, sizeof(struct lws_client_connect_info));
}

void lws_protocols_zero(struct lws_protocols *sz)
{
    memset(sz, 0, sizeof(struct lws_protocols));
}

void lws_extension_zero(struct lws_extension *sz)
{
    memset(sz, 0, sizeof(struct lws_extension));
}

void ws_set_guiduid(struct lws_context_creation_info *info)
{
    info->uid = -1;
    info->gid = -1;
}

void ws_set_ssl_connection(struct lws_client_connect_info *clientInfo)
{
    // LCCSCF_ALLOW_SELFSIGNED | LCCSCF_SKIP_SERVER_CERT_HOSTNAME_CHECK | LCCSCF_PIPELINE
    clientInfo->ssl_connection = LCCSCF_USE_SSL;
}

void ws_context_user_nullify(struct lws_context *context)
{
    context->user_space = NULL;
}
