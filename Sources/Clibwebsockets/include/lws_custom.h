#ifndef lws_custom_h
#define lws_custom_h

int ws_write_bin_text(struct lws *wsi, char *data, size_t len, int is_text, int is_start, int is_fin);

int ws_write_ping(struct lws *wsi);

int ws_write_pong(struct lws *wsi);

void *lws_context_creation_info_zero(struct lws_context_creation_info *sz);
void *lws_client_connect_info_zero(struct lws_client_connect_info *sz);
void *lws_protocols_zero(struct lws_protocols *sz);
void *lws_extension_zero(struct lws_extension *sz);

void ws_set_guiduid(struct lws_context_creation_info *info);

void ws_set_ssl_connection(struct lws_client_connect_info *clientInfo);

void ws_context_user_nullify(struct lws_context *context);

#endif /* lws_custom_h */
