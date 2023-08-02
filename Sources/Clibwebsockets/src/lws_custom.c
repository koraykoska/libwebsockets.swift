#include <libwebsockets.h>
#include <string.h>
#include <stdlib.h>
#include "private-lib-core.h"

int ws_write_bin(struct lws *wsi, char *bin, size_t len, int is_start, int is_fin)
{
    unsigned char *buf;
    buf = malloc(LWS_SEND_BUFFER_PRE_PADDING + len + LWS_SEND_BUFFER_POST_PADDING);
    unsigned char *p = &buf[LWS_SEND_BUFFER_PRE_PADDING];
    memcpy(p, bin, len);
    int retValue = lws_write(wsi, p, len, lws_write_ws_flags(LWS_WRITE_BINARY, is_start, is_fin)) < len ? -1 : 0;
    free(buf);
    return retValue;
}

int ws_write_text(struct lws *wsi, char *string, int is_start, int is_fin)
{
    size_t len = strlen(string);
    unsigned char *buf;
    buf = malloc(LWS_SEND_BUFFER_PRE_PADDING + len + LWS_SEND_BUFFER_POST_PADDING);
    unsigned char *p = &buf[LWS_SEND_BUFFER_PRE_PADDING];
    memcpy(p, string, len);
    int retValue = lws_write(wsi, p, len, lws_write_ws_flags(LWS_WRITE_TEXT, is_start, is_fin)) < len ? -1 : 0;
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

void *lws_context_creation_info_zero(struct lws_context_creation_info *sz)
{
    memset(sz, 0, sizeof(struct lws_context_creation_info));
}

void *lws_client_connect_info_zero(struct lws_client_connect_info *sz)
{
    memset(sz, 0, sizeof(struct lws_client_connect_info));
}

void *lws_protocols_zero(struct lws_protocols *sz)
{
    memset(sz, 0, sizeof(struct lws_protocols));
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

void *ws_context_user(struct lws_context *context)
{
    return context->user_space;
}
