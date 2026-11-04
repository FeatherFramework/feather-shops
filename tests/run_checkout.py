"""Run the actual four-resource checkout composition against a transactional SQL model.
Sibling worktrees are required; there is no silent dependency skip.
"""
import argparse
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--lupa-dir', type=Path)
parser.add_argument('--resources', type=Path, default=Path(__file__).resolve().parents[2])
args = parser.parse_args()
if args.lupa_dir:
    sys.path.insert(0, str(args.lupa_dir.resolve()))
from lupa.lua54 import LuaRuntime

roots = [args.resources / name for name in
         ('feather-inventory', 'feather-shops', 'feather-economy', 'feather-weapons')]
for root in roots:
    if not root.is_dir():
        raise SystemExit(f'Required checkout dependency missing: {root}')
lua = LuaRuntime(unpack_returned_tuples=True)
for root in roots:
    for folder in ('server', 'client', 'shared'):
        for path in (root / folder).rglob('*.lua'):
            lua.execute('assert(load(...))', path.read_text(encoding='utf-8-sig'), '@' + str(path))
lua.globals().arg = lua.table_from({i + 1: root.as_posix() for i, root in enumerate(roots)})
fixture = roots[0] / 'tests/lua/slot_updates_spec.lua'
lua.execute(fixture.read_text(encoding='utf-8'))
print(f'PASS {lua.globals().ShopCheckoutCompositionCases} four-resource checkout scenarios (modeled SQL/CFX; live database acceptance pending)')
