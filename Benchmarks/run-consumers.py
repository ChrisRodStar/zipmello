#!/usr/bin/env python3
"""Alternating variants, fresh processes, five measured runs; one warmup per pair."""
from pathlib import Path
import subprocess
import json
import statistics
import platform

root = Path(__file__).resolve().parents[1]
package = root / 'Benchmarks'
bin_dir = subprocess.check_output(
    ['swift', 'build', '--package-path', str(package), '-c', 'release', '--show-bin-path'],
    text=True
).strip()
exe = Path(bin_dir) / 'zipmello-consumer-benchmark'
fixtures = root / 'Benchmarks/Fixtures'
cases = [('memory', 'source'), ('memory', 'comic'), ('tree', 'source'), ('tree', 'model'),
         ('tree', 'dictionary4000'), ('export', 'comic128'), ('export', 'dictionary4000'),
         ('validate', 'dictionary4000'), ('pages', 'comic128'),
         ('memory_batch', 'comic'), ('memory_batch', 'dictionary4000')]
rows = []
for operation, workload in cases:
    base_variants = ['upstream', 'zipmello', 'zipmello-small'] if operation == 'validate' else ['upstream', 'zipmello']
    for variant in base_variants:
        subprocess.run([str(exe), variant, operation, workload, str(fixtures)], check=True, capture_output=True)
    for run in range(5):
        variants = base_variants if run % 2 == 0 else list(reversed(base_variants))
        for variant in variants:
            result = subprocess.run([str(exe), variant, operation, workload, str(fixtures)], check=True, capture_output=True, text=True)
            row = json.loads(result.stdout); row['run'] = run + 1; rows.append(row)
    pair = [r for r in rows if r['operation'] == operation and r['workload'] == workload]
    before = statistics.median(r['milliseconds'] for r in pair if r['variant'] == 'upstream')
    after = statistics.median(r['milliseconds'] for r in pair if r['variant'] == 'zipmello')
    print(f'{operation}/{workload}: {before:.3f} -> {after:.3f} ms ({before/after:.2f}x)', flush=True)
    if operation == 'validate':
        tuned = statistics.median(r['milliseconds'] for r in pair if r['variant'] == 'zipmello-small')
        print(f'  bounded dictionary codec: {tuned:.3f} ms ({before/tuned:.2f}x)', flush=True)
output = root / 'Benchmarks/results/consumer-replacement.json'
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps({'environment': platform.platform(), 'samples': rows}, indent=2) + '\n')
