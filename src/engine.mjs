// The logic behind AirPods Approvals: what gets asked, what is said, and when an answer may reach
// Hermes. No SDK or browser globals here, so every rule is tested by tests/engine.test.mjs.
//
// The rule that matters most: Hermes only hears "once" after a completed gesture from the helper
// and a fresh check that this exact request is still waiting. Every other path sends nothing, so
// the prompt stays on screen and Hermes' own timeout denies it.

export const HELPER_URL = 'ws://127.0.0.1:47291'
// Desktop opens a bare local path with macOS, which starts the helper. Custom URL schemes are refused.
export const HELPER_APP = '~/Applications/Hermes AirPods.app'

export const DEFAULT_SETTINGS = {
  enabled: true,
  confirmApprovals: false,
  listenSeconds: 8,
  questions: true,
}

const SEEN_LIMIT = 300

export function clip(value, limit) {
  const text = String(value == null ? '' : value).replace(/\s+/g, ' ').trim()
  return text.length > limit ? `${text.slice(0, limit - 1).trimEnd()}…` : text
}

// The closing instruction is always ours and always last, so text inside a command can't change
// what a nod means.
export function approvalSpeech(request) {
  const reason = clip(request.description, 160).replace(/[.\s]+$/, '')
  const command = clip(request.command, 140)
  const parts = ['Hermes needs your approval.']
  if (reason) parts.push(`${reason}.`)
  if (command) parts.push(`The command is: ${command}.`)
  parts.push('Nod to approve, or shake to deny.')
  return parts.join(' ')
}

export function pickerSpeech(question, choices) {
  const [first, second] = choices
  return `${clip(question, 200)} Nod for ${clip(first, 60)}. Shake for ${clip(second, 60)}.`
}

export function optionSpeech(question, choice, index, total) {
  const lead = index === 0 ? `${clip(question, 200)} ` : ''
  return `${lead}Option ${index + 1} of ${total}: ${clip(choice, 80)}. Nod to choose it, or shake for the next.`
}

// One plain question with choices can be answered by head. Anything else is read aloud and left
// on screen.
export function questionPlan(params) {
  const questions = Array.isArray(params.questions) ? params.questions : []
  if (questions.length !== 1) return { mode: 'read', text: 'Hermes has some questions for you on screen.' }
  const q = questions[0]
  const choices = (Array.isArray(q.choices) ? q.choices : []).map(String).filter(Boolean)
  if (q.multi_select || choices.length < 2) {
    return { mode: 'read', text: `Hermes asks: ${clip(q.question, 240)} Please answer on screen.` }
  }
  return { mode: choices.length === 2 ? 'pair' : 'list', qid: q.qid, question: q.question, choices }
}

export function hex(bytes) {
  return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('')
}

// The authenticated link to the Mac helper. Nothing from the helper counts until it has proved it
// holds the pairing token, so a process squatting on the port can't forge an answer.
export class HelperLink {
  constructor({ createSocket, token, sign, nonce, onChange, setTimer }) {
    Object.assign(this, { createSocket, token, sign, nonce, onChange, setTimer })
    this.socket = null
    this.trusted = false
    this.status = {}
    this.waiting = new Map()
    this.progress = () => {}
    this.closed = false
    // Set only when the user presses Connect. The token is never offered to the helper otherwise,
    // so something squatting on the port can't collect it in the background.
    this.pairUntil = 0
    this.refused = false
  }

  pairSoon(now = Date.now()) {
    this.pairUntil = now + 20000
    this.refused = false
  }

  get connected() {
    return this.trusted
  }

  connect() {
    if (this.closed || this.socket) return
    const secret = this.token()
    if (!secret) return
    let socket
    try {
      socket = this.createSocket(HELPER_URL)
    } catch {
      this.retry()
      return
    }
    this.socket = socket
    const clientNonce = this.nonce()
    socket.onmessage = event => this.receive(socket, secret, clientNonce, event.data)
    socket.onclose = () => this.dropped(socket)
    socket.onerror = () => {}
  }

  retry() {
    if (!this.closed) this.setTimer(() => this.connect(), Date.now() < this.pairUntil ? 700 : 3000)
  }

  dropped(socket) {
    if (socket !== this.socket) return
    // The helper hung up after our hello during a Connect: it is paired with another token.
    if (!this.trusted && this.offered) {
      this.refused = true
      this.pairUntil = 0
    }
    this.offered = false
    this.socket = null
    this.trusted = false
    this.onChange()
    for (const resolve of this.waiting.values()) resolve({ reason: 'lost' })
    this.waiting.clear()
    this.retry()
  }

  close() {
    this.closed = true
    if (this.socket) this.socket.close()
  }

  async receive(socket, secret, clientNonce, data) {
    let message
    try {
      message = JSON.parse(data)
    } catch {
      return
    }
    if (socket !== this.socket) return

    if (!this.trusted) {
      if (message.type === 'challenge') {
        const pairing = Date.now() < this.pairUntil
        if (pairing && (message.paired === false || message.pairing === true)) {
          socket.send(JSON.stringify({ type: 'pair', token: secret }))
        } else if (message.paired === false) {
          socket.close()
          return
        }
        const proof = await this.sign(secret, `plugin:${message.nonce}`)
        socket.send(JSON.stringify({ type: 'hello', nonce: clientNonce, proof }))
        this.offered = pairing
      } else if (message.type === 'ready') {
        if (message.proof !== (await this.sign(secret, `helper:${clientNonce}`))) {
          socket.close()
          return
        }
        this.trusted = true
        this.pairUntil = 0
        this.refused = false
        this.status = message
        this.onChange()
      }
      return
    }

    if (message.type === 'status') {
      this.status = message
      this.onChange()
    } else if (message.type === 'progress') {
      this.progress(message)
    } else if (message.type === 'answer' || message.type === 'ended') {
      const resolve = this.waiting.get(message.id)
      if (resolve) {
        this.waiting.delete(message.id)
        resolve(message.type === 'answer' ? { answer: message.answer } : { reason: message.reason })
      }
    }
  }

  send(message) {
    if (this.trusted && this.socket) this.socket.send(JSON.stringify(message))
  }

  ask(message) {
    if (!this.trusted) return Promise.resolve({ reason: 'unavailable' })
    return new Promise(resolve => {
      this.waiting.set(message.id, resolve)
      this.send({ type: 'ask', ...message })
    })
  }
}

// Decides what to ask and carries answers back to Hermes, one prompt at a time.
export class Coordinator {
  constructor({ rpc, link, settings, newId, onChange }) {
    Object.assign(this, { rpc, link, settings, newId, onChange })
    this.queue = []
    this.seen = new Set()
    this.current = null
    this.running = false
    this.last = null
  }

  remember(key) {
    this.seen.add(key)
    if (this.seen.size > SEEN_LIMIT) this.seen.delete(this.seen.values().next().value)
  }

  offerApproval(sessionId, request) {
    // Without a request id an answer couldn't be tied to this prompt, so it stays on screen.
    if (!this.settings().enabled || !sessionId || !request || !request.request_id) return
    this.offer({ kind: 'approval', key: `a:${sessionId}:${request.request_id}`, sessionId, request })
  }

  offerQuestion(sessionId, promptId, params) {
    if (!this.settings().enabled || !this.settings().questions || !sessionId || !promptId) return
    this.offer({ kind: 'question', key: `q:${sessionId}:${promptId}`, sessionId, promptId, params })
  }

  offer(item) {
    if (this.seen.has(item.key)) return
    this.remember(item.key)
    this.queue.push(item)
    void this.drain()
  }

  // Called with each poll. If a prompt was answered on screen or timed out, stop asking about it.
  reconcile(sessionId, pending) {
    const live = new Set(pending.map(p => p.request_id))
    this.queue = this.queue.filter(item => !(item.kind === 'approval' && item.sessionId === sessionId && !live.has(item.request.request_id)))
    const now = this.current
    if (now && now.kind === 'approval' && now.sessionId === sessionId && !live.has(now.request.request_id) && now.askId) {
      this.link.send({ type: 'cancel', id: now.askId })
    }
  }

  async drain() {
    if (this.running) return
    this.running = true
    while (this.queue.length) {
      const item = this.queue.shift()
      this.current = item
      this.onChange()
      try {
        await (item.kind === 'approval' ? this.runApproval(item) : this.runQuestion(item))
      } catch (error) {
        this.note(item, 'error', String((error && error.message) || error))
      }
      this.current = null
      this.onChange()
    }
    this.running = false
  }

  note(item, outcome, detail) {
    this.last = { kind: item.kind, outcome, detail: detail || '' }
    // Once Hermes has taken the answer, the helper plays how it landed.
    const sound = { approved: 'approved', denied: 'denied', answered: 'approved', stale: 'failed', error: 'failed' }[outcome]
    if (sound) this.link.send({ type: 'result', outcome: sound })
    this.onChange()
  }

  async ask(item, text, { confirm = false, mode = 'gesture' } = {}) {
    const { listenSeconds } = this.settings()
    const id = this.newId()
    item.askId = id
    // The helper fetches Gemini's voice itself, so the key never leaves the Mac's Keychain.
    const pending = this.link.ask({ id, mode, text, listenSeconds, confirm })
    const result = await pending
    item.askId = null
    return result
  }

  async stillWaiting(item) {
    const reply = await this.rpc('approval.pending', { session_id: item.sessionId }, 5000)
    const found = ((reply && reply.approvals) || []).find(p => p.request_id === item.request.request_id)
    return Boolean(found && found.command === item.request.command)
  }

  async runApproval(item) {
    const { request, sessionId } = item
    const result = await this.ask(item, approvalSpeech(request), { confirm: this.settings().confirmApprovals })
    if (!result.answer) {
      this.note(item, 'unanswered', result.reason)
      return
    }
    const offered = Array.isArray(request.choices) && request.choices.length ? request.choices : ['once', 'deny']
    const choice = result.answer === 'yes' ? 'once' : 'deny'
    if (!offered.includes(choice) || !(await this.stillWaiting(item))) {
      this.note(item, 'stale')
      return
    }
    await this.rpc('approval.respond', { session_id: sessionId, request_id: request.request_id, choice }, 30000)
    this.note(item, choice === 'once' ? 'approved' : 'denied')
  }

  async answerQuestion(item, plan, answer) {
    await this.rpc('clarify.respond', { session_id: item.sessionId, request_id: item.promptId, answer }, 30000)
    this.note(item, 'answered', answer)
  }

  async runQuestion(item) {
    const plan = questionPlan(item.params || {})
    if (plan.mode === 'read') {
      await this.ask(item, plan.text, { mode: 'say' })
      this.note(item, 'read')
      return
    }
    if (plan.mode === 'pair') {
      const result = await this.ask(item, pickerSpeech(plan.question, plan.choices))
      if (!result.answer) {
        this.note(item, 'unanswered', result.reason)
        return
      }
      await this.answerQuestion(item, plan, plan.choices[result.answer === 'yes' ? 0 : 1])
      return
    }
    for (let i = 0; i < plan.choices.length; i++) {
      const result = await this.ask(item, optionSpeech(plan.question, plan.choices[i], i, plan.choices.length))
      if (result.answer === 'yes') {
        await this.answerQuestion(item, plan, plan.choices[i])
        return
      }
      if (!result.answer) {
        this.note(item, 'unanswered', result.reason)
        return
      }
    }
    this.note(item, 'unanswered', 'no option chosen')
  }
}
