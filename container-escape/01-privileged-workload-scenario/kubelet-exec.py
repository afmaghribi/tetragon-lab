#!/usr/bin/env python3
"""Minimal kubelet /exec client over the channels.k8s.io websocket protocol.

Reaches a static pod that has NO API object (so kubectl exec cannot address
it) by talking straight to the kubelet :10250 stream endpoint. Authenticate
with either a client certificate (from a kubeconfig) or a bearer token
(ServiceAccount token / kubectl create token).

Usage (client certificate):
    python3 kubelet-exec.py --client-cert client.crt --client-key client.key \
      <NODE_IP> <NAMESPACE> <POD> <CONTAINER> -- <command> [args...]

Usage (bearer token — no certs needed):
    export TOKEN=$(kubectl create token <sa> -n <ns> --duration=6h)
    python3 kubelet-exec.py --token "$TOKEN" \
      <NODE_IP> <NAMESPACE> <POD> <CONTAINER> -- <command> [args...]

The token/SA must be allowed to call the kubelet API, e.g. bound to
system:kubelet-api-admin:
    kubectl create clusterrolebinding token:kubelet-admin \
      --clusterrole=system:kubelet-api-admin --serviceaccount=<ns>:<sa>

Requires python3 + the `websockets` package (pip install websockets).

Stream framing (v4.channel.k8s.io): every frame is prefixed with one byte
that selects the stream: 0 = stdin, 1 = stdout, 2 = stderr, 3 = error.
"""
import argparse
import asyncio
import ssl
import sys
import urllib.parse

import websockets


def build_tls_context(client_cert, client_key):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    if client_cert:
        ctx.load_cert_chain(client_cert, client_key)
    return ctx


def auth_headers(bearer_token):
    if bearer_token:
        return [("Authorization", f"Bearer {bearer_token}")]
    return []


async def exec_command(host, port, namespace, pod, container, argv,
                       client_cert, client_key, bearer_token):
    qs = [("command", c) for c in argv]
    qs += [("input", "1"), ("output", "1"), ("error", "1")]
    path = f"/exec/{namespace}/{pod}/{container}?" + urllib.parse.urlencode(qs)
    uri = f"wss://{host}:{port}{path}"

    ssl_ctx = build_tls_context(client_cert, client_key)

    try:
        async with websockets.connect(
            uri,
            ssl=ssl_ctx,
            additional_headers=auth_headers(bearer_token),
            subprotocols=["v4.channel.k8s.io", "v3.channel.k8s.io", "channel.k8s.io"],
            max_size=16 * 1024 * 1024,
        ) as ws:
            if ws.subprotocol is None:
                print("kubelet did not negotiate a channel subprotocol",
                      file=sys.stderr)
                return 1

            async def shouter():
                while True:
                    try:
                        frame = await ws.recv()
                    except websockets.exceptions.ConnectionClosed:
                        break
                    if not isinstance(frame, bytes) or not frame:
                        continue
                    channel = frame[0]
                    payload = frame[1:]
                    if channel == 1:
                        sys.stdout.buffer.write(payload)
                        sys.stdout.buffer.flush()
                    elif channel in (2, 3):
                        sys.stderr.buffer.write(payload)
                        sys.stderr.buffer.flush()

            async def feeder():
                loop = asyncio.get_event_loop()
                while True:
                    line = await loop.run_in_executor(None, sys.stdin.buffer.readline)
                    if not line:
                        break
                    await ws.send(b"\x00" + line)

            await asyncio.gather(shouter(), feeder())
    except Exception as exc:  # noqa: BLE001 - report and exit nonzero
        print(f"kubelet-exec error: {exc}", file=sys.stderr)
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--client-cert", default=None,
                    help="admin client cert PEM (omit when using --token)")
    ap.add_argument("--client-key", default=None,
                    help="admin client key PEM (omit when using --token)")
    ap.add_argument("--token", default=None,
                    help="bearer token (SA token / kubectl create token); "
                         "omit when using --client-cert/--client-key")
    ap.add_argument("hostport", help="<node-ip>[:10250]")
    ap.add_argument("namespace")
    ap.add_argument("pod")
    ap.add_argument("container")
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    host, _, port = args.hostport.partition(":")
    port = port or "10250"

    if (args.client_cert or args.client_key) and args.token:
        print("use either --token OR --client-cert/--client-key, not both",
              file=sys.stderr)
        return 2
    if not args.token and not (args.client_cert and args.client_key):
        print("need --token, or --client-cert + --client-key", file=sys.stderr)
        return 2

    cmd = args.command[1:] if args.command and args.command[0] == "--" else args.command
    if not cmd:
        print("no command given (use `--` before the command)", file=sys.stderr)
        return 2

    return asyncio.run(exec_command(
        host, port, args.namespace, args.pod, args.container, cmd,
        args.client_cert, args.client_key, args.token,
    ))


if __name__ == "__main__":
    sys.exit(main())