import io, re, yaml

import os
HERE = os.path.dirname(os.path.abspath(__file__))
QA = os.path.dirname(HERE)
md = io.open(os.path.join(QA, '测试用例_markmap.md'), encoding='utf-8').read()

module_names = {}
for m in re.finditer(r'^## (\d+)\. (.+)$', md, re.M):
    module_names[str(int(m.group(1)))] = m.group(2).strip()

shared = {}
cur = None
for line in md.split('\n'):
    m = re.match(r'^## (\d+)\. ', line)
    if m:
        cur = str(int(m.group(1))); continue
    m = re.match(r'^> 前置：(.+)$', line)
    if m and cur:
        shared.setdefault(cur, []).append(m.group(1).strip())

CASE_RE = re.compile(
    r'^- \*\*(TC-(\d+)-(\d+)) (.+?)\*\* \[(P[012])\](?:（(SMOKE-\d+)）)?'
    r'(?: \[([^\]]+)\])?\s*$', re.M)

blocks = re.split(r'(?m)^(?=- \*\*TC-)', md)
cases = []
for b in blocks:
    m = CASE_RE.match(b)
    if not m:
        continue
    cid, mod, seq, title, pri, smoke, tags = m.groups()
    mod = str(int(mod))
    title = title.strip()
    body = b[m.end():]
    pre = re.search(r'^- 前置条件: (.+)$', body, re.M)
    st = re.search(r'^- 操作步骤: (.+)$', body, re.M)
    ex = re.search(r'^- 预期结果: (.+)$', body, re.M)
    steps = []
    if st:
        parts = re.split(r'\s(?=\d+\.\s)', st.group(1))
        steps = [p.strip() for p in parts if p.strip()]
    expected = []
    if ex:
        expected = [x.strip() for x in re.split(r'；(?=\S)', ex.group(1)) if x.strip()]
    tagset = {'[' + tags + ']'} if tags else set()
    if '[并发]' in tagset: t = 'concurrency'
    elif '[可靠]' in tagset: t = 'reliability'
    elif '[集成]' in tagset: t = 'functional'
    elif any(k in title for k in ('失败','崩','缺失','无法','不改变')): t = 'exception'
    elif any(k in title for k in ('一致','加总','序号')): t = 'data'
    elif any(k in title for k in ('切换','返回','移动','流转')): t = 'state'
    else: t = 'functional'
    cases.append(dict(
        id=cid, title=title, module="%s. %s" % (mod, module_names[mod]),
        priority=pri, type=t, execution_model='ui', smoke=smoke or None,
        preconditions=[pre.group(1).strip()] if pre else [],
        steps=steps, expected=expected, test_data={},
        risk_ref=[], code_refs=[], evidence=None,
        tags=sorted(tagset), automation=None, status='active'))

risk_cov = {
 'R1': ['TC-04-01','TC-04-02','TC-04-03','TC-04-04','TC-04-05','TC-04-07'],
 'R2': ['TC-02-02','TC-02-06','TC-02-07','TC-05-01','TC-05-02','TC-05-03','TC-05-04','TC-05-05','TC-05-06'],
 'R3': ['TC-01-09','TC-01-10','TC-01-11','TC-06-01','TC-06-02'],
 'R4': ['TC-02-01','TC-02-08','TC-02-09','TC-02-10','TC-02-11','TC-02-12','TC-02-13','TC-02-14','TC-02-15'],
 'R5': ['TC-04-06','TC-04-07','TC-07-01','TC-07-04'],
 'R6': ['TC-04-03','TC-04-06','TC-07-01','TC-07-04'],
 'R7': ['TC-01-01','TC-01-06','TC-01-07','TC-06-01'],
 'R8': ['TC-02-03','TC-02-04','TC-02-05','TC-06-03'],
}
for c in cases:
    c['risk_ref'] = [r for r, lst in risk_cov.items() if c['id'] in lst]

ev = {}
sec = md.split('### 附录 C：代码证据清单')[1].split('### 附录 D')[0]
for line in sec.split('\n'):
    m = re.match(r'^\|\s*(TC-[\d-]+)\s*\|(.*)\|\s*$', line)
    if m:
        refs = re.findall(r'`([^`]+)`', m.group(2))
        if refs:
            ev.setdefault(m.group(1), []).extend(refs)
for c in cases:
    c['code_refs'] = ev.get(c['id'], [])
    c['evidence'] = {'level': 'E2', 'source': (c['code_refs'][0] if c['code_refs'] else None),
                     'confidence': 'medium'}
    c['automation'] = {'supported': 'yes' if c['code_refs'] else 'partial',
                       'framework': 'manual'}

out = {
 'meta': {'source_markmap': '测试用例_markmap.md', 'extracted_at': '2026-11-05',
          'strategy_ref': '测试策略.md'},
 'modules': [{'module': '%s. %s' % (k, module_names[k]),
              'shared_preconditions': shared.get(k, [])} for k in sorted(module_names, key=int)],
 'cases': cases,
}
io.open(os.path.join(QA, '测试用例.schema.yaml'),'w',encoding='utf-8',newline='\n').write(
    yaml.safe_dump(out, allow_unicode=True, sort_keys=False, width=100))
from collections import Counter
print('cases:', len(cases), 'code_refs:', sum(1 for c in cases if c['code_refs']))
print('priority:', dict(Counter(c['priority'] for c in cases)))
print('type:', dict(Counter(c['type'] for c in cases)))
