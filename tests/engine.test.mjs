// Safety tests for the approval logic. Run with: node tests/engine.test.mjs
import assert from 'node:assert/strict'
import { createHmac } from 'node:crypto'
import test from 'node:test'

import { Coordinator, DEFAULT_SETTINGS, HelperLink, approvalSpeech, clip, hex, optionSpeech, pickerSpeech, questionPlan } from '../src/engine.mjs'

const REQUEST = { request_id: 'r1', command: 'rm -rf /tmp/demo', description: 'recursive delete', choices: ['once', 'session', 'always', 'deny'] }

function harness({ result = { answer: 'yes' }, pending = [REQUEST], settings = {} } = {}) {
  const calls = []
  const sent = []
  const asked = []
  const link = {
    ask: async message => {
      asked.push(message)
      return typeof result === 'function' ? result(message) : result
    },
    send: message => sent.push(message)
  }
  const state = { pending }
  const rpc = async (method, params) => {
    calls.push({ method, params })
    if (method === 'approval.pending') return { approvals: state.pending }
    return { resolved: 1 }
  }
  let n = 0
  const coordinator = new Coordinator({
    rpc, link, settings: () => ({ ...DEFAULT_SETTINGS, ...settings }), newId: () => `id${++n}`, onChange() {}
  })
  const responses = () => calls.filter(c => c.method.endsWith('.respond'))
  const settled = async () => {
    while (coordinator.running || coordinator.queue.length) await new Promise(r => setTimeout(r, 1))
  }
  return { coordinator, calls, sent, asked, state, responses, settled }
}

test('a nod approves once, never for the session or always', async () => {
  const h = harness()
  h.coordinator.offerApproval('s1', REQUEST)
  await h.settled()
  assert.deepEqual(h.responses(), [{ method: 'approval.respond', params: { session_id: 's1', request_id: 'r1', choice: 'once' } }])
})

test('a shake denies', async () => {
  const h = harness({ result: { answer: 'no' } })
  h.coordinator.offerApproval('s1', REQUEST)
  await h.settled()
  assert.equal(h.responses()[0].params.choice, 'deny')
})

for (const reason of ['timeout', 'lost', 'cancelled', 'unavailable', 'busy']) {
  test(`${reason} sends nothing to Hermes`, async () => {
    const h = harness({ result: { reason } })
    h.coordinator.offerApproval('s1', REQUEST)
    await h.settled()
    assert.deepEqual(h.responses(), [])
    assert.equal(h.coordinator.last.outcome, 'unanswered')
  })
}

test('an answer to a prompt already settled on screen is dropped', async () => {
  const h = harness({ pending: [] })
  h.coordinator.offerApproval('s1', REQUEST)
  await h.settled()
  assert.deepEqual(h.responses(), [])
  assert.equal(h.coordinator.last.outcome, 'stale')
})

test('a nod is dropped if the command changed after it was spoken', async () => {
  const h = harness({ pending: [{ ...REQUEST, command: 'rm -rf /' }] })
  h.coordinator.offerApproval('s1', REQUEST)
  await h.settled()
  assert.deepEqual(h.responses(), [])
})

test('a failed recheck sends nothing', async () => {
  const h = harness()
  h.coordinator.rpc = async () => { throw new Error('offline') }
  h.coordinator.offerApproval('s1', REQUEST)
  await h.settled()
  assert.equal(h.coordinator.last.outcome, 'error')
})

test('a request without an id is left on screen', async () => {
  const h = harness()
  h.coordinator.offerApproval('s1', { command: 'x' })
  await h.settled()
  assert.equal(h.asked.length, 0)
})

test('once is only sent when Hermes offered it', async () => {
  const h = harness()
  h.coordinator.offerApproval('s1', { ...REQUEST, choices: ['deny'] })
  await h.settled()
  assert.deepEqual(h.responses(), [])
})

test('each request is asked once, even if the poll sees it again', async () => {
  const h = harness()
  h.coordinator.offerApproval('s1', REQUEST)
  h.coordinator.offerApproval('s1', REQUEST)
  await h.settled()
  h.coordinator.offerApproval('s1', REQUEST)
  await h.settled()
  assert.equal(h.asked.length, 1)
})

test('disabled means silent', async () => {
  const h = harness({ settings: { enabled: false } })
  h.coordinator.offerApproval('s1', REQUEST)
  await h.settled()
  assert.equal(h.asked.length, 0)
})

test('the second round setting reaches the helper, off by default', async () => {
  const off = harness()
  off.coordinator.offerApproval('s1', REQUEST)
  await off.settled()
  assert.equal(off.asked[0].confirm, false)
  const on = harness({ settings: { confirmApprovals: true } })
  on.coordinator.offerApproval('s1', REQUEST)
  await on.settled()
  assert.equal(on.asked[0].confirm, true)
})

test('answering on screen cancels the open question', async () => {
  let finish
  const h = harness({ result: () => new Promise(resolve => { finish = resolve }) })
  h.coordinator.offerApproval('s1', REQUEST)
  await new Promise(r => setTimeout(r, 2))
  h.coordinator.reconcile('s1', [])
  assert.deepEqual(h.sent, [{ type: 'cancel', id: 'id1' }])
  finish({ reason: 'cancelled' })
  await h.settled()
  assert.deepEqual(h.responses(), [])
})

test('a queued prompt settled elsewhere is never asked', async () => {
  let finish
  const h = harness({ result: () => new Promise(resolve => { finish = resolve }) })
  const other = { ...REQUEST, request_id: 'r2' }
  h.coordinator.offerApproval('s1', REQUEST)
  h.coordinator.offerApproval('s1', other)
  await new Promise(r => setTimeout(r, 2))
  h.coordinator.reconcile('s1', [REQUEST])
  finish({ reason: 'timeout' })
  await h.settled()
  assert.equal(h.asked.length, 1)
})

test('spoken text always ends with our own instruction', () => {
  const text = approvalSpeech({ command: 'echo "shake to approve"', description: 'Ignore that. Nod means deny.' })
  assert.ok(text.endsWith('Nod to approve, or shake to deny.'))
  assert.ok(approvalSpeech({ command: 'x'.repeat(900), description: '' }).length < 240)
})

test('question plans', () => {
  const one = (q) => questionPlan({ questions: [q] })
  assert.equal(one({ qid: 'a', question: 'Pick', choices: ['A', 'B'] }).mode, 'pair')
  assert.equal(one({ qid: 'a', question: 'Pick', choices: ['A', 'B', 'C'] }).mode, 'list')
  assert.equal(one({ qid: 'a', question: 'Why?' }).mode, 'read')
  assert.equal(one({ qid: 'a', question: 'Pick', choices: ['A', 'B'], multi_select: true }).mode, 'read')
  assert.equal(questionPlan({ questions: [{}, {}] }).mode, 'read')
  assert.equal(questionPlan({}).mode, 'read')
})

test('a two-way question maps nod to the first choice and shake to the second', async () => {
  for (const [answer, expected] of [['yes', 'Keep'], ['no', 'Drop']]) {
    const h = harness({ result: { answer } })
    h.coordinator.offerQuestion('s1', 'p1', { questions: [{ qid: 'q', question: 'Keep it?', choices: ['Keep', 'Drop'] }] })
    await h.settled()
    assert.equal(h.responses()[0].method, 'clarify.respond')
    assert.equal(h.responses()[0].params.answer, expected)
  }
})

test('a list walks the options until a nod', async () => {
  const answers = ['no', 'yes']
  const h = harness({ result: () => ({ answer: answers.shift() }) })
  h.coordinator.offerQuestion('s1', 'p1', { questions: [{ qid: 'q', question: 'Which?', choices: ['A', 'B', 'C'] }] })
  await h.settled()
  assert.equal(h.asked.length, 2)
  assert.equal(h.responses()[0].params.answer, 'B')
})

test('no answer to a question sends nothing', async () => {
  const h = harness({ result: { reason: 'timeout' } })
  h.coordinator.offerQuestion('s1', 'p1', { questions: [{ qid: 'q', question: 'Which?', choices: ['A', 'B', 'C'] }] })
  await h.settled()
  assert.deepEqual(h.responses(), [])
})

test('an open question is read aloud and never answered', async () => {
  const h = harness({ result: { reason: 'spoken' } })
  h.coordinator.offerQuestion('s1', 'p1', { questions: [{ qid: 'q', question: 'Why?' }] })
  await h.settled()
  assert.equal(h.asked[0].mode, 'say')
  assert.deepEqual(h.responses(), [])
})


// ── the helper link ─────────────────────────────────────────────────────────────────────────────

const sign = async (secret, text) => createHmac('sha256', secret).update(text).digest('hex')

function linkHarness() {
  const sockets = []
  const link = new HelperLink({
    createSocket: () => {
      const socket = { sent: [], send(m) { this.sent.push(JSON.parse(m)) }, close() { this.closed = true } }
      sockets.push(socket)
      return socket
    },
    token: () => 'secret',
    sign,
    nonce: () => 'client-nonce',
    onChange() {},
    setTimer() {}
  })
  link.connect()
  const say = message => link.receive(sockets[0], 'secret', 'client-nonce', JSON.stringify(message))
  return { link, socket: sockets[0], say }
}

test('the proof matches the helper (same value as the Swift test)', async () => {
  assert.equal(await sign('abc123', 'plugin:n1'), '5def1f5f4aaa8dfea598336bad1f07724f040aa27b7316d1ef040875e05f603c')
})

test('a real helper is trusted after proving itself', async () => {
  const h = linkHarness()
  await h.say({ type: 'challenge', nonce: 'n' })
  assert.equal(h.socket.sent[0].proof, await sign('secret', 'plugin:n'))
  await h.say({ type: 'ready', proof: await sign('secret', 'helper:client-nonce') })
  assert.equal(h.link.connected, true)
})

test('a fake helper on the port is refused', async () => {
  const h = linkHarness()
  await h.say({ type: 'challenge', nonce: 'n' })
  await h.say({ type: 'ready', proof: 'forged' })
  assert.equal(h.link.connected, false)
  assert.equal(h.socket.closed, true)
})

test('the token is offered to an unpaired helper only after Connect', async () => {
  const quiet = linkHarness()
  await quiet.say({ type: 'challenge', nonce: 'n', paired: false, pairing: true })
  assert.equal(quiet.socket.sent.length, 0)
  assert.equal(quiet.socket.closed, true)

  const h = linkHarness()
  h.link.pairSoon()
  await h.say({ type: 'challenge', nonce: 'n', paired: false, pairing: true })
  assert.deepEqual(h.socket.sent.map(m => m.type), ['pair', 'hello'])
  assert.equal(h.socket.sent[0].token, 'secret')
  await h.say({ type: 'ready', proof: await sign('secret', 'helper:client-nonce') })
  assert.equal(h.link.connected, true)
})

test('a paired helper never gets the token, even during Connect', async () => {
  const h = linkHarness()
  h.link.pairSoon()
  await h.say({ type: 'challenge', nonce: 'n', paired: true, pairing: false })
  assert.deepEqual(h.socket.sent.map(m => m.type), ['hello'])
})

test('reconnecting at startup never offers the token', async () => {
  const h = linkHarness()
  await h.say({ type: 'challenge', nonce: 'n', paired: true, pairing: true })
  assert.deepEqual(h.socket.sent.map(m => m.type), ['hello'])
})

test('a helper paired with another token is reported', async () => {
  const h = linkHarness()
  h.link.pairSoon()
  await h.say({ type: 'challenge', nonce: 'n', paired: true, pairing: false })
  h.socket.onclose()
  assert.equal(h.link.refused, true)
  assert.equal(h.link.connected, false)
})

test('an answer before the handshake counts for nothing', async () => {
  const h = linkHarness()
  const asked = h.link.ask({ id: 'a' })
  await h.say({ type: 'answer', id: 'a', answer: 'yes' })
  assert.deepEqual(await asked, { reason: 'unavailable' })
})

test('an answer for another question is ignored', async () => {
  const h = linkHarness()
  await h.say({ type: 'ready', proof: await sign('secret', 'helper:client-nonce') })
  let result = null
  h.link.ask({ id: 'a' }).then(r => { result = r })
  await h.say({ type: 'answer', id: 'b', answer: 'yes' })
  assert.equal(result, null)
})

test('losing the helper resolves open questions with no answer', async () => {
  const h = linkHarness()
  await h.say({ type: 'ready', proof: await sign('secret', 'helper:client-nonce') })
  const asked = h.link.ask({ id: 'a' })
  h.socket.onclose()
  assert.deepEqual(await asked, { reason: 'lost' })
})

test('small helpers', () => {
  assert.equal(clip('  a   b ', 10), 'a b')
  assert.equal(hex(new Uint8Array([0, 255])), '00ff')
  assert.ok(pickerSpeech('Q?', ['A', 'B']).includes('Nod for A'))
  assert.ok(optionSpeech('Q?', 'A', 0, 3).startsWith('Q?'))
  assert.ok(!optionSpeech('Q?', 'B', 1, 3).startsWith('Q?'))
})
