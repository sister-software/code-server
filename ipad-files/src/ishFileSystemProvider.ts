import * as vscode from "vscode"
import { base64ToBytes, bridge, BridgeResult, bytesToBase64 } from "./bridge"

/// Browses/edits the live Alpine guest filesystem from the iSH emulator.
/// URIs are `ish:/absolute/guest/path`; the whole guest fs is one root, so the
/// URI path IS the guest path. Ops bridge to the native iSH kernel (ish-* ops).
export const ISH_SCHEME = "ish"

function childUri(parent: vscode.Uri, name: string): vscode.Uri {
  const base = parent.path.endsWith("/") ? parent.path : parent.path + "/"
  return parent.with({ path: base + name })
}

function fail(result: BridgeResult, uri: vscode.Uri): vscode.FileSystemError {
  switch (result.status) {
    case 404:
      return vscode.FileSystemError.FileNotFound(uri)
    case 503:
      return vscode.FileSystemError.Unavailable("Alpine isn't running yet — open a terminal first.")
    default:
      return vscode.FileSystemError.Unavailable(result.error ?? `iSH fs error ${result.status}`)
  }
}

export class IshFileSystemProvider implements vscode.FileSystemProvider {
  private readonly emitter = new vscode.EventEmitter<vscode.FileChangeEvent[]>()
  readonly onDidChangeFile = this.emitter.event

  // VS Code doesn't reliably call watch() for virtual schemes, so we drive the
  // polling ourselves: every ~2s, diff the listing of each open ish directory
  // (workspace roots + any expanded subdir we've read) and emit add/remove
  // events. iSH has no inotify to bridge.
  private readonly snapshots = new Map<string, Set<string>>()

  constructor() {
    setInterval(() => void this.poll(), 2000)
  }

  watch(): vscode.Disposable {
    return new vscode.Disposable(() => undefined)
  }

  /// Track a directory for change polling once it's been listed.
  private trackDir(uri: vscode.Uri, names: string[]): void {
    if (!this.snapshots.has(uri.path)) this.snapshots.set(uri.path, new Set(names))
  }

  private async poll(): Promise<void> {
    // Always include workspace ish roots; plus any dirs we've already listed.
    for (const folder of vscode.workspace.workspaceFolders ?? [])
      if (folder.uri.scheme === ISH_SCHEME && !this.snapshots.has(folder.uri.path))
        this.snapshots.set(folder.uri.path, new Set())

    for (const path of [...this.snapshots.keys()]) {
      try {
        const result = await bridge.request("ish-list", { path })
        if (!result.ok) continue
        const now = new Set(((result.entries as { name: string }[]) ?? []).map((e) => e.name))
        const prev = this.snapshots.get(path) ?? new Set()
        const dirUri = vscode.Uri.from({ scheme: ISH_SCHEME, path })
        const changes: vscode.FileChangeEvent[] = []
        for (const name of now)
          if (!prev.has(name)) changes.push({ type: vscode.FileChangeType.Created, uri: childUri(dirUri, name) })
        for (const name of prev)
          if (!now.has(name)) changes.push({ type: vscode.FileChangeType.Deleted, uri: childUri(dirUri, name) })
        if (changes.length) this.emitter.fire(changes)
        this.snapshots.set(path, now)
      } catch {
        /* guest may be mid-boot; retry next tick */
      }
    }
  }

  async stat(uri: vscode.Uri): Promise<vscode.FileStat> {
    const result = await bridge.request("ish-stat", { path: uri.path })
    if (!result.ok) throw fail(result, uri)
    return {
      type: result.type === "directory" ? vscode.FileType.Directory : vscode.FileType.File,
      ctime: 0,
      mtime: (result.mtime as number) ?? 0,
      size: (result.size as number) ?? 0,
    }
  }

  async readDirectory(uri: vscode.Uri): Promise<[string, vscode.FileType][]> {
    const result = await bridge.request("ish-list", { path: uri.path })
    if (!result.ok) throw fail(result, uri)
    const entries = (result.entries as { name: string; type: string }[]) ?? []
    this.trackDir(uri, entries.map((e) => e.name)) // poll this dir for live changes
    return entries.map((e): [string, vscode.FileType] => [
      e.name,
      e.type === "directory" ? vscode.FileType.Directory : vscode.FileType.File,
    ])
  }

  async readFile(uri: vscode.Uri): Promise<Uint8Array> {
    const result = await bridge.request("ish-read", { path: uri.path })
    if (!result.ok) throw fail(result, uri)
    return base64ToBytes((result.bytes as string) ?? "")
  }

  async writeFile(uri: vscode.Uri, content: Uint8Array): Promise<void> {
    const result = await bridge.request("ish-write", { path: uri.path }, bytesToBase64(content))
    if (!result.ok) throw fail(result, uri)
    this.emitter.fire([{ type: vscode.FileChangeType.Changed, uri }])
  }

  async createDirectory(uri: vscode.Uri): Promise<void> {
    const result = await bridge.request("ish-mkdir", { path: uri.path })
    if (!result.ok) throw fail(result, uri)
  }

  async delete(uri: vscode.Uri): Promise<void> {
    const result = await bridge.request("ish-delete", { path: uri.path })
    if (!result.ok) throw fail(result, uri)
    this.emitter.fire([{ type: vscode.FileChangeType.Deleted, uri }])
  }

  async rename(oldUri: vscode.Uri, newUri: vscode.Uri): Promise<void> {
    const result = await bridge.request("ish-rename", { from: oldUri.path, to: newUri.path })
    if (!result.ok) throw fail(result, oldUri)
    this.emitter.fire([
      { type: vscode.FileChangeType.Deleted, uri: oldUri },
      { type: vscode.FileChangeType.Created, uri: newUri },
    ])
  }
}
