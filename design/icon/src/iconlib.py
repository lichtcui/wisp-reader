"""Dependency-free PNG helpers used by the icon export pipeline.

Only the standard library is required: PNGs are decoded/encoded with zlib and
the compositing, resizing and masking are done in pure Python.
"""

import struct
import zlib


def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', f'{path}: not a PNG'
    pos = 8
    idat = b''
    width = height = None
    color_type = None
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b'IHDR':
            width, height, _depth, color_type = struct.unpack('>IIBB', chunk[:10])
        elif kind == b'IDAT':
            idat += chunk
        elif kind == b'IEND':
            break
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    raw = zlib.decompress(idat)
    stride = width * channels
    out = bytearray()
    previous = bytearray(stride)
    pos = 0
    for _ in range(height):
        filt = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if filt == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 255
        elif filt == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 255
        elif filt == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 255
        elif filt == 4:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = previous[i]
                upleft = previous[i - channels] if i >= channels else 0
                p = left + up - upleft
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - upleft)
                pred = left if (pa <= pb and pa <= pc) else (up if pb <= pc else upleft)
                line[i] = (line[i] + pred) & 255
        out += line
        previous = line
    return width, height, channels, bytes(out)


def _chunk(kind, payload):
    return (struct.pack('>I', len(payload)) + kind + payload
            + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff))


def _write_png(path, width, height, color_type, body):
    png = b'\x89PNG\r\n\x1a\n'
    png += _chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, color_type, 0, 0, 0))
    png += _chunk(b'IDAT', zlib.compress(bytes(body), 9))
    png += _chunk(b'IEND', b'')
    open(path, 'wb').write(png)


def write_rgb(path, width, height, rgb):
    stride = width * 3
    body = bytearray()
    for y in range(height):
        body.append(0)
        body += rgb[y * stride:(y + 1) * stride]
    _write_png(path, width, height, 2, body)


def write_rgba(path, width, height, rgba):
    stride = width * 4
    body = bytearray()
    for y in range(height):
        body.append(0)
        body += rgba[y * stride:(y + 1) * stride]
    _write_png(path, width, height, 6, body)


def flatten(fg, bg):
    fw, fh, fch, fd = fg
    bw, bh, bch, bd = bg
    assert (fw, fh) == (bw, bh)
    out = bytearray(fw * fh * 3)
    for i in range(fw * fh):
        fo = i * fch
        bo = i * bch
        a = fd[fo + 3] / 255.0 if fch == 4 else 1.0
        for k in range(3):
            out[i * 3 + k] = int(round(fd[fo + k] * a + bd[bo + k] * (1 - a)))
    return out


def resize(image, size):
    width, height, channels, data = image
    out = bytearray(size * size * channels)
    for y in range(size):
        y0 = y * height // size
        y1 = max(y0 + 1, (y + 1) * height // size)
        for x in range(size):
            x0 = x * width // size
            x1 = max(x0 + 1, (x + 1) * width // size)
            count = (y1 - y0) * (x1 - x0)
            acc = [0] * channels
            for sy in range(y0, y1):
                base = sy * width
                for sx in range(x0, x1):
                    offset = (base + sx) * channels
                    for k in range(channels):
                        acc[k] += data[offset + k]
            offset = (y * size + x) * channels
            for k in range(channels):
                out[offset + k] = acc[k] // count
    if channels == 4:
        for i in range(size * size):
            o = i * 4
            a = out[o + 3]
            if 0 < a < 255:
                for k in range(3):
                    out[o + k] = min(255, out[o + k] * 255 // a)
    return size, size, channels, bytes(out)


def squircle(rgb, size, radius_ratio=0.225):
    radius = size * radius_ratio
    half = size / 2.0
    inner = half - radius
    out = bytearray(size * size * 4)
    for y in range(size):
        dy = abs(y + 0.5 - half) - inner
        dy = dy if dy > 0.0 else 0.0
        for x in range(size):
            dx = abs(x + 0.5 - half) - inner
            dx = dx if dx > 0.0 else 0.0
            distance = (dx * dx + dy * dy) ** 0.5 - radius
            alpha = 0.5 - distance
            alpha = 0.0 if alpha < 0.0 else (1.0 if alpha > 1.0 else alpha)
            o = (y * size + x) * 4
            s = (y * size + x) * 3
            out[o] = rgb[s]
            out[o + 1] = rgb[s + 1]
            out[o + 2] = rgb[s + 2]
            out[o + 3] = int(round(alpha * 255))
    return size, size, 4, bytes(out)