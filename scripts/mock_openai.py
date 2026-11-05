#!/usr/bin/env python3
"""Local stand-in for the OpenAI Image API, for testing without spending credit.

Usage: python3 scripts/mock_openai.py [delay-seconds] [fail-first-n] [gif-error-status]   (listens on 127.0.0.1:8765)
fail-first-n: answer the first N generation requests with 503 + Retry-After: 2 (to exercise retries).
gif-error-status: answer GIF requests with this status, e.g. 403 (no preview access) or 400 (over the pixel budget).
SVG requests get a real SVG. A prompt containing "malformed" or "hostile" gets a broken or misbehaving document instead.
Then launch a DEBUG build with: -OpenAIBaseURL http://127.0.0.1:8765/v1

Requests the real API rejects (see `rejection` and `markup_rejection`) get a 400, so a client bug shows up here too.
Edit requests log whether a `markup` part arrived, its PNG size and alpha channel, and the first image's size.
"""
import base64, json, re, sys, time, zlib, struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DELAY = float(sys.argv[1]) if len(sys.argv) > 1 else 20
FAIL_FIRST = int(sys.argv[2]) if len(sys.argv) > 2 else 0
GIF_ERROR = int(sys.argv[3]) if len(sys.argv) > 3 else 0
failures = 0

# Request fields echoed to the log, in order. Add new options here.
LOGGED_FIELDS = ("model", "complexity", "output_format", "output_compression", "frame_count", "frame_duration_ms")

def png(w, h, seed):
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            row += bytes(((x * 255 // w + seed) % 256, (y * 255 // h) % 256, (seed * 3) % 256))
        rows.append(bytes(row))
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 6)) + chunk(b"IEND", b""))

def lzw(pixels, min_code_size=8):
    """GIF-flavoured LZW compression of a sequence of palette indices."""
    clear, end = 1 << min_code_size, (1 << min_code_size) + 1
    out, buffer, bits = bytearray(), 0, 0
    def emit(code, width):
        nonlocal buffer, bits
        buffer |= code << bits
        bits += width
        while bits >= 8:
            out.append(buffer & 0xff)
            buffer >>= 8
            bits -= 8
    width, next_code, table = min_code_size + 1, end + 1, {}
    emit(clear, width)
    prefix = pixels[0]
    for pixel in pixels[1:]:
        key = (prefix << 8) | pixel
        if key in table:
            prefix = table[key]
            continue
        emit(prefix, width)
        if next_code > (1 << width) - 1 and width < 12:
            width += 1
        if next_code < 4096:
            table[key] = next_code
            next_code += 1
        else:
            emit(clear, width)
            width, next_code, table = min_code_size + 1, end + 1, {}
        prefix = pixel
    emit(prefix, width)
    emit(end, width)
    if bits:
        out.append(buffer & 0xff)
    return bytes(out)

def gif(w, h, seed, frames, duration_ms):
    """A looping animated GIF: a gradient with a white square crossing it and a progress bar along the bottom."""
    palette = bytearray()
    for i in range(255):
        palette += bytes(((i + seed) % 256, (i // 2 + seed * 3) % 256, (200 - i // 2) % 256))
    palette += bytes((255, 255, 255))  # index 255 is white
    delay = max(round(duration_ms / 10), 1)  # GIF stores hundredths of a second
    out = bytearray(b"GIF89a" + struct.pack("<HHBBB", w, h, 0xF7, 0, 0) + palette)
    out += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"  # loop forever
    side = h // 4
    for frame in range(frames):
        left = frame * (w - side) // max(frames - 1, 1)
        bar = (frame + 1) * w // frames
        pixels = bytearray((x + y) * 254 // (w + h) for y in range(h) for x in range(w))
        for y in range(h // 2 - side // 2, h // 2 + side // 2):
            pixels[y * w + left:y * w + left + side] = b"\xff" * side
        for y in range(h - h // 16, h):
            pixels[y * w:y * w + bar] = b"\xff" * bar
        out += b"\x21\xF9\x04\x04" + struct.pack("<H", delay) + b"\x00\x00"  # graphic control extension
        out += b"\x2C" + struct.pack("<HHHHB", 0, 0, w, h, 0) + b"\x08"  # image descriptor, then LZW minimum code size
        data = lzw(bytes(pixels))
        for start in range(0, len(data), 255):
            block = data[start:start + 255]
            out += bytes([len(block)]) + block
        out += b"\x00"
    return bytes(out + b"\x3B")

def render_gif(index, fields):
    seed = index * 70 + int(time.time()) % 200
    return gif(256, 256, seed, int(fields.get("frame_count", 9)), int(fields.get("frame_duration_ms", 200)))

def render_png(index, fields):
    return png(512, 512, index * 70 + int(time.time()) % 200)

def svg(seed):
    """A real SVG with an unpainted canvas: black, white and coloured artwork, and fine detail for checking sharpness."""
    hue = seed * 47 % 360
    rays = "".join(f'<line x1="320" y1="200" x2="{320 + 170 * x / 20:.1f}" y2="{200 + 170 * y / 20:.1f}"/>'
                   for x, y in ((-20, -8), (-16, -14), (-8, -20), (0, -20), (8, -20), (16, -14), (20, -8)))
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 400">
  <title>Mock SVG</title>
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="hsl({hue}, 80%, 60%)"/><stop offset="1" stop-color="hsl({hue + 60}, 80%, 40%)"/>
  </linearGradient></defs>
  <circle cx="320" cy="200" r="110" fill="url(#g)"/>
  <g stroke="#111" stroke-width="1.5">{rays}</g>
  <path d="M40 340 C 160 240, 240 400, 340 320 S 520 260, 600 340 L 600 370 L 40 370 Z"/>
  <circle cx="120" cy="90" r="46" fill="#fff"/>
  <rect x="470" y="50" width="120" height="70" rx="12" fill="#f5e6c8"/>
  <text x="320" y="214" font-family="Helvetica" font-size="44" font-weight="700" text-anchor="middle" fill="#fff">SVG</text>
</svg>
""".encode()

def render_svg(index, fields):
    """Prompts mentioning "malformed" or "hostile" get a document the app must cope with."""
    prompt = fields.get("prompt", "").lower()
    if "malformed" in prompt:
        return b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10"'
    if "hostile" in prompt:
        # Fetches are logged below if the app ever lets one through.
        return b"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><style>@import url(http://127.0.0.1:8765/fetched-style.css);</style>
<script>new Image().src="http://127.0.0.1:8765/fetched-by-script";</script>
<image href="http://127.0.0.1:8765/fetched-image.png" width="100" height="100"/><rect width="50" height="50" fill="#c00"/></svg>"""
    return svg(index * 70 + int(time.time()) % 200)

def multipart_files(raw, boundary):
    """The file parts of a multipart body, in order, as (field name, bytes)."""
    delimiter = b"--" + boundary.encode()
    files = []
    for part in (b"\r\n" + raw).split(b"\r\n" + delimiter)[1:]:
        head, separator, content = part.lstrip(b"\r\n").partition(b"\r\n\r\n")
        name = re.search(rb'name="([^"]+)"', head)
        if separator and name and b"filename=" in head:
            files.append((name.group(1).decode(), content))
    return files

def png_info(data):
    """(width, height, has alpha) from a PNG's IHDR and any tRNS chunk, or None if it isn't a PNG."""
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    width, height, _, color_type = struct.unpack(">IIBB", data[16:26])
    return width, height, color_type in (4, 6) or b"tRNS" in data[:data.find(b"IDAT")]

def jpeg_size(data):
    """(width, height) from a JPEG's start-of-frame marker, or None."""
    if data[:2] != b"\xff\xd8":
        return None
    position = 2
    while position + 9 < len(data):
        if data[position] != 0xFF:
            position += 1
            continue
        marker = data[position + 1]
        if marker == 0xFF:
            position += 1
        elif 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            height, width = struct.unpack(">HH", data[position + 5:position + 9])
            return width, height
        elif marker == 0xD8 or 0xD0 <= marker <= 0xD7:
            position += 2
        else:
            position += 2 + struct.unpack(">H", data[position + 2:position + 4])[0]
    return None

def image_size(data):
    info = png_info(data)
    return info[:2] if info else jpeg_size(data)

MARKUP_MODELS = ("gpt-image-2.6-flare", "gpt-image-2.6-sunburst", "gpt-image-2.5-flare", "gpt-image-2.5-sunburst")
MARKUP_MAX_PIXELS = 16_777_216
MARKUP_MAX_BYTES = 50 * 1024 * 1024

def markup_rejection(fields, files):
    """The error the real API would give for this request's markup, or None."""
    markups = [data for name, data in files if name == "markup"]
    if not markups:
        return None
    for name in ("mask", "prompt_rewriter"):
        if name in fields or any(field == name for field, _ in files):
            return f"markup can't be combined with {name}."
    if fields.get("model") not in MARKUP_MODELS:
        return f"markup isn't supported with {fields.get('model')}."
    images = [data for name, data in files if name == "image[]"]
    if not images:
        return "markup needs an input image."
    info = png_info(markups[0])
    if not info:
        return "markup must be a PNG."
    width, height, has_alpha = info
    if not has_alpha:
        return "markup must contain transparent pixels."
    if len(markups[0]) > MARKUP_MAX_BYTES:
        return "markup is larger than 50 MB."
    if width * height > MARKUP_MAX_PIXELS:
        return f"markup is larger than {MARKUP_MAX_PIXELS} pixels."
    first = image_size(images[0])
    if first and first != (width, height):
        return f"markup is {width}x{height} but the first image is {first[0]}x{first[1]}."
    return None

def markup_summary(files):
    """What arrived as markup, and the size of the first image it has to match."""
    markups = [data for name, data in files if name == "markup"]
    if not markups:
        return "markup= no"
    images = [data for name, data in files if name == "image[]"]
    first = image_size(images[0]) if images else None
    first_label = f"{first[0]}x{first[1]}" if first else "unknown"
    info = png_info(markups[0])
    if not info:
        return f"markup= yes (not a PNG, {len(markups[0])} bytes) first_image= {first_label}"
    return f"markup= {info[0]}x{info[1]} alpha= {'yes' if info[2] else 'no'} bytes= {len(markups[0])} first_image= {first_label}"

# output_format -> (renderer, reported output_format). Anything else gets a PNG, as it always has.
RENDERERS = {"gif": (render_gif, "gif"), "svg": (render_svg, "svg")}

def rejection(path, fields):
    """The error the real API would give for this request, or None."""
    output_format = fields.get("output_format", "png")
    if path.endswith("/images/edits") and output_format == "gif":
        return "The image edit endpoint does not support GIF output."
    if output_format != "gif" and ("frame_count" in fields or "frame_duration_ms" in fields):
        return "frame_count and frame_duration_ms are only supported with output_format=gif."
    if output_format == "gif" and "output_compression" in fields:
        return "GIF output does not support custom output_compression."
    if output_format == "svg":
        if path.endswith("/images/edits"):
            return "The image edit endpoint does not support SVG output."
        if int(fields.get("n", 1)) != 1:
            return "SVG output requires n=1."
        for name in ("output_compression", "prompt_rewriter", "stream", "partial_images"):
            if name in fields:
                return f"SVG output does not support {name}."
        if "svg" in fields:
            return "Your organization does not have access to SVG model selection. Omit the svg object."
    return None

def gif_error_message(status):
    if status == 403:
        return "Your organization does not have access to the GIF preview for this model."
    return "The requested GIF exceeds the total pixel budget. Reduce frame_count, the frame size or n."

def summary(fields):
    return " ".join(f"{name}= {fields.get(name)}" for name in LOGGED_FIELDS)

class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def _error(self, code, message):
        self._send(code, {"error": {"message": message, "type": "invalid_request_error", "code": None}})
        print(" ", code, message, flush=True)
    def do_GET(self):
        print("GET", self.path, flush=True)
        if "fetched" in self.path:
            print("  WARNING: an SVG document reached the network", flush=True)
        self._send(200, {"object": "list", "data": []})
    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        files = []
        if self.path.endswith("/images/edits"):
            # Multipart form: pull out the text fields and count the reference images.
            text = raw.decode("latin-1")
            fields = dict(re.findall(r'name="([^"\[\]]+)"\r\n\r\n(.*?)\r\n--', text, re.S))
            body = {**fields, "n": int(fields.get("n", 1))}
            boundary = self.headers.get("Content-Type", "").partition("boundary=")[2]
            files = multipart_files(raw, boundary)
            print("POST", self.path, body.get("prompt"), "n=", body["n"], "references=", sum(name == "image[]" for name, _ in files),
                  summary(body), markup_summary(files), flush=True)
        else:
            body = json.loads(raw)
            print("POST", self.path, body.get("prompt"), "n=", body.get("n"), summary(body),
                  "auth=", self.headers.get("Authorization", "")[:14], flush=True)
        problem = rejection(self.path, body) or markup_rejection(body, files)
        if problem:
            self._error(400, problem)
            return
        global failures
        if failures < FAIL_FIRST:
            failures += 1
            payload = json.dumps({"error": {"message": "The server is overloaded.", "type": "server_error", "code": None}}).encode()
            self.send_response(503); self.send_header("Content-Type", "application/json"); self.send_header("Retry-After", "2")
            self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload)
            print("  503 (failure", failures, "of", FAIL_FIRST, ")", flush=True)
            return
        if GIF_ERROR and body.get("output_format") == "gif":
            self._error(GIF_ERROR, gif_error_message(GIF_ERROR))
            return
        time.sleep(DELAY)
        renderer, reported_format = RENDERERS.get(body.get("output_format"), (render_png, "png"))
        imgs = [{"b64_json": base64.b64encode(renderer(i, body)).decode()} for i in range(body.get("n", 1))]
        self._send(200, {"created": int(time.time()), "size": "1024x1024", "quality": "high", "background": "opaque",
                         "output_format": reported_format, "data": imgs, "usage": {"input_tokens": 9, "output_tokens": 4160, "total_tokens": 4169},
                         **({"svg_usage": {"input_tokens": 120, "model": "mock-svg-author", "output_tokens": 900, "reasoning_tokens": 0, "total_tokens": 1020}} if reported_format == "svg" else {})})
        print("  responded", reported_format, flush=True)
    def log_message(self, *a): pass

ThreadingHTTPServer(("127.0.0.1", 8765), H).serve_forever()
