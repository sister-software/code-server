import * as vscode from "vscode"
import { bridge } from "./bridge"
import { IpadFileSystemProvider } from "./fileSystemProvider"

const SCHEME = "ipadfs"

export function activate(context: vscode.ExtensionContext): void {
  const provider = new IpadFileSystemProvider()
  context.subscriptions.push(
    vscode.workspace.registerFileSystemProvider(SCHEME, provider, { isCaseSensitive: true }),
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
