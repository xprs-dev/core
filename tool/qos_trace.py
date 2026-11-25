#!/usr/bin/env python3
"""Turn a station console log into a replay trace for the QoS harness.

    python3 tool/qos_trace.py <console.log> <out.jsonl.gz> [--utc-offset 1]

The input is what the firmware prints for every packet a station hears, one
line each, as a long-lived serial logger records it (wall clock first):

    15:26:34 ... xprs: ble   -50 dBm 226B  t:service f:X3PTZM ...
    15:26:56 ... xprs: lan   192.168.178.148 245B  t:message ...
    15:26:56 ... xprs: espnow ac:27:6e:74:0c:fc -30 dBm 201B  t:message ...
    15:34:24 ... xprs: lora  -5 dBm 223B  t:command ...

The output (test/xprs_qos_replay_test.dart reads it) is gzipped JSON lines:
a header {"start_utc_ms":...,"source":...} and then one object per packet,
{"t": ms since start, "bearer": "ble"|"lan"|"espnow"|"lora", "rssi": int or
null, "wire": "..."}.

REDACTED, because a trace goes into a public repository: the text after m:,
the value of sig: and of x: (a sealed body) are replaced by filler of the same
length, so airtime arithmetic is unchanged and nobody's words or signatures
are published. Callsigns, types, timestamps and every other field stay: they
are what the scheduler decides by.
"""
import datetime
import gzip
import json
import re
import sys

LINE = re.compile(
    r'^(\d\d):(\d\d):(\d\d) .*?xprs: (ble|lan|espnow|lora)\s+(.*?)\s+(\d+)B\s+(t:.*)$')
RSSI = re.compile(r'(-?\d+) dBm')
ANSI = re.compile(r'\x1b\[[0-9;]*m')


def redact(wire):
    out = []
    i = 0
    while i < len(wire):
        if wire.startswith('m:', i):
            out.append('m:' + 'x' * len(wire[i + 2:].encode()))
            break
        end = wire.find(' ', i)
        if end < 0:
            end = len(wire)
        tok = wire[i:end]
        k, _, v = tok.partition(':')
        if k in ('sig', 'x') and v:
            tok = k + ':' + ('s' if k == 'sig' else 'z') * len(v)
        out.append(tok)
        i = end + 1
    return ' '.join(out)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    src, dst = sys.argv[1], sys.argv[2]
    off_h = 1
    if '--utc-offset' in sys.argv:
        off_h = int(sys.argv[sys.argv.index('--utc-offset') + 1])
    date = None
    m = re.search(r'(\d{4}-\d\d-\d\d)', src)
    rows = []
    day = 0
    last = -1
    for raw in open(src, 'rb'):
        line = ANSI.sub('', raw.decode('latin1')).rstrip('\r\n')
        mt = LINE.match(line)
        if not mt:
            continue
        h, mi, s, bearer, mid, _n, wire = mt.groups()
        sec = int(h) * 3600 + int(mi) * 60 + int(s) + day * 86400
        if sec < last - 3600:   # midnight
            day += 1
            sec += 86400
        last = sec
        if date is None:
            ts = re.search(r'ts:(\d{4}-\d\d-\d\d)_', wire)
            date = ts.group(1) if ts else (m.group(1) if m else '2026-01-01')
        r = RSSI.search(mid)
        rows.append((sec, bearer, int(r.group(1)) if r else None, redact(wire.rstrip())))
    if not rows:
        print('no packet lines found')
        sys.exit(1)
    base = datetime.datetime.fromisoformat(date + 'T00:00:00+00:00')
    start_utc = base + datetime.timedelta(seconds=rows[0][0] - off_h * 3600)
    first = rows[0][0]
    with gzip.open(dst, 'wt', encoding='utf-8') as f:
        f.write(json.dumps({'start_utc_ms': int(start_utc.timestamp() * 1000),
                            'source': src.rsplit('/', 1)[-1], 'packets': len(rows)}) + '\n')
        seen_in_second = {}
        for sec, bearer, rssi, wire in rows:
            # One-second log resolution: spread a second's packets over it.
            k = seen_in_second.get(sec, 0)
            seen_in_second[sec] = k + 1
            f.write(json.dumps({'t': (sec - first) * 1000 + min(k * 50, 950),
                                'bearer': bearer, 'rssi': rssi, 'wire': wire}) + '\n')
    print(f'{len(rows)} packets, {rows[-1][0] - first} s, {dst}')


if __name__ == '__main__':
    main()
