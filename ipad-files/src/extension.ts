import * as vscode from "vscode"
import { bridge, bridgeLog } from "./bridge"
import { IpadFileSystemProvider } from "./fileSystemProvider"
import { IshFileSystemProvider, ISH_SCHEME } from "./ishFileSystemProvider"
import { IpadPty } from "./terminal"

const SCHEME = "ipadfs"

export function activate(context: vscode.ExtensionContext): void {
  const folders = vscode.workspace.workspaceFolders?.map((f) => f.uri.toString()).join(", ") ?? "none"
  bridgeLog(`activate; workspace folders=[${folders}]`)

  const provider = new IpadFileSystemProvider()
  context.subscriptions.push(
    vscode.workspace.registerFileSystemProvider(SCHEME, provider, { isCaseSensitive: true }),
  )
  bridgeLog(`registered FileSystemProvider for ${SCHEME}`)

  // The live Alpine guest filesystem (iSH), browsable/editable in the Explorer.
  context.subscriptions.push(
    vscode.workspace.registerFileSystemProvider(ISH_SCHEME, new IshFileSystemProvider(), {
      isCaseSensitive: true,
    }),
  )
  context.subscriptions.push(
    vscode.commands.registerCommand("ipadFiles.mountAlpine", () => {
      // Mount operator's home (the terminal opens there too), not root's.
      const uri = vscode.Uri.parse(`${ISH_SCHEME}:/home/operator`)
      const index = vscode.workspace.workspaceFolders?.length ?? 0
      vscode.workspace.updateWorkspaceFolders(index, 0, { uri, name: "Alpine (operator)" })
    }),
  )

  // Offline terminal: a Pseudoterminal bridged to the native ios_system engine.
  // Available from the terminal-profile dropdown and a command.
  context.subscriptions.push(
    vscode.window.registerTerminalProfileProvider("ipadFiles.terminal", {
      provideTerminalProfile: () =>
        new vscode.TerminalProfile({ name: "iPad", pty: new IpadPty() }),
    }),
  )
  context.subscriptions.push(
    vscode.commands.registerCommand("ipadFiles.newTerminal", () => {
      vscode.window.createTerminal({ name: "iPad", pty: new IpadPty() }).show()
    }),
  )

  // The iSH profile is made the default via contributes.configurationDefaults,
  // so + / Terminal ▸ New create it without the profile picker.

  // Host-action commands: the command-palette equivalents of the native wrapper's
  // two-finger action menu (which is hard to trigger in the Simulator). Each just
  // signals the native WebViewController via the bridge; fire-and-forget because
  // reload/hardReload tear down the page before a reply could arrive.
  function hostAction(action: string): void {
    bridge.request("host-action", { action }).catch(() => undefined)
  }
  context.subscriptions.push(
    vscode.commands.registerCommand("ipadFiles.reload", () => hostAction("reload")),
    vscode.commands.registerCommand("ipadFiles.hardReload", () => hostAction("hardReload")),
    vscode.commands.registerCommand("ipadFiles.servers", () => hostAction("servers")),
    vscode.commands.registerCommand("ipadFiles.diagnostics", () => hostAction("diagnostics")),
  )

  // A pure web workbench has no terminal backend, so the panel is inert until a
  // terminal exists. Pre-create one (local workbench only) so selecting the
  // Terminal tab shows a ready shell, like desktop. open()/boot is deferred by
  // VS Code until the terminal is first revealed.
  if (!vscode.env.remoteName) {
    context.subscriptions.push(vscode.window.createTerminal({ name: "iPad", pty: new IpadPty() }))
  }

  // WebKit doesn't fire a `copy`/`cut` DOM event when there's no selection, so
  // VS Code's built-in empty-selection line copy/cut silently does nothing on
  // iPad. These keybindings (active only when the selection is empty) ask the
  // wrapper's bridge.js to dispatch a synthetic copy/cut event at Monaco's
  // textarea: VS Code's real handler then performs the line copy/cut AND stores
  // the in-memory metadata that makes paste insert line-above (desktop
  // semantics). Without the wrapper (desktop browser, relay absent) we fall
  // back to a plain clipboard write: correct content, paste lands at the cursor.
  let editorBridgeAvailable: boolean | undefined

  async function syntheticEditorClipboard(op: "editor-copy" | "editor-cut"): Promise<boolean> {
    if (editorBridgeAvailable === false) return false
    try {
      const result = await bridge.request(op, {}, undefined, 1_000)
      editorBridgeAvailable = true
      return result.ok === true
    } catch {
      editorBridgeAvailable = false // relay missing; don't pay the wait again
      return false
    }
  }

  context.subscriptions.push(
    vscode.commands.registerCommand("ipadFiles.copyLine", async () => {
      const editor = vscode.window.activeTextEditor
      if (!editor) return
      if (await syntheticEditorClipboard("editor-copy")) return
      const line = editor.document.lineAt(editor.selection.active.line)
      const eol = editor.document.eol === vscode.EndOfLine.CRLF ? "\r\n" : "\n"
      await vscode.env.clipboard.writeText(line.text + eol)
    }),
  )

  context.subscriptions.push(
    vscode.commands.registerCommand("ipadFiles.cutLine", async () => {
      const editor = vscode.window.activeTextEditor
      if (!editor) return
      // The synthetic cut also triggers the editor's own line deletion.
      if (await syntheticEditorClipboard("editor-cut")) return
      const lineNumber = editor.selection.active.line
      const line = editor.document.lineAt(lineNumber)
      const eol = editor.document.eol === vscode.EndOfLine.CRLF ? "\r\n" : "\n"
      await vscode.env.clipboard.writeText(line.text + eol)
      // Delete the whole line including its trailing newline.
      await editor.edit((builder) => builder.delete(line.rangeIncludingLineBreak))
    }),
  )

  // Asks the native wrapper to present the iOS document picker; returns the
  // picked root's ipadfs URI and display name, or undefined on cancel/error.
  async function pickLocalFolder(): Promise<{ uri: vscode.Uri; name: string } | undefined> {
    const pick = await bridge.request("pick-folder")
    bridgeLog(`pick result ok=${pick.ok} id=${pick.id} name=${pick.name} status=${pick.status}`)
    if (!pick.ok) {
      if (pick.status !== 499) {
        // 499 = user cancelled the picker
        vscode.window.showErrorMessage(`Pick Local Folder failed: ${pick.error ?? pick.status}`)
      }
      return undefined
    }
    return {
      uri: vscode.Uri.parse(`${SCHEME}:/${pick.id as string}`),
      name: (pick.name as string) || "iPad Folder",
    }
  }

  // Replaces the current workspace with the picked folder. The workbench
  // reloads; onFileSystem:ipadfs re-activates us so the provider is back
  // before the new root resolves.
  context.subscriptions.push(
    vscode.commands.registerCommand("ipadFiles.openFolder", async () => {
      try {
        const picked = await pickLocalFolder()
        if (!picked) return
        bridgeLog(`openFolder uri=${picked.uri.toString()}`)
        await vscode.commands.executeCommand("vscode.openFolder", picked.uri)
      } catch (error) {
        vscode.window.showErrorMessage(`Open Local Folder failed: ${error}`)
      }
    }),
  )

  // Adds the picked folder alongside the current workspace folders.
  context.subscriptions.push(
    vscode.commands.registerCommand("ipadFiles.addFolder", async () => {
      try {
        const picked = await pickLocalFolder()
        if (!picked) return
        const index = vscode.workspace.workspaceFolders?.length ?? 0
        bridgeLog(`adding workspace folder uri=${picked.uri.toString()} at index=${index}`)
        const added = vscode.workspace.updateWorkspaceFolders(index, 0, {
          uri: picked.uri,
          name: picked.name,
        })
        bridgeLog(`updateWorkspaceFolders returned ${added}; count now=${vscode.workspace.workspaceFolders?.length}`)
      } catch (error) {
        vscode.window.showErrorMessage(`Add Local Folder failed: ${error}`)
      }
    }),
  )
}

export function deactivate(): void {
  // FileSystemProvider + command disposed via context.subscriptions.
}
