#ifndef lws_custom_h
#define lws_custom_h

int ws_write_bin(struct lws *wsi, char *bin, size_t len, int is_start, int is_fin);

int ws_write_text(struct lws *wsi, char *string, int is_start, int is_fin);

int ws_write_ping(struct lws *wsi);

int ws_write_pong(struct lws *wsi);

void *lws_context_creation_info_zero(struct lws_context_creation_info *sz);
void *lws_client_connect_info_zero(struct lws_client_connect_info *sz);
void *lws_protocols_zero(struct lws_protocols *sz);

void ws_set_guiduid(struct lws_context_creation_info *info);

void ws_set_ssl_connection(struct lws_client_connect_info *clientInfo);

void *ws_context_user(struct lws_context *context);

#endif /* lws_custom_h */
