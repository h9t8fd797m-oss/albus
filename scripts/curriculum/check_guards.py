"""Exercise invalid in-memory fixtures without changing the published corpus."""
import copy
import gen
base=gen.load()[0][1]
base['syllabusTopics']=[{'name':'First','ordinal':0},{'name':'Second','ordinal':1}]
base['syllabusTopicsSource']='https://example.org/test-only'
base['syllabusTopicsConfidence']='official'
cases={
 'blank name':lambda s:s['syllabusTopics'][0].update(name=' '),
 'duplicate ordinal':lambda s:s['syllabusTopics'][1].update(ordinal=0),
 'gap in ordinals':lambda s:s['syllabusTopics'][1].update(ordinal=2),
 'source without topics':lambda s:s.update(syllabusTopics=[]),
 'topics without source':lambda s:s.pop('syllabusTopicsSource'),
 'unverified topics':lambda s:s.update(syllabusTopicsConfidence='unverified'),
 'one topic':lambda s:s.update(syllabusTopics=s['syllabusTopics'][:1]),
 'confidence without topics':lambda s:s.update(syllabusTopics=[],syllabusTopicsSource=None),
 'reversed AO weighting':lambda s:s.update(objectives=[{'code':'AO_TEST','weightingMin':50,'weightingMax':20}]),
}
for label,mutate in cases.items():
 s=copy.deepcopy(base); mutate(s)
 try:gen.validate(label,s)
 except gen.DataError as e:print(e)
 else:raise RuntimeError(f'GUARD DID NOT FIRE: {label}')
gen.validate('clean',base)
print('All 9 violating fixtures rejected; clean fixture accepted. No fixture persisted.')
