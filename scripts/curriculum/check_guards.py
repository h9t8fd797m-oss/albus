"""Exercise invalid in-memory fixtures without changing the published corpus."""
import copy

import gen

base = next(s for _, s in gen.load() if s['code'] == 'IB_DP_BIOLOGY')
base['syllabusTopics'] = [{'name': 'First', 'ordinal': 0}, {'name': 'Second', 'ordinal': 1}]
base['syllabusTopicsSource'] = 'https://example.org/test-only'
base['syllabusTopicsConfidence'] = 'official'

cases = {
    'blank topic name': (lambda s: s['syllabusTopics'][0].update(name=' '), 'non-empty name'),
    'duplicate ordinal': (lambda s: s['syllabusTopics'][1].update(ordinal=0), 'unique and contiguous'),
    'gap in ordinals': (lambda s: s['syllabusTopics'][1].update(ordinal=2), 'unique and contiguous'),
    'source without topics': (lambda s: s.update(syllabusTopics=[]), 'supplied together'),
    'topics without source': (lambda s: s.pop('syllabusTopicsSource'), 'supplied together'),
    'unverified topics': (lambda s: s.update(syllabusTopicsConfidence='unverified'), 'official or corroborated'),
    'one topic': (lambda s: s.update(syllabusTopics=s['syllabusTopics'][:1]), 'one-topic outline'),
    'confidence without topics': (lambda s: s.update(syllabusTopics=[], syllabusTopicsSource=None), 'empty syllabusTopics'),
    'reversed AO weighting': (lambda s: s['objectives'][0].update(weightingMin=50, weightingMax=20), 'weightingMin > weightingMax'),
    'objectives without source': (lambda s: s.pop('objectivesSource'), 'objectives and objectivesSource'),
    'source without objectives': (lambda s: s.update(objectives=[]), 'objectives and objectivesSource'),
    'unverified objectives': (lambda s: s.update(objectivesConfidence='unverified'), 'published objectives'),
    'confidence without objectives': (lambda s: s.update(objectives=[], objectivesSource=None), 'empty objectives'),
    'blank objective code': (lambda s: s['objectives'][0].update(code=' '), 'non-empty code'),
    'duplicate objective code': (lambda s: s['objectives'][1].update(code=s['objectives'][0]['code']), 'duplicate objective code'),
    'blank objective name': (lambda s: s['objectives'][0].update(name=' '), 'non-empty name'),
    'missing weighting bound': (lambda s: s['objectives'][0].update(weightingMin=20), 'both bounds or neither'),
    'negative weighting': (lambda s: s['objectives'][0].update(weightingMin=-1, weightingMax=20), 'numbers from 0 to 100'),
    'over-100 weighting': (lambda s: s['objectives'][0].update(weightingMin=20, weightingMax=101), 'numbers from 0 to 100'),
    'nonnumeric weighting': (lambda s: s['objectives'][0].update(weightingMin='20', weightingMax=30), 'numbers from 0 to 100'),
}
for label, (mutate, expected) in cases.items():
    fixture = copy.deepcopy(base)
    mutate(fixture)
    try:
        gen.validate(label, fixture)
    except gen.DataError as error:
        assert expected in str(error), f'Wrong guard fired for {label}: {error}'
        print(error)
    else:
        raise RuntimeError(f'GUARD DID NOT FIRE: {label}')
gen.validate('clean', base)
print(f'All {len(cases)} violating fixtures rejected; clean fixture accepted. No fixture persisted.')
