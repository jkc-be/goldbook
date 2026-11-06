#!/usr/bin/env python3
"""Probe the WoW Forever auction routes of the Battle.net Game Data API.

Reads BNET_CLIENT_ID and BNET_CLIENT_SECRET from the environment, or from
server/.env.local. Saves every response body under OUT and writes
OUT/summary.json. Read-only; prints no credentials.

    scripts/probe-forever-ah.py eu OUT
"""
from pathlib import Path
import base64
import gzip
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def credentials():
    values = {}
    env_file = ROOT / 'server/.env.local'
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            name, _, value = line.partition('=')
            values[name.strip()] = value.strip()
    pair = [os.environ.get(name) or values.get(name) for name in ('BNET_CLIENT_ID', 'BNET_CLIENT_SECRET')]
    if not all(pair):
        sys.exit('BNET_CLIENT_ID and BNET_CLIENT_SECRET are not set')
    return pair


def token(client_id, secret):
    basic = base64.b64encode(f'{client_id}:{secret}'.encode()).decode()
    request = urllib.request.Request(
        'https://oauth.battle.net/token', data=b'grant_type=client_credentials',
        headers={'Authorization': f'Basic {basic}', 'Content-Type': 'application/x-www-form-urlencoded'})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.load(response)
    return body['access_token'], body.get('expires_in')


class Probe:
    def __init__(self, region, out, bearer):
        self.region = region
        self.namespace = f'dynamic-forever-{region}'
        self.host = f'https://{region}.api.blizzard.com'
        self.out = out
        self.bearer = bearer
        self.calls = []

    def get(self, path, namespace=None, send=None, tag=''):
        """GET a path or full href, save the body, and record what came back."""
        url = path if path.startswith('https://') else self.host + path
        parts = urllib.parse.urlsplit(url)
        query = dict(urllib.parse.parse_qsl(parts.query))
        query['namespace'] = namespace or self.namespace
        url = urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query)))
        request = urllib.request.Request(url, headers={
            'Authorization': f'Bearer {self.bearer}', 'Accept-Encoding': 'gzip', **(send or {})})
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                status, headers, raw = response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            status, headers, raw = error.code, error.headers, error.read()
        body = gzip.decompress(raw) if headers.get('Content-Encoding') == 'gzip' else raw
        name = parts.path.lstrip('/').replace('/', '_') + f'{tag}.{query["namespace"]}.json'
        (self.out / 'raw' / name).write_bytes(body)
        call = {
            'path': parts.path,
            'namespace': query['namespace'],
            'sent': send or {},
            'status': status,
            'seconds': round(time.monotonic() - started, 2),
            'content_encoding': headers.get('Content-Encoding'),
            'last_modified': headers.get('Last-Modified'),
            'etag': headers.get('ETag'),
            'cache_control': headers.get('Cache-Control'),
            'bytes_on_wire': len(raw),
            'bytes': len(body),
            'sha256': hashlib.sha256(body).hexdigest(),
            'file': f'raw/{name}',
        }
        self.calls.append(call)
        time.sleep(0.05)
        try:
            return status, json.loads(body)
        except ValueError:
            return status, None


def listings(body):
    """Summarize an auctions or commodities body without the listings themselves."""
    auctions = body.get('auctions')
    summary = {'top_level_keys': sorted(body), 'has_auctions_array': auctions is not None}
    if auctions is None:
        return summary
    summary['listings_sha256'] = hashlib.sha256(json.dumps(auctions, sort_keys=True).encode()).hexdigest()
    fields, item_fields, time_left = set(), set(), {}
    for auction in auctions:
        fields.update(auction)
        item_fields.update(auction.get('item', {}))
        time_left[auction.get('time_left')] = time_left.get(auction.get('time_left'), 0) + 1
    stacked = [a for a in auctions if a.get('quantity', 1) > 1 and 'buyout' in a]
    summary.update({
        'count': len(auctions),
        'items': len({a['item']['id'] for a in auctions}),
        'fields': sorted(fields),
        'item_fields': sorted(item_fields),
        'time_left': time_left,
        'with_bid': sum('bid' in a for a in auctions),
        'with_buyout': sum('buyout' in a for a in auctions),
        'with_unit_price': sum('unit_price' in a for a in auctions),
        'quantity_above_1_with_buyout': len(stacked),
        'examples': auctions[:2] + stacked[:2],
    })
    return summary


def main():
    region, out = sys.argv[1], Path(sys.argv[2])
    (out / 'raw').mkdir(parents=True, exist_ok=True)
    bearer, expires_in = token(*credentials())
    probe = Probe(region, out, bearer)
    summary = {'region': region, 'namespace': probe.namespace, 'token_expires_in': expires_in,
               'started': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'houses': []}

    for path in ('/data/wow/realm/index', '/data/wow/connected-realm/index',
                 '/data/wow/auctions/commodities'):
        probe.get(path)
    _, regions = probe.get('/data/wow/region/index')
    summary['regions'] = [probe.get(r['href'])[1] for r in (regions or {}).get('regions', [])]
    _, rulesets = probe.get('/data/wow/ruleset/index')
    summary['ruleset_index'] = rulesets
    for ruleset in (rulesets or {}).get('rulesets', []):
        rid = ruleset['id']
        _, detail = probe.get(f'/data/wow/ruleset/{rid}')
        summary.setdefault('ruleset_details', []).append(detail)
        if (detail or {}).get('auctions', {}).get('href'):
            probe.get(detail['auctions']['href'])
        probe.get(f'/data/wow/ruleset/{rid}/auctions')
        _, index = probe.get(f'/data/wow/ruleset/{rid}/auctions/index')
        for house in (index or {}).get('auctions', []):
            status, body = probe.get(house['key']['href'])
            entry = {'ruleset': rid, 'house': house['id'], 'name': house.get('name'),
                     'status': status, 'call': probe.calls[-1]}
            if body is not None and status == 200:
                entry['regular'] = listings(body)
                entry['echoed_ruleset'] = body.get('ruleset')
                href = (body.get('commodities') or {}).get('href')
                if href:
                    status, commodities = probe.get(href)
                    entry['commodities_status'] = status
                    entry['commodities_call'] = probe.calls[-1]
                    if commodities is not None and status == 200:
                        entry['commodities'] = listings(commodities)
            summary['houses'].append(entry)
            print(rid, house['id'], status, entry.get('regular', {}).get('count'),
                  entry.get('commodities', {}).get('count'), flush=True)

    populated = next((h for h in summary['houses'] if h.get('regular', {}).get('count')), None)
    if populated:
        rid, hid, modified = populated['ruleset'], populated['house'], populated['call']['last_modified']
        house = f'/data/wow/ruleset/{rid}/auctions/{hid}'
        probe.get(house, send={'If-Modified-Since': modified}, tag='.if-modified-since')
        probe.get(house, namespace=f'dynamic-forever-{"us" if region == "eu" else "eu"}')
        probe.get(f'/data/wow/ruleset/{rid}/auctions/122')
        probe.get(f'/data/wow/ruleset/4/auctions/{hid}')

    summary['calls'] = probe.calls
    (out / 'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f'{len(probe.calls)} calls, summary in {out / "summary.json"}')


if __name__ == '__main__':
    main()
