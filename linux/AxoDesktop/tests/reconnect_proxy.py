"""Owned-fixture transport cuts. No production sockets, daemon restarts or master flag changes."""
import array
import json
import pathlib
import select
import socket
import struct
import threading
import time
import os


class OwnedProxy:
    def __init__(self, run, upstream):
        if os.environ.get('AXO_DESKTOP_ISOLATED') != '1':
            raise RuntimeError('owned desktop fixture required')
        self.rpc_path = pathlib.Path(run) / 'proxy-rpc.sock'
        self.attach_path = pathlib.Path(run) / 'proxy-attach.sock'
        self.upstream = str(upstream)
        self.lock = threading.Lock()
        self.connections = {'rpc': set(), 'attach': set()}
        self.opened = {'rpc': 0, 'attach': 0}
        self.methods = []
        self.errors = []
        self.available = True
        self.lose_viewport_ack = False
        self.stopping = False
        self.attach_gate = threading.Event()
        self.attach_gate.set()
        self.listeners = []
        self.threads = []
        for kind, path in [('rpc', self.rpc_path), ('attach', self.attach_path)]:
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(path))
            listener.listen()
            listener.settimeout(.1)
            self.listeners.append(listener)
            self._start(self._accept, listener, kind)

    def _start(self, target, *args):
        thread = threading.Thread(target=target, args=args, daemon=True)
        self.threads.append(thread)
        thread.start()

    def _accept(self, listener, kind):
        while not self.stopping:
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self._start(self._serve, client, kind)

    @staticmethod
    def _line(sock):
        line = bytearray()
        while len(line) < 32 * 1024 * 1024:
            byte = sock.recv(1)
            if not byte:
                raise EOFError()
            line.extend(byte)
            if byte == b'\n':
                return bytes(line)
        raise ValueError('oversized fixture frame')

    @staticmethod
    def _exact(sock, length):
        data = bytearray()
        while len(data) < length:
            chunk = sock.recv(length - len(data))
            if not chunk:
                raise EOFError()
            data.extend(chunk)
        return bytes(data)

    def _rewrite(self, value):
        if isinstance(value, dict):
            return {key: str(self.attach_path) if key == 'attachSocketPath' else self._rewrite(item)
                    for key, item in value.items()}
        if isinstance(value, list):
            return [self._rewrite(item) for item in value]
        return value

    def _serve(self, client, kind):
        server = socket.socket(socket.AF_UNIX)
        pair = (client, server)
        with self.lock:
            self.connections[kind].add(pair)
            self.opened[kind] += 1
        try:
            if not self.available:
                return
            if kind == 'rpc':
                server.connect(self.upstream)
                while True:
                    request = self._line(client)
                    method = json.loads(request)['method']
                    with self.lock:
                        self.methods.append(method)
                    assert method in ['axo.protocol.negotiate', 'axo.session.catalog',
                                      'axo.daemon.health', 'axo.session.events.stream',
                                      'axo.client.viewport.set.v2'], method
                    server.sendall(request)
                    response = self._rewrite(json.loads(self._line(server)))
                    if method == 'axo.client.viewport.set.v2' and self.lose_viewport_ack:
                        return  # The real fixture daemon committed; only its acknowledgement is lost.
                    client.sendall(json.dumps(response).encode() + b'\n')
                    if method == 'axo.session.events.stream':
                        self._output(server, client, lines=True)
                        return
            else:
                request = self._line(client)
                assert request.startswith(b'3:'), request
                while not self.attach_gate.wait(.05):
                    if self.stopping:
                        return
                server.connect(str(pathlib.Path(self.upstream).parent / 'attach.sock'))
                server.sendall(request)
                header = self._exact(server, 8)
                if struct.unpack('>Q', header)[0] == 2**64 - 1:
                    client.sendall(header + self._exact(server, 1))
                    return
                grid = self._exact(server, 4)
                marker, ancillary, flags, _ = server.recvmsg(1, socket.CMSG_SPACE(4), socket.MSG_CMSG_CLOEXEC)
                descriptors = array.array('i')
                for level, code, data in ancillary:
                    if level == socket.SOL_SOCKET and code == socket.SCM_RIGHTS:
                        descriptors.frombytes(data[:len(data) - len(data) % descriptors.itemsize])
                try:
                    assert len(descriptors) == 1 and marker == b'1'
                    assert not flags & (socket.MSG_CTRUNC | socket.MSG_TRUNC)
                    assert not os.get_inheritable(descriptors[0]), 'proxy receipt must be CLOEXEC'
                    # Preserve descriptor marker positioning: never attach rights to the header.
                    client.sendall(header + grid)
                    client.sendmsg([marker], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, descriptors)])
                finally:
                    for descriptor in descriptors:
                        os.close(descriptor)
                self._output(server, client, lines=False)
        except (OSError, EOFError):
            pass  # An intentional transport cut or ordinary frontend detach.
        except Exception as error:
            self.errors.append(repr(error))
        finally:
            for sock in pair:
                sock.close()
            with self.lock:
                self.connections[kind].discard(pair)

    def _output(self, server, client, lines):
        while not self.stopping:
            readable, _, _ = select.select([server, client], [], [], .1)
            if client in readable:
                return  # Stream clients send nothing after the handshake; EOF means detach.
            if server in readable:
                data = self._line(server) if lines else server.recv(65536)
                if not data:
                    return
                client.sendall(data)

    def cut(self, kind):
        with self.lock:
            pairs = list(self.connections[kind])
        for pair in pairs:
            for sock in pair:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def count(self, kind):
        with self.lock:
            return len(self.connections[kind])

    def close(self):
        self.stopping = True
        self.attach_gate.set()
        for listener in self.listeners:
            listener.close()
        for kind in self.connections:
            self.cut(kind)
        end = time.monotonic() + 2
        for thread in self.threads:
            thread.join(max(0, end - time.monotonic()))
