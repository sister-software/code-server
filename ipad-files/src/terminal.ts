import * as vscode from "vscode"
import { base64ToBytes, bytesToBase64 } from "./bridge"

// Transport for the local terminal. Mirrors the file bridge: a same-origin
// BroadcastChannel relayed by the wrapper's bridge.js to a native handler that
// drives ios_system (a-Shell's engine). Output/ready/exit are pushed back.
const CHANNEL = "ipad-terminal"

interface NativeReply {
  ok: boolean
  error?: string
  [key: string]: unknown
}

class TerminalBridge {
  private readonly channel = new BroadcastChannel(CHANNEL)
  private seq = 0
  private readonly pending = new Map<number, (r: NativeReply) => void>()
  private readonly listeners = new Map<number, (event: string, data: string) => void>()

  constructor() {
    this.channel.onmessage = (event: MessageEvent) => {
      const msg = event.data
      if (!msg || msg.dir !== "fromNative") return
      if (typeof msg.reqId === "number") {
        const resolve = this.pending.get(msg.reqId)
        if (resolve) {
          this.pending.delete(msg.reqId)
          resolve(msg.result as NativeReply)
        }
        return
      }
      if (typeof msg.event === "string" && typeof msg.id === "number") {
        this.listeners.get(msg.id)?.(msg.event, msg.data ?? "")
      }
    }
  }

  /// Subscribe a terminal id to native events (data/ready/exit).
  listen(id: number, handler: (event: string, data: string) => void): void {
    this.listeners.set(id, handler)
  }

  unlisten(id: number): void {
    this.listeners.delete(id)
  }

  send(op: string, id: number, extra: Record<string, unknown> = {}): Promise<NativeReply> {
    const reqId = this.seq++
    return new Promise<NativeReply>((resolve) => {
      this.pending.set(reqId, resolve)
      this.channel.postMessage({ dir: "toNative", op, id, reqId, ...extra })
      // Control acks are fast; don't leak forever if native is absent.
      setTimeout(() => {
        if (this.pending.delete(reqId)) resolve({ ok: false, error: "timeout" })
      }, 5000)
    })
  }
}

const bridge = new TerminalBridge()
let nextId = 1

function decode(base64: string): string {
  return new TextDecoder().decode(base64ToBytes(base64))
}

function encode(text: string): string {
  return bytesToBase64(new TextEncoder().encode(text))
}

/// A vscode.Pseudoterminal backed by a native ios_system session. Line editing
/// (echo, backspace, history-free) happens here so the native side receives
/// complete command lines; interactive raw mode is a later enhancement.
export class IpadPty implements vscode.Pseudoterminal {
  private readonly writeEmitter = new vscode.EventEmitter<string>()
  readonly onDidWrite = this.writeEmitter.event
  private readonly closeEmitter = new vscode.EventEmitter<number | void>()
  readonly onDidClose = this.closeEmitter.event

  private readonly id = nextId++
  private buffer = ""
  private cols = 80
  private rows = 24

  open(initialDimensions: vscode.TerminalDimensions | undefined): void {
    if (initialDimensions) {
      this.cols = initialDimensions.columns
      this.rows = initialDimensions.rows
    }
    bridge.listen(this.id, (event, data) => this.onNative(event, data))
    this.writeEmitter.fire("\x1b[1miPad local shell\x1b[0m (ios_system) — type a command\r\n")
    void bridge.send("open", this.id, { cols: this.cols, rows: this.rows }).then((r) => {
      if (!r.ok) this.writeEmitter.fire(`\r\n\x1b[31mfailed to start: ${r.error ?? "?"}\x1b[0m\r\n`)
    })
  }

  close(): void {
    void bridge.send("close", this.id)
    bridge.unlisten(this.id)
  }

  setDimensions(dimensions: vscode.TerminalDimensions): void {
    this.cols = dimensions.columns
    this.rows = dimensions.rows
    void bridge.send("resize", this.id, { cols: this.cols, rows: this.rows })
  }

  handleInput(data: string): void {
    for (const ch of data) {
      if (ch === "\r") {
        // Enter: echo newline, ship the line, reset.
        this.writeEmitter.fire("\r\n")
        void bridge.send("input", this.id, { data: encode(this.buffer + "\n") })
        this.buffer = ""
      } else if (ch === "\x7f" || ch === "\b") {
        // Backspace.
        if (this.buffer.length > 0) {
          this.buffer = this.buffer.slice(0, -1)
          this.writeEmitter.fire("\b \b")
        }
      } else if (ch === "\x03") {
        // Ctrl-C: abandon the current line.
        this.writeEmitter.fire("^C\r\n")
        this.buffer = ""
        void bridge.send("input", this.id, { data: encode("\n") })
      } else if (ch >= " ") {
        this.buffer += ch
        this.writeEmitter.fire(ch) // echo
      }
    }
  }

  private onNative(event: string, data: string): void {
    switch (event) {
      case "data":
        // Native sends \n line endings; xterm needs \r\n.
        this.writeEmitter.fire(decode(data).replace(/(?<!\r)\n/g, "\r\n"))
        break
      case "ready":
        this.writeEmitter.fire("\x1b[32m$\x1b[0m ")
        break
      case "exit":
        this.closeEmitter.fire(Number(decode(data)) || 0)
        bridge.unlisten(this.id)
        break
    }
  }
}
