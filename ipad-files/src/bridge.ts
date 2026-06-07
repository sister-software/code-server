// Transport to the native iOS layer.
//
// The web extension host runs in a Web Worker, where window.webkit is
// unavailable AND fetch() to a custom scheme would be blocked by the worker
// host's CSP (connect-src). BroadcastChannel is not CSP-governed and is shared
// across same-origin contexts, so we use it to reach the wrapper's bridge.js
// relay in the main frame, which forwards to the native fileBridge handler.

const CHANNEL = "ipadfs-bridge"
const TIMEOUT_MS = 30_000

export class BridgeError extends Error {
  constructor(
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? `bridge error ${status}`)
    this.name = "BridgeError"
  }
}

/// Native reply shape: { ok: true, …payload } or { ok: false, status, error }.
export interface BridgeResult {
  ok: boolean
  status?: number
  error?: string
  [key: string]: unknown
}

interface Pending {
  resolve: (value: BridgeResult) => void
  reject: (error: unknown) => void
  timer: ReturnType<typeof setTimeout>
}

class Bridge {
  private readonly channel = new BroadcastChannel(CHANNEL)
  private readonly pending = new Map<string, Pending>()
  private seq = 0

  constructor() {
    this.channel.onmessage = (event: MessageEvent) => {
      const msg = event.data
      if (!msg || typeof msg.reqId !== "string" || !("result" in msg)) return
      const entry = this.pending.get(msg.reqId)
      if (!entry) return
      this.pending.delete(msg.reqId)
      clearTimeout(entry.timer)
      entry.resolve(msg.result as BridgeResult)
    }
  }

  request(
    op: string,
    params: Record<string, string> = {},
    bodyBase64?: string,
  ): Promise<BridgeResult> {
    const reqId = `${this.seq++}-${Math.random().toString(36).slice(2)}`
    return new Promise<BridgeResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(reqId)
        reject(new BridgeError(504, `bridge timeout for "${op}" (is the iOS wrapper connected?)`))
      }, TIMEOUT_MS)
      this.pending.set(reqId, { resolve, reject, timer })
      this.channel.postMessage({ reqId, op, params, bodyBase64 })
    })
  }
}

export const bridge = new Bridge()

// --- base64 helpers (binary read/write stays within message-reply types) -----

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = ""
  const chunk = 0x8000
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk))
  }
  return btoa(binary)
}

export function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}
