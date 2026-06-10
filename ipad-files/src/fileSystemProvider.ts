import * as vscode from "vscode"
import { base64ToBytes, bridge, bridgeLog, BridgeResult, bytesToBase64 } from "./bridge"

/// URIs look like `ipadfs:/<rootId>/relative/path`. The first path segment is the
/// id of a native security-scoped bookmark; the rest is the path within it.
function split(uri: vscode.Uri): { id: string; path: string } {
  const segments = uri.path.replace(/^\/+/, "").split("/")
  const id = segments.shift() ?? ""
  return { id, path: segments.join("/") }
}

function fail(result: BridgeResult, uri: vscode.Uri): vscode.FileSystemError {
  switch (result.status) {
    case 404:
      return vscode.FileSystemError.FileNotFound(uri)
    case 410:
      return vscode.FileSystemError.Unavailable("This folder is no longer accessible. Re-add it.")
    default:
      return vscode.FileSystemError.Unavailable(result.error ?? `bridge error ${result.status}`)
  }
}

export class IpadFileSystemProvider implements vscode.FileSystemProvider {
  private readonly emitter = new vscode.EventEmitter<vscode.FileChangeEvent[]>()
  readonly onDidChangeFile = this.emitter.event

  // File watching is not yet bridged; return a no-op disposable. VS Code falls
  // back to refresh-on-focus, which is acceptable for v1.
  watch(): vscode.Disposable {
    return new vscode.Disposable(() => undefined)
  }

  async stat(uri: vscode.Uri): Promise<vscode.FileStat> {
    const { id, path } = split(uri)
    bridgeLog(`stat ${uri.toString()} -> id=${id} path="${path}"`)
    const result = await bridge.request("stat", { id, path })
    bridgeLog(`stat result ok=${result.ok} type=${result.type} status=${result.status}`)
    if (!result.ok) throw fail(result, uri)
    return {
      type: result.type === "directory" ? vscode.FileType.Directory : vscode.FileType.File,
      ctime: (result.ctime as number) ?? 0,
      mtime: (result.mtime as number) ?? 0,
      size: (result.size as number) ?? 0,
    }
  }

  async readDirectory(uri: vscode.Uri): Promise<[string, vscode.FileType][]> {
    const { id, path } = split(uri)
    bridgeLog(`readDirectory ${uri.toString()}`)
    const result = await bridge.request("list", { id, path })
    bridgeLog(`readDirectory result ok=${result.ok} entries=${(result.entries as unknown[])?.length} status=${result.status}`)
    if (!result.ok) throw fail(result, uri)
    const entries = (result.entries as { name: string; type: string }[]) ?? []
    return entries.map((entry): [string, vscode.FileType] => [
      entry.name,
      entry.type === "directory" ? vscode.FileType.Directory : vscode.FileType.File,
    ])
  }

  async readFile(uri: vscode.Uri): Promise<Uint8Array> {
    const { id, path } = split(uri)
    const result = await bridge.request("read", { id, path })
    if (!result.ok) throw fail(result, uri)
    return base64ToBytes((result.bytes as string) ?? "")
  }

  async writeFile(uri: vscode.Uri, content: Uint8Array): Promise<void> {
    const { id, path } = split(uri)
    const result = await bridge.request("write", { id, path }, bytesToBase64(content))
    if (!result.ok) throw fail(result, uri)
    this.emitter.fire([{ type: vscode.FileChangeType.Changed, uri }])
  }

  async createDirectory(uri: vscode.Uri): Promise<void> {
    const { id, path } = split(uri)
    const result = await bridge.request("mkdir", { id, path })
    if (!result.ok) throw fail(result, uri)
  }

  async delete(uri: vscode.Uri): Promise<void> {
    const { id, path } = split(uri)
    const result = await bridge.request("delete", { id, path })
    if (!result.ok) throw fail(result, uri)
    this.emitter.fire([{ type: vscode.FileChangeType.Deleted, uri }])
  }

  async rename(oldUri: vscode.Uri, newUri: vscode.Uri): Promise<void> {
    const from = split(oldUri)
    const to = split(newUri)
    if (from.id !== to.id) {
      throw vscode.FileSystemError.Unavailable("Cannot move across roots")
    }
    const result = await bridge.request("rename", { id: from.id, from: from.path, to: to.path })
    if (!result.ok) throw fail(result, oldUri)
    this.emitter.fire([
      { type: vscode.FileChangeType.Deleted, uri: oldUri },
      { type: vscode.FileChangeType.Created, uri: newUri },
    ])
  }
}
