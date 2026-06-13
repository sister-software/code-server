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
  // "prompt": we line-edit locally and ship a whole line via run.
  // "running": a command owns the tty — forward every keystroke raw to stdin.
  private mode: "prompt" | "running" = "prompt"
  private history: string[] = []
  private historyIndex = 0

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
    // A command owns the tty: forward keystrokes raw (the program echoes and
    // does its own editing). Ctrl-C interrupts the command.
    if (this.mode === "running") {
      if (data === "\x03") {
        void bridge.send("interrupt", this.id)
      } else {
        void bridge.send("stdin", this.id, { data: encode(data) })
      }
      return
    }

    // Prompt mode: local line editing.
    for (const ch of data) {
      if (ch === "\r") {
        this.writeEmitter.fire("\r\n")
        const line = this.buffer
        this.buffer = ""
        if (line.trim().length > 0) {
          this.history.push(line)
          this.historyIndex = this.history.length
        }
        this.mode = "running"
        void bridge.send("run", this.id, { data: encode(line) })
      } else if (ch === "\x7f" || ch === "\b") {
        if (this.buffer.length > 0) {
          this.buffer = this.buffer.slice(0, -1)
          this.writeEmitter.fire("\b \b")
        }
      } else if (ch === "\x03") {
        this.writeEmitter.fire("^C\r\n")
        this.buffer = ""
        this.writeEmitter.fire("\x1b[32m$\x1b[0m ")
      } else if (ch === "\x1b") {
        // Escape sequences (arrows): handle up/down for history below.
        // Full sequences arrive in one chunk, so inspect `data` directly.
      } else if (ch >= " ") {
        this.buffer += ch
        this.writeEmitter.fire(ch)
      }
    }

    // Up/Down history recall (arrows come as ESC[A / ESC[B).
    if (data === "\x1b[A" || data === "\x1b[B") {
      if (data === "\x1b[A" && this.historyIndex > 0) this.historyIndex--
      else if (data === "\x1b[B" && this.historyIndex < this.history.length) this.historyIndex++
      const recalled = this.history[this.historyIndex] ?? ""
      // Clear the current line, then write the recalled command.
      this.writeEmitter.fire("\r\x1b[K\x1b[32m$\x1b[0m " + recalled)
      this.buffer = recalled
    }
  }

  private onNative(event: string, data: string): void {
    switch (event) {
      case "data":
        // Native sends \n line endings; xterm needs \r\n.
        this.writeEmitter.fire(decode(data).replace(/(?<!\r)\n/g, "\r\n"))
        break
      case "ready":
        // Command finished (or initial): back to prompt mode.
        this.mode = "prompt"
        this.writeEmitter.fire("\x1b[32m$\x1b[0m ")
        break
      case "exit":
        this.closeEmitter.fire(Number(decode(data)) || 0)
        bridge.unlisten(this.id)
        break
    }
  }
}
