import test from 'node:test';
import assert from 'node:assert/strict';
import { fingerprint, mergeText, overlaps, classify, parseAnswers, labelIds, buildQuestions } from '../core.mjs';
const topics = [{ id: 'notes', name: 'AI 笔记', description: '自动收集与个人知识库' }, { id: 'design', name: '设计', description: '交互与界面' }];

test('normalization deduplicates whitespace and full-width characters', () => {
  assert.equal(fingerprint('ＡＩ  笔记\nhello'), fingerprint('AI 笔记 hello'));
  assert.notEqual(fingerprint('AI 笔记 hello'), fingerprint('AI 笔记 goodbye'));
});
test('scrolling preserves old paragraphs and adds only new paragraphs', () => {
  assert.deepEqual(mergeText('标题\n第一段\n第二段', '标题\n第二段\n第三段'), { text: '标题\n第一段\n第二段\n第三段', added: 1 });
  assert.equal(overlaps('标题\n第一段\n第二段', '标题\n第二段\n第三段'), 2 / 3);
  assert.equal(overlaps('旧内容', '完全不同的内容'), 0);
});
test('independent questions include full topic semantics, not just IDs', () => {
  const questions = buildQuestions(topics);
  assert.equal(questions.notes.type, 'noul');
  assert.equal(questions.notes.instructions.goal, '自动收集与个人知识库');
  assert.equal(questions.design.instructions.topic, '设计');
});
test('classification supports multiple matches, no matches, and manual corrections', () => {
  assert.deepEqual(labelIds({ scores: { notes: .9, design: .8 }, manual: {} }, topics), ['notes', 'design']);
  assert.deepEqual(labelIds({ scores: { notes: .2, design: .1 }, manual: {} }, topics), []);
  assert.deepEqual(labelIds({ scores: { notes: .9, design: .1 }, manual: { notes: false, design: true } }, topics), ['design']);
});
test('incomplete, invalid, and wrong-type model answers fail instead of inventing classifications', () => {
  for (const answers of [{}, { notes: { type: 'noul', noul: 1.5 } }, { notes: { type: 'choice', noul: .9 } }]) {
    assert.throws(() => parseAnswers({ answers }, topics));
  }
});
test('API integration uses bearer auth, narrow text state, and validates every answer', async () => {
  const result = await classify({ text: 'document', title: 'Title', app: 'Chrome' }, topics, {
    key: 'test-only', fetch: async (url, request) => {
      assert.equal(url, 'https://api.typesafe.ai/v1/systemone');
      assert.equal(request.headers.Authorization, 'Bearer test-only');
      const payload = JSON.parse(request.body);
      assert.equal(payload.state.document.text, 'document');
      assert.equal(Object.keys(payload.questions).length, 2);
      return new Response(JSON.stringify({ model: 'test', answers: { notes: { type: 'noul', noul: .92 }, design: { type: 'noul', noul: .17 } } }));
    },
  });
  assert.deepEqual(result.scores, { notes: .92, design: .17 });
});
test('auth errors surface and do not turn into fabricated labels', async () => {
  await assert.rejects(classify({ text: 'hello' }, topics, { key: 'test', fetch: async () => new Response('{}', { status: 401 }) }), /401/);
});
