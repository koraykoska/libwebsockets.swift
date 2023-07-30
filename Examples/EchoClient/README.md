# EchoClient

This simple websocket client connects to a locally running websocket echo server, sends a text, waits for the response,
and closes the connection.

Run a local websocket server using the below command:

```bash
docker run -it --rm -p 10000:8080 jmalloc/echo-server
```

Alternatively use wscat:

```bash
wscat --listen 10000
```

You can close the server with `CTRL + C` after you are done.

Run `swift run` to test this example.
