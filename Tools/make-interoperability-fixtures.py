#!/usr/bin/env python3
"""Small external-writer fixtures: Python stdlib, fixed names and payloads."""
from pathlib import Path
import io
import zipfile

root = Path(__file__).resolve().parents[1] / 'Tests/ZipMelloTests/Fixtures'
root.mkdir(parents=True, exist_ok=True)
class Pipe(io.BytesIO):
    def seekable(self): return False
    def seek(self, *args): raise io.UnsupportedOperation()
for force_zip64 in [False, True]:
    pipe = Pipe()
    with zipfile.ZipFile(pipe, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        info = zipfile.ZipInfo('日本語/page.txt', date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        with archive.open(info, 'w', force_zip64=force_zip64) as member:
            member.write(b'external descriptor payload' * 100)
    (root / ('descriptor64.zip' if force_zip64 else 'descriptor32.zip')).write_bytes(pipe.getvalue())
class CP437Info(zipfile.ZipInfo):
    def _encodeFilenameFlags(self): return self.filename.encode('cp437'), self.flag_bits & ~0x800
with zipfile.ZipFile(root / 'cp437.zip', 'w') as archive:
    archive.writestr(CP437Info('café.txt', date_time=(2026, 1, 1, 0, 0, 0)), b'legacy encoding')
# Unsigned 32-bit data descriptor: remove its optional signature and repair EOCD offset.
import struct
signed = (root / 'descriptor32.zip').read_bytes()
position = signed.index(b'PK\x07\x08')
unsigned = bytearray(signed[:position] + signed[position + 4:])
eocd = unsigned.rindex(b'PK\x05\x06')
struct.pack_into('<I', unsigned, eocd + 16, struct.unpack_from('<I', unsigned, eocd + 16)[0] - 4)
(root / 'descriptor-unsigned.zip').write_bytes(unsigned)
# Genuine ZIP64 central fields for zero sizes and a zero local-header offset.
small = io.BytesIO()
with zipfile.ZipFile(small, 'w') as archive:
    archive.writestr(zipfile.ZipInfo('zero.txt', date_time=(2026, 1, 1, 0, 0, 0)), b'')
raw = bytearray(small.getvalue())
central = raw.index(b'PK\x01\x02')
name_length = struct.unpack_from('<H', raw, central + 28)[0]
struct.pack_into('<H', raw, central + 6, 45)
for offset in [20, 24, 42]: struct.pack_into('<I', raw, central + offset, 0xffffffff)
extra = struct.pack('<HHQQQ', 1, 24, 0, 0, 0)
struct.pack_into('<H', raw, central + 30, len(extra))
position = central + 46 + name_length
raw = raw[:position] + extra + raw[position:]
eocd = raw.rindex(b'PK\x05\x06')
struct.pack_into('<I', raw, eocd + 12, struct.unpack_from('<I', raw, eocd + 12)[0] + len(extra))
(root / 'zip64-zero.zip').write_bytes(raw)
