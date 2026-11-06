#!/usr/bin/env python3
"""Rank Battle.net auction houses by how well they match a realm's latest scan.

Reads the output of scripts/probe-forever-ah.py and the server's public
/api/export for one realm and faction. Compares each item's minimum unit
price in the scan with each house's snapshot.

    scripts/match-forever-house.py OUT https://app.jkc-be.com/goldbook CAMWOWEU4Realm8PvP Horde
"""
from pathlib import Path
import json
import math
import statistics
import sys
import urllib.parse
import urllib.request


def house_prices(out, entry):
    """Map item ID to (minimum unit price, total quantity) for one house."""
    prices = {}
    calls = [(entry['call'], 'buyout')]
    if entry.get('commodities_call'):
        calls.append((entry['commodities_call'], 'unit_price'))
    for call, field in calls:
        for auction in json.loads((out / call['file']).read_text()).get('auctions', []):
            if field not in auction:
                continue
            item, quantity = str(auction['item']['id']), auction['quantity']
            unit = auction[field] if field == 'unit_price' else math.ceil(auction[field] / quantity)
            low, total = prices.get(item, (unit, 0))
            prices[item] = (min(low, unit), total + quantity)
    return prices


def main():
    out, server, realm, faction = Path(sys.argv[1]), sys.argv[2].rstrip('/'), sys.argv[3], sys.argv[4]
    summary = json.loads((out / 'summary.json').read_text())
    first = summary['houses'][0]['ruleset']
    houses = {e['house']: house_prices(out, e) for e in summary['houses']
              if e['ruleset'] == first and e.get('regular', {}).get('count')}

    query = urllib.parse.urlencode({'realm': realm, 'faction': faction})
    # The proxy in front of production refuses urllib's default User-Agent.
    request = urllib.request.Request(f'{server}/api/export?{query}',
                                     headers={'User-Agent': 'goldbook-scripts'})
    with urllib.request.urlopen(request, timeout=60) as response:
        export = json.load(response)
    newest = export['scannedAt']
    scan = {key: item['price'][0] for key, item in export['items'].items()
            if key.isdigit() and item['price'][3] == newest and item['price'][0] > 0}
    print(f'{realm} {faction}: {len(scan)} items in the scan at {newest}, '
          f'snapshot {summary["houses"][0]["call"]["last_modified"]}')

    ranked = []
    for house, prices in houses.items():
        common = [key for key in scan if key in prices]
        if not common:
            continue
        exact = sum(scan[key] == prices[key][0] for key in common) / len(common)
        drift = statistics.median(abs(math.log(scan[key] / prices[key][0])) for key in common)
        ranked.append((len(common) / len(scan), exact, drift, house))
    ranked.sort(reverse=True)
    print('house  found  exact  median |log ratio|')
    for found, exact, drift, house in ranked:
        print(f'{house:5d}  {found:5.0%}  {exact:5.0%}  {drift:.2f}')

    if len(ranked) > 1:
        a, b = ranked[0][3], ranked[1][3]
        disputed = [key for key in scan if key in houses[a] and key in houses[b]
                    and houses[a][key][0] != houses[b][key][0]]
        wins_a = sum(scan[key] == houses[a][key][0] for key in disputed)
        wins_b = sum(scan[key] == houses[b][key][0] for key in disputed)
        print(f'{len(disputed)} items where {a} and {b} disagree: the scan matches {a} exactly '
              f'{wins_a} times and {b} {wins_b} times')


if __name__ == '__main__':
    main()
