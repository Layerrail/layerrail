const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');
const { buildSync } = require('esbuild');
const { marked } = require('marked');
const jquery = require('jquery');
const purify = require('dompurify');

const bundle = buildSync({ entryPoints: ['assets/js/playground/controller.js'], bundle: true, format: 'iife', globalName: 'Playground', write: false }).outputFiles[0].text;
const responseBundle = buildSync({ entryPoints: ['assets/js/playground/response.js'], bundle: true, format: 'cjs', platform: 'node', write: false }).outputFiles[0].text;
const responseModule = { exports: {} };
new Function('module', 'exports', responseBundle)(responseModule, responseModule.exports);
const { visibleAnswer, readEventStream } = responseModule.exports;
const tick = async () => { for (let i = 0; i < 4; i++) await new Promise(setImmediate); };
const jsonResponse = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });

function fixture(t, { api = 'chat', provider = 'cloudflare', capability = 'Text Generation', fetch } = {}) {
  const dom = new JSDOM(`<!doctype html><section id="inference_playground" data-state="idle">
    <select id="inference_endpoint"><option value="test-model" data-url="https://model.test" data-api="${api}" data-provider="${provider}" data-capability="${capability}" data-tags='{"multimodal":true}' data-display-name="Test model" data-input-price="2" data-output-price="4">test-model</option></select>
    <select id="inference_api_key"><option value="test-key">Test key</option></select>
    <button id="inference_new_chat">New chat</button><div id="inference_conversation"><div id="inference_previous_empty"><div id="inference_welcome_orb"></div><div id="inference_starters"><button data-prompt-template="json">JSON</button></div></div><div id="inference_previous"></div></div>
    <label for="inference_prompt">Message</label><textarea id="inference_prompt"></textarea><div id="inference_context_container"><textarea id="inference_context"></textarea></div>
    <input id="inference_files" type="file" multiple><button id="inference_attach"></button><button id="inference_clear_files"></button><span id="inference_attachment_summary"></span>
    <button id="inference_submit"><span id="inference_submit_label">Send</span><span id="inference_submit_icon"></span></button><div id="inference_error" hidden></div><div id="inference_status"></div><p id="inference_task_hint"></p>
    <details id="inference_settings"><fieldset id="inference_config_advanced_settings"><textarea id="inference_system"></textarea>
    <input id="inference_temperature" type="number" min="0" max="2" step=".1"><input id="inference_top_p" type="number" min="0" max="1" step=".05"><input id="inference_max_tokens" type="number" min="1">
    <select id="inference_response_format"><option value=""></option><option value="json_object">JSON</option></select><select id="inference_prompt_template"><option value=""></option><option value="json">JSON</option><option value="code">Code</option></select>
    <input id="inference_source_language"><input id="inference_target_language"><input id="inference_top_k"><input id="inference_image_width"><input id="inference_image_height"></fieldset></details>
    ${['model_name', 'provider', 'capability', 'context', 'price', 'url'].map((key) => `<span id="inference_selected_${key}"></span>`).join('')}
    ${['message_count', 'usage', 'cost'].map((key) => `<span id="inference_session_${key}"></span>`).join('')}
    <span id="inference_last_usage"></span><span data-free-quota-value="1000"></span></section>`, { url: 'https://console.test', runScripts: 'outside-only' });
  const w = dom.window;
  w.$ = jquery(w);
  w.marked = marked;
  w.DOMPurify = purify(w);
  Object.assign(w, { fetch, TextEncoder, TextDecoder, AbortController });
  w.requestAnimationFrame = (fn) => setImmediate(fn);
  const states = [];
  const orbs = new Map();
  const effects = {
    orb(element, state) { if (!element) return; states.push(state); if (state) orbs.set(element, state); else orbs.delete(element); },
    busy(value) { effects.isBusy = value; }
  };
  w.eval(bundle);
  w.Playground.setupPlayground(effects);
  t.after(() => dom.window.close());
  return { w, $: w.$, effects, states, orbs, state: () => w.document.getElementById('inference_playground').dataset.state, send: async (prompt = 'Hello') => { w.$('#inference_prompt').val(prompt); w.$('#inference_submit').trigger('click'); await tick(); } };
}

test('reasoning uses the orb, streamed answers render safely, usage counts once', async (t) => {
  let stream;
  const f = fixture(t, { fetch: async () => new Response(new ReadableStream({ start(controller) { stream = controller; } })) });
  const frame = async (value) => { stream.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(value)}\n\n`)); await tick(); };
  await f.send('<img src=x onerror=alert(1)>');
  assert.equal(f.state(), 'waiting');
  assert.equal(f.$('#inference_message_0 img').length, 0);
  assert.equal(f.$('#inference_submit').attr('aria-label'), 'Stop response');
  assert.ok(f.states.includes('working'));
  await frame({ choices: [{ delta: { reasoning_content: 'Private reasoning text' } }] });
  assert.equal(f.state(), 'reasoning');
  assert.ok(f.states.includes('solving'));
  assert.ok(!f.$('#inference_previous').text().includes('Private reasoning'));
  await frame({ choices: [{ delta: { content: '**Answer** <img src=x onerror=alert(1)>' } }], usage: { prompt_tokens: 10, completion_tokens: 5 } });
  assert.equal(f.state(), 'streaming');
  assert.equal(f.$('#inference_message_1 strong').text(), 'Answer');
  assert.equal(f.$('#inference_message_1 [onerror]').length, 0);
  await frame({ choices: [], usage: { prompt_tokens: 10, completion_tokens: 5 } });
  stream.close(); await tick();
  assert.equal(f.state(), 'complete');
  assert.equal(f.orbs.size, 0);
  assert.equal(f.$('#inference_session_usage').text(), '10 input · 5 output');
  assert.equal(f.$('[data-free-quota-value]').text(), '985');
  assert.equal(f.$('#inference_endpoint').prop('disabled'), false);
  assert.equal(f.$('#inference_orb_1').prop('hidden'), true);
});

test('GPT-6 Astra Responses requests preserve zero settings and Azure quota', async (t) => {
  let sent;
  const f = fixture(t, { api: 'responses', provider: 'azure_foundry', fetch: async (url, options) => {
    sent = { url, body: JSON.parse(options.body) };
    return jsonResponse({ output: [{ content: [{ text: '<think>Hidden thoughts</think>Clear answer' }] }], usage: { input_tokens: 7, output_tokens: 9 } });
  } });
  f.$('#inference_temperature, #inference_top_p').val('0');
  f.$('#inference_max_tokens').val('512');
  f.$('#inference_system').val('Be concise');
  await f.send();
  assert.equal(sent.url, 'https://model.test/v1/responses');
  assert.equal(sent.body.temperature, 0);
  assert.equal(sent.body.top_p, 0);
  assert.equal(sent.body.max_output_tokens, 512);
  assert.equal(sent.body.instructions, 'Be concise');
  assert.equal(sent.body.stream, false);
  assert.equal(f.$('#inference_message_1').text().trim(), 'Clear answer');
  assert.equal(f.$('[data-free-quota-value]').attr('data-free-quota-value'), '1000');
  assert.equal(f.state(), 'complete');
});

test('Stop aborts the request and always clears the busy UI', async (t) => {
  let signal;
  const f = fixture(t, { fetch: (_, options) => new Promise((resolve, reject) => {
    signal = options.signal;
    signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')));
  }) });
  await f.send();
  f.$('#inference_submit').trigger('click'); await tick();
  assert.equal(signal.aborted, true);
  assert.equal(f.state(), 'stopped');
  assert.equal(f.orbs.size, 0);
  assert.equal(f.effects.isBusy, false);
  assert.equal(f.$('#inference_message_info_1').text(), 'Response stopped.');
});

test('New chat isolates an in-flight response from the next conversation', async (t) => {
  const pending = [];
  const f = fixture(t, { api: 'responses', fetch: (_, options) => new Promise((resolve) => pending.push({ resolve, signal: options.signal })) });
  await f.send('Old conversation');
  f.$('#inference_new_chat').trigger('click');
  assert.equal(pending[0].signal.aborted, true);
  await f.send('New conversation');
  pending[0].resolve(jsonResponse({ output_text: 'Old answer', usage: { input_tokens: 100, output_tokens: 100 } }));
  await tick();
  assert.equal(f.state(), 'waiting');
  assert.ok(!f.$('#inference_previous').text().includes('Old answer'));
  pending[1].resolve(jsonResponse({ output_text: 'New answer', usage: { input_tokens: 2, output_tokens: 3 } }));
  await tick();
  assert.equal(f.$('#inference_message_1').text().trim(), 'New answer');
  assert.equal(f.$('#inference_session_usage').text(), '2 input · 3 output');
  assert.equal(f.state(), 'complete');
});

test('HTTP errors restore the draft and expose an accessible error', async (t) => {
  const f = fixture(t, { fetch: async () => jsonResponse({ error: { message: 'Rate limit reached.' } }, 429) });
  await f.send('Please retry me');
  assert.equal(f.state(), 'error');
  assert.equal(f.$('#inference_error').prop('hidden'), false);
  assert.equal(f.$('#inference_error').text(), 'Rate limit reached.');
  assert.equal(f.$('#inference_prompt').val(), 'Please retry me');
  assert.equal(f.effects.isBusy, false);
});

test('preparation errors unlock controls without creating empty messages', async (t) => {
  const f = fixture(t, { capability: 'Automatic Speech Recognition', fetch: () => assert.fail('Must not send without an audio file') });
  await f.send('');
  assert.equal(f.$('.playground-message').length, 0);
  assert.equal(f.state(), 'error');
  assert.match(f.$('#inference_error').text(), /upload an audio file/);
  assert.equal(f.$('#inference_attach').prop('disabled'), false);
});

test('native audio uploads retain their payload and render transcription', async (t) => {
  let payload;
  const f = fixture(t, { capability: 'Automatic Speech Recognition', fetch: async (_, options) => {
    payload = JSON.parse(options.body);
    return jsonResponse({ result: { text: 'Hello from audio' }, usage: { prompt_tokens: 4, completion_tokens: 3 } });
  } });
  const file = new f.w.File([new Uint8Array([1, 2, 3])], 'voice.wav', { type: 'audio/wav' });
  Object.defineProperty(f.w.document.getElementById('inference_files'), 'files', { value: [file] });
  await f.send('');
  assert.deepEqual(payload.audio, [1, 2, 3]);
  assert.equal(f.$('#inference_message_1').text().trim(), 'Hello from audio');
  assert.equal(f.state(), 'complete');
});

test('embeddings and rerank preserve their task-specific inputs', async (t) => {
  for (const capability of ['Embeddings', 'Rerank']) {
    let sent;
    const f = fixture(t, { capability, fetch: async (url, options) => {
      sent = { url, body: JSON.parse(options.body) };
      return jsonResponse(capability === 'Embeddings' ? { data: [{ embedding: [0.1, 0.2] }] } : { result: [{ index: 0, score: 0.8 }] });
    } });
    f.$('#inference_context').val('Document one\nDocument two');
    await f.send('Find this');
    assert.equal(f.state(), 'complete');
    if (capability === 'Embeddings') {
      assert.equal(sent.url, 'https://model.test/v1/embeddings');
      assert.equal(sent.body.input, 'Find this');
    } else {
      assert.equal(sent.url, 'https://model.test/v1/run');
      assert.deepEqual(sent.body.contexts, [{ text: 'Document one' }, { text: 'Document two' }]);
      assert.equal(sent.body.query, 'Find this');
    }
  }
});

test('PDF attachment selection and prompt templates remain usable', async (t) => {
  const f = fixture(t, { fetch: async () => jsonResponse({}) });
  assert.match(f.$('#inference_files').attr('accept'), /\.pdf/);
  f.$('[data-prompt-template="json"]').trigger('click');
  assert.equal(f.$('#inference_response_format').val(), 'json_object');
  assert.match(f.$('#inference_prompt').val(), /JSON object/);
  f.$('#inference_prompt_template').val('code').trigger('change');
  assert.equal(f.$('#inference_response_format').val(), '');
});

test('keyboard send handles Ctrl/Command+Enter without submitting plain Enter', async (t) => {
  let calls = 0;
  const f = fixture(t, { api: 'responses', fetch: async () => { calls++; return jsonResponse({ output_text: 'Done' }); } });
  f.$('#inference_prompt').val('Hello').trigger(f.$.Event('keydown', { key: 'Enter' }));
  await tick(); assert.equal(calls, 0);
  f.$('#inference_prompt').trigger(f.$.Event('keydown', { key: 'Enter', ctrlKey: true }));
  await tick(); assert.equal(calls, 1);
});

test('reasoning tags never leak across split stream chunks or into history', () => {
  for (const chunk of ['<', '<thi', '<think>', '<think>Reasoning', '<think>Reasoning</thi']) {
    assert.equal(visibleAnswer(chunk).text, '');
    assert.equal(visibleAnswer(chunk).thinking, true);
  }
  assert.equal(visibleAnswer('<think>Reasoning</think>Answer').text, 'Answer');
  const literal = 'Example: `<think>content</think>`';
  assert.equal(visibleAnswer(literal).text, literal);
});

test('SSE handles UTF-8 boundaries, CRLF, multiline data and missing final newline', async () => {
  const bytes = new TextEncoder().encode(': keepalive\r\ndata: {"message":\r\ndata: "Hello 🌍"}\r\n\r\ndata: {"last":true}');
  const stream = new ReadableStream({ start(controller) { for (const byte of bytes) controller.enqueue(new Uint8Array([byte])); controller.close(); } });
  const frames = [];
  for await (const frame of readEventStream(stream)) frames.push(frame);
  assert.deepEqual(frames, [{ message: 'Hello 🌍' }, { last: true }]);
  assert.equal(stream.locked, false);
});

test('SSE terminates at DONE and surfaces malformed frames', async () => {
  const stream = (text) => new Response(text).body;
  const frames = [];
  for await (const frame of readEventStream(stream('data: {"ok":true}\n\ndata: [DONE]\n\ndata: {"ignored":true}\n\n'))) frames.push(frame);
  assert.deepEqual(frames, [{ ok: true }]);
  await assert.rejects(async () => { for await (const frame of readEventStream(stream('data: invalid\n\n'))) void frame; }, /invalid response stream/);
});
