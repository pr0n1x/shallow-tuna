#!/usr/bin/env python3
"""
Generate AmneziaWG 1.5 special junk packets (I1-I5) that are byte-valid QUIC v1
Initial packets carrying a real TLS ClientHello.

Unlike a static <b 0x...> blob copied from a capture, every packet produced here
has a fresh connection ID, TLS random, X25519 key share and GREASE values, yet
still authenticates when a DPI engine derives the QUIC Initial keys from the
DCID and decrypts it.

Requires: pip install cryptography
"""

import argparse
import hashlib
import hmac
import os
import sys

from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

# RFC 9001 s5.2 initial salt for QUIC v1. Public constant; this is what lets
# anyone -- including a censor's DPI -- decrypt an Initial packet.
INITIAL_SALT = bytes.fromhex("38762cf7f55934b34d179ae6a4c80cadccbb7f0a")
QUIC_V1 = bytes.fromhex("00000001")

# ClientHello lifted from an iOS/macOS HTTP/3 request to bag.itunes.apple.com.
# Used as a fingerprint template: extension order, cipher list and transport
# parameters are preserved verbatim so the JA3/JA4 hash stays Apple's.
TEMPLATE_CH = bytes.fromhex(
    "0100010403032eb6eae14633f4950f99690744edfb0b90d0478be51f0685ba53f6f3df3c73fd"
    "0000088a8a130113021303010000d31a1a00000000001900170000146261672e6974756e6573"
    "2e6170706c652e636f6d000a000c000a1a1a001d001700180019001000050003026833000500"
    "050100000000000d0018001604030804040105030203080508050501080606010201001200"
    "000033002b00291a1a000100001d00204c72ecdb5a040f8e9571dae9337ee0404d1069255c37"
    "a95851e368198c59613e002d00020101002b000504aaaa030400390022070480200000090240"
    "670e0240400f00040481000000050480200000060480200000001b00030200016a6a000100"
)

EXT_SERVER_NAME = 0x0000
EXT_SUPPORTED_GROUPS = 0x000A
EXT_ALPN = 0x0010
EXT_KEY_SHARE = 0x0033
EXT_SUPPORTED_VERSIONS = 0x002B
GROUP_X25519 = 0x001D


# --- primitives ------------------------------------------------------------


def hkdf_expand_label(secret: bytes, label: str, length: int) -> bytes:
    lbl = b"tls13 " + label.encode()
    info = length.to_bytes(2, "big") + bytes([len(lbl)]) + lbl + b"\x00"
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac.new(secret, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]


def initial_keys(dcid: bytes):
    initial_secret = hmac.new(INITIAL_SALT, dcid, hashlib.sha256).digest()
    client = hkdf_expand_label(initial_secret, "client in", 32)
    return (
        hkdf_expand_label(client, "quic key", 16),
        hkdf_expand_label(client, "quic iv", 12),
        hkdf_expand_label(client, "quic hp", 16),
    )


def varint(value: int, force_len: int = 0) -> bytes:
    """QUIC variable-length integer. force_len pins the encoding width."""
    for prefix, width in ((0, 1), (1, 2), (2, 4), (3, 8)):
        if force_len and width != force_len:
            continue
        if value < (1 << (width * 8 - 2)):
            return (value | (prefix << (width * 8 - 2))).to_bytes(width, "big")
    raise ValueError(f"cannot encode {value} as a {force_len}-byte varint")


def read_varint(buf: bytes, i: int):
    width = 1 << (buf[i] >> 6)
    value = buf[i] & 0x3F
    for k in range(1, width):
        value = (value << 8) | buf[i + k]
    return value, i + width


def is_grease(value: int) -> bool:
    hi, lo = value >> 8, value & 0xFF
    return hi == lo and (hi & 0x0F) == 0x0A


def new_grease() -> int:
    n = os.urandom(1)[0] & 0x0F
    byte = (n << 4) | 0x0A
    return (byte << 8) | byte


def u16(v: int) -> bytes:
    return v.to_bytes(2, "big")


def vector(data: bytes, len_bytes: int) -> bytes:
    return len(data).to_bytes(len_bytes, "big") + data


# --- ClientHello surgery ---------------------------------------------------


def split_client_hello(ch: bytes):
    """Return (prefix_before_ciphers, cipher_suites, mid, [(type, data), ...])."""
    if ch[0] != 0x01:
        raise ValueError("template is not a ClientHello")
    if int.from_bytes(ch[1:4], "big") != len(ch) - 4:
        raise ValueError("ClientHello length field does not match body")

    p = 4 + 2 + 32                       # handshake header, legacy_version, random
    p += 1 + ch[p]                       # legacy_session_id
    ciphers_len = int.from_bytes(ch[p : p + 2], "big")
    ciphers = ch[p + 2 : p + 2 + ciphers_len]
    prefix, p = ch[4 : p], p + 2 + ciphers_len

    mid_start = p
    p += 1 + ch[p]                       # legacy_compression_methods
    mid = ch[mid_start:p]

    ext_total = int.from_bytes(ch[p : p + 2], "big")
    p += 2
    end = p + ext_total
    exts = []
    while p < end:
        etype = int.from_bytes(ch[p : p + 2], "big")
        elen = int.from_bytes(ch[p + 2 : p + 4], "big")
        exts.append((etype, ch[p + 4 : p + 4 + elen]))
        p += 4 + elen
    if p != end:
        raise ValueError("extension block is malformed")
    return prefix, ciphers, mid, exts


def encode_host(hostname: str) -> bytes:
    try:
        return hostname.encode("idna")
    except UnicodeError:
        return hostname.encode()      # oversized/odd labels: send them verbatim


def build_sni(hostname: str) -> bytes:
    entry = b"\x00" + vector(encode_host(hostname), 2)
    return vector(entry, 2)


def build_alpn(protocols) -> bytes:
    body = b"".join(vector(p.encode(), 1) for p in protocols)
    return vector(body, 2)


def rewrite_key_share(data: bytes, regrease: bool) -> bytes:
    total = int.from_bytes(data[:2], "big")
    p, out = 2, b""
    while p < 2 + total:
        group = int.from_bytes(data[p : p + 2], "big")
        klen = int.from_bytes(data[p + 2 : p + 4], "big")
        key = data[p + 4 : p + 4 + klen]
        p += 4 + klen
        if is_grease(group) and regrease:
            group = new_grease()
        if group == GROUP_X25519:
            priv = x25519.X25519PrivateKey.generate()
            key = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        out += u16(group) + vector(key, 2)
    return vector(out, 2)


def rewrite_u16_list(data: bytes, len_bytes: int, regrease: bool) -> bytes:
    """Re-GREASE a length-prefixed list of 2-byte codepoints."""
    if not regrease:
        return data
    total = int.from_bytes(data[:len_bytes], "big")
    body = data[len_bytes : len_bytes + total]
    out = b""
    for k in range(0, len(body), 2):
        v = int.from_bytes(body[k : k + 2], "big")
        out += u16(new_grease() if is_grease(v) else v)
    return vector(out, len_bytes)


def make_client_hello(template: bytes, sni: str, alpn, regrease: bool) -> bytes:
    prefix, ciphers, mid, exts = split_client_hello(template)

    # prefix is legacy_version(2) + random(32) + legacy_session_id(1+n)
    prefix = prefix[:2] + os.urandom(32) + prefix[34:]

    if regrease:
        ciphers = b"".join(
            u16(new_grease() if is_grease(int.from_bytes(ciphers[k : k + 2], "big"))
                else int.from_bytes(ciphers[k : k + 2], "big"))
            for k in range(0, len(ciphers), 2)
        )

    rebuilt = b""
    for etype, data in exts:
        if etype == EXT_SERVER_NAME and sni:
            data = build_sni(sni)
        elif etype == EXT_ALPN and alpn:
            data = build_alpn(alpn)
        elif etype == EXT_KEY_SHARE:
            data = rewrite_key_share(data, regrease)
        elif etype == EXT_SUPPORTED_GROUPS:
            data = rewrite_u16_list(data, 2, regrease)
        elif etype == EXT_SUPPORTED_VERSIONS:
            data = rewrite_u16_list(data, 1, regrease)
        if is_grease(etype) and regrease:
            etype = new_grease()
        rebuilt += u16(etype) + vector(data, 2)

    body = prefix + vector(ciphers, 2) + mid + vector(rebuilt, 2)
    return b"\x01" + len(body).to_bytes(3, "big") + body


# --- QUIC Initial assembly -------------------------------------------------


def build_initial(client_hello: bytes, size: int, dcid_len: int) -> bytes:
    dcid = os.urandom(dcid_len)
    key, iv, hp = initial_keys(dcid)

    crypto = b"\x06" + varint(0) + varint(len(client_hello), force_len=2) + client_hello
    # total = first(1) + version(4) + dcidlen(1) + dcid + scidlen(1) + token(1)
    #         + length varint(2) + pn(1) + plaintext + AEAD tag(16)
    overhead = 11 + dcid_len + 16
    pad = size - overhead - len(crypto)
    if pad < 0:
        raise ValueError(
            f"ClientHello is {-pad} bytes too large for a {size}-byte packet "
            "(shorten the SNI or raise --size)"
        )
    plaintext = crypto + b"\x00" * pad          # PADDING frames

    pn = b"\x00"
    first = 0xC0                                # long header, Initial, 1-byte PN
    header = (
        bytes([first]) + QUIC_V1
        + bytes([dcid_len]) + dcid
        + b"\x00"                               # zero-length SCID
        + varint(0)                             # empty token
        + varint(len(pn) + len(plaintext) + 16, force_len=2)
        + pn
    )

    nonce = bytes(a ^ b for a, b in zip(iv, b"\x00" * 11 + pn))
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, header)

    # Header protection (RFC 9001 s5.4): sample starts 4 bytes past the PN field.
    sample = ciphertext[3:19]
    mask = Cipher(algorithms.AES(hp), modes.ECB()).encryptor().update(sample)
    protected = bytes([first ^ (mask[0] & 0x0F)]) + header[1:-1] + bytes([pn[0] ^ mask[1]])
    return protected + ciphertext


# --- verification ----------------------------------------------------------


def verify(packet: bytes) -> str:
    """Decrypt exactly as a DPI engine would; return the SNI it observes."""
    dcid_len = packet[5]
    dcid = packet[6 : 6 + dcid_len]
    key, iv, hp = initial_keys(dcid)

    p = 6 + dcid_len
    p += 1 + packet[p]                          # SCID
    token_len, p = read_varint(packet, p)
    p += token_len
    _, pn_off = read_varint(packet, p)

    mask = Cipher(algorithms.AES(hp), modes.ECB()).encryptor().update(
        packet[pn_off + 4 : pn_off + 20]
    )
    first = packet[0] ^ (mask[0] & 0x0F)
    pn_len = (first & 0x03) + 1
    pn = bytes(a ^ b for a, b in zip(packet[pn_off : pn_off + pn_len], mask[1:]))

    nonce = bytes(a ^ b for a, b in zip(iv, b"\x00" * (12 - pn_len) + pn))
    plaintext = AESGCM(key).decrypt(
        nonce, packet[pn_off + pn_len :], bytes([first]) + packet[1:pn_off] + pn
    )

    if plaintext[0] != 0x06:
        raise ValueError("first frame is not CRYPTO")
    _, i = read_varint(plaintext, 1)
    clen, i = read_varint(plaintext, i)
    _, _, _, exts = split_client_hello(plaintext[i : i + clen])
    for etype, data in exts:
        if etype == EXT_SERVER_NAME:
            host = data[5:]
            try:
                return host.decode("idna")
            except UnicodeError:
                return host.decode(errors="replace")
    return "<none>"


# --- CLI -------------------------------------------------------------------


def load_template(path: str) -> bytes:
    """Accept either a raw ClientHello or a full captured QUIC Initial packet."""
    blob = open(path).read().strip().replace("\n", "").replace(" ", "")
    if blob.startswith("<b"):
        blob = blob[blob.index("0x") + 2 : blob.rindex(">")]
    if blob.lower().startswith("0x"):
        blob = blob[2:]
    data = bytes.fromhex(blob)
    if data[0] == 0x01:
        return data
    # Full packet: decrypt it and lift the ClientHello back out.
    dcid = data[6 : 6 + data[5]]
    key, iv, hp = initial_keys(dcid)
    pn_off = 8 + data[5] + 2
    mask = Cipher(algorithms.AES(hp), modes.ECB()).encryptor().update(
        data[pn_off + 4 : pn_off + 20]
    )
    first = data[0] ^ (mask[0] & 0x0F)
    pn_len = (first & 0x03) + 1
    pn = bytes(a ^ b for a, b in zip(data[pn_off : pn_off + pn_len], mask[1:]))
    nonce = bytes(a ^ b for a, b in zip(iv, b"\x00" * (12 - pn_len) + pn))
    pt = AESGCM(key).decrypt(
        nonce, data[pn_off + pn_len :], bytes([first]) + data[1:pn_off] + pn
    )
    _, i = read_varint(pt, 1)
    clen, i = read_varint(pt, i)
    return pt[i : i + clen]


def main():
    ap = argparse.ArgumentParser(
        description="Generate AmneziaWG I1-I5 junk packets shaped as QUIC Initials.",
        epilog="Example: %(prog)s --sni www.microsoft.com --count 3",
    )
    ap.add_argument("--sni", default="bag.itunes.apple.com", help="SNI to advertise")
    ap.add_argument("--alpn", default="h3", help="comma-separated ALPN list")
    ap.add_argument("--count", type=int, default=1, help="packets to emit")
    ap.add_argument("--size", type=int, default=1200, help="packet size in bytes")
    ap.add_argument("--dcid-len", type=int, default=8, help="destination conn-id length")
    ap.add_argument("--template", help="file with a ClientHello or captured Initial")
    ap.add_argument("--no-grease", action="store_true", help="keep template GREASE values")
    ap.add_argument(
        "--format", choices=("awg", "hex", "raw"), default="awg",
        help="awg = <b 0x...> config line, raw = binary to stdout",
    )
    ap.add_argument("--param", default="I", help="config key prefix (I or J)")
    ap.add_argument("--start", type=int, default=1, help="first parameter index")
    args = ap.parse_args()

    if not 0 <= args.dcid_len <= 20:
        ap.error("--dcid-len must be between 0 and 20")

    template = load_template(args.template) if args.template else TEMPLATE_CH
    alpn = [p for p in args.alpn.split(",") if p]

    for n in range(args.count):
        ch = make_client_hello(template, args.sni, alpn, not args.no_grease)
        packet = build_initial(ch, args.size, args.dcid_len)

        observed = verify(packet)
        if observed != args.sni:
            raise SystemExit(f"self-check failed: DPI would see {observed!r}")

        if args.format == "raw":
            sys.stdout.buffer.write(packet)
        elif args.format == "hex":
            print(packet.hex())
        else:
            print(f"{args.param}{args.start + n} = <b 0x{packet.hex()}>")

    if args.format != "raw":
        print(
            f"\n# {args.count} packet(s), {args.size} B each, SNI {args.sni}, "
            f"ALPN {','.join(alpn)} -- each verified decryptable via the QUIC "
            "initial salt",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
