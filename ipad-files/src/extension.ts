import * as vscode from "vscode"
import { bridge } from "./bridge"
import { IpadFileSystemProvider } from "./fileSystemProvider"

const SCHEME = "ipadfs"

export function activate(context: vscode.ExtensionContext): void {
  const provider = new IpadFileSystemProvider()
  context.subscriptions.push(
    vscode.workspace.registerFileSystemProvider(SCHEME, provider, { isCaseSensitive: true }),
  )

  // WebKit doesn't fire a `copy`/`cut` DOM event when there's no selection, so
  // VS Code's built-in empty-selection line copy/cut silently does nothing on
  // iPad. These keybindings (active only when the selection is empty) reproduce
  // it through the VS Code API + clipboard, which the native wrapper bridges to
  // UIPasteboard.
  context.subscriptions.push(
    vscode.commands.registerCommand("ipadFiles.copyLine", async () => {
      const editor = vscode.window.activeTextEditor
      if (!editor) return
      const line = editor.document.lineAt(editor.selection.active.line)
      const eol = editor.document.eol === vscode.EndOfLine.CRLF ? "\r\n" : "\n"
      await vscode.env.clipboard.writeText(line.text + eol)
    }),
  )

  context.subscriptions.push(
    vscode.commands.registerCommand("ipadFiles.cutLine", async () => {
      const editor = vscode.window.activeTextEditor
      if (!editor) return
      const lineNumber = editor.selection.active.line
      const line = editor.document.lineAt(lineNumber)
      const eol = editor.document.eol === vscode.EndOfLine.CRLF ? "\r\n" : "\n"
      await vscode.env.clipboard.writeText(line.text + eol)
      // Delete the whole line including its trailing newline.
      await editor.edit((builder) => builder.delete(line.rangeIncludingLineBreak))
    }),
  )

  context.subscriptions.push(
    vscode.commands.registerCommand("ipadFiles.openFolder", async () => {
      try {
        // Asks the native wrapper to present the iOS document picker.
        const pick = await bridge.request("pick-folder")
        if (!pick.ok) {
          if (pick.status !== 499) {
            vscode.window.showErrorMessage(`Open Local Folder failed: ${pick.error ?? pick.status}`)
          }
          return // 499 = user cancelled the picker
        }
        const uri = vscode.Uri.parse(`${SCHEME}:/${pick.id as string}`)
        const index = vscode.workspace.workspaceFolders?.length ?? 0
        vscode.workspace.updateWorkspaceFolders(index, 0, {
          uri,
          name: (pick.name as string) || "iPad Folder",
        })
      } catch (error) {
        vscode.window.showErrorMessage(`Open Local Folder failed: ${error}`)
      }
    }),
  )
}

export function deactivate(): void {
  // FileSystemProvider + command disposed via context.subscriptions.
}
