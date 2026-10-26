'use strict';
/**
 * wsproto.js — dependency-free RFC6455 WebSocket codec + client/server.
 *
 * Written for the Stream Dock protocol harness: the app ships Node 20.11.1 and talks
 * RFC6455 to 127.0.0.1:<port>, so a harness that needs `npm i ws` is useless on a
 * clean machine. Pure net + crypto, no deps.
 *
 * Scope: text frames, ping/pong, close. No fragmentation, no extensions, no TLS.
 * That is exactly what the reverse-engineered protocol uses.
 */
const net = require('net');
const crypto = require('crypto');
const { EventEmitter } = require('events');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function acceptKey(key) {
  return crypto.createHash('sha1').update(key + GUID).digest('base64');
}

function encodeFrame(payload, opcode = 0x1, mask = false) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, 'utf8');
  const len = data.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  header[0] = 0x80 | opcode;
  if (!mask) return Buffer.concat([header, data]);
  header[1] |= 0x80;
  const key = crypto.randomBytes(4);
  const masked = Buffer.alloc(len);
  for (let i = 0; i < len; i++) masked[i] = data[i] ^ key[i & 3];
  return Buffer.concat([header, key, masked]);
}

/** Incremental frame decoder. Emits complete messages from a socket buffer. */
class FrameReader extends EventEmitter {
  constructor(socket) {
    super();
    this.buf = Buffer.alloc(0);
    socket.on('data', (chunk) => {
      this.buf = Buffer.concat([this.buf, chunk]);
      this._drain();
    });
  }

  _drain() {
    for (;;) {
      const b = this.buf;
      if (b.length < 2) return;
      const fin = (b[0] & 0x80) !== 0;
      const opcode = b[0] & 0x0f;
      const masked = (b[1] & 0x80) !== 0;
      let len = b[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        if (b.length < off + 2) return;
        len = b.readUInt16BE(off);
        off += 2;
      } else if (len === 127) {
        if (b.length < off + 8) return;
        len = Number(b.readBigUInt64BE(off));
        off += 8;
      }
      let key = null;
      if (masked) {
        if (b.length < off + 4) return;
        key = b.subarray(off, off + 4);
        off += 4;
      }
      if (b.length < off + len) return;
      let payload = Buffer.from(b.subarray(off, off + len));
      if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= key[i & 3];
      this.buf = b.subarray(off + len);
      if (!fin) return this.emit('protocol_error', 'fragmentation unsupported');
      if (opcode === 0x1 || opcode === 0x2) this.emit('message', payload.toString('utf8'));
      else if (opcode === 0x8) this.emit('close');
      else if (opcode === 0x9) this.emit('ping', payload);
    }
  }
}

/**
 * Client — the side a plugin/PI runs.
 *   const ws = await connect(port);
 *   ws.send({ event: 'registerPlugin', uuid });
 *   ws.on('message', obj => ...)
 */
function connect(port, host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    const key = crypto.randomBytes(16).toString('base64');
    const socket = net.connect(port, host, () => {
      socket.write(
        `GET / HTTP/1.1\r\nHost: ${host}:${port}\r\nUpgrade: websocket\r\n` +
          `Connection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\n` +
          `Sec-WebSocket-Version: 13\r\n\r\n`
      );
    });
    let handshake = Buffer.alloc(0);
    const onData = (chunk) => {
      handshake = Buffer.concat([handshake, chunk]);
      const end = handshake.indexOf('\r\n\r\n');
      if (end < 0) return;
      const head = handshake.subarray(0, end).toString();
      if (!/^HTTP\/1\.1 101/.test(head)) return reject(new Error('handshake rejected: ' + head.split('\r\n')[0]));
      const m = /sec-websocket-accept:\s*(\S+)/i.exec(head);
      if (!m || m[1] !== acceptKey(key)) return reject(new Error('bad Sec-WebSocket-Accept'));
      socket.removeListener('data', onData);
      const reader = new FrameReader(socket);
      const rest = handshake.subarray(end + 4);
      if (rest.length) reader.buf = rest, reader._drain();
      const api = new EventEmitter();
      api.socket = socket;
      api.send = (obj) => socket.write(encodeFrame(JSON.stringify(obj), 0x1, true));
      api.close = () => socket.end(encodeFrame(Buffer.alloc(0), 0x8, true));
      reader.on('message', (txt) => {
        let obj;
        try { obj = JSON.parse(txt); } catch { obj = { raw: txt }; }
        api.emit('message', obj);
      });
      reader.on('close', () => api.emit('close'));
      socket.on('error', (e) => api.emit('error', e));
      socket.on('close', () => api.emit('close'));
      resolve(api);
    };
    socket.on('data', onData);
    socket.on('error', reject);
  });
}

/**
 * Server — the side the app runs (SDPluginServer).
 *   const srv = await listen(0)        // ephemeral port, like the app
 *   srv.on('connection', ws => ...)
 */
function listen(port = 0, host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    const server = net.createServer((socket) => {
      let buf = Buffer.alloc(0);
      const onData = (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        const end = buf.indexOf('\r\n\r\n');
        if (end < 0) return;
        socket.removeListener('data', onData);
        const head = buf.subarray(0, end).toString();
        const key = /sec-websocket-key:\s*(\S+)/i.exec(head);
        if (!key) return socket.destroy();
        socket.write(
          'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n' +
            'Connection: Upgrade\r\nSec-WebSocket-Accept: ' + acceptKey(key[1]) + '\r\n\r\n'
        );
        const reader = new FrameReader(socket);
        const rest = buf.subarray(end + 4);
        if (rest.length) reader.buf = rest, reader._drain();
        const api = new EventEmitter();
        api.socket = socket;
        api.remote = `${socket.remoteAddress}:${socket.remotePort}`;
        api.send = (obj) => socket.write(encodeFrame(JSON.stringify(obj), 0x1, false));
        api.close = () => socket.end(encodeFrame(Buffer.alloc(0), 0x8, false));
        reader.on('message', (txt) => {
          let obj;
          try { obj = JSON.parse(txt); } catch { obj = { raw: txt }; }
          api.emit('message', obj);
        });
        reader.on('close', () => api.emit('close'));
        socket.on('error', () => {});
        emitter.emit('connection', api);
      };
      socket.on('data', onData);
      socket.on('error', () => {});
    });
    const emitter = new EventEmitter();
    server.on('error', reject);
    server.listen(port, host, () => {
      emitter.port = server.address().port;
      emitter.close = () => server.close();
      resolve(emitter);
    });
  });
}

module.exports = { connect, listen, encodeFrame, acceptKey };
