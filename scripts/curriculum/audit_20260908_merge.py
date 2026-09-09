#!/usr/bin/env python3
"""Keep the hand-merge verdict reproducible against immutable Git objects."""
import json
import subprocess

BASE = 'e0dd0b595f313d4f460bfa06c20af3659cfc147a'
TOPICS = '45cbe5c1b36a57b33e9df895475a494a31174755'
OBJECTIVES = '1a609f704eedcfe9e6ef124a48ca64bbf2b0024a'
LANDED = '24a9f2e421a207903afd31a30e5912bae46ebb50'


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, f'duplicate JSON key: {key}'
        result[key] = value
    return result


def read(revision, path):
    return json.loads(git('show', f'{revision}:{path}'), object_pairs_hook=unique_keys)


paths = git('ls-tree', '-r', '--name-only', LANDED, 'scripts/curriculum/data').splitlines()
missing = object()
field_count = note_count = 0
for path in paths:
    base, topics, objectives, landed = [read(rev, path) for rev in (BASE, TOPICS, OBJECTIVES, LANDED)]
    expected = {}
    changed = []
    for key in sorted(set(base) | set(topics) | set(objectives)):
        b, t, o = (record.get(key, missing) for record in (base, topics, objectives))
        if key == 'notes':
            assert t[:len(b)] == b and o[:len(b)] == b, f'{path}: authored note removal requires review'
            value = t + [note for note in o[len(b):] if note not in t]
            note_count += len(value)
        elif t == o or o == b:
            value = t
        elif t == b:
            value = o
        else:
            raise AssertionError(f'{path}: conflicting authored values for {key}')
        if value is not missing:
            expected[key] = value
        if t != b or o != b:
            changed.append(key)
        field_count += 1
    assert landed == expected, f'{path}: landed differs from exact authored union'
    for array, confidence in [('syllabusTopics', 'syllabusTopicsConfidence'), ('objectives', 'objectivesConfidence')]:
        assert landed.get(array) or landed.get(confidence) not in ('official', 'corroborated'), f'{path}: confidence on empty {array}'
    print(f"PASS {path.rsplit('/', 1)[1]}: exact authored union; changed fields={','.join(changed)}; notes={len(landed['notes'])}; topics={len(landed.get('syllabusTopics', []))}; objectives={len(landed.get('objectives', []))}")
    if landed['subject'] in ('Biology', 'Chemistry', 'Physics') and landed['qualification'] == 'IB_DP':
        assert landed['syllabusTopics'] == topics['syllabusTopics']
        assert landed['syllabusTopicsSource'] == topics['syllabusTopicsSource']
        assert landed['objectives'] == objectives['objectives']
        assert landed['objectivesSource'] == objectives['objectivesSource']
        assert [ao['code'] for ao in landed['objectives']] == ['AO1', 'AO2', 'AO3', 'AO4']
        print('  PASS science arrays preserve authored order and independently attached sources')
    if landed['subject'] == 'History':
        assert landed['lastAssessment'] == 2027 and landed['supersededBy'] == 'First assessment 2028'
        assert all(r['lastAssessment'] == 2027 and r['supersededBy'] == 'First assessment 2028' for r in (base, topics, objectives))
        print('  PASS History dates already agree in common base and both authored branches; no duplicate keys')
assert git('rev-parse', 'e502286^{tree}') == git('rev-parse', f'{LANDED}^{{tree}}')
print(f'PASS {len(paths)} subjects, {field_count} top-level fields, {note_count} notes: no unexplained difference or lost note')
print('PASS e502286 and 24a9f2e have identical entire Git trees')
print(f"Observed landed parent(s): {git('show', '-s', '--format=%P', LANDED)}")
