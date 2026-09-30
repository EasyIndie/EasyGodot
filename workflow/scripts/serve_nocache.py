#!/usr/bin/env python3
"""本地静态服务器：多线程 + 禁用缓存。

用途：托管 Godot Web 构建产物。

两个坑（都踩过）：
1. index.pck（~14MB）/ index.wasm（~39MB）体积大，浏览器极易沿用旧缓存，
   造成「改了代码但页面没变」。→ 所有响应加 Cache-Control: no-store。
2. 单线程服务器（socketserver.TCPServer / python -m http.server）只要有一个
   客户端中途断开下载，就会阻塞在 send() 上，之后所有请求全部挂起，浏览器
   只能回退到旧缓存。→ 用 ThreadingHTTPServer 并发处理。

用法: python3 serve_nocache.py [port] [directory]
"""
import http.server
import os
import sys


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # 支持 keep-alive / Range

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    directory = sys.argv[2] if len(sys.argv) > 2 else "."
    os.chdir(directory)
    socketserver_timeout = 30
    with Server(("", port), NoCacheHandler) as httpd:
        httpd.timeout = socketserver_timeout
        print("serving %s at http://localhost:%d  (no-cache, threaded)" % (os.getcwd(), port), file=sys.stderr)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
